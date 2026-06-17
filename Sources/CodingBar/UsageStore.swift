import Foundation
import SwiftUI
import CodingBarCore

// MARK: - Central UI state holder.
// Runs Aggregator.run() off the main actor and publishes on main.
@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot = .sample()
    @Published var menuMetric: MenuMetric = .tokens

    // Last-known online quota (Claude + Codex usage APIs). Refreshed on its own
    // 5-min cadence and carried into every local refresh so the snapshot stays
    // consistent between network fetches.
    private var quotaWindows: [QuotaWindow] = []
    private var quotaNotes: [String] = []

    /// The primaryText for the current menuMetric.
    var primaryText: String {
        switch menuMetric {
        case .tokens: return UsageStore.humanTokens(snapshot.overview.spend.tokens.total)
        case .cost:   return String(format: "$%.2f", snapshot.overview.spend.cost)
        }
    }

    func toggleMetric() {
        menuMetric = (menuMetric == .tokens) ? .cost : .tokens
    }

    /// Re-aggregate local logs (fast, offline). Reuses the last-known quota.
    func refresh() {
        let q = quotaWindows
        let notes = quotaNotes
        Task.detached(priority: .userInitiated) {
            var snap = Aggregator.run(quota: q)
            snap.quotaNotes = notes
            let result = snap
            await MainActor.run { self.snapshot = result }
        }
    }

    /// Fetch online quota (TTL-cached in QuotaService) and patch it into the
    /// current snapshot in place — no local rescan needed. `force` bypasses the
    /// cache for the manual refresh button.
    func refreshQuota(force: Bool = false) {
        Task {
            let result = await QuotaService.shared.current(force: force)
            self.quotaWindows = result.windows
            self.quotaNotes = result.notes
            var snap = self.snapshot
            snap.quota = result.windows
            snap.quotaNotes = result.notes
            snap.menu.quotaPercent = result.windows.menuWindow?.remaining
            self.snapshot = snap
        }
    }

    nonisolated static func humanTokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}
