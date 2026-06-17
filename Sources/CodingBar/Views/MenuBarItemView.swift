import SwiftUI
import AppKit
import CodingBarCore

// MARK: - Width measurement key (line 1 defines the block width; line 2 matches it)
private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - The menu bar item: [pulse] 6pt [two-line equal-width number block]
struct MenuBarItemView: View {
    let menu: MenuSummary

    @State private var line1Width: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            PulseIcon(active: menu.active, throughput: menu.throughput,
                      dotColor: menu.quotaPercent.map { Theme.quotaColor($0) })
                // Crisp white on a dark menu bar (black on a light one) — not the
                // slightly-gray 85%-alpha labelColor.
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)

            VStack(alignment: .leading, spacing: 0) {
                Text(menu.primaryText)
                    .font(Theme.menuBarFont)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize()
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: WidthKey.self, value: geo.size.width)
                    })

                if let pct = menu.quotaPercent {
                    line2(pct: pct).frame(width: max(line1Width, 1))
                }
            }
            .onPreferenceChange(WidthKey.self) { line1Width = $0 }
        }
        .frame(height: 22)
        .fixedSize()
    }

    // `pct` is the remaining fraction of the menu window (Claude 5h). We render
    // it as *used %* per user preference; the 4-cell meter lights up with usage
    // and is colored by health (low usage = green, high usage = red). The row is
    // trailing-anchored to the number's width so the meter's right edge always
    // lines up with the number above and never overflows to the right.
    private func line2(pct: Double) -> some View {
        let used = 1 - pct
        return HStack(spacing: 3) {
            Text("\(Int((used * 100).rounded()))%")
                .font(Theme.menuBarFont)
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
                .fixedSize()
            Spacer(minLength: 2)
            // Pull in by the monospaced glyph's trailing side-bearing (~1pt) so the
            // meter's right edge sits on the number's ink, not its layout box.
            QuotaSegMeter(used: used, health: pct, colorScheme: colorScheme)
                .padding(.trailing, 1)
        }
        .frame(width: max(line1Width, 1), alignment: .trailing)
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
