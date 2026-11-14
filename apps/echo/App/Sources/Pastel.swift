import SwiftUI
import UIKit

// MARK: - 粉彩：手绘感的绘制引擎
//
// 画材只用四种干性的：粉彩（大面积色块，带颗粒和脱落）、彩铅（细排线）、蜡笔（边缘、色点）、炭笔（暗部的几笔）。
// 颜色取 90 年代动画背景的感觉：赛璐璐式分层的天空、品红与桃色的黄昏、偏紫的阴影、偏暖的高光、镜头光晕。
// 所有随机都由种子决定：同一天、同一段每次画出来都一样，不会闪。

/// 可复现的随机数（SplitMix64）。
struct PastelRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    init(text: String) {
        var h: UInt64 = 1469598103934665603
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        self.init(h)
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0..<1
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func chance(_ p: CGFloat) -> Bool { unit() < p }
}

/// RGB 三元组，便于插值。
struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xff) / 255
        g = CGFloat((hex >> 8) & 0xff) / 255
        b = CGFloat(hex & 0xff) / 255
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    var color: Color { Color(red: Double(r), green: Double(g), blue: Double(b)) }
    func color(_ a: Double) -> Color { Color(red: Double(r), green: Double(g), blue: Double(b), opacity: a) }
}

/// 一个时刻的整套颜色。
struct SkyPalette {
    var zenith: RGB      // 天顶
    var upper: RGB
    var lower: RGB
    var horizon: RGB     // 地平线上最亮的那一条
    var cloud: RGB       // 云的受光面
    var cloudShade: RGB  // 云的背光面（偏紫）
    var glow: RGB        // 太阳 / 月亮的光
    var far: RGB         // 远山
    var mid: RGB
    var near: RGB        // 近处的剪影
    var spark: RGB       // 闪光点

    private static func p(_ z: UInt32, _ u: UInt32, _ l: UInt32, _ h: UInt32, _ c: UInt32, _ cs: UInt32, _ g: UInt32,
                          _ f: UInt32, _ m: UInt32, _ n: UInt32, _ s: UInt32) -> SkyPalette {
        SkyPalette(zenith: RGB(z), upper: RGB(u), lower: RGB(l), horizon: RGB(h), cloud: RGB(c), cloudShade: RGB(cs), glow: RGB(g),
                   far: RGB(f), mid: RGB(m), near: RGB(n), spark: RGB(s))
    }

    /// 一天里的关键帧：深夜 → 黎明 → 上午 → 正午 → 傍晚 → 入夜 → 深夜。
    private static let keys: [(CGFloat, SkyPalette)] = [
        (0.0, p(0x0E1035, 0x1F1C55, 0x3A2C72, 0x6A4A9C, 0x4E4A8E, 0x272358, 0xDCD6FF, 0x2C2766, 0x1D1A4C, 0x110F33, 0xFFF4C8)),
        (5.0, p(0x2A2A6E, 0x5A4A93, 0xC97FA5, 0xFFC2A0, 0xF4B6C2, 0x6E5A9E, 0xFFE3B8, 0x7A6BA6, 0x5A4E8A, 0x3A3368, 0xFFFFFF)),
        (8.0, p(0x3E7FD0, 0x8FC0F0, 0xF2D6E4, 0xFFD9B0, 0xFFFFFF, 0xB0A6E0, 0xFFF0C8, 0x9C9AD8, 0x7476BE, 0x4C4E96, 0xFFFFFF)),
        (12.5, p(0x1F6FD6, 0x4FAAF0, 0x9ED8F8, 0xE8F8FF, 0xFFFFFF, 0x98B0EC, 0xFFFBEA, 0x7EA2E0, 0x557CC8, 0x34569E, 0xFFFFFF)),
        (17.0, p(0x3F4FB0, 0xA066C0, 0xFF7FA6, 0xFFB870, 0xFFD6B8, 0x8E5AA8, 0xFFD58A, 0x9A5AA0, 0x6A3C88, 0x3C2468, 0xFFF1C2)),
        (19.5, p(0x1C2066, 0x48327F, 0xA44A90, 0xF2747A, 0xCC80AA, 0x4A3478, 0xFFB08A, 0x5A3C83, 0x3A2A6B, 0x1E1747, 0xFFE6B0)),
        (24.0, p(0x0E1035, 0x1F1C55, 0x3A2C72, 0x6A4A9C, 0x4E4A8E, 0x272358, 0xDCD6FF, 0x2C2766, 0x1D1A4C, 0x110F33, 0xFFF4C8)),
    ]

    static func at(hour: CGFloat) -> SkyPalette {
        let h = max(0, min(24, hour))
        for i in 1..<keys.count where h <= keys[i].0 {
            let a = keys[i - 1], b = keys[i]
            let t = (h - a.0) / (b.0 - a.0)
            // 缓入缓出，交界处不生硬
            let s = t * t * (3 - 2 * t)
            return a.1.mix(b.1, s)
        }
        return keys[0].1
    }

    func mix(_ o: SkyPalette, _ t: CGFloat) -> SkyPalette {
        SkyPalette(zenith: zenith.mix(o.zenith, t), upper: upper.mix(o.upper, t), lower: lower.mix(o.lower, t), horizon: horizon.mix(o.horizon, t),
                   cloud: cloud.mix(o.cloud, t), cloudShade: cloudShade.mix(o.cloudShade, t), glow: glow.mix(o.glow, t),
                   far: far.mix(o.far, t), mid: mid.mix(o.mid, t), near: near.mix(o.near, t), spark: spark.mix(o.spark, t))
    }

    /// 深色模式：往夜里靠一点，免得一整块亮色刺眼。
    func dimmed() -> SkyPalette { mix(SkyPalette.at(hour: 22), 0.35) }

    static func hour(of date: Date) -> CGFloat {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return CGFloat(c.hour ?? 12) + CGFloat(c.minute ?? 0) / 60
    }
}

// MARK: - 笔触

enum Brush {
    /// 粉彩 / 蜡笔：沿路径点下一串略扁的颗粒，有些颗粒“脱落”，看起来是纸纹没吃到颜色。
    static func pastel(_ ctx: inout GraphicsContext, points: [CGPoint], color: Color, width: CGFloat,
                       dropout: CGFloat = 0.22, rng: inout PastelRNG) {
        guard points.count > 1 else { return }
        var path = Path()
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(len / max(0.8, width * 0.42)))
            let nx = -(b.y - a.y) / max(len, 0.001), ny = (b.x - a.x) / max(len, 0.001)
            for s in 0..<steps {
                if rng.chance(dropout) { continue }
                let t = CGFloat(s) / CGFloat(steps)
                let off = rng.range(-0.32, 0.32) * width
                let cx = a.x + (b.x - a.x) * t + nx * off
                let cy = a.y + (b.y - a.y) * t + ny * off
                let rx = width * rng.range(0.22, 0.42), ry = rx * rng.range(0.5, 0.9)
                path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            }
        }
        ctx.fill(path, with: .color(color))
    }

    /// 一条手抖的线（用于粉彩、蜡笔笔触的骨架）。
    static func wobble(from a: CGPoint, to b: CGPoint, amount: CGFloat, segments: Int = 10, rng: inout PastelRNG) -> [CGPoint] {
        let phase = rng.range(0, 6.28), freq = rng.range(1.2, 2.6)
        return (0...segments).map { i in
            let t = CGFloat(i) / CGFloat(segments)
            let w = sin(t * freq * .pi + phase) * amount + rng.range(-0.25, 0.25) * amount
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
            return CGPoint(x: a.x + (b.x - a.x) * t + nx * w, y: a.y + (b.y - a.y) * t + ny * w)
        }
    }

    /// 彩铅排线：一片区域里斜着的细线，长短、角度、深浅都略有不同。
    static func hatch(_ ctx: inout GraphicsContext, in rect: CGRect, angle: CGFloat, spacing: CGFloat, color: Color,
                      width: CGFloat = 0.6, rng: inout PastelRNG) {
        var path = Path()
        let diag = hypot(rect.width, rect.height)
        let dx = cos(angle), dy = sin(angle)
        let px = -dy, py = dx
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var d = -diag / 2
        while d < diag / 2 {
            d += spacing * rng.range(0.7, 1.3)
            if rng.chance(0.35) { continue }
            let length = rng.range(diag * 0.04, diag * 0.16)
            let along = rng.range(-diag / 2, diag / 2)
            let jitter = rng.range(-0.05, 0.05)
            let sx = center.x + px * d + dx * along, sy = center.y + py * d + dy * along
            path.move(to: CGPoint(x: sx, y: sy))
            path.addLine(to: CGPoint(x: sx + (dx + jitter) * length, y: sy + (dy - jitter) * length))
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// 彩铅的质感：一片区域里很多短短的斜线（3–9pt），像铅笔在纸上来回蹭。
    static func shortHatch(_ ctx: inout GraphicsContext, in rect: CGRect, angle: CGFloat, density: CGFloat, length: CGFloat,
                           color: Color, width: CGFloat, rng: inout PastelRNG) {
        var path = Path()
        let count = Int(rect.width * rect.height * density)
        for _ in 0..<count {
            let x = rng.range(rect.minX, rect.maxX), y = rng.range(rect.minY, rect.maxY)
            let l = rng.range(length * 0.5, length * 1.3), a = angle + rng.range(-0.12, 0.12)
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l))
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// 纸纹：深浅两种细小颗粒。
    static func grain(_ ctx: inout GraphicsContext, size: CGSize, density: CGFloat, light: Color, dark: Color, rng: inout PastelRNG) {
        var lightPath = Path(), darkPath = Path()
        let count = Int(size.width * size.height * density)
        for _ in 0..<count {
            let x = rng.range(0, size.width), y = rng.range(0, size.height)
            let r = rng.range(0.25, 0.85)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            if rng.chance(0.5) { lightPath.addEllipse(in: rect) } else { darkPath.addEllipse(in: rect) }
        }
        ctx.fill(lightPath, with: .color(light))
        ctx.fill(darkPath, with: .color(dark))
    }

    /// 动画里的闪光：四角星。
    static func sparkle(_ ctx: inout GraphicsContext, at c: CGPoint, size s: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - s))
        p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + s * 0.12, y: c.y - s * 0.12))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + s * 0.12, y: c.y + s * 0.12))
        p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - s * 0.12, y: c.y + s * 0.12))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - s * 0.12, y: c.y - s * 0.12))
        ctx.fill(p, with: .color(color))
    }
}

// MARK: - 一幅天空

/// 画一块“那个时刻的光”。marks 是 0...1 的横向位置（比如当天每一段发生的时刻），会在地平线上留一颗小光点。
enum SkyPainter {
    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func glow(_ ctx: inout GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ color: RGB, _ stops: [(CGFloat, Double)]) {
        let g = Gradient(stops: stops.map { Gradient.Stop(color: color.color($0.1), location: $0.0) })
        ctx.fill(circle(c, r), with: .radialGradient(g, center: c, startRadius: 0, endRadius: r))
    }

    static func paint(_ ctx: inout GraphicsContext, size: CGSize, hour: CGFloat, seed: String, marks: [(CGFloat, RGB)], dark: Bool) {
        var rng = PastelRNG(text: seed)
        var pal = SkyPalette.at(hour: hour)
        if dark { pal = pal.dimmed() }
        let w = size.width, h = size.height
        let hy = h * rng.range(0.64, 0.70)
        let night = hour < 5 || hour > 19.5

        // 1. 平滑的底
        let sky = Gradient(stops: [Gradient.Stop(color: pal.zenith.color, location: 0), Gradient.Stop(color: pal.upper.color, location: 0.45),
                                   Gradient.Stop(color: pal.lower.color, location: 0.8), Gradient.Stop(color: pal.horizon.color, location: 1)])
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: hy)))

        // 2. 赛璐璐的几层：越往下越亮越暖，边缘是抹出来的波浪
        for i in 0..<4 {
            let top = hy * (0.18 + 0.2 * CGFloat(i)) + rng.range(-4, 4)
            let col = pal.upper.mix(pal.horizon, 0.25 + 0.22 * CGFloat(i))
            let ph = rng.range(0, 6.28), amp = rng.range(2, 6), fr = rng.range(1.5, 3.5)
            var band = Path()
            band.move(to: CGPoint(x: -4, y: h))
            var x: CGFloat = -4
            while x <= w + 4 {
                band.addLine(to: CGPoint(x: x, y: top + sin(x / w * fr * .pi + ph) * amp))
                x += 5
            }
            band.addLine(to: CGPoint(x: w + 4, y: h))
            band.closeSubpath()
            ctx.fill(band, with: .color(col.color(0.28)))
        }

        // 3. 光
        let arc = max(0, min(1, (hour - 5) / 15))
        var sun = CGPoint(x: w * (0.14 + 0.72 * arc), y: hy - sin(arc * .pi) * hy * 0.6 - h * 0.05)
        if night { sun = CGPoint(x: w * rng.range(0.65, 0.85), y: h * rng.range(0.16, 0.26)) }
        if !night {
            // 光柱
            for _ in 0..<7 {
                let an = CGFloat.pi * 0.5 + rng.range(-1.1, 1.1), spread = rng.range(0.03, 0.08), len = h * 1.8
                var beam = Path()
                beam.move(to: sun)
                beam.addLine(to: CGPoint(x: sun.x + cos(an - spread) * len, y: sun.y + sin(an - spread) * len))
                beam.addLine(to: CGPoint(x: sun.x + cos(an + spread) * len, y: sun.y + sin(an + spread) * len))
                beam.closeSubpath()
                let g = Gradient(colors: [pal.glow.color(Double(rng.range(0.10, 0.2))), pal.glow.color(0)])
                ctx.fill(beam, with: .radialGradient(g, center: sun, startRadius: 0, endRadius: len))
            }
        }
        glow(&ctx, sun, h * 0.75, pal.glow, [(0, 0.55), (0.25, 0.25), (1, 0)])
        let dr = h * (night ? 0.055 : 0.07)
        if night {
            glow(&ctx, sun, dr * 2.2, pal.glow, [(0, 0.5), (1, 0)])
            // 月牙：把月亮挖掉一块
            ctx.drawLayer { layer in
                var mask = Path(CGRect(x: -w, y: -h, width: w * 3, height: h * 3))
                mask.addPath(circle(CGPoint(x: sun.x + dr * 0.5, y: sun.y - dr * 0.25), dr * 0.92))
                layer.clip(to: mask, style: FillStyle(eoFill: true))
                layer.fill(circle(sun, dr), with: .color(pal.glow.color))
            }
            for _ in 0..<40 {
                Brush.sparkle(&ctx, at: CGPoint(x: rng.range(0, w), y: rng.range(0, hy * 0.75)), size: rng.range(0.6, 2.4),
                              color: pal.spark.color(Double(rng.range(0.35, 0.9))))
            }
        } else {
            glow(&ctx, sun, dr * 2.6, RGB(0xFFFFFF), [(0, 0.9), (0.35, 0.5), (1, 0)])
            ctx.fill(circle(sun, dr), with: .color(RGB(0xFFFFF8).color))
            // 横向的一道光带
            ctx.drawLayer { layer in
                layer.translateBy(x: sun.x, y: sun.y)
                layer.scaleBy(x: w * 0.55, y: dr * 0.22)
                let g = Gradient(colors: [Color.white.opacity(0.75), pal.glow.color(0)])
                layer.fill(circle(.zero, 1), with: .radialGradient(g, center: .zero, startRadius: 0, endRadius: 1))
            }
            // 镜头光晕
            let center = CGPoint(x: w / 2, y: h / 2)
            let flares: [(CGFloat, CGFloat, Double, RGB)] = [(0.45, h * 0.035, 0.35, pal.glow), (0.8, h * 0.06, 0.22, pal.horizon),
                                                              (1.25, h * 0.02, 0.45, RGB(0xB3E6FF)), (1.6, h * 0.09, 0.15, pal.lower)]
            for (t, r, a, col) in flares {
                let f = CGPoint(x: sun.x + (center.x - sun.x) * t * 1.4, y: sun.y + (center.y - sun.y) * t * 1.4)
                glow(&ctx, f, r, col, [(0, a * 0.4), (0.8, a), (1, 0)])
            }
        }

        // 4. 云：赛璐璐两色 + 一道边缘高光；底部是波浪状的裁切
        let clouds = night ? 1 : Int(rng.range(2, 4.99))
        for ci in 0..<clouds {
            let cx = w * (CGFloat(ci) + rng.range(0.25, 0.75)) / CGFloat(max(clouds, 1))
            let cy = rng.range(0.28, 0.58) * hy
            let sc = rng.range(0.6, 1.0) * h * 0.16
            let n = Int(rng.range(4, 6.99))
            var blobs: [(CGFloat, CGFloat, CGFloat)] = []
            for j in 0..<n {
                let t = (CGFloat(j) - CGFloat(n - 1) / 2) / (CGFloat(n - 1) / 2)
                let r = sc * (1.0 - 0.55 * t * t) * rng.range(0.8, 1.1)
                let bx = cx + t * sc * CGFloat(n) * 0.36 + rng.range(-0.1, 0.1) * sc
                let by = cy - r * rng.range(0.55, 0.95)
                blobs.append((bx, by, r))
            }
            let lx: CGFloat = sun.x < cx ? -1 : 1
            func body(_ dx: CGFloat, _ dy: CGFloat, _ k: CGFloat) -> Path {
                var p = Path()
                for (bx, by, r) in blobs { p.addPath(circle(CGPoint(x: bx + dx * r, y: by + dy * r), r * k)) }
                return p
            }
            var bottom = Path()
            let span = sc * CGFloat(n)
            bottom.move(to: CGPoint(x: cx - span, y: cy - sc * 3))
            bottom.addLine(to: CGPoint(x: cx + span, y: cy - sc * 3))
            var x = cx + span
            while x >= cx - span {
                bottom.addLine(to: CGPoint(x: x, y: cy + sin(x * 0.08) * sc * 0.05))
                x -= 6
            }
            bottom.closeSubpath()
            let shape = body(0, 0, 1)
            let hatchSeed = rng.next()
            ctx.drawLayer { layer in
                layer.clip(to: bottom)
                layer.fill(shape, with: .color(pal.cloudShade.color(0.96)))
                layer.clip(to: shape)
                layer.fill(body(-lx * 0.14, -0.34, 1), with: .color(pal.cloud.mix(pal.cloudShade, 0.10).color))
                layer.fill(body(-lx * 0.32, -0.58, 0.86), with: .color(pal.cloud.mix(pal.glow, 0.55).color(0.95)))
                var local = PastelRNG(hatchSeed)
                Brush.shortHatch(&layer, in: CGRect(x: cx - span, y: cy - sc * 2.5, width: span * 2, height: sc * 2.6), angle: -0.9,
                                 density: 0.03, length: 4, color: pal.cloudShade.color(0.22), width: 0.5, rng: &local)
            }
            // 云底一笔暗色粉彩
            let pts = (0...10).map { i -> CGPoint in
                let px = cx - span * 0.45 + CGFloat(i) * span * 0.09
                return CGPoint(x: px, y: cy - 1 + sin(px * 0.08) * sc * 0.05)
            }
            Brush.pastel(&ctx, points: pts, color: pal.cloudShade.mix(pal.near, 0.3).color(0.45), width: 2.4, dropout: 0.4, rng: &rng)
        }

        // 5. 地平线的雾光
        let haze = Gradient(stops: [Gradient.Stop(color: pal.horizon.color(0), location: 0), Gradient.Stop(color: pal.horizon.color(0.75), location: 0.6),
                                    Gradient.Stop(color: pal.horizon.color(0), location: 1)])
        ctx.fill(Path(CGRect(x: 0, y: hy - h * 0.12, width: w, height: h * 0.2)),
                 with: .linearGradient(haze, startPoint: CGPoint(x: 0, y: hy - h * 0.12), endPoint: CGPoint(x: 0, y: hy + h * 0.08)))

        // 6. 剪影：三层，越远越淡（空气透视），受光的边用粉彩描
        let layers: [(RGB, CGFloat, CGFloat)] = [(pal.far.mix(pal.horizon, 0.35), 0.0, 0.07), (pal.mid, 0.07, 0.11), (pal.near, 0.17, 0.14)]
        for (index, layer) in layers.enumerated() {
            let base = hy + h * layer.1
            let amp = h * layer.2
            let freq = rng.range(1.6, 3.2) + CGFloat(index)
            let phase = rng.range(0, 6.28)
            var ridge: [CGPoint] = []
            var x: CGFloat = -6
            while x <= w + 6 {
                let t = x / w
                let soft = sin(t * freq * .pi + phase) * 0.6 + sin(t * freq * 2.3 * .pi + phase * 1.7) * 0.25
                ridge.append(CGPoint(x: x, y: base - amp * (0.4 + soft * 0.5)))
                x += index == 2 ? 7 : 10
            }
            var land = Path()
            land.move(to: CGPoint(x: -6, y: h + 4))
            for p in ridge { land.addLine(to: p) }
            land.addLine(to: CGPoint(x: w + 6, y: h + 4))
            land.closeSubpath()
            ctx.fill(land, with: .linearGradient(Gradient(colors: [layer.0.color, layer.0.mix(pal.near, 0.6).color]),
                                                 startPoint: CGPoint(x: 0, y: base - amp), endPoint: CGPoint(x: 0, y: h)))
            Brush.pastel(&ctx, points: ridge, color: layer.0.mix(pal.glow, 0.55).color(0.7), width: index == 0 ? 2.6 : 2.0, dropout: 0.3, rng: &rng)
            if index < 2 {
                let mist = Gradient(colors: [pal.horizon.color(0), pal.horizon.color(0.18)])
                ctx.fill(Path(CGRect(x: 0, y: base, width: w, height: h - base)),
                         with: .linearGradient(mist, startPoint: CGPoint(x: 0, y: base), endPoint: CGPoint(x: 0, y: base + h * 0.12)))
            }
        }

        // 7. 这一天的光点：地平线上，按时刻排开
        for (mx, tint) in marks {
            let p = CGPoint(x: w * (0.06 + 0.88 * mx), y: hy + h * 0.03)
            let r = max(3, h * 0.02)
            glow(&ctx, p, r * 3.2, tint.mix(RGB(0xFFFFFF), 0.4), [(0, 0.75), (1, 0)])
            ctx.fill(circle(p, r * 0.5), with: .color(.white.opacity(0.95)))
        }

        // 8. 闪光
        if !night {
            for _ in 0..<Int(rng.range(3, 6.99)) {
                Brush.sparkle(&ctx, at: CGPoint(x: rng.range(0, w), y: rng.range(0, hy * 0.9)), size: rng.range(2, 5),
                              color: pal.spark.color(Double(rng.range(0.55, 0.9))))
            }
        }

        // 9. 质感：彩铅短排线、暗部的炭笔、纸纹、暗角
        Brush.shortHatch(&ctx, in: CGRect(x: 0, y: 0, width: w, height: hy), angle: -0.95, density: 0.02, length: 5,
                         color: pal.zenith.mix(pal.cloudShade, 0.5).color(0.10), width: 0.45, rng: &rng)
        Brush.shortHatch(&ctx, in: CGRect(x: 0, y: hy * 0.5, width: w, height: h - hy * 0.5), angle: -0.35, density: 0.015, length: 6,
                         color: pal.horizon.color(0.12), width: 0.5, rng: &rng)
        Brush.shortHatch(&ctx, in: CGRect(x: 0, y: hy + h * 0.12, width: w, height: h), angle: -0.6, density: 0.035, length: 4,
                         color: pal.near.mix(RGB(0x000000), 0.4).color(0.18), width: 0.6, rng: &rng)
        Brush.grain(&ctx, size: size, density: 0.10, light: Color.white.opacity(0.16), dark: Color.black.opacity(0.07), rng: &rng)
        let vignette = Gradient(colors: [Color.clear, pal.near.mix(RGB(0x000000), 0.5).color(0.35)])
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                 with: .radialGradient(vignette, center: CGPoint(x: w / 2, y: h * 0.45), startRadius: min(w, h) * 0.35, endRadius: max(w, h) * 0.75))
    }
}

/// 画好的天空，缓存成位图（一次几千笔，不能每次刷新都重画）。
@MainActor
final class SkyCache {
    static let shared = SkyCache()
    private var images: [String: UIImage] = [:]

    func image(key: String, size: CGSize, scale: CGFloat, draw: @escaping (inout GraphicsContext, CGSize) -> Void) -> UIImage? {
        if let hit = images[key] { return hit }
        guard size.width > 10, size.height > 10 else { return nil }
        let renderer = ImageRenderer(content: Canvas { ctx, s in draw(&ctx, s) }.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.uiImage else { return nil }
        if images.count > 24 { images.removeAll() }
        images[key] = image
        return image
    }
}

/// 一幅画好的天空。先显示一块平涂的底色，画好后淡入。
struct PaintedSky: View {
    let hour: CGFloat
    let seed: String
    var marks: [(CGFloat, RGB)] = []
    var corner: CGFloat = 22
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private func key(_ size: CGSize) -> String {
        let m = marks.map { String(format: "%.3f", $0.0) }.joined(separator: ",")
        return "\(seed)|\(String(format: "%.2f", hour))|\(Int(size.width))x\(Int(size.height))|\(scheme == .dark ? "d" : "l")|\(m)"
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                let pal = SkyPalette.at(hour: hour)
                LinearGradient(colors: [pal.zenith.color, pal.lower.color, pal.near.color], startPoint: .top, endPoint: .bottom)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .transition(.opacity)
                }
            }
            .task(id: key(size)) {
                let k = key(size)
                let h = hour, s = seed, mk = marks, dark = scheme == .dark
                let rendered = SkyCache.shared.image(key: k, size: size, scale: min(displayScale, 2)) { ctx, sz in
                    SkyPainter.paint(&ctx, size: sz, hour: h, seed: s, marks: mk, dark: dark)
                }
                withAnimation(.easeOut(duration: 0.5)) { image = rendered }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - 纸纹底（整页用）

enum PaperGrain {
    /// 一块可平铺的纸纹。
    @MainActor static let tile: UIImage = {
        let size = CGSize(width: 180, height: 180)
        let renderer = ImageRenderer(content: Canvas { ctx, s in
            var rng = PastelRNG(7)
            Brush.grain(&ctx, size: s, density: 0.22, light: Color.white.opacity(0.5), dark: Color.black.opacity(0.35), rng: &rng)
            Brush.hatch(&ctx, in: CGRect(origin: .zero, size: s), angle: -0.8, spacing: 6, color: Color.black.opacity(0.08), width: 0.4, rng: &rng)
        }.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return renderer.uiImage ?? UIImage()
    }()
}

struct PaperBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Ink.paper
            Image(uiImage: PaperGrain.tile)
                .resizable(resizingMode: .tile)
                .opacity(scheme == .dark ? 0.10 : 0.07)
                .blendMode(scheme == .dark ? .screen : .multiply)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - 蜡笔的点和线（时间线用）

/// 时间线上一段的标记：一颗蜡笔点出来的色点，带一个动画式的小高光。
struct CrayonDot: View {
    let color: RGB
    var size: CGFloat = 14
    let seed: String

    var body: some View {
        Canvas { ctx, s in
            var rng = PastelRNG(text: seed)
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let r = min(s.width, s.height) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.92, y: c.y - r * 0.92, width: r * 1.84, height: r * 1.84)), with: .color(color.color(0.9)))
            // 一圈一圈涂出来
            var a: CGFloat = 0
            var pts: [CGPoint] = []
            while a < 6.28 * 2.2 {
                let rr = r * (0.35 + 0.6 * (a / (6.28 * 2.2)))
                pts.append(CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr))
                a += 0.35
            }
            Brush.pastel(&ctx, points: pts, color: color.mix(RGB(0x000000), 0.22).color(0.55), width: r * 0.42, dropout: 0.4, rng: &rng)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.6, width: r * 0.42, height: r * 0.32)), with: .color(.white.opacity(0.85)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 竖着的一笔蜡笔线，颜色从上一段的时刻渐变到下一段。
struct CrayonRail: View {
    let from: RGB
    let to: RGB
    let seed: String

    var body: some View {
        Canvas { ctx, s in
            var rng = PastelRNG(text: seed)
            let x = s.width / 2
            // 先垫一条连续的底色，再撒蜡笔颗粒
            var base = Path()
            base.move(to: CGPoint(x: x, y: 0))
            base.addLine(to: CGPoint(x: x, y: s.height))
            ctx.stroke(base, with: .linearGradient(Gradient(colors: [from.color(0.55), to.color(0.55)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: s.height)),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            let steps = max(2, Int(s.height / 26))
            for i in 0..<steps {
                let y0 = s.height * CGFloat(i) / CGFloat(steps)
                let y1 = s.height * CGFloat(i + 1) / CGFloat(steps)
                let t = CGFloat(i) / CGFloat(max(1, steps - 1))
                let pts = Brush.wobble(from: CGPoint(x: x, y: y0), to: CGPoint(x: x, y: y1 + 1), amount: 0.7, segments: 4, rng: &rng)
                Brush.pastel(&ctx, points: pts, color: from.mix(to, t).color(0.8), width: 3.6, dropout: 0.08, rng: &rng)
            }
        }
        .accessibilityHidden(true)
    }
}

extension Daylight {
    /// 时间线用的颜色：取天空调色板里地平线附近最饱和的那一条。
    static func rgb(_ date: Date) -> RGB {
        let p = SkyPalette.at(hour: SkyPalette.hour(of: date))
        return p.lower.mix(p.horizon, 0.3).mix(p.upper, 0.25)
    }
}
