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
        case "cloud": return "云端模型"
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

    private static let instructions = """
    下面是手表录音经语音识别得到的转写，识别错误很多（同音字、断句错误、漏字、把几个人的话连在一起）。
    请先结合上下文弄懂大意，再整理。原则是宁缺毋滥：碎片、口头语、看不懂的句子一律忽略，不要逐句照搬。
    每行转写前有方括号编号。只输出一个 JSON 对象：
    {"points":[{"text":"","sources":[编号]}],
     "decisions":[{"text":"","sources":[编号]}],
     "todos":[{"text":"","owner":null,"due":null,"sources":[编号]}],
     "pending":[{"text":"","sources":[编号]}]}
    要求：
    1. points：用完整通顺的句子概括这段在谈什么、得出了什么，最多 5 条。可以修正明显的识别错字，但不得加入转写里没有的事实。
    2. decisions：只收明确说出“已经定下来”的事。
    3. todos：只收明确要某人去做的具体事情（有动作、有对象），text 写成“做什么”的完整句子。owner、due 必须是转写里出现的原词，没有明确说就填 null。
    4. pending：只收明确提出但没有结论、需要后续确认的具体问题，写成完整的一句话，最多 3 条。
    5. 每条 text 不少于 8 个字，必须能脱离上下文看懂；每条必须给 sources（只能用【本段转写】里的编号）。
    6. 如果这段内容听不出任何有意义的信息，四个数组都留空。
    """

    static func llm(day: String, lines: [Line], segments: [Segment], engine: String, context: String = "") async throws -> Digest {
        let chunkLimit = engine == "device" ? 1400 : 9000
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        var chunks: [String] = []
        var current = ""
        for (i, line) in lines.enumerated() {
            let row = "[\(i)] \(time.string(from: line.time)) \(line.text)\n"
            if current.count + row.count > chunkLimit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += row
        }
        if !current.isEmpty { chunks.append(current) }

        var items: [DigestItem] = []
        for chunk in chunks {
            let prompt = (context.isEmpty ? "" : "【上文，仅供理解，不要从中提取】\n\(context)\n\n") + "【本段转写】\n" + chunk
            let raw: String
            if engine == "device" {
                raw = try await deviceRespond(prompt)
            } else {
                raw = try await cloudRespond(prompt)
            }
            items.append(contentsOf: parse(raw, lines: lines))
        }
        return Digest(day: day, stats: stats(lines: lines, segments: segments), items: items,
                      generatedAt: Date(), engine: engine, lineCount: lines.count)
    }

    private static func deviceRespond(_ prompt: String) async throws -> String {
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

    private static func cloudRespond(_ prompt: String) async throws -> String {
        let d = UserDefaults.standard
        guard d.bool(forKey: "cloudEnabled") else { throw DigestError.unavailable("云端总结未启用。") }
        let base = (d.string(forKey: "cloudURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (d.string(forKey: "cloudModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Keychain.get("cloudKey") ?? ""
        guard !base.isEmpty, !model.isEmpty, !key.isEmpty,
              let url = URL(string: base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"),
              url.scheme == "https" else {
            throw DigestError.unavailable("请先在设置里填写云端服务的 HTTPS 地址、模型名和密钥。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DigestError.unavailable("云端服务返回错误（HTTP \(code)）。")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DigestError.unavailable("云端服务返回了无法识别的内容。")
        }
        return content
    }

    /// 解析并校验模型输出：没有有效来源的条目丢弃；负责人/截止时间不在来源原文中则清空。
    static func parse(_ raw: String, lines: [Line]) -> [DigestItem] {
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var out: [DigestItem] = []
        let groups: [(String, ItemKind)] = [("points", .point), ("decisions", .decision), ("todos", .todo), ("pending", .pending)]
        for (key, kind) in groups {
            guard let array = obj[key] as? [[String: Any]] else { continue }
            for entry in array {
                guard let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 6 else { continue }
                let numbers = (entry["sources"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") }
                let valid = numbers.filter { lines.indices.contains($0) }
                guard !valid.isEmpty else { continue }
                let cited = valid.map { lines[$0].text }.joined(separator: " ")
                var owner = (entry["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let o = owner, o.isEmpty || o.lowercased() == "null" || !cited.contains(o) { owner = nil }
                var due = (entry["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = due, d.isEmpty || d.lowercased() == "null" || !cited.contains(d) { due = nil }
                var dueDate: Date?
                if kind == .todo, let d = due { dueDate = parseDue(d, base: lines[valid[0]].time)?.1 }
                out.append(DigestItem(id: UUID(), kind: kind, text: text, owner: kind == .todo ? owner : nil,
                                      due: kind == .todo ? due : nil, dueDate: dueDate,
                                      sourceLineIDs: valid.map { lines[$0].id }, done: false, exported: false))
            }
        }
        return out
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

/// 增量整理：每有新转写就只处理新增的句子并追加到当天回顾，
/// 所以回顾和待办是随录随出的；已勾选/已写入的状态不会被覆盖。
final class DigestCoordinator: ObservableObject {
    static let shared = DigestCoordinator()

    @Published var working = false
    @Published var lastError: String?
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

    func unprocessedCount(day: String) -> Int {
        let done = Set(Store.shared.db.digests[day]?.processed ?? [])
        return Store.shared.lines(on: day).filter { !done.contains($0.id) }.count
    }

    /// 新内容要攒够一段再交给模型：碎片逐句整理只会得到碎片。
    /// 条件：新增 ≥ 1200 字，或最后一句已经过去 5 分钟（这段对话结束了）。
    func readyToProcess(_ fresh: [Line]) -> Bool {
        guard let last = fresh.last else { return false }
        let chars = fresh.reduce(0) { $0 + $1.text.count }
        return chars >= 1200 || Date().timeIntervalSince(last.time) > 300
    }

    /// full = 丢弃当天已有回顾，整天重新整理；force = 不等攒够，现在就整理新增内容。
    func update(day: String, full: Bool = false, force: Bool = false) {
        let store = Store.shared
        let lines = store.lines(on: day)
        guard !lines.isEmpty, !working else { return }
        let segments = store.segments(on: day)
        let engine = DigestEngine.engine
        let existing = full ? nil : store.db.digests[day]
        // 老版本的回顾没有 processed 记录：视为全部处理过
        let done = Set(existing.map { $0.processed ?? lines.map { $0.id } } ?? [])
        let fresh = lines.filter { !done.contains($0.id) }
        guard !fresh.isEmpty else { return }
        if engine != "rules" && !full && !force && !readyToProcess(fresh) { return }
        let context = lines.filter { done.contains($0.id) }.suffix(8).map { $0.text }.joined(separator: "\n")

        func commit(_ items: [DigestItem]) {
            var digest = existing ?? Digest(day: day, stats: "", items: [], generatedAt: Date(), engine: engine, lineCount: 0)
            digest.items.append(contentsOf: items)
            digest.stats = DigestEngine.stats(lines: lines, segments: segments)
            digest.engine = engine
            digest.generatedAt = Date()
            digest.lineCount = lines.count
            digest.processed = Array(done) + fresh.map { $0.id }
            store.setDigest(digest)
            Notifier.apply()
        }

        if engine == "rules" {
            commit(DigestEngine.rules(day: day, lines: fresh, segments: segments).items)
            return
        }
        working = true
        lastError = nil
        Task {
            do {
                let result = try await DigestEngine.llm(day: day, lines: fresh, segments: segments, engine: engine, context: context)
                await MainActor.run {
                    commit(result.items)
                    self.working = false
                    if self.unprocessedCount(day: day) > 0 { self.update(day: day) }
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.working = false
                }
            }
        }
    }
}
