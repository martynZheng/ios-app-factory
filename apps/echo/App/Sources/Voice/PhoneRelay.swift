import Foundation
import AVFoundation
import UIKit

// MARK: - 手机接力
//
// 手表没电、没戴、或者没在录的时候，手机接着录，录音不断档。
// iOS 只允许 App 在前台时打开麦克风，之后可以在后台一直录下去（系统会一直显示橙色的麦克风指示）；
// 不允许在后台自己打开麦克风。所以接力要你在手机上点一次“开启”，之后：
//   - 手表在录：手机待命（麦克风开着但不保存，什么都不留）；
//   - 手表停了：收不到手表的心跳超过 3 分钟、或手表说自己没电/停了，手机立刻开始保存，并发通知告诉你；
//   - 手表又开始录：手机回到待命。
// 手机录的分段和手表的一样进转写、声纹、整理，分段编号以 phone- 开头。

/// 音频会话的总开关：手机接力在录的时候，别的功能（朗读、回听、语音输入）不能把会话切成“只播放”或者关掉，
/// 否则麦克风会被停掉。
enum AudioGate {
    static var relayActive = false

    /// 边录边能放声音、不打断别的 App 的音乐。
    static func configureShared() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    /// 播放前调用：接力在录就保持录音会话，否则切到播放。
    static func preparePlayback() throws {
        if relayActive { try configureShared(); return }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    static func release() {
        guard !relayActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
final class PhoneRelay: NSObject, ObservableObject {
    static let shared = PhoneRelay()

    enum Mode: Equatable { case off, standby, recording }
    @Published private(set) var mode: Mode = .off {
        didSet { AudioGate.relayActive = mode != .off }
    }
    @Published private(set) var note: String?
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var watchRecording = false
    /// 上次是开着的、但 App 被系统关掉了：提醒你重新打开
    @Published var wasArmed = UserDefaults.standard.bool(forKey: "relayArmed")

    var active: Bool { mode != .off }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var fileID = ""
    private var sessionID = ""
    private var index = 0
    private var segmentStart = Date()
    private var segmentFrames: AVAudioFramePosition = 0
    private var voicedFrames: AVAudioFramePosition = 0
    private var timer: Timer?
    private var watchStopReason: String?

    static let segmentLength: AVAudioFramePosition = 60 * 16_000
    /// 多久收不到手表的心跳就接手
    static let silence: TimeInterval = 180

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    // MARK: 开关（只能在前台由你打开）

    func arm() {
        guard mode == .off else { return }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.note = "没有麦克风权限。到系统「设置 › 拾言 › 麦克风」打开。"
                    return
                }
                self.start()
            }
        }
    }

    func disarm() {
        closeSegment()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timer?.invalidate()
        timer = nil
        mode = .off
        wasArmed = false
        UserDefaults.standard.set(false, forKey: "relayArmed")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start() {
        do {
            try AudioGate.configureShared()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw NSError(domain: "Relay", code: 1, userInfo: [NSLocalizedDescriptionKey: "麦克风不可用"]) }
            converter = AVAudioConverter(from: format, to: target)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                Task { @MainActor in self.consume(buffer) }
            }
            engine.prepare()
            try engine.start()
            sessionID = "phone-" + UUID().uuidString
            index = 0
            mode = .standby
            note = nil
            wasArmed = true
            UserDefaults.standard.set(true, forKey: "relayArmed")
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.evaluate() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            evaluate()
        } catch {
            note = "开不了：\(error.localizedDescription)"
            mode = .off
        }
    }

    // MARK: 手表的心跳

    /// 手表每分钟报一次；手表传来录音分段也算。
    func heartbeat(recording: Bool, at: Date = Date(), reason: String? = nil) {
        if let last = lastHeartbeat, at < last { return }
        lastHeartbeat = at
        watchRecording = recording
        watchStopReason = recording ? nil : reason
        evaluate()
    }

    private var watchAlive: Bool {
        guard watchRecording, let last = lastHeartbeat else { return false }
        return Date().timeIntervalSince(last) < Self.silence
    }

    private func evaluate() {
        guard mode != .off else { return }
        if watchAlive {
            if mode == .recording {
                closeSegment()
                mode = .standby
                note = "手表回来了，手机回到待命"
            }
        } else if mode == .standby {
            mode = .recording
            let why: String
            switch watchStopReason {
            case "lowBattery": why = "手表快没电了"
            case "stopped": why = "手表停止了录音"
            default: why = lastHeartbeat == nil ? "手表没在录" : "收不到手表的信号"
            }
            note = "\(why)，手机接着录"
            Task { _ = await Pusher.now(title: "手机接着录了", body: "\(why)。手机在后台继续记录，手表恢复后会自动交回。") }
        }
    }

    // MARK: 写分段

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard mode == .recording, let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        if file == nil { openSegment() }
        guard let file else { return }
        do { try file.write(from: out) } catch {
            note = "写入失败：\(error.localizedDescription)"
            return
        }
        segmentFrames += AVAudioFramePosition(out.frameLength)
        if let ch = out.floatChannelData {
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            if VoiceEncoder.dBFS(samples, from: 0, to: samples.count) > -45 { voicedFrames += AVAudioFramePosition(out.frameLength) }
        }
        if segmentFrames >= Self.segmentLength {
            closeSegment()
        }
    }

    private func openSegment() {
        fileID = "\(sessionID)_\(index)"
        let url = Store.shared.audioURL(fileID)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        segmentStart = Date()
        segmentFrames = 0
        voicedFrames = 0
    }

    /// 结束当前分段：几乎没声音的丢掉（省转写），有声音的进转写队列。
    private func closeSegment() {
        guard file != nil else { return }
        file = nil   // 释放即写完文件
        let id = fileID
        let url = Store.shared.audioURL(id)
        let seconds = Double(segmentFrames) / 16_000
        index += 1
        if Double(voicedFrames) / 16_000 < 2 || seconds < 1 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        Store.shared.addSegment(Segment(id: id, sessionID: sessionID, index: index - 1, start: segmentStart, duration: seconds,
                                        hasAudio: true, status: .pending, error: nil))
        Transcriber.shared.kick()
    }

    // MARK: 被打断（来电、Siri）

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            guard self.mode != .off else { return }
            switch type {
            case .began:
                self.closeSegment()
            case .ended:
                do {
                    try AudioGate.configureShared()
                    if !self.engine.isRunning { try self.engine.start() }
                } catch {
                    self.note = "被打断后没能继续，打开拾言再点一次“开启”"
                    self.disarm()
                    self.wasArmed = true
                    UserDefaults.standard.set(true, forKey: "relayArmed")
                    _ = await Pusher.now(title: "手机接力停了", body: "被来电或其他声音打断后没能继续，打开拾言点一下就好。")
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func reset() {
        Task { @MainActor in
            guard self.mode != .off else { return }
            self.disarm()
            self.arm()
        }
    }

    var statusText: String {
        switch mode {
        case .off: return wasArmed ? "手机接力被系统关掉了，点一下重新开启" : "手表没电或没录时，手机接着录"
        case .standby: return "待命中：手表在录，手机不保存"
        case .recording: return note ?? "手机在录"
        }
    }
}
