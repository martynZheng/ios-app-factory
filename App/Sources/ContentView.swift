import SwiftUI

/// 占位首页：第一次跑通流水线用。之后让 Claude 按你的需求整个替换掉。
struct ContentView: View {
    @State private var taps = 0

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("流水线已跑通")
                    .font(.title.bold())
                Text("在手机上的 Claude Code 里说出需求，\n这里就会变成你要的 App。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("点我 · \(taps)") { taps += 1 }
                    .buttonStyle(.borderedProminent)
                Text("版本 \(version)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle("AI 工厂")
        }
    }
}

#Preview {
    ContentView()
}
