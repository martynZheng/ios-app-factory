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
    // 下面几项是后来加的，必须是可选的，旧的对话记录才读得出来
    /// 回答后给的快捷选项（点一下就发出去）
    var suggestions: [String]?
    /// 附件在 DeepSeek Files API 的 file_id
    var fileID: String?
    /// 这句是用语音说的
    var spoken: Bool?
    /// 被你中途停下的回答
    var stopped: Bool?
    /// 它画的图
    var charts: [ChartSpec]?
}

/// 发给助理的文件。text 是本机能直接读出的文字；data 是原文件，交给 DeepSeek 解析。
struct Attachment {
    var name: String
    var text: String?
    var data: Data?
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
    /// 正在生成的回答（流式）
    @Published var streaming = ""
    private var job: Task<Void, Never>?

    static var deepThink: Bool { UserDefaults.standard.bool(forKey: "deepThink") }
    static var speakReplies: Bool { UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true }
    static var feedTopics: [String] { UserDefaults.standard.stringArray(forKey: "feedTopics") ?? [] }

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
        let name = BuddyProfile.shared.name
        parts.append("""
        你叫“\(name)”，是住在我 iPhone 和 Apple Watch 里的常驻助理（App 叫“拾言”）。我的手表会把我一天里身边的对话录下来转成文字，手机知道我去过哪、是在走路还是坐车、日程上有什么。
        你能用工具查这些，也能联网搜索、读网页、看图、读我发的文件，还能用我接入的连接器。凡是涉及“我今天/最近说过什么、答应过什么、在哪、接下来有什么”的问题，先用工具查，不要凭空回答；涉及最新消息、价格、事实的，先联网查。
        说话像一个靠谱又亲近的朋友在发微信：中文、口语，先给结论。每条消息一两句话，最多三四句；要说的多就分成 2–4 条，条与条之间单独一行写 ---（三个减号），不要一次倒一大段。只有我明确要“详细讲”“写一篇”“列清单”时才写长。不确定就说不确定；不要编造我没说过的话。少用标题和长列表。引用网上的信息时用 Markdown 链接把来源嵌在句子里。
        要查东西时，可以先用一句很短的话告诉我你去查什么（比如“我查一下”），然后在同一轮直接调用工具；说了要做的事（查、画图、记下来）就必须在这次回复里真的调用对应的工具做完，不要只说不做。
        写入提醒事项或日历必须用 propose_reminder / propose_event 提议，由我在界面上点确认，你不能替我确认。
        持续了解我：对话里出现值得长期记住的关于我的事（偏好、习惯、家人同事是谁、在忙的项目、在意的事、固定安排），不用我开口，直接用 remember 记下来，一条一件事；发现记错了或过时了用 forget 删掉。临时的事不要记。
        我说想看什么资讯、关心什么话题时，用 set_feed_topics 更新我的资讯流（传完整的新列表）。你会按它定时给我推送。
        我要图表、走势、对比图时，你能画：先把数据查全（联网搜索、读网页，或用我给的文件和数字），再调用 draw_chart，图会直接显示在回答里。量纲不同的两组数（比如股价和市净率）一组放左轴一组放右轴叠在一起。不要说自己画不了图，也不要让我自己去 Excel 里画。查不到完整数据就说清楚缺哪段、用了多少个点，绝不编数字；股票有拆股的用复权价并在 note 里注明。
        回答完如果有很自然的下一步，调用 suggest_replies 给我 2–3 个可以直接点的选项（每个不超过 12 个字，用我的口吻写，比如“帮我写进日历”）。没有就不用。
        """)
        parts.append("现在：\(clock.string(from: now))")
        let me = (d.string(forKey: "aboutMe") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { parts.append("关于我：\(me)") }
        let memory = ChatStore.shared.memory
        if !memory.isEmpty { parts.append("你记住的关于我的事：\n" + memory.map { "- \($0)" }.joined(separator: "\n")) }
        let topics = Self.feedTopics
        if !topics.isEmpty { parts.append("我的资讯流话题：" + topics.joined(separator: "、")) }
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
        case "forget": return "更新记忆…"
        case "set_feed_topics": return "调整资讯流…"
        case "suggest_replies": return "在整理回答…"
        case "draw_chart": return "画图…"
        case "schedule_notification": return "设定提醒…"
        case "propose_reminder", "propose_event": return "准备写入，等你确认…"
        default: return tool.hasPrefix("c") ? "调用连接器…" : "处理中…"
        }
    }

    // MARK: 对话

    func stop() {
        halted = true
        queue.removeAll()
        job?.cancel()
    }

    // MARK: 一条一条地“打”出来

    /// 等着显示的气泡（模型写得比人读得快，这里排队慢慢放）。
    private var queue: [String] = []
    /// 这次回复已经落下的气泡
    private var committed: [UUID] = []
    private var revealer: Task<Void, Never>?
    private var halted = false
    /// 当前这一轮已经排进队列的段数
    private var queuedInTurn = 0
    private var turnOpen = false

    /// 模型用单独一行的 --- 把回答分成几条消息。
    static func segments(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "***" || t == "———" || t == "——" {
                out.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        out.append(current.joined(separator: "\n"))
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 流式文字进来：已经写完的段（后面出现了分隔线）先排队；final 时把剩下的也排进去。
    private func absorb(_ text: String, final: Bool) {
        var parts = Self.segments(text)
        if !final { parts = Array(parts.dropLast()) }
        if parts.count > queuedInTurn {
            for part in parts[queuedInTurn...] where !part.isEmpty { queue.append(part) }
            queuedInTurn = parts.count
            reveal()
        }
    }

    private func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let message = ChatMessage(role: .assistant, text: t)
        ChatStore.shared.append(message)
        committed.append(message.id)
    }

    /// 先停一下（三个点），再像打字一样把一条消息放出来，然后落成气泡。
    private func reveal() {
        guard revealer == nil else { return }
        revealer = Task { @MainActor in
            while !self.queue.isEmpty {
                let text = self.queue.removeFirst()
                self.streaming = ""
                try? await Task.sleep(nanoseconds: self.committed.isEmpty ? 250_000_000 : 550_000_000)
                let chars = Array(text)
                let step = max(1, chars.count / 70)
                var shown = 0
                while shown < chars.count && !self.halted {
                    shown = min(chars.count, shown + step)
                    self.streaming = String(chars[0..<shown])
                    try? await Task.sleep(nanoseconds: 22_000_000)
                }
                self.streaming = ""
                self.commit(String(chars[0..<shown]))
                if self.halted { break }
            }
            self.revealer = nil
        }
    }

    private func drain() async {
        while revealer != nil { try? await Task.sleep(nanoseconds: 40_000_000) }
    }

    func send(text: String, imageJPEG: Data? = nil, attachment: Attachment? = nil, spoken: Bool = false) {
        let chat = ChatStore.shared
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty || imageJPEG != nil || attachment != nil else { return }
        var mine = ChatMessage(role: .user, text: trimmed)
        if let imageJPEG { mine.image = chat.saveImage(imageJPEG) }
        mine.attachment = attachment?.name
        if spoken { mine.spoken = true }
        let mineID = mine.id
        let history = Array(chat.messages.suffix(16))
        chat.append(mine)
        busy = true
        streaming = ""
        status = "在想…"
        queue = []
        committed = []
        halted = false
        queuedInTurn = 0
        turnOpen = false
        Speaker.shared.stop()

        job = Task { @MainActor in
            var proposals: [Proposal] = []
            var sources: [WebSource] = []
            var suggestions: [String] = []
            var charts: [ChartSpec] = []
            /// 这一轮模型在调用工具之前已经说了话
            var spokeThisTurn = false
            var problem: String?
            var stopped = false
            var outOfTurns = false
            do {
                let model = try Cloud.model(thinking: Self.deepThink)
                let str: [String: Any] = ["type": "string"]
                let strings: [String: Any] = ["type": "array", "items": str]
                func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] { ["type": "object", "properties": props, "required": required] }
                var tools = readTools(collect: { sources.append(contentsOf: $0) }, question: trimmed)
                tools.append(AgentTool(name: "remember", description: "记下一条关于我的长期信息（偏好、习惯、人物关系、在忙的事、固定安排）。不用等我说“记住”，你觉得以后用得上就记。以后每次对话你都能看到。",
                                       parameters: obj(["fact": str], ["fact"])) { args in
                    let fact = args["fact"] as? String ?? ""
                    await MainActor.run { chat.remember(fact) }
                    return ToolResult(content: "记住了。")
                })
                tools.append(AgentTool(name: "forget", description: "删掉一条记错了或过时的记忆。fact 要和记忆里的原文一致。",
                                       parameters: obj(["fact": str], ["fact"])) { args in
                    let fact = (args["fact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let found = await MainActor.run { () -> Bool in
                        guard chat.memory.contains(fact) else { return false }
                        chat.forget(fact)
                        return true
                    }
                    return ToolResult(content: found ? "删掉了。" : "记忆里没有这一条原文。", isError: !found)
                })
                tools.append(AgentTool(name: "set_feed_topics", description: "设置我的资讯流话题（完整的新列表，最多 8 个，每个是一个具体的话题或关键词）。传空列表表示不再推送。",
                                       parameters: obj(["topics": strings], ["topics"])) { args in
                    let list = (args["topics"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    UserDefaults.standard.set(Array(list.prefix(8)), forKey: "feedTopics")
                    return ToolResult(content: list.isEmpty ? "已清空，不再推送资讯。" : "已更新。每天上午和傍晚各看一次，有值得看的才推。")
                })
                tools.append(AgentTool(name: "suggest_replies", description: "在回答下面给我 2–3 个可以直接点的后续选项。每个不超过 12 个字，用我的口吻。先把回答写完，在同一轮的最后调用它。",
                                       parameters: obj(["options": strings], ["options"])) { args in
                    suggestions = (args["options"] as? [String] ?? []).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)) }.filter { !$0.isEmpty }
                    return ToolResult(content: "好，选项会显示在回答下面。如果还没写回答，现在直接写，不要在正文里重复这些选项。", terminate: spokeThisTurn)
                })
                let numbers: [String: Any] = ["type": "array", "items": ["type": "number"] as [String: Any]]
                let seriesItem: [String: Any] = obj(["name": str, "type": ["type": "string", "enum": ["line", "area", "bar"]] as [String: Any],
                                                     "axis": ["type": "string", "enum": ["left", "right"]] as [String: Any], "values": numbers], ["name", "values"])
                let seriesList: [String: Any] = ["type": "array", "items": seriesItem]
                tools.append(AgentTool(name: "draw_chart", description: "画一张图显示在回答里。x 是横轴标签（日期等，按时间从早到晚，2–400 个）；series 是 1–4 条数据，每条的 values 必须和 x 一样多，type 可选 line/area/bar，axis 为 right 的画在右轴（用于和左轴量纲不同的数据）。left_unit/right_unit 是单位，note 写数据来源和口径。数据必须是你查到或我给的真实数字。",
                                       parameters: obj(["title": str, "x": strings, "series": seriesList, "left_unit": str, "right_unit": str, "note": str], ["title", "x", "series"])) { args in
                    let (spec, problem) = ChartSpec.parse(args)
                    guard let spec else { return ToolResult(content: "没画成：\(problem)", isError: true) }
                    charts.append(spec)
                    return ToolResult(content: "图已经显示在回答里了。接着用一两句话说图里最值得注意的地方，不要再把数据列一遍。", terminate: spokeThisTurn)
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
                tools.append(contentsOf: Connectors.shared.agentTools(readOnly: false))

                // 附件：能交给 DeepSeek 解析的（PDF、Word、PPT、表格、电子书）上传后用 file_id 引用；否则用本机读出的文字
                var prompt = trimmed
                var fileIDs: [String] = []
                if let attachment {
                    let ext = (attachment.name as NSString).pathExtension
                    var uploaded = false
                    if Cloud.isDeepSeek, Cloud.parsesRemotely(ext), let data = attachment.data {
                        self.status = "解析文件…"
                        do {
                            let id = try await Cloud.uploadDocument(name: attachment.name, data: data)
                            fileIDs = [id]
                            uploaded = true
                            chat.update(mineID) { $0.fileID = id }
                        } catch {
                            if attachment.text == nil { throw error }
                        }
                    }
                    if !uploaded {
                        guard let local = attachment.text, !local.isEmpty else {
                            throw DigestError.unavailable("这个文件我读不出来。接上 DeepSeek 后可以解析 PDF、Word、PPT、表格。")
                        }
                        prompt += "\n\n【附件：\(attachment.name)】\n" + String(local.prefix(24_000))
                    }
                }
                if prompt.isEmpty { prompt = imageJPEG != nil ? "看看这张图片。" : (attachment != nil ? "看看这个文件，告诉我要点。" : "（空）") }

                var system = await systemPrompt(proactive: false)
                if spoken {
                    system += "\n\n我这句话是用语音说的（语音识别可能有错别字，按意思理解），你的回答会被朗读出来：像说话一样，两三句讲完，不用 Markdown、列表和链接。"
                }
                let agent = Agent(systemPrompt: system, tools: tools, model: model)
                agent.maxTurns = 14
                let recent = Date().addingTimeInterval(-20 * 86_400)
                let turns: [AgentMessage] = history.filter { !$0.failed }.map { m -> AgentMessage in
                    var t = m.text
                    if m.image != nil { t += "\n［当时附了一张图片］" }
                    for chart in m.charts ?? [] { t += "\n［这里显示了一张图：\(chart.title)］" }
                    if m.role == .user {
                        if let id = m.fileID, m.time > recent, Cloud.isDeepSeek {
                            return AgentMessage.userWithFiles(t.isEmpty ? "看看这个文件。" : t, [], [id])
                        }
                        if let a = m.attachment { t += "\n［当时附了文件：\(a)］" }
                        return AgentMessage.user(t.isEmpty ? "（空）" : t)
                    }
                    return AgentMessage.assistant(text: t, toolCalls: [], reasoning: nil)
                }
                // 它的一次回复可能是好几条气泡：合成一条再交给模型，避免连续两条 assistant 消息
                var merged: [AgentMessage] = []
                for turn in turns {
                    if case let .assistant(text, _, _) = turn, case let .assistant(previous, _, _)? = merged.last {
                        merged[merged.count - 1] = .assistant(text: (previous ?? "") + "\n---\n" + (text ?? ""), toolCalls: [], reasoning: nil)
                    } else {
                        merged.append(turn)
                    }
                }
                agent.seed(merged)
                agent.onPartial = { text in
                    guard self.turnOpen else { return }
                    self.status = nil
                    self.absorb(text, final: false)
                }
                agent.subscribe { event in
                    switch event {
                    case .turnStart:
                        self.turnOpen = true
                        self.queuedInTurn = 0
                        spokeThisTurn = false
                    case .messageEnd(let message):
                        if case let .assistant(text, _, _) = message {
                            self.turnOpen = false
                            let said = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            spokeThisTurn = !said.isEmpty
                            self.absorb(said, final: true)
                        }
                    case .toolExecutionStart(_, let name, _):
                        self.status = self.statusText(name)
                    default: break
                    }
                }
                let reason = try await agent.prompt(prompt, images: imageJPEG.map { [$0] } ?? [], fileIDs: fileIDs)
                outOfTurns = reason == "max_turns"
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                    stopped = true
                } else {
                    problem = error.localizedDescription
                }
            }
            // 等排队的气泡都放完，再把图、确认卡片、来源、快捷选项挂到最后一条上
            await self.drain()
            if outOfTurns { self.commit("这件事要查的步骤太多，我先停在这儿。你说一声“继续”，我接着查。") }
            if self.committed.isEmpty && problem == nil {
                if stopped {
                    self.commit("（已停下）")
                } else {
                    self.commit(!charts.isEmpty ? "图画好了。" : (proposals.isEmpty ? "我没想出该怎么回答，换个说法再问我一次。" : "准备好了，点下面确认。"))
                }
            }
            let said = self.committed.compactMap { id in chat.messages.first(where: { $0.id == id })?.text }.joined(separator: "\n")
            if let last = self.committed.last {
                var seen = Set<String>()
                let extra = sources.filter { !said.contains($0.url) && seen.insert($0.url).inserted }.prefix(4).map { $0 }
                chat.update(last) { m in
                    m.proposals = proposals
                    if !charts.isEmpty { m.charts = Array(charts.suffix(3)) }
                    if !suggestions.isEmpty && problem == nil && !stopped { m.suggestions = Array(suggestions.prefix(3)) }
                    m.sources = extra
                    if stopped { m.stopped = true }
                }
            }
            if let problem {
                var failure = ChatMessage(role: .assistant, text: problem)
                failure.failed = true
                chat.append(failure)
            }
            self.streaming = ""
            self.busy = false
            self.status = nil
            self.job = nil
            if spoken, Self.speakReplies, problem == nil, !stopped, !said.isEmpty {
                Speaker.shared.speak(said, id: self.committed.last)
            }
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
