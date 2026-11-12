import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var coordinator: DigestCoordinator
    @EnvironmentObject private var transcriber: Transcriber
    @State private var day = Store.dayKey(Date())
    @State private var source: DigestItem?
    @State private var chapter: Chapter?
    @State private var contextDraft = ""
    @State private var confirmFull = false
    @State private var confirmRetranscribe = false
    @FocusState private var contextFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            let lines = store.lines(on: day)
            let digest = store.db.digests[day]
            ScrollView {
                VStack(spacing: 16) {
                    dayPicker.card()
                    if lines.isEmpty {
                        ContentUnavailableView {
                            Label("这一天还没有记录", systemImage: "waveform")
                        } description: {
                            Text(emptyHint)
                        }
                        .padding(.top, 40)
                    } else {
                        contextField.card()
                        statusLine
                        fishbone(digest, wide: wide)
                        itemCard("重要决定", "checkmark.seal", .decision, digest)
                        itemCard("待办", "checklist", .todo, digest)
                        itemCard("待确认", "questionmark.circle", .pending, digest)
                        tools.card()
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
        }
        .sheet(item: $source) { SourceSheet(item: $0) }
        .sheet(item: $chapter) { ChapterSheet(chapter: $0, day: day) }
        .onAppear {
            contextDraft = store.db.dayContext?[day] ?? ""
            coordinator.update(day: day)
            if Store.isDemo, UserDefaults.standard.object(forKey: "chapter") != nil {
                let index = UserDefaults.standard.integer(forKey: "chapter")
                chapter = store.db.digests[day]?.chapters?[safe: index]
            }
        }
        .onChange(of: day) { _, newDay in
            contextDraft = store.db.dayContext?[newDay] ?? ""
            coordinator.update(day: newDay)
        }
        .confirmationDialog("用当前的识别引擎把这一天留着的录音重新转写一遍，原来的文字和回顾会被替换。", isPresented: $confirmRetranscribe, titleVisibility: .visible) {
            Button("重新转写") { transcriber.retranscribe(day: day) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("整天重新整理会结合全天上下文和你写的背景重做一遍，已勾选的待办状态会被清除。", isPresented: $confirmFull, titleVisibility: .visible) {
            Button("重新整理") { coordinator.update(day: day, full: true) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶部

    private var dayPicker: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("前一天")
            Spacer()
            Text(day == Store.dayKey(Date()) ? "今天" : day).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= Store.dayKey(Date()))
                .accessibilityLabel("后一天")
        }
        .buttonStyle(.borderless)
    }

    private func shift(_ delta: Int) {
        let date = Calendar.current.date(byAdding: .day, value: delta, to: Store.date(fromDayKey: day)) ?? Date()
        day = Store.dayKey(date)
    }

    /// 一句话背景：告诉整理模型今天在干什么，分章和待办会准很多。
    private var contextField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("今天的背景", systemImage: "text.bubble")
                .font(.caption).foregroundStyle(.secondary)
            TextField("写一句，如：上午主持 AI 大赛决赛，我是主持人", text: $contextDraft, axis: .vertical)
                .lineLimit(1...3)
                .focused($contextFocused)
                .submitLabel(.done)
                .onChange(of: contextFocused) { _, focused in
                    if !focused { saveContext() }
                }
        }
    }

    private func saveContext() {
        let text = contextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != (store.db.dayContext?[day] ?? "") { store.setDayContext(text, day: day) }
    }

    @ViewBuilder
    private var statusLine: some View {
        let waiting = coordinator.unprocessedCount(day: day)
        if coordinator.working {
            progress("正在整理新内容…")
        } else if transcriber.busy {
            progress("正在转写…")
        } else if let error = coordinator.lastError, waiting > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(waiting) 句没能整理：\(error)").font(.footnote).foregroundStyle(.red)
                Button("重试") { coordinator.update(day: day, force: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else if waiting > 0 {
            HStack {
                Text("\(waiting) 句新内容，攒够一段后自动整理").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("现在整理") { coordinator.update(day: day, force: true) }.font(.footnote)
            }
            .card()
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .card()
    }

    // MARK: 鱼骨图

    @ViewBuilder
    private func fishbone(_ digest: Digest?, wide: Bool) -> some View {
        let chapters = digest?.chapters ?? []
        if chapters.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "fish").font(.title2).foregroundStyle(.secondary)
                Text(digest == nil ? "攒够一段内容后，这里会长出今天的鱼骨图。" : "这一天还没有分章。点下面的「整天重新整理」生成鱼骨图。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .card()
        } else {
            FishboneView(headline: headline(digest), chapters: chapters, items: digest?.items ?? [],
                         live: isLive, wide: wide) { chapter = $0 }
        }
    }

    private func headline(_ digest: Digest?) -> String {
        let mine = (store.db.dayContext?[day] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { return mine }
        if let scene = digest?.scene, !scene.isEmpty { return scene }
        return digest?.stats ?? ""
    }

    private var isLive: Bool {
        if coordinator.working || transcriber.busy { return true }
        guard day == Store.dayKey(Date()), let last = store.segments(on: day).map({ $0.start.addingTimeInterval($0.duration) }).max() else { return false }
        return Date().timeIntervalSince(last) < 180
    }

    // MARK: 决定 / 待办 / 待确认

    @ViewBuilder
    private func itemCard(_ title: String, _ symbol: String, _ kind: ItemKind, _ digest: Digest?) -> some View {
        let items = (digest?.items ?? []).filter { $0.kind == kind }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                ForEach(items) { item in
                    Button { source = item } label: { ItemRow(item: item) }
                        .buttonStyle(.plain)
                    if item.id != items.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    // MARK: 工具

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(segmentSummary).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button("整天重新整理") { confirmFull = true }.disabled(coordinator.working)
                Button("重新转写这一天") { confirmRetranscribe = true }.disabled(transcriber.busy)
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 这一天各分段的转写情况，方便判断问题出在录音、同步还是识别。
    private var segmentSummary: String {
        let segs = store.segments(on: day)
        let done = segs.filter { $0.status == .done }.count
        let silent = segs.filter { $0.status == .noSpeech }.count
        let failed = segs.filter { $0.status == .failed || $0.status == .blocked }.count
        let pending = segs.filter { $0.status == .pending }.count
        var parts = ["\(segs.count) 段录音：\(done) 段有文字"]
        if silent > 0 { parts.append("\(silent) 段没识别出语音") }
        if failed > 0 { parts.append("\(failed) 段失败") }
        if pending > 0 { parts.append("\(pending) 段待转写") }
        var text = parts.joined(separator: "，")
        if let digest = store.db.digests[day] { text += "。由「\(DigestEngine.engineName(digest.engine))」整理" }
        if let note = segs.compactMap({ $0.error }).first { text += "\n" + note }
        return text
    }

    private var emptyHint: String {
        let pending = store.segments(on: day).filter { $0.status == .pending }.count
        if pending > 0 { return "有 \(pending) 段录音正在转写，稍后会出现在这里。" }
        return "在 Apple Watch 上打开拾言，点「开始录音」。录音会边录边同步到这里。"
    }
}

extension View {
    /// 统一的卡片底。
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// 回顾/待办条目：正文 + 负责人、截止、待确认标签。
struct ItemRow: View {
    let item: DigestItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.body)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.kind == .todo, item.owner != nil || item.due != nil {
                HStack(spacing: 6) {
                    if let owner = item.owner { Chip(text: owner, warn: false) }
                    if let due = item.due {
                        Chip(text: item.dueDate == nil ? "\(due)（日期待确认）" : due, warn: item.dueDate == nil)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct Chip: View {
    let text: String
    let warn: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(warn ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12)))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
    }
}
