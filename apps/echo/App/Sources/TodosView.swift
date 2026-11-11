import SwiftUI

struct TodoRef: Identifiable {
    let day: String
    let item: DigestItem
    var id: UUID { item.id }
}

struct TodosView: View {
    @EnvironmentObject private var store: Store
    @State private var source: DigestItem?
    @State private var exporting: TodoRef?
    @State private var message: String?

    private var todos: [TodoRef] {
        store.db.digests.keys.sorted(by: >).flatMap { day in
            (store.db.digests[day]?.items ?? []).filter { $0.kind == .todo }.map { TodoRef(day: day, item: $0) }
        }
    }

    var body: some View {
        let open = todos.filter { !$0.item.done }
        let done = todos.filter { $0.item.done }
        List {
            if todos.isEmpty {
                ContentUnavailableView {
                    Label("没有待办", systemImage: "checklist")
                } description: {
                    Text("从对话里识别出的待办会出现在这里。写入提醒事项或日历前都会先问你。")
                }
            }
            if !open.isEmpty {
                Section("未完成") { ForEach(open) { row($0) } }
            }
            if !done.isEmpty {
                Section("已完成") { ForEach(done) { row($0) } }
            }
        }
        .sheet(item: $source) { SourceSheet(item: $0) }
        .confirmationDialog("写入到系统", isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                            titleVisibility: .visible, presenting: exporting) { ref in
            Button("写入「提醒事项」") { export(ref, calendar: false) }
            if ref.item.dueDate != nil {
                Button("写入日历（全天）") { export(ref, calendar: true) }
            }
            Button("取消", role: .cancel) {}
        } message: { ref in
            Text("「\(ref.item.text)」" + (ref.item.dueDate == nil ? "\n截止时间未确定，将不带日期写入。" : ""))
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        }
    }

    private func row(_ ref: TodoRef) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.updateItem(day: ref.day, id: ref.item.id) { $0.done.toggle() }
            } label: {
                Image(systemName: ref.item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(ref.item.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(ref.item.done ? "标为未完成" : "标为完成")

            Button { source = ref.item } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ItemRow(item: ref.item)
                    Text(ref.day + (ref.item.exported ? " · 已写入系统" : ""))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing) {
            Button { exporting = ref } label: { Label("写入系统", systemImage: "square.and.arrow.up") }
                .tint(.blue)
        }
    }

    private func export(_ ref: TodoRef, calendar: Bool) {
        let quote = ref.item.sourceLineIDs.compactMap { store.line($0)?.text }.joined(separator: " ")
        Task {
            let result = calendar ? await Exporter.addEvent(ref.item, source: quote) : await Exporter.addReminder(ref.item, source: quote)
            await MainActor.run {
                if result.hasPrefix("已写入") { store.updateItem(day: ref.day, id: ref.item.id) { $0.exported = true } }
                message = result
            }
        }
    }
}
