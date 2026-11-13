import SwiftUI
import PhotosUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

/// 对话：主页面。跟住在手机里的助理说话——它知道你今天说过什么、在哪、接下来有什么，也能联网、看图、读文件。
struct ChatView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var assistant = Assistant.shared
    @StateObject private var speaker = Speaker()
    @State private var draft = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var image: Data?
    @State private var file: (name: String, text: String)?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var keyDraft = ""
    @State private var cloudReady = Cloud.ready
    @State private var bottomVisible = true
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !cloudReady && !Store.isDemo { setupCard }
                    if chat.messages.isEmpty { welcome }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, speaker: speaker)
                            .id(message.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    }
                    if assistant.busy { thinking }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { bottomVisible = true }
                        .onDisappear { bottomVisible = false }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .animation(.spring(response: 0.4, dampingFraction: 0.88), value: chat.messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                JumpButtons(showTop: false, showBottom: !bottomVisible && !chat.messages.isEmpty, onTop: {},
                            onBottom: { withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo("bottom", anchor: .bottom) } })
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: assistant.busy) { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { inputBar }
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { image = Self.compress(data) }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .plainText, .text, .json, .commaSeparatedText]) { result in
            if case let .success(url) = result { file = Self.read(url) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in image = data.flatMap { Self.compress($0) } }
                .ignoresSafeArea()
        }
    }

    // MARK: 空状态与配置

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudyVignette(live: false)
                .frame(maxWidth: 520)
                .padding(.horizontal, -6)
            Text(greeting)
                .font(Ink.serif(26, relativeTo: .title))
                .foregroundStyle(Ink.ink)
            Text("我知道你今天说过什么、去过哪、接下来有什么安排，也能上网查、看图、读文件。")
                .font(.subheadline)
                .foregroundStyle(Ink.ink2)
                .lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s)
                            .font(.subheadline)
                            .foregroundStyle(Ink.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Ink.ink3, style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 4)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 5 { return "夜深了，还有什么要记的？" }
        if hour < 11 { return "早。今天想先理哪件事？" }
        if hour < 14 { return "中午好。上午的事要回顾一下吗？" }
        if hour < 18 { return "下午好。有什么要我查的？" }
        return "晚上好。今天过得怎么样？"
    }

    private var suggestions: [String] {
        var list = ["今天我答应了别人什么？", "帮我总结今天，挑出最要紧的三件事"]
        if ContextSensor.calendarOn || Store.isDemo { list.append("明天有什么安排，需要提前准备什么？") }
        list.append("上网查一下今天有什么值得看的 AI 新闻")
        return list
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先接上大模型")
                .font(Ink.serif(19, relativeTo: .title3))
                .foregroundStyle(Ink.ink)
            Text("粘贴你的 DeepSeek 密钥。它只存在这台手机的钥匙串里，不会进代码仓库，也不会经过别的服务器。")
                .font(.footnote)
                .foregroundStyle(Ink.ink2)
                .lineSpacing(3)
            HStack(spacing: 10) {
                SecureField("sk-…", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.rule, lineWidth: 1))
                Button("接上") {
                    Cloud.setupDeepSeek(key: keyDraft)
                    keyDraft = ""
                    cloudReady = Cloud.ready
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Ink.paper)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Ink.ink))
                .buttonStyle(.plain)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).count < 10)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.wash))
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            ThinkingDots()
            Text(assistant.status ?? "在想…")
                .font(.footnote)
                .foregroundStyle(Ink.ink3)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: assistant.status)
    }

    // MARK: 输入

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if image != nil || file != nil {
                HStack(spacing: 8) {
                    if let image, let ui = UIImage(data: image) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let file {
                        Label(file.name, systemImage: "doc.text").labelStyle(TightLabel())
                            .font(.footnote).foregroundStyle(Ink.ink2).lineLimit(1)
                    }
                    Spacer()
                    Button { image = nil; file = nil } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink3)
                            .frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("移除附件")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                    Button { showPhotos = true } label: { Label("照片", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("文件（PDF、文本）", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("添加图片或文件")
                TextField("跟拾言说点什么", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 9)
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.paper)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? Ink.ink : Ink.ink3))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 3)
                .accessibilityLabel("发送")
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.paper))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.ink.opacity(0.35), lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Ink.paper)
    }

    private var canSend: Bool {
        !assistant.busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil || file != nil)
    }

    private func send(_ text: String) {
        guard !assistant.busy else { return }
        assistant.send(text: text, imageJPEG: image, attachment: file)
        draft = ""
        image = nil
        file = nil
    }

    // MARK: 附件处理

    /// 缩到长边 1600 以内再转 JPEG，省流量也够 OCR 用。
    static func compress(_ data: Data) -> Data? {
        guard let ui = UIImage(data: data) else { return nil }
        let longest = max(ui.size.width, ui.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.72)
    }

    /// 文件在本机解析成文字（PDF 用系统的 PDFKit），再交给模型。
    static func read(_ url: URL) -> (name: String, text: String)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            guard let text = PDFDocument(url: url)?.string, !text.isEmpty else { return (name, "（这个 PDF 里没有可提取的文字，可能是扫描件。可以改成拍照发给我。）") }
            return (name, text)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (name, text)
    }
}

// MARK: - 一条消息

private struct MessageRow: View {
    let message: ChatMessage
    @ObservedObject var speaker: Speaker
    @ObservedObject private var chat = ChatStore.shared

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        if message.role == .user { userBubble } else { assistantBlock }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let name = message.image, let ui = UIImage(contentsOfFile: chat.dir.appendingPathComponent(name).path) {
                Image(uiImage: ui).resizable().scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let file = message.attachment {
                Label(file, systemImage: "doc.text").labelStyle(TightLabel())
                    .font(.footnote).foregroundStyle(Ink.ink2)
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Ink.ink)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5,
                                                       topTrailingRadius: 18, style: .continuous).fill(Ink.wash))
                    .contextMenu { menu }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.proactive {
                HStack(spacing: 6) {
                    Circle().fill(Ink.vermilion).frame(width: 5, height: 5)
                    Text("主动提醒 \(Self.time.string(from: message.time))")
                        .font(.caption)
                        .foregroundStyle(Ink.vermilion)
                }
            }
            Text(Self.rich(message.text))
                .font(.body)
                .foregroundStyle(message.failed ? Ink.vermilion : Ink.ink)
                .lineSpacing(5)
                .tint(Ink.indigo)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { menu }
            ForEach(Array(message.proposals.enumerated()), id: \.offset) { index, proposal in
                ProposalCard(proposal: proposal) { Assistant.shared.confirm(message: message.id, index: index) }
            }
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.sources, id: \.self) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Label(source.site.isEmpty ? source.title : "\(source.site)：\(source.title)", systemImage: "link")
                                    .labelStyle(TightLabel())
                                    .font(.footnote)
                                    .foregroundStyle(Ink.indigo)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(.trailing, 28)
    }

    @ViewBuilder
    private var menu: some View {
        Button { UIPasteboard.general.string = message.text } label: { Label("复制", systemImage: "doc.on.doc") }
        if message.role == .assistant {
            Button { speaker.toggle(message.text) } label: { Label(speaker.speaking ? "停止朗读" : "朗读", systemImage: "speaker.wave.2") }
        }
        Button(role: .destructive) { chat.remove(message.id) } label: { Label("删除", systemImage: "trash") }
    }

    static func rich(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 等你点头的动作。
private struct ProposalCard: View {
    let proposal: Proposal
    let confirm: () -> Void

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(proposal.kind == .reminder ? "提醒事项" : "日历", systemImage: proposal.kind == .reminder ? "checklist" : "calendar")
                .labelStyle(TightLabel())
                .font(.caption)
                .foregroundStyle(Ink.ink3)
            Text(proposal.title)
                .font(.body.weight(.medium))
                .foregroundStyle(Ink.ink)
            if let start = proposal.start {
                Text(Self.when.string(from: start) + (proposal.location.map { "，\($0)" } ?? ""))
                    .font(.footnote)
                    .foregroundStyle(Ink.ink2)
            }
            if let result = proposal.result {
                HStack(spacing: 6) {
                    if proposal.done {
                        InkTick().stroke(Ink.vermilion, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 12, height: 10)
                    }
                    Text(result).font(.footnote).foregroundStyle(proposal.done ? Ink.ink2 : Ink.vermilion)
                }
            }
            if !proposal.done {
                Button(action: confirm) {
                    Text(proposal.kind == .reminder ? "写入提醒事项" : "写入日历")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.paper)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Ink.ink))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.ink.opacity(0.3), lineWidth: 1))
    }
}

private struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Ink.ink2).frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.18), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

// MARK: - 朗读（系统语音，在本机合成）

final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ text: String) {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            speaking = false
            return
        }
        let plain = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(utterance)
        speaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }
}

// MARK: - 拍照

struct CameraPicker: UIViewControllerRepresentable {
    let done: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.done(image?.jpegData(compressionQuality: 0.9))
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
