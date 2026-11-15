import SwiftUI
import AVFoundation

// MARK: - 手机接力的开关（今日页、设置页）

struct RelayCard: View {
    @ObservedObject private var relay = PhoneRelay.shared

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 34, height: 34)
                Image(systemName: relay.mode == .recording ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: relay.mode == .recording)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                Text(relay.statusText).font(.caption).foregroundStyle(Ink.ink3).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(relay.active ? "关闭" : "开启") {
                if relay.active { relay.disarm() } else { relay.arm() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(relay.active ? Ink.ink2 : Chat.mineText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(relay.active ? Ink.wash : Chat.mine))
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.wash.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(relay.mode == .recording ? Ink.vermilion.opacity(0.5) : Ink.rule, lineWidth: 1))
        .animation(.snappy, value: relay.mode)
    }

    private var title: String {
        switch relay.mode {
        case .off: return "手机接力"
        case .standby: return "手机接力 · 待命"
        case .recording: return "手机接力 · 在录"
        }
    }

    private var tint: Color { relay.mode == .recording ? Ink.vermilion : (relay.active ? Ink.indigo : Ink.ink2) }
}

// MARK: - 我的声音：录 20 秒，让它认得你

struct VoiceEnrollView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var analyzer = VoiceAnalyzer.shared
    @State private var recorder: AVAudioRecorder?
    @State private var seconds = 0
    @State private var level: Float = 0
    @State private var timer: Timer?
    @State private var result: String?
    @State private var working = false
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("enroll.wav")
    static let length = 20

    private let passage = """
    今天天气不错，我早上七点多出门，先去楼下买了杯咖啡，然后开车去公司。上午有两个会，一个讲预算，一个讲新项目的排期。中午和同事在附近吃了碗面，下午把评分表整理好，发给了评委组。晚上回家路上听了会儿播客，想着明天要早点起。
    """

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("用平常说话的音量，把下面这段读出来（大约 20 秒）。只在这台手机上算出你的声纹，录音读完就删掉。")
                    .font(.subheadline).foregroundStyle(Ink.ink2).lineSpacing(3)
                Text(passage)
                    .font(.system(size: 19))
                    .foregroundStyle(Ink.ink)
                    .lineSpacing(8)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.wash))
                if recorder != nil {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(seconds), total: Double(Self.length)).tint(Ink.vermilion)
                        Text("\(Self.length - seconds) 秒").font(.footnote.monospacedDigit()).foregroundStyle(Ink.ink2)
                    }
                }
                if let result { Text(result).font(.footnote).foregroundStyle(Ink.ink2) }
                Spacer()
                Button(action: toggle) {
                    Text(recorder == nil ? (working ? "在算…" : "开始读") : "读完了")
                        .font(.headline)
                        .foregroundStyle(Chat.mineText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(recorder == nil ? Chat.mine : Ink.vermilion))
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            .padding(22)
            .navigationTitle("我的声音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { stop(save: false); dismiss() } } }
        }
    }

    private func toggle() {
        if recorder == nil { start() } else { stop(save: true) }
    }

    private func start() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { result = "没有麦克风权限。"; return }
                do {
                    try AudioGate.configureShared()
                    let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
                                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                    try? FileManager.default.removeItem(at: url)
                    let r = try AVAudioRecorder(url: url, settings: settings)
                    guard r.record(forDuration: TimeInterval(Self.length)) else { result = "麦克风现在用不了。"; return }
                    recorder = r
                    seconds = 0
                    result = nil
                    let t = Timer(timeInterval: 1, repeats: true) { _ in
                        DispatchQueue.main.async {
                            seconds += 1
                            if seconds >= Self.length { stop(save: true) }
                        }
                    }
                    RunLoop.main.add(t, forMode: .common)
                    timer = t
                } catch {
                    result = "开不了麦克风：\(error.localizedDescription)"
                }
            }
        }
    }

    private func stop(save: Bool) {
        timer?.invalidate()
        timer = nil
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        AudioGate.release()
        guard save else { try? FileManager.default.removeItem(at: url); return }
        guard seconds >= 8 else { result = "太短了，至少读 8 秒。"; return }
        working = true
        let file = url
        Task {
            let samples = await Task.detached { VoiceEncoder.loadMono16k(file) }.value
            try? FileManager.default.removeItem(at: file)
            let ok = samples.map { analyzer.enroll(samples: $0, device: "phone") } ?? false
            working = false
            result = ok ? "记住你的声音了。以后录音里你说的话会标成“我”，以前的录音也会重新认一遍。" : "没听清，换个安静的地方再读一次。"
        }
    }
}

// MARK: - 认识的声音

struct VoiceListView: View {
    @ObservedObject private var analyzer = VoiceAnalyzer.shared
    @State private var renaming: SpeakerProfile?
    @State private var draft = ""
    @State private var showEnroll = false
    @State private var confirmForget = false

    var body: some View {
        List {
            Section {
                Button { showEnroll = true } label: {
                    Label(analyzer.hasMe ? "重新录我的声音" : "录一段我的声音", systemImage: "waveform.badge.mic")
                }
                if analyzer.hasMe {
                    Text("已经认得你：\(analyzer.book.me.keys.map { $0 == "watch" ? "手表" : "手机" }.sorted().joined(separator: "、"))上的声音。手表上的会用手表录到的声音自己慢慢校准。")
                        .font(.footnote).foregroundStyle(Ink.ink3)
                }
            } header: {
                Text("我")
            }
            Section {
                let list = analyzer.book.speakers.sorted { ($0.name == nil ? 1 : 0, -$0.count) < ($1.name == nil ? 1 : 0, -$1.count) }
                if list.isEmpty {
                    Text("还没有。录音分析过以后，出现过的不同声音会列在这里。").font(.footnote).foregroundStyle(Ink.ink3)
                }
                ForEach(list) { p in
                    Button {
                        draft = p.name ?? ""
                        renaming = p
                    } label: {
                        HStack {
                            Circle().fill(VoiceAnalyzer.color(p.id)).frame(width: 10, height: 10)
                            Text(p.name ?? "说话人 \(p.letter)").foregroundStyle(Ink.ink)
                            Spacer()
                            Text("\(p.count) 次").font(.caption).foregroundStyle(Ink.ink3)
                        }
                    }
                }
            } header: {
                Text("认识的声音")
            } footer: {
                Text("点一下可以起名字。也可以在“原话”里长按某一句，选“这是谁说的”。起了名字的声音以后在任何一天都会被认出来。")
            }
            Section {
                Button("忘掉所有声纹", role: .destructive) { confirmForget = true }
            }
        }
        .navigationTitle("声音")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEnroll) { VoiceEnrollView() }
        .alert("这个声音是谁", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $draft)
            Button("好") { if let p = renaming { analyzer.rename(p.id, to: draft) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("忘掉你和所有人的声纹？原话里的“谁说的”标记也会清掉。", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("忘掉", role: .destructive) { analyzer.forgetAll() }
        }
    }
}
