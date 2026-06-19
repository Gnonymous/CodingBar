import Foundation
import SwiftUI
import CodingBarCore

// Runs Aggregator.run() off the main actor and publishes on main.
@MainActor
final class UsageStore: ObservableObject {
    private enum Keys { static let metric = "menuMetric"; static let range = "selectedRange"; static let quotaSource = "menuQuotaSource" }
    private static let defaults = UserDefaults.standard

    @Published var snapshot: Snapshot = .sample()
    // Preferences persist across launches (they used to reset to defaults every start).
    @Published var menuMetric: MenuMetric { didSet { Self.defaults.set(menuMetric.rawValue, forKey: Keys.metric) } }
    /// Range for the overview hero (成果/代价/效率/趋势-delta). Menu bar stays today.
    @Published var selectedRange: Range { didSet { Self.defaults.set(selectedRange.rawValue, forKey: Keys.range) } }
    /// Which provider's quota the menu-bar icon reflects (falls back gracefully when
    /// that provider has no window). Re-applied to the live snapshot on change.
    @Published var menuQuotaSource: Provider {
        didSet { Self.defaults.set(menuQuotaSource.rawValue, forKey: Keys.quotaSource); applyMenuQuota() }
    }

    init() {
        let d = Self.defaults
        menuMetric = MenuMetric(rawValue: d.string(forKey: Keys.metric) ?? "") ?? .tokens
        selectedRange = Range(rawValue: d.string(forKey: Keys.range) ?? "") ?? .today
        menuQuotaSource = Provider(rawValue: d.string(forKey: Keys.quotaSource) ?? "") ?? .claude
    }

    /// Recompute the menu-bar quota percentage from the last-fetched windows using the
    /// current provider preference — no network, just re-selects the surfaced window.
    private func applyMenuQuota() {
        snapshot.menu.quotaPercent = quotaWindows.menuWindow(preferring: menuQuotaSource)?.remaining
    }

    // Last-known online quota (Claude + Codex usage APIs). Refreshed on its own
    // 5-min cadence and carried into every local refresh so the snapshot stays
    // consistent between network fetches.
    private var quotaWindows: [QuotaWindow] = []
    private var quotaNotes: [String] = []

    // A local re-aggregation already in flight. The 30s timer, the status-item click
    // and opening the panel all call refresh(); without this guard they pile up into
    // overlapping Aggregator.run() passes that fight over CPU/disk and the shared
    // scan-cache.json. Coalescing is correct here — every trigger just wants "the
    // latest data soon", and the next tick (or interaction) picks up anything skipped.
    private var isRefreshing = false

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
    /// Coalesced: a trigger that arrives while a pass is still running is dropped.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let q = quotaWindows
        let notes = quotaNotes
        let pref = menuQuotaSource
        Task.detached(priority: .userInitiated) {
            var snap = Aggregator.run(quota: q, menuQuotaProvider: pref)
            snap.quotaNotes = notes
            await MainActor.run { [snap] in
                self.snapshot = snap
                self.isRefreshing = false
            }
        }
    }

    /// Fetch online quota (TTL-cached in QuotaService) and patch it into the
    /// current snapshot in place — no local rescan needed. `force` bypasses the
    /// cache for the manual refresh button.
    func refreshQuota(force: Bool = false) {
        Task {
            let result = await QuotaService.shared.current(force: force)
            let nowD = Date()
            // Forecaster reads and rewrites quota-history.json; keep that disk I/O off
            // the main actor so a slow/large/corrupt history file can't jank the UI.
            let windows = result.windows
            let forecast = await Task.detached(priority: .utility) { () -> [String: String] in
                _ = Forecaster.recordAndForecast(quota: windows, now: nowD)
                return Forecaster.forecastByProvider(quota: windows, now: nowD)
            }.value
            self.quotaWindows = result.windows
            self.quotaNotes = result.notes
            var snap = self.snapshot
            snap.quota = result.windows
            snap.quotaNotes = result.notes
            snap.quotaForecast = forecast
            snap.quotaFetchedAt = result.windows.isEmpty ? nil : nowD
            snap.menu.quotaPercent = result.windows.menuWindow(preferring: self.menuQuotaSource)?.remaining
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
