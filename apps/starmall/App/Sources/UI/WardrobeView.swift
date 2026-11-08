import SwiftUI

/// 衣橱：换装提升魅力值，魅力值直接带来客流（全商场收入加成）。
struct WardrobeView: View {
    @EnvironmentObject private var store: GameStore
    @State private var slot: OutfitSlot = .dress

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height * 1.1 {
                HStack(spacing: 14) {
                    stage.frame(width: geo.size.width * 0.38)
                    closet
                }
                .padding(14)
            } else {
                VStack(spacing: 12) {
                    stage.frame(height: max(220, geo.size.height * 0.42))
                    closet
                }
                .padding(14)
            }
        }
    }

    private var stage: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [Palette.blush.opacity(0.7), Palette.lilac.opacity(0.5)],
                                     startPoint: .top, endPoint: .bottom))
            // T 台聚光灯
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0)], center: .center, startRadius: 2, endRadius: 120))
                .frame(width: 220, height: 40)
                .padding(.bottom, 18)
            AvatarView(look: store.heroineLook)
                .padding(.vertical, 18)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.state.equipped)
            VStack {
                HStack {
                    Label("魅力 \(store.charm)", systemImage: "heart.fill")
                    Spacer()
                    Text("客流 ×\(String(format: "%.2f", store.charmMultiplier))")
                }
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.rose)
                .padding(14)
                Spacer()
            }
        }
    }

    private var closet: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OutfitSlot.allCases, id: \.self) { s in
                    let on = s == slot
                    Button {
                        withAnimation(.snappy) { slot = s }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: s.symbol).font(.system(size: 14, weight: .semibold))
                            Text(s.rawValue).font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(on ? .white : Palette.ink.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(on ? Palette.pink : .white))
                    }
                    .buttonStyle(Squish())
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(Catalog.outfits.filter { $0.slot == slot }) { item in
                        OutfitCard(item: item)
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }
}

struct OutfitCard: View {
    @EnvironmentObject private var store: GameStore
    let item: OutfitItem

    var body: some View {
        let owned = store.ownsOutfit(item.id)
        let equipped = store.state.equipped[item.slot.rawValue] == item.id
        Button {
            store.buyOrEquip(item)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(item.color == .clear ? Palette.cream : item.color.opacity(0.25))
                    preview
                }
                .frame(height: 70)
                Text(item.name)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 2) {
                    Image(systemName: "heart.fill").font(.system(size: 8))
                    Text("+\(item.charm)")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.pink)
                priceTag(owned: owned, equipped: equipped)
            }
            .foregroundStyle(Palette.ink)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(equipped ? Palette.pink : .clear, lineWidth: 2))
            )
        }
        .buttonStyle(Squish())
    }

    @ViewBuilder
    private var preview: some View {
        switch item.slot {
        case .hair:
            Image(systemName: "comb.fill").font(.system(size: 26)).foregroundStyle(item.color)
                .shadow(color: .black.opacity(0.15), radius: 1)
        case .dress:
            Image(systemName: item.style == AvatarDress.gown.rawValue ? "sparkles" : "tshirt.fill")
                .font(.system(size: 30))
                .foregroundStyle(item.color)
                .shadow(color: .black.opacity(0.15), radius: 1)
        case .shoes:
            Image(systemName: "shoe.fill").font(.system(size: 28)).foregroundStyle(item.color)
                .shadow(color: .black.opacity(0.2), radius: 1)
        case .accessory:
            Image(systemName: item.style == 0 ? "circle.slash" : "sparkles").font(.system(size: 26))
                .foregroundStyle(item.style == 0 ? Palette.ink.opacity(0.3) : item.color)
                .shadow(color: .black.opacity(0.15), radius: 1)
        case .bag:
            Image(systemName: item.style == 0 ? "circle.slash" : "handbag.fill").font(.system(size: 26))
                .foregroundStyle(item.style == 0 ? Palette.ink.opacity(0.3) : item.color)
                .shadow(color: .black.opacity(0.2), radius: 1)
        }
    }

    @ViewBuilder
    private func priceTag(owned: Bool, equipped: Bool) -> some View {
        if equipped {
            Text("穿着中").tagStyle(Palette.pink)
        } else if owned {
            Text("穿上").tagStyle(Palette.mint)
        } else if item.gems > 0 {
            Label("\(item.gems)", systemImage: "diamond.fill").tagStyle(Palette.sky)
        } else {
            Label(Fmt.num(item.price), systemImage: "dollarsign.circle.fill").tagStyle(Palette.gold)
        }
    }
}

extension View {
    func tagStyle(_ color: Color) -> some View {
        self.font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(color))
    }
}
