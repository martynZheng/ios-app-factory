import SwiftUI

struct MallView: View {
    @EnvironmentObject private var store: GameStore
    @State private var selectedShop: Int?
    @State private var showOrder = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if let order = store.order {
                    OrderBanner(order: order) { showOrder = true }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                StarProgress()
                ForEach(0..<Catalog.floorNames.count, id: \.self) { floor in
                    floorSection(floor)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.order?.id)
        }
        .sheet(item: Binding(get: { selectedShop.map { ShopRef(id: $0) } }, set: { selectedShop = $0?.id })) { ref in
            ShopSheet(shopID: ref.id)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showOrder) {
            OrderSheet()
                .presentationDetents([.height(460)])
                .presentationCornerRadius(28)
        }
    }

    @ViewBuilder
    private func floorSection(_ floor: Int) -> some View {
        let shops = Catalog.shops.filter { $0.floor == floor }
        let visible = shops.first.map { floor == 0 || store.isUnlocked($0.id) || store.isUnlocked($0.id - 1) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(Catalog.floorNames[floor])
            }
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(Palette.rose)

            if visible {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(shops) { shop in
                        ShopCard(shop: shop)
                            .onTapGesture {
                                if store.isUnlocked(shop.id) {
                                    store.tapShop(shop.id)
                                } else {
                                    selectedShop = shop.id
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.3) {
                                selectedShop = shop.id
                            }
                    }
                }
            } else {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("爆改完楼下的店铺后开放")
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.5)))
            }
        }
    }
}

struct ShopRef: Identifiable { let id: Int }

/// 商场人气星级进度
struct StarProgress: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .foregroundStyle(Palette.gold)
            Text("商场人气 \(store.stars)★")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            Text("轻点店铺招揽顾客 · 长按管理店铺")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.5))
        }
        .foregroundStyle(Palette.ink)
    }
}

// MARK: - 店铺卡片

struct ShopCard: View {
    @EnvironmentObject private var store: GameStore
    let shop: ShopDef

    var body: some View {
        let unlocked = store.isUnlocked(shop.id)
        VStack(spacing: 0) {
            Storefront(shop: shop, unlocked: unlocked)
                .frame(height: 112)
                .overlay(alignment: .top) { floaters }
            VStack(spacing: 4) {
                HStack {
                    Text(shop.name)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    if unlocked {
                        Text("Lv.\(store.level(shop.id))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.rose)
                    }
                }
                if unlocked {
                    HStack {
                        Text("\(Fmt.num(store.shopIncome(shop.id)))/秒")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink.opacity(0.6))
                        Spacer()
                        upgradeChip
                    }
                    milestoneBar
                } else {
                    Text(shop.dusty)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Image(systemName: "hammer.fill")
                        Text("爆改 \(Fmt.num(shop.unlockCost))")
                    }
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(Capsule().fill(store.state.coins >= shop.unlockCost ? Palette.pink : Color.gray.opacity(0.4)))
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)
                .shadow(color: Palette.pink.opacity(0.14), radius: 8, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
    }

    private var upgradeChip: some View {
        let cost = store.upgradeCost(shop.id, levels: 1)
        let ok = store.state.coins >= cost
        return Button {
            store.upgrade(shop.id, amount: .one)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                Text(Fmt.num(cost))
            }
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(ok ? Palette.pink : Color.gray.opacity(0.35)))
        }
        .buttonStyle(Squish())
        .disabled(!ok)
    }

    private var milestoneBar: some View {
        let lv = store.level(shop.id)
        let next = store.nextMilestone(shop.id) ?? lv
        let prev = Catalog.milestones.last { $0 <= lv } ?? 0
        let fraction = next > prev ? Double(lv - prev) / Double(next - prev) : 1
        return HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.blush.opacity(0.4))
                    Capsule().fill(LinearGradient(colors: [Palette.peach, Palette.pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            HStack(spacing: 1) {
                Image(systemName: "star.fill").font(.system(size: 8))
                Text("\(store.milestonesReached(shop.id))")
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Palette.gold)
        }
    }

    private var floaters: some View {
        ZStack {
            ForEach(store.floaters.filter { $0.shopID == shop.id }) { f in
                FloatingText(text: f.text)
            }
        }
    }
}

struct FloatingText: View {
    let text: String
    @State private var rise = false

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .black, design: .rounded))
            .foregroundStyle(Palette.gold)
            .shadow(color: .white, radius: 2)
            .offset(y: rise ? -10 : 40)
            .opacity(rise ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.9)) { rise = true } }
    }
}

// MARK: - 店面插画

struct Storefront: View {
    let shop: ShopDef
    let unlocked: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !unlocked)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                draw(context, size: size, time: t)
            }
        }
        .saturation(unlocked ? 1 : 0.15)
        .overlay {
            if !unlocked {
                ZStack {
                    Color.white.opacity(0.35)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Palette.ink.opacity(0.5))
                }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, time: Double) {
        let w = size.width
        let h = size.height
        let main = shop.colors[0]
        let accent = shop.colors[1]

        // 墙面
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(main.opacity(0.28)))
        // 地面
        ctx.fill(Path(CGRect(x: 0, y: h * 0.82, width: w, height: h * 0.18)), with: .color(Palette.cream))

        // 遮阳棚：条纹 + 波浪边
        let awningTop = h * 0.08
        let awningH = h * 0.2
        let stripes = 8
        let sw = w / CGFloat(stripes)
        for i in 0..<stripes {
            let rect = CGRect(x: CGFloat(i) * sw, y: awningTop, width: sw, height: awningH)
            ctx.fill(Path(rect), with: .color(i % 2 == 0 ? main : .white))
        }
        for i in 0..<stripes {
            let rect = CGRect(x: CGFloat(i) * sw, y: awningTop + awningH - sw / 2, width: sw, height: sw)
            ctx.fill(Path(ellipseIn: rect), with: .color(i % 2 == 0 ? main : .white))
        }

        // 招牌
        let sign = CGRect(x: w * 0.22, y: 0, width: w * 0.56, height: awningTop + 4)
        ctx.fill(Path(roundedRect: sign, cornerRadius: 4), with: .color(accent))

        // 橱窗 + 门
        let windowRect = CGRect(x: w * 0.08, y: h * 0.40, width: w * 0.52, height: h * 0.40)
        ctx.fill(Path(roundedRect: windowRect, cornerRadius: 8), with: .color(.white.opacity(0.85)))
        ctx.stroke(Path(roundedRect: windowRect, cornerRadius: 8), with: .color(accent.opacity(0.5)), lineWidth: 2)
        let door = CGRect(x: w * 0.68, y: h * 0.40, width: w * 0.22, height: h * 0.42)
        ctx.fill(Path(roundedRect: door, cornerRadius: 10), with: .color(accent.opacity(0.75)))
        ctx.fill(Path(ellipseIn: CGRect(x: door.minX + door.width * 0.7, y: door.midY, width: 4, height: 4)), with: .color(Palette.gold))

        // 橱窗里的商品图标
        var symbol = ctx.resolve(Image(systemName: shop.symbol))
        symbol.shading = .color(accent)
        let bob = unlocked ? CGFloat(sin(time * 2)) * 2 : 0
        ctx.draw(symbol, in: CGRect(x: windowRect.midX - 15, y: windowRect.midY - 15 + bob, width: 30, height: 30))

        // 顾客：小人从左往右走
        guard unlocked else { return }
        let walkers = 3
        for k in 0..<walkers {
            let speed = 18.0 + Double(k) * 7
            let phase = Double(k) * 0.37
            let span = Double(w) + 30
            let x = CGFloat((time * speed + phase * span).truncatingRemainder(dividingBy: span)) - 15
            let baseY = h * 0.82
            let hop = CGFloat(abs(sin(time * 6 + Double(k)))) * 2
            let colors: [Color] = [Palette.pink, Palette.lilac, Palette.mint, Palette.peach, Palette.sky]
            let body = colors[(k + shop.id) % colors.count]
            ctx.fill(Path(roundedRect: CGRect(x: x - 5, y: baseY - 16 - hop, width: 10, height: 13), cornerRadius: 4), with: .color(body))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: baseY - 27 - hop, width: 10, height: 10)), with: .color(Palette.skin))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: baseY - 28.5 - hop, width: 11, height: 6)), with: .color(Palette.cocoa))
        }
    }
}

// MARK: - 店铺详情

struct ShopSheet: View {
    @EnvironmentObject private var store: GameStore
    let shopID: Int
    @State private var amount: UpgradeAmount = .one

    var body: some View {
        let shop = Catalog.shops[shopID]
        let unlocked = store.isUnlocked(shopID)
        ScrollView {
            VStack(spacing: 16) {
                Storefront(shop: shop, unlocked: unlocked)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text(shop.name)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Palette.ink)
                if unlocked {
                    stats(shop)
                    Picker("", selection: $amount) {
                        ForEach(UpgradeAmount.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let n = store.levels(for: amount, shopID: shopID)
                    let cost = store.upgradeCost(shopID, levels: n)
                    CandyButton(title: "升级 +\(n) 级", subtitle: "花费 \(Fmt.num(cost))", enabled: store.state.coins >= cost) {
                        store.upgrade(shopID, amount: amount)
                    }
                    managers
                    VStack(alignment: .leading, spacing: 6) {
                        Text("招牌商品").font(.system(size: 13, weight: .bold, design: .rounded))
                        Text(shop.products.joined(separator: " · "))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Palette.ink.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("这里原本是\(shop.dusty)。爆改之后，它会变成全城最火的打卡店！")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.7))
                        .multilineTextAlignment(.center)
                    let prevOpen = shopID == 0 || store.isUnlocked(shopID - 1)
                    CandyButton(title: prevOpen ? "爆改开业" : "先爆改上一家店",
                                subtitle: "花费 \(Fmt.num(shop.unlockCost))",
                                enabled: prevOpen && store.state.coins >= shop.unlockCost) {
                        store.unlock(shopID)
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.cream)
    }

    private func stats(_ shop: ShopDef) -> some View {
        HStack(spacing: 10) {
            statBox("等级", "Lv.\(store.level(shopID))")
            statBox("每秒收入", Fmt.num(store.shopIncome(shopID)))
            statBox("下个里程碑", store.nextMilestone(shopID).map { "Lv.\($0)" } ?? "已满")
        }
    }

    private func statBox(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Palette.ink)
            Text(title).font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
    }

    private var managers: some View {
        let defs = Catalog.partners.filter { $0.shopID == shopID }
        return VStack(alignment: .leading, spacing: 8) {
            Text("店长").font(.system(size: 13, weight: .bold, design: .rounded))
            HStack(spacing: 10) {
                ForEach(defs) { def in
                    let owned = store.owns(def.id)
                    VStack(spacing: 4) {
                        AvatarView(look: def.look)
                            .frame(width: 54, height: 70)
                            .opacity(owned ? 1 : 0.3)
                        Text(owned ? def.name : "未招募")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Text(def.skillText)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Palette.ink.opacity(0.55))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 紧急订单

struct OrderBanner: View {
    @EnvironmentObject private var store: GameStore
    let order: RushOrder
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = max(0, Int(order.expires.timeIntervalSince(timeline.date)))
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.rose))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("紧急订单 · \(Catalog.shops[order.shopID].name)")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                        Text("客人要 \(order.count) 份\(order.product)，\(remaining) 秒内完成")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Palette.ink.opacity(0.65))
                    }
                    Spacer()
                    Text("去完成")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(Palette.pink))
                }
                .foregroundStyle(Palette.ink)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Palette.lemon.opacity(0.9))
                )
            }
            .buttonStyle(Squish())
        }
    }
}

struct OrderSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var pop = false

    var body: some View {
        VStack(spacing: 16) {
            if let order = store.order {
                let shop = Catalog.shops[order.shopID]
                Text("\(shop.name) · 紧急订单")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                Text("\(order.count) 份\(order.product)")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.65))
                Button {
                    store.workOnOrder()
                    pop.toggle()
                } label: {
                    ZStack {
                        Circle().fill(shop.colors[0].opacity(0.5)).frame(width: 150, height: 150)
                        Image(systemName: shop.symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(shop.colors[1])
                            .scaleEffect(pop ? 1.12 : 1)
                            .animation(.spring(response: 0.18, dampingFraction: 0.4), value: pop)
                    }
                }
                .buttonStyle(Squish())
                Text("连续点击制作！")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.rose)
                ProgressView(value: Double(order.progress), total: Double(order.required))
                    .tint(Palette.pink)
                    .padding(.horizontal, 30)
                Text("奖励：金币 \(Fmt.num(order.reward)) · 钻石 \(order.gems)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.6))
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Palette.mint)
                Text("订单完成啦！")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                CandyButton(title: "好的", color: Palette.pink) { dismiss() }
                    .padding(.horizontal, 60)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .sensoryFeedback(.impact(weight: .light), trigger: pop)
    }
}
