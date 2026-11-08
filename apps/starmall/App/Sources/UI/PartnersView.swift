import SwiftUI

struct PartnersView: View {
    @EnvironmentObject private var store: GameStore
    @State private var results: [RecruitResult] = []
    @State private var showResults = false
    @State private var detail: PartnerDef?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                recruitBanner
                HStack {
                    Text("我的伙伴")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                    Spacer()
                    Text("全商场收入 +\(Int((store.partnerPassive - 1) * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.rose)
                }
                .foregroundStyle(Palette.ink)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Catalog.partners) { def in
                        PartnerCard(def: def)
                            .onTapGesture { detail = def }
                    }
                }
            }
            .padding(14)
        }
        .sheet(isPresented: $showResults) {
            RecruitResultsView(results: results)
                .presentationDetents([.large])
                .presentationCornerRadius(28)
        }
        .sheet(item: $detail) { def in
            PartnerDetail(def: def)
                .presentationDetents([.medium])
                .presentationCornerRadius(28)
        }
    }

    private var recruitBanner: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: -18) {
                AvatarView(look: Catalog.partners[6].look).frame(width: 80, height: 104)
                AvatarView(look: Catalog.partners[10].look).frame(width: 96, height: 124).zIndex(1)
                AvatarView(look: Catalog.partners[11].look).frame(width: 80, height: 104)
            }
            Text("星光招募")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("SSR 6% · SR 24% · 十连必出 SR 以上")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 12) {
                CandyButton(title: "招募 1 次", subtitle: "\(GameStore.recruitCost) 钻石", color: Palette.lilac,
                            enabled: store.state.gems >= GameStore.recruitCost) { recruit(1) }
                CandyButton(title: "招募 10 次", subtitle: "\(GameStore.recruitTenCost) 钻石", color: Palette.rose,
                            enabled: store.state.gems >= GameStore.recruitTenCost) { recruit(10) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Palette.pink, Palette.lilac], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Palette.pink.opacity(0.3), radius: 12, y: 6)
        )
    }

    private func recruit(_ times: Int) {
        let r = store.recruit(times: times)
        guard !r.isEmpty else { return }
        results = r
        showResults = true
    }
}

struct PartnerCard: View {
    @EnvironmentObject private var store: GameStore
    let def: PartnerDef

    var body: some View {
        let owned = store.owns(def.id)
        let progress = store.progress(def.id)
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                AvatarView(look: def.look)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .background(def.rarity.color.opacity(owned ? 0.35 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .saturation(owned ? 1 : 0)
                    .opacity(owned ? 1 : 0.5)
                RarityBadge(rarity: def.rarity)
                    .padding(6)
            }
            Text(owned ? def.name : "？？？")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.ink)
            Text(owned ? "Lv.\(progress?.level ?? 1) · \(def.title)" : def.title)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.55))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
        .overlay(alignment: .topTrailing) {
            if let p = progress, p.shards >= p.level {
                Circle().fill(Palette.rose).frame(width: 10, height: 10).padding(6)
            }
        }
    }
}

struct RarityBadge: View {
    let rarity: Rarity

    var body: some View {
        Text(rarity.rawValue)
            .font(.system(size: 10, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(rarity == .r ? Color(red: 0.45, green: 0.65, blue: 0.90) : (rarity == .sr ? Color(red: 0.62, green: 0.50, blue: 0.90) : Palette.gold)))
    }
}

struct PartnerDetail: View {
    @EnvironmentObject private var store: GameStore
    let def: PartnerDef

    var body: some View {
        let owned = store.owns(def.id)
        let progress = store.progress(def.id)
        HStack(spacing: 18) {
            AvatarView(look: def.look)
                .frame(width: 130, height: 180)
                .background(Circle().fill(def.rarity.color.opacity(0.35)).frame(width: 140, height: 140))
                .saturation(owned ? 1 : 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RarityBadge(rarity: def.rarity)
                    Text(def.title).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.ink.opacity(0.6))
                }
                Text(owned ? def.name : "尚未招募")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                Text("「\(def.quote)」")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.7))
                Label(def.skillText, systemImage: "sparkles")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.rose)
                if let p = progress {
                    Text("等级 Lv.\(p.level) · 碎片 \(p.shards)/\(p.level)")
                        .font(.system(size: 12, design: .rounded))
                    CandyButton(title: "升级", subtitle: "每级加成 +25%", color: Palette.pink, enabled: p.shards >= p.level) {
                        store.levelUpPartner(def.id)
                    }
                } else {
                    Text("在星光招募中可能遇见她/他")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.ink.opacity(0.5))
                }
            }
            .foregroundStyle(Palette.ink)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }
}

extension PartnerDef: Equatable {
    static func == (lhs: PartnerDef, rhs: PartnerDef) -> Bool { lhs.id == rhs.id }
}

struct RecruitResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let results: [RecruitResult]
    @State private var revealed = 0

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.lilac, Palette.pink], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text("招募结果")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        resultCard(result)
                            .opacity(index < revealed ? 1 : 0)
                            .scaleEffect(index < revealed ? 1 : 0.6)
                    }
                }
                .padding(.horizontal, 18)
                Spacer()
                CandyButton(title: revealed < results.count ? "全部翻开" : "收下", color: Palette.rose) {
                    if revealed < results.count {
                        withAnimation(.spring) { revealed = results.count }
                    } else {
                        dismiss()
                    }
                }
                .padding(.horizontal, 40)
            }
            .padding(.top, 30)
            .padding(.bottom, 20)
        }
        .onAppear { revealNext() }
    }

    private func revealNext() {
        guard revealed < results.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (revealed == 0 ? 0.2 : 0.18)) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { revealed += 1 }
            revealNext()
        }
    }

    private func resultCard(_ result: RecruitResult) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                AvatarView(look: result.partner.look)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .background(result.partner.rarity.color.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                RarityBadge(rarity: result.partner.rarity).padding(5)
            }
            Text(result.partner.name)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            Text(result.isNew ? "NEW!" : "碎片 +1")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(result.isNew ? Palette.rose : Palette.ink.opacity(0.5))
        }
        .foregroundStyle(Palette.ink)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
        .shadow(color: result.partner.rarity == .ssr ? Palette.gold.opacity(0.8) : .clear, radius: 10)
    }
}
