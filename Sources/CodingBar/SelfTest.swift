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

        // ── Quota (offline: credential + response parsing, no network) ──────────
        let claudeCred = CredentialParser.parseClaudeCredentials(
            data: Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":9999999999000}}"#.utf8))
        check("claude credential valid", claudeCred.token == "tok" && claudeCred.status == .valid)

        let claudeExpired = CredentialParser.parseClaudeCredentials(
            data: Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1700000000000}}"#.utf8))
        check("claude credential expired", claudeExpired.status == .expired)

        let codexCred = CredentialParser.parseCodexCredentials(
            data: Data(#"{"auth_mode":"chatgpt","last_refresh":"2099-01-01T00:00:00Z","tokens":{"access_token":"ctok","account_id":"acc1"}}"#.utf8))
        check("codex credential valid", codexCred.token == "ctok" && codexCred.accountID == "acc1" && codexCred.status == .valid)

        let claudeWindows = ClaudeQuotaFetcher.parse(
            Data(#"{"five_hour":{"utilization":7.0,"resets_at":"2026-06-17T08:10:00.179218+00:00"},"seven_day":{"utilization":20.0,"resets_at":null},"seven_day_opus":null,"seven_day_sonnet":{"utilization":2.0,"resets_at":null}}"#.utf8))
        check("claude usage → 3 windows (opus null skipped)", claudeWindows.count == 3)
        check("claude 5h remaining ~0.93", abs((claudeWindows.first?.remaining ?? 0) - 0.93) < 0.0001)

        let codexWindows = CodexQuotaFetcher.parse(
            Data(#"{"rate_limit":{"primary_window":{"used_percent":1,"reset_at":1781674221,"limit_window_seconds":18000},"secondary_window":{"used_percent":74,"reset_at":1781742628,"limit_window_seconds":604800}}}"#.utf8))
        check("codex usage → 2 windows", codexWindows.count == 2)
        check("codex secondary labelled 7d", codexWindows.last?.label == "7d")
        check("codex 7d remaining ~0.26", abs((codexWindows.last?.remaining ?? 0) - 0.26) < 0.0001)

        let mixed = claudeWindows + codexWindows
        check("tightestRemaining picks most-depleted", abs((mixed.tightestRemaining ?? 1) - 0.26) < 0.0001)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
