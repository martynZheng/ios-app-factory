import SwiftUI

/// 鱼骨图：一天是一条鱼，脊柱是时间，每一章是一根骨头，随着记录一节一节长出来。
/// 竖屏：脊柱向下，骨头左右交替；宽屏（iPhone Duo 内屏）：脊柱向右，骨头上下交替。
struct FishboneView: View {
    let headline: String
    let chapters: [Chapter]
    let items: [DigestItem]
    let live: Bool
    let wide: Bool
    let onTap: (Chapter) -> Void

    private func points(_ chapter: Chapter) -> [DigestItem] {
        items.filter { $0.kind == .point && $0.chapterID == chapter.id }
    }

    var body: some View {
        Group {
            if wide { horizontal } else { vertical }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.82), value: chapters)
    }

    private var vertical: some View {
        VStack(spacing: 0) {
            FishHead(text: headline)
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                BoneRow(chapter: chapter, points: points(chapter), left: index % 2 == 0, index: index)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(chapter) }
            }
            FishTail(live: live)
        }
    }

    private var horizontal: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    FishHead(text: headline).frame(width: 220)
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        BoneColumn(chapter: chapter, points: points(chapter), top: index % 2 == 0, index: index)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(chapter) }
                    }
                    FishTail(live: live).frame(width: 120).id("tail")
                }
                .padding(.vertical, 4)
            }
            .onChange(of: chapters.count) { _, _ in
                withAnimation(.easeOut(duration: 0.5)) { proxy.scrollTo("tail", anchor: .trailing) }
            }
        }
    }
}

// MARK: 骨头里的卡片

private struct BoneCard: View {
    let chapter: Chapter
    let points: [DigestItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chapter.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let speaker = chapter.speaker {
                Text(speaker).font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            if !chapter.summary.isEmpty {
                Text(chapter.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(points.prefix(2)) { point in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle().fill(Color.accentColor.opacity(0.7)).frame(width: 4, height: 4).offset(y: -2)
                    Text(point.text).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if points.count > 2 {
                Text("还有 \(points.count - 2) 条要点").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看这一章的详情")
    }
}

private func span(_ chapter: Chapter) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let a = f.string(from: chapter.start)
    let b = f.string(from: chapter.end)
    return a == b ? a : "\(a)–\(b)"
}

private let spineColor = Color.accentColor.opacity(0.35)

// MARK: 竖向一节

private struct BoneRow: View {
    let chapter: Chapter
    let points: [DigestItem]
    let left: Bool
    let index: Int
    @State private var shown = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(card: left, alignment: .trailing)
            ZStack(alignment: .top) {
                Rectangle().fill(spineColor).frame(width: 3)
                    .scaleEffect(x: 1, y: shown ? 1 : 0, anchor: .top)
                Rib(towardStart: left)
                    .trim(from: 0, to: shown ? 1 : 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(height: 46)
                Circle().fill(Color.accentColor).frame(width: 11, height: 11)
                    .padding(.top, 10)
                    .scaleEffect(shown ? 1 : 0.1)
            }
            .frame(width: 40)
            side(card: !left, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(min(index, 10)) * 0.07)) { shown = true }
        }
    }

    @ViewBuilder
    private func side(card: Bool, alignment: Alignment) -> some View {
        if card {
            BoneCard(chapter: chapter, points: points)
                .padding(.top, 30)
                .padding(.bottom, 8)
                .opacity(shown ? 1 : 0)
                .offset(x: shown ? 0 : (left ? 26 : -26))
        } else {
            Text(span(chapter))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
                .opacity(shown ? 1 : 0)
        }
    }
}

/// 斜着的肋骨：从脊柱上的节点斜向卡片。
private struct Rib: Shape {
    let towardStart: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: 15))
        p.addLine(to: CGPoint(x: towardStart ? rect.minX + 2 : rect.maxX - 2, y: rect.maxY - 4))
        return p
    }
}

// MARK: 横向一节

private struct BoneColumn: View {
    let chapter: Chapter
    let points: [DigestItem]
    let top: Bool
    let index: Int
    @State private var shown = false
    private let slot: CGFloat = 210

    var body: some View {
        VStack(spacing: 0) {
            slotView(card: top, alignment: .bottom)
            ZStack(alignment: .leading) {
                Rectangle().fill(spineColor).frame(height: 3)
                    .scaleEffect(x: shown ? 1 : 0, y: 1, anchor: .leading)
                RibH(up: top)
                    .trim(from: 0, to: shown ? 1 : 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle().fill(Color.accentColor).frame(width: 11, height: 11)
                    .padding(.leading, 12)
                    .scaleEffect(shown ? 1 : 0.1)
            }
            .frame(height: 40)
            slotView(card: !top, alignment: .top)
        }
        .frame(width: 250)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(min(index, 10)) * 0.07)) { shown = true }
        }
    }

    @ViewBuilder
    private func slotView(card: Bool, alignment: Alignment) -> some View {
        Group {
            if card {
                BoneCard(chapter: chapter, points: points)
                    .padding(.leading, 36)
                    .padding(.trailing, 6)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : (top ? 22 : -22))
            } else {
                Text(span(chapter))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(shown ? 1 : 0)
            }
        }
        .frame(height: slot, alignment: alignment)
    }
}

private struct RibH: Shape {
    let up: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 17, y: rect.midY))
        p.addLine(to: CGPoint(x: 44, y: up ? rect.minY + 2 : rect.maxY - 2))
        return p
    }
}

// MARK: 头和尾

private struct FishHead: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "fish.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text(text.isEmpty ? "今天" : text)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }
}

private struct FishTail: View {
    let live: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if live {
                    Circle().stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.25 : 0.7)
                        .opacity(pulse ? 0 : 1)
                }
                Circle().fill(live ? Color.accentColor : spineColor).frame(width: 12, height: 12)
            }
            .frame(width: 30, height: 30)
            Text(live ? "还在长…" : "到这里")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: 章节详情

struct ChapterSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let chapter: Chapter
    let day: String

    var body: some View {
        let items = (store.db.digests[day]?.items ?? []).filter { $0.chapterID == chapter.id }
        let points = items.filter { $0.kind == .point }
        let others = items.filter { $0.kind != .point }
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(span(chapter) + (chapter.speaker.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if !chapter.summary.isEmpty { Text(chapter.summary) }
                    }
                }
                if !points.isEmpty {
                    Section("要点") {
                        ForEach(points) { point in
                            NavigationLink { SourceDetail(item: point) } label: { Text(point.text) }
                        }
                    }
                }
                if !others.isEmpty {
                    Section("这一章里的决定 / 待办 / 待确认") {
                        ForEach(others) { item in
                            NavigationLink { SourceDetail(item: item) } label: { ItemRow(item: item) }
                        }
                    }
                }
                Section("原始转写") {
                    let lines = chapter.sourceLineIDs.compactMap { store.line($0) }.sorted { $0.time < $1.time }
                    if lines.isEmpty { Text("来源转写已被删除").foregroundStyle(.secondary) }
                    ForEach(lines) { LineRow(line: $0) }
                }
            }
            .navigationTitle(chapter.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// 一条整理结果所依据的原句。
struct SourceDetail: View {
    @EnvironmentObject private var store: Store
    let item: DigestItem

    var body: some View {
        List {
            Section("整理结果") { Text(item.text) }
            Section("原始转写") {
                let lines = item.sourceLineIDs.compactMap { store.line($0) }
                if lines.isEmpty { Text("来源转写已被删除").foregroundStyle(.secondary) }
                ForEach(lines) { LineRow(line: $0) }
            }
        }
        .navigationTitle("来源")
        .navigationBarTitleDisplayMode(.inline)
    }
}
