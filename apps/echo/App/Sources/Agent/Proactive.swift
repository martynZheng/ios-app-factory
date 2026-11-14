import Foundation
import BackgroundTasks

/// 主动提醒：有新的情境进来时（新整理出一段、到了新地点、系统给了后台时间），
/// 让智能体自己看一眼有没有值得现在告诉你的事。值得才发通知，并在对话里留一条。
/// iOS 不允许 App 真正常驻后台，所以它是“被这些事件唤醒”的，不是每分钟都在跑。
@MainActor
final class Proactive {
    static let shared = Proactive()
    static let taskID = "com.deffisoan.echo.refresh"
    /// 夜里做梦用的长时后台任务（系统通常在充电、空闲时给）
    static let dreamTaskID = "com.deffisoan.echo.dream"
    private var running = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "proactiveEnabled") as? Bool ?? true
    }

    /// 必须在 App 启动完成前注册。
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                Proactive.scheduleRefresh()
                let work = Task { @MainActor in
                    await Proactive.shared.consider(reason: "系统给了后台时间")
                    await Proactive.shared.brief()
                }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: dreamTaskID, using: nil) { task in
            Task { @MainActor in
                Proactive.scheduleDream()
                let work = Task { @MainActor in
                    MemoryFS.shared.syncRaw()
                    await Dreaming.shared.dreamIfDue()
                }
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
        scheduleDream()
    }

    /// 约在夜里 2 点之后，要联网；不要求充电（系统自己会挑空闲的时候）。
    static func scheduleDream() {
        let request = BGProcessingTaskRequest(identifier: dreamTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        var next = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
        if next < Date() { next = next.addingTimeInterval(86_400) }
        request.earliestBeginDate = next
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
            tools.append(contentsOf: Connectors.shared.agentTools(readOnly: true))
            tools.append(AgentTool(name: "notify", description: "发一条通知给我。只有现在说确实有用时才用。",
                                   parameters: ["type": "object", "properties": ["title": str, "body": str], "required": ["title", "body"]]) { args in
                out = (String((args["title"] as? String ?? "").prefix(20)), String((args["body"] as? String ?? "").prefix(90)))
                return ToolResult(content: "已发出。", terminate: true)
            })
            tools.append(AgentTool(name: "stay_quiet", description: "现在没有值得提醒的事。",
                                   parameters: ["type": "object", "properties": [String: Any]()]) { _ in
                ToolResult(content: "好。", terminate: true)
            })
            let system = await assistant.systemPrompt(proactive: true)
            let sent = ChatStore.shared.messages.filter { $0.proactive && Calendar.current.isDateInToday($0.time) }.map { "- \($0.text)" }
            let already = sent.isEmpty ? "今天还没有提醒过我。" : "今天已经提醒过：\n" + sent.joined(separator: "\n")
            _ = try await Brain.run(system: system, tools: tools, thinking: false,
                                    prompt: "你被唤醒了（原因：\(reason)）。\(already)\n看看现在有没有值得提醒我的事。", maxTurns: 6)
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

    // MARK: 资讯流

    static var feedEnabled: Bool {
        UserDefaults.standard.object(forKey: "feedEnabled") as? Bool ?? true
    }

    /// 上午、傍晚各一档。这一档推过（或看过觉得没什么可推）就不再跑。
    private func feedSlot() -> String? {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 7, hour < 22 else { return nil }
        return Store.dayKey(Date()) + (hour < 14 ? "-am" : "-pm")
    }

    /// 按你的话题和最近的经历，联网找值得看的内容推给你。打开 App 或系统给后台时间时触发。
    func brief() async {
        let d = UserDefaults.standard
        guard Self.feedEnabled, Cloud.ready, Cloud.isDeepSeek, !Store.isDemo, !running, !Assistant.shared.busy else { return }
        guard let slot = feedSlot(), d.string(forKey: "feedSlot") != slot else { return }
        let topics = Assistant.feedTopics
        let aboutMe = (d.string(forKey: "aboutMe") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let knowsMe = !MemoryFS.shared.list("wiki").isEmpty || !MemoryFS.shared.list("notes").isEmpty
        guard !topics.isEmpty || knowsMe || !aboutMe.isEmpty else { return }
        running = true
        defer { running = false }
        d.set(slot, forKey: "feedSlot")
        do {
            let assistant = Assistant.shared
            var out: (String, String)?
            var sources: [WebSource] = []
            let str: [String: Any] = ["type": "string"]
            var tools = assistant.readTools(collect: { sources.append(contentsOf: $0) }, question: nil)
            tools.append(contentsOf: Connectors.shared.agentTools(readOnly: true))
            tools.append(AgentTool(name: "push", description: "把整理好的内容推给我。title 不超过 14 个字；body 是正文。",
                                   parameters: ["type": "object", "properties": ["title": str, "body": str], "required": ["title", "body"]]) { args in
                out = (String((args["title"] as? String ?? "").prefix(24)), String((args["body"] as? String ?? "").prefix(900)))
                return ToolResult(content: "已推送。", terminate: true)
            })
            tools.append(AgentTool(name: "skip", description: "这次没有值得推的内容。",
                                   parameters: ["type": "object", "properties": [String: Any]()]) { _ in
                ToolResult(content: "好。", terminate: true)
            })
            var system = await assistant.systemPrompt(proactive: false)
            system += """


            这一次不是我在问你，而是到了你给我推送内容的时间。
            根据我的资讯流话题（没设就根据你对我的了解和我最近在忙的事），联网搜索最近一两天的新消息，必要时打开网页核实，挑 2–4 条真正值得我看的。
            每条一两句话：发生了什么、为什么跟我有关；把来源用 Markdown 链接嵌在句子里。口语一点，像朋友发消息，不要标题党，不要凑数。
            写好后调用 push；实在没有新东西就调用 skip。不要重复之前推过的内容。这一轮不要调用 remember、suggest_replies。
            """

            let earlier = ChatStore.shared.messages.suffix(60).filter { $0.proactive }.suffix(4).map { "- " + String($0.text.prefix(160)) }
            let already = earlier.isEmpty ? "之前还没有推过。" : "最近推过：\n" + earlier.joined(separator: "\n")
            _ = try await Brain.run(system: system, tools: tools, thinking: false, prompt: "到推送时间了。\(already)", maxTurns: 8)
            if let (title, body) = out, !body.isEmpty {
                var message = ChatMessage(role: .assistant, text: title.isEmpty ? body : "**\(title)**\n\n\(body)")
                message.proactive = true
                var seen = Set<String>()
                message.sources = sources.filter { !body.contains($0.url) && seen.insert($0.url).inserted }.prefix(3).map { $0 }
                message.suggestions = ["展开讲讲第一条", "调整我的资讯流"]
                ChatStore.shared.append(message)
                let plain = Speaker.readable(body)
                _ = await Pusher.now(title: title.isEmpty ? BuddyProfile.shared.name : title, body: String(plain.prefix(80)))
            }
        } catch {
            // 这一档失败了就放开，下次打开再试
            d.removeObject(forKey: "feedSlot")
        }
    }
}
