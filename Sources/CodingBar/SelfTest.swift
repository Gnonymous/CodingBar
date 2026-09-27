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

        let millionTokens = TokenBreakdown(input: 1_000_000, output: 1_000_000,
                                           cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let july = Date(timeIntervalSince1970: 1_783_555_200)
        let september = Date(timeIntervalSince1970: 1_788_220_800)
        check("Fable 5 1h cache pricing", abs(Pricing.cost(model: "claude-fable-5", tokens: millionTokens,
                                                            at: july, cacheWrite1h: 1_000_000) - 81) < 0.000_001)
        check("Sonnet 5 permanent price", abs(Pricing.cost(model: "claude-sonnet-5", tokens: millionTokens,
                                                             at: july, cacheWrite1h: 1_000_000) - 16.2) < 0.000_001
              && abs(Pricing.cost(model: "claude-sonnet-5", tokens: millionTokens,
                                  at: september, cacheWrite1h: 1_000_000) - 16.2) < 0.000_001)
        check("latest Claude tiers and cache reads",
              abs(Pricing.cost(model: "claude-opus-5-5", tokens: millionTokens,
                               at: september, cacheWrite1h: 1_000_000) - 32.2) < 0.000_001
              && abs(Pricing.cost(model: "claude-fable-5-1", tokens: millionTokens,
                                  at: september, cacheWrite1h: 1_000_000) - 80.25) < 0.000_001
              && Pricing.priceIsExact(model: "claude-mythos-5-1"))

        let openAIBaseTokens = TokenBreakdown(input: 100_000, output: 100_000,
                                              cacheRead: 100_000, cacheWrite: 100_000)
        check("GPT-5.6 tiers resolve exactly",
              Pricing.normalize(model: "gpt-5.6") == "openai/gpt-5.6-sol"
                  && Pricing.normalize(model: "gpt-5.6-sol") == "openai/gpt-5.6-sol"
                  && Pricing.normalize(model: "gpt-5.6-terra") == "openai/gpt-5.6-terra"
                  && Pricing.normalize(model: "gpt-5.6-luna") == "openai/gpt-5.6-luna"
                  && Pricing.priceIsExact(model: "gpt-5.6"))
        check("GPT-5.6 Sol base and long-context pricing",
              abs(Pricing.cost(model: "gpt-5.6-sol", tokens: openAIBaseTokens, at: september,
                               billingInputTokens: 272_000) - 2.94) < 0.000_001
                  && abs(Pricing.cost(model: "gpt-5.6-sol", tokens: openAIBaseTokens, at: september,
                                      billingInputTokens: 272_001) - 4.88) < 0.000_001)
        check("GPT-6 exact rates and long context",
              Pricing.priceIsExact(model: "gpt-6-astra")
                  && Pricing.priceIsExact(model: "gpt-6-sol")
                  && Pricing.priceIsExact(model: "gpt-6-luna")
                  && abs(Pricing.cost(model: "gpt-6-astra", tokens: openAIBaseTokens,
                                      at: september, billingInputTokens: 272_001) - 12.2) < 0.000_001
                  && abs(Pricing.cost(model: "gpt-6-luna", tokens: openAIBaseTokens,
                                      at: september, billingInputTokens: 272_001) - 0.122) < 0.000_001)
        check("GPT prices cover current and historical IDs",
              abs(Pricing.cost(model: "gpt-5.4-mini", tokens: TokenBreakdown(output: 1_000_000),
                               at: july) - 4.5) < 0.000_001
                  && abs(Pricing.cost(model: "gpt-5.3-codex", tokens: TokenBreakdown(output: 1_000_000),
                                      at: july) - 14) < 0.000_001
                  && Pricing.priceIsExact(model: "gpt-5.1")
                  && Pricing.priceIsExact(model: "gpt-4o-mini")
                  && Pricing.normalize(model: "gpt-5.4-nano-2026-03-17") == "openai/gpt-5.4-nano")
        check("unknown Codex IDs remain approximate",
              Pricing.normalize(model: "gpt-5.6-codex") == "gpt-5.6-codex"
                  && !Pricing.priceIsExact(model: "gpt-5.6-codex")
                  && !Pricing.priceIsExact(model: "gpt-5.5-codex"))

        // Regression: the family-keyword fallback used to funnel every Opus into 4.8, so a
        // real `claude-opus-5` record was renamed and merged into the 4.8 row. Each tier
        // must resolve to itself; an unrecognized version keeps its own approximate ID.
        check("Opus 5 keeps its own identity",
              Pricing.normalize(model: "claude-opus-5") == "anthropic/claude-opus-5"
                  && Pricing.displayName(forCanonicalKey: "anthropic/claude-opus-5") == "Opus 5")
        check("older Opus tiers still resolve to themselves",
              Pricing.normalize(model: "claude-opus-4-8") == "anthropic/claude-opus-4-8"
                  && Pricing.normalize(model: "claude-opus-4-6") == "anthropic/claude-opus-4-6")
        check("dated Opus 5 variant resolves exactly",
              Pricing.normalize(model: "claude-opus-5-20260315") == "anthropic/claude-opus-5")
        check("unknown Claude versions keep their identity and approximate marker",
              Pricing.normalize(model: "claude-opus-9") == "claude-opus-9"
                  && !Pricing.priceIsExact(model: "claude-opus-9")
                  && Pricing.normalize(model: "claude-sonnet-9") == "claude-sonnet-9")
        // Opus 4.1 costs 3x the 4.5+ tiers, so explicit historical rows matter.
        check("off-tier Opus versions resolve to themselves, not the newest",
              Pricing.normalize(model: "claude-opus-4-1-20250805") == "anthropic/claude-opus-4-1"
                  && Pricing.normalize(model: "claude-opus-4-5-20251101") == "anthropic/claude-opus-4-5")
        check("Opus 4.1 keeps its 3x rate",
              abs(Pricing.cost(model: "claude-opus-4-1", tokens: millionTokens, at: july) - 110.25) < 0.000_001)
        check("Mythos 5 priced at the Fable tier",
              Pricing.priceIsExact(model: "claude-mythos-5")
                  && abs(Pricing.cost(model: "claude-mythos-5", tokens: millionTokens, at: july)
                         - Pricing.cost(model: "claude-fable-5", tokens: millionTokens, at: july)) < 0.000_001)
        check("bare family selectors mean the current model",
              Pricing.normalize(model: "opus") == "anthropic/claude-opus-5-5"
                  && Pricing.normalize(model: "sonnet") == "anthropic/claude-sonnet-5")
        // 1M each of input/output/cacheRead/cacheWrite at $5 / $25 / $0.5 / $6.25 = $36.75.
        check("Opus 5 priced at the Opus tier, not the generic fallback",
              Pricing.priceIsExact(model: "claude-opus-5")
                  && abs(Pricing.cost(model: "claude-opus-5", tokens: millionTokens, at: july) - 36.75) < 0.000_001)

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

        // ── Refresh pass reuses work ────────────────────────────────────────────
        // Both assertions guard a silent regression: the numbers stay correct either
        // way, the app just goes back to burning a core every 30 seconds.
        let disk = PerfCounters.scanCacheDiskReads
        _ = Aggregator.run()
        check("scan cache decoded once per process, not per pass",
              PerfCounters.scanCacheDiskReads == disk)

        let probe = "/CodingBar/self-test/not-a-repo"
        let t = Date()
        let recomputes = PerfCounters.gitRangeRecomputes
        PerfCounters.probeGitRanges(at: probe, now: t)
        PerfCounters.probeGitRanges(at: probe, now: t)
        check("git ranges memoized within TTL",
              PerfCounters.gitRangeRecomputes - recomputes == 1)
        PerfCounters.probeGitRanges(at: probe, now: t.addingTimeInterval(PerfCounters.gitRangeTTL + 1))
        check("git ranges recomputed past TTL",
              PerfCounters.gitRangeRecomputes - recomputes == 2)

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

        // Current schema: the model-scoped weekly caps live in `limits[]` and the legacy
        // `seven_day_opus`/`seven_day_sonnet` fields come back null, so parsing only the
        // legacy tiers drops the Fable sub-cap entirely.
        let limitsWindows = ClaudeQuotaFetcher.parse(
            Data(#"{"five_hour":{"utilization":37.0,"resets_at":"2026-08-03T23:40:00.568125+00:00"},"seven_day":{"utilization":14.0,"resets_at":"2026-08-09T23:00:00.568151+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"limits":[{"kind":"session","group":"session","percent":37,"resets_at":"2026-08-03T23:40:00.568125+00:00","scope":null,"is_active":true},{"kind":"weekly_all","group":"weekly","percent":14,"resets_at":"2026-08-09T23:00:00.568151+00:00","scope":null,"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":13,"resets_at":"2026-08-09T23:00:00.568411+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}"#.utf8))
        check("limits[] → 3 windows, no duplicate 5h/7d from legacy tiers", limitsWindows.count == 3)
        check("limits[] surfaces the Fable weekly sub-cap",
              limitsWindows.contains { $0.label == "7d·Fable" && abs($0.remaining - 0.87) < 0.0001 })
        check("limits[] scoped window carries its reset time",
              limitsWindows.first { $0.label == "7d·Fable" }?.resetAt != nil)

        // An unlabelable scoped entry must be dropped, not rendered as a second bare "7d".
        let unnamedScope = ClaudeQuotaFetcher.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":10,"resets_at":null,"scope":null},{"kind":"weekly_scoped","percent":50,"resets_at":null,"scope":{"model":{"id":null,"display_name":null}}},{"kind":"future_kind","percent":90,"resets_at":null,"scope":null}]}"#.utf8))
        check("unnamed scope and unknown kind are dropped",
              unnamedScope.count == 1 && unnamedScope.first?.label == "7d")

        // A limits[] that loses a window (renamed kind) must fall back to the legacy tier
        // for it rather than dropping the whole row.
        let mergedFallback = ClaudeQuotaFetcher.parse(
            Data(#"{"five_hour":{"utilization":7.0,"resets_at":null},"seven_day":{"utilization":20.0,"resets_at":null},"limits":[{"kind":"weekly_all","percent":14,"resets_at":null,"scope":null}]}"#.utf8))
        check("legacy tier fills a window missing from limits[]",
              mergedFallback.count == 2 && mergedFallback.contains { $0.label == "5h" })
        check("limits[] wins on a label both sources report",
              abs((mergedFallback.first { $0.label == "7d" }?.remaining ?? 0) - 0.86) < 0.0001)

        let codexWindows = CodexQuotaFetcher.parse(
            Data(#"{"rate_limit":{"primary_window":{"used_percent":1,"reset_at":1781674221,"limit_window_seconds":18000},"secondary_window":{"used_percent":74,"reset_at":1781742628,"limit_window_seconds":604800}}}"#.utf8))
        check("codex usage → 2 windows", codexWindows.count == 2)
        check("codex secondary labelled 7d", codexWindows.last?.label == "7d")
        check("codex 7d remaining ~0.26", abs((codexWindows.last?.remaining ?? 0) - 0.26) < 0.0001)
        check("codex menu quota uses weekly window",
              codexWindows.menuWindow(preferring: .codex)?.label == "7d")
        let codexFiveHourOnly = [QuotaWindow(provider: .codex, label: "5h", remaining: 0.91, resetAt: nil)]
        let canonicalFallback = [QuotaWindow(provider: .claude, label: "5h", remaining: 0.72, resetAt: nil)] + codexFiveHourOnly
        check("codex menu quota never falls back to 5h",
              codexFiveHourOnly.menuWindow(preferring: .codex) == nil
                  && canonicalFallback.menuWindow(preferring: .codex)?.provider == .claude)

        let mixed = claudeWindows + codexWindows
        check("tightestRemaining picks most-depleted", abs((mixed.tightestRemaining ?? 1) - 0.26) < 0.0001)

        // A scoped window renders as the bare model name: it sits above the plan-wide "7
        // days" row and shares its reset time, so re-stating the period on every scoped
        // row is redundant. The "7d·" prefix stays in the *label* — it's the forecast key,
        // the history-sample key and the sort key — so only the display strips it.
        check("scoped window displays the bare model name",
              Panel.windowLabel("7d·Fable", lang: .en) == "Fable" && Panel.windowLabel("7d·Fable", lang: .zh) == "Fable")
        check("plain windows keep their localized period label",
              Panel.windowLabel("7d", lang: .en) == "7 days" && Panel.windowLabel("5h", lang: .zh) == "5 小时")
        // Broadest limit first: 5h, then the plan-wide week, then the per-model slices
        // carved out of it.
        check("scoped weekly cap sorts under the plan-wide 7d",
              OverviewTab.windowRank("5h") < OverviewTab.windowRank("7d")
                  && OverviewTab.windowRank("7d") < OverviewTab.windowRank("7d·Fable"))

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
