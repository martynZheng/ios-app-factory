import AVFoundation
import SwiftUI

// MARK: - WAV

enum WAV {
    /// 把任意 16 位 PCM WAV 重写成最朴素的 44 字节文件头。
    /// 系统录出来的 WAV 带填充块；DeepSeek 流式合成的 WAV 长度字段是 0xFFFFFFFF，系统播放器不认。
    static func canonical(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 44, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 else { return nil }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        var offset = 12
        var channels = 1, rate = 16000, bits = 16
        var body: ArraySlice<UInt8>?
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            let start = offset + 8
            if id == "fmt ", start + 16 <= bytes.count {
                channels = u16(start + 2)
                rate = u32(start + 4)
                bits = u16(start + 14)
            }
            if id == "data" {
                let end = (size == 0 || start + size > bytes.count) ? bytes.count : start + size
                body = bytes[start..<end]
                break
            }
            if size > bytes.count { break }
            offset = start + size + (size % 2)
        }
        guard let body, !body.isEmpty, bits == 16, channels >= 1 else { return nil }
        var out = Data()
        func put32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; out.append(Data(bytes: &x, count: 2)) }
        out.append(Data("RIFF".utf8)); put32(36 + body.count)
        out.append(Data("WAVEfmt ".utf8)); put32(16); put16(1); put16(channels); put32(rate)
        put32(rate * channels * 2); put16(channels * 2); put16(16)
        out.append(Data("data".utf8)); put32(body.count)
        out.append(contentsOf: body)
        return out
    }
}

// MARK: - 说话输入

/// 点一下麦克风开始说，再点一下发送。录音只在你点了之后进行，界面上一直显示计时和电平。
/// 录成 16 kHz 单声道 16 位 WAV，交给 DeepSeek 语音识别（一次最长 120 秒）。
final class VoiceInput: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing }
    @Published var phase: Phase = .idle
    @Published var level: CGFloat = 0
    @Published var seconds = 0
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var started = Date()
    private var deliver: ((String) -> Void)?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-input.wav")
    static let limit: TimeInterval = 115

    func start(deliver: @escaping (String) -> Void) {
        guard phase == .idle else { return }
        error = nil
        guard Cloud.ready, Cloud.isDeepSeek else {
            error = "语音输入要用 DeepSeek 的语音识别，先接上 DeepSeek。"
            return
        }
        self.deliver = deliver
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { self.begin() } else { self.error = "没有麦克风权限。到系统「设置 › 拾言」里打开麦克风。" }
            }
        }
    }

    private func begin() {
        guard phase == .idle else { return }
        Speaker.shared.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            try? FileManager.default.removeItem(at: url)
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.limit) else {
                error = "麦克风现在用不了。"
                return
            }
            recorder = r
            started = Date()
            seconds = 0
            level = 0
            phase = .recording
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } catch {
            self.error = "开始录音失败：\(error.localizedDescription)"
        }
    }

    private func tick() {
        guard phase == .recording, let r = recorder else { return }
        if !r.isRecording {
            finish(send: true)
            return
        }
        r.updateMeters()
        let db = CGFloat(r.averagePower(forChannel: 0))
        let normalized = max(0, min(1, (db + 50) / 45))
        level = level * 0.55 + normalized * 0.45
        seconds = Int(Date().timeIntervalSince(started))
    }

    /// send = false：丢掉这段录音。
    func finish(send: Bool) {
        guard phase == .recording else { return }
        timer?.invalidate()
        timer = nil
        let length = Date().timeIntervalSince(started)
        recorder?.stop()
        recorder = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard send, length >= 0.6 else {
            if send { error = "说得太短了，再试一次。" }
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            return
        }
        phase = .transcribing
        let file = url
        let deliver = self.deliver
        Task {
            var text = ""
            var problem: String?
            do {
                guard let raw = try? Data(contentsOf: file), let wav = WAV.canonical(raw) else {
                    throw DigestError.unavailable("录音文件读不出来。")
                }
                text = try await Cloud.transcribe(wav: wav)
                if text.isEmpty { problem = "没听清，再说一次？" }
            } catch {
                problem = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: file)
            let heard = text
            let failed = problem
            DispatchQueue.main.async {
                self.phase = .idle
                self.error = failed
                if !heard.isEmpty { deliver?(heard) }
            }
        }
    }
}

// MARK: - 朗读

/// 朗读回答：优先 DeepSeek 语音合成（海星 / 暗潮），没接上或失败时退回系统语音（本机合成）。
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = Speaker()
    @Published var speaking = false
    @Published var loading = false
    /// 正在读哪条消息
    @Published var current: UUID?

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var job: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    static var voice: String { UserDefaults.standard.string(forKey: "ttsVoice") ?? "stella" }

    func toggle(_ text: String, id: UUID?) {
        if (speaking || loading) && current == id {
            stop()
        } else {
            speak(text, id: id)
        }
    }

    func stop() {
        job?.cancel()
        job = nil
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
        loading = false
        current = nil
    }

    func speak(_ text: String, id: UUID?) {
        stop()
        let plain = Self.readable(text)
        guard !plain.isEmpty else { return }
        current = id
        let voice = Self.voice
        guard voice != "system", Cloud.ready, Cloud.isDeepSeek else {
            system(plain)
            return
        }
        loading = true
        job = Task {
            var audio: Data?
            if let data = try? await Cloud.speech(plain, voice: voice) { audio = WAV.canonical(data) }
            if Task.isCancelled { return }
            let ready = audio
            DispatchQueue.main.async {
                guard self.current == id, self.loading else { return }
                self.loading = false
                if let ready, self.play(ready) { return }
                self.system(plain)
            }
        }
    }

    private func play(_ data: Data) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            guard p.play() else { return false }
            player = p
            speaking = true
            return true
        } catch {
            return false
        }
    }

    private func system(_ plain: String) {
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(utterance)
        speaking = true
    }

    /// 去掉链接地址和 Markdown 记号，只留能读出来的字。最多读 2500 字。
    static func readable(_ text: String) -> String {
        var s = text
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: "https?://\\S+") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        for mark in ["**", "*", "#", "`", "> "] { s = s.replacingOccurrences(of: mark, with: "") }
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2500))
    }

    private func finished() {
        DispatchQueue.main.async {
            self.speaking = false
            self.current = nil
            self.player = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished() }
}
