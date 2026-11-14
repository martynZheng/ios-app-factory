import SwiftUI
import Charts

// MARK: - 助理画的图

/// 一条数据线。axis 为 right 的画在右轴上（量纲不同的两组数叠在一张图里）。
struct ChartSeries: Codable, Hashable {
    var name: String
    /// line / area / bar
    var kind: String
    var right: Bool
    /// 和横轴标签一一对应；缺的点是 nil
    var values: [Double?]
}

struct ChartSpec: Codable, Hashable {
    var title: String
    var labels: [String]
    var series: [ChartSeries]
    var leftUnit: String?
    var rightUnit: String?
    var note: String?

    /// 从工具参数解析。返回 nil 和原因。
    static func parse(_ args: [String: Any]) -> (ChartSpec?, String) {
        let labels = (args["x"] as? [Any] ?? []).map { "\($0)" }
        guard labels.count >= 2 else { return (nil, "x 至少要有 2 个横轴标签。") }
        guard labels.count <= 400 else { return (nil, "点太多了，横轴最多 400 个点，先按周或按月取样。") }
        var list: [ChartSeries] = []
        for raw in (args["series"] as? [[String: Any]] ?? []).prefix(4) {
            let numbers = (raw["values"] as? [Any] ?? []).map { item -> Double? in
                if let n = item as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
                if let s = item as? String { return Double(s) }
                return nil
            }
            guard numbers.count == labels.count else {
                return (nil, "「\(raw["name"] as? String ?? "?")」有 \(numbers.count) 个值，但横轴有 \(labels.count) 个标签，两者必须一样多（缺的填 null）。")
            }
            guard numbers.compactMap({ $0 }).count >= 2 else { continue }
            let kind = (raw["type"] as? String ?? "line").lowercased()
            list.append(ChartSeries(name: raw["name"] as? String ?? "数据", kind: ["line", "area", "bar"].contains(kind) ? kind : "line",
                                    right: (raw["axis"] as? String ?? "left").lowercased() == "right", values: numbers))
        }
        guard !list.isEmpty else { return (nil, "series 里没有可画的数据。") }
        // 全都标了右轴等于没有左轴：都放回左边
        if list.allSatisfy({ $0.right }) { list = list.map { var s = $0; s.right = false; return s } }
        func clean(_ key: String) -> String? {
            let s = (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        let spec = ChartSpec(title: clean("title") ?? "图表", labels: labels, series: list,
                             leftUnit: clean("left_unit"), rightUnit: clean("right_unit"), note: clean("note"))
        return (spec, "")
    }
}

/// 对话气泡里的一张图。右轴的数据换算到左轴的范围里画，右边的刻度再换算回去。
struct ChartCard: View {
    let spec: ChartSpec

    private struct Point: Identifiable {
        let id: Int
        let series: Int
        let x: Int
        let y: Double
    }

    private static let palette: [Color] = [
        Color(red: 0.18, green: 0.44, blue: 0.84), Color(red: 0.86, green: 0.42, blue: 0.18),
        Color(red: 0.16, green: 0.62, blue: 0.48), Color(red: 0.62, green: 0.36, blue: 0.80),
    ]

    private func color(_ index: Int) -> Color { Self.palette[index % Self.palette.count] }

    /// 一组数的坐标范围：上下各留一点空；柱状和面积从 0 起。
    private func range(right: Bool) -> (Double, Double)? {
        let chosen = spec.series.filter { $0.right == right }
        let all = chosen.flatMap { $0.values.compactMap { $0 } }
        guard var low = all.min(), var high = all.max() else { return nil }
        if chosen.contains(where: { $0.kind != "line" }) && low > 0 { low = 0 }
        if high - low < 1e-9 {
            high += 1
            low -= 1
        }
        let pad = (high - low) * 0.08
        return (low == 0 ? 0 : low - pad, high + pad)
    }

    private var left: (Double, Double) { range(right: false) ?? (0, 1) }
    private var rightRange: (Double, Double)? { range(right: true) }

    /// 把一个值换到左轴的坐标里。
    private func plotted(_ value: Double, right: Bool) -> Double {
        guard right, let r = rightRange else { return value }
        let l = left
        return l.0 + (value - r.0) / (r.1 - r.0) * (l.1 - l.0)
    }

    private var points: [Point] {
        var out: [Point] = []
        for (s, series) in spec.series.enumerated() {
            for (x, value) in series.values.enumerated() {
                if let value { out.append(Point(id: out.count, series: s, x: x, y: plotted(value, right: series.right))) }
            }
        }
        return out
    }

    private var xTicks: [Int] {
        let n = spec.labels.count
        let want = 4
        if n <= want { return Array(0..<n) }
        return (0..<want).map { Int((Double($0) * Double(n - 1) / Double(want - 1)).rounded()) }
    }

    private var yTicks: [Double] {
        let l = left
        return (0...4).map { l.0 + (l.1 - l.0) * Double($0) / 4 }
    }

    static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 100_000_000 { return String(format: "%.1f亿", v / 100_000_000) }
        if a >= 10_000 { return String(format: "%.1f万", v / 10_000) }
        if a >= 100 { return String(format: "%.0f", v) }
        if a >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.ink)
            legend
            chart
                .frame(height: 210)
            if let note = spec.note {
                Text(note).font(.caption).foregroundStyle(Ink.ink3).lineSpacing(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Chat.field))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("图表：\(spec.title)")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(color(index)).frame(width: 12, height: 4)
                    Text(legendText(series))
                        .font(.caption)
                        .foregroundStyle(Ink.ink2)
                        .lineLimit(1)
                }
            }
        }
    }

    private func legendText(_ series: ChartSeries) -> String {
        let unit = series.right ? spec.rightUnit : spec.leftUnit
        var text = series.name
        if let unit { text += "（\(unit)）" }
        if rightRange != nil { text += series.right ? " · 右轴" : " · 左轴" }
        return text
    }

    private var chart: some View {
        let l = left
        let all = points
        return Chart {
            ForEach(all) { p in
                mark(p, base: l.0)
            }
        }
        .chartYScale(domain: l.0...l.1)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine().foregroundStyle(Ink.rule)
                AxisValueLabel {
                    if let i = value.as(Int.self), spec.labels.indices.contains(i) {
                        Text(spec.labels[i]).font(.caption2).foregroundStyle(Ink.ink3)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine().foregroundStyle(Ink.rule)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.short(v)).font(.caption2).foregroundStyle(Ink.ink3)
                    }
                }
            }
            AxisMarks(position: .trailing, values: yTicks) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), let r = rightRange {
                        Text(Self.short(r.0 + (v - l.0) / (l.1 - l.0) * (r.1 - r.0))).font(.caption2).foregroundStyle(Ink.ink3)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func mark(_ p: Point, base: Double) -> some ChartContent {
        let series = spec.series[p.series]
        let tint = color(p.series)
        if series.kind == "bar" {
            BarMark(x: .value("x", p.x), yStart: .value("y0", base), yEnd: .value("y", p.y))
                .foregroundStyle(tint.opacity(0.75))
        } else {
            if series.kind == "area" {
                AreaMark(x: .value("x", p.x), yStart: .value("y0", base), yEnd: .value("y", p.y))
                    .foregroundStyle(tint.opacity(0.18))
            }
            LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("s", series.name))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
