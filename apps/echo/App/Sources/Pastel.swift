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
        (8.0, p(0x4F8FD6, 0x8EC3EC, 0xD7E9F2, 0xFFE6C4, 0xFFFFFF, 0xA9B5E0, 0xFFF1CF, 0x8FA7D6, 0x6D84BF, 0x4E5F9A, 0xFFFFFF)),
        (12.5, p(0x2F7FD8, 0x5FB2EE, 0xA6DDF6, 0xE6F7FB, 0xFFFFFF, 0x9DB6E6, 0xFFFBEA, 0x86A9DA, 0x5E86C4, 0x3E5F9C, 0xFFFFFF)),
        (17.0, p(0x4A5BB3, 0xB06FB6, 0xFF8FA0, 0xFFC27A, 0xFFD3B0, 0x9A5E9E, 0xFFD58A, 0x9C5C9C, 0x6E3F86, 0x3F2766, 0xFFF1C2)),
        (19.5, p(0x1E2366, 0x4B347F, 0xA14C8E, 0xF0797A, 0xC982A8, 0x4A3478, 0xFFB38A, 0x5A3C83, 0x3A2A6B, 0x1E1747, 0xFFE6B0)),
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
    static func paint(_ ctx: inout GraphicsContext, size: CGSize, hour: CGFloat, seed: String, marks: [(CGFloat, RGB)], dark: Bool) {
        var rng = PastelRNG(text: seed)
        var pal = SkyPalette.at(hour: hour)
        if dark { pal = pal.dimmed() }
        let w = size.width, h = size.height
        let horizonY = h * rng.range(0.66, 0.74)

        // 1. 赛璐璐分层的天空：上下几条色带，交界是手抹的波浪边
        let bands = 7
        for i in 0..<bands {
            let t0 = CGFloat(i) / CGFloat(bands)
            let t1 = CGFloat(i + 1) / CGFloat(bands)
            let color: RGB
            if t0 < 0.35 { color = pal.zenith.mix(pal.upper, t0 / 0.35) }
            else if t0 < 0.7 { color = pal.upper.mix(pal.lower, (t0 - 0.35) / 0.35) }
            else { color = pal.lower.mix(pal.horizon, (t0 - 0.7) / 0.3) }
            let top = horizonY * t0 - (i == 0 ? 2 : 0)
            let bottom = i == bands - 1 ? h : horizonY * t1 + 3
            var band = Path()
            band.move(to: CGPoint(x: -4, y: bottom))
            let phase = rng.range(0, 6.28), amp = rng.range(1.5, 4.5)
            var x: CGFloat = -4
            band.addLine(to: CGPoint(x: -4, y: top))
            while x <= w + 4 {
                band.addLine(to: CGPoint(x: x, y: top + sin(x / w * 5.5 + phase) * amp + rng.range(-0.6, 0.6)))
                x += 6
            }
            band.addLine(to: CGPoint(x: w + 4, y: bottom))
            band.closeSubpath()
            ctx.fill(band, with: .color(color.color))
        }

        // 2. 光：太阳 / 月亮按时刻在天上划一道弧
        let arc = max(0, min(1, (hour - 5) / 15))
        let sunX = w * (0.12 + 0.76 * arc)
        let sunY = horizonY - sin(arc * .pi) * horizonY * 0.62 - h * 0.06
        let glowR = h * 0.55
        ctx.fill(Path(ellipseIn: CGRect(x: sunX - glowR, y: sunY - glowR, width: glowR * 2, height: glowR * 2)),
                 with: .radialGradient(Gradient(colors: [pal.glow.color(0.55), pal.glow.color(0.18), pal.glow.color(0)]),
                                       center: CGPoint(x: sunX, y: sunY), startRadius: 0, endRadius: glowR))
        let night = hour < 5 || hour > 19.5
        let discR = h * (night ? 0.06 : 0.075)
        ctx.fill(Path(ellipseIn: CGRect(x: sunX - discR, y: sunY - discR, width: discR * 2, height: discR * 2)), with: .color(pal.glow.color(0.95)))
        if night {
            // 月牙：用天空的颜色咬掉一块
            let off = discR * 0.45
            ctx.fill(Path(ellipseIn: CGRect(x: sunX - discR + off, y: sunY - discR - off * 0.4, width: discR * 2, height: discR * 2)),
                     with: .color(pal.upper.color(0.92)))
            // 星
            for _ in 0..<26 {
                let p = CGPoint(x: rng.range(0, w), y: rng.range(0, horizonY * 0.7))
                Brush.sparkle(&ctx, at: p, size: rng.range(0.8, 2.4), color: pal.spark.color(Double(rng.range(0.4, 0.9))))
            }
        } else {
            // 镜头光晕：沿着光往画面中心的方向几个淡圈
            let cx = w / 2, cy = h / 2
            for k in 1...3 {
                let t = CGFloat(k) * 0.32
                let fx = sunX + (cx - sunX) * t * 1.6, fy = sunY + (cy - sunY) * t * 1.6
                let r = h * rng.range(0.03, 0.08)
                ctx.stroke(Path(ellipseIn: CGRect(x: fx - r, y: fy - r, width: r * 2, height: r * 2)),
                           with: .color(pal.glow.color(0.25)), lineWidth: rng.range(0.8, 2))
            }
        }

        // 3. 云：几团积云，背光面偏紫、受光面偏暖，边缘是粉彩的颗粒
        let clouds = night ? 2 : Int(rng.range(3, 5.99))
        for _ in 0..<clouds {
            let cx = rng.range(-0.05, 1.05) * w
            let cy = rng.range(0.16, 0.58) * horizonY
            let scale = rng.range(0.55, 1.15) * h * 0.22
            var blobs: [CGRect] = []
            let n = Int(rng.range(6, 10.99))
            for j in 0..<n {
                let bx = cx + (CGFloat(j) - CGFloat(n) / 2) * scale * rng.range(0.45, 0.7)
                let r = scale * rng.range(0.45, 1.0) * (1 - abs(CGFloat(j) - CGFloat(n) / 2) / CGFloat(n))
                let by = cy - r * rng.range(0.2, 0.8)
                blobs.append(CGRect(x: bx - r, y: by - r, width: r * 2, height: r * 2))
            }
            var shade = Path(), body = Path(), lit = Path()
            for b in blobs {
                shade.addEllipse(in: b.offsetBy(dx: scale * 0.06, dy: scale * 0.12))
                body.addEllipse(in: b)
                lit.addEllipse(in: b.insetBy(dx: b.width * 0.18, dy: b.height * 0.18).offsetBy(dx: -(sunX < cx ? 1 : -1) * b.width * 0.08, dy: -b.height * 0.1))
            }
            ctx.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: -w, y: -h, width: w * 3, height: cy + h + scale * 0.2)))
                layer.fill(shade, with: .color(pal.cloudShade.color(0.85)))
                layer.fill(body, with: .color(pal.cloud.mix(pal.cloudShade, 0.35).color(0.95)))
                layer.fill(lit, with: .color(pal.cloud.color(0.9)))
            }
            // 受光边：粉彩颗粒
            for b in blobs.prefix(6) {
                let start = rng.range(3.4, 4.2), end = start + rng.range(1.0, 1.8)
                var pts: [CGPoint] = []
                var a = start
                while a <= end {
                    pts.append(CGPoint(x: b.midX + cos(a) * b.width / 2 * 0.96, y: b.midY + sin(a) * b.height / 2 * 0.96))
                    a += 0.18
                }
                Brush.pastel(&ctx, points: pts, color: pal.cloud.mix(pal.glow, 0.4).color(0.75), width: max(2, scale * 0.07), rng: &rng)
            }
        }

        // 4. 远处起伏的剪影：三层，越近越深，边缘用蜡笔再描一遍
        let layers: [(RGB, CGFloat, CGFloat)] = [(pal.far, 0.0, 0.08), (pal.mid, 0.06, 0.12), (pal.near, 0.15, 0.16)]
        for (index, layer) in layers.enumerated() {
            let base = horizonY + h * layer.1
            let amp = h * layer.2
            let freq = rng.range(1.6, 3.2) + CGFloat(index)
            let phase = rng.range(0, 6.28)
            var ridge: [CGPoint] = []
            var x: CGFloat = -6
            while x <= w + 6 {
                let t = x / w
                // 一部分像山的缓坡，一部分像屋顶的折线，说不清是什么
                let soft = sin(t * freq * .pi + phase) * 0.6 + sin(t * freq * 2.3 * .pi + phase * 1.7) * 0.25
                let step = (index == 2 && rng.chance(0.18)) ? rng.range(-0.5, 0.2) : 0
                ridge.append(CGPoint(x: x, y: base - amp * (0.4 + soft * 0.5 + step)))
                x += index == 2 ? 7 : 10
            }
            var land = Path()
            land.move(to: CGPoint(x: -6, y: h + 4))
            for p in ridge { land.addLine(to: p) }
            land.addLine(to: CGPoint(x: w + 6, y: h + 4))
            land.closeSubpath()
            ctx.fill(land, with: .linearGradient(Gradient(colors: [layer.0.color, layer.0.mix(pal.near, 0.5).color]),
                                                 startPoint: CGPoint(x: 0, y: base - amp), endPoint: CGPoint(x: 0, y: h)))
            Brush.pastel(&ctx, points: ridge, color: layer.0.mix(pal.horizon, 0.45).color(0.55), width: index == 0 ? 3 : 2.2, dropout: 0.35, rng: &rng)
        }

        // 5. 这一天的光点：地平线上，按时刻排开
        for (x, tint) in marks {
            let p = CGPoint(x: w * (0.06 + 0.88 * x), y: horizonY + h * 0.035)
            let r = max(3, h * 0.022)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(Gradient(colors: [tint.mix(RGB(0xFFFFFF), 0.4).color(0.7), tint.color(0)]),
                                           center: p, startRadius: 0, endRadius: r * 3))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.55, y: p.y - r * 0.55, width: r * 1.1, height: r * 1.1)), with: .color(.white.opacity(0.95)))
        }

        // 6. 闪光与浮尘
        if !night {
            for _ in 0..<Int(rng.range(3, 6)) {
                let p = CGPoint(x: rng.range(0, w), y: rng.range(0, horizonY * 0.9))
                Brush.sparkle(&ctx, at: p, size: rng.range(2, 5.5), color: pal.spark.color(Double(rng.range(0.55, 0.9))))
            }
        }
        var dust = Path()
        for _ in 0..<Int(w * 0.35) {
            let x = rng.range(0, w), y = rng.range(0, h)
            let r = rng.range(0.4, 1.2)
            dust.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        ctx.fill(dust, with: .color(pal.spark.color(0.28)))

        // 7. 彩铅排线：两遍不同方向，让整块颜色“是画上去的”
        Brush.hatch(&ctx, in: CGRect(x: 0, y: 0, width: w, height: horizonY), angle: -0.95, spacing: 3.2,
                    color: pal.zenith.mix(pal.cloudShade, 0.5).color(0.16), width: 0.55, rng: &rng)
        Brush.hatch(&ctx, in: CGRect(x: 0, y: horizonY * 0.4, width: w, height: h), angle: -0.35, spacing: 4.2,
                    color: pal.horizon.color(0.14), width: 0.6, rng: &rng)
        // 暗部的几笔炭笔
        Brush.hatch(&ctx, in: CGRect(x: 0, y: horizonY + h * 0.1, width: w, height: h * 0.3), angle: -0.6, spacing: 2.6,
                    color: pal.near.mix(RGB(0x000000), 0.4).color(0.22), width: 0.8, rng: &rng)

        // 8. 纸纹
        Brush.grain(&ctx, size: size, density: 0.09, light: Color.white.opacity(0.16), dark: Color.black.opacity(0.07), rng: &rng)
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
            let steps = max(2, Int(s.height / 26))
            for i in 0..<steps {
                let y0 = s.height * CGFloat(i) / CGFloat(steps)
                let y1 = s.height * CGFloat(i + 1) / CGFloat(steps)
                let t = CGFloat(i) / CGFloat(max(1, steps - 1))
                let pts = Brush.wobble(from: CGPoint(x: x, y: y0), to: CGPoint(x: x, y: y1 + 1), amount: 0.7, segments: 4, rng: &rng)
                Brush.pastel(&ctx, points: pts, color: from.mix(to, t).color(0.85), width: 3.2, dropout: 0.28, rng: &rng)
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
