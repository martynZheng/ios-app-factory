import SwiftUI

/// 竖向鱼骨图：鱼尾在上（这一天的开始），脊柱向下是时间，鱼头在最下面（现在）。
/// 每一章是一根斜向上的大骨头，章里的要点是从它分出来的小骨头。
/// 新的一章从鱼头上方长出来，鱼头跟着往下游——像聊天一样，最新的总在底部。
struct FishboneView: View {
    let chapters: [Chapter]
    let items: [DigestItem]
    let live: Bool
    let namespace: Namespace.ID
    let onTap: (Chapter) -> Void

    /// 首次出现时已有的章数：这些依次入场；之后新增的立即生长。
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

    private func color(_ index: Int) -> Color {
        guard !chapters.isEmpty else { return .accentColor }
        return Daylight.color(chapters[min(max(index, 0), chapters.count - 1)].start)
    }

    private func delay(_ index: Int) -> Double {
        if reduceMotion { return 0 }
        return index < initialCount ? 0.12 + Double(min(index, 8)) * 0.09 : 0.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TailRow(color: color(0), start: chapters.first?.start)
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                BoneRow(chapter: chapter,
                        points: items.filter { $0.kind == .point && $0.chapterID == chapter.id },
                        followUps: items.filter { $0.kind != .point && $0.chapterID == chapter.id }.count,
                        color: color(index), next: color(index + 1), delay: delay(index))
                    .modifier(ZoomSource(id: chapter.id, namespace: namespace))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(chapter) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)), removal: .opacity))
            }
            HeadRow(color: color(chapters.count - 1), live: live, end: chapters.last?.end)
                .id("fish-head")
        }
        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86), value: chapters.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("这一天的经过，共 \(chapters.count) 章")
    }
}

// MARK: - 几何常量

private enum Spine {
    static let x: CGFloat = 19          // 脊柱的水平位置
    static let gutter: CGFloat = 60     // 文字左缘
    static let width: CGFloat = 3
    static let nodeY: CGFloat = 62      // 大骨头在脊柱上的起点
    static let ribEnd = CGPoint(x: 52, y: 34)
}

// MARK: - 一章 = 一根大骨头

private struct BoneRow: View {
    let chapter: Chapter
    let points: [DigestItem]
    let followUps: Int
    let color: Color
    let next: Color
    let delay: Double
    @State private var shown = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: Spine.gutter)
            content
                .padding(.top, 20)
                .padding(.bottom, 30)
                .padding(.trailing, 6)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
        }
        .background(alignment: .topLeading) { skeleton }
        .onAppear {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.82).delay(delay)) { shown = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("查看这一章")
    }

    /// 脊柱这一段 + 大骨头 + 节点。
    private var skeleton: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(LinearGradient(colors: [color, next], startPoint: .top, endPoint: .bottom))
                    .frame(width: Spine.width, height: geo.size.height)
                    .offset(x: Spine.x - Spine.width / 2)
                Path { p in
                    p.move(to: CGPoint(x: Spine.x, y: Spine.nodeY))
                    p.addLine(to: Spine.ribEnd)
                }
                .trim(from: 0, to: shown ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                Circle()
                    .fill(color)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Paper.background, lineWidth: 3))
                    .scaleEffect(shown ? 1 : 0.01)
                    .position(x: Spine.x, y: Spine.nodeY)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Daylight.time(chapter.start))
                    .font(.system(size: 24, weight: .bold))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                Text(Daylight.minutes(chapter))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if followUps > 0 {
                    Label("\(followUps)", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("\(followUps) 件要跟进")
                }
            }
            Text(chapter.title)
                .font(.system(size: 19, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if let speaker = chapter.speaker {
                SpeakerTag(name: speaker, color: color).padding(.top, 7)
            }
            if !chapter.summary.isEmpty {
                Text(chapter.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points.prefix(3)) { point in
                        HStack(alignment: .top, spacing: 11) {
                            TwigMark(color: color)
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
                            .padding(.leading, 20)
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 鱼尾（一天的开始）

private struct TailRow: View {
    let color: Color
    let start: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Path { p in
                p.move(to: CGPoint(x: Spine.x - 13, y: 2))
                p.addQuadCurve(to: CGPoint(x: Spine.x, y: 22), control: CGPoint(x: Spine.x - 4, y: 10))
                p.addQuadCurve(to: CGPoint(x: Spine.x + 13, y: 2), control: CGPoint(x: Spine.x + 4, y: 10))
                p.move(to: CGPoint(x: Spine.x, y: 22))
                p.addLine(to: CGPoint(x: Spine.x, y: 34))
            }
            .stroke(color, style: StrokeStyle(lineWidth: Spine.width, lineCap: .round, lineJoin: .round))
            .frame(width: Spine.gutter, height: 34, alignment: .topLeading)
            if let start {
                Text("\(Daylight.time(start)) 开始记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 鱼头（现在）

private struct HeadRow: View {
    let color: Color
    let live: Bool
    let end: Date?
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(color).frame(width: Spine.width, height: 8).offset(x: Spine.x - Spine.width / 2)
                FishHead()
                    .stroke(color, style: StrokeStyle(lineWidth: Spine.width, lineCap: .round, lineJoin: .round))
                    .frame(width: 34, height: 40)
                    .offset(x: Spine.x - 17, y: 6)
                if live && !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.7), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .scaleEffect(pulse ? 1.6 : 0.6)
                        .opacity(pulse ? 0 : 1)
                        .position(x: Spine.x, y: 21)
                }
                Circle().fill(color).frame(width: 7, height: 7).position(x: Spine.x, y: 21)
            }
            .frame(width: Spine.gutter, height: 50, alignment: .topLeading)
            Group {
                if live {
                    Text("还在记录，新内容会从这里长出来")
                } else if let end {
                    Text("记录到 \(Daylight.time(end))")
                }
            }
            .font(.footnote)
            .foregroundStyle(live ? Color.accentColor : .secondary)
        }
        .padding(.bottom, 8)
        .onAppear {
            guard live else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 朝下的鱼头轮廓。
private struct FishHead: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.minX + 1, y: r.maxY * 0.78))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - 1, y: r.maxY * 0.78))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: r.minY + 8))
        return p
    }
}
