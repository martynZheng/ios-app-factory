import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var coordinator: DigestCoordinator
    @State private var day = Store.dayKey(Date())
    @State private var source: DigestItem?
    @State private var confirmFull = false
    @State private var confirmRetranscribe = false
    @EnvironmentObject private var transcriber: Transcriber

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
                    Text(segmentSummary).font(.footnote).foregroundStyle(.secondary)
                    status
                    Button("整天重新整理") { confirmFull = true }
                        .disabled(coordinator.working)
                    Button("重新转写这一天") { confirmRetranscribe = true }
                        .disabled(transcriber.busy)
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
        .confirmationDialog("用当前的识别引擎把这一天留着的录音重新转写一遍，原来的文字和回顾会被替换。", isPresented: $confirmRetranscribe, titleVisibility: .visible) {
            Button("重新转写") { transcriber.retranscribe(day: day) }
            Button("取消", role: .cancel) {}
        }
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
        } else if transcriber.busy {
            HStack {
                ProgressView().padding(.trailing, 4)
                Text("正在转写…").foregroundStyle(.secondary)
            }
        } else if coordinator.lastError == nil, waiting > 0 {
            HStack {
                Text("\(waiting) 句新内容，攒够一段后自动整理").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("现在整理") { coordinator.update(day: day, force: true) }.buttonStyle(.borderless)
            }
        } else if let error = coordinator.lastError, waiting > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(waiting) 句待整理").font(.subheadline)
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("重试") { coordinator.update(day: day, force: true) }
            }
        }
    }

    /// 这一天各分段的转写情况，方便判断问题出在录音、同步还是识别。
    private var segmentSummary: String {
        let segs = store.segments(on: day)
        let done = segs.filter { $0.status == .done }.count
        let silent = segs.filter { $0.status == .noSpeech }.count
        let failed = segs.filter { $0.status == .failed || $0.status == .blocked }.count
        let pending = segs.filter { $0.status == .pending }.count
        var parts = ["\(segs.count) 段录音：\(done) 段有文字"]
        if silent > 0 { parts.append("\(silent) 段没识别出语音") }
        if failed > 0 { parts.append("\(failed) 段失败") }
        if pending > 0 { parts.append("\(pending) 段待转写") }
        var text = parts.joined(separator: "，")
        text += Transcriber.modernAvailable ? "。识别引擎：新版端侧" : "。识别引擎：旧版端侧"
        if let note = segs.compactMap({ $0.error }).first { text += "\n" + note }
        return text
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
            if item.kind == .todo, item.owner != nil || item.due != nil {
                HStack(spacing: 6) {
                    if let owner = item.owner { Chip(text: owner, warn: false) }
                    if let due = item.due {
                        Chip(text: item.dueDate == nil ? "\(due)（日期待确认）" : due, warn: item.dueDate == nil)
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
