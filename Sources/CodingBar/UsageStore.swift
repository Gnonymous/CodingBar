import Foundation
import SwiftUI
import CodingBarCore

// MARK: - Central UI state holder.
// Runs Aggregator.run() off the main actor and publishes on main.
@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: Snapshot = .sample()
    @Published var menuMetric: MenuMetric = .tokens

    /// The primaryText for the current menuMetric.
    var primaryText: String {
        switch menuMetric {
        case .tokens: return UsageStore.humanTokens(snapshot.overview.spend.tokens.total)
        case .cost:   return String(format: "$%.2f", snapshot.overview.spend.cost)
        }
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let snap = Aggregator.run()
            await MainActor.run { self.snapshot = snap }
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
