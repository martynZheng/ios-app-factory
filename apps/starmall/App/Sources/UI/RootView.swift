import SwiftUI

@main
struct StarMallApp: App {
    @StateObject private var store = GameStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: store.start()
                    case .background, .inactive: store.pause()
                    @unknown default: break
                    }
                }
                .onAppear { store.start() }
        }
    }
}

enum Tab: String, CaseIterable {
    case mall = "商场"
    case partners = "伙伴"
    case wardrobe = "衣橱"
    case decor = "家装"

    var symbol: String {
        switch self {
        case .mall: return "building.2.fill"
        case .partners: return "person.2.fill"
        case .wardrobe: return "hanger"
        case .decor: return "sofa.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: GameStore
    @State private var tab: Tab = .mall

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                HUD()
                Group {
                    switch tab {
                    case .mall: MallView()
                    case .partners: PartnersView()
                    case .wardrobe: WardrobeView()
                    case .decor: DecorView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TabBar(tab: $tab)
            }
            ToastView()
            if !store.state.introSeen {
                IntroView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: Binding(get: { store.offlineReward != nil && store.state.introSeen },
                                    set: { if !$0 { store.collectOffline(double: false) } })) {
            OfflineSheet()
                .presentationDetents([.height(380)])
                .presentationCornerRadius(28)
        }
    }
}

// MARK: - 背景

struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.cream, Color(red: 1.0, green: 0.92, blue: 0.94)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                // 星星点点
                var rng = SeededRandom(seed: 7)
                for _ in 0..<40 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height
                    let r = 1 + rng.next() * 2.2
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                                 with: .color(Palette.pink.opacity(0.18)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

// MARK: - 顶栏

struct HUD: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(look: store.heroineLook)
                .frame(width: 40, height: 52)
                .background(Circle().fill(Palette.blush.opacity(0.7)).frame(width: 44, height: 44).offset(y: -4))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.state.heroineName)的星光百货")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundStyle(Palette.gold)
                    Text(Fmt.num(store.state.coins))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text("+\(Fmt.num(store.incomePerSecond))/秒")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.rose)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Pill(symbol: "diamond.fill", text: "\(store.state.gems)", color: Palette.sky)
                Pill(symbol: "heart.fill", text: "\(store.charm)", color: Palette.pink)
            }
            if store.canSignIn {
                Button { store.signIn() } label: {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.pink))
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(Palette.gold).frame(width: 10, height: 10)
                        }
                }
                .buttonStyle(Squish())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.85))
                .shadow(color: Palette.pink.opacity(0.15), radius: 10, y: 4)
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

struct Pill: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text).font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(0.35)))
    }
}

// MARK: - 底栏

struct TabBar: View {
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                let on = item == tab
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tab = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: on ? 20 : 18, weight: .semibold))
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(on ? Palette.pink : Palette.ink.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(on ? Palette.blush.opacity(0.6) : .clear)
                            .padding(.horizontal, 10)
                    )
                }
                .buttonStyle(Squish())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.92))
                .shadow(color: Palette.pink.opacity(0.18), radius: 12, y: -2)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - 通用

struct Squish: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct CandyButton: View {
    let title: String
    var subtitle: String? = nil
    var color: Color = Palette.pink
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(enabled ? color : Color.gray.opacity(0.45))
                    .shadow(color: (enabled ? color : .gray).opacity(0.35), radius: 6, y: 3)
            )
        }
        .buttonStyle(Squish())
        .disabled(!enabled)
    }
}

struct ToastView: View {
    @EnvironmentObject private var store: GameStore
    @State private var token = 0

    var body: some View {
        VStack {
            if let text = store.toast {
                Text(text)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Palette.ink.opacity(0.82)))
                    .padding(.top, 90)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.toast)
        .onChange(of: store.toast) { _, newValue in
            guard newValue != nil else { return }
            token += 1
            let current = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if current == token { store.toast = nil }
            }
        }
    }
}

// MARK: - 离线收益

struct OfflineSheet: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        VStack(spacing: 14) {
            AvatarView(look: store.heroineLook)
                .frame(width: 90, height: 120)
            Text("欢迎回来，\(store.state.heroineName)！")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.ink)
            if let reward = store.offlineReward {
                Text("你不在的 \(Fmt.duration(reward.seconds)) 里，伙伴们帮你赚到了")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Palette.ink.opacity(0.7))
                Text(Fmt.num(reward.amount))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(Palette.gold)
            }
            HStack(spacing: 12) {
                CandyButton(title: "收下", color: Palette.peach) { store.collectOffline(double: false) }
                CandyButton(title: "双倍领取", subtitle: "20 钻石", color: Palette.pink, enabled: store.state.gems >= 20) {
                    store.collectOffline(double: true)
                }
            }
        }
        .padding(24)
    }
}
