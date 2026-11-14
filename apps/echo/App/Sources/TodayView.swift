import SwiftUI

/// 今日回顾：页头（这一天在干什么）→ 要跟进的 → 这一天的经过（往下延展的时间线）。
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
    @State private var headerVisible = true
    @State private var endVisible = false
    @ObservedObject private var sensor = ContextSensor.shared
    @Namespace private var zoom

    private static let dateTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    var body: some View {
        let digest = store.db.digests[day]
        let hasLines = !store.lines(on: day).isEmpty
        let chapters = digest?.chapters ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(digest, hasLines: hasLines)
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .id("top")
                        .onAppear { headerVisible = true }
                        .onDisappear { headerVisible = false }
                    if hasLines {
                        DayStoryCard(day: day)
                            .padding(.horizontal, 22)
                            .padding(.top, 30)
                            .id("story")
                        followUps(digest)
                            .padding(.horizontal, 22)
                        sectionTitle(day == Store.dayKey(Date()) ? "今天的经过" : "这一天的经过")
                            .padding(.horizontal, 22)
                            .padding(.top, 34)
                        if chapters.isEmpty {
                            Text(digest == nil ? "内容攒够一段后，这一天的经过会从这里一节一节长出来。" : "这一天还没有分章。点最下面的「重新整理」生成。")
                                .font(.subheadline)
                                .foregroundStyle(Ink.ink3)
                                .padding(.horizontal, 22)
                                .padding(.top, 12)
                        } else {
                            DayFlowView(chapters: chapters, items: digest?.items ?? [], live: isLive, namespace: zoom) { chapter = $0 }
                                .id(day)
                                .padding(.horizontal, 22)
                                .padding(.top, 18)
                        }
                        tools
                            .padding(.horizontal, 22)
                            .padding(.top, 30)
                            .padding(.bottom, 24)
                            .id("bottom")
                            .onAppear { endVisible = true }
                            .onDisappear { endVisible = false }
                    } else {
                        empty.padding(.horizontal, 22).padding(.top, 48)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.5, dampingFraction: 0.88), value: digest?.items.count ?? 0)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                JumpButtons(showTop: !headerVisible, showBottom: hasLines && !chapters.isEmpty && !endVisible,
                            onTop: { withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo("top", anchor: .top) } },
                            onBottom: { withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo("bottom", anchor: .bottom) } })
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            }
            .onChange(of: chapters.count) { old, new in
                // 只有本来就停在底部时才跟着往下走；正在往上翻看时不打断
                guard new > old, endVisible else { return }
                withAnimation(.smooth(duration: 0.65)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                coordinator.update(day: day)
                if Store.isDemo, UserDefaults.standard.bool(forKey: "scrollStory") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo("story", anchor: .top) }
                }
                if Store.isDemo, UserDefaults.standard.bool(forKey: "scroll") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if Store.isDemo, UserDefaults.standard.object(forKey: "chapter") != nil {
                    chapter = store.db.digests[day]?.chapters?[safe: UserDefaults.standard.integer(forKey: "chapter")]
                }
            }
        }
        .background(PaperBackground())
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: chapters.count)
        .onChange(of: day) { _, newDay in coordinator.update(day: newDay) }
        .sheet(item: $source) { SourceSheet(item: $0) }
        .sheet(item: $chapter) { ch in
            ChapterSheet(chapter: ch, day: day)
                .modifier(ZoomDestination(id: ch.id, namespace: zoom))
        }
        .alert("这一天你在做什么", isPresented: $editingContext) {
            TextField("如：上午主持 AI 大赛决赛", text: $contextDraft)
            Button("保存") {
                store.setDayContext(contextDraft.trimmingCharacters(in: .whitespacesAndNewlines), day: day)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("写一句就够。整理时以它为准来分章，保存后点「重新整理」生效。")
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

    // MARK: 页头

    private func header(_ digest: Digest?, hasLines: Bool) -> some View {
        let isToday = day == Store.dayKey(Date())
        let dateText = Self.dateTitle.string(from: Store.date(fromDayKey: day))
        let mine = (store.db.dayContext?[day] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = digest?.scene ?? ""
        let title = !mine.isEmpty ? mine : (scene.isEmpty ? (isToday ? "今天" : dateText) : scene)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 30, height: 30)
                }
                .accessibilityLabel("前一天")
                Text(isToday ? "今天，\(dateText)" : dateText)
                    .font(.subheadline)
                    .foregroundStyle(Ink.ink2)
                    .contentTransition(.numericText())
                Button { shift(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 30, height: 30)
                }
                .disabled(isToday)
                .accessibilityLabel("后一天")
                Spacer()
                if isLive { LivePill() }
            }
            .font(.subheadline)
            .foregroundStyle(Ink.ink)
            .padding(.leading, -8)
            PaintedSky(hour: heroHour(digest), seed: "day-" + day, marks: heroMarks(digest))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottomLeading) { heroCaption(digest) }
                .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
                .padding(.vertical, 6)
            Text(title)
                .font(Ink.serif(29, relativeTo: .largeTitle))
                .foregroundStyle(Ink.ink)
                .lineSpacing(5)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if let route = footprint {
                Label {
                    Text(route)
                } icon: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .labelStyle(TightLabel())
                .font(.footnote)
                .foregroundStyle(Ink.ink2)
                .lineLimit(2)
            }
            if hasLines {
                Text(statusText(digest))
                    .font(.footnote)
                    .foregroundStyle(Ink.ink3)
                    .contentTransition(.numericText())
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
                .foregroundStyle(Ink.indigo)
                .buttonStyle(.plain)
                if let error = coordinator.lastError, coordinator.unprocessedCount(day: day) > 0 {
                    Text(error).font(.footnote).foregroundStyle(Ink.vermilion)
                }
            }
        }
        .animation(.snappy, value: day)
    }

    /// 天空画的是哪个时刻：今天就是现在；以前的日子取最后一段的时刻。
    private func heroHour(_ digest: Digest?) -> CGFloat {
        if Store.isDemo { return 10.0 }
        if day == Store.dayKey(Date()) { return SkyPalette.hour(of: Date()) }
        if let last = digest?.chapters?.map({ $0.end }).max() { return SkyPalette.hour(of: last) }
        return 18
    }

    /// 地平线上的光点：每一段按时刻排开（早 6 点到夜 12 点）。
    private func heroMarks(_ digest: Digest?) -> [(CGFloat, RGB)] {
        (digest?.chapters ?? []).map { c in
            let x = (SkyPalette.hour(of: c.start) - 6) / 18
            return (max(0, min(1, x)), Daylight.rgb(c.start))
        }
    }

    /// 画上压一行小字：几段、多长、在哪。
    private func heroCaption(_ digest: Digest?) -> some View {
        let chapters = digest?.chapters ?? []
        let minutes = chapters.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
        var parts: [String] = []
        if !chapters.isEmpty { parts.append("\(chapters.count) 段") }
        if minutes >= 1 { parts.append(minutes >= 60 ? String(format: "%.1f 小时", minutes / 60) : "\(Int(minutes)) 分钟") }
        if let last = sensor.places(from: Store.date(fromDayKey: day), to: Store.date(fromDayKey: day).addingTimeInterval(86_400)).last?.1 { parts.append(last) }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    /// 这一天依次去过的地方。
    private var footprint: String? {
        let start = Store.date(fromDayKey: day)
        let places = sensor.places(from: start, to: start.addingTimeInterval(86_400)).map { $0.1 }
        return places.isEmpty ? nil : places.joined(separator: " → ")
    }

    private func statusText(_ digest: Digest?) -> String {
        if coordinator.working { return coordinator.agentStatus ?? "正在整理新内容…" }
        if transcriber.busy { return "正在转写…" }
        let waiting = coordinator.unprocessedCount(day: day)
        let base = digest?.stats ?? DigestEngine.stats(lines: store.lines(on: day), segments: store.segments(on: day))
        return waiting > 0 ? "\(base)，\(waiting) 句新内容待整理" : base
    }

    private func shift(_ delta: Int) {
        let date = Calendar.current.date(byAdding: .day, value: delta, to: Store.date(fromDayKey: day)) ?? Date()
        withAnimation(.snappy) { day = Store.dayKey(date) }
    }

    private var isLive: Bool {
        if Store.isDemo, UserDefaults.standard.bool(forKey: "grow") { return true }
        if coordinator.working || transcriber.busy { return true }
        guard day == Store.dayKey(Date()), let last = store.segments(on: day).map({ $0.start.addingTimeInterval($0.duration) }).max() else { return false }
        return Date().timeIntervalSince(last) < 180
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(Ink.serif(21, relativeTo: .title2)).foregroundStyle(Ink.ink)
    }

    // MARK: 要跟进的

    @ViewBuilder
    private func followUps(_ digest: Digest?) -> some View {
        let items = digest?.items ?? []
        let todos = items.filter { $0.kind == .todo }
        let decisions = items.filter { $0.kind == .decision }
        let pending = items.filter { $0.kind == .pending }
        if !todos.isEmpty { group("要你跟进的", todos, digest) }
        if !decisions.isEmpty { group("定下来的", decisions, digest) }
        if !pending.isEmpty { group("还没定的", pending, digest) }
    }

    private func group(_ title: String, _ items: [DigestItem], _ digest: Digest?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(title)
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    marker(item)
                    Button { source = item } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text)
                                .font(.body)
                                .strikethrough(item.done, color: Ink.ink3)
                                .foregroundStyle(item.done ? Ink.ink3 : Ink.ink)
                                .lineSpacing(3)
                                .multilineTextAlignment(.leading)
                            if let meta = meta(item, digest) {
                                Text(meta).font(.footnote).foregroundStyle(Ink.ink3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 11)
                .transition(.opacity.combined(with: .move(edge: .top)))
                if item.id != items.last?.id {
                    InkRule(seed: CGFloat(item.text.count)).stroke(Ink.rule, lineWidth: 0.8).frame(height: 2).padding(.leading, 38)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: DigestItem) -> some View {
        switch item.kind {
        case .todo:
            Button {
                withAnimation(.snappy) { store.updateItem(day: day, id: item.id) { $0.done.toggle() } }
            } label: {
                InkCheckbox(done: item.done, size: 20, seed: CGFloat(item.text.count))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: item.done) { _, now in now }
            .accessibilityLabel(item.done ? "标为未完成" : "标为完成")
        case .decision:
            InkTick()
                .stroke(Ink.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 11)
                .frame(width: 26)
                .padding(.top, 6)
        default:
            Text("？")
                .font(Ink.serif(17, relativeTo: .body))
                .foregroundStyle(Ink.indigo)
                .frame(width: 26)
        }
    }

    private func meta(_ item: DigestItem, _ digest: Digest?) -> String? {
        var parts: [String] = []
        if item.kind == .todo {
            if let owner = item.owner { parts.append(owner) }
            if let due = item.due { parts.append(item.dueDate == nil ? "\(due)（日期待确认）" : "\(due)前") }
        }
        if let id = item.chapterID, let chapter = digest?.chapters?.first(where: { $0.id == id }) {
            parts.append("出自「\(chapter.title)」")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    // MARK: 页脚与空状态

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            InkRule(seed: 7).stroke(Ink.rule, lineWidth: 1).frame(height: 2)
            Text(segmentSummary).font(.caption).foregroundStyle(Ink.ink3).lineSpacing(3).padding(.top, 6)
            HStack(spacing: 22) {
                Button("重新整理") { confirmFull = true }.disabled(coordinator.working)
                Button("重新转写") { confirmRetranscribe = true }.disabled(transcriber.busy)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Ink.indigo)
            .buttonStyle(.plain)
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
                .font(Ink.serif(21, relativeTo: .title3))
                .foregroundStyle(Ink.ink)
            Text(pending > 0 ? "转写完会出现在这里。" : "在 Apple Watch 上打开拾言，点「开始录音」。录音边录边同步过来，攒够一段就长出一节。")
                .font(.subheadline)
                .foregroundStyle(Ink.ink2)
                .lineSpacing(4)
        }
    }
}

extension View {
    /// 统一的卡片底。
    func card() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Paper.bubble))
    }
}

/// 回到顶部 / 跳到最新。
struct JumpButtons: View {
    let showTop: Bool
    let showBottom: Bool
    let onTop: () -> Void
    let onBottom: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if showTop { button("arrow.up", "回到顶部", onTop) }
            if showBottom { button("arrow.down", "跳到最新", onBottom) }
        }
        .animation(.snappy(duration: 0.25), value: showTop)
        .animation(.snappy(duration: 0.25), value: showBottom)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.ink)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Ink.paper))
                .overlay(InkRing(seed: symbol.count == 8 ? 1 : 4).stroke(Ink.ink.opacity(0.7), lineWidth: 1).padding(1))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
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
            .overlay(Capsule().strokeBorder(warn ? Ink.vermilion.opacity(0.6) : Ink.rule, lineWidth: 0.8))
            .foregroundStyle(warn ? Ink.vermilion : Ink.ink2)
    }
}
