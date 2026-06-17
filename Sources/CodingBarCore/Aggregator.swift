import Foundation

public enum Aggregator {

    /// `quota` is supplied by the online `QuotaService` (Claude + Codex usage
    /// APIs). It is a parameter rather than scanned here so the local-log
    /// aggregation stays synchronous and offline; the UI injects the latest
    /// network-fetched quota each run. All three overview ranges are precomputed.
    public static func run(now: Date = Date(), quota: [QuotaWindow] = []) -> Snapshot {
        let cal = Calendar.current

        // 1. Scan all sources (token/cost/behavior — 100% local)
        let (claudeRecords, _) = ClaudeScanner.scan()
        let codexRecords = CodexScanner.scan()
        let allRecords = claudeRecords + codexRecords

        // 2. Date helpers
        let todayStart = cal.startOfDay(for: now)
        func isToday(_ date: Date) -> Bool { date >= todayStart && date <= now }
        func dayStart(_ date: Date) -> Date { cal.startOfDay(for: date) }

        // 3. Today's records (drive the always-today menu bar + today's coach)
        let todayRecords = allRecords.filter { isToday($0.timestamp) }
        var todayCost: Double = 0
        var todayTokens = TokenBreakdown()
        for r in todayRecords {
            todayCost += Pricing.cost(model: r.model, tokens: r.tokens)
            todayTokens += r.tokens
        }

        // 4. Overview — precompute ALL three ranges so the panel switches instantly
        //    and stays internally consistent (成果 + 代价 always from one range).
        let weekStart  = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let monthStart = cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        func spend(since start: Date) -> (cost: Double, tokens: TokenBreakdown, cwds: [String: Int]) {
            var c: Double = 0; var t = TokenBreakdown(); var cw: [String: Int] = [:]
            for r in allRecords where r.timestamp >= start && r.timestamp <= now {
                c += Pricing.cost(model: r.model, tokens: r.tokens)
                t += r.tokens
                if !r.cwd.isEmpty { cw[r.cwd, default: 0] += 1 }
            }
            return (c, t, cw)
        }
        func cost(from a: Date, to b: Date) -> Double {
            var c: Double = 0
            for r in allRecords where r.timestamp >= a && r.timestamp < b { c += Pricing.cost(model: r.model, tokens: r.tokens) }
            return c
        }

        // Git output for all ranges in one pass per repo, scanning the most-active
        // cwds over the widest (month) window.
        let monthSpend = spend(since: monthStart)
        let monthCwds = monthSpend.cwds.sorted { $0.value > $1.value }.map { $0.key }
        let gitRanges = GitCorrelator.buildRanges(cwds: monthCwds, now: now)

        // 5. Trend — last 7 calendar days (always 7d, independent of the range pill)
        var trend: [DayPoint] = []
        for dayOffset in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -dayOffset, to: todayStart) else { continue }
            let nextDay = cal.date(byAdding: .day, value: 1, to: d) ?? d
            var dayCost: Double = 0
            var dayTotalTokens = 0
            for r in allRecords {
                let ds = dayStart(r.timestamp)
                if ds >= d && r.timestamp < nextDay {
                    dayCost += Pricing.cost(model: r.model, tokens: r.tokens)
                    dayTotalTokens += r.tokens.total
                }
            }
            trend.append(DayPoint(date: d, cost: dayCost, tokens: dayTotalTokens))
        }

        // 6. Models — group by normalized model, sort by cost desc
        var modelMap: [String: (tokens: TokenBreakdown, cost: Double)] = [:]
        for r in allRecords {
            let key = Pricing.normalize(model: r.model)
            var entry = modelMap[key] ?? (tokens: TokenBreakdown(), cost: 0)
            entry.tokens += r.tokens
            entry.cost += Pricing.cost(model: r.model, tokens: r.tokens)
            modelMap[key] = entry
        }

        let models: [ModelStat] = modelMap
            .map { key, entry in
                ModelStat(
                    model: key,
                    provider: Pricing.provider(forCanonicalKey: key),
                    tokens: entry.tokens,
                    cost: entry.cost
                )
            }
            .sorted { $0.cost > $1.cost }

        // 7. Projects — group by cwd, top 8 by cost
        var projectMap: [String: (tokens: TokenBreakdown, cost: Double, lastActive: Date)] = [:]
        for r in allRecords {
            guard !r.cwd.isEmpty else { continue }
            var entry = projectMap[r.cwd] ?? (tokens: TokenBreakdown(), cost: 0, lastActive: Date.distantPast)
            entry.tokens += r.tokens
            entry.cost += Pricing.cost(model: r.model, tokens: r.tokens)
            if r.timestamp > entry.lastActive { entry.lastActive = r.timestamp }
            projectMap[r.cwd] = entry
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projects: [ProjectStat] = projectMap
            .map { cwd, entry -> ProjectStat in
                let displayPath = cwd.hasPrefix(home)
                    ? "~" + cwd.dropFirst(home.count)
                    : cwd
                let name = URL(fileURLWithPath: cwd).lastPathComponent
                return ProjectStat(
                    name: name,
                    path: displayPath,
                    tokens: entry.tokens,
                    cost: entry.cost,
                    lastActive: entry.lastActive
                )
            }
            .sorted { $0.cost > $1.cost }
            .prefix(8)
            .map { $0 }

        // 8. Cache stats — Claude only
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalInput = 0
        var totalSavedWeightedRead = 0.0

        for r in claudeRecords {
            totalCacheRead  += r.tokens.cacheRead
            totalCacheWrite += r.tokens.cacheWrite
            totalInput      += r.tokens.input
            let key = Pricing.normalize(model: r.model)
            let iPrice  = Pricing.inputPrice(forCanonicalKey: key)
            let crPrice = Pricing.cacheReadPrice(forCanonicalKey: key)
            totalSavedWeightedRead += Double(r.tokens.cacheRead) * (iPrice - crPrice)
        }

        let denominator = totalCacheRead + totalCacheWrite + totalInput
        let hitRate = denominator > 0 ? Double(totalCacheRead) / Double(denominator) : 0
        let savedUSD = totalSavedWeightedRead / 1_000_000

        let cache = CacheStat(hitRate: hitRate, savedUSD: savedUSD)

        // 9. Menu — token display
        let totalTodayTokens = todayTokens.total
        let primaryText: String
        if totalTodayTokens >= 1_000_000 {
            let val = Double(totalTodayTokens) / 1_000_000
            primaryText = String(format: "%.1fM", val)
        } else if totalTodayTokens >= 1_000 {
            let val = Double(totalTodayTokens) / 1_000
            primaryText = String(format: "%.0fK", val)
        } else {
            primaryText = "\(totalTodayTokens)"
        }

        // Menu bar shows one fixed window (Claude 5h preferred). quotaPercent is
        // the *remaining* fraction (drives bar fill + color); the view renders it
        // as "used %".
        let quotaPercent: Double? = quota.menuWindow?.remaining

        // ── Insight pillars ──────────────────────────────────────────────────

        // Pillar ③ — Habits (tool mix, rhythm, heatmap)
        let habits = Behavior.build(from: allRecords, todayStart: todayStart, now: now)

        // Pillar ② — Fuel gauge + active/throughput
        let (fuelGauge, isActive, throughput) = FuelCalculator.build(from: claudeRecords, now: now)

        // Pillar ② — parallel live sessions + current burn rate ($/min)
        let (liveSessions, burnPerMin) = FuelCalculator.liveSessions(
            claudeRecords: claudeRecords, codexRecords: codexRecords, now: now)

        // Pillar ④ — Forecast (records history, returns coach insight)
        let forecastInsight = Forecaster.recordAndForecast(quota: quota, now: now)
        let quotaForecast = Forecaster.forecastByProvider(quota: quota, now: now)

        // Pillar ④b — Coach tips
        var coach: [Insight] = Coach.build(from: todayRecords)
        if let fi = forecastInsight { coach.append(fi) }

        // ── Assemble ─────────────────────────────────────────────────────────

        let menu = MenuSummary(
            metric: .tokens,
            primaryText: primaryText,
            todayTokens: todayTokens.total,
            todayCost: todayCost,
            quotaPercent: quotaPercent,
            active: isActive,
            throughput: throughput
        )

        // 10. Overviews — one per range (today / last 7d / last 30d)
        func makeOverview(_ range: Range, start: Date, output: OutputStat) -> Overview {
            let s = spend(since: start)
            let periodDays = (range == .today) ? 1 : (range == .week ? 7 : 30)
            let prevStart = cal.date(byAdding: .day, value: -periodDays, to: start) ?? start
            let prev = cost(from: prevStart, to: start)
            let delta: Double? = prev > 0 ? (s.cost - prev) / prev * 100 : nil
            return Overview(
                range: range,
                spend: PeriodTotals(cost: s.cost, tokens: s.tokens, sessions: s.cwds.count),
                output: output,
                deltaVsPrevPct: delta,
                trend: trend
            )
        }
        let overviewToday = makeOverview(.today, start: todayStart, output: gitRanges.today)
        let overviews = [
            overviewToday,
            makeOverview(.week,  start: weekStart,  output: gitRanges.week),
            makeOverview(.month, start: monthStart, output: gitRanges.month),
        ]

        return Snapshot(
            generatedAt: now,
            menu: menu,
            overview: overviewToday,
            habits: habits,
            projects: projects,
            models: models,
            cache: cache,
            quota: quota,
            coach: coach,
            fuel: fuelGauge,
            overviews: overviews,
            liveSessions: liveSessions,
            burnPerMin: burnPerMin,
            quotaForecast: quotaForecast,
            quotaFetchedAt: quota.isEmpty ? nil : now
        )
    }
}
