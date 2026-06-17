import Foundation

public enum Aggregator {

    /// `quota` is supplied by the online `QuotaService` (Claude + Codex usage
    /// APIs). It is a parameter rather than scanned here so the local-log
    /// aggregation stays synchronous and offline; the UI injects the latest
    /// network-fetched quota each run.
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

        // 3. Today's records
        let todayRecords = allRecords.filter { isToday($0.timestamp) }

        // 4. Overview — spend
        var todayCost: Double = 0
        var todayTokens = TokenBreakdown()
        var todayCwds = Set<String>()

        for r in todayRecords {
            let c = Pricing.cost(model: r.model, tokens: r.tokens)
            todayCost += c
            todayTokens += r.tokens
            if !r.cwd.isEmpty { todayCwds.insert(r.cwd) }
        }

        let todaySessions = todayCwds.count

        // 5. Trend — last 7 calendar days
        var trend: [DayPoint] = []
        var yesterdayCost: Double = 0
        for dayOffset in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -dayOffset, to: todayStart) else { continue }
            let nextDay = cal.date(byAdding: .day, value: 1, to: d) ?? d
            var dayCost: Double = 0
            var dayTotalTokens = 0
            for r in allRecords {
                let ds = dayStart(r.timestamp)
                if ds >= d && r.timestamp < nextDay {
                    let c = Pricing.cost(model: r.model, tokens: r.tokens)
                    dayCost += c
                    dayTotalTokens += r.tokens.total
                }
            }
            trend.append(DayPoint(date: d, cost: dayCost, tokens: dayTotalTokens))
            if dayOffset == 1 { yesterdayCost = dayCost }
        }

        let deltaVsPrevPct: Double
        if yesterdayCost > 0 {
            deltaVsPrevPct = (todayCost - yesterdayCost) / yesterdayCost * 100
        } else {
            deltaVsPrevPct = 0
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

        // Pillar ④ — Forecast
        let forecastInsight = Forecaster.recordAndForecast(quota: quota, now: now)

        // Pillar ④b — Coach tips
        var coach: [Insight] = Coach.build(from: todayRecords)
        if let fi = forecastInsight { coach.append(fi) }

        // Pillar ① — Git output (today's active project cwds)
        let output = GitCorrelator.build(fromTodayCwds: todayCwds, now: now)

        // ── Assemble ─────────────────────────────────────────────────────────

        let menu = MenuSummary(
            metric: .tokens,
            primaryText: primaryText,
            quotaPercent: quotaPercent,
            active: isActive,
            throughput: throughput
        )

        // 10. Overview
        let overview = Overview(
            range: .today,
            spend: PeriodTotals(cost: todayCost, tokens: todayTokens, sessions: todaySessions),
            output: output,
            deltaVsPrevPct: deltaVsPrevPct,
            trend: trend
        )

        return Snapshot(
            generatedAt: now,
            menu: menu,
            overview: overview,
            habits: habits,
            projects: projects,
            models: models,
            cache: cache,
            quota: quota,
            coach: coach,
            fuel: fuelGauge
        )
    }
}
