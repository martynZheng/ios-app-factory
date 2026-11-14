import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum DigestError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let m): return m }
    }
}

/// 每日回顾的三种引擎：
/// - rules：纯规则，条目文字就是转写原句，零编造；默认。
/// - device：系统端侧大模型（Foundation Models，需 Apple 智能可用）。
/// - cloud：用户自行配置的云端模型（只上传当天转写文字，默认关闭）。
/// 大模型输出必须逐条给出来源句编号，校验不通过的条目直接丢弃；负责人/截止时间若不在来源原文里出现则清空并标「待确认」。
enum DigestEngine {
    static var engine: String { UserDefaults.standard.string(forKey: "digestEngine") ?? "rules" }

    /// 首次启动：端侧模型可用就默认用它。
    static func chooseDefaultEngine() {
        if UserDefaults.standard.string(forKey: "digestEngine") == nil {
            UserDefaults.standard.set(deviceModelAvailable() ? "device" : "rules", forKey: "digestEngine")
        }
    }

    static func engineName(_ e: String) -> String {
        switch e {
        case "device": return "端侧模型"
        case "cloud": return "云端智能体"
        default: return "规则提取"
        }
    }

    static func stats(lines: [Line], segments: [Segment]) -> String {
        let minutes = Int((segments.reduce(0) { $0 + $1.duration } / 60).rounded())
        let sessions = Set(segments.map { $0.sessionID }).count
        return "\(sessions) 次录音，约 \(minutes) 分钟，转写 \(lines.count) 句"
    }

    // MARK: 规则引擎

    private static let todoWords = ["记得", "别忘", "需要", "要去", "得去", "待办", "提醒我", "帮我", "安排", "跟进", "发给", "提交", "预约", "准备一下", "负责", "搞定", "处理一下", "todo", "to do"]
    private static let decisionWords = ["决定", "确定了", "定了", "就这么", "敲定", "结论是", "同意", "那就", "达成一致"]
    private static let pendingWords = ["待确认", "再确认", "确认一下", "不确定", "回头再", "再看看", "还没定", "再商量", "再讨论", "问一下", "可能要"]

    static func rules(day: String, lines: [Line], segments: [Segment]) -> Digest {
        var items: [DigestItem] = []
        for line in lines {
            let text = line.text
            let lower = text.lowercased()
            var kind: ItemKind?
            if pendingWords.contains(where: { lower.contains($0) }) { kind = .pending }
            else if decisionWords.contains(where: { lower.contains($0) }) { kind = .decision }
            else if todoWords.contains(where: { lower.contains($0) }) { kind = .todo }
            guard let kind, text.count >= 4 else { continue }
            let due = kind == .todo ? parseDue(text, base: line.time) : nil
            items.append(DigestItem(id: UUID(), kind: kind, text: text, owner: nil, due: due?.0, dueDate: due?.1,
                                    sourceLineIDs: [line.id], done: false, exported: false))
        }
        return Digest(day: day, stats: stats(lines: lines, segments: segments), items: items,
                      generatedAt: Date(), engine: "rules", lineCount: lines.count)
    }

    // MARK: 大模型引擎

    static func deviceModelAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static let instructions = """
    你在帮“我”整理随身录音的转写。录音来自手表，语音识别错误很多（同音字、断句错、漏字），而且分不清是谁在说话：
    可能是我在说，也可能是我在听别人演讲、汇报、路演、开会，或者只是周围的背景声音。
    请先判断这是什么场合，再按话题分章整理。原则是宁缺毋滥，看不懂的碎片一律忽略。
    每行转写前有方括号编号。只输出一个 JSON 对象：
    {"scene":"",
     "chapters":[{"title":"","speaker":null,"situation":"","summary":"","continues":false,"sources":[编号],"points":[{"text":"","sources":[编号]}]}],
     "decisions":[{"text":"","sources":[编号]}],
     "todos":[{"text":"","owner":null,"due":null,"sources":[编号]}],
     "pending":[{"text":"","sources":[编号]}]}
    要求：
    1. scene：一句话说明这是什么场合、我大概是什么角色（例如“AI 大赛决赛路演，我在主持并旁听”）。如果【背景】里我已经写明，以我写的为准；实在看不出就留空。
       如果给了【情境】（位置、身体状态、日程），先用它判断：乘车多半是路上，静止在会场+日程写着会议多半是在开会，深夜在家可能只是电视背景声。
    2. chapters：按时间顺序把【本段转写】分成 1–4 章，每章是一个完整话题。比赛、路演、分享会里，一位选手/讲者或一个项目算一章。
       title 不超过 14 个字，写具体内容（如“3 号选手：告警自闭环助手”），不要写“讨论”“内容”这类空话。
       speaker 填转写里出现的讲者称呼（如“2 号选手”“老张”），没有就 null。
       situation 用不超过 16 个字说我当时在做什么（如“在会场主持”“开车路上通话”）。情境变了（换地点、开始乘车）通常就是新的一章。
       summary 用 1–2 句通顺的话概括这一章讲了什么、结论是什么；可以修正明显的识别错字，但不得加入转写里没有的事实。
       points 最多 4 条，每条是一个具体的信息点（数字、做法、结论），不要重复 summary。
       sources 列出属于这一章的编号。
       如果第一章明显是【上一章】的继续，把它的 continues 设为 true，summary 写成整章到目前为止的概括。
    3. todos：只收明确需要“我”或在场某个具体的人会后去做的事。演讲者介绍他们的方案、系统会做什么、未来规划，都不是待办。
       owner、due 必须是转写里出现的原词，否则 null。
    4. decisions：只收明确说出“已经定下来”的事。pending：只收明确提出、没有结论、需要我后续确认的具体问题，最多 2 条。
       旁听别人演讲时，这三类通常是空的，留空数组即可。
    5. 每条 text 不少于 8 个字，能脱离上下文看懂；所有 sources 只能用【本段转写】里的编号。
    """

    static func respond(engine: String, prompt: String) async throws -> String {
        if engine == "device" { return try await deviceRespond(prompt) }
        return try await cloudRespond(prompt)
    }

    static func deviceRespond(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard deviceModelAvailable() else { throw DigestError.unavailable("这台设备上的端侧模型暂不可用（需要系统支持 Apple 智能并已下载模型）。") }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif
        throw DigestError.unavailable("端侧模型需要 iOS 26 及以上系统。")
    }

    /// 单次整理（不带工具），同样经 Pi 发出。
    @MainActor
    static func cloudRespond(_ prompt: String) async throws -> String {
        var last = ""
        _ = try await Brain.run(system: instructions, tools: [], thinking: false, prompt: prompt, maxTurns: 1, web: false) { event in
            if case let .assistant(text, _) = event, !text.isEmpty { last = text }
        }
        guard !last.isEmpty else { throw DigestError.unavailable("云端服务没有返回内容。") }
        return last
    }

    struct ParsedChapter {
        var title: String
        var speaker: String?
        var situation: String? = nil
        var summary: String
        var continues: Bool
        var lineIdx: [Int]
        var points: [DigestItem]
    }

    struct Block {
        var scene: String = ""
        var chapters: [ParsedChapter] = []
        var others: [DigestItem] = []
    }

    private static func ints(_ any: Any?, valid: Range<Int>) -> [Int] {
        let raw = (any as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
        var seen = Set<Int>()
        return raw.filter { valid.contains($0) && seen.insert($0).inserted }
    }

    private static func clean(_ any: Any?) -> String {
        let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.lowercased() == "null" ? "" : s
    }

    /// 解析并校验模型输出。没有有效来源的章节/条目丢弃；负责人、截止时间、讲者不在来源原文中出现则清空。
    static func parseBlock(_ raw: String, lines: [Line]) -> Block {
        var block = Block()
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return block }
        let valid = 0..<lines.count
        block.scene = String(clean(obj["scene"]).prefix(60))

        func item(_ entry: [String: Any], kind: ItemKind) -> DigestItem? {
            let text = clean(entry["text"])
            let src = ints(entry["sources"], valid: valid)
            guard text.count >= 6, !src.isEmpty else { return nil }
            let cited = src.map { lines[$0].text }.joined(separator: " ")
            var owner: String? = clean(entry["owner"])
            if owner == "" || !cited.contains(owner ?? "") { owner = nil }
            var due: String? = clean(entry["due"])
            if due == "" || !cited.contains(due ?? "") { due = nil }
            var dueDate: Date?
            if kind == .todo, let d = due { dueDate = parseDue(d, base: lines[src[0]].time)?.1 }
            return DigestItem(id: UUID(), kind: kind, text: text, owner: kind == .todo ? owner : nil,
                              due: kind == .todo ? due : nil, dueDate: dueDate,
                              sourceLineIDs: src.map { lines[$0].id }, done: false, exported: false)
        }

        for (i, entry) in (obj["chapters"] as? [[String: Any]] ?? []).enumerated() {
            let title = clean(entry["title"])
            let src = ints(entry["sources"], valid: valid)
            guard !title.isEmpty, !src.isEmpty else { continue }
            let all = lines.map { $0.text }.joined(separator: " ")
            var speaker: String? = clean(entry["speaker"])
            if speaker == "" || !all.contains(speaker ?? "") { speaker = nil }
            let points = (entry["points"] as? [[String: Any]] ?? []).compactMap { item($0, kind: .point) }.prefix(4)
            let situation = clean(entry["situation"])
            block.chapters.append(ParsedChapter(title: String(title.prefix(24)), speaker: speaker,
                                                situation: situation.isEmpty ? nil : String(situation.prefix(20)),
                                                summary: clean(entry["summary"]),
                                                continues: i == 0 && (entry["continues"] as? Bool ?? false),
                                                lineIdx: src, points: Array(points)))
        }
        let groups: [(String, ItemKind)] = [("decisions", .decision), ("todos", .todo), ("pending", .pending)]
        for (key, kind) in groups {
            for entry in obj[key] as? [[String: Any]] ?? [] {
                if let it = item(entry, kind: kind) { block.others.append(it) }
            }
        }
        return block
    }

    /// 规则引擎的分章：按 5 分钟以上的停顿切开，不生成任何概括。
    static func rulesBlock(lines: [Line]) -> Block {
        var block = Block()
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        var current: [Int] = []
        func flush() {
            guard let first = current.first else { return }
            block.chapters.append(ParsedChapter(title: "\(time.string(from: lines[first].time)) 的对话", speaker: nil,
                                                summary: "", continues: false, lineIdx: current, points: []))
            current = []
        }
        for i in lines.indices {
            if let last = current.last, lines[i].time.timeIntervalSince(lines[last].time) > 300 { flush() }
            current.append(i)
        }
        flush()
        block.others = rules(day: "", lines: lines, segments: []).items
        return block
    }

    // MARK: 截止时间

    private static let dueRegex = try? NSRegularExpression(
        pattern: "(大后天|后天|明天|明早|明晚|今天|今晚|下下周[一二三四五六日天]|下周[一二三四五六日天]|本周[一二三四五六日天]|这周[一二三四五六日天]|周[一二三四五六日天]|星期[一二三四五六日天]|礼拜[一二三四五六日天]|月底|下个月|\\d{1,2}月\\d{1,2}[日号])")

    /// 从一句话里找出时间说法。返回（原话, 能确定的日期）；说法模糊（如“月底”“下个月”）时日期为 nil。
    static func parseDue(_ text: String, base: Date) -> (String, Date?)? {
        guard let regex = dueRegex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let phrase = String(text[range])
        let cal = Calendar.current
        let today = cal.startOfDay(for: base)
        func plus(_ days: Int) -> Date? { cal.date(byAdding: .day, value: days, to: today) }
        func weekday(_ ch: Character) -> Int? {
            switch ch {
            case "一": return 2
            case "二": return 3
            case "三": return 4
            case "四": return 5
            case "五": return 6
            case "六": return 7
            case "日", "天": return 1
            default: return nil
            }
        }
        if phrase.hasPrefix("大后天") { return (phrase, plus(3)) }
        if phrase.hasPrefix("后天") { return (phrase, plus(2)) }
        if phrase.hasPrefix("明") { return (phrase, plus(1)) }
        if phrase.hasPrefix("今") { return (phrase, plus(0)) }
        if phrase.contains("月"), let m = phrase.firstIndex(of: "月"), phrase != "月底", phrase != "下个月" {
            let month = Int(phrase[..<m]) ?? 0
            let day = Int(phrase[phrase.index(after: m)...].dropLast()) ?? 0
            var comps = cal.dateComponents([.year], from: today)
            comps.month = month
            comps.day = day
            guard month >= 1, month <= 12, day >= 1, day <= 31 else { return (phrase, nil) }
            return (phrase, cal.date(from: comps))
        }
        if let last = phrase.last, let target = weekday(last) {
            let current = cal.component(.weekday, from: today)
            if phrase.hasPrefix("下下周") || phrase.hasPrefix("下周") {
                var toMonday = (9 - current) % 7
                if toMonday == 0 { toMonday = 7 }
                let offset = target == 1 ? 6 : target - 2
                return (phrase, plus(toMonday + offset + (phrase.hasPrefix("下下周") ? 7 : 0)))
            }
            return (phrase, plus((target - current + 7) % 7))
        }
        return (phrase, nil)
    }
}

/// 增量整理：新内容攒够一段就交给模型（云端时是带工具的智能体），按场景和话题分章，插进当天的时间线；
/// 已勾选/已写入的状态不会被覆盖。
final class DigestCoordinator: ObservableObject {
    static let shared = DigestCoordinator()

    @Published var working = false
    @Published var lastError: String?
    /// 智能体此刻在做什么（显示在今日回顾的状态行）
    @Published var agentStatus: String?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .transcriptChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateRecent()
        }
        updateRecent()
    }

    func updateRecent() {
        let today = Date()
        update(day: Store.dayKey(today))
        update(day: Store.dayKey(today.addingTimeInterval(-86_400)))
    }

    private func fresh(day: String) -> [Line] {
        let lines = Store.shared.lines(on: day)
        guard let digest = Store.shared.db.digests[day] else { return lines }
        let done = Set(digest.processed ?? lines.map { $0.id })
        return lines.filter { !done.contains($0.id) }
    }

    func unprocessedCount(day: String) -> Int { fresh(day: day).count }

    /// 新内容要攒够一段再交给模型：碎片逐句整理只会得到碎片。
    func readyToProcess(_ fresh: [Line]) -> Bool {
        guard let last = fresh.last else { return false }
        let chars = fresh.reduce(0) { $0 + $1.text.count }
        return chars >= 1200 || Date().timeIntervalSince(last.time) > 300
    }

    private func context(day: String) -> String {
        let store = Store.shared
        var parts: [String] = []
        let me = (UserDefaults.standard.string(forKey: "aboutMe") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { parts.append("【关于我】\(me)") }
        let bg = (store.db.dayContext?[day] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !bg.isEmpty { parts.append("【背景（我自己写的，以此为准）】\(bg)") }
        if let digest = store.db.digests[day] {
            if let scene = digest.scene, !scene.isEmpty { parts.append("【之前判断的场合】\(scene)") }
            if let last = digest.chapters?.last { parts.append("【上一章】标题：\(last.title)；概括：\(last.summary)") }
            let done = Set(digest.processed ?? [])
            let tail = store.lines(on: day).filter { done.contains($0.id) }.suffix(6).map { $0.text }.joined(separator: "\n")
            if !tail.isEmpty { parts.append("【上文最后几句，仅供理解，不要从中提取】\n\(tail)") }
        }
        return parts.joined(separator: "\n")
    }

    /// 把一段的整理结果并入当天回顾。
    /// 章节始终按开始时间排序；同一段里各章的时间范围首尾相接、不重叠；
    /// 晚到的、时间落在已有章节里的内容并入那一章，而不是排到最后（以前“10 点 → 11 点 → 又回到 10 点”就是这么来的）。
    func merge(_ block: DigestEngine.Block, chunk: [Line], day: String, engine: String) {
        let store = Store.shared
        let lines = store.lines(on: day)
        var digest = store.db.digests[day] ?? Digest(day: day, stats: "", items: [], generatedAt: Date(), engine: engine, lineCount: 0)
        var chapters = (digest.chapters ?? []).sorted { $0.start < $1.start }
        let parsedList = block.chapters.sorted { ($0.lineIdx.min() ?? 0) < ($1.lineIdx.min() ?? 0) }
        let chunkStart = chunk.first?.time ?? Date()

        for (k, parsed) in parsedList.enumerated() {
            guard let lo = parsed.lineIdx.min(), let hi = parsed.lineIdx.max() else { continue }
            let nextLo = k + 1 < parsedList.count ? (parsedList[k + 1].lineIdx.min() ?? chunk.count) : chunk.count
            let upper = max(lo, min(hi, nextLo - 1))
            let own = parsed.lineIdx.filter { $0 <= upper }.map { chunk[$0] }
            let start = chunk[lo].time, end = chunk[upper].time

            // 1) 明说是上一章的继续：并入开始时间在这段之前的最后一章
            var target: Int?
            if parsed.continues, k == 0, let i = chapters.lastIndex(where: { $0.start <= chunkStart }) { target = i }
            // 2) 晚到的内容：时间落在已有章节范围内
            if target == nil, let i = chapters.firstIndex(where: { start >= $0.start && start <= $0.end.addingTimeInterval(60) && end <= $0.end.addingTimeInterval(120) }) {
                target = i
            }
            let chapterID: UUID
            if let i = target {
                chapters[i].start = min(chapters[i].start, start)
                chapters[i].end = max(chapters[i].end, end)
                chapters[i].sourceLineIDs += own.map { $0.id }
                if parsed.continues, !parsed.summary.isEmpty { chapters[i].summary = parsed.summary }
                if chapters[i].situation == nil { chapters[i].situation = parsed.situation }
                chapterID = chapters[i].id
            } else {
                var chapter = Chapter(id: UUID(), title: parsed.title, summary: parsed.summary, speaker: parsed.speaker,
                                      start: start, end: end, sourceLineIDs: own.map { $0.id })
                chapter.situation = parsed.situation
                chapters.append(chapter)
                chapterID = chapter.id
            }
            chapters.sort { $0.start < $1.start }
            for var point in parsed.points {
                point.chapterID = chapterID
                digest.items.append(point)
            }
        }
        for var other in block.others {
            if let first = other.sourceLineIDs.first, let time = chunk.first(where: { $0.id == first })?.time {
                other.chapterID = chapters.last(where: { $0.start <= time.addingTimeInterval(1) })?.id ?? chapters.first?.id
            }
            digest.items.append(other)
        }
        if !block.scene.isEmpty { digest.scene = block.scene }
        digest.chapters = chapters
        digest.processed = (digest.processed ?? []) + chunk.map { $0.id }
        digest.stats = DigestEngine.stats(lines: lines, segments: store.segments(on: day))
        digest.engine = engine
        digest.generatedAt = Date()
        digest.lineCount = lines.count
        store.setDigest(digest)
        fillSettings(day: day)
    }

    /// 旧版本把开车路过的地方也当成“在那里”，写进了章节的情境标签。升级后把最近 14 天的重算一遍（只做一次）。
    func refreshSettingsOnce() {
        let d = UserDefaults.standard
        guard !Store.isDemo, !d.bool(forKey: "settingsV2") else { return }
        d.set(true, forKey: "settingsV2")
        for i in 0..<14 {
            fillSettings(day: Store.dayKey(Date().addingTimeInterval(-Double(i) * 86_400)), all: true)
        }
    }

    /// 给还没有情境标签的章节补上“地点 · 状态”（来自传感器，不是模型）。all = 全部重算。
    func fillSettings(day: String, all: Bool = false) {
        Task { @MainActor in
            guard let chapters = Store.shared.db.digests[day]?.chapters else { return }
            var labels: [UUID: String] = [:]
            for c in chapters where c.setting == nil || all {
                if let label = await ContextSensor.shared.setting(from: c.start, to: c.end) { labels[c.id] = label }
            }
            guard !labels.isEmpty || all, var digest = Store.shared.db.digests[day] else { return }
            for i in (digest.chapters ?? []).indices {
                if let label = labels[digest.chapters![i].id] {
                    digest.chapters![i].setting = label
                } else if all {
                    digest.chapters![i].setting = nil
                }
            }
            Store.shared.setDigest(digest)
        }
    }

    private func takeChunk(_ remaining: inout [Line], limit: Int, cuts: [Date] = []) -> [Line] {
        var chunk: [Line] = []
        var chars = 0
        while let next = remaining.first, chunk.isEmpty || chars + next.text.count <= limit {
            // 情境切换（换了地点、开始乘车）处切开，前后各自成段；太短的段不切
            if chunk.count >= 4, let prev = chunk.last,
               cuts.contains(where: { $0 > prev.time && $0 <= next.time }), remaining.count >= 4 { break }
            chunk.append(next)
            chars += next.text.count
            remaining.removeFirst()
        }
        return chunk
    }

    /// full = 丢弃当天已有回顾，整天重新整理；force = 不等攒够，现在就整理新增内容。
    func update(day: String, full: Bool = false, force: Bool = false) {
        let store = Store.shared
        guard !Store.isDemo, !working, !store.lines(on: day).isEmpty else { return }
        let engine = DigestEngine.engine
        if full {
            store.mutate { db in db.digests[day] = nil }
        } else if let digest = store.db.digests[day], digest.processed == nil {
            // 老版本的回顾：标记为全部处理过，避免重复
            var d = digest
            d.processed = store.lines(on: day).map { $0.id }
            store.setDigest(d)
        }
        var remaining = fresh(day: day)
        guard !remaining.isEmpty else { return }

        if engine == "rules" {
            merge(DigestEngine.rulesBlock(lines: remaining), chunk: remaining, day: day, engine: engine)
            Notifier.apply()
            return
        }
        if !full && !force && !readyToProcess(remaining) { return }
        // 更早的录音还在转写：先等它们，否则晚到的内容会排乱时间线（超过 20 分钟还没转完就不等了）
        if !full && !force, let lastFresh = remaining.last?.time,
           store.segments(on: day).contains(where: { $0.status == .pending && $0.start < lastFresh && Date().timeIntervalSince($0.start) < 20 * 60 }) {
            return
        }

        working = true
        lastError = nil
        let limit = engine == "device" ? 1400 : 6000
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let queued = remaining
        Task { @MainActor in
            var remaining = queued
            let sensor = ContextSensor.shared
            let cuts = await sensor.changes(from: queued.first?.time ?? Date(), to: queued.last?.time ?? Date())
            while !remaining.isEmpty {
                let chunk = self.takeChunk(&remaining, limit: limit, cuts: cuts)
                let ctx = self.context(day: day)
                do {
                    let block: DigestEngine.Block
                    if engine == "cloud" {
                        block = try await DigestAgent.run(chunk: chunk, day: day, contextNote: ctx) { text in
                            self.agentStatus = text
                        }
                    } else {
                        let rows = chunk.enumerated().map { "[\($0.offset)] \(time.string(from: $0.element.time)) \($0.element.text)" }.joined(separator: "\n")
                        let situation = await sensor.describe(from: chunk.first!.time.addingTimeInterval(-300), to: chunk.last!.time.addingTimeInterval(60))
                        let prompt = (ctx.isEmpty ? "" : ctx + "\n\n") + (situation.isEmpty ? "" : "【情境】\n\(situation)\n\n") + "【本段转写】\n" + rows
                        let raw = try await DigestEngine.respond(engine: engine, prompt: prompt)
                        block = DigestEngine.parseBlock(raw, lines: chunk)
                    }
                    self.merge(block, chunk: chunk, day: day, engine: engine)
                } catch {
                    self.lastError = error.localizedDescription
                    break
                }
            }
            self.agentStatus = nil
            self.working = false
            Notifier.apply()
            if self.lastError == nil { await Proactive.shared.consider(reason: "刚整理出新的一段对话") }
        }
    }
}
