import SwiftUI

// MARK: - 设计基础

/// 一天里的光：凌晨靛蓝 → 清晨杏色 → 上午金 → 正午天蓝 → 傍晚橘 → 入夜紫。
/// 时间线上每一段的圆点颜色取自它发生的时刻。
enum Daylight {
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0, (0.30, 0.34, 0.78)), (5, (0.94, 0.58, 0.40)), (9, (0.90, 0.62, 0.14)),
        (13, (0.18, 0.58, 0.90)), (17, (0.94, 0.46, 0.28)), (20, (0.52, 0.44, 0.94)), (24, (0.30, 0.34, 0.78)),
    ]

    static func color(_ date: Date) -> Color {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        for i in 1..<stops.count where h <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let t = (h - a.0) / (b.0 - a.0)
            return Color(red: a.1.0 + (b.1.0 - a.1.0) * t, green: a.1.1 + (b.1.1 - a.1.1) * t, blue: a.1.2 + (b.1.2 - a.1.2) * t)
        }
        return Color(red: 0.30, green: 0.34, blue: 0.78)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    static func span(_ chapter: Chapter) -> String {
        let a = time(chapter.start), b = time(chapter.end)
        return a == b ? a : "\(a)–\(b)"
    }

    static func minutes(_ chapter: Chapter) -> String {
        let m = max(1, Int((chapter.end.timeIntervalSince(chapter.start) / 60).rounded()))
        return "\(m) 分钟"
    }
}

/// 旧名字，统一指向墨与纸。
enum Paper {
    static let background = Ink.paper
    static let bubble = Ink.wash
    static let rail = Ink.rule
    static let hairline = Ink.rule
}

/// 斜着的小记号：章节详情里要点前面的标记。
struct Twig: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

struct TwigMark: View {
    let color: Color
    var body: some View {
        Twig()
            .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            .frame(width: 9, height: 6)
            .padding(.top, 9)
            .accessibilityHidden(true)
    }
}

// MARK: - iOS 18 缩放转场（低版本自动忽略）

struct ZoomSource: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct ZoomDestination: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

// MARK: - 转写气泡（像聊天消息）

/// 一句转写。时间像聊天软件一样嵌在气泡右下角；点按回听，长按有菜单。
struct TranscriptBubble: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    let line: Line
    var tail = true
    var highlight: Color? = nil

    var body: some View {
        let hasAudio = store.segment(line.segmentID)?.hasAudio ?? false
        let playing = player.playingSegment == line.segmentID
        let stamp = Daylight.time(line.time) + (line.edited ? " 已改" : "")
        // 末尾放一段透明的时间文字占位，再把真正的时间叠在右下角
        (Text(line.text) + Text("　\(stamp)").font(.caption2).foregroundColor(.clear))
            .font(.body)
            .foregroundStyle(Ink.ink)
            .lineSpacing(3)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    if playing {
                        Image(systemName: "speaker.wave.2.fill")
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    Text(stamp)
                }
                .font(.caption2)
                .foregroundStyle(playing ? Ink.vermilion : Ink.ink3)
                .padding(.trailing, 10)
                .padding(.bottom, 6)
            }
            .background {
                let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: tail ? 4 : 16,
                                                   bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
                shape.fill(playing ? Ink.vermilion.opacity(0.08) : (highlight?.opacity(0.08) ?? Ink.wash))
                    .overlay(shape.strokeBorder(playing ? Ink.vermilion.opacity(0.5) : Ink.rule, lineWidth: 0.7))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if hasAudio { player.toggle(segmentID: line.segmentID, at: line.offset) }
            }
            .animation(.snappy(duration: 0.25), value: playing)
            .accessibilityElement(children: .combine)
            .accessibilityHint(hasAudio ? "轻点回听" : "")
    }
}

/// 一组连续的转写气泡。
struct BubbleStack: View {
    let lines: [Line]
    var highlight: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines) { line in
                TranscriptBubble(line: line, tail: line.id == lines.last?.id, highlight: highlight)
            }
        }
    }
}

// MARK: - 章节详情

struct ChapterSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let chapter: Chapter
    let day: String

    var body: some View {
        let color = Ink.ink
        let items = (store.db.digests[day]?.items ?? []).filter { $0.chapterID == chapter.id }
        let points = items.filter { $0.kind == .point }
        let others = items.filter { $0.kind != .point }
        let lines = chapter.sourceLineIDs.compactMap { store.line($0) }.sorted { $0.time < $1.time }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PaintedSky(hour: SkyPalette.hour(of: chapter.start), seed: "chapter-\(chapter.id)",
                               marks: [(0.5, Daylight.rgb(chapter.start))], corner: 20)
                        .frame(height: 150)
                        .padding(.bottom, 18)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Daylight.span(chapter))
                            .font(Ink.clock(17))
                            .foregroundStyle(Ink.ink2)
                        Text(Daylight.minutes(chapter)).font(.footnote).foregroundStyle(Ink.ink3)
                    }
                    Text(chapter.title)
                        .font(Ink.serif(26, relativeTo: .title))
                        .foregroundStyle(Ink.ink)
                        .lineSpacing(4)
                        .padding(.top, 6)
                    if let speaker = chapter.speaker {
                        SpeakerTag(name: speaker, color: color).padding(.top, 10)
                    }
                    if !chapter.summary.isEmpty {
                        Text(chapter.summary)
                            .font(.body)
                            .foregroundStyle(Ink.ink2)
                            .lineSpacing(5)
                            .padding(.top, 14)
                    }
                    if !points.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(points) { point in
                                NavigationLink { SourceDetail(item: point) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        TwigMark(color: color)
                                        Text(point.text).font(.body).foregroundStyle(Ink.ink).lineSpacing(3).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 22)
                    }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(others) { item in
                                NavigationLink { SourceDetail(item: item) } label: { ItemRow(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 22)
                    }
                    InkRule(seed: 3).stroke(Ink.rule, lineWidth: 1).frame(height: 2).padding(.top, 30)
                    Text("原话")
                        .font(Ink.serif(19, relativeTo: .title3))
                        .foregroundStyle(Ink.ink)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                    if lines.isEmpty {
                        Text("原始转写已被删除").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        BubbleStack(lines: lines)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PaperBackground())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Ink.ink)
        .presentationDetents([.large])
    }
}

struct SpeakerTag: View {
    let name: String
    var color: Color = Ink.indigo
    var body: some View {
        HStack(spacing: 6) {
            InkRing(seed: 2).stroke(Ink.indigo, lineWidth: 1).frame(width: 8, height: 8)
            Text(name).font(.footnote.weight(.medium)).foregroundStyle(Ink.indigo)
        }
    }
}

/// 一条整理结果所依据的原话（导航内）。
struct SourceDetail: View {
    @EnvironmentObject private var store: Store
    let item: DigestItem

    var body: some View {
        let lines = item.sourceLineIDs.compactMap { store.line($0) }.sorted { $0.time < $1.time }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.text).font(Ink.serif(21, relativeTo: .title3)).foregroundStyle(Ink.ink).lineSpacing(4)
                Text("依据的原话").font(.subheadline).foregroundStyle(Ink.ink3)
                if lines.isEmpty {
                    Text("原始转写已被删除").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    BubbleStack(lines: lines)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Paper.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一条整理结果所依据的原话（弹出）。
struct SourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: DigestItem

    var body: some View {
        NavigationStack {
            SourceDetail(item: item)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
