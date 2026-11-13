import Foundation
import EventKit
import UserNotifications

// MARK: - 对话记录

/// 需要你点头才会执行的动作（写提醒事项、写日历）。
struct Proposal: Codable, Equatable {
    enum Kind: String, Codable { case reminder, event }
    var kind: Kind
    var title: String
    var notes: String?
    var start: Date?
    var end: Date?
    var location: String?
    var done = false
    var result: String?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var time = Date()
    /// 附图的文件名（存在 Chat 目录里）
    var image: String?
    var attachment: String?
    var proposals: [Proposal] = []
    var sources: [WebSource] = []
    /// 智能体主动发来的
    var proactive = false
    var failed = false
}

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published private(set) var messages: [ChatMessage] = []
    /// 你让它记住的事
    @Published private(set) var memory: [String] = []
    let dir: URL
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        dir = base.appendingPathComponent("Chat", isDirectory: true)
        fileURL = dir.appendingPathComponent("chat.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !Store.isDemo, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved
        }
        memory = UserDefaults.standard.stringArray(forKey: "agentMemory") ?? []
    }

    private func save() {
        guard !Store.isDemo else { return }
        if messages.count > 600 { messages.removeFirst(messages.count - 600) }
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func append(_ message: ChatMessage) {
        messages.append(message)
        save()
    }

    func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
        save()
    }

    func remove(_ id: UUID) {
        messages.removeAll { $0.id == id }
        save()
    }

    func clear() {
        messages = []
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func saveImage(_ data: Data) -> String {
        let name = UUID().uuidString + ".jpg"
        try? data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }

    func remember(_ fact: String) {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !memory.contains(text) else { return }
        memory.append(text)
        if memory.count > 80 { memory.removeFirst(memory.count - 80) }
        UserDefaults.standard.set(memory, forKey: "agentMemory")
    }

    func forget(_ fact: String) {
        memory.removeAll { $0 == fact }
        UserDefaults.standard.set(memory, forKey: "agentMemory")
    }

    func forgetAll() {
        memory = []
        UserDefaults.standard.removeObject(forKey: "agentMemory")
    }

    func seedDemo(_ list: [ChatMessage]) { messages = list }
}

// MARK: - 常驻助手

/// 对话页背后的智能体：同一套 Pi 式循环，工具更多——
/// 读你的情境和记录、联网搜索和读网页、看图、记住事情、定时提醒、提议写入提醒事项/日历，以及你接入的连接器。
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()
    @Published var busy = false
    @Published var status: String?

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        return f
    }()
    nonisolated func parseTime(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let full = DateFormatter()
        full.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = full.date(from: s) { return d }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: s)
    }

    func systemPrompt(proactive: Bool) async -> String {
        let d = UserDefaults.standard
        let now = Date()
        let sensor = ContextSensor.shared
        let here = await sensor.describe(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60))
        let today = Store.shared.db.digests[Store.dayKey(now)]
        var parts: [String] = []
        parts.append("""
        你是“拾言”，住在我 iPhone 和 Apple Watch 里的个人助理。我的手表会把我一天里身边的对话录下来转成文字，手机知道我去过哪、是在走路还是坐车、日程上有什么。
        你能用工具查这些，也能联网。回答我之前，凡是涉及“我今天/最近说过什么、答应过什么、在哪、接下来有什么”的问题，先用工具查，不要凭空回答。
        说话像一个靠谱的朋友：中文、简短、直接给结论；不确定就说不确定；不要编造我没说过的话。引用网上的信息时在句末用 Markdown 链接标出来源。
        写入提醒事项或日历必须用 propose_reminder / propose_event 提议，由我在界面上点确认，你不能替我确认。
        我让你记住的长期信息用 remember 存下来。
        """)
        parts.append("现在：\(clock.string(from: now))")
        let me = (d.string(forKey: "aboutMe") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { parts.append("关于我：\(me)") }
        let memory = ChatStore.shared.memory
        if !memory.isEmpty { parts.append("我让你记住的事：\n" + memory.map { "- \($0)" }.joined(separator: "\n")) }
        if !here.isEmpty { parts.append("最近一小时的情境：\n\(here)") }
        if let scene = today?.scene, !scene.isEmpty { parts.append("今天的场合：\(scene)") }
        if proactive {
            parts.append("""
            这一次不是我在问你，而是你自己醒来看看有没有值得提醒我的事。标准很高：只有现在告诉我确实有用、晚了就没用的事才提醒
            （比如：马上要开的会和我之前说过的相关准备、今天答应别人还没做的事快到点了、刚才对话里新出现的需要我跟进的事、到了某个地方正好能办的事）。
            先用工具看情境、今天的经过、待办和日程。值得提醒就调用 notify（标题不超过 14 个字，正文不超过 50 个字，说清楚是什么事、为什么是现在）；
            不值得就调用 stay_quiet。宁可不说，不要为了提醒而提醒，也不要重复今天已经提醒过的事。
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// 读类工具：对话和主动检查都能用。
    func readTools(collect: @escaping ([WebSource]) -> Void, question: String?) -> [AgentTool] {
        let store = Store.shared
        let sensor = ContextSensor.shared
        let str: [String: Any] = ["type": "string"]
        func obj(_ props: [String: Any], _ required: [String] = []) -> [String: Any] { ["type": "object", "properties": props, "required": required] }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"

        var tools: [AgentTool] = [
            AgentTool(name: "get_context", description: "查某段时间我的情境：位置、身体状态（静止/步行/乘车）、日程。时间格式 yyyy-MM-dd HH:mm。",
                      parameters: obj(["from": str, "to": str], ["from", "to"])) { args in
                let from = self.parseTime(args["from"]) ?? Date().addingTimeInterval(-3 * 3600)
                let to = self.parseTime(args["to"]) ?? Date()
                let text = await sensor.describe(from: from, to: max(to, from.addingTimeInterval(60)))
                return ToolResult(content: text.isEmpty ? "这段时间没有情境数据（可能没开定位/运动/日历）。" : text)
            },
            AgentTool(name: "get_day", description: "某一天整理好的经过：场合、各章节（时间、标题、情境、概括、要点）、决定、待办、待确认。day 格式 yyyy-MM-dd，不填是今天。",
                      parameters: obj(["day": str])) { args in
                let day = (args["day"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Store.dayKey(Date())
                guard let digest = store.db.digests[day] else {
                    let n = store.lines(on: day).count
                    return ToolResult(content: n == 0 ? "\(day) 没有录音记录。" : "\(day) 有 \(n) 句转写，还没整理。可以用 get_transcript 直接看原话。")
                }
                var rows: [String] = []
                if let scene = digest.scene, !scene.isEmpty { rows.append("场合：\(scene)") }
                for c in (digest.chapters ?? []).sorted(by: { $0.start < $1.start }) {
                    var row = "\(hm.string(from: c.start))–\(hm.string(from: c.end)) \(c.title)"
                    let ctx = [c.situation, c.setting].compactMap { $0 }.joined(separator: " · ")
                    if !ctx.isEmpty { row += "［\(ctx)］" }
                    rows.append(row + "：\(c.summary)")
                    for p in digest.items where p.kind == .point && p.chapterID == c.id { rows.append("  · \(p.text)") }
                }
                for item in digest.items where item.kind != .point {
                    let label = item.kind == .todo ? (item.done ? "待办(已完成)" : "待办") : (item.kind == .decision ? "决定" : "待确认")
                    var row = "\(label)：\(item.text)"
                    if let o = item.owner { row += "（\(o)）" }
                    if let due = item.due { row += "（\(due)）" }
                    rows.append(row)
                }
                return ToolResult(content: rows.isEmpty ? "这一天没有整理出内容。" : rows.joined(separator: "\n"))
            },
            AgentTool(name: "get_transcript", description: "看某段时间的转写原话（最多 80 句）。时间格式 yyyy-MM-dd HH:mm。",
                      parameters: obj(["from": str, "to": str], ["from", "to"])) { args in
                guard let from = self.parseTime(args["from"]), let to = self.parseTime(args["to"]) else {
                    return ToolResult(content: "时间格式应为 yyyy-MM-dd HH:mm。", isError: true)
                }
                let lines = store.sortedLines.filter { $0.time >= from && $0.time <= to }.prefix(80)
                return ToolResult(content: lines.isEmpty ? "这段时间没有转写。" : lines.map { "\(hm.string(from: $0.time)) \($0.text)" }.joined(separator: "\n"))
            },
            AgentTool(name: "search_memory", description: "在我所有的录音转写和整理里按关键词查找（人名、项目、地点、事情），返回带日期的原话或章节。",
                      parameters: obj(["query": str], ["query"])) { args in
                let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { return ToolResult(content: "关键词太短。", isError: true) }
                let md = DateFormatter()
                md.dateFormat = "M月d日 HH:mm"
                var rows: [String] = []
                for (_, digest) in store.db.digests {
                    for c in digest.chapters ?? [] where c.title.localizedCaseInsensitiveContains(q) || c.summary.localizedCaseInsensitiveContains(q) {
                        rows.append("\(md.string(from: c.start)) 章节「\(c.title)」：\(c.summary)")
                    }
                }
                for line in store.sortedLines.reversed() where line.text.localizedCaseInsensitiveContains(q) {
                    rows.append("\(md.string(from: line.time)) \(line.text)")
                    if rows.count >= 20 { break }
                }
                return ToolResult(content: rows.isEmpty ? "没有找到「\(q)」。" : rows.prefix(20).joined(separator: "\n"))
            },
            AgentTool(name: "list_todos", description: "我所有未完成的待办（来自录音整理），带日期、负责人、截止。",
                      parameters: obj([:])) { _ in
                var rows: [String] = []
                for day in store.db.digests.keys.sorted(by: >) {
                    for item in store.db.digests[day]?.items ?? [] where item.kind == .todo && !item.done {
                        var row = "\(day)：\(item.text)"
                        if let o = item.owner { row += "（\(o)）" }
                        if let due = item.due { row += "（截止 \(due)）" }
                        rows.append(row)
                    }
                }
                return ToolResult(content: rows.isEmpty ? "没有未完成的待办。" : rows.prefix(40).joined(separator: "\n"))
            },
            AgentTool(name: "get_calendar", description: "看我的日程（需要我在设置里开启“读取日程”）。时间格式 yyyy-MM-dd HH:mm。",
                      parameters: obj(["from": str, "to": str], ["from", "to"])) { args in
                let from = self.parseTime(args["from"]) ?? Date()
                let to = self.parseTime(args["to"]) ?? from.addingTimeInterval(86_400)
                guard ContextSensor.calendarOn || Store.isDemo else { return ToolResult(content: "我还没开启“读取日程”（设置 › 情境感知）。") }
                let events = sensor.calendar(from: from, to: to)
                let md = DateFormatter()
                md.dateFormat = "M月d日 HH:mm"
                var rows: [String] = []
                for e in events {
                    var row = "\(md.string(from: e.0))–\(hm.string(from: e.1)) \(e.2)"
                    if let loc = e.3, !loc.isEmpty { row += "（\(loc)）" }
                    rows.append(row)
                }
                return ToolResult(content: rows.isEmpty ? "这段时间没有日程。" : rows.joined(separator: "\n"))
            },
        ]
        if Cloud.isDeepSeek {
            tools.append(AgentTool(name: "web_search", description: "联网搜索最新信息。query 是搜索词（不超过 128 字）。",
                                   parameters: obj(["query": str], ["query"])) { args in
                let (text, sources) = try await Cloud.search(args["query"] as? String ?? "", question: question)
                collect(sources)
                return ToolResult(content: text)
            })
            tools.append(AgentTool(name: "web_fetch", description: "读取一个网页的正文（Markdown）。",
                                   parameters: obj(["url": str], ["url"])) { args in
                ToolResult(content: try await Cloud.fetch(args["url"] as? String ?? ""))
            })
        }
        return tools
    }

    nonisolated private func statusText(_ tool: String) -> String {
        switch tool {
        case "get_context": return "查看你的位置和状态…"
        case "get_day": return "回看这一天的经过…"
        case "get_transcript": return "翻原话…"
        case "search_memory": return "在以前的记录里找…"
        case "list_todos": return "看待办…"
        case "get_calendar": return "看日程…"
        case "web_search": return "联网搜索…"
        case "web_fetch": return "读网页…"
        case "remember": return "记下来…"
        case "schedule_notification": return "设定提醒…"
        case "propose_reminder", "propose_event": return "准备写入，等你确认…"
        default: return tool.hasPrefix("c") ? "调用连接器…" : "处理中…"
        }
    }

    // MARK: 对话

    func send(text: String, imageJPEG: Data? = nil, attachment: (name: String, text: String)? = nil) {
        let chat = ChatStore.shared
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty || imageJPEG != nil || attachment != nil else { return }
        var mine = ChatMessage(role: .user, text: trimmed)
        if let imageJPEG { mine.image = chat.saveImage(imageJPEG) }
        mine.attachment = attachment?.name
        let history = Array(chat.messages.suffix(16))
        chat.append(mine)
        busy = true
        status = "在想…"

        Task { @MainActor in
            var proposals: [Proposal] = []
            var sources: [WebSource] = []
            var reply = ChatMessage(role: .assistant, text: "")
            do {
                let model = try Cloud.model()
                let str: [String: Any] = ["type": "string"]
                func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] { ["type": "object", "properties": props, "required": required] }
                var tools = readTools(collect: { sources.append(contentsOf: $0) }, question: trimmed)
                tools.append(AgentTool(name: "remember", description: "把一条关于我的长期信息记下来（偏好、人物关系、固定安排）。以后每次对话你都能看到。",
                                       parameters: obj(["fact": str], ["fact"])) { args in
                    let fact = args["fact"] as? String ?? ""
                    await MainActor.run { chat.remember(fact) }
                    return ToolResult(content: "记住了。")
                })
                tools.append(AgentTool(name: "schedule_notification", description: "在指定时间给我发一条手机通知。time 格式 yyyy-MM-dd HH:mm，必须是将来。",
                                       parameters: obj(["time": str, "title": str, "body": str], ["time", "title"])) { args in
                    guard let when = self.parseTime(args["time"]), when > Date() else { return ToolResult(content: "时间无效或已经过去。", isError: true) }
                    let ok = await Pusher.schedule(at: when, title: args["title"] as? String ?? "提醒", body: args["body"] as? String ?? "")
                    return ToolResult(content: ok ? "已设定，到时间会提醒。" : "没有通知权限，我需要到系统设置里允许拾言发通知。", isError: !ok)
                })
                tools.append(AgentTool(name: "propose_reminder", description: "提议写一条提醒事项，由我点确认后才写入。due 可选，格式 yyyy-MM-dd HH:mm。",
                                       parameters: obj(["title": str, "due": str, "notes": str], ["title"])) { args in
                    proposals.append(Proposal(kind: .reminder, title: args["title"] as? String ?? "", notes: args["notes"] as? String,
                                              start: self.parseTime(args["due"])))
                    return ToolResult(content: "已放到界面上等我确认。告诉我点一下确认就行，不要说已经写入。")
                })
                tools.append(AgentTool(name: "propose_event", description: "提议写一个日历日程，由我点确认后才写入。start/end 格式 yyyy-MM-dd HH:mm。",
                                       parameters: obj(["title": str, "start": str, "end": str, "location": str, "notes": str], ["title", "start"])) { args in
                    guard let start = self.parseTime(args["start"]) else { return ToolResult(content: "start 时间格式应为 yyyy-MM-dd HH:mm。", isError: true) }
                    let end = self.parseTime(args["end"]) ?? start.addingTimeInterval(3600)
                    proposals.append(Proposal(kind: .event, title: args["title"] as? String ?? "", notes: args["notes"] as? String,
                                              start: start, end: max(end, start), location: args["location"] as? String))
                    return ToolResult(content: "已放到界面上等我确认。告诉我点一下确认就行，不要说已经写入。")
                })
                tools.append(contentsOf: Connectors.shared.agentTools())

                let agent = Agent(systemPrompt: await systemPrompt(proactive: false), tools: tools, model: model)
                agent.maxTurns = 10
                agent.seed(history.map { m -> AgentMessage in
                    var t = m.text
                    if m.image != nil { t += "\n［当时附了一张图片］" }
                    if let a = m.attachment { t += "\n［当时附了文件：\(a)］" }
                    return m.role == .user ? AgentMessage.user(t) : AgentMessage.assistant(text: t, toolCalls: [])
                })
                agent.subscribe { event in
                    switch event {
                    case .toolExecutionStart(_, let name, _): self.status = self.statusText(name)
                    case .turnStart(let n): if n > 1 { self.status = "在整理回答…" }
                    default: break
                    }
                }
                var prompt = trimmed
                if let attachment {
                    prompt += "\n\n【附件：\(attachment.name)】\n" + String(attachment.text.prefix(24_000))
                }
                if prompt.isEmpty { prompt = imageJPEG != nil ? "看看这张图片。" : "（空）" }
                try await agent.prompt(prompt, images: imageJPEG.map { [$0] } ?? [])
                reply.text = agent.lastText ?? (proposals.isEmpty ? "我没想出该怎么回答，换个说法再问我一次。" : "准备好了，点下面确认。")
            } catch {
                reply.text = error.localizedDescription
                reply.failed = true
            }
            reply.proposals = proposals
            var seen = Set<String>()
            reply.sources = sources.filter { reply.text.contains($0.url) == false && seen.insert($0.url).inserted }.prefix(4).map { $0 }
            chat.append(reply)
            self.busy = false
            self.status = nil
        }
    }

    /// 你点了确认：真正写入系统。
    func confirm(message: UUID, index: Int) {
        let chat = ChatStore.shared
        guard let m = chat.messages.first(where: { $0.id == message }), m.proposals.indices.contains(index) else { return }
        let p = m.proposals[index]
        Task { @MainActor in
            let result = await Self.write(p)
            chat.update(message) { $0.proposals[index].done = result.hasPrefix("已"); $0.proposals[index].result = result }
        }
    }

    private static let events = EKEventStore()

    private static func write(_ p: Proposal) async -> String {
        do {
            switch p.kind {
            case .reminder:
                guard try await events.requestFullAccessToReminders() else { return "没有提醒事项权限" }
                guard let calendar = events.defaultCalendarForNewReminders() else { return "没有可用的提醒事项列表" }
                let r = EKReminder(eventStore: events)
                r.title = p.title
                r.notes = p.notes
                r.calendar = calendar
                if let due = p.start {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                    r.addAlarm(EKAlarm(absoluteDate: due))
                }
                try events.save(r, commit: true)
                return "已写入提醒事项"
            case .event:
                guard let start = p.start else { return "缺少开始时间" }
                guard try await events.requestWriteOnlyAccessToEvents() else { return "没有日历权限" }
                guard let calendar = events.defaultCalendarForNewEvents else { return "没有可用的日历" }
                let e = EKEvent(eventStore: events)
                e.title = p.title
                e.notes = p.notes
                e.location = p.location
                e.startDate = start
                e.endDate = p.end ?? start.addingTimeInterval(3600)
                e.calendar = calendar
                try events.save(e, span: .thisEvent, commit: true)
                return "已写入日历"
            }
        } catch {
            return "写入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 通知

enum Pusher {
    static func authorized() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func schedule(at date: Date, title: String, body: String) async -> Bool {
        guard await authorized() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: "agent-" + UUID().uuidString, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        return (try? await UNUserNotificationCenter.current().add(request)) != nil
    }

    static func now(title: String, body: String) async -> Bool {
        guard await authorized() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "agent-" + UUID().uuidString, content: content, trigger: nil)
        return (try? await UNUserNotificationCenter.current().add(request)) != nil
    }
}
