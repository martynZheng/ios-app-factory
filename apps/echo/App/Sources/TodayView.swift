import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var transcriber: Transcriber
    @AppStorage("digestEngine") private var engine = "rules"
    @State private var day = Store.dayKey(Date())
    @State private var working = false
    @State private var errorText: String?
    @State private var source: DigestItem?

    var body: some View {
        let lines = store.lines(on: day)
        let digest = store.db.digests[day]
        List {
            Section { dayPicker }
            if lines.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("这一天还没有记录", systemImage: "waveform")
                    } description: {
                        Text(emptyHint)
                    }
                }
            } else {
                Section {
                    Text(digest?.stats ?? DigestEngine.stats(lines: lines, segments: store.segments(on: day)))
                        .font(.subheadline).foregroundStyle(.secondary)
                    generateButton(digest: digest, lines: lines)
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    if let digest {
                        Text("由「\(DigestEngine.engineName(digest.engine))」生成。每条都可点开查看原始转写；没有来源的内容不会出现在这里。")
                    }
                }
                if let digest {
                    itemSection("要点", .point, digest)
                    itemSection("重要决定", .decision, digest)
                    itemSection("待办", .todo, digest)
                    itemSection("待确认", .pending, digest)
                    if digest.items.isEmpty {
                        Section { Text("没有识别出决定或待办。可以到「时间线」查看完整转写。").foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .sheet(item: $source) { SourceSheet(item: $0) }
        .onAppear { autoRules() }
        .onChange(of: day) { _, _ in errorText = nil; autoRules() }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptChanged)) { _ in autoRules() }
    }

    private var emptyHint: String {
        let pending = store.segments(on: day).filter { $0.status == .pending }.count
        if pending > 0 { return "有 \(pending) 段录音正在转写，稍后会出现在这里。" }
        return "在 Apple Watch 上打开拾言，点「开始录音」。录音会自动同步到这里并转写。"
    }

    private var dayPicker: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("前一天")
            Spacer()
            Text(day == Store.dayKey(Date()) ? "今天" : day).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= Store.dayKey(Date()))
                .accessibilityLabel("后一天")
        }
        .buttonStyle(.borderless)
    }

    private func shift(_ delta: Int) {
        let date = Calendar.current.date(byAdding: .day, value: delta, to: Store.date(fromDayKey: day)) ?? Date()
        day = Store.dayKey(date)
    }

    private func generateButton(digest: Digest?, lines: [Line]) -> some View {
        Button {
            generate(lines: lines)
        } label: {
            HStack {
                if working { ProgressView().padding(.trailing, 4) }
                Text(digest == nil ? "生成回顾" : "重新生成（\(DigestEngine.engineName(engine))）")
            }
        }
        .disabled(working)
    }

    @ViewBuilder
    private func itemSection(_ title: String, _ kind: ItemKind, _ digest: Digest) -> some View {
        let items = digest.items.filter { $0.kind == kind }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { source = item } label: { ItemRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// 规则引擎零成本，转写更新后自动刷新；模型引擎只在用户点按时运行。
    private func autoRules() {
        let lines = store.lines(on: day)
        guard !lines.isEmpty else { return }
        let digest = store.db.digests[day]
        if digest == nil || (digest?.engine == "rules" && digest?.lineCount != lines.count) {
            store.setDigest(DigestEngine.rules(day: day, lines: lines, segments: store.segments(on: day)))
            Notifier.apply()
        }
    }

    private func generate(lines: [Line]) {
        errorText = nil
        let segments = store.segments(on: day)
        let targetDay = day
        if engine == "rules" {
            store.setDigest(DigestEngine.rules(day: targetDay, lines: lines, segments: segments))
            Notifier.apply()
            return
        }
        working = true
        let chosen = engine
        Task {
            do {
                let digest = try await DigestEngine.llm(day: targetDay, lines: lines, segments: segments, engine: chosen)
                await MainActor.run {
                    store.setDigest(digest)
                    Notifier.apply()
                    working = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    working = false
                }
            }
        }
    }
}

/// 回顾/待办条目：正文 + 负责人、截止、待确认标签。
struct ItemRow: View {
    let item: DigestItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.body)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.kind == .todo || item.kind == .pending {
                HStack(spacing: 6) {
                    if item.kind == .pending { Chip(text: "待确认", warn: true) }
                    if item.kind == .todo {
                        Chip(text: item.owner.map { "负责人 \($0)" } ?? "负责人待确认", warn: item.owner == nil)
                        if let due = item.due {
                            Chip(text: item.dueDate == nil ? "截止「\(due)」待确认" : "截止 \(due)", warn: item.dueDate == nil)
                        } else {
                            Chip(text: "截止时间待确认", warn: true)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct Chip: View {
    let text: String
    let warn: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(warn ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12)))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
    }
}
