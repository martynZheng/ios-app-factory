import SwiftUI

/// 家装：布置老板办公室。每件家具都会提高离线收益比例和离线时长上限。
struct DecorView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.1
            let layout = wide ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                VStack(spacing: 8) {
                    OfficeRoom()
                        .aspectRatio(1.35, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    HStack {
                        Label("离线收益 \(Int(store.offlineRate * 100))%", systemImage: "moon.zzz.fill")
                        Spacer()
                        Label("最长 \(Int(store.offlineHours)) 小时", systemImage: "clock.fill")
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.rose)
                    .padding(.horizontal, 6)
                }
                .frame(maxWidth: wide ? geo.size.width * 0.5 : .infinity)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(Catalog.decor) { item in
                            DecorRow(item: item)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(14)
        }
    }
}

struct DecorRow: View {
    @EnvironmentObject private var store: GameStore
    let item: DecorItem

    var body: some View {
        let owned = store.ownsDecor(item.id)
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 20))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(Circle().fill(item.color.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 14, weight: .heavy, design: .rounded))
                Text("离线收益 +\(Int(DecorItem.rateBonus * 100))% · 时长 +\(Int(DecorItem.hoursBonus))h")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.55))
            }
            Spacer()
            if owned {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.mint)
            } else {
                Button {
                    store.buyDecor(item)
                } label: {
                    Text(Fmt.num(item.price))
                        .tagStyle(store.state.coins >= item.price ? Palette.pink : Color.gray.opacity(0.45))
                }
                .buttonStyle(Squish())
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
    }
}

/// 办公室插画：买了的家具会出现在房间里。
struct OfficeRoom: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Canvas { ctx, size in
                    // 墙
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.72)),
                             with: .color(Color(red: 1.0, green: 0.93, blue: 0.90)))
                    // 墙纸竖纹
                    let stripe = size.width / 14
                    for i in stride(from: 0, to: 14, by: 2) {
                        ctx.fill(Path(CGRect(x: CGFloat(i) * stripe, y: 0, width: stripe, height: size.height * 0.72)),
                                 with: .color(Palette.blush.opacity(0.25)))
                    }
                    // 地板
                    ctx.fill(Path(CGRect(x: 0, y: size.height * 0.72, width: size.width, height: size.height * 0.28)),
                             with: .color(Color(red: 0.93, green: 0.82, blue: 0.72)))
                    for i in 0..<8 {
                        var line = Path()
                        let x = size.width * CGFloat(i) / 7
                        line.move(to: CGPoint(x: x, y: size.height * 0.72))
                        line.addLine(to: CGPoint(x: size.width / 2 + (x - size.width / 2) * 1.6, y: size.height))
                        ctx.stroke(line, with: .color(Palette.cocoa.opacity(0.12)), lineWidth: 1)
                    }
                    // 窗户
                    let window = CGRect(x: size.width * 0.40, y: size.height * 0.16, width: size.width * 0.26, height: size.height * 0.32)
                    ctx.fill(Path(roundedRect: window, cornerRadius: 10), with: .color(Palette.sky.opacity(0.8)))
                    ctx.stroke(Path(roundedRect: window, cornerRadius: 10), with: .color(.white), lineWidth: 5)
                    var cross = Path()
                    cross.move(to: CGPoint(x: window.midX, y: window.minY)); cross.addLine(to: CGPoint(x: window.midX, y: window.maxY))
                    cross.move(to: CGPoint(x: window.minX, y: window.midY)); cross.addLine(to: CGPoint(x: window.maxX, y: window.midY))
                    ctx.stroke(cross, with: .color(.white), lineWidth: 3)
                    // 窗帘
                    ctx.fill(Path(roundedRect: CGRect(x: window.minX - 14, y: window.minY - 6, width: 16, height: window.height + 16), cornerRadius: 6), with: .color(Palette.pink.opacity(0.7)))
                    ctx.fill(Path(roundedRect: CGRect(x: window.maxX - 2, y: window.minY - 6, width: 16, height: window.height + 16), cornerRadius: 6), with: .color(Palette.pink.opacity(0.7)))
                }
                ForEach(Catalog.decor.filter { store.ownsDecor($0.id) }) { item in
                    Image(systemName: item.symbol)
                        .font(.system(size: min(w, h) * 0.12))
                        .foregroundStyle(item.color == .white ? Palette.ink.opacity(0.75) : item.color)
                        .shadow(color: Palette.ink.opacity(0.25), radius: 2, y: 2)
                        .position(x: item.spot.x * w, y: item.spot.y * h)
                        .transition(.scale.combined(with: .opacity))
                }
                AvatarView(look: store.heroineLook)
                    .frame(width: w * 0.2, height: h * 0.5)
                    .position(x: w * 0.52, y: h * 0.66)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: store.state.ownedDecor)
        }
    }
}
