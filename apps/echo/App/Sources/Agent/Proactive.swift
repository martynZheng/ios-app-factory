import Foundation
import BackgroundTasks

/// 主动提醒：有新的情境进来时（新整理出一段、到了新地点、系统给了后台时间），
/// 让智能体自己看一眼有没有值得现在告诉你的事。值得才发通知，并在对话里留一条。
/// iOS 不允许 App 真正常驻后台，所以它是“被这些事件唤醒”的，不是每分钟都在跑。
@MainActor
final class Proactive {
    static let shared = Proactive()
    static let taskID = "com.deffisoan.echo.refresh"
    private var running = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "proactiveEnabled") as? Bool ?? true
    }

    /// 必须在 App 启动完成前注册。
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                Proactive.scheduleRefresh()
                let work = Task { @MainActor in await Proactive.shared.consider(reason: "系统给了后台时间") }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// 节制：安静时段不打扰，两次之间至少隔 50 分钟，一天最多 6 条。
    private func allowed() -> Bool {
        let d = UserDefaults.standard
        guard Self.enabled, Cloud.ready, !Store.isDemo else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 8 || hour >= 23 { return false }
        if Date().timeIntervalSince1970 - d.double(forKey: "proactiveLastRun") < 50 * 60 { return false }
        let today = Store.dayKey(Date())
        if d.string(forKey: "proactiveDay") != today {
            d.set(today, forKey: "proactiveDay")
            d.set(0, forKey: "proactiveCount")
        }
        return d.integer(forKey: "proactiveCount") < 6
    }

    func consider(reason: String) async {
        guard !running, allowed() else { return }
        running = true
        defer { running = false }
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: "proactiveLastRun")
        do {
            let assistant = Assistant.shared
            var out: (String, String)?
            let str: [String: Any] = ["type": "string"]
            var tools = assistant.readTools(collect: { _ in }, question: nil)
            tools.append(AgentTool(name: "notify", description: "发一条通知给我。只有现在说确实有用时才用。",
                                   parameters: ["type": "object", "properties": ["title": str, "body": str], "required": ["title", "body"]]) { args in
                out = (String((args["title"] as? String ?? "").prefix(20)), String((args["body"] as? String ?? "").prefix(90)))
                return ToolResult(content: "已发出。", terminate: true)
            })
            tools.append(AgentTool(name: "stay_quiet", description: "现在没有值得提醒的事。",
                                   parameters: ["type": "object", "properties": [String: Any]()]) { _ in
                ToolResult(content: "好。", terminate: true)
            })
            let agent = Agent(systemPrompt: await assistant.systemPrompt(proactive: true), tools: tools, model: try Cloud.model())
            agent.maxTurns = 6
            let sent = ChatStore.shared.messages.filter { $0.proactive && Calendar.current.isDateInToday($0.time) }.map { "- \($0.text)" }
            let already = sent.isEmpty ? "今天还没有提醒过我。" : "今天已经提醒过：\n" + sent.joined(separator: "\n")
            try await agent.prompt("你被唤醒了（原因：\(reason)）。\(already)\n看看现在有没有值得提醒我的事。")
            if let (title, body) = out, !title.isEmpty {
                d.set(d.integer(forKey: "proactiveCount") + 1, forKey: "proactiveCount")
                _ = await Pusher.now(title: title, body: body)
                var message = ChatMessage(role: .assistant, text: body.isEmpty ? title : "**\(title)**\n\(body)")
                message.proactive = true
                ChatStore.shared.append(message)
            }
        } catch {
            // 主动检查失败不打扰你，下次再试
        }
    }
}
