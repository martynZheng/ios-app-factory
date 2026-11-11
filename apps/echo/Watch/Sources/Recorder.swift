import AVFoundation
import Foundation
import WatchKit

/// 手表录音器。
/// - 只在用户点「开始」后录音（watchOS 要求录音必须在前台由用户发起；之后可在后台继续）。
/// - AAC 单声道 16 kHz / 24 kbps：语音转写够用，约 11 MB/小时，编码走硬件、功耗低。
/// - 每 2 分钟切一个分段并立即入同步队列：崩溃/没电最多丢当前分段，传输单元也小。
/// - 暂停 = 结束当前分段并释放麦克风（系统录音指示随之消失），不会“假暂停”。
final class Recorder: NSObject, ObservableObject {
    enum State { case idle, recording, paused }

    @Published var state: State = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var level: Double = 0
    @Published var notice: String?
    @Published var skipSilence: Bool = UserDefaults.standard.bool(forKey: "skipSilence") {
        didSet { UserDefaults.standard.set(skipSilence, forKey: "skipSilence") }
    }

    static let segmentLength: TimeInterval = 120
    /// 能量门限（dBFS）。只用来丢弃“整段几乎没有声音”的分段，宁可多留也不漏对话。
    static let voiceThreshold: Float = -45

    private var recorder: AVAudioRecorder?
    private var sessionID = ""
    private var index = 0
    private var segmentStart = Date()
    private var voicedSeconds: Double = 0
    private var timer: Timer?
    private var ticks = 0
    private let tick: TimeInterval = 0.25

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }

    // MARK: 用户操作

    func start() {
        guard state == .idle else { return }
        if let problem = precheck() { notice = problem; return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.notice = "没有麦克风权限。请在手表「设置 › 隐私与安全性 › 麦克风」中允许。"
                    return
                }
                self.sessionID = UUID().uuidString
                self.index = 0
                self.elapsed = 0
                self.beginSegment(haptic: .start)
            }
        }
    }

    func pause() {
        guard state == .recording else { return }
        finishSegment(discard: false)
        deactivate()
        state = .paused
        WKInterfaceDevice.current().play(.click)
    }

    func resume() {
        guard state == .paused else { return }
        if let problem = precheck() { notice = problem; return }
        beginSegment(haptic: .start)
    }

    func stop() {
        guard state != .idle else { return }
        if state == .recording { finishSegment(discard: false) }
        deactivate()
        state = .idle
        WKInterfaceDevice.current().play(.stop)
    }

    /// 删除本次录音（含已同步到手机的部分）。
    func deleteCurrent() {
        guard state != .idle else { return }
        if state == .recording { finishSegment(discard: true) }
        deactivate()
        state = .idle
        Sync.shared.deleteSession(sessionID)
        WKInterfaceDevice.current().play(.failure)
        notice = "本次录音已删除"
    }

    // MARK: 分段

    private func precheck() -> String? {
        if Sync.shared.capturePaused { return "已在 iPhone 上暂停采集" }
        let battery = WKInterfaceDevice.current().batteryLevel
        if battery >= 0, battery < 0.10 { return "电量低于 10%，为保证手表可用，暂不录音" }
        if freeBytes() < 30_000_000 { return "手表存储空间不足，请先让录音同步到 iPhone" }
        return nil
    }

    private func freeBytes() -> Int64 {
        let values = try? Sync.shared.outbox.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map { Int64($0) } ?? Int64.max
    }

    private func beginSegment(haptic: WKHapticType?) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
            let url = Sync.shared.outbox.appendingPathComponent("\(sessionID)_\(index).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw NSError(domain: "Recorder", code: 1) }
            recorder = r
            segmentStart = Date()
            voicedSeconds = 0
            state = .recording
            startTimer()
            if let haptic { WKInterfaceDevice.current().play(haptic) }
        } catch {
            recorder = nil
            deactivate()
            if state == .recording { state = .paused }
            notice = "无法开始录音：\(error.localizedDescription)"
        }
    }

    private func finishSegment(discard: Bool) {
        timer?.invalidate()
        timer = nil
        guard let r = recorder else { return }
        let duration = r.currentTime
        let url = r.url
        r.stop()
        recorder = nil
        level = 0
        let silent = skipSilence && voicedSeconds < 2
        if discard || duration < 0.5 || silent {
            try? FileManager.default.removeItem(at: url)
        } else {
            Sync.shared.enqueue(url, meta: [
                Wire.sessionID: sessionID, Wire.index: index, Wire.start: segmentStart, Wire.duration: duration,
            ])
        }
        index += 1
    }

    private func deactivate() {
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: tick, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func onTick() {
        guard state == .recording, let r = recorder else { return }
        elapsed += tick
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        if db > Self.voiceThreshold { voicedSeconds += tick }
        level = Double(max(0, min(1, (db + 60) / 60)))
        ticks += 1
        if r.currentTime >= Self.segmentLength {
            finishSegment(discard: false)
            beginSegment(haptic: nil)
            return
        }
        if ticks % 40 == 0 { // 约每 10 秒检查一次电量和空间
            let battery = WKInterfaceDevice.current().batteryLevel
            if battery >= 0, battery < 0.10 {
                stop()
                notice = "电量低于 10%，已自动结束并保存录音"
            } else if freeBytes() < 15_000_000 {
                stop()
                notice = "存储空间不足，已自动结束并保存录音"
            }
        }
    }

    // MARK: 中断（来电、Siri 等）

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            switch type {
            case .began:
                guard self.state == .recording else { return }
                self.finishSegment(discard: false)
                self.state = .paused
                self.notice = "录音被系统中断，已保存到中断前。抬腕点「继续」恢复。"
                WKInterfaceDevice.current().play(.notification)
            case .ended:
                // watchOS 不允许在后台重新开始录音；只有 App 在前台时才自动恢复
                if self.state == .paused, WKApplication.shared().applicationState == .active {
                    self.resume()
                }
            @unknown default:
                break
            }
        }
    }
}
