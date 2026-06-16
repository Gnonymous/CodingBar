import SwiftUI
import CodingBarCore

// MARK: - Placeholder popover content until the real 3-tab panel lands (Phase: panel).
struct PanelPlaceholderView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 12) {
            Text("CodingBar").font(.headline)
            Text("Today: \(store.primaryText)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(String(format: "Cost: $%.2f", store.snapshot.overview.spend.cost))
                .font(.subheadline).foregroundStyle(.secondary)
            Divider()
            Button("Refresh") { store.refresh() }.buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 220)
    }
}
