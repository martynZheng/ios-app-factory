import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var transcriber: Transcriber
    @State private var query = ""
    @State private var editing: Line?
    @State private var draft = ""

    private var days: [(String, [Line])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let lines = q.isEmpty ? store.db.lines : store.db.lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
        let grouped = Dictionary(grouping: lines) { Store.dayKey($0.time) }
        return grouped.keys.sorted(by: >).map { ($0, (grouped[$0] ?? []).sorted { $0.time < $1.time }) }
    }

    var body: some View {
        let waiting = store.db.segments.filter { $0.status == .pending || $0.status == .failed || $0.status == .blocked }
        List {
            if transcriber.authDenied {
                Section {
                    Label("没有语音识别权限，录音无法转写。请到系统设置里为拾言开启「语音识别」。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }
            if !waiting.isEmpty { processing(waiting) }
            if days.isEmpty && waiting.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "还没有对话记录" : "没有找到相关内容", systemImage: query.isEmpty ? "text.alignleft" : "magnifyingglass")
                } description: {
                    Text(query.isEmpty ? "手表上的录音同步并转写后，会按时间排列在这里。" : "换个关键词试试。")
                }
            }
            ForEach(days, id: \.0) { day, lines in
                Section(day) {
                    ForEach(lines) { line in
                        LineRow(line: line)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.deleteLine(line.id) } label: { Label("删除", systemImage: "trash") }
                                Button { draft = line.text; editing = line } label: { Label("修改", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                            .contextMenu {
                                Button { draft = line.text; editing = line } label: { Label("修改文字", systemImage: "pencil") }
                                Button(role: .destructive) { store.deleteLine(line.id) } label: { Label("删除这一句", systemImage: "trash") }
                                Button(role: .destructive) {
                                    if let seg = store.segment(line.segmentID) { store.deleteSession(seg.sessionID, tombstone: false) }
                                } label: { Label("删除整次录音", systemImage: "trash.slash") }
                            }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索对话内容")
        .sheet(item: $editing) { line in editor(line) }
    }

    private func processing(_ segments: [Segment]) -> some View {
        let pending = segments.filter { $0.status == .pending }.count
        let problems = segments.filter { $0.status != .pending }
        return Section("处理中") {
            if pending > 0 {
                HStack {
                    if transcriber.busy { ProgressView().padding(.trailing, 4) }
                    Text("\(pending) 段录音等待转写")
                }
            }
            if let first = problems.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(problems.count) 段未能转写").font(.subheadline)
                    Text(first.error ?? "").font(.footnote).foregroundStyle(.secondary)
                }
                Button("重试") { transcriber.retryAll() }
                Button("删除这些录音", role: .destructive) { store.deleteSegments(problems.map { $0.id }) }
            }
        }
    }

    private func editor(_ line: Line) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft).frame(minHeight: 140)
                } footer: {
                    Text("修改只影响文字，原始录音不变。")
                }
            }
            .navigationTitle("修改转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.editLine(line.id, text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        editing = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
