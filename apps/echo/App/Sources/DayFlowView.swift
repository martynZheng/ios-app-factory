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
    @State private var mountedAt = Date()
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
        let sorted = chapters.sorted { $0.start < $1.start }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(chapter: chapter,
                           next: index + 1 < sorted.count ? sorted[index + 1].start : nil,
                           points: items.filter { $0.kind == .point && $0.chapterID == chapter.id },
                           followUps: items.filter { $0.kind != .point && $0.chapterID == chapter.id }.count,
                           delay: delay(index),
                           animate: { index >= initialCount || Date().timeIntervalSince(mountedAt) < 1.5 })
                    .modifier(ZoomSource(id: chapter.id, namespace: namespace))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(chapter) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            }
            EndRow(live: live, end: chapters.map { $0.end }.max())
                .id("flow-end")
        }
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.88), value: chapters.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("这一天的经过，共 \(chapters.count) 段")
    }
}

// MARK: - 栅格

private enum Flow {
    static let timeColumn: CGFloat = 50
    static let rail: CGFloat = 24
    static let dot: CGFloat = 14
    static let dotY: CGFloat = 27      // 色点中心，对齐卡片里标题第一行
}

// MARK: - 一段

private struct ChapterRow: View {
    let chapter: Chapter
    /// 下一段开始的时刻：线的颜色从这一段渐变过去
    let next: Date?
    let points: [DigestItem]
    let followUps: Int
    let delay: Double
    /// 滚动回来时不再重播入场动画，避免一卡一卡的
    let animate: () -> Bool
    @State private var shown = false

    private var seed: CGFloat { CGFloat(abs(chapter.id.hashValue % 97)) / 9 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Daylight.time(chapter.start))
                    .font(Ink.clock(15))
                    .foregroundStyle(Ink.ink)
                Text(Daylight.minutes(chapter))
                    .font(.caption2)
                    .foregroundStyle(Ink.ink3)
            }
            .frame(width: Flow.timeColumn, alignment: .leading)
            .padding(.top, 16)

            Color.clear
                .frame(width: Flow.rail, height: 1)

            content
                .padding(14)
                .background(wash)
                .padding(.bottom, 22)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 8)
        }
        .background(alignment: .topLeading) {
            rail
                .frame(width: Flow.rail)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, Flow.timeColumn)
        }
        .onAppear {
            guard !shown else { return }
            if animate() {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay)) { shown = true }
            } else {
                shown = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("查看这一段")
    }

    private var tint: RGB { Daylight.rgb(chapter.start) }
    @Environment(\.colorScheme) private var scheme

    /// 这一段的底：那个时刻的颜色淡淡一抹，左上角浓一点，像粉彩擦过。
    private var wash: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let strong = scheme == .dark ? 0.20 : 0.16
        return shape
            .fill(LinearGradient(colors: [tint.color(strong), tint.color(strong * 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(uiImage: PaperGrain.tile)
                    .resizable(resizingMode: .tile)
                    .opacity(0.10)
                    .blendMode(scheme == .dark ? .screen : .multiply)
                    .clipShape(shape)
            )
            .overlay(shape.strokeBorder(tint.color(scheme == .dark ? 0.35 : 0.28), lineWidth: 0.8))
    }

    /// 蜡笔点 + 往下的一笔蜡笔线，颜色从这一段的时刻过渡到下一段。
    private var rail: some View {
        ZStack(alignment: .top) {
            CrayonRail(from: tint, to: next.map { Daylight.rgb($0) } ?? tint, seed: "rail-\(chapter.id)")
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .padding(.top, Flow.dotY + Flow.dot / 2 + 2)
                .scaleEffect(x: 1, y: shown ? 1 : 0, anchor: .top)
            CrayonDot(color: tint, size: Flow.dot, seed: "dot-\(chapter.id)")
                .padding(.top, Flow.dotY - Flow.dot / 2)
                .scaleEffect(shown ? 1 : 0.2)
        }
    }

    /// “当时在做什么 · 在哪 · 什么状态”
    private var whereLine: String? {
        let parts = [chapter.situation, chapter.setting].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chapter.title)
                .font(Ink.serif(19, relativeTo: .title3))
                .foregroundStyle(Ink.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let where_ = whereLine {
                Label {
                    Text(where_)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .labelStyle(TightLabel())
                .font(.caption)
                .foregroundStyle(Ink.ink3)
                .lineLimit(1)
                .padding(.top, 6)
            }
            if chapter.speaker != nil || followUps > 0 {
                HStack(spacing: 14) {
                    if let speaker = chapter.speaker { SpeakerTag(name: speaker) }
                    if followUps > 0 {
                        Text("\(followUps) 件要跟进")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Ink.vermilion)
                    }
                }
                .padding(.top, 8)
            }
            if !chapter.summary.isEmpty {
                Text(chapter.summary)
                    .font(.subheadline)
                    .foregroundStyle(Ink.ink2)
                    .lineSpacing(5)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points.prefix(3)) { point in
                        HStack(alignment: .top, spacing: 10) {
                            TwigMark(color: Ink.ink2)
                            Text(point.text)
                                .font(.subheadline)
                                .foregroundStyle(Ink.ink)
                                .lineSpacing(3)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if points.count > 3 {
                        Text("另有 \(points.count - 3) 条")
                            .font(.caption)
                            .foregroundStyle(Ink.ink3)
                            .padding(.leading, 19)
                    }
                }
                .padding(.top, 12)
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
                .font(live ? Ink.serif(15, relativeTo: .subheadline) : Ink.clock(15))
                .foregroundStyle(live ? Ink.vermilion : Ink.ink3)
                .frame(width: Flow.timeColumn, alignment: .leading)
            ZStack {
                if live && !reduceMotion {
                    Circle()
                        .fill(Ink.vermilion.opacity(0.3))
                        .frame(width: 22, height: 22)
                        .scaleEffect(pulse ? 1.2 : 0.4)
                        .opacity(pulse ? 0 : 1)
                }
                if live {
                    Circle().fill(Ink.vermilion).frame(width: 7, height: 7)
                } else {
                    InkRing(seed: 5).stroke(Ink.ink3, lineWidth: 1).frame(width: 7, height: 7)
                }
            }
            .frame(width: Flow.rail)
            Text(live ? "还在记录，新的一段会接在这里" : "这一天记到这里")
                .font(.footnote)
                .foregroundStyle(Ink.ink3)
        }
        .padding(.bottom, 6)
        .onAppear {
            guard live else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 图标和文字挨得更近的 Label。
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
