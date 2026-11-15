import Foundation
import AVFoundation
import SoundAnalysis
import SwiftUI

// MARK: - 谁在说话、是不是背景
//
// 每段录音转写完以后，在本机做三件事：
// 1. 声音分类（系统自带的 SoundAnalysis 分类器，300 多类）：每 0.5 秒判断是人声、电视音乐，还是环境噪声。
// 2. 声纹（VoiceEncoder，GE2E）：人声部分每 0.8 秒取一个 1.6 秒的片段算声纹向量。
//    先和“我”的声纹比（手表、手机各存一份，因为两种麦克风听到的同一个人不一样），像就是我；
//    不像就在“认识的声音”里找最像的人，都不像就记成一个新的声音（说话人 A、B……），你可以给它起名字。
// 3. 关注度：结合音量判断——我说的、近处在跟我说话的人、远处背景里的人声、电视音乐。
// 每一句转写按时间对上这些结果，带上 speaker 和 zone。整理和对话时，背景和电视里的话不会被当成我的事。
// 全部在本机算，音频不出手机。

/// 一个声音（一个人）。
struct SpeakerProfile: Codable, Identifiable {
    var id: String
    var name: String?
    var centroid: [Float]
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
    /// 按出现顺序的字母，没起名字时显示“说话人 A”
    var letter: String
}

struct VoiceBook: Codable {
    /// 我的声纹，按设备分开（watch / phone）
    var me: [String: [Float]] = [:]
    /// 我说话时的典型音量（dBFS），按设备
    var meLevel: [String: Float] = [:]
    var meSamples: [String: Int] = [:]
    var speakers: [SpeakerProfile] = []
    var nextLetter: Int = 0
}

@MainActor
final class VoiceAnalyzer: ObservableObject {
    static let shared = VoiceAnalyzer()
    @Published private(set) var book = VoiceBook()
    @Published private(set) var busy = false
    private let fileURL: URL

    /// 同一台设备上“是我”的门槛；跨设备（只有另一台设备的声纹时）放低一些
    static let meThreshold: Float = 0.74
    static let meCrossThreshold: Float = 0.66
    /// 归到已有的某个人
    static let speakerThreshold: Float = 0.76

    static var enabled: Bool { UserDefaults.standard.object(forKey: "voiceAnalysis") as? Bool ?? true }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Echo", isDirectory: true)
        fileURL = base.appendingPathComponent("voices.json")
        if !Store.isDemo, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(VoiceBook.self, from: data) {
            book = saved
        }
        if Store.isDemo {
            book.speakers = [SpeakerProfile(id: "demo-a", name: "二号选手", centroid: [], count: 20, firstSeen: Date(), lastSeen: Date(), letter: "A"),
                             SpeakerProfile(id: "demo-b", name: nil, centroid: [], count: 8, firstSeen: Date(), lastSeen: Date(), letter: "B")]
        }
    }

    private func save() {
        guard !Store.isDemo, let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var hasMe: Bool { !book.me.isEmpty }

    // MARK: 显示

    func label(_ speaker: String?) -> String? {
        guard let speaker else { return nil }
        if speaker == "me" { return "我" }
        guard let p = book.speakers.first(where: { $0.id == speaker }) else { return nil }
        return p.name ?? "说话人 \(p.letter)"
    }

    static func color(_ speaker: String?) -> Color {
        guard let speaker else { return Ink.ink3 }
        if speaker == "me" { return Ink.vermilion }
        let palette: [Color] = [Ink.indigo, Color(red: 0.16, green: 0.55, blue: 0.48), Color(red: 0.62, green: 0.36, blue: 0.80),
                                Color(red: 0.80, green: 0.50, blue: 0.16), Color(red: 0.25, green: 0.55, blue: 0.85)]
        var h = 0
        for u in speaker.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0xFFFF }
        return palette[h % palette.count]
    }

    /// 给整理和对话用的前缀：[我] [阿杰] [说话人 B] [背景] [电视/音乐]
    func prefix(_ line: Line) -> String {
        switch line.zone {
        case "media": return "[电视/音乐] "
        case "far": return "[背景] "
        default: break
        }
        guard let name = label(line.speaker) else { return "" }
        return "[\(name)] "
    }

    static func device(of segmentID: String) -> String {
        segmentID.hasPrefix("phone-") ? "phone" : "watch"
    }

    // MARK: 排队分析

    /// 转写完、还没分析过的分段，一段一段做（在后台线程算）。
    func kick() {
        guard Self.enabled, !busy, !Store.isDemo, VoiceEncoder.shared != nil else { return }
        let store = Store.shared
        guard let seg = store.db.segments.sorted(by: { $0.start < $1.start }).first(where: {
            $0.status == .done && $0.voice != true && $0.hasAudio
        }) else { return }
        let lines = store.db.lines.filter { $0.segmentID == seg.id }.sorted { $0.offset < $1.offset }
        let url = store.audioURL(seg.id)
        busy = true
        Task {
            let result = await Task.detached(priority: .utility) { Self.measure(url: url) }.value
            self.apply(result, segment: seg, lines: lines)
            self.busy = false
            self.kick()
        }
    }

    // MARK: 第一步：在后台线程把声音量出来

    struct Window {
        var start: Double
        var end: Double
        var level: Float
        var speech: Float
        var media: Float
        var embedding: [Float]?
    }

    struct Measurement {
        var windows: [Window]
        var duration: Double
    }

    private final class ClassObserver: NSObject, SNResultsObserving {
        var items: [(Double, Double, Float, Float)] = []   // 起止、人声置信度、电视音乐置信度
        private static let speechWords = ["speech", "conversation", "whisper", "shout", "yell", "babble", "laughter", "chatter", "narration"]
        private static let mediaWords = ["music", "singing", "television", "radio", "song", "guitar", "piano", "drum", "orchestra", "choir", "rapping", "dj"]
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            var speech: Float = 0, media: Float = 0
            for c in r.classifications {
                let id = c.identifier.lowercased()
                let conf = Float(c.confidence)
                if Self.speechWords.contains(where: { id.contains($0) }) { speech = max(speech, conf) }
                if Self.mediaWords.contains(where: { id.contains($0) }) { media = max(media, conf) }
            }
            items.append((r.timeRange.start.seconds, r.timeRange.start.seconds + r.timeRange.duration.seconds, speech, media))
        }
    }

    nonisolated static func measure(url: URL) -> Measurement? {
        guard let encoder = VoiceEncoder.shared, let wav = VoiceEncoder.loadMono16k(url), wav.count > 16_000 else { return nil }
        let duration = Double(wav.count) / Double(VoiceEncoder.sampleRate)
        // 声音分类
        let observer = ClassObserver()
        if let analyzer = try? SNAudioFileAnalyzer(url: url), let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            request.overlapFactor = 0.5
            if (try? analyzer.add(request, withObserver: observer)) != nil { analyzer.analyze() }
        }
        let classes = observer.items
        // 声纹
        let (frames, mel) = encoder.melSpectrogram(wav)
        var windows: [Window] = []
        var s = 0
        while s + VoiceEncoder.window <= frames {
            let t0 = Double(s) * 0.01, t1 = t0 + 1.6
            let level = VoiceEncoder.dBFS(wav, from: s * VoiceEncoder.hop, to: (s + VoiceEncoder.window) * VoiceEncoder.hop)
            var speech: Float = 0, media: Float = 0, n: Float = 0
            for c in classes where c.1 > t0 && c.0 < t1 {
                speech += c.2
                media += c.3
                n += 1
            }
            if n > 0 { speech /= n; media /= n } else { speech = level > -45 ? 0.5 : 0 }
            var w = Window(start: t0, end: t1, level: level, speech: speech, media: media, embedding: nil)
            // 只给像人声、而且不是太小声的片段算声纹
            if speech >= 0.3, level > -52 {
                let gain = level < -30 ? powf(10, (-30 - level) / 20) : 1
                w.embedding = encoder.embed(mel: mel, start: s, gain: gain)
            }
            windows.append(w)
            s += 80
        }
        return Measurement(windows: windows, duration: duration)
    }

    // MARK: 第二步：认人、给每句打标签

    private func meSimilarity(_ e: [Float], device: String) -> Float? {
        if let mine = book.me[device] { return VoiceEncoder.cosine(e, mine) }
        if let other = book.me.values.first {
            // 只有另一台设备的声纹：放宽门槛（换算到同一刻度）
            return VoiceEncoder.cosine(e, other) + (Self.meThreshold - Self.meCrossThreshold)
        }
        return nil
    }

    private func assignSpeaker(_ e: [Float], at time: Date) -> String {
        var best: (Int, Float)?
        for (i, p) in book.speakers.enumerated() where !p.centroid.isEmpty {
            let sim = VoiceEncoder.cosine(e, p.centroid)
            if sim > (best?.1 ?? -1) { best = (i, sim) }
        }
        if let (i, sim) = best, sim >= Self.speakerThreshold {
            var p = book.speakers[i]
            let w = 1 / Float(min(p.count + 1, 50))
            p.centroid = VoiceEncoder.normalized(zip(p.centroid, e).map { $0 * (1 - w) + $1 * w }) ?? p.centroid
            p.count += 1
            p.lastSeen = time
            book.speakers[i] = p
            return p.id
        }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let letter = String(letters[book.nextLetter % letters.count]) + (book.nextLetter >= letters.count ? "\(book.nextLetter / letters.count)" : "")
        book.nextLetter += 1
        let p = SpeakerProfile(id: UUID().uuidString, name: nil, centroid: e, count: 1, firstSeen: time, lastSeen: time, letter: letter)
        book.speakers.append(p)
        return p.id
    }

    private func apply(_ m: Measurement?, segment: Segment, lines: [Line]) {
        let store = Store.shared
        guard let m else {
            store.updateSegment(segment.id) { $0.voice = true }
            return
        }
        let device = Self.device(of: segment.id)
        // 每个片段：是我 / 某个人
        var who: [Int: String] = [:]
        for (i, w) in m.windows.enumerated() {
            guard let e = w.embedding else { continue }
            let time = segment.start.addingTimeInterval(w.start)
            if let sim = meSimilarity(e, device: device), sim >= Self.meThreshold {
                who[i] = "me"
                // 很确定是我、而且是近处的声音：慢慢校准这台设备上的“我”
                if sim >= Self.meThreshold + 0.06 { learnMe(e, level: w.level, device: device) }
            } else {
                who[i] = assignSpeaker(e, at: time)
            }
        }
        let myLevel = book.meLevel[device] ?? -30
        var updated: [Line] = []
        for (k, line) in lines.enumerated() {
            let a = line.offset
            let b = k + 1 < lines.count ? max(lines[k + 1].offset, a + 0.5) : min(m.duration, a + 8)
            var votes: [String: Double] = [:]
            var level: Float = -120, speech: Float = 0, media: Float = 0, n: Float = 0
            for (i, w) in m.windows.enumerated() where w.end > a && w.start < b {
                let overlap = min(w.end, b) - max(w.start, a)
                if let id = who[i] { votes[id, default: 0] += overlap }
                level = max(level, w.level)
                speech += w.speech
                media += w.media
                n += 1
            }
            if n > 0 { speech /= n; media /= n }
            var l = line
            l.speaker = votes.max { $0.value < $1.value }?.key
            if media >= 0.5 && media > speech {
                l.zone = "media"
            } else if l.speaker == "me" {
                l.zone = "me"
            } else if level >= max(-40, myLevel - 14) {
                l.zone = "near"
            } else if n > 0 {
                l.zone = "far"
            }
            updated.append(l)
        }
        store.mutate { db in
            for l in updated {
                if let i = db.lines.firstIndex(where: { $0.id == l.id }) {
                    db.lines[i].speaker = l.speaker
                    db.lines[i].zone = l.zone
                }
            }
            if let i = db.segments.firstIndex(where: { $0.id == segment.id }) { db.segments[i].voice = true }
        }
        prune()
        save()
    }

    private func learnMe(_ e: [Float], level: Float, device: String) {
        let n = book.meSamples[device] ?? 0
        if let old = book.me[device] {
            let w: Float = 1 / Float(min(n + 1, 200))
            book.me[device] = VoiceEncoder.normalized(zip(old, e).map { $0 * (1 - w) + $1 * w }) ?? old
        } else {
            book.me[device] = e
        }
        let oldLevel = book.meLevel[device] ?? level
        book.meLevel[device] = oldLevel * 0.95 + level * 0.05
        book.meSamples[device] = n + 1
    }

    /// 没起名字、只出现过几次、两周没再出现的声音，清掉。
    private func prune() {
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        book.speakers.removeAll { $0.name == nil && $0.count < 20 && $0.lastSeen < cutoff }
    }

    // MARK: 你来纠正

    /// 声纹（取这一句所在的音频范围重新算）。
    private func embedding(of line: Line) async -> [Float]? {
        let store = Store.shared
        guard let seg = store.segment(line.segmentID), seg.hasAudio else { return nil }
        let url = store.audioURL(seg.id)
        let lines = store.db.lines.filter { $0.segmentID == seg.id }.sorted { $0.offset < $1.offset }
        let next = lines.first(where: { $0.offset > line.offset })?.offset ?? (line.offset + 6)
        let a = line.offset, b = max(next, a + 1.6)
        return await Task.detached(priority: .userInitiated) { () -> [Float]? in
            guard let encoder = VoiceEncoder.shared, let wav = VoiceEncoder.loadMono16k(url) else { return nil }
            let (frames, mel) = encoder.melSpectrogram(wav)
            var sum = [Float](repeating: 0, count: VoiceEncoder.hidden)
            var count = 0
            var s = Int(a * 100)
            while s + VoiceEncoder.window <= min(frames, Int(b * 100) + 40) {
                let level = VoiceEncoder.dBFS(wav, from: s * VoiceEncoder.hop, to: (s + VoiceEncoder.window) * VoiceEncoder.hop)
                let gain = level < -30 ? powf(10, (-30 - level) / 20) : 1
                if let e = encoder.embed(mel: mel, start: s, gain: gain) {
                    for i in 0..<sum.count { sum[i] += e[i] }
                    count += 1
                }
                s += 80
            }
            return count > 0 ? VoiceEncoder.normalized(sum) : nil
        }.value
    }

    /// “这句是我说的”：用它校准我的声纹，并把同一个声音的句子都改成“我”。
    func markMe(_ line: Line) async {
        guard let e = await embedding(of: line) else { return }
        let device = Self.device(of: line.segmentID)
        for _ in 0..<10 { learnMe(e, level: -30, device: device) }
        let old = line.speaker
        Store.shared.mutate { db in
            for i in db.lines.indices where db.lines[i].id == line.id || (old != nil && old != "me" && db.lines[i].speaker == old) {
                db.lines[i].speaker = "me"
                db.lines[i].zone = "me"
            }
        }
        if let old, old != "me" { book.speakers.removeAll { $0.id == old } }
        save()
    }

    /// 给这个声音起名字（之后在任何一天认出来都会显示这个名字）。
    func name(_ line: Line, as name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let id = line.speaker, id != "me", let i = book.speakers.firstIndex(where: { $0.id == id }) {
            // 同名的合并成一个人
            if let j = book.speakers.firstIndex(where: { $0.name == clean && $0.id != id }) {
                let keep = book.speakers[j].id
                book.speakers[j].centroid = VoiceEncoder.normalized(zip(book.speakers[j].centroid, book.speakers[i].centroid).map { $0 + $1 }) ?? book.speakers[j].centroid
                book.speakers[j].count += book.speakers[i].count
                book.speakers.remove(at: i)
                Store.shared.mutate { db in
                    for k in db.lines.indices where db.lines[k].speaker == id { db.lines[k].speaker = keep }
                }
            } else {
                book.speakers[i].name = clean
            }
            save()
            return
        }
        guard let e = await embedding(of: line) else { return }
        let id = UUID().uuidString
        book.speakers.append(SpeakerProfile(id: id, name: clean, centroid: e, count: 1, firstSeen: Date(), lastSeen: Date(), letter: "?"))
        Store.shared.mutate { db in
            if let i = db.lines.firstIndex(where: { $0.id == line.id }) {
                db.lines[i].speaker = id
                if db.lines[i].zone == "me" { db.lines[i].zone = "near" }
            }
        }
        save()
    }

    func rename(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = book.speakers.firstIndex(where: { $0.id == id }) else { return }
        book.speakers[i].name = clean.isEmpty ? nil : clean
        save()
    }

    /// 录一段我自己的声音（设置里的“我的声音”）。
    func enroll(samples: [Float], device: String) -> Bool {
        guard let encoder = VoiceEncoder.shared else { return false }
        let (frames, mel) = encoder.melSpectrogram(samples)
        var sum = [Float](repeating: 0, count: VoiceEncoder.hidden)
        var count = 0
        var levels: [Float] = []
        var s = 0
        while s + VoiceEncoder.window <= frames {
            let level = VoiceEncoder.dBFS(samples, from: s * VoiceEncoder.hop, to: (s + VoiceEncoder.window) * VoiceEncoder.hop)
            if level > -50 {
                let gain = level < -30 ? powf(10, (-30 - level) / 20) : 1
                if let e = encoder.embed(mel: mel, start: s, gain: gain) {
                    for i in 0..<sum.count { sum[i] += e[i] }
                    count += 1
                    levels.append(level)
                }
            }
            s += 80
        }
        guard count >= 5, let me = VoiceEncoder.normalized(sum) else { return false }
        book.me[device] = me
        book.meSamples[device] = count
        book.meLevel[device] = levels.sorted()[levels.count / 2]
        // 手表上还没有：先用手机的（门槛会放宽），之后用手表录到的声音自己校准
        save()
        // 以前分析过的重新分析一遍
        Store.shared.mutate { db in for i in db.segments.indices { db.segments[i].voice = nil } }
        kick()
        return true
    }

    func forgetAll() {
        book = VoiceBook()
        save()
        Store.shared.mutate { db in
            for i in db.lines.indices { db.lines[i].speaker = nil; db.lines[i].zone = nil }
            for i in db.segments.indices { db.segments[i].voice = nil }
        }
    }
}
