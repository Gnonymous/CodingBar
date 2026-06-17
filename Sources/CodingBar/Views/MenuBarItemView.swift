import SwiftUI
import AppKit
import CodingBarCore

// MARK: - The menu bar item: [pulse] 6pt [two-line equal-width number block]
struct MenuBarItemView: View {
    let menu: MenuSummary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            PulseIcon(active: menu.active, throughput: menu.throughput)
                // Crisp white on a dark menu bar (black on a light one) — not the
                // slightly-gray 85%-alpha labelColor. The pulse line follows this
                // tint; the live dot keeps its own green/gray (liveness, not quota
                // — quota health stays on the meter + % below).
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)

            VStack(alignment: .trailing, spacing: 0) {
                numberText
                if let pct = menu.quotaPercent {
                    // The two lines share one width: a *hidden copy of the number*
                    // is the width authority (resolved in a single layout pass — no
                    // GeometryReader/preference feedback that fails to settle), so
                    // the quota row is proposed the number's full width. The % sits
                    // at the left edge, the meter's right edge lines up with the
                    // number's, and the gap between them absorbs the slack.
                    ZStack(alignment: .leading) {
                        numberText.hidden()
                        line2(pct: pct)
                    }
                }
            }
        }
        .frame(height: 22)
        .fixedSize()
    }

    private var numberText: some View {
        Text(menu.primaryText)
            .font(Theme.menuBarFont)
            .foregroundStyle(Color(nsColor: .labelColor))
            .fixedSize()
    }

    // `pct` is the remaining fraction of the menu window (Claude 5h). We render it
    // as *used %* per user preference; the 4-cell meter lights up with usage and is
    // colored by health (low usage = green, high usage = red). The Spacer expands
    // to fill the shared width, so the meter stays flush with the number's edge.
    private func line2(pct: Double) -> some View {
        let used = 1 - pct
        return HStack(spacing: 0) {
            Text("\(Int((used * 100).rounded()))%")
                .font(Theme.menuBarFont)
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
                .fixedSize()
            Spacer(minLength: 4)
            QuotaSegMeter(used: used, health: pct, colorScheme: colorScheme)
        }
    }
}

// MARK: - 4-cell quota meter (vertical segments, lit by usage, health-colored)
private struct QuotaSegMeter: View {
    let used: Double      // 0…1 used fraction → number of lit cells
    let health: Double    // remaining fraction → fill color
    let colorScheme: ColorScheme

    private let cells = 4
    private var lit: Int { min(cells, max(0, Int((used * Double(cells)).rounded()))) }

    var body: some View {
        HStack(spacing: 1.3) {
            ForEach(0..<cells, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(i < lit ? Theme.quotaColor(health) : Theme.quotaTrack(scheme: colorScheme))
                    .frame(width: 2, height: 11)
            }
        }
        .fixedSize()
    }
}
