import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var coordinator: DigestCoordinator
    @State private var day = Store.dayKey(Date())
    @State private var source: DigestItem?
    @State private var confirmFull = false

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
                    status
                    Button("整天重新整理") { confirmFull = true }
                        .disabled(coordinator.working)
                } footer: {
                    if let digest {
                        Text("由「\(DigestEngine.engineName(digest.engine))」随录随整理。每条都可点开查看原始转写；没有来源的内容不会出现在这里。")
                    }
                }
                if let digest {
                    itemSection("要点", .point, digest)
                    itemSection("重要决定", .decision, digest)
                    itemSection("待办", .todo, digest)
                    itemSection("待确认", .pending, digest)
                    if digest.items.isEmpty {
                        Section { Text("还没有识别出决定或待办。可以到「时间线」查看完整转写。").foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .sheet(item: $source) { SourceSheet(item: $0) }
        .onAppear { coordinator.update(day: day) }
        .onChange(of: day) { _, newDay in coordinator.update(day: newDay) }
        .confirmationDialog("整天重新整理会结合全天上下文重做一遍，已勾选的待办状态会被清除。", isPresented: $confirmFull, titleVisibility: .visible) {
            Button("重新整理") { coordinator.update(day: day, full: true) }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var status: some View {
        let waiting = coordinator.unprocessedCount(day: day)
        if coordinator.working {
            HStack {
                ProgressView().padding(.trailing, 4)
                Text("正在整理新内容…").foregroundStyle(.secondary)
            }
        } else if let error = coordinator.lastError, waiting > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(waiting) 句待整理").font(.subheadline)
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("重试") { coordinator.update(day: day) }
            }
        }
    }

    private var emptyHint: String {
        let pending = store.segments(on: day).filter { $0.status == .pending }.count
        if pending > 0 { return "有 \(pending) 段录音正在转写，稍后会出现在这里。" }
        return "在 Apple Watch 上打开拾言，点「开始录音」。录音会边录边同步到这里。"
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
