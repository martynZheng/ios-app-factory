import SwiftUI

// MARK: - 墨与纸

/// 整个 App 的视觉：一支细墨线画在暖白纸上；夜里反过来，浅色墨线落在靛蓝纸上。
/// 颜色只用两种点缀：朱红（正在记录、要你做的事）和靛青（人名、书脊）。
enum Ink {
    private static func dyn(_ day: UInt32, _ night: UInt32, alpha: CGFloat = 1) -> Color {
        Color(UIColor { t in
            let v = t.userInterfaceStyle == .dark ? night : day
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: alpha)
        })
    }

    static let paper = dyn(0xFDFCF8, 0x1A2036)
    static let wash = dyn(0xF5F2EA, 0x232B47)
    static let ink = dyn(0x1C1C1C, 0xEFE6CF)
    static let ink2 = dyn(0x1C1C1C, 0xEFE6CF, alpha: 0.62)
    static let ink3 = dyn(0x1C1C1C, 0xEFE6CF, alpha: 0.40)
    static let rule = dyn(0x1C1C1C, 0xEFE6CF, alpha: 0.13)
    static let vermilion = dyn(0xC8432F, 0xE0705A)
    static let indigo = dyn(0x34407A, 0x9AA5E0)
    static let lamp = Color(red: 1.0, green: 0.84, blue: 0.54)

    /// 标题用的宋体（随 App 打包的思源宋体子集）。
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("NotoSerifCJKsc-SemiBold", size: size, relativeTo: style)
    }

    /// 时刻数字：衬线、等宽。
    static func clock(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }
}

// MARK: - 手写感的线

/// 确定性的小抖动：同一条线每次画出来都一样，不会闪。
private func wobble(_ seed: CGFloat, _ t: CGFloat) -> CGFloat {
    sin(t * 0.21 + seed * 1.7) * 0.55 + sin(t * 0.057 + seed * 3.1) * 0.75
}

/// 一条竖着的墨线，略有起伏。
struct InkRail: Shape {
    var seed: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x = rect.midX
        p.move(to: CGPoint(x: x + wobble(seed, 0) * 0.5, y: rect.minY))
        var y: CGFloat = 6
        while y < rect.height {
            p.addLine(to: CGPoint(x: x + wobble(seed, y) * 0.5, y: rect.minY + y))
            y += 6
        }
        p.addLine(to: CGPoint(x: x + wobble(seed, rect.height) * 0.5, y: rect.maxY))
        return p
    }
}

/// 一条横着的墨线。
struct InkRule: Shape {
    var seed: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: y + wobble(seed, 0) * 0.4))
        var x: CGFloat = 8
        while x < rect.width {
            p.addLine(to: CGPoint(x: rect.minX + x, y: y + wobble(seed, x) * 0.4))
            x += 8
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: y + wobble(seed, rect.width) * 0.4))
        return p
    }
}

/// 手画的圈：起笔和收笔错开一点，不完全闭合。
struct InkRing: Shape {
    var seed: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let start = -1.9 + Double(seed.truncatingRemainder(dividingBy: 1)) * 0.6
        let sweep = 2 * Double.pi + 0.35
        let steps = 40
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let a = start + sweep * t
            let rr = r * (1 + 0.035 * CGFloat(sin(a * 2 + Double(seed))) - 0.05 * CGFloat(t * t))
            let pt = CGPoint(x: c.x + rr * CGFloat(cos(a)), y: c.y + rr * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// 手画的勾。
struct InkTick: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.maxY - rect.height * 0.08),
                       control: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.70))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.32))
        return p
    }
}

/// 待办的勾选框：手画的圈，勾上时朱红的勾一笔画出来。
struct InkCheckbox: View {
    let done: Bool
    var size: CGFloat = 22
    var seed: CGFloat = 0

    var body: some View {
        ZStack {
            InkRing(seed: seed)
                .stroke(done ? Ink.ink3 : Ink.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            InkTick()
                .trim(from: 0, to: done ? 1 : 0)
                .stroke(Ink.vermilion, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.78, height: size * 0.62)
                .offset(x: size * 0.08, y: -size * 0.08)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.32), value: done)
    }
}

// MARK: - 插画里用到的 SVG 路径（只支持绝对坐标的 M L C Q Z）

enum InkRole { case band, line, detail, paper, blot, red, indigo, lit }

enum SVGPath {
    static func parse(_ d: String) -> Path {
        var tokens: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }
        for ch in d {
            if ch.isLetter {
                flush()
                tokens.append(String(ch))
            } else if ch == " " || ch == "," {
                flush()
            } else if ch == "-" && !cur.isEmpty {
                flush()
                cur = "-"
            } else {
                cur.append(ch)
            }
        }
        flush()

        var path = Path()
        var i = 0
        var cmd = "M"
        func num() -> CGFloat {
            guard i < tokens.count else { return 0 }
            let v = Double(tokens[i]) ?? 0
            i += 1
            return CGFloat(v)
        }
        func point() -> CGPoint {
            let x = num()
            let y = num()
            return CGPoint(x: x, y: y)
        }
        while i < tokens.count {
            let t = tokens[i]
            if let c = t.first, c.isLetter {
                cmd = t
                i += 1
                if cmd == "Z" { path.closeSubpath() }
                continue
            }
            switch cmd {
            case "M":
                path.move(to: point())
                cmd = "L"
            case "L":
                path.addLine(to: point())
            case "C":
                let c1 = point()
                let c2 = point()
                let end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
            case "Q":
                let c = point()
                let end = point()
                path.addQuadCurve(to: end, control: c)
            default:
                i += 1
            }
        }
        return path
    }
}

// MARK: - 页头插画：书桌前的人

/// 一张线描小画：窗、书架、书桌、台灯、写字的人。
/// 白天窗外有太阳和慢慢飘的云；夜里纸变成靛蓝，台灯和窗里的灯亮起来。
/// 正在记录时，人手腕上的表闪一个朱红的点。
struct StudyVignette: View {
    var live: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let parts: [(InkRole, Path, CGFloat)] = StudyArt.parts.map { ($0.0, SVGPath.parse($0.1), $0.2) }
    private static let window = CGRect(x: 34, y: 20, width: 130, height: 94)
    private static let start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { ctx, size in
                draw(&ctx, size: size, t: context.date.timeIntervalSince(Self.start))
            }
        }
        .aspectRatio(390.0 / 160.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let night = scheme == .dark
        let s = size.width / 390
        ctx.scaleBy(x: s, y: s)
        let ink = Ink.ink, paper = Ink.paper
        let w = Self.window

        // 窗外的天
        var sky = ctx
        sky.clip(to: Path(w))
        let top = night ? Color(red: 0.11, green: 0.13, blue: 0.25) : Color(red: 0.95, green: 0.95, blue: 0.93)
        let bottom = night ? Color(red: 0.22, green: 0.23, blue: 0.38) : Color(red: 0.98, green: 0.94, blue: 0.87)
        sky.fill(Path(w), with: .linearGradient(Gradient(colors: [top, bottom]),
                                                startPoint: CGPoint(x: 0, y: w.minY), endPoint: CGPoint(x: 0, y: w.maxY)))
        let hour = Double(Calendar.current.component(.hour, from: Date())) + Double(Calendar.current.component(.minute, from: Date())) / 60
        if night {
            for (i, star) in [(52.0, 30.0), (74.0, 44.0), (96.0, 26.0), (150.0, 58.0), (60.0, 60.0), (142.0, 30.0)].enumerated() {
                let a = 0.45 + 0.4 * sin(t * 1.3 + Double(i) * 1.9)
                sky.fill(Path(ellipseIn: CGRect(x: star.0 - 0.8, y: star.1 - 0.8, width: 1.6, height: 1.6)), with: .color(ink.opacity(a)))
            }
            var moon = Path()
            moon.addArc(center: CGPoint(x: 128, y: 42), radius: 10, startAngle: .degrees(-60), endAngle: .degrees(170), clockwise: false)
            moon.addArc(center: CGPoint(x: 133, y: 38), radius: 8.5, startAngle: .degrees(150), endAngle: .degrees(-40), clockwise: true)
            moon.closeSubpath()
            sky.fill(moon, with: .color(ink.opacity(0.9)))
        } else {
            // 太阳从左到右走过窗：6 点在左，18 点在右，中午最高
            let u = min(max((hour - 6) / 12, 0), 1)
            let sun = CGPoint(x: w.minX + 18 + (w.width - 36) * u, y: 58 - 22 * sin(u * .pi))
            sky.fill(Path(ellipseIn: CGRect(x: sun.x - 24, y: sun.y - 24, width: 48, height: 48)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.62).opacity(0.55), .clear]),
                                           center: sun, startRadius: 0, endRadius: 24))
            sky.stroke(Path(ellipseIn: CGRect(x: sun.x - 10, y: sun.y - 10, width: 20, height: 20)), with: .color(ink), lineWidth: 1)
        }
        // 云：一条长线收一个小卷，慢慢往右飘
        let drift = reduceMotion ? 0 : CGFloat((t * 2.2).truncatingRemainder(dividingBy: 190))
        let clouds: [(CGFloat, CGFloat, CGFloat)] = [(0, 36, 40), (96, 50, 28)]
        for (dx, y, len) in clouds {
            let x0 = w.minX - 60 + (dx + drift).truncatingRemainder(dividingBy: 190)
            var cloud = Path()
            cloud.move(to: CGPoint(x: x0, y: y))
            cloud.addLine(to: CGPoint(x: x0 + len, y: y))
            cloud.addCurve(to: CGPoint(x: x0 + len + 1, y: y - 6), control1: CGPoint(x: x0 + len + 6, y: y), control2: CGPoint(x: x0 + len + 6, y: y - 6))
            cloud.addCurve(to: CGPoint(x: x0 + len - 1, y: y - 3), control1: CGPoint(x: x0 + len - 2, y: y - 6), control2: CGPoint(x: x0 + len - 3, y: y - 3.5))
            cloud.move(to: CGPoint(x: x0 - 12, y: y + 6))
            cloud.addLine(to: CGPoint(x: x0 + len * 0.6, y: y + 6))
            sky.stroke(cloud, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }

        // 台灯的光（夜里）
        if night {
            let c = CGPoint(x: 346, y: 86)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 58, y: c.y - 58, width: 116, height: 116)),
                     with: .radialGradient(Gradient(colors: [Ink.lamp.opacity(0.42), Ink.lamp.opacity(0)]), center: c, startRadius: 0, endRadius: 58))
        }

        // 线描本体
        for (role, path, width) in Self.parts {
            switch role {
            case .band:
                ctx.fill(path, with: .color(paper))
            case .line:
                ctx.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            case .detail:
                ctx.stroke(path, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            case .paper, .red, .indigo, .lit:
                let fill: Color
                switch role {
                case .red: fill = Ink.vermilion
                case .indigo: fill = Ink.indigo
                case .lit: fill = night ? Ink.lamp : paper
                default: fill = paper
                }
                ctx.fill(path, with: .color(fill))
                ctx.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            case .blot:
                ctx.fill(path, with: .color(ink))
            }
        }
        if night {
            // 灯罩下沿透出的光
            var shade = Path()
            shade.move(to: CGPoint(x: 340, y: 74)); shade.addLine(to: CGPoint(x: 356, y: 70))
            ctx.stroke(shade, with: .color(Ink.lamp), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }

        // 杯子上的热气：两缕，往上飘、渐淡
        if !reduceMotion {
            for k in 0..<2 {
                let phase = (t / 2.6 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let baseX = 255.0 + Double(k) * 3.5
                let y0 = 89.0 - phase * 10
                var steam = Path()
                steam.move(to: CGPoint(x: baseX, y: y0))
                steam.addCurve(to: CGPoint(x: baseX, y: y0 - 11),
                               control1: CGPoint(x: baseX - 4, y: y0 - 3.5), control2: CGPoint(x: baseX + 4, y: y0 - 7.5))
                ctx.stroke(steam, with: .color(ink.opacity(0.5 * sin(phase * .pi))), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }

        // 正在记录：手腕上的表
        if live {
            let a = reduceMotion ? 1 : 0.55 + 0.45 * sin(t * 3.2)
            let wrist = CGPoint(x: 233.5, y: 103.2)
            ctx.fill(Path(ellipseIn: CGRect(x: wrist.x - 4.5, y: wrist.y - 4.5, width: 9, height: 9)), with: .color(Ink.vermilion.opacity(0.18 * a)))
            ctx.fill(Path(ellipseIn: CGRect(x: wrist.x - 1.8, y: wrist.y - 1.8, width: 3.6, height: 3.6)), with: .color(Ink.vermilion.opacity(a)))
        }
    }
}

// MARK: - 正在记录

struct LivePill: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Ink.vermilion)
                .frame(width: 6, height: 6)
                .opacity(on ? 1 : 0.3)
            Text("记录中").font(.caption.weight(.medium))
        }
        .foregroundStyle(Ink.vermilion)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Ink.vermilion.opacity(0.55), lineWidth: 0.8))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
        .accessibilityLabel("正在记录")
    }
}
