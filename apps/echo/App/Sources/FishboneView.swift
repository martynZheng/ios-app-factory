import SwiftUI

/// 一天里的光：凌晨靛蓝 → 清晨杏色 → 上午金 → 正午天蓝 → 傍晚橘 → 入夜紫。
/// 鱼骨图上每一章的颜色取自它发生的时刻，整条脊柱就是这一天的天色。
enum Daylight {
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0, (0.22, 0.26, 0.62)), (5, (0.93, 0.60, 0.42)), (9, (0.91, 0.64, 0.16)),
        (13, (0.20, 0.60, 0.90)), (17, (0.93, 0.47, 0.30)), (20, (0.48, 0.42, 0.92)), (24, (0.22, 0.26, 0.62)),
    ]

    static func color(_ date: Date) -> Color {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        for i in 1..<stops.count where h <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            let t = (h - a.0) / (b.0 - a.0)
            return Color(red: a.1.0 + (b.1.0 - a.1.0) * t, green: a.1.1 + (b.1.1 - a.1.1) * t, blue: a.1.2 + (b.1.2 - a.1.2) * t)
        }
        return Color(red: 0.22, green: 0.26, blue: 0.62)
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

/// 鱼骨图：一天是一条向前游的鱼。尾巴是这一天的开始，脊柱是时间，
/// 每一章是一根斜着的骨头，上下交替；鱼头在“现在”，新的一章从头后面长出来。
struct FishboneView: View {
    let chapters: [Chapter]
    let items: [DigestItem]
    let live: Bool
    let onTap: (Chapter) -> Void

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let step: CGFloat = 156
    private let tailX: CGFloat = 40
    private var mid: CGFloat { Bone.blockH + Bone.gap + 8 }
    private var height: CGFloat { mid * 2 }
    private func x(_ index: Int) -> CGFloat { tailX + 36 + Bone.reach + CGFloat(index) * step }
    private var headX: CGFloat { x(max(chapters.count - 1, 0)) + 54 }

    private var spineColors: [Color] {
        let colors = chapters.map { Daylight.color($0.start) }
        return colors.count >= 2 ? colors : [colors.first ?? .accentColor, colors.first ?? .accentColor]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    TailShape()
                        .stroke(spineColors[0], style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: 30, height: 52)
                        .offset(x: tailX - 30, y: mid - 26)
                        .opacity(drawn ? 1 : 0)
                    Capsule()
                        .fill(LinearGradient(colors: spineColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: drawn ? headX - tailX : 0, height: 4)
                        .offset(x: tailX, y: mid - 2)
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        Bone(chapter: chapter,
                             points: items.filter { $0.kind == .point && $0.chapterID == chapter.id },
                             top: index % 2 == 0, mid: mid, delay: reduceMotion ? 0 : 0.25 + Double(min(index, 12)) * 0.12,
                             onTap: { onTap(chapter) })
                            .frame(width: Bone.reach + 12, height: height)
                            .offset(x: x(index) - Bone.reach)
                    }
                    HeadView(color: spineColors[spineColors.count - 1], live: live)
                        .frame(width: 62, height: 68)
                        .offset(x: headX - 2, y: mid - 34)
                        .opacity(drawn ? 1 : 0)
                    Color.clear.frame(width: 1, height: 1).offset(x: headX + 90).id("head")
                }
                .frame(width: headX + 96, height: height, alignment: .topLeading)
                .animation(.spring(response: 0.7, dampingFraction: 0.85), value: chapters.count)
            }
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.0)) { drawn = true }
                if live {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        withAnimation(.easeInOut(duration: 0.8)) { proxy.scrollTo("head", anchor: .trailing) }
                    }
                }
            }
            .onChange(of: chapters.count) { _, _ in
                withAnimation(.easeInOut(duration: 0.7)) { proxy.scrollTo("head", anchor: .trailing) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("这一天的鱼骨图，共 \(chapters.count) 章")
    }
}

/// 一根骨头：斜的肋骨 + 脊柱上的节点 + 这一章的文字。
private struct Bone: View {
    static let blockW: CGFloat = 236
    static let blockH: CGFloat = 262
    static let gap: CGFloat = 16
    /// 文字块左缘到脊柱节点的水平距离
    static let reach: CGFloat = blockW + 46

    let chapter: Chapter
    let points: [DigestItem]
    let top: Bool
    let mid: CGFloat
    let delay: Double
    let onTap: () -> Void
    @State private var shown = false

    var body: some View {
        let color = Daylight.color(chapter.start)
        ZStack(alignment: .topLeading) {
            RibShape(from: CGPoint(x: Bone.reach, y: mid),
                     to: CGPoint(x: Bone.reach - 34, y: top ? mid - 178 : mid + 178))
                .trim(from: 0, to: shown ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(Paper.background, lineWidth: 3))
                .scaleEffect(shown ? 1 : 0.01)
                .position(x: Bone.reach, y: mid)
            text(color)
                .frame(width: Bone.blockW, height: Bone.blockH, alignment: top ? .bottomLeading : .topLeading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .position(x: Bone.blockW / 2, y: top ? mid - Bone.gap - Bone.blockH / 2 : mid + Bone.gap + Bone.blockH / 2)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : (top ? 10 : -10))
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(delay)) { shown = true }
        }
    }

    private func text(_ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Daylight.time(chapter.start))
                    .font(.system(size: 30, weight: .bold))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                Text(Daylight.minutes(chapter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(chapter.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let speaker = chapter.speaker {
                Text(speaker).font(.footnote.weight(.semibold)).foregroundStyle(color)
            }
            if !chapter.summary.isEmpty {
                Text(chapter.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(points.prefix(2)) { point in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Capsule().fill(color).frame(width: 9, height: 2.5).offset(y: -3.5)
                    Text(point.text).font(.footnote).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if points.count > 2 {
                Text("另有 \(points.count - 2) 条").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("查看这一章")
    }
}

private struct RibShape: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

private struct TailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.midX * 0.9, y: rect.midY))
        return p
    }
}

/// 鱼头：线描轮廓 + 一只眼睛。还在记录时眼睛会一下一下地亮。
private struct HeadView: View {
    let color: Color
    let live: Bool
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addQuadCurve(to: CGPoint(x: w, y: h / 2), control: CGPoint(x: w * 0.78, y: h * 0.04))
                    p.addQuadCurve(to: CGPoint(x: 0, y: h), control: CGPoint(x: w * 0.78, y: h * 0.96))
                    p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: w * 0.22, y: h / 2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if live {
                    Circle().stroke(color.opacity(0.6), lineWidth: 2)
                        .frame(width: 20, height: 20)
                        .scaleEffect(pulse ? 1.5 : 0.6)
                        .opacity(pulse ? 0 : 1)
                        .position(x: w * 0.52, y: h * 0.36)
                }
                Circle().fill(color).frame(width: 8, height: 8).position(x: w * 0.52, y: h * 0.36)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel(live ? "还在记录" : "记录到这里")
    }
}

/// 页面底色：冷调的纸白 / 夜里的深蓝。
enum Paper {
    static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.075, blue: 0.125, alpha: 1)
            : UIColor(red: 0.965, green: 0.970, blue: 0.980, alpha: 1)
    })
}

// MARK: 章节详情

struct ChapterSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let chapter: Chapter
    let day: String

    var body: some View {
        let items = (store.db.digests[day]?.items ?? []).filter { $0.chapterID == chapter.id }
        let points = items.filter { $0.kind == .point }
        let others = items.filter { $0.kind != .point }
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Daylight.span(chapter) + (chapter.speaker.map { "，\($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if !chapter.summary.isEmpty { Text(chapter.summary) }
                    }
                }
                if !points.isEmpty {
                    Section("要点") {
                        ForEach(points) { point in
                            NavigationLink { SourceDetail(item: point) } label: { Text(point.text) }
                        }
                    }
                }
                if !others.isEmpty {
                    Section("这一章里的决定 / 待办 / 待确认") {
                        ForEach(others) { item in
                            NavigationLink { SourceDetail(item: item) } label: { ItemRow(item: item) }
                        }
                    }
                }
                Section("原始转写") {
                    let lines = chapter.sourceLineIDs.compactMap { store.line($0) }.sorted { $0.time < $1.time }
                    if lines.isEmpty { Text("来源转写已被删除").foregroundStyle(.secondary) }
                    ForEach(lines) { LineRow(line: $0) }
                }
            }
            .navigationTitle(chapter.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// 一条整理结果所依据的原句。
struct SourceDetail: View {
    @EnvironmentObject private var store: Store
    let item: DigestItem

    var body: some View {
        List {
            Section("整理结果") { Text(item.text) }
            Section("原始转写") {
                let lines = item.sourceLineIDs.compactMap { store.line($0) }
                if lines.isEmpty { Text("来源转写已被删除").foregroundStyle(.secondary) }
                ForEach(lines) { LineRow(line: $0) }
            }
        }
        .navigationTitle("来源")
        .navigationBarTitleDisplayMode(.inline)
    }
}
