import Foundation

/// 连接器：一个远程 MCP 服务（Streamable HTTP）。智能体可以调用它提供的工具。
struct Connector: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    /// 上次连接时拿到的工具
    var tools: [ConnectorTool] = []
    var lastError: String?
}

struct ConnectorTool: Codable, Equatable {
    var name: String
    var description: String
    /// JSON Schema 原文
    var schema: String
    /// 服务方声明这个工具只读（annotations.readOnlyHint）。旧数据里没有这一项。
    var readOnly: Bool?
}

@MainActor
final class Connectors: ObservableObject {
    static let shared = Connectors()
    @Published private(set) var list: [Connector] = []
    private var sessions: [UUID: String] = [:]
    private static let hello: [String: Any] = [
        "protocolVersion": "2025-03-26",
        "capabilities": [String: Any](),
        "clientInfo": ["name": "Echo", "version": "1.0"] as [String: Any],
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: "connectors"), let saved = try? JSONDecoder().decode([Connector].self, from: data) {
            list = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: "connectors") }
    }

    func add(name: String, url: String, token: String) -> Connector {
        let c = Connector(name: name, url: url)
        list.append(c)
        if !token.isEmpty { Keychain.set(token, for: "connector-" + c.id.uuidString) }
        save()
        return c
    }

    func remove(_ id: UUID) {
        list.removeAll { $0.id == id }
        Keychain.set("", for: "connector-" + id.uuidString)
        sessions[id] = nil
        save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].enabled = on
        save()
    }

    /// 连接并读取工具列表。
    func refresh(_ id: UUID) async {
        guard let c = list.first(where: { $0.id == id }) else { return }
        do {
            sessions[id] = nil
            _ = try await rpc(c, method: "initialize", params: Self.hello)
            try? await notify(c, method: "notifications/initialized")
            let result = try await rpc(c, method: "tools/list", params: [String: Any]())
            let raw = result["tools"] as? [[String: Any]] ?? []
            let tools: [ConnectorTool] = raw.compactMap { t -> ConnectorTool? in
                guard let name = t["name"] as? String else { return nil }
                let fallback: [String: Any] = ["type": "object", "properties": [String: Any]()]
                let schema: Any = t["inputSchema"] ?? fallback
                let data = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8)
                let hint = (t["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
                return ConnectorTool(name: name, description: String((t["description"] as? String ?? "").prefix(600)),
                                     schema: String(data: data, encoding: .utf8) ?? "{}", readOnly: hint)
            }
            update(id) { $0.tools = tools; $0.lastError = nil }
        } catch {
            update(id) { $0.lastError = error.localizedDescription }
        }
    }

    private func update(_ id: UUID, _ change: (inout Connector) -> Void) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        save()
    }

    /// 给智能体用的工具。名字加上连接器前缀，避免重名。
    /// readOnly = true：只给声明了只读的工具（助理自己醒来时用，不让它在没人看着的时候改东西）。
    func agentTools(readOnly: Bool) -> [AgentTool] {
        var out: [AgentTool] = []
        for (n, c) in list.enumerated() where c.enabled {
            for t in c.tools.prefix(24) {
                if readOnly && t.readOnly != true { continue }
                let schema = (try? JSONSerialization.jsonObject(with: Data(t.schema.utf8))) as? [String: Any] ?? ["type": "object"]
                let safe = String(t.name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(48))
                out.append(AgentTool(name: "c\(n)_\(safe)", description: "【连接器：\(c.name)】\(t.description)", parameters: schema) { [weak self] args in
                    guard let self else { return ToolResult(content: "连接器不可用", isError: true) }
                    return try await self.call(c, tool: t.name, args: args)
                })
            }
        }
        return out
    }

    private func call(_ c: Connector, tool: String, args: [String: Any]) async throws -> ToolResult {
        if sessions[c.id] == nil {
            _ = try await rpc(c, method: "initialize", params: Self.hello)
            try? await notify(c, method: "notifications/initialized")
        }
        let result = try await rpc(c, method: "tools/call", params: ["name": tool, "arguments": args])
        let blocks = result["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let isError = result["isError"] as? Bool ?? false
        return ToolResult(content: text.isEmpty ? "（没有文字结果）" : String(text.prefix(8000)), isError: isError)
    }

    // MARK: JSON-RPC over HTTP（响应可能是 JSON，也可能是 SSE）

    private func request(_ c: Connector, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: c.url.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else {
            throw DigestError.unavailable("连接器地址必须是 https:// 开头。")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = Keychain.get("connector-" + c.id.uuidString), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let session = sessions[c.id] { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func notify(_ c: Connector, method: String) async throws {
        let req = try request(c, body: ["jsonrpc": "2.0", "method": method])
        _ = try await URLSession.shared.data(for: req)
    }

    private func rpc(_ c: Connector, method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = Int.random(in: 1...1_000_000)
        let req = try request(c, body: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DigestError.unavailable("连接器没有响应。") }
        guard (200..<300).contains(http.statusCode) else {
            throw DigestError.unavailable(http.statusCode == 401 ? "连接器拒绝了令牌（HTTP 401）。" : "连接器返回 HTTP \(http.statusCode)。")
        }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessions[c.id] = session }
        let text = String(data: data, encoding: .utf8) ?? ""
        var candidates: [String] = []
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
                candidates.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        } else {
            candidates = [text]
        }
        for candidate in candidates.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any] else { continue }
            if let error = obj["error"] as? [String: Any] {
                throw DigestError.unavailable("连接器报错：\(error["message"] as? String ?? "未知错误")")
            }
            if let result = obj["result"] as? [String: Any] { return result }
        }
        throw DigestError.unavailable("连接器返回了无法识别的内容。")
    }
}
