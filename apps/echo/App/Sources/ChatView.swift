import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - 对话页的颜色

/// 对话页比其他页更“干净”：近白的底、柔和的灰气泡、深色的自己。
enum Chat {
    private static func dyn(_ day: UInt32, _ night: UInt32, alpha: CGFloat = 1) -> Color {
        Color(UIColor { t in
            let v = t.userInterfaceStyle == .dark ? night : day
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: alpha)
        })
    }

    static let page = dyn(0xFCFCFA, 0x161B2E)
    static let bubble = dyn(0xEDEDEC, 0x252D49)
    static let field = dyn(0xFFFFFF, 0x1F2640)
    static let ring = dyn(0xFFFFFF, 0x2D3657)
    static let mine = dyn(0x1F1F21, 0xEFE6CF)
    static let mineText = dyn(0xFFFFFF, 0x1A2036)
    static let link = dyn(0x2F6FD6, 0x8FB4FF)
    static let chip = dyn(0x1C1C1C, 0xEFE6CF, alpha: 0.34)
}

/// 对话：主页面。跟住在手机里的助理说话——它知道你今天说过什么、在哪、接下来有什么，也能联网、看图、读文件、听你说话。
struct ChatView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var assistant = Assistant.shared
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var profile = BuddyProfile.shared
    @StateObject private var voice = VoiceInput()
    @AppStorage("deepThink") private var deepThink = false
    @State private var draft = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var image: Data?
    @State private var file: Attachment?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var showAbilities = false
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var keyDraft = ""
    @State private var cloudReady = Cloud.ready
    @State private var bottomVisible = true
    @FocusState private var focused: Bool

    private static var fileTypes: [UTType] {
        var types: [UTType] = [.pdf, .text, .plainText, .json, .commaSeparatedText, .spreadsheet, .presentation, .epub]
        for ext in ["doc", "docx", "ppt", "pptx", "xls", "xlsx", "md", "mobi"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !cloudReady && !Store.isDemo { setupCard }
                    if chat.messages.isEmpty { welcome }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if let label = stampText(index) { TimeStamp(text: label, proactive: message.proactive) }
                        MessageRow(message: message, isLast: index == chat.messages.count - 1 && !assistant.busy, onSuggestion: { send($0) })
                            .id(message.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                    }
                    if assistant.busy { live }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { bottomVisible = true }
                        .onDisappear { bottomVisible = false }
                }
                .padding(.horizontal, 16)
                .padding(.top, 104)
                .padding(.bottom, 6)
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: chat.messages.count)
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
            .onChange(of: assistant.streaming) { _, _ in
                if bottomVisible { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Chat.page.ignoresSafeArea())
        .overlay(alignment: .top) { header }
        .safeAreaInset(edge: .bottom) { inputBar }
        .photosPicker(isPresented: $showPhotos, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { image = Self.compress(data) }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: Self.fileTypes) { result in
            if case let .success(url) = result { file = Self.read(url) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in image = data.flatMap { Self.compress($0) } }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showAbilities) { AbilitiesView() }
        .alert("给它起个名字", isPresented: $renaming) {
            TextField("名字", text: $nameDraft)
            Button("好") { profile.rename(nameDraft) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶上的头像

    private var mood: BuddyMood {
        if voice.phase == .recording { return .listening }
        if speaker.speaking { return .speaking }
        if assistant.busy { return assistant.streaming.isEmpty ? .thinking : .speaking }
        if voice.phase == .transcribing || speaker.loading { return .thinking }
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 && !Store.isDemo ? .sleeping : .idle
    }

    private var caption: String? {
        if voice.phase == .recording { return "在听…" }
        if voice.phase == .transcribing { return "听写中…" }
        if assistant.busy { return assistant.status ?? "正在输入…" }
        if speaker.loading { return "清清嗓子…" }
        return nil
    }

    private var header: some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: Chat.page, location: 0), .init(color: Chat.page.opacity(0.96), location: 0.62),
                                   .init(color: Chat.page.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 176)
                .padding(.top, -60)
                .allowsHitTesting(false)
            BuddyHeader(mood: mood, caption: caption) {
                nameDraft = profile.name
                renaming = true
            }
            .padding(.top, -14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 时间戳

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 第一条、隔了 10 分钟以上、或它主动找你时，显示时间。
    private func stampText(_ index: Int) -> String? {
        let message = chat.messages[index]
        if index > 0, !message.proactive, message.time.timeIntervalSince(chat.messages[index - 1].time) < 600 { return nil }
        let f = Calendar.current.isDateInToday(message.time) ? Self.clock : Self.dayClock
        return f.string(from: message.time)
    }

    // MARK: 空状态与配置

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(greeting)
                .font(.system(size: 17))
                .foregroundStyle(Ink.ink)
                .lineSpacing(5)
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    ChipButton(title: s) { send(s) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Chat.bubble))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello: String
        if hour < 5 { hello = "这么晚还没睡。" } else if hour < 11 { hello = "早。" } else if hour < 14 { hello = "中午好。" } else if hour < 18 { hello = "下午好。" } else { hello = "晚上好。" }
        return "\(hello)我是\(profile.name)，一直在这儿。你今天说过什么、去过哪、接下来有什么安排我都记着；也能上网查、看图、读文件，你直接说话我也听得懂。"
    }

    private var suggestions: [String] {
        ["今天我答应了别人什么？", "定制我的资讯流", "你都能帮我做什么？"]
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先接上大模型")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Text("粘贴你的 DeepSeek 密钥。它只存在这台手机的钥匙串里，不会进代码仓库，也不会经过别的服务器。对话、搜索、语音、文件解析都用它。")
                .font(.footnote)
                .foregroundStyle(Ink.ink2)
                .lineSpacing(3)
            HStack(spacing: 10) {
                SecureField("sk-…", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Chat.field))
                Button("接上") {
                    Cloud.setupDeepSeek(key: keyDraft)
                    keyDraft = ""
                    cloudReady = Cloud.ready
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Chat.mineText)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Chat.mine))
                .buttonStyle(.plain)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).count < 10)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Chat.bubble))
    }

    /// 正在生成的回答：字一边到一边显示；还没出字时是三个跳动的点。
    private var live: some View {
        Group {
            if assistant.streaming.isEmpty {
                ThinkingDots()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            } else {
                RichText(text: assistant.streaming)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Chat.bubble))
        .transition(.opacity)
    }

    // MARK: 输入

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = voice.error {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Ink.vermilion)
                    .padding(.horizontal, 12)
                    .onTapGesture { voice.error = nil }
            }
            if image != nil || file != nil { attachmentRow }
            Group {
                switch voice.phase {
                case .idle: typingRow
                case .recording: recordingRow
                case .transcribing: transcribingRow
                }
            }
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Chat.field))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(voice.phase == .recording ? Ink.vermilion.opacity(0.55) : Ink.rule, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 3)
            .animation(.snappy(duration: 0.22), value: voice.phase)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Chat.page)
    }

    private var attachmentRow: some View {
        HStack(spacing: 8) {
            if let image, let ui = UIImage(data: image) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .padding(.horizontal, 8)
    }

    private var typingRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Menu {
                Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                Button { showPhotos = true } label: { Label("照片", systemImage: "photo") }
                Button { showFiles = true } label: { Label("文件（PDF、Word、PPT、表格）", systemImage: "doc") }
                Divider()
                Toggle(isOn: $deepThink) { Label("深度思考（更慢更细）", systemImage: "brain") }
                Button { showAbilities = true } label: { Label("能力与连接器", systemImage: "square.grid.2x2") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 46, height: 52)
            }
            .accessibilityLabel("添加图片、文件，或打开能力与连接器")
            TextField("发消息", text: $draft, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 15)
            trailingButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if assistant.busy {
            RoundButton(symbol: "stop.fill", filled: true, label: "停下") { assistant.stop() }
        } else if hasContent {
            RoundButton(symbol: "arrow.up", filled: true, label: "发送") { send(draft) }
        } else {
            RoundButton(symbol: "mic", filled: false, label: "说话") {
                focused = false
                voice.start { heard in send(heard, spoken: true) }
            }
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 10) {
            RoundButton(symbol: "xmark", filled: false, label: "取消") { voice.finish(send: false) }
            LevelBars(level: voice.level)
            Text(String(format: "%d:%02d", voice.seconds / 60, voice.seconds % 60))
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.ink)
            Text(voice.seconds >= 100 ? "快到 2 分钟上限了" : "说完点右边发送")
                .font(.footnote)
                .foregroundStyle(Ink.ink3)
                .lineLimit(1)
            Spacer(minLength: 0)
            RoundButton(symbol: "arrow.up", filled: true, tint: Ink.vermilion, label: "发送") { voice.finish(send: true) }
        }
        .padding(.horizontal, 6)
    }

    private var transcribingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("听写中…").font(.subheadline).foregroundStyle(Ink.ink2)
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil || file != nil
    }

    private func send(_ text: String, spoken: Bool = false) {
        guard !assistant.busy else { return }
        assistant.send(text: text, imageJPEG: image, attachment: file, spoken: spoken)
        draft = ""
        image = nil
        file = nil
    }

    // MARK: 附件处理

    /// 缩到长边 1600 以内再转 JPEG，省流量也够看清字。
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

    /// 读文件：原文件留着交给 DeepSeek 解析（扫描件、Word、PPT、表格都行）；能在本机读出文字的也读一份备用。
    static func read(_ url: URL) -> Attachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text: String?
        if ext == "pdf" {
            if let s = PDFDocument(data: data)?.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { text = s }
        } else if !Cloud.parsesRemotely(ext) {
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        return Attachment(name: name, text: text, data: data.count <= 60 * 1024 * 1024 ? data : nil)
    }
}

// MARK: - 小部件

private struct TimeStamp: View {
    let text: String
    let proactive: Bool
    @ObservedObject private var profile = BuddyProfile.shared

    var body: some View {
        HStack(spacing: 6) {
            if proactive { Circle().fill(Ink.vermilion).frame(width: 5, height: 5) }
            Text(proactive ? "\(text) · \(profile.name)想到的" : text)
                .font(.footnote)
                .foregroundStyle(Ink.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// 虚线框的快捷选项，点一下就替你发出去。
private struct ChipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Ink.ink)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Chat.chip, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
        .buttonStyle(.plain)
    }
}

private struct RoundButton: View {
    let symbol: String
    let filled: Bool
    var tint: Color = Chat.mine
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: filled ? 15 : 19, weight: filled ? .semibold : .regular))
                .foregroundStyle(filled ? (tint == Chat.mine ? Chat.mineText : Color.white) : Ink.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(filled ? tint : Color.clear))
                .frame(width: 44, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 录音电平：五根随声音起伏的小柱子。
private struct LevelBars: View {
    let level: CGFloat
    private let shape: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Ink.vermilion)
                    .frame(width: 3.5, height: 5 + 21 * level * shape[i])
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

private struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Ink.ink2).frame(width: 7, height: 7)
                    .opacity(on ? 1 : 0.25)
                    .offset(y: on ? -2 : 2)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(i) * 0.16), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityLabel("在想")
    }
}

// MARK: - 文字排版

/// 把模型写的 Markdown 排成聊天里好读的样子：段落之间留空，列表变成圆点，标题变成加粗的一行，链接可点。
struct RichText: View {
    let text: String
    var color: Color = Ink.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 17))
                    .foregroundStyle(color)
                    .lineSpacing(5)
                    .tint(Chat.link)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func paragraphs(_ text: String) -> [AttributedString] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out: [AttributedString] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.joined(separator: "\n")
            out.append((try? AttributedString(markdown: joined, options: options)) ?? AttributedString(joined))
            current = []
        }
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                flush()
                line = "**\(title)**"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                line = "•  " + trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                continue
            }
            current.append(line)
        }
        flush()
        return out.isEmpty ? [AttributedString(text)] : out
    }
}

// MARK: - 一条消息

private struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    let onSuggestion: (String) -> Void
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var chat = ChatStore.shared

    var body: some View {
        if message.role == .user { userBubble } else { assistantBubble }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let name = message.image, let ui = UIImage(contentsOfFile: chat.dir.appendingPathComponent(name).path) {
                Image(uiImage: ui).resizable().scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if let file = message.attachment {
                Label(file, systemImage: "doc.text").labelStyle(TightLabel())
                    .font(.footnote).foregroundStyle(Ink.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Chat.bubble))
            }
            if !message.text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if message.spoken == true {
                        Image(systemName: "waveform").font(.footnote).foregroundStyle(Chat.mineText.opacity(0.7))
                    }
                    Text(message.text)
                        .font(.system(size: 17))
                        .foregroundStyle(Chat.mineText)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Chat.mine))
                .contextMenu { menu }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 14) {
            RichText(text: message.text, color: message.failed ? Ink.vermilion : Ink.ink)
                .textSelection(.enabled)
            if message.stopped == true {
                Text("已停下").font(.footnote).foregroundStyle(Ink.ink3)
            }
            ForEach(Array((message.charts ?? []).enumerated()), id: \.offset) { _, chart in
                ChartCard(spec: chart)
            }
            ForEach(Array(message.proposals.enumerated()), id: \.offset) { index, proposal in
                ProposalCard(proposal: proposal) { Assistant.shared.confirm(message: message.id, index: index) }
            }
            if !message.sources.isEmpty { sources }
            if speaker.current == message.id { speakingRow }
            if isLast, let options = message.suggestions, !options.isEmpty {
                VStack(spacing: 10) {
                    ForEach(options, id: \.self) { option in
                        ChipButton(title: option) { onSuggestion(option) }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Chat.bubble))
        .contextMenu { menu }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.sources, id: \.self) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        Label(source.site.isEmpty ? source.title : "\(source.site)：\(source.title)", systemImage: "link")
                            .labelStyle(TightLabel())
                            .font(.subheadline)
                            .foregroundStyle(Chat.link)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var speakingRow: some View {
        Button { speaker.stop() } label: {
            HStack(spacing: 6) {
                if speaker.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative, options: .repeating)
                }
                Text(speaker.loading ? "准备朗读…" : "正在朗读，点一下停止")
            }
            .font(.footnote)
            .foregroundStyle(Ink.ink2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menu: some View {
        Button { UIPasteboard.general.string = message.text } label: { Label("复制", systemImage: "doc.on.doc") }
        if message.role == .assistant {
            Button { speaker.toggle(message.text, id: message.id) } label: {
                Label(speaker.current == message.id ? "停止朗读" : "朗读", systemImage: "speaker.wave.2")
            }
        }
        Button(role: .destructive) { chat.remove(message.id) } label: { Label("删除", systemImage: "trash") }
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
                        .foregroundStyle(Chat.mineText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Chat.mine))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Chat.field))
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
