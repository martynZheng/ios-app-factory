import Foundation

enum SegStatus: String, Codable { case pending, done, failed, noSpeech, blocked }

/// 一段录音（手表上约 2 分钟一段）。
struct Segment: Codable, Identifiable {
    var id: String
    var sessionID: String
    var index: Int
    var start: Date
    var duration: Double
    var hasAudio: Bool
    var status: SegStatus
    var error: String?
}

/// 一句转写。time 是绝对时间，offset 是在所属分段音频里的秒数。
struct Line: Codable, Identifiable {
    var id: UUID
    var segmentID: String
    var time: Date
    var offset: Double
    var text: String
    var edited: Bool
}

enum ItemKind: String, Codable { case point, decision, todo, pending }

/// 回顾条目。每条都必须能指回原始转写（sourceLineIDs 非空），否则不会生成。
struct DigestItem: Codable, Identifiable {
    var id: UUID
    var kind: ItemKind
    var text: String
    var owner: String?
    var due: String?
    var dueDate: Date?
    var sourceLineIDs: [UUID]
    var done: Bool
    var exported: Bool
    var chapterID: UUID? = nil
}

/// 一章 = 一段连续的话题（一位选手的路演、一个议题、一次闲聊）。鱼骨图上的一根骨头。
struct Chapter: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var summary: String
    var speaker: String?
    var start: Date
    var end: Date
    var sourceLineIDs: [UUID]
}

struct Digest: Codable {
    var day: String
    var stats: String
    var items: [DigestItem]
    var generatedAt: Date
    var engine: String
    var lineCount: Int
    /// 已经整理过的转写句（增量整理用）
    var processed: [UUID]? = nil
    var chapters: [Chapter]? = nil
    /// 模型判断出的场合（如“AI 大赛路演，我是主持人”）
    var scene: String? = nil
}

struct DB: Codable {
    var segments: [Segment] = []
    var lines: [Line] = []
    var digests: [String: Digest] = [:]
    var deletedSessions: [String] = []
    /// 用户给某一天写的一句背景
    var dayContext: [String: String]? = nil
}

/// 本地存储：一个 JSON 数据库 + 音频目录，都放在 Application Support，
/// 使用 iOS 数据保护（设备首次解锁后可读，以便后台接收手表文件；设备锁定且未解锁过时为密文）。
final class Store: ObservableObject {
    static let shared = Store()
    /// 演示模式（-demo 1）：内存里的示例数据，不读写磁盘。CI 截图自测用。
    static let isDemo = UserDefaults.standard.bool(forKey: "demo")

    @Published private(set) var db = DB()
    let audioDir: URL
    private let dbURL: URL
    private var saveScheduled = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(fromDayKey key: String) -> Date { dayFormatter.date(from: key) ?? Date() }

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        audioDir = base.appendingPathComponent("Audio", isDirectory: true)
        dbURL = base.appendingPathComponent("db.json")
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true, attributes: attrs)
        if !Store.isDemo, let data = try? Data(contentsOf: dbURL), let loaded = try? JSONDecoder().decode(DB.self, from: data) {
            db = loaded
        }
    }

    func mutate(_ change: (inout DB) -> Void) {
        change(&db)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.saveNow() }
    }

    func saveNow() {
        saveScheduled = false
        guard !Store.isDemo else { return }
        guard let data = try? JSONEncoder().encode(db) else { return }
        try? data.write(to: dbURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: 查询

    func audioURL(_ segmentID: String) -> URL { audioDir.appendingPathComponent(segmentID + ".m4a") }
    func segment(_ id: String) -> Segment? { db.segments.first { $0.id == id } }
    func line(_ id: UUID) -> Line? { db.lines.first { $0.id == id } }

    func lines(on day: String) -> [Line] {
        db.lines.filter { Store.dayKey($0.time) == day }.sorted { $0.time < $1.time }
    }

    func segments(on day: String) -> [Segment] {
        db.segments.filter { Store.dayKey($0.start) == day }
    }

    var storageBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: 写入

    func addSegment(_ seg: Segment) {
        mutate { db in
            db.segments.removeAll { $0.id == seg.id }
            db.segments.append(seg)
        }
    }

    func updateSegment(_ id: String, _ change: (inout Segment) -> Void) {
        mutate { db in
            if let i = db.segments.firstIndex(where: { $0.id == id }) { change(&db.segments[i]) }
        }
    }

    func setLines(_ lines: [Line], for segmentID: String) {
        mutate { db in
            db.lines.removeAll { $0.segmentID == segmentID }
            db.lines.append(contentsOf: lines)
        }
    }

    func editLine(_ id: UUID, text: String) {
        mutate { db in
            if let i = db.lines.firstIndex(where: { $0.id == id }) {
                db.lines[i].text = text
                db.lines[i].edited = true
            }
        }
    }

    func deleteLine(_ id: UUID) {
        mutate { db in db.lines.removeAll { $0.id == id } }
    }

    func deleteSegments(_ ids: [String]) {
        for id in ids { try? FileManager.default.removeItem(at: audioURL(id)) }
        let set = Set(ids)
        mutate { db in
            db.segments.removeAll { set.contains($0.id) }
            db.lines.removeAll { set.contains($0.segmentID) }
        }
    }

    func deleteSession(_ sessionID: String, tombstone: Bool) {
        let ids = db.segments.filter { $0.sessionID == sessionID }.map { $0.id }
        deleteSegments(ids)
        if tombstone {
            mutate { db in
                db.deletedSessions.append(sessionID)
                if db.deletedSessions.count > 200 { db.deletedSessions.removeFirst(db.deletedSessions.count - 200) }
            }
        }
    }

    func setDayContext(_ text: String, day: String) {
        mutate { db in
            var all = db.dayContext ?? [:]
            all[day] = text
            db.dayContext = all
        }
    }

    func setDigest(_ digest: Digest) {
        mutate { db in db.digests[digest.day] = digest }
    }

    func updateItem(day: String, id: UUID, _ change: (inout DigestItem) -> Void) {
        mutate { db in
            guard var d = db.digests[day], let i = d.items.firstIndex(where: { $0.id == id }) else { return }
            change(&d.items[i])
            db.digests[day] = d
        }
    }

    func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
        mutate { db in db = DB() }
        saveNow()
    }

    /// 自动清理：删除超过保留期的音频（文字保留），days <= 0 表示不清理。
    func cleanupAudio(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = db.segments.filter { $0.hasAudio && $0.start < cutoff && $0.status != .pending }.map { $0.id }
        guard !old.isEmpty else { return }
        for id in old { try? FileManager.default.removeItem(at: audioURL(id)) }
        let set = Set(old)
        mutate { db in
            for i in db.segments.indices where set.contains(db.segments[i].id) { db.segments[i].hasAudio = false }
        }
    }

    /// 导出全部转写与回顾为纯文本文件。
    func exportFile() -> URL? {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var out = "拾言导出 \(Date())\n"
        let days = Set(db.lines.map { Store.dayKey($0.time) }).sorted()
        for day in days {
            out += "\n===== \(day) =====\n"
            if let d = db.digests[day] {
                out += "[回顾 · \(d.engine)] \(d.stats)\n"
                for item in d.items {
                    out += "- (\(item.kind.rawValue)) \(item.text)"
                    if let o = item.owner { out += " 负责人:\(o)" }
                    if let due = item.due { out += " 截止:\(due)" }
                    out += "\n"
                }
                out += "\n"
            }
            for l in lines(on: day) { out += "\(time.string(from: l.time))  \(l.text)\n" }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("拾言导出-\(Store.dayKey(Date())).txt")
        do {
            try out.data(using: .utf8)?.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch { return nil }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
