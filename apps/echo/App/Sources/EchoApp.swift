import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var transcriber = Transcriber.shared
    @StateObject private var sync = PhoneSync.shared
    @StateObject private var player = Player.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLock") private var appLock = false
    @AppStorage("retentionDays") private var retentionDays = 30
    @State private var locked = UserDefaults.standard.bool(forKey: "appLock")

    @StateObject private var coordinator = DigestCoordinator.shared

    init() {
        DigestEngine.chooseDefaultEngine()
        PhoneSync.shared.activate()
        if Store.isDemo { Demo.seed() }
        DigestCoordinator.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(store)
                    .environmentObject(transcriber)
                    .environmentObject(sync)
                    .environmentObject(player)
                    .environmentObject(coordinator)
                if appLock && locked { lockScreen }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if appLock && locked { AppLock.unlock { ok in if ok { locked = false } } }
                    store.cleanupAudio(olderThanDays: retentionDays)
                    transcriber.kick()
                    coordinator.updateRecent()
                case .background:
                    if appLock { locked = true }
                    store.saveNow()
                    player.stop()
                default:
                    break
                }
            }
        }
    }

    private var lockScreen: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("拾言已锁定").font(.headline)
                Button("解锁") { AppLock.unlock { ok in if ok { locked = false } } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct RootView: View {
    @State private var showSettings = false
    @State private var selection = Store.isDemo ? UserDefaults.standard.integer(forKey: "tab") : 0

    var body: some View {
        TabView(selection: $selection) {
            tab(0, "今日回顾", "sun.max") { TodayView() }
            tab(1, "时间线", "text.alignleft") { TranscriptView() }
            tab(2, "待办", "checklist") { TodosView() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func tab<V: View>(_ index: Int, _ title: String, _ symbol: String, @ViewBuilder content: () -> V) -> some View {
        NavigationStack {
            content()
                .navigationTitle(index == 0 ? "" : title)
                .navigationBarTitleDisplayMode(index == 0 ? .inline : .large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("设置")
                    }
                }
        }
        .tabItem { Label(title, systemImage: symbol) }
        .tag(index)
    }
}
