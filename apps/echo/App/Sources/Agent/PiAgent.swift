import Foundation

// 一个最小的智能体运行时，按 Pi（earendil-works/pi，packages/agent）的 agent-core 设计移植到 Swift：
// - Agent 持有对话状态（AgentMessage[]）、工具表和模型；prompt() 跑一轮完整循环
// - 每个 turn = 一次模型调用 + 它要求的工具执行；工具结果回填后进入下一个 turn，直到模型不再调用工具
// - 事件流：agent_start / turn_start / message_end / tool_execution_start / tool_execution_end / turn_end / agent_end
// - transformContext：每次请求前裁剪/注入上下文；beforeToolCall：可拦截工具调用
// - 工具结果可带 terminate：本批全部 terminate 时不再追加模型调用（用于“提交结果”这类收尾工具）
// - steer()：在当前 turn 的工具执行完后插入一条用户消息
// Pi 本身是 TypeScript/Node 程序，不能直接跑在 iOS App 里，所以这里移植它的循环与约定，而不是嵌入它。

struct ToolCall: Equatable {
    var id: String
    var name: String
    var arguments: String
}

enum AgentMessage {
    case user(String)
    case assistant(text: String?, toolCalls: [ToolCall])
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

/// 模型接口（对应 Pi 的 streamFn）。这里只需要整条回复，不需要流式。
protocol ChatModel {
    func complete(system: String, messages: [AgentMessage], tools: [AgentTool]) async throws -> AgentMessage
}

@MainActor
final class Agent {
    var systemPrompt: String
    var tools: [AgentTool]
    var model: ChatModel
    var maxTurns = 8
    var transformContext: (([AgentMessage]) -> [AgentMessage])?
    var beforeToolCall: ((ToolCall) -> ToolResult?)?

    private(set) var messages: [AgentMessage] = []
    private var steering: [String] = []
    private var listeners: [(AgentEvent) -> Void] = []

    init(systemPrompt: String, tools: [AgentTool], model: ChatModel) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.model = model
    }

    func subscribe(_ listener: @escaping (AgentEvent) -> Void) { listeners.append(listener) }
    func steer(_ text: String) { steering.append(text) }

    private func emit(_ event: AgentEvent) { for l in listeners { l(event) } }

    /// 跑完整个循环。返回停止原因：stop（模型自己停）/ terminate（收尾工具结束）/ max_turns。
    @discardableResult
    func prompt(_ text: String) async throws -> String {
        messages.append(.user(text))
        emit(.agentStart)
        emit(.messageEnd(.user(text)))
        var turn = 0
        var reason = "max_turns"
        loop: while turn < maxTurns {
            turn += 1
            emit(.turnStart(turn))
            let context = transformContext?(messages) ?? messages
            let reply = try await model.complete(system: systemPrompt, messages: context, tools: tools)
            messages.append(reply)
            emit(.messageEnd(reply))

            guard case let .assistant(_, calls) = reply, !calls.isEmpty else {
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

    func complete(system: String, messages: [AgentMessage], tools: [AgentTool]) async throws -> AgentMessage {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"), url.scheme == "https" else {
            throw DigestError.unavailable("云端服务地址必须是 HTTPS。")
        }
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m {
            case .user(let text):
                wire.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                var msg: [String: Any] = ["role": "assistant", "content": text ?? ""]
                if !calls.isEmpty {
                    msg["tool_calls"] = calls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.arguments]]
                    }
                }
                wire.append(msg)
            case .toolResult(let id, _, let content, _):
                wire.append(["role": "tool", "tool_call_id": id, "content": content])
            }
        }
        var body: [String: Any] = ["model": model, "temperature": temperature, "messages": wire]
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

        var lastError: Error = DigestError.unavailable("云端服务没有响应。")
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 || code >= 500 {
                    lastError = DigestError.unavailable("云端服务繁忙（HTTP \(code)）。")
                    try await Task.sleep(nanoseconds: UInt64(2 + attempt * 3) * 1_000_000_000)
                    continue
                }
                guard code == 200 else {
                    let detail = String(data: data, encoding: .utf8).map { String($0.prefix(160)) } ?? ""
                    throw DigestError.unavailable(code == 401 ? "云端密钥无效（HTTP 401）。" : "云端服务返回错误（HTTP \(code)）\(detail)")
                }
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
                return .assistant(text: text, toolCalls: calls)
            } catch let error as DigestError {
                throw error
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError
    }
}
