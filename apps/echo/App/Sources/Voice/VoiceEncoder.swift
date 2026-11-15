import Foundation
import Accelerate
import AVFoundation

// MARK: - 声纹：GE2E 编码器（本机运行）
//
// 模型来自 Resemblyzer（Apache 2.0）自带的 GE2E 声纹编码器：40 维梅尔功率谱 → 3 层 LSTM(256) → 线性 + ReLU → L2 归一化的 256 维向量。
// 同一个人的两段声音向量很接近（余弦相似度高），不同人的很远。
// 权重由 apps/echo/voice/export.py 导出成 App/Resources/ge2e.bin；这里的计算和 voice/ge2e.py（已用真实语音验证过）逐行对应。
// 实测（DeepSeek 合成的两种声音，干净 / 加噪 / 远处带混响）：同一人 0.68–0.96，不同人 0.43–0.63。

final class VoiceEncoder {
    static let shared: VoiceEncoder? = VoiceEncoder()

    static let sampleRate = 16_000
    static let nfft = 400
    static let hop = 160
    static let bins = 201
    static let mels = 40
    static let hidden = 256
    /// 一个“片段”= 160 帧 = 1.6 秒
    static let window = 160

    private let melBasis: [Float]     // 40×201
    private let hann: [Float]         // 400
    private let cosM: [Float]         // 400×201
    private let sinM: [Float]         // 400×201
    private var wih: [[Float]] = []   // 1024×in
    private var whh: [[Float]] = []   // 1024×256
    private var bias: [[Float]] = []  // 1024
    private let linW: [Float]         // 256×256
    private let linB: [Float]         // 256

    init?() {
        guard let url = Bundle.main.url(forResource: "ge2e", withExtension: "bin"),
              let data = try? Data(contentsOf: url), data.count > 8,
              String(data: data.prefix(4), encoding: .ascii) == "GE2E" else { return nil }
        var floats = [Float](repeating: 0, count: (data.count - 8) / 4)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 8..<(8 + $0.count)) }
        var cursor = 0
        func take(_ n: Int) -> [Float] {
            let out = Array(floats[cursor..<cursor + n])
            cursor += n
            return out
        }
        let need = 40 * 201 + 400 + (1024 * 40 + 1024 * 256 + 1024) + 2 * (1024 * 256 + 1024 * 256 + 1024) + 256 * 256 + 256
        guard floats.count >= need else { return nil }
        melBasis = take(Self.mels * Self.bins)
        hann = take(Self.nfft)
        for layer in 0..<3 {
            let input = layer == 0 ? Self.mels : Self.hidden
            wih.append(take(1024 * input))
            whh.append(take(1024 * Self.hidden))
            bias.append(take(1024))
        }
        linW = take(Self.hidden * Self.hidden)
        linB = take(Self.hidden)
        // 实数 DFT 的余弦、负正弦矩阵（400×201）
        var c = [Float](repeating: 0, count: Self.nfft * Self.bins)
        var s = [Float](repeating: 0, count: Self.nfft * Self.bins)
        for n in 0..<Self.nfft {
            for k in 0..<Self.bins {
                let angle = 2 * Double.pi * Double(n * k) / Double(Self.nfft)
                c[n * Self.bins + k] = Float(cos(angle))
                s[n * Self.bins + k] = Float(-sin(angle))
            }
        }
        cosM = c
        sinM = s
    }

    // MARK: 梅尔功率谱（librosa.feature.melspectrogram 的默认做法：center=True、反射补边、汉宁窗、功率谱、不取对数）

    /// 返回 (帧数, 帧数×40 的行优先矩阵)
    func melSpectrogram(_ wav: [Float]) -> (Int, [Float]) {
        let pad = Self.nfft / 2
        guard wav.count > pad + 1 else { return (0, []) }
        var y = [Float](repeating: 0, count: wav.count + 2 * pad)
        for i in 0..<pad {
            y[pad - 1 - i] = wav[i + 1]                       // 左边反射（不含端点）
            y[pad + wav.count + i] = wav[wav.count - 2 - i]   // 右边反射
        }
        for i in 0..<wav.count { y[pad + i] = wav[i] }
        let frames = 1 + (y.count - Self.nfft) / Self.hop
        guard frames > 0 else { return (0, []) }
        var framed = [Float](repeating: 0, count: frames * Self.nfft)
        for f in 0..<frames {
            let base = f * Self.hop
            for n in 0..<Self.nfft { framed[f * Self.nfft + n] = y[base + n] * hann[n] }
        }
        var re = [Float](repeating: 0, count: frames * Self.bins)
        var im = [Float](repeating: 0, count: frames * Self.bins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.bins), Int32(Self.nfft),
                    1, framed, Int32(Self.nfft), cosM, Int32(Self.bins), 0, &re, Int32(Self.bins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.bins), Int32(Self.nfft),
                    1, framed, Int32(Self.nfft), sinM, Int32(Self.bins), 0, &im, Int32(Self.bins))
        var power = [Float](repeating: 0, count: frames * Self.bins)
        for i in 0..<power.count { power[i] = re[i] * re[i] + im[i] * im[i] }
        var mel = [Float](repeating: 0, count: frames * Self.mels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(Self.mels), Int32(Self.bins),
                    1, power, Int32(Self.bins), melBasis, Int32(Self.bins), 0, &mel, Int32(Self.mels))
        return (frames, mel)
    }

    // MARK: 一个 1.6 秒片段的声纹

    @inline(__always) private static func sigmoid(_ x: Float) -> Float { 1 / (1 + expf(-x)) }

    /// mel：整段的梅尔谱；start：片段起始帧；gain：音量增益（片段太小声时调到 -30 dBFS，与训练时一致）。
    func embed(mel: [Float], start: Int, gain: Float = 1) -> [Float]? {
        let T = Self.window
        guard start >= 0, (start + T) * Self.mels <= mel.count else { return nil }
        let g2 = gain * gain   // 功率谱随增益平方变化
        var x = [Float](repeating: 0, count: T * Self.mels)
        for i in 0..<x.count { x[i] = mel[start * Self.mels + i] * g2 }
        var input = Self.mels
        var h = [Float](repeating: 0, count: Self.hidden)
        for layer in 0..<3 {
            let H = Self.hidden
            var pre = [Float](repeating: 0, count: T * 4 * H)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(T), Int32(4 * H), Int32(input),
                        1, x, Int32(input), wih[layer], Int32(input), 0, &pre, Int32(4 * H))
            h = [Float](repeating: 0, count: H)
            var c = [Float](repeating: 0, count: H)
            var out = [Float](repeating: 0, count: T * H)
            var gates = [Float](repeating: 0, count: 4 * H)
            let b = bias[layer]
            for t in 0..<T {
                for j in 0..<(4 * H) { gates[j] = pre[t * 4 * H + j] + b[j] }
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * H), Int32(H), 1, whh[layer], Int32(H), h, 1, 1, &gates, 1)
                for j in 0..<H {   // 门的顺序：输入、遗忘、候选、输出
                    let ig = Self.sigmoid(gates[j])
                    let fg = Self.sigmoid(gates[H + j])
                    let gg = tanhf(gates[2 * H + j])
                    let og = Self.sigmoid(gates[3 * H + j])
                    c[j] = fg * c[j] + ig * gg
                    h[j] = og * tanhf(c[j])
                    out[t * H + j] = h[j]
                }
            }
            x = out
            input = H
        }
        var e = linB
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(Self.hidden), Int32(Self.hidden), 1, linW, Int32(Self.hidden), h, 1, 1, &e, 1)
        for i in 0..<e.count { e[i] = max(0, e[i]) }
        return Self.normalized(e)
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

    // MARK: 读音频：任意格式 → 16 kHz 单声道 Float

    static func loadMono16k(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: inBuffer) } catch { return nil }
        if src.sampleRate == Double(sampleRate), src.channelCount == 1, let ch = inBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: src, to: target) else { return nil }
        let ratio = Double(sampleRate) / src.sampleRate
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

    /// 一段采样的音量（dBFS）。
    static func dBFS(_ wav: [Float], from: Int, to: Int) -> Float {
        let a = max(0, from), b = min(wav.count, to)
        guard b > a else { return -120 }
        var ms: Float = 0
        wav.withUnsafeBufferPointer { p in
            vDSP_measqv(p.baseAddress! + a, 1, &ms, vDSP_Length(b - a))
        }
        return 10 * log10f(max(ms, 1e-12))
    }
}
