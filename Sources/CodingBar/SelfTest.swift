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
        check("aggregator 3 overviews (today/week/month)",
              Set(snap.overviews.map { $0.range }) == Set([.today, .week, .month]))
        // Per-range composition: wider windows include at least as many models as today.
        let monthModels = snap.overviews.first { $0.range == .month }?.models.count ?? 0
        let todayModels = snap.overviews.first { $0.range == .today }?.models.count ?? 0
        check("month composition ⊇ today", monthModels >= todayModels)

        // ── Quota (offline: credential + response parsing, no network) ──────────
        let claudeCred = CredentialParser.parseClaudeCredentials(
            data: Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":9999999999000}}"#.utf8))
        check("claude credential valid", claudeCred.token == "tok" && claudeCred.status == .valid)

        let claudeExpired = CredentialParser.parseClaudeCredentials(
            data: Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1700000000000}}"#.utf8))
        check("claude credential expired", claudeExpired.status == .expired)

        // Regression: a long-stale `last_refresh` must still be valid. Codex tokens have
        // no readable expiry, so only the live 401/403 decides — an 8-day staleness
        // heuristic here used to false-negative active Codex sessions (idle >8 days).
        let codexCred = CredentialParser.parseCodexCredentials(
            data: Data(#"{"auth_mode":"chatgpt","last_refresh":"2020-01-01T00:00:00Z","tokens":{"access_token":"ctok","account_id":"acc1"}}"#.utf8))
        check("codex credential valid despite stale last_refresh", codexCred.token == "ctok" && codexCred.accountID == "acc1" && codexCred.status == .valid)

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

        // ── Forecast (provider-agnostic: same path for Claude and Codex) ─────────
        let fcCal = Calendar.current
        let fcNow = fcCal.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 12))!  // Wednesday
        let fcDay = 86_400.0, fcT0 = fcNow.timeIntervalSince1970
        func fcPt(_ d: Double, _ r: Double) -> Forecaster.Point { (t: fcT0 + d * fcDay, r: r) }
        // Live window 1.0 → 0.10 over 6 days ⇒ zero ≈ now + 0.667 day (16h).
        let fcLive = (0...6).map { fcPt(-6 + Double($0), 1.0 - 0.9 * (Double($0) / 6.0)) }
        let fcResetFar = fcNow.addingTimeInterval(3 * fcDay)
        let fcLiveZero = Forecaster.predictDepletion(samples: fcLive, resetAt: fcResetFar, now: fcNow)
        check("forecast projects clean decline ~16h out",
              abs((fcLiveZero?.timeIntervalSince1970 ?? 0) - (fcT0 + (2.0 / 3.0) * fcDay)) < 3600)
        // Samples before a reset (the old cross-reset bug) must not shift the projection.
        let fcWithReset = [fcPt(-13, 0.30), fcPt(-12, 0.20), fcPt(-11, 0.12), fcPt(-10, 0.05)] + fcLive
        check("forecast ignores pre-reset samples",
              Forecaster.predictDepletion(samples: fcWithReset, resetAt: fcResetFar, now: fcNow)?.timeIntervalSince1970
                == fcLiveZero?.timeIntervalSince1970)
        // Window resets before the projected zero ⇒ never runs out ⇒ no forecast.
        check("forecast suppressed when reset precedes depletion",
              Forecaster.predictDepletion(samples: fcLive, resetAt: fcNow.addingTimeInterval(0.25 * fcDay), now: fcNow) == nil)
        // Day always spelled out so a multi-day-out "Mon" can't read as a past weekday.
        let fcToday = fcCal.date(bySettingHour: 15, minute: 0, second: 0, of: fcNow)!
        let fc3d = fcCal.date(byAdding: .day, value: 3, to: fcNow)!  // Wed + 3 = Saturday
        check("forecast formats same-day as today", Forecaster.formatDepletion(fcToday, now: fcNow, language: .en) == "today 15:00")
        check("forecast formats multi-day as weekday", Forecaster.formatDepletion(fc3d, now: fcNow, language: .en).hasPrefix("Sat "))

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
