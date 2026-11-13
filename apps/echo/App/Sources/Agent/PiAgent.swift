import Foundation

// 一个最小的智能体运行时，按 Pi（earendil-works/pi，packages/agent）的 agent-core 设计移植到 Swift：
// - Agent 持有对话状态（AgentMessage[]）、工具表和模型；prompt() 跑一轮完整循环
// - 每个 turn = 一次模型调用 + 它要求的工具执行；工具结果回填后进入下一个 turn，直到模型不再调用工具
// - 事件流：agent_start / turn_start / message_end / tool_execution_start / tool_execution_end / turn_end / agent_end
// - transformContext：每次请求前裁剪/注入上下文；beforeToolCall：可拦截工具调用
// - 工具结果可带 terminate：本批全部 terminate 时不再追加模型调用（用于“提交结果”这类收尾工具）
// - onPartial：流式文字，界面可以一边生成一边显示
// - steer()：在当前 turn 的工具执行完后插入一条用户消息
// Pi 本身是 TypeScript/Node 程序，不能直接跑在 iOS App 里，所以这里移植它的循环与约定，而不是嵌入它。

struct ToolCall: Equatable {
    var id: String
    var name: String
    var arguments: String
}

enum AgentMessage {
    case user(String)
    /// 带图片的用户消息（JPEG 数据）。图片只能出现在 user 消息里。
    case userWithImages(String, [Data])
    /// 带图片和/或已上传文件（DeepSeek Files API 的 file_id）的用户消息。
    case userWithFiles(String, [Data], [String])
    /// reasoning：思考模式下模型的思维链。带工具的多轮请求必须原样回传，否则服务端拒绝。
    case assistant(text: String?, toolCalls: [ToolCall], reasoning: String?)
    case toolResult(callID: String, name: String, content: String, isError: Bool)
}

struct ToolResult {
    var content: String
    var isError = false
    var terminate = false
}

struct AgentTool {
    var name: String
    var description: String
    /// JSON Schema（object）
    var parameters: [String: Any]
    var execute: ([String: Any]) async throws -> ToolResult
}

enum AgentEvent {
    case agentStart
    case turnStart(Int)
    case messageEnd(AgentMessage)
    case toolExecutionStart(id: String, name: String, args: [String: Any])
    case toolExecutionEnd(id: String, name: String, result: ToolResult)
    case turnEnd(Int)
    case agentEnd(stopReason: String)
}

/// 模型接口（对应 Pi 的 streamFn）。onText 不为空时流式输出：每来一段就把“这一轮到目前为止的全文”交给它。
protocol ChatModel {
    func complete(system: String, messages: [AgentMessage], tools: [AgentTool], onText: ((String) -> Void)?) async throws -> AgentMessage
}

extension ChatModel {
    func complete(system: String, messages: [AgentMessage], tools: [AgentTool]) async throws -> AgentMessage {
        try await complete(system: system, messages: messages, tools: tools, onText: nil)
    }
}

@MainActor
final class Agent {
    var systemPrompt: String
    var tools: [AgentTool]
    var model: ChatModel
    var maxTurns = 8
    var transformContext: (([AgentMessage]) -> [AgentMessage])?
    var beforeToolCall: ((ToolCall) -> ToolResult?)?
    /// 流式文字（主线程回调，参数是当前这一轮到目前为止的全文）。
    var onPartial: ((String) -> Void)?

    private(set) var messages: [AgentMessage] = []
    private var steering: [String] = []
    private var listeners: [(AgentEvent) -> Void] = []

    init(systemPrompt: String, tools: [AgentTool], model: ChatModel) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.model = model
    }

    func subscribe(_ listener: @escaping (AgentEvent) -> Void) { listeners.append(listener) }
    /// 续上之前的对话（只放文字，不放工具过程）。
    func seed(_ history: [AgentMessage]) { messages = history }
    func steer(_ text: String) { steering.append(text) }

    private func emit(_ event: AgentEvent) { for l in listeners { l(event) } }

    /// 跑完整个循环。返回停止原因：stop（模型自己停）/ terminate（收尾工具结束）/ max_turns。
    @discardableResult
    func prompt(_ text: String, images: [Data] = [], fileIDs: [String] = []) async throws -> String {
        let first: AgentMessage
        if !fileIDs.isEmpty {
            first = .userWithFiles(text, images, fileIDs)
        } else if !images.isEmpty {
            first = .userWithImages(text, images)
        } else {
            first = .user(text)
        }
        messages.append(first)
        emit(.agentStart)
        emit(.messageEnd(first))
        var turn = 0
        var reason = "max_turns"
        loop: while turn < maxTurns {
            turn += 1
            emit(.turnStart(turn))
            let context = transformContext?(messages) ?? messages
            var sink: ((String) -> Void)?
            if let partial = onPartial {
                sink = { text in DispatchQueue.main.async { partial(text) } }
            }
            let reply = try await model.complete(system: systemPrompt, messages: context, tools: tools, onText: sink)
            messages.append(reply)
            emit(.messageEnd(reply))

            guard case let .assistant(_, calls, _) = reply, !calls.isEmpty else {
                emit(.turnEnd(turn))
                if steering.isEmpty { reason = "stop"; break loop }
                drainSteering()
                continue
            }

            var results: [ToolResult] = []
            for call in calls {
                let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                emit(.toolExecutionStart(id: call.id, name: call.name, args: args))
                var result: ToolResult
                if let blocked = beforeToolCall?(call) {
                    result = blocked
                } else if let tool = tools.first(where: { $0.name == call.name }) {
                    do { result = try await tool.execute(args) } catch { result = ToolResult(content: "工具出错：\(error.localizedDescription)", isError: true) }
                } else {
                    result = ToolResult(content: "没有名为 \(call.name) 的工具。可用：\(tools.map { $0.name }.joined(separator: ", "))", isError: true)
                }
                emit(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                let message = AgentMessage.toolResult(callID: call.id, name: call.name, content: result.content, isError: result.isError)
                messages.append(message)
                emit(.messageEnd(message))
                results.append(result)
            }
            emit(.turnEnd(turn))
            if results.allSatisfy({ $0.terminate }) { reason = "terminate"; break loop }
            drainSteering()
        }
        emit(.agentEnd(stopReason: reason))
        return reason
    }

    /// 最后一条助手文字回复。
    var lastText: String? {
        for m in messages.reversed() {
            if case let .assistant(text, _, _) = m, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private func drainSteering() {
        for s in steering {
            messages.append(.user(s))
            emit(.messageEnd(.user(s)))
        }
        steering.removeAll()
    }
}

// MARK: - OpenAI 兼容接口（DeepSeek 等）

struct OpenAICompatModel: ChatModel {
    var baseURL: String
    var model: String
    var apiKey: String
    var temperature = 0.2
    /// DeepSeek 的思考模式开关：nil 不传（用服务端默认），false 关掉以换取速度。
    var thinking: Bool? = nil

    private func wire(system: String, messages: [AgentMessage]) -> [[String: Any]] {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m {
            case .user(let text):
                wire.append(["role": "user", "content": text])
            case .userWithImages(let text, let images):
                wire.append(["role": "user", "content": Self.blocks(text: text, images: images, fileIDs: [])])
            case .userWithFiles(let text, let images, let fileIDs):
                wire.append(["role": "user", "content": Self.blocks(text: text, images: images, fileIDs: fileIDs)])
            case .assistant(let text, let calls, let reasoning):
                var msg: [String: Any] = ["role": "assistant", "content": text ?? ""]
                if let reasoning { msg["reasoning_content"] = reasoning }
                if !calls.isEmpty {
                    msg["tool_calls"] = calls.map { c -> [String: Any] in
                        let fn: [String: Any] = ["name": c.name, "arguments": c.arguments]
                        return ["id": c.id, "type": "function", "function": fn]
                    }
                }
                wire.append(msg)
            case .toolResult(let id, _, let content, _):
                wire.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        return wire
    }

    private static func blocks(text: String, images: [Data], fileIDs: [String]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for id in fileIDs {
            blocks.append(["type": "file", "file_id": id])
        }
        for data in images {
            let url: [String: Any] = ["url": "data:image/jpeg;base64," + data.base64EncodedString()]
            blocks.append(["type": "image_url", "image_url": url])
        }
        blocks.append(["type": "text", "text": text])
        return blocks
    }

    private func makeRequest(system: String, messages: [AgentMessage], tools: [AgentTool], stream: Bool) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"), url.scheme == "https" else {
            throw DigestError.unavailable("云端服务地址必须是 HTTPS。")
        }
        var body: [String: Any] = ["model": model, "temperature": temperature, "messages": wire(system: system, messages: messages)]
        if stream { body["stream"] = true }
        if let thinking {
            let mode: [String: Any] = ["type": thinking ? "enabled" : "disabled"]
            body["thinking"] = mode
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                let fn: [String: Any] = ["name": t.name, "description": t.description, "parameters": t.parameters]
                return ["type": "function", "function": fn]
            }
            body["tool_choice"] = "auto"
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func failure(_ code: Int, _ detail: String) -> DigestError {
        if code == 401 { return DigestError.unavailable("云端密钥无效（HTTP 401）。") }
        if code == 402 { return DigestError.unavailable("DeepSeek 账户余额不足（HTTP 402）。") }
        return DigestError.unavailable("云端服务返回错误（HTTP \(code)）\(String(detail.prefix(160)))")
    }

    func complete(system: String, messages: [AgentMessage], tools: [AgentTool], onText: ((String) -> Void)?) async throws -> AgentMessage {
        let request = try makeRequest(system: system, messages: messages, tools: tools, stream: onText != nil)
        var lastError: Error = DigestError.unavailable("云端服务没有响应。")
        for attempt in 0..<3 {
            do {
                if let onText {
                    if let message = try await streamOnce(request, onText: onText) { return message }
                } else {
                    if let message = try await plainOnce(request) { return message }
                }
                lastError = DigestError.unavailable("云端服务繁忙，稍后再试。")
                try await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
            } catch let error as DigestError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError
    }

    /// 返回 nil 表示服务繁忙、可以重试。
    private func plainOnce(_ request: URLRequest) async throws -> AgentMessage? {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || code >= 500 { return nil }
        guard code == 200 else { throw Self.failure(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw DigestError.unavailable("云端服务返回了无法识别的内容。")
        }
        let text = message["content"] as? String
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { c -> ToolCall? in
            guard let fn = c["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            return ToolCall(id: c["id"] as? String ?? UUID().uuidString, name: name, arguments: fn["arguments"] as? String ?? "{}")
        }
        return .assistant(text: text, toolCalls: calls, reasoning: message["reasoning_content"] as? String)
    }

    /// 流式（SSE）。文字一边到一边交给 onText；工具调用的参数分片拼起来。
    private func streamOnce(_ request: URLRequest, onText: (String) -> Void) async throws -> AgentMessage? {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || code >= 500 { return nil }
        guard code == 200 else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 300 { break }
            }
            throw Self.failure(code, detail)
        }
        var text = ""
        var reasoning = ""
        var sawReasoning = false
        var ids: [Int: String] = [:]
        var names: [Int: String] = [:]
        var arguments: [Int: String] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let piece = delta["reasoning_content"] as? String {
                reasoning += piece
                sawReasoning = true
            }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                onText(text)
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                if let id = call["id"] as? String, !id.isEmpty { ids[index] = id }
                if let fn = call["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty { names[index] = name }
                    if let piece = fn["arguments"] as? String { arguments[index, default: ""] += piece }
                }
            }
        }
        var calls: [ToolCall] = []
        for index in names.keys.sorted() {
            guard let name = names[index] else { continue }
            let args = arguments[index] ?? ""
            calls.append(ToolCall(id: ids[index] ?? UUID().uuidString, name: name, arguments: args.isEmpty ? "{}" : args))
        }
        if text.isEmpty && calls.isEmpty { throw DigestError.unavailable("云端服务没有返回内容。") }
        return .assistant(text: text.isEmpty ? nil : text, toolCalls: calls, reasoning: sawReasoning ? reasoning : nil)
    }
}
