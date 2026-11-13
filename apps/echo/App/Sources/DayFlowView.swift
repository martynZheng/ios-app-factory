import SwiftUI

/// 这一天的经过：一条往下延展的时间线。
/// 左边是时刻，中间一根细线串起每一章，右边是这一章讲了什么。
/// 新的一章出现在最下面，线跟着往下画，末端的“现在”标记随之下移。
struct DayFlowView: View {
    let chapters: [Chapter]
    let items: [DigestItem]
    let live: Bool
    let namespace: Namespace.ID
    let onTap: (Chapter) -> Void

    /// 首次出现时已有的章数：这些依次入场；之后新增的立即出现。
    @State private var initialCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(chapters: [Chapter], items: [DigestItem], live: Bool, namespace: Namespace.ID, onTap: @escaping (Chapter) -> Void) {
        self.chapters = chapters
        self.items = items
        self.live = live
        self.namespace = namespace
        self.onTap = onTap
        _initialCount = State(initialValue: chapters.count)
    }

    private func delay(_ index: Int) -> Double {
        if reduceMotion { return 0 }
        return index < initialCount ? 0.08 + Double(min(index, 8)) * 0.07 : 0.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(chapter: chapter,
                           points: items.filter { $0.kind == .point && $0.chapterID == chapter.id },
                           followUps: items.filter { $0.kind != .point && $0.chapterID == chapter.id }.count,
                           delay: delay(index))
                    .modifier(ZoomSource(id: chapter.id, namespace: namespace))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(chapter) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            }
            EndRow(live: live, end: chapters.last?.end)
                .id("flow-end")
        }
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88), value: chapters.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("这一天的经过，共 \(chapters.count) 段")
    }
}

// MARK: - 栅格

private enum Flow {
    static let timeColumn: CGFloat = 54
    static let rail: CGFloat = 26
    static let dot: CGFloat = 9
    static let dotY: CGFloat = 12      // 圆点中心，对齐标题第一行
}

// MARK: - 一段

private struct ChapterRow: View {
    let chapter: Chapter
    let points: [DigestItem]
    let followUps: Int
    let delay: Double
    @State private var shown = false

    var body: some View {
        let color = Daylight.color(chapter.start)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Daylight.time(chapter.start))
                    .font(.system(size: 17, weight: .semibold))
                    .fontWidth(.condensed)
                    .monospacedDigit()
                Text(Daylight.minutes(chapter))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: Flow.timeColumn, alignment: .leading)
            .padding(.top, 1)

            rail(color)
                .frame(width: Flow.rail)

            content(color)
                .padding(.bottom, 34)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay)) { shown = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("查看这一段")
    }

    /// 细线 + 圆点。线从圆点往下画到这一段结束。
    private func rail(_ color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Paper.rail)
                    .frame(width: 1.5, height: max(0, geo.size.height - Flow.dotY))
                    .scaleEffect(x: 1, y: shown ? 1 : 0, anchor: .top)
                    .offset(y: Flow.dotY)
                Circle()
                    .fill(color)
                    .frame(width: Flow.dot, height: Flow.dot)
                    .background(Circle().fill(color.opacity(0.22)).frame(width: 19, height: 19).opacity(shown ? 1 : 0))
                    .scaleEffect(shown ? 1 : 0.01)
                    .offset(y: Flow.dotY - Flow.dot / 2)
            }
            .frame(width: geo.size.width)
        }
    }

    private func content(_ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chapter.title)
                .font(.system(size: 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if chapter.speaker != nil || followUps > 0 {
                HStack(spacing: 8) {
                    if let speaker = chapter.speaker { SpeakerTag(name: speaker, color: color) }
                    if followUps > 0 {
                        Label("\(followUps) 件要跟进", systemImage: "checklist")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.top, 8)
            }
            if !chapter.summary.isEmpty {
                Text(chapter.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(points.prefix(3)) { point in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(color).frame(width: 5, height: 5).padding(.top, 7)
                            Text(point.text)
                                .font(.subheadline)
                                .lineSpacing(2)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if points.count > 3 {
                        Text("另有 \(points.count - 3) 条")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 15)
                    }
                }
                .padding(.top, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
    }
}

// MARK: - 末端（现在）

private struct EndRow: View {
    let live: Bool
    let end: Date?
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(live ? "现在" : (end.map { Daylight.time($0) } ?? ""))
                .font(.system(size: 17, weight: .semibold))
                .fontWidth(.condensed)
                .monospacedDigit()
                .foregroundStyle(live ? Color.red : .secondary)
                .frame(width: Flow.timeColumn, alignment: .leading)
            ZStack {
                if live && !reduceMotion {
                    Circle()
                        .fill(Color.red.opacity(0.35))
                        .frame(width: 22, height: 22)
                        .scaleEffect(pulse ? 1.25 : 0.4)
                        .opacity(pulse ? 0 : 1)
                }
                Circle()
                    .strokeBorder(live ? Color.red : Paper.rail, lineWidth: live ? 0 : 1.5)
                    .background(Circle().fill(live ? Color.red : Color.clear))
                    .frame(width: Flow.dot, height: Flow.dot)
            }
            .frame(width: Flow.rail)
            Text(live ? "正在记录，新的内容会接着出现在这里" : "这一天记录到这里")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
        .onAppear {
            guard live else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
    }
}
