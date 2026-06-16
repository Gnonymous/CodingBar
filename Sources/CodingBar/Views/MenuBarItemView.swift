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
            PulseIcon(active: menu.active, throughput: menu.throughput)
                .foregroundStyle(Color(nsColor: .labelColor))

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

    @ViewBuilder
    private func line2(pct: Double) -> some View {
        HStack(spacing: 0) {
            Text("\(Int((pct * 100).rounded()))%")
                .font(Theme.menuBarFont)
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.6))
                .fixedSize()
            Spacer(minLength: 2)
            QuotaBarView(remaining: pct, colorScheme: colorScheme)
        }
    }
}

// MARK: - Vertical quota bar (3pt wide, 11pt tall, fills from bottom)
private struct QuotaBarView: View {
    let remaining: Double
    let colorScheme: ColorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.quotaTrack(scheme: colorScheme))
                .frame(width: 3, height: 11)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.quotaColor(remaining))
                .frame(width: 3, height: max(11 * remaining, 1.5))
        }
        .frame(width: 3, height: 11)
    }
}
