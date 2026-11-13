import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var coordinator: DigestCoordinator
    @EnvironmentObject private var transcriber: Transcriber
    @State private var day = Store.dayKey(Date())
    @State private var source: DigestItem?
    @State private var chapter: Chapter?
    @State private var editingContext = false
    @State private var contextDraft = ""
    @State private var confirmFull = false
    @State private var confirmRetranscribe = false

    private static let dateTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    var body: some View {
        let lines = store.lines(on: day)
        let digest = store.db.digests[day]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(digest, hasLines: !lines.isEmpty)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                if lines.isEmpty {
                    empty.padding(.horizontal, 22).padding(.top, 56)
                } else {
                    fishbone(digest)
                        .padding(.top, 14)
                    followUps(digest)
                        .padding(.horizontal, 22)
                    tools
                        .padding(.horizontal, 22)
                        .padding(.top, 36)
                        .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Paper.background.ignoresSafeArea())
        .sheet(item: $source) { SourceSheet(item: $0) }
        .sheet(item: $chapter) { ChapterSheet(chapter: $0, day: day) }
        .onAppear {
            coordinator.update(day: day)
            if Store.isDemo, UserDefaults.standard.object(forKey: "chapter") != nil {
                chapter = store.db.digests[day]?.chapters?[safe: UserDefaults.standard.integer(forKey: "chapter")]
            }
        }
        .onChange(of: day) { _, newDay in coordinator.update(day: newDay) }
        .alert("这一天你在做什么", isPresented: $editingContext) {
            TextField("如：上午主持 AI 大赛决赛", text: $contextDraft)
            Button("保存") {
                store.setDayContext(contextDraft.trimmingCharacters(in: .whitespacesAndNewlines), day: day)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("写一句就够。整理时会以它为准来分章，保存后点「重新整理」生效。")
        }
        .confirmationDialog("用当前的识别引擎把这一天留着的录音重新转写一遍，原来的文字和回顾会被替换。", isPresented: $confirmRetranscribe, titleVisibility: .visible) {
            Button("重新转写") { transcriber.retranscribe(day: day) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("结合全天上下文和你写的背景重新整理一遍。已勾选的待办状态会被清除。", isPresented: $confirmFull, titleVisibility: .visible) {
            Button("重新整理") { coordinator.update(day: day, full: true) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 页头：日期、这一天的标题、状态

    private func header(_ digest: Digest?, hasLines: Bool) -> some View {
        let isToday = day == Store.dayKey(Date())
        let dateText = Self.dateTitle.string(from: Store.date(fromDayKey: day))
        let mine = (store.db.dayContext?[day] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !mine.isEmpty ? mine : ((digest?.scene ?? "").isEmpty ? (isToday ? "今天" : dateText) : (digest?.scene ?? ""))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("前一天")
                Text(isToday ? "今天，\(dateText)" : dateText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
                    .accessibilityLabel("后一天")
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if hasLines {
                Text(statusText(digest))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Button(mine.isEmpty ? "补一句背景，分章更准" : "修改背景") {
                        contextDraft = mine
                        editingContext = true
                    }
                    if coordinator.unprocessedCount(day: day) > 0, !coordinator.working, !transcriber.busy {
                        Button(coordinator.lastError == nil ? "现在整理" : "重试") { coordinator.update(day: day, force: true) }
                    }
                }
                .font(.footnote.weight(.medium))
                if let error = coordinator.lastError, coordinator.unprocessedCount(day: day) > 0 {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private func statusText(_ digest: Digest?) -> String {
        if coordinator.working { return "正在整理新内容…" }
        if transcriber.busy { return "正在转写…" }
        let waiting = coordinator.unprocessedCount(day: day)
        let base = digest?.stats ?? DigestEngine.stats(lines: store.lines(on: day), segments: store.segments(on: day))
        return waiting > 0 ? "\(base)，有 \(waiting) 句新内容待整理" : base
    }

    private func shift(_ delta: Int) {
        let date = Calendar.current.date(byAdding: .day, value: delta, to: Store.date(fromDayKey: day)) ?? Date()
        day = Store.dayKey(date)
    }

    // MARK: 鱼骨图

    @ViewBuilder
    private func fishbone(_ digest: Digest?) -> some View {
        let chapters = digest?.chapters ?? []
        if chapters.isEmpty {
            Text(digest == nil || (digest?.items.isEmpty ?? true)
                 ? "内容攒够一段后，这一天的鱼骨图会从这里长出来。"
                 : "这一天还没有分章。点最下面的「重新整理」生成鱼骨图。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 40)
        } else {
            FishboneView(chapters: chapters, items: digest?.items ?? [], live: isLive) { chapter = $0 }
                .id(day)
        }
    }

    private var isLive: Bool {
        if coordinator.working || transcriber.busy { return true }
        guard day == Store.dayKey(Date()), let last = store.segments(on: day).map({ $0.start.addingTimeInterval($0.duration) }).max() else { return false }
        return Date().timeIntervalSince(last) < 180
    }

    // MARK: 要跟进的

    @ViewBuilder
    private func followUps(_ digest: Digest?) -> some View {
        let items = digest?.items ?? []
        let todos = items.filter { $0.kind == .todo }
        let decisions = items.filter { $0.kind == .decision }
        let pending = items.filter { $0.kind == .pending }
        if !todos.isEmpty { group("要你跟进的", todos) }
        if !decisions.isEmpty { group("定下来的", decisions) }
        if !pending.isEmpty { group("还没定的", pending) }
    }

    private func group(_ title: String, _ items: [DigestItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 34)
                .padding(.bottom, 6)
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    marker(item)
                    Button { source = item } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text)
                                .font(.body)
                                .strikethrough(item.done)
                                .foregroundStyle(item.done ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            if let meta = meta(item) {
                                Text(meta).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12)
                if item.id != items.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: DigestItem) -> some View {
        switch item.kind {
        case .todo:
            Button {
                store.updateItem(day: day, id: item.id) { $0.done.toggle() }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "标为未完成" : "标为完成")
        case .decision:
            Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor).frame(width: 24)
        default:
            Image(systemName: "questionmark").font(.subheadline.weight(.bold)).foregroundStyle(.orange).frame(width: 24)
        }
    }

    private func meta(_ item: DigestItem) -> String? {
        guard item.kind == .todo else { return nil }
        var parts: [String] = []
        if let owner = item.owner { parts.append(owner) }
        if let due = item.due { parts.append(item.dueDate == nil ? "\(due)（日期待确认）" : "\(due)前") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    // MARK: 页脚工具与空状态

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(segmentSummary).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            HStack(spacing: 22) {
                Button("重新整理") { confirmFull = true }.disabled(coordinator.working)
                Button("重新转写") { confirmRetranscribe = true }.disabled(transcriber.busy)
            }
            .font(.footnote.weight(.medium))
        }
    }

    private var segmentSummary: String {
        let segs = store.segments(on: day)
        let done = segs.filter { $0.status == .done }.count
        let silent = segs.filter { $0.status == .noSpeech }.count
        let failed = segs.filter { $0.status == .failed || $0.status == .blocked }.count
        let pending = segs.filter { $0.status == .pending }.count
        var parts = ["\(segs.count) 段录音，\(done) 段有文字"]
        if silent > 0 { parts.append("\(silent) 段没识别出语音") }
        if failed > 0 { parts.append("\(failed) 段失败") }
        if pending > 0 { parts.append("\(pending) 段待转写") }
        var text = parts.joined(separator: "，")
        if let digest = store.db.digests[day] { text += "。由\(DigestEngine.engineName(digest.engine))整理" }
        if let note = segs.compactMap({ $0.error }).first { text += "\n" + note }
        return text
    }

    private var empty: some View {
        let pending = store.segments(on: day).filter { $0.status == .pending }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text(pending > 0 ? "有 \(pending) 段录音正在转写" : "这一天还没有记录")
                .font(.title3.weight(.semibold))
            Text(pending > 0 ? "转写完会出现在这里。" : "在 Apple Watch 上打开拾言，点「开始录音」。录音会边录边同步过来，攒够一段就长出一根骨头。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
