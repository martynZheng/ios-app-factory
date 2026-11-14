import Foundation

/// 整理录音的个人智能体：跑在 Pi 上（Brain.run），DeepSeek 先用工具弄清楚“我在哪、在干什么、之前发生了什么”，
/// 再按场景分章，最后通过 submit_digest 提交；提交的内容会被校验，不合格就把问题退回给模型重写。
@MainActor
enum DigestAgent {
    static let system = """
    你是“我”的随身个人助理（personal agent）。我戴着手表，它把我身边的声音录下来、转成文字交给你。
    转写错字很多，也分不清谁在说话：可能是我在说、我在听别人讲、我在开车打电话，也可能只是背景里别人的声音。
    你的工作是：先弄清楚我当时在什么场景、在做什么，再把这一段整理成我回头能看懂的记录。

    工作方式（像侦探一样先取证再下结论）：
    1. 先调用 get_context 查这段时间的情境：我在哪（地点）、身体状态（静止/步行/乘车/跑步）、日程上写着什么。
       例：乘车 + 两个人对话 → 多半是车上聊天或打电话；静止在会展中心 + 日程“决赛” + 有人报选手号 → 我在比赛现场；
       在家 + 夜里 + 电视腔调的句子 → 背景是电视，不是我的事。
    2. 需要时调用 get_day_so_far 看今天前面整理过什么，保持章节连贯；对不熟的人名、项目名可以 search_memory 翻以前的记录；
       get_profile 看我是谁、我自己写的背景。不要为了调用而调用，一般 1–3 次工具就够。
    3. 推理出场景后，调用 submit_digest 提交结果。提交是唯一的输出方式，不要把结果写在普通回复里。
       如果提交被退回，按退回的问题修改后重新提交。

    整理规则：
    - scene：一句话说今天这一段我在什么场合、什么角色（如“在云栖小镇会展中心主持 AI 大赛决赛”）。我自己写的背景优先。
    - chapters：按时间顺序分章，一个完整话题/一位讲者/一段路程里的一次对话算一章；情境变了（换了地点、从静止变成乘车）通常就是新的一章。
      title 不超过 14 个字、写具体内容；speaker 只填转写里出现的称呼；situation 用不超过 16 个字说“我当时在做什么”（如“在会场主持”“开车回家路上通话”）；
      summary 1–2 句；points 最多 4 条具体信息点；sources 是这一章的行号。第一章如果是【上一章】的继续，continues 设 true。
    - todos 只收明确需要我或在场具体某人会后去做的事；decisions 只收明确定下来的事；pending 只收需要我后续确认的具体问题（最多 2 条）。
      旁听别人演讲、背景声音里的话，都不是我的待办。owner、due 必须是原文里出现的词，否则 null。
    - 所有 sources 只能用【本段转写】的行号。看不懂的碎片忽略，宁缺毋滥，不得编造原文没有的事实。
    """

    private static func obj(_ props: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    private static func arr(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    private static let str: [String: Any] = ["type": "string"]
    private static let nullableStr: [String: Any] = ["type": ["string", "null"]]
    private static let sources: [String: Any] = ["type": "array", "items": ["type": "integer"], "description": "本段转写的行号"]

    static var submitSchema: [String: Any] {
        let simple = arr(obj(["text": str, "sources": sources], required: ["text", "sources"]))
        let chapter = obj(["title": str, "speaker": nullableStr, "situation": str, "summary": str,
                           "continues": ["type": "boolean"] as [String: Any], "sources": sources, "points": simple],
                          required: ["title", "summary", "sources"])
        let todo = obj(["text": str, "owner": nullableStr, "due": nullableStr, "sources": sources], required: ["text", "sources"])
        return obj(["scene": str, "chapters": arr(chapter), "decisions": simple, "todos": arr(todo), "pending": simple],
                   required: ["scene", "chapters", "decisions", "todos", "pending"])
    }

    /// 跑一次智能体，返回校验过的整理结果。status 用来在界面上显示它正在做什么。
    static func run(chunk: [Line], day: String, contextNote: String,
                    status: @escaping (String) -> Void) async throws -> DigestEngine.Block {
        let store = Store.shared
        let sensor = ContextSensor.shared
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let dayStart = Store.date(fromDayKey: day)
        func time(_ s: Any?) -> Date? {
            guard let s = s as? String else { return nil }
            let parts = s.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: dayStart)
        }

        var submitted: DigestEngine.Block?
        let first = chunk.first?.time ?? Date(), last = chunk.last?.time ?? Date()

        let tools: [AgentTool] = [
            AgentTool(name: "get_context",
                      description: "查一段时间里我的情境：位置（地名）、身体状态（静止/步行/乘车/跑步/骑行）、日程。时间用 HH:mm。",
                      parameters: ["type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"]], "required": ["from", "to"]]) { args in
                let from = time(args["from"]) ?? first.addingTimeInterval(-600)
                let to = time(args["to"]) ?? last.addingTimeInterval(300)
                let text = await sensor.describe(from: from, to: max(to, from.addingTimeInterval(60)))
                return ToolResult(content: text.isEmpty ? "这段时间没有情境数据（我可能没有开启定位/运动/日历）。只能从对话内容判断。" : text)
            },
            AgentTool(name: "get_day_so_far",
                      description: "今天已经整理好的章节（时间、标题、情境、概括）和未完成的待办。",
                      parameters: ["type": "object", "properties": [:] as [String: Any]]) { _ in
                guard let digest = store.db.digests[day] else { return ToolResult(content: "今天还没有整理过的内容。") }
                var rows: [String] = []
                if let scene = digest.scene, !scene.isEmpty { rows.append("场合：\(scene)") }
                for c in (digest.chapters ?? []).sorted(by: { $0.start < $1.start }) {
                    var row = "\(clock.string(from: c.start))–\(clock.string(from: c.end)) \(c.title)"
                    if let s = c.situation { row += "［\(s)］" }
                    if let s = c.setting { row += "（\(s)）" }
                    rows.append(row + "：\(c.summary)")
                }
                let todos = digest.items.filter { $0.kind == .todo && !$0.done }.map { "待办：\($0.text)" }
                return ToolResult(content: (rows + todos).joined(separator: "\n"))
            },
            AgentTool(name: "search_memory",
                      description: "在我以前的录音转写和整理里按关键词查找（人名、项目、地点等），返回最多 12 条带日期的原话或章节标题。",
                      parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]) { args in
                let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { return ToolResult(content: "关键词太短。", isError: true) }
                let stamp = DateFormatter()
                stamp.dateFormat = "M月d日 HH:mm"
                var rows: [String] = []
                for (d, digest) in store.db.digests where d != day {
                    for c in digest.chapters ?? [] where c.title.contains(q) || c.summary.contains(q) {
                        rows.append("\(stamp.string(from: c.start)) 章节「\(c.title)」：\(c.summary)")
                    }
                }
                let chunkIDs = Set(chunk.map { $0.id })
                for line in store.sortedLines.reversed() where !chunkIDs.contains(line.id) && line.text.contains(q) {
                    rows.append("\(stamp.string(from: line.time)) \(line.text)")
                    if rows.count >= 12 { break }
                }
                return ToolResult(content: rows.isEmpty ? "没有找到「\(q)」。" : rows.prefix(12).joined(separator: "\n"))
            },
            AgentTool(name: "get_profile",
                      description: "我是谁（我自己写的介绍）、我给今天写的背景、我的常用词。",
                      parameters: ["type": "object", "properties": [:] as [String: Any]]) { _ in
                let d = UserDefaults.standard
                let me = d.string(forKey: "aboutMe") ?? ""
                let bg = store.db.dayContext?[day] ?? ""
                let vocab = d.string(forKey: "vocab") ?? ""
                return ToolResult(content: "关于我：\(me.isEmpty ? "（没写）" : me)\n今天的背景：\(bg.isEmpty ? "（没写）" : bg)\n常用词：\(vocab.isEmpty ? "（没写）" : vocab)")
            },
            AgentTool(name: "submit_digest",
                      description: "提交这一段的整理结果（唯一的输出方式）。不合格会被退回并说明原因。",
                      parameters: submitSchema) { args in
                let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
                let raw = String(data: data, encoding: .utf8) ?? "{}"
                let block = DigestEngine.parseBlock(raw, lines: chunk)
                let problems = validate(args: args, block: block, chunk: chunk)
                if !problems.isEmpty {
                    return ToolResult(content: "退回，请修改后重新提交：\n" + problems.joined(separator: "\n"), isError: true)
                }
                submitted = block
                return ToolResult(content: "已收到。", terminate: true)
            },
        ]

        var replies: [String] = []
        let onEvent: (PiEvent) -> Void = { event in
            switch event {
            case .turnStart(let n): status(n == 1 ? "智能体在读这一段…" : "智能体在推理场景…")
            case .assistant(let text, _):
                if !text.isEmpty { replies.append(text) }
            case .toolStart(let name):
                switch name {
                case "get_context": status("查看当时的位置、状态和日程…")
                case "get_day_so_far": status("回看今天前面的经过…")
                case "search_memory": status("翻以前的记录…")
                case "get_profile": status("看你写的背景…")
                case "submit_digest": status("写入整理结果…")
                default: break
                }
            default: break
            }
        }
        let rows = chunk.enumerated().map { "[\($0.offset)] \(clock.string(from: $0.element.time)) \($0.element.text)" }.joined(separator: "\n")
        let prompt = (contextNote.isEmpty ? "" : contextNote + "\n\n") +
            "【本段转写】\(clock.string(from: first))–\(clock.string(from: last))，共 \(chunk.count) 行\n" + rows
        _ = try await Brain.run(system: system, tools: tools, thinking: nil, prompt: prompt, maxTurns: 7, web: false, onEvent: onEvent)

        if let submitted { return submitted }
        // 模型没走提交工具、直接把 JSON 写在回复里：也接受
        for text in replies.reversed() where text.contains("{") {
            let block = DigestEngine.parseBlock(text, lines: chunk)
            if !block.chapters.isEmpty || !block.others.isEmpty { return block }
        }
        throw DigestError.unavailable("智能体没有给出整理结果，稍后会重试。")
    }

    /// 提交校验：把能机器发现的问题退回给模型。
    static func validate(args: [String: Any], block: DigestEngine.Block, chunk: [Line]) -> [String] {
        var problems: [String] = []
        let raw = args["chapters"] as? [[String: Any]] ?? []
        let chars = chunk.reduce(0) { $0 + $1.text.count }
        if raw.isEmpty && chars > 120 { problems.append("这一段有 \(chunk.count) 行、\(chars) 字，至少要分出一章。") }
        if block.chapters.count < raw.count {
            problems.append("有 \(raw.count - block.chapters.count) 章被丢弃：title 不能为空，sources 必须是 0–\(chunk.count - 1) 之间的行号。")
        }
        let starts = block.chapters.map { $0.lineIdx.min() ?? 0 }
        if starts != starts.sorted() { problems.append("章节要按时间先后排列（按每章最小的行号从小到大）。") }
        for (i, c) in block.chapters.enumerated() where c.title.count > 16 {
            problems.append("第 \(i + 1) 章标题「\(c.title)」太长，压到 14 个字以内。")
        }
        return problems
    }
}
