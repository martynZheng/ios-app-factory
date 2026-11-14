import SwiftUI

/// 它的记忆：顶层、维基、笔记、原始记录、整理日志。可以看、删，可以让它现在就整理一次，或撤销上一次整理。
struct MemoryView: View {
    @ObservedObject private var memory = MemoryFS.shared
    @ObservedObject private var dreaming = Dreaming.shared
    @AppStorage("dreamEnabled") private var dreamEnabled = true
    @State private var layer = "wiki"
    @State private var confirmUndo = false

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    var body: some View {
        List {
            topSection
            dreamSection
            Section {
                Picker("层", selection: $layer) {
                    Text("维基").tag("wiki")
                    Text("笔记").tag("notes")
                    Text("原始记录").tag("raw")
                    Text("整理日志").tag("dreams")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                fileRows
            } footer: {
                Text(layerFooter)
            }
        }
        .navigationTitle("它的记忆")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { memory.syncRaw(recentDays: 1) }
        .confirmationDialog("撤销上一次整理？笔记、维基和顶层会回到整理之前的样子。", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("撤销", role: .destructive) { dreaming.undo() }
            Button("取消", role: .cancel) {}
        }
    }

    private var topSection: some View {
        Section {
            NavigationLink {
                MemoryFileView(path: MemoryFS.indexName, title: "顶层记忆")
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("顶层记忆").font(.body.weight(.semibold))
                    Text(memory.index.isEmpty ? "还是空的" : String(memory.index.prefix(160)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text("每次对话都会整页带上它；更多的内容按需去维基、笔记、原始记录里找。")
        }
    }

    private var dreamSection: some View {
        Section {
            Toggle("每天整理一次（做梦）", isOn: $dreamEnabled)
            if dreaming.running {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(dreaming.status ?? "在整理…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Button("现在整理") { Task { await dreaming.dream() } }
                    .disabled(!Cloud.ready)
            }
            if let error = dreaming.lastError {
                Text(error).font(.footnote).foregroundStyle(Ink.vermilion)
            }
            if dreaming.canUndo && !dreaming.running {
                Button("撤销上一次整理", role: .destructive) { confirmUndo = true }
            }
        } header: {
            Text("整理")
        } footer: {
            Text(dreamFooter)
        }
    }

    private var dreamFooter: String {
        var text = "像睡觉时整理白天的事：读还没消化的原始记录和零散笔记，用原始记录核对笔记，并进维基，删掉过时的，再重写顶层。原始记录只读；每次整理前都会备份，可以撤销。"
        if let last = Dreaming.lastDream { text = "上次整理：\(Self.when.string(from: last))。待整理 \(dreaming.pendingDays().count) 天。\n" + text }
        return text
    }

    private var layerFooter: String {
        switch layer {
        case "wiki": return "按主题整理好的长期记忆（人、项目、偏好、习惯……）。左滑可以删掉。"
        case "notes": return "聊天时它随手记下的，还没核对整理。左滑可以删掉。"
        case "raw": return "每天的录音转写、整理出的章节和对话原文，是核对记忆的依据。"
        default: return "每次整理改了什么。"
        }
    }

    @ViewBuilder
    private var fileRows: some View {
        let files = memory.list(layer)
        if files.isEmpty {
            Text(layer == "wiki" ? "还没有。整理一次之后会出现。" : "还没有。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(files) { file in
            NavigationLink {
                MemoryFileView(path: file.path, title: title(file))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(file)).font(.body)
                    if !file.description.isEmpty {
                        Text(file.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("\(Self.when.string(from: file.updated)) · \(file.size) 字").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .swipeActions {
                if MemoryFS.canWrite(file.path) {
                    Button("删除", role: .destructive) { memory.delete(file.path) }
                }
            }
        }
    }

    private func title(_ file: MemoryFile) -> String {
        let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }
}

/// 打开一个记忆文件看全文。
struct MemoryFileView: View {
    let path: String
    let title: String
    @ObservedObject private var memory = MemoryFS.shared

    var body: some View {
        let parsed = MemoryFS.parse(memory.read(path) ?? "")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(path).font(.caption).foregroundStyle(.secondary)
                if !parsed.description.isEmpty {
                    Text(parsed.description).font(.subheadline).foregroundStyle(Ink.ink2)
                }
                RichText(text: parsed.body.isEmpty ? "（空）" : parsed.body)
                    .textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Chat.page.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
