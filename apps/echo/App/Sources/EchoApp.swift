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

    init() { PhoneSync.shared.activate() }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(store)
                    .environmentObject(transcriber)
                    .environmentObject(sync)
                    .environmentObject(player)
                if appLock && locked { lockScreen }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if appLock && locked { AppLock.unlock { ok in if ok { locked = false } } }
                    store.cleanupAudio(olderThanDays: retentionDays)
                    transcriber.kick()
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

    var body: some View {
        TabView {
            tab("今日回顾", "sun.max") { TodayView() }
            tab("时间线", "text.alignleft") { TranscriptView() }
            tab("待办", "checklist") { TodosView() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func tab<V: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> V) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("设置")
                    }
                }
        }
        .tabItem { Label(title, systemImage: symbol) }
    }
}

/// 来源面板：展示一条回顾/待办所依据的原始转写，可回听。
struct SourceSheet: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    let item: DigestItem

    var body: some View {
        NavigationStack {
            List {
                Section("整理结果") { Text(item.text) }
                Section("原始转写") {
                    let lines = item.sourceLineIDs.compactMap { store.line($0) }
                    if lines.isEmpty {
                        Text("来源转写已被删除").foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in LineRow(line: line) }
                }
            }
            .navigationTitle("来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 一句转写：时间 + 文字，点按回听。
struct LineRow: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var player: Player
    let line: Line

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        let hasAudio = store.segment(line.segmentID)?.hasAudio ?? false
        let playing = player.playingSegment == line.segmentID
        Button {
            if hasAudio { player.toggle(segmentID: line.segmentID, at: line.offset) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.time.string(from: line.time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasAudio {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(playing ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(playing ? "停止回听" : "回听")
                }
            }
        }
        .buttonStyle(.plain)
    }
}
