import SwiftUI
import CodingBarCore

// MARK: - Spend sparkline (prototype: polyline + 10% area fill + last dot)

struct DCSparkline: View {
    @Environment(\.dc) private var dc
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let mx = max(values.max() ?? 1, 1e-9)
            let n = max(values.count - 1, 1)
            let pad: CGFloat = 3
            let pts: [CGPoint] = values.enumerated().map { i, c in
                CGPoint(x: pad + CGFloat(i) * ((w - 2 * pad) / CGFloat(n)),
                        y: h - pad - CGFloat(c / mx) * (h - 2 * pad - 4))
            }
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: pad, y: h))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: w - pad, y: h))
                    p.closeSubpath()
                }
                .fill(dc.fixedBlue.opacity(0.10))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(dc.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(dc.accent).frame(width: 5.2, height: 5.2).position(last)
                }
            }
        }
        .frame(height: 36)
    }
}

// MARK: - Code-output add/remove ratio bar (height 5)

struct DCRatioBar: View {
    @Environment(\.dc) private var dc
    let added: Int
    let removed: Int
    var body: some View {
        let total = max(1, added + removed)
        let addF = Double(added) / Double(total)
        return GeometryReader { g in
            HStack(spacing: 0) {
                Rectangle().fill(dc.good).frame(width: g.size.width * addF)
                Rectangle().fill(dc.bad)
            }
        }
        .frame(height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .background(RoundedRectangle(cornerRadius: 3).fill(dc.track))
    }
}

// MARK: - Tool-mix stacked bar (8px) + wrapping legend

struct DCToolMix: View {
    @Environment(\.dc) private var dc
    @Environment(\.lang) private var lang
    let mix: ToolMix
    private var defs: [(String, Int, Color)] {
        [(lang.t("Write", "写"), mix.write, Color(hex: "#5b8def")), (lang.t("Read", "读"), mix.read, Color(hex: "#57b894")),
         (lang.t("Run", "执行"), mix.run, Color(hex: "#e0a04d")), (lang.t("Search", "搜索"), mix.search, Color(hex: "#b07cc6")),
         (lang.t("Other", "其他"), mix.other, Color(hex: "#8a9099"))].filter { $0.1 > 0 }
    }
    private var total: Double { Double(max(1, defs.map { $0.1 }.reduce(0, +))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(Array(defs.enumerated()), id: \.offset) { _, d in
                        Rectangle().fill(d.2).frame(width: g.size.width * Double(d.1) / total)
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            DCFlow(spacing: 10, lineSpacing: 8) {
                ForEach(Array(defs.enumerated()), id: \.offset) { _, d in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(d.2).frame(width: 6, height: 6)
                        Text("\(d.0) \(d.1)").font(.system(size: 9.5)).foregroundStyle(dc.fg2)
                    }
                }
            }
        }
    }
}

// MARK: - Activity heatmap — GitHub-style green, with weekday (rows) + time (cols) axes

struct DCHeatGrid: View {
    @Environment(\.dc) private var dc
    @Environment(\.lang) private var lang
    @Environment(\.colorScheme) private var scheme
    let cells: [[Double]]

    // rows = Mon…Sun. English uses single letters (M T W T F S S) to fit the 14pt gutter.
    private var weekdays: [String] {
        lang.t("M T W T F S S", "一 二 三 四 五 六 日").split(separator: " ").map(String.init)
    }
    private let labelW: CGFloat = 14

    // GitHub contribution palette (5 levels), appearance-aware.
    private func level(_ v: Double) -> Color {
        if v < 0.06 { return dc.track }
        let light = ["#9be9a8", "#40c463", "#30a14e", "#216e39"]
        let dark  = ["#0e4429", "#006d32", "#26a641", "#39d353"]
        let pal = scheme == .dark ? dark : light
        let i = v < 0.30 ? 0 : (v < 0.55 ? 1 : (v < 0.80 ? 2 : 3))
        return Color(hex: pal[i])
    }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<min(cells.count, 7), id: \.self) { r in
                HStack(spacing: 3) {
                    Text(weekdays[r]).font(.system(size: 8.5)).foregroundStyle(dc.fg3)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(0..<cells[r].count, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level(cells[r][c]))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            // time axis: 12 cols of 2h each → tick every 6h (0 / 6 / 12 / 18)
            HStack(spacing: 3) {
                Color.clear.frame(width: labelW, height: 1)
                ForEach(0..<12, id: \.self) { c in
                    Text(c % 3 == 0 ? "\(c * 2)" : "")
                        .font(.system(size: 7.5)).foregroundStyle(dc.fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Profile stat-card grid (2 cols × 4 rows), modeled on Claude Desktop's Overview

struct DCStatGrid: View {
    @Environment(\.dc) private var dc
    let items: [(label: String, value: String)]   // expects 8 (Sessions … Favorite model)

    var body: some View {
        // 2 per row; an odd tail keeps a balanced empty slot so widths don't jump.
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 6) {
                    ForEach(Array(pair.enumerated()), id: \.offset) { _, it in cell(it) }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func cell(_ it: (label: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(it.label).font(.system(size: 8.5)).foregroundStyle(dc.fg3).lineLimit(1)
            Text(it.value).font(.system(size: 15, weight: .bold)).monospacedDigit()
                .foregroundStyle(dc.fg).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(dc.elev))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dc.sep2, lineWidth: 0.5))
    }
}

// MARK: - Contribution calendar — GitHub-style blue, 7 rows (Mon…Sun) × week columns

struct DCContribCalendar: View {
    @Environment(\.dc) private var dc
    @Environment(\.lang) private var lang
    @Environment(\.colorScheme) private var scheme
    let cells: [[Double]]   // 7 rows × N week cols; -1 = outside window (blank)

    // GitHub shows only every other weekday to fit the gutter — Mon / Wed / Fri / Sun.
    private var weekdays: [String] {
        lang.t("M T W T F S S", "一 二 三 四 五 六 日").split(separator: " ").map(String.init)
    }
    private let labelW: CGFloat = 14

    private func level(_ v: Double) -> Color {
        if v < 0 { return .clear }          // outside the window → blank gap
        if v < 0.06 { return dc.track }     // in-window day with no activity
        let light = ["#bcd2f7", "#7da9ef", "#4a86e8", "#2f6ad0"]
        let dark  = ["#1d3a63", "#2b5aa0", "#3f7bd6", "#5b9bff"]
        let pal = scheme == .dark ? dark : light
        let i = v < 0.30 ? 0 : (v < 0.55 ? 1 : (v < 0.80 ? 2 : 3))
        return Color(hex: pal[i])
    }

    var body: some View {
        let cols = cells.first?.count ?? 0
        VStack(spacing: 3) {
            ForEach(0..<min(cells.count, 7), id: \.self) { r in
                HStack(spacing: 3) {
                    Text(r % 2 == 0 ? weekdays[r] : "").font(.system(size: 8)).foregroundStyle(dc.fg3)
                        .frame(width: labelW, alignment: .trailing)
                    ForEach(0..<cols, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level(cells[r][c]))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }
}

// MARK: - Usage-attribution table (one of Skills / Subagents / Plugins / MCP servers)
// Mirrors Claude Code's `/usage` "% of usage" lists. Each row's % is a share of the
// Claude total (passed in), so shares are independent and don't sum to 100.

struct AttributionTable: View {
    @Environment(\.dc) private var dc
    @Environment(\.lang) private var lang
    let title: String
    let rows: [AttributionRow]
    let metric: MenuMetric
    let total: Double          // Claude total (cost or tokens) — the "% of usage" denominator
    let dot: Color
    @State private var expanded = false
    private let cap = 5

    private func val(_ r: AttributionRow) -> Double { metric == .cost ? r.cost : Double(r.tokens) }
    private var sorted: [AttributionRow] { rows.sorted { val($0) > val($1) } }
    private var shown: [AttributionRow] { expanded ? sorted : Array(sorted.prefix(cap)) }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                ForEach(shown) { row($0) }
                if sorted.count > cap {
                    Button { expanded.toggle() } label: {
                        Text(expanded ? lang.t("Collapse", "收起")
                                      : lang.t("… \(sorted.count - cap) more", "… 还有 \(sorted.count - cap) 项"))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(dc.accent)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
            }
        }
    }

    private func row(_ r: AttributionRow) -> some View {
        let share = total > 0 ? val(r) / total : 0
        let pct = share * 100
        let pctText = (pct > 0 && pct < 0.5) ? "<1%" : "\(Int(pct.rounded()))%"
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 6, height: 6)
            Text(r.name).font(.system(size: 11)).foregroundStyle(dc.fg)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Text(metric == .cost ? Panel.usd(r.cost) : Panel.tok(r.tokens))
                .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(dc.fg3)
            Text(pctText).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(dc.fg).frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Wrapping flow layout (legend chips)

struct DCFlow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + lineSpacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
