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

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    var body: some View {
        let open = todos.filter { !$0.item.done }
        let done = todos.filter { $0.item.done }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if todos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("没有要跟进的事").font(Ink.serif(21, relativeTo: .title3)).foregroundStyle(Ink.ink)
                        Text("对话里明确交给你或别人去做的事会出现在这里。写进「提醒事项」或日历前都会先问你。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                }
                if !open.isEmpty {
                    Text("\(open.count) 件未完成")
                        .font(Ink.serif(17, relativeTo: .headline))
                        .foregroundStyle(Ink.ink2)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .contentTransition(.numericText())
                    ForEach(open) { ref in
                        row(ref)
                        if ref.id != open.last?.id { divider }
                    }
                }
                if !done.isEmpty {
                    Text("已完成")
                        .font(Ink.serif(17, relativeTo: .headline))
                        .foregroundStyle(Ink.ink3)
                        .padding(.top, 30)
                        .padding(.bottom, 2)
                    ForEach(done) { ref in
                        row(ref)
                        if ref.id != done.last?.id { divider }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: done.count)
        }
        .background(Ink.paper.ignoresSafeArea())
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

    private var divider: some View {
        InkRule(seed: 2).stroke(Ink.rule, lineWidth: 0.8).frame(height: 2).padding(.leading, 40)
    }

    private func meta(_ ref: TodoRef) -> String {
        var parts: [String] = []
        if let owner = ref.item.owner { parts.append(owner) }
        if let due = ref.item.due { parts.append(ref.item.dueDate == nil ? "\(due)（日期待确认）" : "\(due)前") }
        let digest = store.db.digests[ref.day]
        if let id = ref.item.chapterID, let chapter = digest?.chapters?.first(where: { $0.id == id }) {
            parts.append("出自「\(chapter.title)」")
        } else {
            parts.append(Self.dayTitle.string(from: Store.date(fromDayKey: ref.day)))
        }
        if ref.item.exported { parts.append("已写入系统") }
        return parts.joined(separator: "，")
    }

    private func row(_ ref: TodoRef) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.snappy) { store.updateItem(day: ref.day, id: ref.item.id) { $0.done.toggle() } }
            } label: {
                InkCheckbox(done: ref.item.done, size: 21, seed: CGFloat(ref.item.text.count))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: ref.item.done) { _, now in now }
            .accessibilityLabel(ref.item.done ? "标为未完成" : "标为完成")

            Button { source = ref.item } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ref.item.text)
                        .font(.body)
                        .strikethrough(ref.item.done, color: Ink.ink3)
                        .foregroundStyle(ref.item.done ? Ink.ink3 : Ink.ink)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                    Text(meta(ref)).font(.footnote).foregroundStyle(Ink.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button { exporting = ref } label: { Label("写入提醒事项或日历", systemImage: "calendar.badge.plus") }
                Button { source = ref.item } label: { Label("查看原话", systemImage: "text.quote") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Ink.ink3)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.vertical, 13)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
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
