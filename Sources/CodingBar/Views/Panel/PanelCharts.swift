import SwiftUI
import CodingBarCore

// MARK: - 7-day trend area chart (cost or tokens)

struct TrendChartView: View {
    let points: [DayPoint]
    var useCost: Bool = true
    private var values: [Double] { points.map { useCost ? $0.cost : Double($0.tokens) } }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 1, 0.0001)
            let n = max(values.count - 1, 1)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: w * CGFloat(i) / CGFloat(n), y: h - 6 - (h - 14) * CGFloat(v / maxV))
            }
            ZStack {
                // baseline
                Path { p in p.move(to: CGPoint(x: 0, y: h - 6)); p.addLine(to: CGPoint(x: w, y: h - 6)) }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                // area fill
                area(pts, w: w, h: h)
                    .fill(LinearGradient(colors: [Theme.brandAmber.opacity(0.34), Theme.brandAmber.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                // line
                line(pts).stroke(Theme.brandAmber, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // last point dot
                if let last = pts.last {
                    Circle().fill(Theme.brandAmber).frame(width: 6, height: 6).position(last)
                }
            }
        }
    }

    private func line(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<pts.count {
            let prev = pts[i-1], cur = pts[i]
            let mx = (prev.x + cur.x) / 2
            p.addCurve(to: cur, control1: CGPoint(x: mx, y: prev.y), control2: CGPoint(x: mx, y: cur.y))
        }
        return p
    }
    private func area(_ pts: [CGPoint], w: CGFloat, h: CGFloat) -> Path {
        var p = line(pts)
        guard let first = pts.first, let last = pts.last else { return p }
        p.addLine(to: CGPoint(x: last.x, y: h - 6))
        p.addLine(to: CGPoint(x: first.x, y: h - 6))
        p.closeSubpath()
        return p
    }
}

// MARK: - Tool-mix stacked bar + legend

struct ToolMixBar: View {
    let mix: ToolMix
    private var segs: [(String, Int, Color)] {
        [("写", mix.write, Theme.brandAmber), ("读", mix.read, Theme.codexColor),
         ("跑命令", mix.run, Theme.quotaGreen), ("搜索", mix.search, Color(hex: "#9a86c4")),
         ("其他", mix.other, Color.primary.opacity(0.25))].filter { $0.1 > 0 }
    }
    private var total: Double { Double(max(mix.total, 1)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(s.2).frame(width: geo.size.width * Double(s.1) / total)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 10)
            // legend
            FlowRow(spacing: 12) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(s.2).frame(width: 8, height: 8)
                        Text("\(s.0) \(Int((Double(s.1)/total*100).rounded()))%")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                    }
                }
            }
        }
    }
}

// Simple wrapping row for legend chips
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Heatmap (7 rows × 12 cols)

struct HeatmapView: View {
    let heat: Heatmap
    private let days = ["一","二","三","四","五","六","日"]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 3) {
                ForEach(0..<min(heat.cells.count, 7), id: \.self) { r in
                    HStack(spacing: 3) {
                        Text(days[r]).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.faintText).frame(width: 12, alignment: .trailing)
                        ForEach(0..<heat.cells[r].count, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Theme.brandAmber.opacity(max(0.05, heat.cells[r][c])))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            if !heat.peakLabel.isEmpty {
                (Text("你和 AI 最高产是 ").foregroundStyle(Theme.dimText)
                 + Text(heat.peakLabel).foregroundStyle(Theme.brandAmber).bold())
                    .font(.system(size: 11.5))
            }
        }
    }
}

// MARK: - Fuel gauge (current session context)

struct FuelGaugeView: View {
    let fuel: FuelGauge
    var active: Bool = true
    private var frac: Double { Double(fuel.usedTokens) / Double(max(fuel.maxTokens, 1)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Which session this gauge reflects: the most-recently-written
                // Claude session. Label "当前"(active) vs "最近"(idle) sets the
                // expectation when several sessions are open at once.
                Circle().fill(active ? Theme.quotaGreen : Theme.faintText).frame(width: 6, height: 6)
                Text(active ? "当前会话" : "最近会话").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                Text(fuel.sessionName).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryText).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(Panel.tokens(fuel.usedTokens)) / \(Panel.tokens(fuel.maxTokens))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText).fixedSize()
            }
            HBar(fraction: frac, color: Theme.quotaColor(1 - frac), height: 6)
            Text("预计还能来回 ~\(fuel.estRemainingTurns) 轮")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.faintText)
        }
    }
}
