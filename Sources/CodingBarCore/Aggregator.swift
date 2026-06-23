import Foundation

public enum Aggregator {

    /// `quota` is supplied by the online `QuotaService` (Claude + Codex usage
    /// APIs). It is a parameter rather than scanned here so the local-log
    /// aggregation stays synchronous and offline; the UI injects the latest
    /// network-fetched quota each run. All three overview ranges are precomputed.
    public static func run(now: Date = Date(), quota: [QuotaWindow] = [], menuQuotaProvider: Provider? = nil,
                           language: AppLanguage = .en) -> Snapshot {
        let cal = Calendar.current

        // One shared Scanner so the on-disk cache is loaded (and saved) once per run,
        // not once per provider — the cache decode is one of the heaviest steps in
        // boot-time memory because it goes through `JSONSerialization`.
        let scanner = Scanner()
        // token/cost/behavior aggregation is 100% local
        let (claudeRecords, _) = ClaudeScanner.scan(scanner: scanner)
        let codexRecords = CodexScanner.scan(scanner: scanner)
        let allRecords = claudeRecords + codexRecords

        let todayStart = cal.startOfDay(for: now)
        func isToday(_ date: Date) -> Bool { date >= todayStart && date <= now }

        // drives the always-today menu bar + today's coach
        let todayRecords = allRecords.filter { isToday($0.timestamp) }
        var todayCost: Double = 0
        var todayTokens = TokenBreakdown()
        for r in todayRecords {
            todayCost += Pricing.cost(model: r.model, tokens: r.tokens)
            todayTokens += r.tokens
        }

        // precompute ALL three ranges so the panel switches instantly
        // and stays internally consistent (成果 + 代价 always from one range).
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
        func tokensTotal(from a: Date, to b: Date) -> Int {
            var t = 0
            for r in allRecords where r.timestamp >= a && r.timestamp < b { t += r.tokens.total }
            return t
        }

        // Git output for all ranges in one pass per repo, scanning the most-active
        // cwds over the widest (month) window. A repo only worked in *today* — a
        // freshly-created project, or a moved/renamed folder whose new path hasn't
        // accumulated enough records to out-rank older ones — would be cut by the
        // latency prefix, and its commits would vanish from the "today" bucket. So
        // today's cwds are prepended unconditionally: the selection criterion
        // (monthly volume) must not exclude a repo that the "today" bucket reports.
        let monthSpend = spend(since: monthStart)
        let monthCwds = monthSpend.cwds.sorted { $0.value > $1.value }.map { $0.key }
        var todayCwds: [String] = []
        var seenCwd = Set<String>()
        for r in todayRecords where !r.cwd.isEmpty {
            if seenCwd.insert(r.cwd).inserted { todayCwds.append(r.cwd) }
        }
        let scanCwds = todayCwds + monthCwds.prefix(10).filter { !seenCwd.contains($0) }
        let gitRanges = GitCorrelator.buildRanges(cwds: scanCwds, now: now)

        // The trend sparkline follows the range pill: Today buckets by hour (since
        // 00:00), 7d/30d by calendar day. Each overview builds its own series so the
        // curve — and the date caption under it — tracks the selection instead of
        // being frozen at one fixed 7-day window.
        func trendSeries(_ buckets: [(start: Date, end: Date)]) -> [DayPoint] {
            buckets.map { b in
                var bucketCost: Double = 0
                var bucketTokens = 0
                for r in allRecords where r.timestamp >= b.start && r.timestamp < b.end {
                    bucketCost += Pricing.cost(model: r.model, tokens: r.tokens)
                    bucketTokens += r.tokens.total
                }
                return DayPoint(date: b.start, cost: bucketCost, tokens: bucketTokens)
            }
        }
        // `count` calendar days ending today, each window [dayStart, nextDay).
        func dayBuckets(_ count: Int) -> [(start: Date, end: Date)] {
            (0..<count).reversed().compactMap { off in
                guard let d = cal.date(byAdding: .day, value: -off, to: todayStart) else { return nil }
                return (start: d, end: cal.date(byAdding: .day, value: 1, to: d) ?? d)
            }
        }
        // Hourly windows from 00:00 today through the hour containing `now`.
        func hourBucketsToday() -> [(start: Date, end: Date)] {
            var out: [(start: Date, end: Date)] = []
            var h = todayStart
            while h <= now {
                guard let next = cal.date(byAdding: .hour, value: 1, to: h), next > h else { break }
                out.append((start: h, end: next))
                h = next
            }
            return out
        }

        // Cost composition (by model / by project) over an arbitrary record set, so
        // the same logic serves the all-time top-level lists AND each range's overview
        // (the 构成 tab now follows the range selector). `pricedExact` is false when any
        // contributing record priced via a family guess / fallback rate.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func breakdown(from records: [RawRecord]) -> (models: [ModelStat], projects: [ProjectStat]) {
            var modelMap: [String: (tokens: TokenBreakdown, cost: Double, exact: Bool)] = [:]
            for r in records {
                let key = Pricing.normalize(model: r.model)
                var entry = modelMap[key] ?? (tokens: TokenBreakdown(), cost: 0, exact: true)
                entry.tokens += r.tokens
                entry.cost += Pricing.cost(model: r.model, tokens: r.tokens)
                entry.exact = entry.exact && Pricing.priceIsExact(model: r.model)
                modelMap[key] = entry
            }
            let models: [ModelStat] = modelMap
                .map { key, entry in
                    ModelStat(model: key, provider: Pricing.provider(forCanonicalKey: key),
                              tokens: entry.tokens, cost: entry.cost, pricedExact: entry.exact)
                }
                .sorted { $0.cost > $1.cost }

            var projectMap: [String: (tokens: TokenBreakdown, cost: Double, lastActive: Date)] = [:]
            for r in records {
                guard !r.cwd.isEmpty else { continue }
                var entry = projectMap[r.cwd] ?? (tokens: TokenBreakdown(), cost: 0, lastActive: Date.distantPast)
                entry.tokens += r.tokens
                entry.cost += Pricing.cost(model: r.model, tokens: r.tokens)
                if r.timestamp > entry.lastActive { entry.lastActive = r.timestamp }
                projectMap[r.cwd] = entry
            }
            let projects: [ProjectStat] = projectMap
                .map { cwd, entry -> ProjectStat in
                    let displayPath = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
                    return ProjectStat(name: URL(fileURLWithPath: cwd).lastPathComponent, path: displayPath,
                                       tokens: entry.tokens, cost: entry.cost, lastActive: entry.lastActive)
                }
                .sorted { $0.cost > $1.cost }
                .prefix(8)
                .map { $0 }
            return (models, projects)
        }

        // Claude spend by context-window size (the `/usage` "what's contributing" lens).
        // Codex is excluded: its per-record tokens are deltas of a running total, not the
        // absolute prompt size, so they can't be bucketed by context. Range-aware via the
        // record set passed in (each overview supplies its own range's records).
        func contextAttribution(from records: [RawRecord]) -> ContextAttribution {
            var small = ContextBucket(), mid = ContextBucket(), large = ContextBucket()
            for r in records where r.provider == .claude {
                // A Claude `usage` block is the request's absolute prompt size.
                let ctx = r.tokens.input + r.tokens.cacheRead + r.tokens.cacheWrite
                let b = ContextBucket(cost: Pricing.cost(model: r.model, tokens: r.tokens), tokens: r.tokens.total)
                if ctx > ContextAttribution.largeThreshold { large = large + b }
                else if ctx > ContextAttribution.midThreshold { mid = mid + b }
                else { small = small + b }
            }
            return ContextAttribution(small: small, mid: mid, large: large)
        }

        // Claude usage attributed to skills / subagents / plugins / MCP servers — the
        // `/usage` "what's contributing" tables. Each turn already carries Claude Code's
        // own `attribution*` tags, so this is an exact group-and-sum (no inference). Codex
        // is excluded (no such tags). `totalCost/Tokens` is the Claude total = the "% of
        // usage" denominator, so a category's share is its cost / all Claude spend.
        func usageAttribution(from records: [RawRecord]) -> UsageAttribution {
            var skill: [String: ContextBucket] = [:], agent: [String: ContextBucket] = [:]
            var plugin: [String: ContextBucket] = [:], mcp: [String: ContextBucket] = [:]
            var totalCost = 0.0, totalTokens = 0
            for r in records where r.provider == .claude {
                let b = ContextBucket(cost: Pricing.cost(model: r.model, tokens: r.tokens), tokens: r.tokens.total)
                totalCost += b.cost; totalTokens += b.tokens
                if let s = r.attribution.skill { skill[s] = (skill[s] ?? .init()) + b }
                if let a = r.attribution.agent { agent[a] = (agent[a] ?? .init()) + b }
                if let p = r.attribution.plugin { plugin[p] = (plugin[p] ?? .init()) + b }
                if let m = r.attribution.mcpServer { mcp[m] = (mcp[m] ?? .init()) + b }
            }
            func rows(_ map: [String: ContextBucket]) -> [AttributionRow] {
                map.map { AttributionRow(name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
                    .sorted { $0.cost > $1.cost }
            }
            return UsageAttribution(skills: rows(skill), subagents: rows(agent), plugins: rows(plugin),
                                    mcpServers: rows(mcp), totalCost: totalCost, totalTokens: totalTokens)
        }

        let (models, projects) = breakdown(from: allRecords)

        // cache stats are Claude only
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

        // Menu bar shows one window (the user's preferred provider, else Claude 5h).
        // quotaPercent is the *remaining* fraction (drives bar fill + color); the view
        // renders it as "used %".
        let quotaPercent: Double? = quota.menuWindow(preferring: menuQuotaProvider)?.remaining

        // Pillar ③ — Habits (tool mix, rhythm, heatmap)
        let habits = Behavior.build(from: allRecords, todayStart: todayStart, now: now)

        // Insights profile — all-time stat-card grid + contribution calendar (offline).
        let profile = ProfileBuilder.build(from: allRecords, now: now)

        // Pillar ② — Fuel gauge + active/throughput
        let (fuelGauge, isActive, throughput) = FuelCalculator.build(from: claudeRecords, now: now)

        // Pillar ② — parallel live sessions + current burn rate ($/min)
        let (liveSessions, burnPerMin) = FuelCalculator.liveSessions(
            claudeRecords: claudeRecords, codexRecords: codexRecords, now: now)

        // Pillar ④ — Forecast (records history, returns coach insight)
        let forecastInsight = Forecaster.recordAndForecast(quota: quota, now: now, language: language)
        let quotaForecast = Forecaster.forecastByProvider(quota: quota, now: now, language: language)

        // Pillar ④b — Coach tips
        var coach: [Insight] = Coach.build(from: todayRecords, language: language)
        if let fi = forecastInsight { coach.append(fi) }

        let menu = MenuSummary(
            metric: .tokens,
            primaryText: primaryText,
            todayTokens: todayTokens.total,
            todayCost: todayCost,
            quotaPercent: quotaPercent,
            active: isActive,
            throughput: throughput
        )

        func makeOverview(_ range: Range, start: Date, output: OutputStat) -> Overview {
            let s = spend(since: start)
            let periodDays = (range == .today) ? 1 : (range == .week ? 7 : 30)
            let prevStart = cal.date(byAdding: .day, value: -periodDays, to: start) ?? start
            let prev = cost(from: prevStart, to: start)
            let delta: Double? = prev > 0 ? (s.cost - prev) / prev * 100 : nil
            let prevTok = tokensTotal(from: prevStart, to: start)
            let deltaTok: Double? = prevTok > 0 ? Double(s.tokens.total - prevTok) / Double(prevTok) * 100 : nil
            let rangeRecords = allRecords.filter { $0.timestamp >= start && $0.timestamp <= now }
            let bd = breakdown(from: rangeRecords)
            let ctxAttr = contextAttribution(from: rangeRecords)
            let usageAttr = usageAttribution(from: rangeRecords)
            let trend: [DayPoint]
            switch range {
            case .today: trend = trendSeries(hourBucketsToday())
            case .week:  trend = trendSeries(dayBuckets(7))
            case .month: trend = trendSeries(dayBuckets(30))
            }
            return Overview(
                range: range,
                spend: PeriodTotals(cost: s.cost, tokens: s.tokens, sessions: s.cwds.count),
                output: output,
                deltaVsPrevPct: delta,
                deltaTokensPct: deltaTok,
                trend: trend,
                models: bd.models,
                projects: bd.projects,
                contextSpend: ctxAttr,
                attribution: usageAttr
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
            quotaFetchedAt: quota.isEmpty ? nil : now,
            profile: profile
        )
    }
}
