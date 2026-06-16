import Foundation
import CodingBarCore

// Runnable test harness (XCTest needs Xcode, unavailable on Command Line Tools).
// Usage: `swift run CodingBar --self-test` (exit 0 = pass).
enum SelfTest {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "✓ " : "✗ ") + name)
            if !cond { failures += 1 }
        }

        let sample = Snapshot.sample()
        if let data = try? JSONEncoder().encode(sample),
           let back = try? JSONDecoder().decode(Snapshot.self, from: data) {
            check("sample snapshot round-trips", back.overview.spend.sessions == 7)
        } else {
            check("sample snapshot round-trips", false)
        }

        check("humanTokens M", UsageStore.humanTokens(1_240_000).hasSuffix("M"))
        check("humanTokens K", UsageStore.humanTokens(847_000).hasSuffix("K"))
        check("token total", TokenBreakdown(input: 10, output: 5, cacheRead: 100).total == 115)
        check("token add", (TokenBreakdown(input: 1) + TokenBreakdown(input: 2)).input == 3)

        let snap = Aggregator.run()
        check("aggregator menu non-empty", !snap.menu.primaryText.isEmpty)
        check("aggregator cost non-negative", snap.overview.spend.cost >= 0)
        check("aggregator cache hitRate in 0...1", (0...1).contains(snap.cache.hitRate))
        check("aggregator trend has points", !snap.overview.trend.isEmpty)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
