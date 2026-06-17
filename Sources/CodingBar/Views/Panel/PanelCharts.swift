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
    let mix: ToolMix
    private var defs: [(String, Int, Color)] {
        [("写", mix.write, Color(hex: "#5b8def")), ("读", mix.read, Color(hex: "#57b894")),
         ("执行", mix.run, Color(hex: "#e0a04d")), ("搜索", mix.search, Color(hex: "#b07cc6")),
         ("其他", mix.other, Color(hex: "#8a9099"))].filter { $0.1 > 0 }
    }
    private var total: Double { Double(max(1, mix.write + mix.read + mix.run + mix.search + mix.other)) }
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
    @Environment(\.colorScheme) private var scheme
    let cells: [[Double]]

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]   // rows = Mon…Sun
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
