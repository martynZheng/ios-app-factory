import SwiftUI

/// 时间线：像聊天记录一样，最新的在最下面，新转写的句子从底部滑入。
/// 轻点气泡回听，长按有修改 / 复制 / 删除。
struct TranscriptView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var transcriber: Transcriber
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var editing: Line?
    @State private var draft = ""
    @State private var topVisible = true
    @State private var bottomVisible = true

    private struct Cluster: Identifiable {
        let id: UUID
        let lines: [Line]
    }

    private struct Day: Identifiable {
        let id: String
        let clusters: [Cluster]
    }

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    /// 按天分组，再把间隔不超过 90 秒、同一次录音的句子并成一簇。
    private var days: [Day] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = q.isEmpty ? store.sortedLines : store.sortedLines.filter { $0.text.localizedCaseInsensitiveContains(q) }
        var result: [Day] = []
        var dayKey = ""
        var clusters: [Cluster] = []
        var current: [Line] = []
        var lastSession = ""
        func closeCluster() {
            if let first = current.first { clusters.append(Cluster(id: first.id, lines: current)) }
            current = []
        }
        func closeDay() {
            closeCluster()
            if !clusters.isEmpty { result.append(Day(id: dayKey, clusters: clusters)) }
            clusters = []
        }
        for line in all {
            let key = Store.dayKey(line.time)
            let session = store.segment(line.segmentID)?.sessionID ?? ""
            if key != dayKey {
                closeDay()
                dayKey = key
            } else if let prev = current.last, line.time.timeIntervalSince(prev.time) > 90 || session != lastSession {
                closeCluster()
            }
            current.append(line)
            lastSession = session
        }
        closeDay()
        return result
    }

    var body: some View {
        let groups = days
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 1).id("top")
                            .onAppear { topVisible = true }
                            .onDisappear { topVisible = false }
                        banners
                        if groups.isEmpty {
                            emptyState.padding(.top, 80)
                        }
                        ForEach(groups) { day in
                            DayChip(text: dayLabel(day.id))
                                .frame(maxWidth: .infinity)
                                .id("day-" + day.id)
                                .padding(.top, 14)
                                .padding(.bottom, 10)
                            ForEach(day.clusters) { cluster in
                                clusterView(cluster, maxWidth: min(geo.size.width * 0.86, 560))
                                    .padding(.bottom, 12)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { bottomVisible = true }
                            .onDisappear { bottomVisible = false }
                    }
                    .padding(.horizontal, 12)
                    .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.db.lines.count)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottom) {
                    ScrollPill(title: "回到最新", symbol: "arrow.down", show: !bottomVisible) {
                        withAnimation(.snappy(duration: 0.45)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .padding(.bottom, 12)
                }
                .toolbar {
                    if groups.count > 1 {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                ForEach(groups.reversed()) { day in
                                    Button(dayLabel(day.id)) {
                                        withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo("day-" + day.id, anchor: .top) }
                                    }
                                }
                            } label: {
                                Image(systemName: "calendar")
                            }
                            .accessibilityLabel("跳到某一天")
                        }
                    }
                }
                .onChange(of: store.db.lines.count) { old, new in
                    // 停在底部时才跟随新内容，往上翻看时不打断
                    guard new > old, query.isEmpty, bottomVisible else { return }
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .searchable(text: $query, prompt: "搜索说过的话")
        .safeAreaInset(edge: .bottom) { workingPill }
        .sheet(item: $editing) { line in editor(line) }
    }

    private func dayLabel(_ key: String) -> String {
        if key == Store.dayKey(Date()) { return "今天" }
        if key == Store.dayKey(Date().addingTimeInterval(-86_400)) { return "昨天" }
        return Self.dayTitle.string(from: Store.date(fromDayKey: key))
    }

    private func clusterView(_ cluster: Cluster, maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(cluster.lines) { line in
                TranscriptBubble(line: line, tail: line.id == cluster.lines.last?.id)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .contextMenu { menu(line) }
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menu(_ line: Line) -> some View {
        if store.segment(line.segmentID)?.hasAudio ?? false {
            Button {
                player.toggle(segmentID: line.segmentID, at: line.offset)
            } label: {
                Label(player.playingSegment == line.segmentID ? "停止回听" : "从这里回听", systemImage: "play.circle")
            }
        }
        Button { draft = line.text; editing = line } label: { Label("修改文字", systemImage: "pencil") }
        Button { UIPasteboard.general.string = line.text } label: { Label("复制", systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) {
            withAnimation(.snappy) { store.deleteLine(line.id) }
        } label: { Label("删除这一句", systemImage: "trash") }
        Button(role: .destructive) {
            if let seg = store.segment(line.segmentID) {
                withAnimation(.snappy) { store.deleteSession(seg.sessionID, tombstone: false) }
            }
        } label: { Label("删除整次录音", systemImage: "trash.slash") }
    }

    // MARK: 状态

    @ViewBuilder
    private var banners: some View {
        let problems = store.db.segments.filter { $0.status == .failed || $0.status == .blocked }
        if transcriber.authDenied {
            Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   text: "没有语音识别权限，录音无法转写。到「设置 › 拾言」里打开「语音识别」。")
                .padding(.top, 10)
        }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Notice(symbol: "exclamationmark.circle.fill", tint: .orange,
                       text: "\(problems.count) 段录音没能转写。\(problems.first?.error ?? "")")
                HStack(spacing: 20) {
                    Button("重试") { transcriber.retryAll() }
                    Button("删除这些录音", role: .destructive) { store.deleteSegments(problems.map { $0.id }) }
                }
                .font(.footnote.weight(.medium))
                .padding(.leading, 30)
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var workingPill: some View {
        let pending = store.db.segments.filter { $0.status == .pending }.count
        if pending > 0 || transcriber.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(pending > 0 ? "正在转写 \(pending) 段" : "正在转写")
                    .font(.footnote.weight(.medium))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy, value: pending)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Ink.ink3)
            Text(query.isEmpty ? "还没有转写" : "没有找到")
                .font(Ink.serif(19, relativeTo: .headline))
                .foregroundStyle(Ink.ink)
            Text(query.isEmpty ? "在手表上开始录音，说过的话会一句句出现在这里。" : "换个词再搜。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }

    private func editor(_ line: Line) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Paper.bubble))
                    .frame(minHeight: 150)
                Text("只改文字，原始录音不变。").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(18)
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle("修改转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.editLine(line.id, text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        editing = nil
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct DayChip: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            InkRule(seed: 1).stroke(Ink.rule, lineWidth: 0.8).frame(width: 36, height: 2)
            Text(text)
                .font(Ink.serif(13, relativeTo: .caption))
                .foregroundStyle(Ink.ink2)
            InkRule(seed: 4).stroke(Ink.rule, lineWidth: 0.8).frame(width: 36, height: 2)
        }
    }
}

struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.footnote).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 0.8))
    }
}
