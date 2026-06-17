import Foundation
import SwiftUI
import CodingBarCore

// Runs Aggregator.run() off the main actor and publishes on main.
@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot = .sample()
    @Published var menuMetric: MenuMetric = .tokens
    /// Range for the overview hero (成果/代价/效率/趋势-delta). Menu bar stays today.
    @Published var selectedRange: Range = .today

    // Last-known online quota (Claude + Codex usage APIs). Refreshed on its own
    // 5-min cadence and carried into every local refresh so the snapshot stays
    // consistent between network fetches.
    private var quotaWindows: [QuotaWindow] = []
    private var quotaNotes: [String] = []

    /// The primaryText for the current menuMetric — always today (menu bar is
    /// independent of the panel's range selector).
    var primaryText: String {
        switch menuMetric {
        case .tokens: return UsageStore.humanTokens(snapshot.menu.todayTokens)
        case .cost:   return String(format: "$%.2f", snapshot.menu.todayCost)
        }
    }

    func toggleMetric() {
        menuMetric = (menuMetric == .tokens) ? .cost : .tokens
    }

    /// Switch the overview range (今日 / 周 / 月). All three are precomputed in the
    /// snapshot, so this is instant and the hero stays internally consistent — no
    /// recompute, no async race between 成果 and 代价.
    func setRange(_ range: Range) {
        selectedRange = range
    }

    /// Re-aggregate local logs (fast, offline). Reuses the last-known quota.
    func refresh() {
        let q = quotaWindows
        let notes = quotaNotes
        Task.detached(priority: .userInitiated) {
            var snap = Aggregator.run(quota: q)
            snap.quotaNotes = notes
            await MainActor.run { [snap] in self.snapshot = snap }
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
            let nowD = Date()
            _ = Forecaster.recordAndForecast(quota: result.windows, now: nowD)
            let forecast = Forecaster.forecastByProvider(quota: result.windows, now: nowD)
            var snap = self.snapshot
            snap.quota = result.windows
            snap.quotaNotes = result.notes
            snap.quotaForecast = forecast
            snap.quotaFetchedAt = result.windows.isEmpty ? nil : nowD
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
