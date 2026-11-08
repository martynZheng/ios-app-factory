import SwiftUI

enum AvatarHair: Int, Codable {
    case long, bob, twinTails, bun, wavy, sidePony, short
}

enum AvatarDress: Int, Codable {
    case aline, topSkirt, puff, suit, gown
}

enum AvatarAccessory: Int, Codable {
    case none, bow, clip, beret, flower, necklace, tiara, glasses
}

/// 角色外观。所有角色（主角和伙伴）都由同一个画师按参数绘制。
struct AvatarLook {
    var hairStyle: AvatarHair
    var hair: Color
    var dress: Color
    var dress2: Color
    var dressStyle: AvatarDress = .aline
    var accessory: AvatarAccessory = .none
    var accessoryColor: Color = Palette.pink
    var shoes: Color = Palette.cocoa
    var shoeStyle: Int = 0
    var bag: Color = .clear
    var bagStyle: Int = 0
    var skin: Color = Palette.skin
}

/// Q 版角色立绘（100 × 160 的画布，按比例缩放）。
struct AvatarView: View {
    let look: AvatarLook

    var body: some View {
        Canvas { context, size in
            let s = min(size.width / 100, size.height / 160)
            context.translateBy(x: (size.width - 100 * s) / 2, y: (size.height - 160 * s) / 2)
            context.scaleBy(x: s, y: s)
            AvatarPainter.draw(look, in: context)
        }
    }
}

enum AvatarPainter {
    private static func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
    }

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    static func draw(_ look: AvatarLook, in context: GraphicsContext) {
        let ctx = context
        let outline = GraphicsContext.Shading.color(Palette.ink.opacity(0.18))

        // 地面阴影
        ctx.fill(oval(24, 146, 52, 8), with: .color(Color.black.opacity(0.08)))

        drawBackHair(look, ctx)

        // 腿 + 鞋
        if look.dressStyle != .gown {
            ctx.fill(box(41, 116, 7, 30, 3.5), with: .color(look.skin))
            ctx.fill(box(52, 116, 7, 30, 3.5), with: .color(look.skin))
        }
        if look.dressStyle == .suit {
            let pants = look.dress.opacity(0.85)
            ctx.fill(box(39.5, 104, 10, 40, 3), with: .color(pants))
            ctx.fill(box(50.5, 104, 10, 40, 3), with: .color(pants))
        }
        drawShoes(look, ctx)

        // 手臂
        ctx.fill(box(27, 76, 7, 36, 3.5), with: .color(look.skin))
        ctx.fill(box(66, 76, 7, 36, 3.5), with: .color(look.skin))

        // 脖子
        ctx.fill(box(45, 58, 10, 18, 4), with: .color(look.skin))

        drawDress(look, ctx)

        if look.accessory == .necklace {
            var chain = Path()
            chain.move(to: CGPoint(x: 43, y: 73))
            chain.addQuadCurve(to: CGPoint(x: 57, y: 73), control: CGPoint(x: 50, y: 82))
            ctx.stroke(chain, with: .color(.white), lineWidth: 1.2)
            ctx.fill(oval(47.5, 77, 5, 6), with: .color(look.accessoryColor == Palette.pink ? Palette.sky : look.accessoryColor))
        }

        // 头
        ctx.fill(oval(26, 16, 48, 48), with: .color(look.skin))
        ctx.stroke(oval(26, 16, 48, 48), with: outline, lineWidth: 0.6)

        drawBangs(look, ctx)
        drawFace(look, ctx)
        drawAccessory(look, ctx)
        drawBag(look, ctx)
    }

    private static func drawBackHair(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let hair = GraphicsContext.Shading.color(look.hair)
        switch look.hairStyle {
        case .long:
            ctx.fill(box(22, 18, 56, 92, 26), with: hair)
        case .wavy:
            ctx.fill(box(18, 18, 64, 92, 28), with: hair)
            for i in 0..<6 {
                ctx.fill(oval(17 + CGFloat(i) * 11, 100, 14, 16), with: hair)
            }
        case .bob:
            ctx.fill(box(22, 18, 56, 56, 24), with: hair)
        case .twinTails:
            ctx.fill(box(25, 18, 50, 48, 22), with: hair)
            ctx.fill(oval(10, 36, 20, 64), with: hair)
            ctx.fill(oval(70, 36, 20, 64), with: hair)
            ctx.fill(oval(23, 38, 7, 7), with: .color(look.accessoryColor))
            ctx.fill(oval(70, 38, 7, 7), with: .color(look.accessoryColor))
        case .bun:
            ctx.fill(oval(38, 0, 24, 24), with: hair)
            ctx.fill(box(25, 18, 50, 46, 22), with: hair)
        case .sidePony:
            ctx.fill(box(25, 18, 50, 48, 22), with: hair)
            ctx.fill(oval(68, 26, 20, 76), with: hair)
            ctx.fill(oval(69, 26, 8, 8), with: .color(look.accessoryColor))
        case .short:
            ctx.fill(box(25, 14, 50, 40, 20), with: hair)
        }
    }

    private static func drawShoes(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let shoe = GraphicsContext.Shading.color(look.shoes)
        switch look.shoeStyle {
        case 1: // 高跟
            ctx.fill(oval(38, 142, 11, 6), with: shoe)
            ctx.fill(oval(51, 142, 11, 6), with: shoe)
            ctx.fill(box(46, 144, 2, 6, 1), with: shoe)
            ctx.fill(box(59, 144, 2, 6, 1), with: shoe)
        case 2: // 短靴
            ctx.fill(box(40, 130, 9, 18, 3), with: shoe)
            ctx.fill(box(51, 130, 9, 18, 3), with: shoe)
        default:
            ctx.fill(oval(37, 141, 12, 8), with: shoe)
            ctx.fill(oval(51, 141, 12, 8), with: shoe)
        }
        ctx.stroke(oval(37, 141, 12, 8), with: .color(Palette.ink.opacity(0.12)), lineWidth: 0.5)
        ctx.stroke(oval(51, 141, 12, 8), with: .color(Palette.ink.opacity(0.12)), lineWidth: 0.5)
    }

    private static func drawDress(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let main = GraphicsContext.Shading.color(look.dress)
        let accent = GraphicsContext.Shading.color(look.dress2)
        let edge = GraphicsContext.Shading.color(Palette.ink.opacity(0.15))

        switch look.dressStyle {
        case .aline:
            var p = Path()
            p.move(to: CGPoint(x: 38, y: 70))
            p.addLine(to: CGPoint(x: 62, y: 70))
            p.addLine(to: CGPoint(x: 75, y: 120))
            p.addQuadCurve(to: CGPoint(x: 25, y: 120), control: CGPoint(x: 50, y: 127))
            p.closeSubpath()
            ctx.fill(p, with: main)
            ctx.stroke(p, with: edge, lineWidth: 0.6)
            ctx.fill(box(36, 92, 28, 4, 2), with: accent)
            ctx.fill(box(30, 72, 8, 14, 4), with: main)
            ctx.fill(box(62, 72, 8, 14, 4), with: main)
            var collar = Path()
            collar.move(to: CGPoint(x: 43, y: 70)); collar.addLine(to: CGPoint(x: 50, y: 78)); collar.addLine(to: CGPoint(x: 57, y: 70))
            ctx.stroke(collar, with: accent, lineWidth: 2)
        case .topSkirt:
            var skirt = Path()
            skirt.move(to: CGPoint(x: 36, y: 94))
            skirt.addLine(to: CGPoint(x: 64, y: 94))
            skirt.addLine(to: CGPoint(x: 72, y: 118))
            skirt.addLine(to: CGPoint(x: 28, y: 118))
            skirt.closeSubpath()
            ctx.fill(skirt, with: accent)
            for i in 1..<5 {
                var pleat = Path()
                let x = 36 + CGFloat(i) * 5.6
                pleat.move(to: CGPoint(x: x, y: 96))
                pleat.addLine(to: CGPoint(x: x + (x - 50) * 0.3, y: 117))
                ctx.stroke(pleat, with: edge, lineWidth: 0.6)
            }
            ctx.fill(box(35, 70, 30, 28, 7), with: main)
            ctx.stroke(box(35, 70, 30, 28, 7), with: edge, lineWidth: 0.6)
            ctx.fill(box(30, 72, 8, 14, 4), with: main)
            ctx.fill(box(62, 72, 8, 14, 4), with: main)
        case .puff:
            var p = Path()
            p.move(to: CGPoint(x: 38, y: 70))
            p.addLine(to: CGPoint(x: 62, y: 70))
            p.addLine(to: CGPoint(x: 77, y: 120))
            p.addQuadCurve(to: CGPoint(x: 23, y: 120), control: CGPoint(x: 50, y: 128))
            p.closeSubpath()
            ctx.fill(p, with: main)
            for i in 0..<9 {
                ctx.fill(oval(22 + CGFloat(i) * 6, 117, 7, 6), with: accent)
            }
            ctx.fill(oval(25, 68, 16, 16), with: main)
            ctx.fill(oval(59, 68, 16, 16), with: main)
            ctx.fill(box(37, 90, 26, 3.5, 1.7), with: accent)
            ctx.fill(oval(47, 88, 6, 6), with: accent)
        case .suit:
            ctx.fill(box(33, 70, 34, 42, 8), with: main)
            ctx.stroke(box(33, 70, 34, 42, 8), with: edge, lineWidth: 0.6)
            var lapel = Path()
            lapel.move(to: CGPoint(x: 42, y: 70)); lapel.addLine(to: CGPoint(x: 50, y: 88)); lapel.addLine(to: CGPoint(x: 58, y: 70)); lapel.closeSubpath()
            ctx.fill(lapel, with: accent)
            ctx.fill(box(27, 72, 9, 26, 4.5), with: main)
            ctx.fill(box(64, 72, 9, 26, 4.5), with: main)
            ctx.fill(oval(48.5, 94, 3, 3), with: .color(Palette.gold))
            ctx.fill(oval(48.5, 101, 3, 3), with: .color(Palette.gold))
        case .gown:
            var p = Path()
            p.move(to: CGPoint(x: 39, y: 70))
            p.addLine(to: CGPoint(x: 61, y: 70))
            p.addLine(to: CGPoint(x: 64, y: 96))
            p.addLine(to: CGPoint(x: 84, y: 146))
            p.addQuadCurve(to: CGPoint(x: 16, y: 146), control: CGPoint(x: 50, y: 154))
            p.addLine(to: CGPoint(x: 36, y: 96))
            p.closeSubpath()
            ctx.fill(p, with: main)
            ctx.stroke(p, with: edge, lineWidth: 0.6)
            ctx.fill(box(36, 92, 28, 4, 2), with: accent)
            let sparkles: [CGPoint] = [CGPoint(x: 40, y: 112), CGPoint(x: 58, y: 120), CGPoint(x: 32, y: 134),
                                       CGPoint(x: 66, y: 138), CGPoint(x: 50, y: 130), CGPoint(x: 46, y: 104)]
            for pt in sparkles {
                ctx.fill(oval(pt.x - 1.2, pt.y - 1.2, 2.4, 2.4), with: accent)
            }
        }
    }

    private static func drawBangs(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let hair = GraphicsContext.Shading.color(look.hair)
        var bangs = Path()
        if look.hairStyle == .short {
            bangs.move(to: CGPoint(x: 26, y: 38))
            bangs.addQuadCurve(to: CGPoint(x: 50, y: 13), control: CGPoint(x: 26, y: 13))
            bangs.addQuadCurve(to: CGPoint(x: 74, y: 38), control: CGPoint(x: 74, y: 13))
            bangs.addQuadCurve(to: CGPoint(x: 52, y: 26), control: CGPoint(x: 66, y: 24))
            bangs.addQuadCurve(to: CGPoint(x: 26, y: 38), control: CGPoint(x: 34, y: 22))
        } else {
            bangs.move(to: CGPoint(x: 25, y: 46))
            bangs.addQuadCurve(to: CGPoint(x: 50, y: 13), control: CGPoint(x: 24, y: 14))
            bangs.addQuadCurve(to: CGPoint(x: 75, y: 46), control: CGPoint(x: 76, y: 14))
            bangs.addQuadCurve(to: CGPoint(x: 62, y: 33), control: CGPoint(x: 70, y: 34))
            bangs.addQuadCurve(to: CGPoint(x: 50, y: 36), control: CGPoint(x: 57, y: 37))
            bangs.addQuadCurve(to: CGPoint(x: 38, y: 32), control: CGPoint(x: 43, y: 36))
            bangs.addQuadCurve(to: CGPoint(x: 25, y: 46), control: CGPoint(x: 29, y: 34))
        }
        bangs.closeSubpath()
        ctx.fill(bangs, with: hair)
        // 高光
        var shine = Path()
        shine.move(to: CGPoint(x: 36, y: 22))
        shine.addQuadCurve(to: CGPoint(x: 50, y: 18), control: CGPoint(x: 42, y: 18))
        ctx.stroke(shine, with: .color(Color.white.opacity(0.35)), lineWidth: 1.6)
    }

    private static func drawFace(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let eye = GraphicsContext.Shading.color(Palette.ink)
        ctx.fill(oval(38.5, 40, 7, 9), with: eye)
        ctx.fill(oval(54.5, 40, 7, 9), with: eye)
        ctx.fill(oval(41.6, 41.5, 2.6, 2.6), with: .color(.white))
        ctx.fill(oval(57.6, 41.5, 2.6, 2.6), with: .color(.white))
        ctx.fill(oval(39.8, 45.5, 1.4, 1.4), with: .color(.white.opacity(0.8)))
        ctx.fill(oval(55.8, 45.5, 1.4, 1.4), with: .color(.white.opacity(0.8)))
        if look.hairStyle != .short {
            var lashes = Path()
            lashes.move(to: CGPoint(x: 38.5, y: 41)); lashes.addLine(to: CGPoint(x: 36, y: 39))
            lashes.move(to: CGPoint(x: 61.5, y: 41)); lashes.addLine(to: CGPoint(x: 64, y: 39))
            ctx.stroke(lashes, with: eye, lineWidth: 1)
        }
        ctx.fill(oval(31, 50, 9, 4.5), with: .color(Palette.pink.opacity(0.35)))
        ctx.fill(oval(60, 50, 9, 4.5), with: .color(Palette.pink.opacity(0.35)))
        var mouth = Path()
        mouth.move(to: CGPoint(x: 47, y: 54))
        mouth.addQuadCurve(to: CGPoint(x: 53, y: 54), control: CGPoint(x: 50, y: 57.5))
        ctx.stroke(mouth, with: .color(Palette.rose), lineWidth: 1.2)
    }

    private static func drawAccessory(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let color = GraphicsContext.Shading.color(look.accessoryColor)
        switch look.accessory {
        case .none, .necklace:
            break
        case .bow:
            var left = Path()
            left.move(to: CGPoint(x: 64, y: 22)); left.addLine(to: CGPoint(x: 55, y: 14)); left.addLine(to: CGPoint(x: 56, y: 28)); left.closeSubpath()
            var right = Path()
            right.move(to: CGPoint(x: 64, y: 22)); right.addLine(to: CGPoint(x: 74, y: 16)); right.addLine(to: CGPoint(x: 72, y: 30)); right.closeSubpath()
            ctx.fill(left, with: color)
            ctx.fill(right, with: color)
            ctx.fill(oval(61, 19, 6, 6), with: color)
        case .clip:
            for (i, pt) in [CGPoint(x: 31, y: 30), CGPoint(x: 35, y: 26), CGPoint(x: 39.5, y: 23)].enumerated() {
                ctx.fill(oval(pt.x - 2, pt.y - 2, 4, 4), with: .color(i == 1 ? Palette.cream : .white))
            }
        case .beret:
            ctx.fill(oval(24, 6, 48, 18), with: color)
            ctx.fill(oval(46, 3, 4, 4), with: color)
        case .flower:
            let center = CGPoint(x: 66, y: 24)
            for k in 0..<5 {
                let a = Double(k) / 5 * 2 * .pi
                ctx.fill(oval(center.x + CGFloat(cos(a)) * 3.6 - 2.6, center.y + CGFloat(sin(a)) * 3.6 - 2.6, 5.2, 5.2), with: .color(.white))
            }
            ctx.fill(oval(center.x - 2, center.y - 2, 4, 4), with: .color(Palette.gold))
        case .tiara:
            var crown = Path()
            crown.move(to: CGPoint(x: 37, y: 19))
            crown.addLine(to: CGPoint(x: 41, y: 9)); crown.addLine(to: CGPoint(x: 45, y: 16))
            crown.addLine(to: CGPoint(x: 50, y: 4)); crown.addLine(to: CGPoint(x: 55, y: 16))
            crown.addLine(to: CGPoint(x: 59, y: 9)); crown.addLine(to: CGPoint(x: 63, y: 19))
            crown.closeSubpath()
            ctx.fill(crown, with: .color(Palette.gold))
            ctx.fill(oval(48, 12, 4, 4), with: .color(Palette.pink))
        case .glasses:
            let frame = GraphicsContext.Shading.color(Palette.ink.opacity(0.85))
            ctx.stroke(oval(35.5, 38.5, 13, 12), with: frame, lineWidth: 1.2)
            ctx.stroke(oval(51.5, 38.5, 13, 12), with: frame, lineWidth: 1.2)
            var bridge = Path()
            bridge.move(to: CGPoint(x: 48.5, y: 43)); bridge.addLine(to: CGPoint(x: 51.5, y: 43))
            ctx.stroke(bridge, with: frame, lineWidth: 1.2)
        }
    }

    private static func drawBag(_ look: AvatarLook, _ ctx: GraphicsContext) {
        let bag = GraphicsContext.Shading.color(look.bag)
        let edge = GraphicsContext.Shading.color(Palette.ink.opacity(0.2))
        switch look.bagStyle {
        case 1:
            var handle = Path()
            handle.addArc(center: CGPoint(x: 77, y: 106), radius: 6, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            ctx.stroke(handle, with: bag, lineWidth: 2)
            ctx.fill(box(68, 105, 18, 14, 4), with: bag)
            ctx.stroke(box(68, 105, 18, 14, 4), with: edge, lineWidth: 0.6)
        case 2:
            var strap = Path()
            strap.move(to: CGPoint(x: 70, y: 78)); strap.addLine(to: CGPoint(x: 72, y: 100))
            ctx.stroke(strap, with: bag, lineWidth: 2)
            ctx.fill(box(66, 98, 20, 22, 2), with: bag)
            ctx.stroke(box(66, 98, 20, 22, 2), with: edge, lineWidth: 0.6)
        case 3:
            var chain = Path()
            chain.move(to: CGPoint(x: 62, y: 74)); chain.addLine(to: CGPoint(x: 76, y: 106))
            ctx.stroke(chain, with: .color(Palette.gold), style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
            ctx.fill(box(69, 105, 15, 11, 2.5), with: bag)
            ctx.fill(oval(75, 108, 3, 3), with: .color(Palette.gold))
        default:
            break
        }
    }
}
