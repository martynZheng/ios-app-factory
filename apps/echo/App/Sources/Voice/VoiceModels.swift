import Foundation
import Accelerate
import AVFoundation
import OnnxRuntimeBindings

// MARK: - 本机的声音模型（ONNX Runtime）
//
// - 声纹：3D-Speaker CAM++（阿里通义实验室，Apache 2.0，中英文 20 万人训练），输入 80 维 Kaldi Fbank，输出 192 维声纹。
// - 分段：pyannote segmentation-3.0（CNRS，MIT），输入 10 秒原始波形，输出约 589 帧 × 7 类（powerset：没人、1、2、3、1+2、1+3、2+3），
//   能看出谁在什么时候说话、两人是否同时在说。
// 模型文件来自 k2-fsa/sherpa-onnx 转好的 ONNX（App/Resources/campplus.onnx、segmentation.onnx），来源与验证脚本见 apps/echo/voice/。
// 实测（DeepSeek 合成的两种声音，干净 / 加噪 / 远处混响混在一起比）：同一人 ≥ 0.49，不同人 ≤ 0.35，没有重叠。

enum Audio16k {
    static let rate = 16_000

    /// 任意格式 → 16 kHz 单声道 Float（-1…1）
    static func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: inBuffer) } catch { return nil }
        if src.sampleRate == Double(rate), src.channelCount == 1, let ch = inBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: src, to: target) else { return nil }
        let ratio = Double(rate) / src.sampleRate
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, let ch = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuffer.frameLength)))
    }

    /// 一段采样的音量（dBFS）
    static func dBFS(_ wav: [Float], from: Int, to: Int) -> Float {
        let a = max(0, from), b = min(wav.count, to)
        guard b > a else { return -120 }
        var ms: Float = 0
        wav.withUnsafeBufferPointer { p in
            vDSP_measqv(p.baseAddress! + a, 1, &ms, vDSP_Length(b - a))
        }
        return 10 * log10f(max(ms, 1e-12))
    }

    static func normalized(_ v: [Float]) -> [Float]? {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrtf(norm)
        guard norm > 1e-6 else { return nil }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}

// MARK: - Kaldi Fbank（和 kaldi-native-fbank 默认设置一致，已在 voice/pipe.py 里比对过，最大误差 7e-4）
//
// 25 ms 帧、10 ms 帧移、snip_edges、去直流、预加重 0.97、Povey 窗、512 点 FFT 功率谱、20 Hz–8 kHz 的 80 个梅尔滤波器、取 log。

final class Fbank {
    static let shared = Fbank()
    static let frameLength = 400
    static let shift = 160
    static let nfft = 512
    static let bins = 257
    static let mels = 80

    private let window: [Float]
    private let cosM: [Float]   // 400×257
    private let sinM: [Float]   // 400×257
    private let melW: [Float]   // 80×257

    private static func mel(_ f: Double) -> Double { 1127.0 * log(1.0 + f / 700.0) }

    init() {
        let N = Self.frameLength
        window = (0..<N).map { i in Float(pow(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(N - 1)), 0.85)) }
        var c = [Float](repeating: 0, count: N * Self.bins)
        var s = [Float](repeating: 0, count: N * Self.bins)
        for n in 0..<N {
            for k in 0..<Self.bins {
                let angle = 2 * Double.pi * Double(n * k) / Double(Self.nfft)
                c[n * Self.bins + k] = Float(cos(angle))
                s[n * Self.bins + k] = Float(-sin(angle))
            }
        }
        cosM = c
        sinM = s
        var w = [Float](repeating: 0, count: Self.mels * Self.bins)
        let lo = Self.mel(20), hi = Self.mel(8000)
        let delta = (hi - lo) / Double(Self.mels + 1)
        let binHz = 16_000.0 / Double(Self.nfft)
        for b in 0..<Self.mels {
            let l = lo + Double(b) * delta, center = lo + Double(b + 1) * delta, r = lo + Double(b + 2) * delta
            for k in 0..<(Self.nfft / 2) {   // Kaldi 不用奈奎斯特频点
                let m = Self.mel(binHz * Double(k))
                if m > l && m < r {
                    w[b * Self.bins + k] = Float(m <= center ? (m - l) / (center - l) : (r - m) / (r - center))
                }
            }
        }
        melW = w
    }

    /// 返回 (帧数, 帧数×80 行优先)
    func compute(_ wav: [Float], from: Int = 0, to: Int? = nil) -> (Int, [Float]) {
        let end = min(to ?? wav.count, wav.count)
        let count = end - from
        let N = Self.frameLength
        guard count >= N else { return (0, []) }
        let frames = 1 + (count - N) / Self.shift
        var framed = [Float](repeating: 0, count: frames * N)
        for f in 0..<frames {
            let base = from + f * Self.shift
            var mean: Float = 0
            for i in 0..<N { mean += wav[base + i] }
            mean /= Float(N)
            var x = [Float](repeating: 0, count: N)
            for i in 0..<N { x[i] = wav[base + i] - mean }
            var i = N - 1
            while i > 0 {
                x[i] -= 0.97 * x[i - 1]
                i -= 1
            }
            x[0] -= 0.97 * x[0]
            for i in 0..<N { framed[f * N + i] = x[i] * window[i] }
        }
        var re = [Float](repeating: 0, count: frames * Self.bins)
        var im = [Float](repeating: 0, count: frames * Self.bins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.bins), Int32(N),
                    1, framed, Int32(N), cosM, Int32(Self.bins), 0, &re, Int32(Self.bins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.bins), Int32(N),
                    1, framed, Int32(N), sinM, Int32(Self.bins), 0, &im, Int32(Self.bins))
        var power = [Float](repeating: 0, count: frames * Self.bins)
        for i in 0..<power.count { power[i] = re[i] * re[i] + im[i] * im[i] }
        var out = [Float](repeating: 0, count: frames * Self.mels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(Self.mels), Int32(Self.bins),
                    1, power, Int32(Self.bins), melW, Int32(Self.bins), 0, &out, Int32(Self.mels))
        let floor = Float.ulpOfOne
        for i in 0..<out.count { out[i] = logf(max(out[i], floor)) }
        return (frames, out)
    }
}

// MARK: - ONNX 模型

final class OnnxModel {
    private static let env: ORTEnv? = try? ORTEnv(loggingLevel: ORTLoggingLevel.warning)
    private let session: ORTSession
    private let input: String
    private let output: String

    init?(resource: String, input: String, output: String) {
        guard let env = Self.env, let path = Bundle.main.path(forResource: resource, ofType: "onnx") else { return nil }
        do {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
        } catch {
            return nil
        }
        self.input = input
        self.output = output
    }

    func run(_ data: [Float], shape: [Int]) -> [Float]? {
        let bytes = NSMutableData(length: data.count * MemoryLayout<Float>.size) ?? NSMutableData()
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { bytes.replaceBytes(in: NSRange(location: 0, length: raw.count), withBytes: base) }
        }
        do {
            let value = try ORTValue(tensorData: bytes, elementType: ORTTensorElementDataType.float, shape: shape.map { NSNumber(value: $0) })
            let outputs = try session.run(withInputs: [input: value], outputNames: [output], runOptions: nil)
            guard let out = outputs[output] else { return nil }
            let result = try out.tensorData() as Data
            var floats = [Float](repeating: 0, count: result.count / MemoryLayout<Float>.size)
            _ = floats.withUnsafeMutableBytes { result.copyBytes(to: $0) }
            return floats
        } catch {
            return nil
        }
    }
}

/// 声纹：CAM++
final class SpeakerEmbedder {
    static let shared: SpeakerEmbedder? = SpeakerEmbedder()
    static let dims = 192
    private let model: OnnxModel

    init?() {
        guard let m = OnnxModel(resource: "campplus", input: "x", output: "embedding") else { return nil }
        model = m
    }

    /// 一段采样的声纹（至少约 0.3 秒）。做法与 voice/pipe.py 一致：Fbank → 减去全局均值 → CAM++ → L2 归一化。
    func embed(_ wav: [Float], from: Int = 0, to: Int? = nil) -> [Float]? {
        let (frames, feats) = Fbank.shared.compute(wav, from: from, to: to)
        guard frames >= 30 else { return nil }
        var x = feats
        for d in 0..<Fbank.mels {
            var mean: Float = 0
            for t in 0..<frames { mean += x[t * Fbank.mels + d] }
            mean /= Float(frames)
            for t in 0..<frames { x[t * Fbank.mels + d] -= mean }
        }
        guard let e = model.run(x, shape: [1, frames, Fbank.mels]), e.count == Self.dims else { return nil }
        return Audio16k.normalized(e)
    }

    /// 把几段采样拼起来再算（同一个人在一窗里断断续续说的话）
    func embed(pieces: [(Int, Int)], of wav: [Float]) -> [Float]? {
        var joined: [Float] = []
        for (a, b) in pieces where b > a { joined.append(contentsOf: wav[max(0, a)..<min(wav.count, b)]) }
        return embed(joined)
    }
}

/// 分段：pyannote segmentation-3.0
final class SpeakerSegmenter {
    static let shared: SpeakerSegmenter? = SpeakerSegmenter()
    static let window = 160_000
    static let shift = 270
    static let field = 991
    private static let powerset: [[Int]] = [[], [0], [1], [2], [0, 1], [0, 2], [1, 2]]
    private let model: OnnxModel

    init?() {
        guard let m = OnnxModel(resource: "segmentation", input: "x", output: "y") else { return nil }
        model = m
    }

    /// 10 秒（不够补零）→ 每帧 3 个局部说话人是否在说（帧数×3，行优先）
    func run(_ wav: [Float], from: Int) -> (Int, [Bool])? {
        var x = [Float](repeating: 0, count: Self.window)
        let n = min(Self.window, wav.count - from)
        guard n > 0 else { return nil }
        for i in 0..<n { x[i] = wav[from + i] }
        guard let y = model.run(x, shape: [1, 1, Self.window]), y.count % 7 == 0 else { return nil }
        let frames = y.count / 7
        var act = [Bool](repeating: false, count: frames * 3)
        for t in 0..<frames {
            var best = 0
            for c in 1..<7 where y[t * 7 + c] > y[t * 7 + best] { best = c }
            for k in Self.powerset[best] { act[t * 3 + k] = true }
        }
        return (frames, act)
    }

    static func frameTime(_ i: Int) -> Double { (Double(i * shift) + Double(field) / 2) / 16_000 }
}
