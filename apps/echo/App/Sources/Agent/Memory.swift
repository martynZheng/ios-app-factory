import Foundation

// MARK: - 记忆：一个本机的文件系统
//
// 参考 Anthropic《The components of agent memory》（2026-11）的分层，全部是 Application Support/Echo/Memory 下的 Markdown 文件：
//
//   MEMORY.md          第 3 层 顶层：核心事实 + 维基目录，每次对话都带上（控制在约 150 行）
//   wiki/<主题>.md      第 2 层 表示：人物、项目、偏好、习惯……做梦时由笔记和原始记录整理出来
//   notes/<日期>.md     第 1 层 笔记：聊天时随手记下的事
//   raw/<日期>.md       第 0 层 原始记录：当天的录音转写、整理出的章节、聊天原文。只读，是核对的依据
//   dreams/<日期>.md    做梦日志：每次整理改了什么
//
// 每个文件开头都有一行描述（front matter 里的 description）。查找时渐进式披露：
// 顶层 → 目录里的描述 → 打开页面 → 翻原始记录。文件多了也只是多几行目录，不会把上下文撑爆。

struct MemoryFile: Identifiable, Hashable {
    var path: String
    var description: String
    var updated: Date
    var size: Int
    var id: String { path }
    var layer: String { path.split(separator: "/").first.map(String.init) ?? "" }
}

@MainActor
final class MemoryFS: ObservableObject {
    static let shared = MemoryFS()
    static let indexName = "MEMORY.md"
    static let writableDirs = ["notes", "wiki"]

    let root: URL
    /// 有变化时加一，界面据此刷新
    @Published private(set) var revision = 0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        root = base.appendingPathComponent(Store.isDemo ? "MemoryDemo" : "Memory", isDirectory: true)
        if Store.isDemo { try? FileManager.default.removeItem(at: root) }
        for dir in ["raw", "notes", "wiki", "dreams", ".backup"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        migrateLegacy()
        if Store.isDemo { Self.seedDemo(self) }
    }

    // MARK: 路径

    /// 只接受 root 里的相对路径；拒绝 ..、绝对路径、隐藏目录。
    func url(_ path: String) -> URL? {
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty, !clean.contains(".."), !clean.hasPrefix(".") else { return nil }
        return root.appendingPathComponent(clean)
    }

    static func canWrite(_ path: String) -> Bool {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if clean == indexName { return true }
        guard clean.hasSuffix(".md"), let dir = clean.split(separator: "/").first.map(String.init) else { return false }
        return writableDirs.contains(dir) && clean.split(separator: "/").count == 2
    }

    // MARK: 读

    struct Parsed {
        var description: String
        var body: String
    }

    static func parse(_ text: String) -> Parsed {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            return Parsed(description: String(first.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(80)), body: text)
        }
        let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var description = ""
        for line in header.split(separator: "\n") where line.hasPrefix("description:") {
            description = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
        }
        return Parsed(description: description, body: String(text[end.upperBound...]))
    }

    func read(_ path: String) -> String? {
        guard let u = url(path) else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    var index: String {
        Self.parse(read(Self.indexName) ?? "").body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 列出一个目录（或全部）里的文件和描述，新的在前。
    func list(_ dir: String? = nil) -> [MemoryFile] {
        let dirs = dir.map { [$0.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))] } ?? ["wiki", "notes", "raw", "dreams"]
        var out: [MemoryFile] = []
        let fm = FileManager.default
        for d in dirs {
            let folder = root.appendingPathComponent(d, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".md") {
                let u = folder.appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: u.path)
                let text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                out.append(MemoryFile(path: "\(d)/\(name)", description: Self.parse(text).description,
                                      updated: attrs?[.modificationDate] as? Date ?? .distantPast, size: text.count))
            }
        }
        return out.sorted { $0.updated > $1.updated }
    }

    struct Hit {
        var path: String
        var description: String
        var snippets: [String]
        var score: Int
    }

    /// 按关键词找：空格分开的每个词都要出现。描述里命中排在前面，正文命中给出上下文片段。
    func search(_ query: String, in dir: String? = nil, limit: Int = 12) -> [Hit] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "，" || $0 == "," }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var hits: [Hit] = []
        let files = list(dir) + (dir == nil ? [MemoryFile(path: Self.indexName, description: "顶层记忆", updated: Date(), size: 0)] : [])
        for f in files {
            guard let text = read(f.path) else { continue }
            let lower = text.lowercased()
            guard words.allSatisfy({ lower.contains($0) }) else { continue }
            let desc = f.description.lowercased()
            var score = words.filter { desc.contains($0) || f.path.lowercased().contains($0) }.count * 10
            var snippets: [String] = []
            for line in text.split(separator: "\n") where words.contains(where: { line.lowercased().contains($0) }) {
                score += 1
                if snippets.count < 3 { snippets.append(String(line.trimmingCharacters(in: .whitespaces).prefix(160))) }
            }
            // 越往上层越可信、越精炼
            if f.layer == "wiki" || f.path == Self.indexName { score += 3 }
            if f.layer == "notes" { score += 1 }
            hits.append(Hit(path: f.path, description: f.description, snippets: snippets, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: 写

    @discardableResult
    func write(_ path: String, description: String, body: String) -> Bool {
        guard Self.canWrite(path), let u = url(path) else { return false }
        let desc = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let text = "---\ndescription: \(desc)\nupdated: \(f.string(from: Date()))\n---\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
            try? (u as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
            revision += 1
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(_ path: String) -> Bool {
        guard Self.canWrite(path), path != Self.indexName, let u = url(path) else { return false }
        do {
            try FileManager.default.removeItem(at: u)
            revision += 1
            return true
        } catch {
            return false
        }
    }

    /// 聊天时随手记一笔：追加到今天的笔记文件。
    func note(_ fact: String) {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let day = Store.dayKey(Date())
        let path = "notes/\(day).md"
        let existing = read(path).map { Self.parse($0).body } ?? ""
        guard !existing.contains(text) else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let body = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- [\(f.string(from: Date()))] \(text)"
        let count = body.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        write(path, description: "\(day) 聊天中记下的 \(count) 条笔记（还没整理进维基）", body: body)
    }

    func touch() { revision += 1 }

    func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        for dir in ["raw", "notes", "wiki", "dreams", ".backup"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        UserDefaults.standard.removeObject(forKey: "dreamedDays")
        UserDefaults.standard.removeObject(forKey: "lastDream")
        revision += 1
    }

    // MARK: 第 0 层：把一天的原始记录写成文件

    /// 当天的录音转写、整理出的章节和待办、聊天原文。内容没变就不重写。
    @discardableResult
    func materialize(day: String) -> Bool {
        guard let u = url("raw/\(day).md") else { return false }
        let store = Store.shared
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        var parts: [String] = []
        var bits: [String] = []
        if let digest = store.db.digests[day] {
            var rows: [String] = []
            if let scene = digest.scene, !scene.isEmpty { rows.append("场合：\(scene)") }
            for c in (digest.chapters ?? []).sorted(by: { $0.start < $1.start }) {
                let ctx = [c.situation, c.setting].compactMap { $0 }.joined(separator: " · ")
                rows.append("- \(hm.string(from: c.start))–\(hm.string(from: c.end)) \(c.title)\(ctx.isEmpty ? "" : "［\(ctx)］")：\(c.summary)")
            }
            for item in digest.items where item.kind != .point {
                let label = item.kind == .todo ? (item.done ? "待办（已完成）" : "待办") : (item.kind == .decision ? "决定" : "待确认")
                rows.append("- \(label)：\(item.text)\(item.owner.map { "（\($0)）" } ?? "")\(item.due.map { "（\($0)）" } ?? "")")
            }
            if !rows.isEmpty {
                parts.append("## 整理\n" + rows.joined(separator: "\n"))
                if let scene = digest.scene, !scene.isEmpty { bits.append(scene) }
            }
        }
        let lines = store.lines(on: day)
        if !lines.isEmpty {
            parts.append("## 录音转写\n" + lines.map { "- \(hm.string(from: $0.time)) \($0.text)" }.joined(separator: "\n"))
            bits.append("\(lines.count) 句录音")
        }
        let chats = ChatStore.shared.messages.filter { Store.dayKey($0.time) == day && !$0.failed }
        if !chats.isEmpty {
            parts.append("## 和助理的对话\n" + chats.map { m in
                let who = m.role == .user ? "我" : "助理"
                let text = m.text.replacingOccurrences(of: "\n", with: " ")
                return "- \(hm.string(from: m.time)) \(who)：\(String(text.prefix(600)))"
            }.joined(separator: "\n"))
            bits.append("\(chats.count) 条对话")
        }
        guard !parts.isEmpty else { return false }
        let text = "---\ndescription: \(day) 原始记录：\(bits.joined(separator: "，"))\n---\n" + parts.joined(separator: "\n\n") + "\n"
        if let old = try? String(contentsOf: u, encoding: .utf8), old == text { return false }
        try? text.write(to: u, atomically: true, encoding: .utf8)
        try? (u as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        revision += 1
        return true
    }

    /// 有记录的所有日子（录音或聊天）。
    func recordedDays() -> [String] {
        var days = Set(Store.shared.sortedLines.map { Store.dayKey($0.time) })
        for m in ChatStore.shared.messages { days.insert(Store.dayKey(m.time)) }
        return days.sorted()
    }

    /// 把最近的原始记录同步成文件（打开 App 时、做梦前）。
    func syncRaw(recentDays: Int = 3) {
        let cutoff = Store.dayKey(Date().addingTimeInterval(-Double(recentDays) * 86_400))
        for day in recordedDays() {
            let exists = url("raw/\(day).md").map { FileManager.default.fileExists(atPath: $0.path) } ?? true
            if !exists || day >= cutoff { materialize(day: day) }
        }
    }

    // MARK: 迁移与演示

    /// 旧版的记忆（一条条字符串）搬进笔记，并建一个初始的顶层。
    private func migrateLegacy() {
        let d = UserDefaults.standard
        guard !Store.isDemo, let old = d.stringArray(forKey: "agentMemory"), !old.isEmpty else {
            if read(Self.indexName) == nil { writeEmptyIndex() }
            return
        }
        write("notes/早先的记忆.md", description: "旧版本里记下的 \(old.count) 条关于我的事（还没整理进维基）",
              body: old.map { "- \($0)" }.joined(separator: "\n"))
        if read(Self.indexName) == nil {
            write(Self.indexName, description: "顶层记忆", body: "## 关于我\n" + old.prefix(30).map { "- \($0)" }.joined(separator: "\n") + "\n\n## 维基目录\n（还没有，等第一次做梦整理）")
        }
        d.removeObject(forKey: "agentMemory")
    }

    private func writeEmptyIndex() {
        write(Self.indexName, description: "顶层记忆", body: "## 关于我\n（还不了解，聊着聊着就知道了）\n\n## 维基目录\n（还没有）")
    }

    static func seedDemo(_ m: MemoryFS) {
        m.write(indexName, description: "顶层记忆", body: """
        ## 关于我
        - 汯毅，负责采供与 IDC 的 AI 落地，常主持内部的 AI 实战挑战赛
        - 说话喜欢直接给结论；不喜欢长篇大论
        - 周末上午不安排工作

        ## 正在进行
        - AI 实战挑战赛决赛已办完，评分表还没汇总（见 wiki/AI实战挑战赛.md）

        ## 维基目录
        - wiki/AI实战挑战赛.md — 赛制、六支队伍、评委组、待办
        - wiki/人物.md — 同事和评委是谁、各自负责什么
        - wiki/偏好.md — 说话方式、作息、关心的资讯
        """)
        m.write("wiki/AI实战挑战赛.md", description: "采供&IDC AI 实战挑战赛：赛制、六支队伍的方案、评委组、会后待办", body: """
        # AI 实战挑战赛
        - 决赛 11 月 13 日在云栖国际会展中心 B 厅，我主持；六支队伍，每队 10 分钟讲解 + 5 分钟问答
        - 二号：告警自闭环助手“小美”，沉淀 34 个技能；恢复操作先建工单
        - 五号（天津 DC 平台）：提交与验收的增量 + 全量检查，用旧页面基线对照
        - 奖项：一等奖 1 名、二等奖 2 名
        - 待办：会后汇总评分表，周五前发给评委组（来源 raw/2026-11-13.md 中场休息）
        """)
        m.write("wiki/偏好.md", description: "我的说话方式、作息和关心的话题", body: "- 回复要短，先说结论\n- 关心 AI 落地、运维自动化、DeepSeek 的新能力")
        m.write("notes/\(Store.dayKey(Date())).md", description: "今天聊天中记下的 2 条笔记（还没整理进维基）",
                body: "- [09:58] 评分表由我汇总，周五前发评委组\n- [10:05] 场地下周能不能用要问行政")
        m.write("dreams/\(Store.dayKey(Date())).md", description: "做梦：整理了 1 天的记录，新建 2 页维基，删 1 条过时笔记", body: "- 新建 wiki/AI实战挑战赛.md\n- 新建 wiki/偏好.md\n- 更新 MEMORY.md 的“正在进行”")
    }
}

// MARK: - 给智能体用的记忆工具

enum MemoryTools {
    private static let str: [String: Any] = ["type": "string"]
    private static func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    /// 只读的三个：浏览目录、搜索、打开文件。对话、主动提醒、做梦都能用。
    @MainActor
    static func read() -> [AgentTool] {
        let m = MemoryFS.shared
        return [
            AgentTool(name: "memory_list", description: """
                看记忆目录：列出文件和一句话描述（不含正文）。dir 可选 wiki（整理好的主题页）、notes（零散笔记）、raw（每天的原始记录：录音、对话）、dreams（整理日志），不填列 wiki 和 notes。
                先看描述再决定打开哪个，不要一次全部打开。
                """, parameters: obj(["dir": str], [])) { args in
                let dir = (args["dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let files = await MainActor.run { () -> [MemoryFile] in
                    if dir == nil { return m.list("wiki") + m.list("notes") }
                    return m.list(dir)
                }
                guard !files.isEmpty else { return ToolResult(content: "这里还没有文件。") }
                let f = DateFormatter()
                f.dateFormat = "M-d"
                let rows = files.prefix(80).map { "\($0.path)  [\(f.string(from: $0.updated)) · \($0.size) 字] \($0.description)" }
                return ToolResult(content: rows.joined(separator: "\n") + (files.count > 80 ? "\n……还有 \(files.count - 80) 个，用 memory_search 缩小范围" : ""))
            },
            AgentTool(name: "memory_search", description: """
                在记忆文件里按关键词找（空格分隔的每个词都要出现），返回文件路径、描述和命中的行。描述里命中的排在前面。
                dir 可选，只在某一层里找。找到后用 memory_read 打开。
                """, parameters: obj(["query": str, "dir": str], ["query"])) { args in
                let q = args["query"] as? String ?? ""
                let dir = (args["dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let hits = await MainActor.run { m.search(q, in: dir) }
                guard !hits.isEmpty else { return ToolResult(content: "没有找到「\(q)」。可以换个说法，或者用 memory_list dir=raw 按日期翻原始记录。") }
                let rows = hits.map { h in "\(h.path) — \(h.description)\n" + h.snippets.map { "    · \($0)" }.joined(separator: "\n") }
                return ToolResult(content: rows.joined(separator: "\n"))
            },
            AgentTool(name: "memory_read", description: "打开一个记忆文件看全文（路径来自 memory_list / memory_search，如 wiki/人物.md、raw/2026-11-13.md）。",
                      parameters: obj(["path": str], ["path"])) { args in
                let path = args["path"] as? String ?? ""
                let text = await MainActor.run { () -> String? in
                    // 原始记录按需生成
                    if path.hasPrefix("raw/"), path.hasSuffix(".md") {
                        m.materialize(day: String(path.dropFirst(4).dropLast(3)))
                    }
                    return m.read(path)
                }
                guard let text else { return ToolResult(content: "没有这个文件：\(path)", isError: true) }
                if text.count > 16_000 {
                    return ToolResult(content: String(text.prefix(16_000)) + "\n……（文件太长，后面省略；用 memory_search 找具体内容）")
                }
                return ToolResult(content: text)
            },
        ]
    }

    /// 写的工具：对话里用来记笔记、改维基；做梦时用来整理。原始记录（raw/）永远不能改。
    @MainActor
    static func write(dreaming: Bool) -> [AgentTool] {
        let m = MemoryFS.shared
        var writeHelp = "新建或整个覆盖一个记忆文件。path 只能是 notes/<名字>.md、wiki/<主题>.md 或 MEMORY.md；description 是一句话说清这个文件里有什么（目录里只显示这一句，要写得让人一看就知道该不该打开）。body 是全文（Markdown）。改已有文件前先 memory_read，保留没过时的内容。"
        if !dreaming { writeHelp += "平时记一件事用 remember 就够了，只有在改正或整理某个主题时才直接写。" }
        var tools: [AgentTool] = [
            AgentTool(name: "memory_write", description: writeHelp,
                parameters: obj(["path": str, "description": str, "body": str], ["path", "description", "body"])) { args in
                let path = args["path"] as? String ?? ""
                guard MemoryFS.canWrite(path) else {
                    return ToolResult(content: "不能写 \(path)：只能写 notes/*.md、wiki/*.md 或 MEMORY.md，原始记录 raw/ 只读。", isError: true)
                }
                let body = args["body"] as? String ?? ""
                if path == MemoryFS.indexName, body.split(separator: "\n").count > 180 {
                    return ToolResult(content: "MEMORY.md 太长了（\(body.split(separator: "\n").count) 行），每次对话都会带上它，请压到 150 行以内：细节放进 wiki，顶层只留核心事实和目录。", isError: true)
                }
                let ok = await MainActor.run { m.write(path, description: args["description"] as? String ?? "", body: body) }
                return ToolResult(content: ok ? "已写入 \(path)。" : "写入失败。", isError: !ok)
            },
            AgentTool(name: "memory_delete", description: "删掉一个过时或已经并进别处的记忆文件（notes/ 或 wiki/ 下）。",
                      parameters: obj(["path": str], ["path"])) { args in
                let path = args["path"] as? String ?? ""
                let ok = await MainActor.run { m.delete(path) }
                return ToolResult(content: ok ? "已删除 \(path)。" : "不能删 \(path)。", isError: !ok)
            },
        ]
        if !dreaming {
            tools.insert(AgentTool(name: "remember", description: """
                记下一条关于我的长期信息（偏好、习惯、人物关系、在忙的事、固定安排）。不用等我说“记住”，你觉得以后用得上就记，一条一件事。
                它会进今天的笔记，夜里整理记忆时会被核对、并进维基。
                """, parameters: obj(["fact": str], ["fact"])) { args in
                let fact = args["fact"] as? String ?? ""
                await MainActor.run { m.note(fact) }
                return ToolResult(content: "记下了。")
            }, at: 0)
        }
        return tools
    }

    /// 放进系统提示的那一段：顶层记忆 + 怎么往下找。
    @MainActor
    static func prompt() -> String {
        let top = MemoryFS.shared.index
        let counts = ["wiki", "notes", "raw"].map { "\($0) \(MemoryFS.shared.list($0).count) 个" }.joined(separator: "，")
        return """
        【你的记忆】下面是顶层记忆（MEMORY.md），每次都带着。更多在记忆文件里（\(counts)）：
        先看这里；不够就 memory_search 或 memory_list 看描述，再 memory_read 打开需要的那一页；要核对原话就打开 raw/<日期>.md。不要凭印象说“你以前说过”，要说就先查到。

        \(top.isEmpty ? "（顶层记忆还是空的）" : String(top.prefix(8000)))
        """
    }
}
