import Foundation

// MARK: - 唤醒
//
// 不在本机用词表、分数、阈值去猜“哪句话值得管”——那是在替模型做判断。
// 这里只做搬运：把上次醒来之后新听到的话（带上声纹/声音分类的标注）原样交给智能体，
// 由它决定要不要说、说什么，以及下次隔多久再来看（recheck_minutes）。
// 触发点：转写完一段、声纹做完、手机接力每 3 分钟、回到前台、到新地点、系统给后台时间。
// 是否真的醒来只看智能体自己定的下次时间；没到就把新话攒着，下次一起给。

@MainActor
final class Signals {
    static let shared = Signals()

    private var watermark: Date {
        get {
            let t = UserDefaults.standard.double(forKey: "signalsWatermark")
            return t > 0 ? Date(timeIntervalSince1970: t) : Date().addingTimeInterval(-1800)
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "signalsWatermark") }
    }

    /// force：真正的新事件（到了新地点），不等智能体定的下次时间。
    func scan(reason: String? = nil, force: Bool = false) async {
        guard !Store.isDemo, Proactive.enabled else { return }
        let store = Store.shared
        let now = Date()
        let analyzed = Set(store.db.segments.filter { $0.voice == true }.map(\.id))
        // 声纹还没做完的句子等一会儿（最多 4 分钟），让标注跟着一起给
        var fresh: [Line] = []
        for line in store.db.lines.filter({ $0.time > watermark }).sorted(by: { $0.time < $1.time }) {
            let ready = !VoiceAnalyzer.enabled || analyzed.contains(line.segmentID) || now.timeIntervalSince(line.time) > 240
            if !ready { break }
            fresh.append(line)
        }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        let voice = VoiceAnalyzer.shared
        let evidence = fresh.suffix(80).map { "\(hm.string(from: $0.time)) \(voice.prefix($0))\($0.text)" }
        let why = reason ?? (fresh.isEmpty ? "到了你上次说要再看一眼的时间" : "又听到了一些新的话")
        let ran = await Proactive.shared.consider(reason: why, evidence: evidence, force: force)
        if ran, let last = fresh.last { watermark = last.time }
    }
}
