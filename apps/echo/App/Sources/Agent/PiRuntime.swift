import Foundation
import JavaScriptCore

// 原版 Pi（earendil-works/pi 的 @earendil-works/pi-agent-core，MIT 许可）跑在系统自带的 JavaScriptCore 里。
// 打包好的代码在 App/Resources/pi-agent.jsbundle（由 apps/echo/pi/ 用 esbuild 生成，桥接层是 pi/host.js）。
// 分工：Pi 管整个智能体循环——轮次、工具调度、参数校验、事件、收尾工具的终止、中断；
// 这里只做三件 Pi 在手机上做不了的事：发流式 HTTP 请求、执行原生工具、把事件交给界面。

enum PiEvent {
    case turnStart(Int)
    /// 这一轮到目前为止的全文
    case text(String)
    /// 一轮结束时模型说的话，以及它要调用几个工具
    case assistant(text: String, toolCalls: Int)
    case toolStart(String)
    /// DeepSeek 服务端联网时用到的网页
    case sources([WebSource])
}

@MainActor
final class PiRuntime {
    static let shared = PiRuntime()

    private struct Run {
        var tools: [AgentTool]
        var onEvent: (PiEvent) -> Void
        var finish: (String, String) -> Void
    }

    private var context: JSContext?
    private var pi: JSValue?
    private var loadFailed = false
    private var runs: [String: Run] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    private var endpoint: URL?
    private var key = ""
    private(set) var version = ""

    /// 打包的 Pi 能不能用。第一次问的时候加载。
    var available: Bool {
        load()
        return pi != nil
    }

    private func load() {
        guard context == nil, !loadFailed else { return }
        guard let url = Bundle.main.url(forResource: "pi-agent", withExtension: "jsbundle"),
              let code = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else {
            loadFailed = true
            return
        }
        let chat: @convention(block) (String, String) -> Void = { [weak self] id, body in
            MainActor.assumeIsolated { self?.startChat(id, body) }
        }
        let cancel: @convention(block) (String) -> Void = { [weak self] id in
            MainActor.assumeIsolated { self?.requests[id]?.cancel() }
        }
        let tool: @convention(block) (String, String, String) -> Void = { [weak self] callID, name, args in
            MainActor.assumeIsolated { self?.startTool(callID, name, args) }
        }
        let event: @convention(block) (String, String) -> Void = { [weak self] runID, json in
            MainActor.assumeIsolated { self?.handle(runID, json) }
        }
        ctx.setObject(unsafeBitCast(chat, to: AnyObject.self), forKeyedSubscript: "__pi_chat" as NSString)
        ctx.setObject(unsafeBitCast(cancel, to: AnyObject.self), forKeyedSubscript: "__pi_cancel" as NSString)
        ctx.setObject(unsafeBitCast(tool, to: AnyObject.self), forKeyedSubscript: "__pi_tool" as NSString)
        ctx.setObject(unsafeBitCast(event, to: AnyObject.self), forKeyedSubscript: "__pi_event" as NSString)
        ctx.evaluateScript(code)
        guard let value = ctx.objectForKeyedSubscript("Pi"), value.isObject else {
            loadFailed = true
            return
        }
        version = value.objectForKeyedSubscript("version")?.toString() ?? ""
        context = ctx
        pi = value
    }

    private func call(_ method: String, _ arguments: [Any]) {
        _ = pi?.invokeMethod(method, withArguments: arguments)
    }

    /// 跑一次完整的智能体循环。返回停止原因：stop / max_turns。出错抛错，被取消抛 CancellationError。
    /// history 每项是 {role: user|assistant, text, fileIDs?}。
    func run(system: String, model: String, endpoint: URL, key: String, thinking: Bool?, serverTools: Bool, tools: [AgentTool],
             history: [[String: Any]], prompt: String, images: [Data], fileIDs: [String], maxTurns: Int,
             onEvent: @escaping (PiEvent) -> Void) async throws -> String {
        guard available else { throw DigestError.unavailable("Pi 内核没有加载成功。") }
        self.endpoint = endpoint
        self.key = key
        let runID = UUID().uuidString
        var config: [String: Any] = [
            "system": system,
            "model": model,
            "maxTurns": maxTurns,
            "tools": tools.map { t -> [String: Any] in ["name": t.name, "description": t.description, "parameters": t.parameters] },
            "history": history,
            "prompt": ["text": prompt, "images": images.map { $0.base64EncodedString() }, "fileIDs": fileIDs] as [String: Any],
        ]
        if let thinking { config["thinking"] = thinking }
        if serverTools {
            // DeepSeek 的服务端 harness：联网搜索、打开网页由 DeepSeek 自己多步完成（必须开思考，用 effort 控制快慢）
            config["serverTools"] = true
            config["effort"] = thinking == true ? "high" : "low"
        }
        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.runs[runID] = Run(tools: tools, onEvent: onEvent, finish: { reason, error in
                    if reason == "aborted" {
                        continuation.resume(throwing: CancellationError())
                    } else if reason == "error" {
                        continuation.resume(throwing: DigestError.unavailable(error.isEmpty ? "智能体出错了。" : error))
                    } else {
                        continuation.resume(returning: reason)
                    }
                })
                self.call("start", [runID, json])
            }
        } onCancel: {
            Task { @MainActor in PiRuntime.shared.call("abort", [runID]) }
        }
    }

    // MARK: Pi 要宿主做的事

    private func handle(_ runID: String, _ json: String) {
        guard let run = runs[runID],
              let e = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        switch e["type"] as? String ?? "" {
        case "turn_start":
            run.onEvent(.turnStart(e["turn"] as? Int ?? 0))
        case "text":
            run.onEvent(.text(e["text"] as? String ?? ""))
        case "assistant":
            run.onEvent(.assistant(text: e["text"] as? String ?? "", toolCalls: e["toolCalls"] as? Int ?? 0))
        case "tool_start":
            run.onEvent(.toolStart(e["name"] as? String ?? ""))
        case "sources":
            let items = (e["items"] as? [[String: Any]] ?? []).compactMap { item -> WebSource? in
                guard let url = item["url"] as? String, !url.isEmpty else { return nil }
                return WebSource(title: item["title"] as? String ?? url, url: url, site: item["site"] as? String ?? "")
            }
            if !items.isEmpty { run.onEvent(.sources(items)) }
        case "end":
            runs[runID] = nil
            run.finish(e["reason"] as? String ?? "stop", e["error"] as? String ?? "")
        default:
            break
        }
    }

    private func startTool(_ callID: String, _ name: String, _ args: String) {
        let runID = String(callID.split(separator: ":").first ?? "")
        let tool = runs[runID]?.tools.first(where: { $0.name == name })
        Task { @MainActor in
            var result = ToolResult(content: "没有名为 \(name) 的工具。", isError: true)
            if let tool {
                let parsed = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
                do {
                    result = try await tool.execute(parsed)
                } catch {
                    result = ToolResult(content: "工具出错：\(error.localizedDescription)", isError: true)
                }
            }
            let payload: [String: Any] = ["content": result.content, "isError": result.isError, "terminate": result.terminate]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            self.call("toolDone", [callID, String(data: data, encoding: .utf8) ?? "{}"])
        }
    }

    /// 发一个流式请求，把每条 SSE data 原样交回给 Pi 解析。繁忙或断网时在还没收到内容前重试。
    private func startChat(_ id: String, _ body: String) {
        guard let endpoint else {
            call("chatEnd", [id, "还没有配置云端服务。"])
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        let outgoing = request
        requests[id] = Task { @MainActor in
            var failure = ""
            var received = false
            for attempt in 0..<3 {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: outgoing)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 429 || code >= 500 {
                        failure = "云端服务繁忙（HTTP \(code)）。"
                        try await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
                        continue
                    }
                    if code != 200 {
                        var detail = ""
                        for try await line in bytes.lines {
                            detail += line
                            if detail.count > 300 { break }
                        }
                        if code == 401 {
                            failure = "云端密钥无效（HTTP 401）。"
                        } else if code == 402 {
                            failure = "DeepSeek 账户余额不足（HTTP 402）。"
                        } else {
                            failure = "云端服务返回错误（HTTP \(code)）\(String(detail.prefix(160)))"
                        }
                        break
                    }
                    failure = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        received = true
                        self.call("chunk", [id, payload])
                    }
                    break
                } catch {
                    failure = Task.isCancelled ? "已停下" : error.localizedDescription
                    if Task.isCancelled || received { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            self.requests[id] = nil
            self.call("chatEnd", [id, failure])
        }
    }
}

// MARK: - 统一入口

/// 对话和主动提醒都从这里进：优先用原版 Pi；万一它加载不了，退回到 Swift 移植的那个循环（PiAgent.swift）。
@MainActor
enum Brain {
    static var usingPi: Bool { PiRuntime.shared.available }
    /// 用 DeepSeek 服务端的联网 harness（默认开）。
    static var useHarness: Bool { UserDefaults.standard.object(forKey: "deepseekHarness") as? Bool ?? true }

    static func run(system: String, tools: [AgentTool], thinking: Bool?, history: [AgentMessage] = [], prompt: String,
                    images: [Data] = [], fileIDs: [String] = [], maxTurns: Int,
                    onEvent: @escaping (PiEvent) -> Void = { _ in }) async throws -> String {
        guard Cloud.ready else { throw DigestError.unavailable("还没有配置云端智能体：在对话页粘贴 DeepSeek 密钥，或到设置里填写。") }
        if PiRuntime.shared.available, let endpoint = Cloud.chatURL {
            // DeepSeek 自己的联网 harness 和我们的工具混用时，模型有时会以为“函数列表里没有搜索”，所以要明说
            let harness = Cloud.isDeepSeek && useHarness
            var system = system
            if harness {
                system += "\n\n联网搜索、打开网页、页内查找是你的内置能力（由系统直接提供，不在函数工具列表里，照常使用即可），需要最新信息时优先用它。函数工具里的 web_search / web_fetch 只是备用。绝不要说自己不能联网或没有搜索工具。"
            }
            var past: [[String: Any]] = []
            for message in history {
                switch message {
                case .user(let text), .userWithImages(let text, _):
                    past.append(["role": "user", "text": text])
                case .userWithFiles(let text, _, let ids):
                    past.append(["role": "user", "text": text, "fileIDs": ids])
                case .assistant(let text, _, _):
                    past.append(["role": "assistant", "text": text ?? ""])
                case .toolResult:
                    break
                }
            }
            return try await PiRuntime.shared.run(system: system, model: Cloud.modelName, endpoint: endpoint, key: Cloud.key,
                                                  thinking: Cloud.isDeepSeek ? thinking : nil, serverTools: harness, tools: tools, history: past,
                                                  prompt: prompt, images: images, fileIDs: fileIDs, maxTurns: maxTurns, onEvent: onEvent)
        }
        let agent = Agent(systemPrompt: system, tools: tools, model: try Cloud.model(thinking: thinking))
        agent.maxTurns = maxTurns
        agent.seed(history)
        agent.onPartial = { text in onEvent(.text(text)) }
        agent.subscribe { event in
            switch event {
            case .turnStart(let n):
                onEvent(.turnStart(n))
            case .messageEnd(let message):
                if case let .assistant(text, calls, _) = message { onEvent(.assistant(text: text ?? "", toolCalls: calls.count)) }
            case .toolExecutionStart(_, let name, _):
                onEvent(.toolStart(name))
            default:
                break
            }
        }
        return try await agent.prompt(prompt, images: images, fileIDs: fileIDs)
    }
}
