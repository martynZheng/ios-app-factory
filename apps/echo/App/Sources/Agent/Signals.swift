import Foundation

// MARK: - 唤醒信号
//
// 以前主动提醒只在“整理完一段”（攒够 1200 字或停顿 5 分钟）、到了新地点、系统给后台时间时才醒，
// 而且醒来只找“马上要开的会”这类事，所以一路开车一路抱怨不会被注意到。
// 现在每转写完一段就在本机过一遍（不联网、不花钱）：
//   - 我说“提醒我…”：马上唤醒；
//   - 抱怨、累、堵车、身体不舒服、答应了别人什么：在一个 20 分钟的窗口里攒分，够了就唤醒，把原话作为证据交给智能体；
//   - 一直在开车：长途本身加分，开太久哪怕没抱怨也醒一次。
// 词表在 App/Resources/signals.json，和 apps/echo/bench/ 的评测共用一份。

struct SignalConfig: Decodable {
    struct Kind: Decodable {
        var weight: Int
        var wake: String
        var words: [String]
    }
    struct Driving: Decodable {
        var long_minutes: Double
        var bonus: Int
        var long_alone_minutes: Double
    }
    var window_minutes: Double
    var threshold: Int
    var kinds: [String: Kind]
    var driving: Driving

    static let shared: SignalConfig? = {
        guard let url = Bundle.main.url(forResource: "signals", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SignalConfig.self, from: data)
    }()
}

@MainActor
final class Signals {
    static let shared = Signals()

    struct Hit {
        var time: Date
        var kind: String
        var wake: String
        var weight: Int
        var text: String
    }

    private var window: [Hit] = []
    private var watermark: Date {
        get {
            let t = UserDefaults.standard.double(forKey: "signalsWatermark")
            return t > 0 ? Date(timeIntervalSince1970: t) : Date().addingTimeInterval(-1800)
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "signalsWatermark") }
    }
    private var scanning = false

    /// 一句话里命中的信号（每类最多算一次）。
    static func hits(in text: String, config: SignalConfig) -> [(String, SignalConfig.Kind)] {
        var out: [(String, SignalConfig.Kind)] = []
        for name in config.kinds.keys.sorted() {
            guard let kind = config.kinds[name] else { continue }
            if kind.words.contains(where: { text.contains($0) }) { out.append((name, kind)) }
        }
        return out
    }

    /// 这句是不是我说的（背景人声、电视不算；别人说的也不算）。没做过声纹的当作可能是我。
    private static func mine(_ line: Line) -> Bool {
        if line.zone == "media" || line.zone == "far" { return false }
        if let s = line.speaker, s != "me" { return false }
        return true
    }

    /// 转写完、声纹做完、手机接力定时器、回到前台时调用。
    func scan() async {
        guard !scanning, let config = SignalConfig.shared, !Store.isDemo, Proactive.enabled else { return }
        scanning = true
        defer { scanning = false }
        let store = Store.shared
        let now = Date()
        let analyzed = Set(store.db.segments.filter { $0.voice == true }.map(\.id))
        let since = watermark
        // 声纹还没做完的句子先等一会儿（最多 4 分钟），免得把电视里的抱怨当成我说的
        var fresh: [Line] = []
        for line in store.db.lines.filter({ $0.time > since }).sorted(by: { $0.time < $1.time }) {
            let ready = !VoiceAnalyzer.enabled || analyzed.contains(line.segmentID) || now.timeIntervalSince(line.time) > 240
            if !ready { break }
            fresh.append(line)
        }
        if let last = fresh.last { watermark = last.time }

        var request: [Hit] = []
        for line in fresh where Self.mine(line) {
            for (name, kind) in Self.hits(in: line.text, config: config) {
                let hit = Hit(time: line.time, kind: name, wake: kind.wake, weight: kind.weight, text: line.text)
                if kind.wake == "request" { request.append(hit) } else { window.append(hit) }
            }
        }
        window.removeAll { now.timeIntervalSince($0.time) > config.window_minutes * 60 }

        let driving = await drivingMinutes()
        let drivingNote = driving >= config.driving.long_minutes ? "已经连续开车约 \(Int(driving)) 分钟" : nil

        if !request.isEmpty {
            await wake(kind: "request", hits: request, extra: drivingNote)
            return
        }
        var score = window.reduce(0) { $0 + $1.weight }
        if !window.isEmpty, drivingNote != nil { score += config.driving.bonus }
        if score >= config.threshold {
            let byWake = Dictionary(grouping: window, by: \.wake).mapValues { $0.reduce(0) { $0 + $1.weight } }
            let kind = byWake.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? "care"
            let hits = window
            window.removeAll()
            await wake(kind: kind, hits: hits, extra: drivingNote)
            return
        }
        // 开了很久的车，哪怕没抱怨，也醒一次看看（每段长途一次）
        if driving >= config.driving.long_alone_minutes {
            let d = UserDefaults.standard
            if now.timeIntervalSince1970 - d.double(forKey: "signalsLongDrive") > 3 * 3600 {
                d.set(now.timeIntervalSince1970, forKey: "signalsLongDrive")
                await wake(kind: "care", hits: [], extra: drivingNote)
            }
        }
    }

    private func wake(kind: String, hits: [Hit], extra: String?) async {
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        var evidence = hits.suffix(10).map { "\(hm.string(from: $0.time)) 我说：「\($0.text)」" }
        if let extra { evidence.append(extra) }
        let reason: String
        switch kind {
        case "request": reason = "我刚说了要你提醒我"
        case "commitment": reason = "我刚答应了别人一件事"
        default: reason = hits.isEmpty ? "我开了很久的车" : "我这阵子一直在抱怨、不舒服或者很累"
        }
        await Proactive.shared.consider(reason: reason, kind: kind, evidence: evidence)
    }

    /// 现在这段连续开车开了多久（没在开车就是 0）。
    private func drivingMinutes() async -> Double {
        let now = Date()
        let spans = await ContextSensor.shared.activities(from: now.addingTimeInterval(-4 * 3600), to: now)
        guard let last = spans.last, last.2 == .driving, now.timeIntervalSince(last.1) < 10 * 60 else { return 0 }
        // 中途等红灯、短暂停车（< 5 分钟）算同一段
        var start = last.0
        for span in spans.dropLast().reversed() {
            if span.2 == .driving || span.1.timeIntervalSince(span.0) < 5 * 60 { start = span.0 } else { break }
        }
        return now.timeIntervalSince(start) / 60
    }
}
