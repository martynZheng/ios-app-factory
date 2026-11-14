import Foundation

/// 做梦：离线整理记忆。每天一次（夜里系统给后台时间，或白天打开 App 时补上），也可以在设置里手动触发。
/// 读还没整理过的原始记录和零散笔记 → 用原始记录核对笔记 → 并进维基主题页 → 删掉过时和重复的 → 重写顶层 MEMORY.md。
/// 原始记录只读；每次开始前把 notes、wiki、MEMORY.md 备份一份，出错可以回滚；改了什么写进 dreams/<日期>.md。
@MainActor
final class Dreaming: ObservableObject {
    static let shared = Dreaming()
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published private(set) var lastError: String?

    /// 一次最多消化几天的原始记录（控制花费；剩下的下次接着做）
    static let daysPerDream = 5

    static var enabled: Bool { UserDefaults.standard.object(forKey: "dreamEnabled") as? Bool ?? true }
    static var lastDream: Date? {
        let t = UserDefaults.standard.double(forKey: "lastDream")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private var dreamed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "dreamedDays") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "dreamedDays") }
    }

    /// 还没整理过的日子：有记录、不是今天（今天还没过完），或者整理之后又有了新内容。
    func pendingDays() -> [String] {
        let m = MemoryFS.shared
        let today = Store.dayKey(Date())
        let done = dreamed
        return m.recordedDays().filter { $0 < today && !done.contains($0) }
    }

    /// 到时间了吗：一天一次，晚上 9 点后或第二天任何时候都行；有新东西才做。
    func due() -> Bool {
        guard Self.enabled, Cloud.ready, !Store.isDemo, !running else { return false }
        if let last = Self.lastDream, Date().timeIntervalSince(last) < 18 * 3600 { return false }
        return !pendingDays().isEmpty || !MemoryFS.shared.list("notes").isEmpty
    }

    func dreamIfDue() async {
        if due() { await dream() }
    }

    func dream() async {
        guard !running, Cloud.ready else { return }
        running = true
        lastError = nil
        status = "准备整理…"
        defer {
            running = false
            status = nil
        }
        let m = MemoryFS.shared
        let days = Array(pendingDays().prefix(Self.daysPerDream))
        for day in days { m.materialize(day: day) }
        backup()

        var summary = ""
        var finished = false
        let str: [String: Any] = ["type": "string"]
        var tools = MemoryTools.read() + MemoryTools.write(dreaming: true)
        tools.append(AgentTool(name: "finish_dream", description: "整理完成后调用：summary 用几行列出这次新建、合并、修改、删除了什么，以及顶层改了什么。",
                               parameters: ["type": "object", "properties": ["summary": str], "required": ["summary"]]) { args in
            summary = args["summary"] as? String ?? ""
            finished = true
            return ToolResult(content: "好，辛苦了。", terminate: true)
        })

        let notes = m.list("notes").map { "- \($0.path)：\($0.description)" }.joined(separator: "\n")
        let wiki = m.list("wiki").map { "- \($0.path)：\($0.description)" }.joined(separator: "\n")
        let raws = days.map { "- raw/\($0).md" }.joined(separator: "\n")
        let name = BuddyProfile.shared.name
        let system = """
        你是“\(name)”，我（用户）的常驻助理。现在不是在和我聊天，而是在“做梦”：离线整理你关于我的长期记忆。

        记忆是一组 Markdown 文件，分四层：
        - raw/<日期>.md：当天的原始记录（录音转写、整理出的章节和待办、我和你的对话）。只读，是判断真假的唯一依据。
        - notes/*.md：你平时聊天时随手记的笔记，零散、可能记错、可能过时。
        - wiki/<主题>.md：整理好的主题页，比如一个人、一个项目、我的偏好、作息、家庭、工作。每页开头有一句 description。
        - MEMORY.md：顶层记忆，每次对话都会整页带上，所以必须短（150 行以内）：只放最核心、最常用的关于我的事实，正在进行的事，以及 wiki 目录（每页一行：路径 — 一句话）。

        这次要做的：
        1. 读这次要消化的原始记录（下面列出了），以及所有 notes。
        2. 核对：笔记和原始记录对不上的，以原始记录为准改正；原始记录里没有依据、又说不清来源的猜测，删掉。
        3. 合并：把值得长期记住的内容并进对应的 wiki 页（没有就新建一页；同一主题不要拆成好几页，也不要把不相干的东西塞进一页）。
           值得记的：我是谁、身边的人（名字、关系、在做什么）、在忙的项目和进展、做过的决定、答应别人的事、偏好和习惯、反复出现的模式。
           不值得记的：一次性的闲聊、天气、已经过去且没有后续的琐事、可以随时再查到的公开信息。
           写进 wiki 的事实尽量注明日期和来源（如“（11-13，raw/2026-11-13.md）”），过时的要更新而不是并列保留。
        4. 清理：已经并进 wiki 的笔记文件删掉（memory_delete）；重复、矛盾、过时的条目合并或删除。
        5. 重写 MEMORY.md：从所有 wiki 里提炼最重要的事实放在“关于我”“正在进行”，最后是完整的“维基目录”。
        6. 调用 finish_dream 汇报。

        原则：宁缺毋滥，绝不编造原始记录里没有的事；description 要写得让人只看这一句就知道该不该打开；全部用中文，wiki 文件名用简短的中文主题名（如 wiki/家庭.md、wiki/AI实战挑战赛.md、wiki/人物-阿杰.md）。
        """
        let prompt = """
        这次要消化的原始记录（\(days.count) 天）：
        \(raws.isEmpty ? "（没有新的原始记录，只整理笔记）" : raws)

        现有笔记：
        \(notes.isEmpty ? "（没有）" : notes)

        现有维基：
        \(wiki.isEmpty ? "（还没有）" : wiki)

        当前顶层 MEMORY.md：
        \(m.index)
        """
        do {
            _ = try await Brain.run(system: system, tools: tools, thinking: nil, prompt: prompt, maxTurns: 80, web: false) { event in
                switch event {
                case .turnStart(let n): self.status = n == 1 ? "在读记录…" : "在整理（第 \(n) 步）…"
                case .toolStart(let tool):
                    switch tool {
                    case "memory_read": self.status = "在翻记录…"
                    case "memory_write": self.status = "在写维基…"
                    case "memory_delete": self.status = "在清理…"
                    default: break
                    }
                default: break
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        guard finished || lastError == nil else { return }
        var d = dreamed
        for day in days { d.insert(day) }
        dreamed = d
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastDream")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let log = "时间：\(stamp.string(from: Date()))\n消化的原始记录：\(days.isEmpty ? "无" : days.joined(separator: "、"))\n\n" +
            (summary.isEmpty ? "（没有留下说明）" : summary)
        let firstLine = summary.split(separator: "\n").first.map(String.init) ?? "整理了记忆"
        _ = writeLog(log, description: "做梦：\(days.isEmpty ? "整理笔记" : "消化 \(days.count) 天的记录")。\(String(firstLine.prefix(60)))")
    }

    private func writeLog(_ body: String, description: String) -> Bool {
        let m = MemoryFS.shared
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        guard let u = m.url("dreams/\(f.string(from: Date())).md") else { return false }
        let text = "---\ndescription: \(description.replacingOccurrences(of: "\n", with: " "))\n---\n" + body + "\n"
        let ok = (try? text.write(to: u, atomically: true, encoding: .utf8)) != nil
        m.touch()
        return ok
    }

    // MARK: 备份与回滚

    private var backupURL: URL { MemoryFS.shared.root.appendingPathComponent(".backup", isDirectory: true) }

    /// 做梦前把 notes、wiki、MEMORY.md 拷一份（只留最近一次）。
    private func backup() {
        let fm = FileManager.default
        let root = MemoryFS.shared.root
        try? fm.removeItem(at: backupURL)
        try? fm.createDirectory(at: backupURL, withIntermediateDirectories: true)
        for item in ["notes", "wiki", MemoryFS.indexName] {
            let from = root.appendingPathComponent(item)
            if fm.fileExists(atPath: from.path) { try? fm.copyItem(at: from, to: backupURL.appendingPathComponent(item)) }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "dreamBackup")
        UserDefaults.standard.set(Array(dreamed).sorted(), forKey: "dreamedDaysBackup")
        UserDefaults.standard.set(UserDefaults.standard.double(forKey: "lastDream"), forKey: "lastDreamBackup")
    }

    var canUndo: Bool { FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("wiki").path) }

    /// 撤销上一次做梦：恢复到做梦前的样子。
    func undo() {
        let fm = FileManager.default
        let root = MemoryFS.shared.root
        guard canUndo else { return }
        for item in ["notes", "wiki", MemoryFS.indexName] {
            let target = root.appendingPathComponent(item)
            let saved = backupURL.appendingPathComponent(item)
            try? fm.removeItem(at: target)
            if fm.fileExists(atPath: saved.path) { try? fm.copyItem(at: saved, to: target) }
        }
        try? fm.removeItem(at: backupURL)
        let d = UserDefaults.standard
        d.set(d.stringArray(forKey: "dreamedDaysBackup") ?? [], forKey: "dreamedDays")
        d.set(d.double(forKey: "lastDreamBackup"), forKey: "lastDream")
        MemoryFS.shared.touch()
    }
}
