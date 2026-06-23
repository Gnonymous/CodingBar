import Foundation

// Sample snapshot matching the approved mockups (panel-02.html). Used by `--dump-json`
// and SwiftUI previews until the real Aggregator lands, then kept for previews/tests.
public extension Snapshot {
    static func sample(now: Date = Date()) -> Snapshot {
        let cal = Calendar.current
        // Sample overview is the Today range, which buckets by hour (see Aggregator).
        let hourly = [0.0, 0.0, 0.1, 0.4, 0.9, 0.6, 0.3, 0.8, 1.4, 0.7, 1.1, 0.5, 0.9]
        let trend: [DayPoint] = hourly.enumerated().map { i, c in
            let d = cal.date(byAdding: .hour, value: -(hourly.count - 1 - i), to: now) ?? now
            return DayPoint(date: d, cost: c, tokens: Int(c * 290_000))
        }
        let heat: [[Double]] = (0..<7).map { d in
            (0..<12).map { h in
                var base = 0.22
                if h >= 10 { base = 0.85 } else if (6...8).contains(h) { base = 0.62 } else if (4...5).contains(h) { base = 0.5 } else if h <= 1 { base = 0.12 }
                if d >= 5 { base *= 0.55 }
                let jit = Double((d * 7 + h * 13) % 5) / 22.0
                return min(0.95, base + jit - 0.06)
            }
        }
        // 7 rows (Mon…Sun) × 13 week columns. Recent weeks denser, weekends lighter,
        // the tail of the current (last) week left blank (-1) to mirror real output.
        let profileCal: [[Double]] = (0..<7).map { row in
            (0..<13).map { col -> Double in
                if col == 12 && row >= 4 { return -1 }   // future days this week
                let seed = Double((row * 31 + col * 17) % 11) / 11.0
                let wk = row >= 5 ? seed * 0.5 : seed
                return col >= 9 ? min(1.0, wk + 0.25) : max(0, wk - 0.08)
            }
        }
        return Snapshot(
            generatedAt: now,
            menu: MenuSummary(metric: .tokens, primaryText: "1.2M", quotaPercent: 0.26, active: true, throughput: 1400),
            overview: Overview(
                range: .today,
                spend: PeriodTotals(cost: 4.20, tokens: TokenBreakdown(input: 280_000, output: 95_000, cacheRead: 820_000, cacheWrite: 60_000), sessions: 7),
                output: OutputStat(added: 1240, removed: 180, commits: 3, files: 18),
                deltaVsPrevPct: 12,
                deltaTokensPct: 9,
                trend: trend,
                contextSpend: ContextAttribution(
                    small: ContextBucket(cost: 0.52, tokens: 190_000),
                    mid: ContextBucket(cost: 1.28, tokens: 430_000),
                    large: ContextBucket(cost: 2.40, tokens: 640_000)),
                attribution: UsageAttribution(
                    skills: [AttributionRow(name: "orchestration", cost: 0.42, tokens: 120_000),
                             AttributionRow(name: "superpowers:brainstorming", cost: 0.13, tokens: 36_000),
                             AttributionRow(name: "hunt", cost: 0.08, tokens: 22_000),
                             AttributionRow(name: "check", cost: 0.05, tokens: 14_000)],
                    subagents: [AttributionRow(name: "workflow-subagent", cost: 0.30, tokens: 88_000),
                                AttributionRow(name: "general-purpose", cost: 0.12, tokens: 34_000)],
                    plugins: [AttributionRow(name: "superpowers", cost: 0.21, tokens: 60_000),
                              AttributionRow(name: "skill-creator", cost: 0.05, tokens: 14_000)],
                    mcpServers: [AttributionRow(name: "playwright", cost: 0.29, tokens: 84_000),
                                 AttributionRow(name: "happy", cost: 0.04, tokens: 11_000)],
                    totalCost: 4.20, totalTokens: 1_260_000)),
            habits: Habits(
                toolMix: ToolMix(write: 52, read: 28, run: 14, search: 6),
                rhythm: Rhythm(turnsPerSession: 11, avgMinutes: 22, interruptRate: 0.18),
                heatmap: Heatmap(cells: heat, peakLabel: "22:00–24:00")),
            projects: [
                ProjectStat(name: "coding-bar", path: "~/dev/coding-bar", tokens: TokenBreakdown(input: 220_000, output: 70_000, cacheRead: 600_000), cost: 3.10, lastActive: now.addingTimeInterval(-720)),
                ProjectStat(name: "api-svc", path: "~/work/api-svc", tokens: TokenBreakdown(input: 60_000, output: 20_000, cacheRead: 130_000), cost: 0.80, lastActive: now.addingTimeInterval(-7200)),
                ProjectStat(name: "dotfiles", path: "~/.dotfiles", tokens: TokenBreakdown(input: 18_000, output: 6_000, cacheRead: 36_000), cost: 0.20, lastActive: now.addingTimeInterval(-86_400)),
            ],
            models: [
                ModelStat(model: "Opus 4.8", provider: .claude, tokens: TokenBreakdown(input: 180_000, output: 60_000, cacheRead: 480_000), cost: 2.80),
                ModelStat(model: "Sonnet 4.6", provider: .claude, tokens: TokenBreakdown(input: 90_000, output: 30_000, cacheRead: 260_000), cost: 1.10),
                ModelStat(model: "GPT-5.5", provider: .codex, tokens: TokenBreakdown(input: 40_000, output: 14_000, cacheRead: 56_000), cost: 0.30),
            ],
            cache: CacheStat(hitRate: 0.87, savedUSD: 6.40),
            quota: [
                QuotaWindow(provider: .claude, label: "5h", remaining: 0.88, resetAt: now.addingTimeInterval(2 * 3600 + 12 * 60)),
                QuotaWindow(provider: .claude, label: "7d", remaining: 0.79, resetAt: now.addingTimeInterval(4 * 86_400)),
                QuotaWindow(provider: .claude, label: "7d·Sonnet", remaining: 0.98, resetAt: now.addingTimeInterval(4 * 86_400)),
                QuotaWindow(provider: .codex, label: "5h", remaining: 0.99, resetAt: now.addingTimeInterval(3 * 3600)),
                QuotaWindow(provider: .codex, label: "7d", remaining: 0.26, resetAt: now.addingTimeInterval(86_400)),
            ],
            coach: [
                Insight(kind: .tip, text: "8 simple tasks ran on Opus. Haiku could handle them — save ~$0.9 today.", savingUSD: 0.9),
                Insight(kind: .forecast, text: "Weekly quota runs out Thu 15:00"),
            ],
            fuel: FuelGauge(sessionName: "coding-bar", usedTokens: 142_000, maxTokens: 200_000, estRemainingTurns: 28),
            liveSessions: [
                LiveSession(name: "CodingBar", model: "Opus 4.8", provider: .claude, usedTokens: 123_954, maxTokens: 200_000, throughput: 142),
                LiveSession(name: "web-scraper", model: "Sonnet 4.5", provider: .claude, usedTokens: 48_200, maxTokens: 200_000, throughput: 96),
                LiveSession(name: "docs-site", model: "Haiku 4", provider: .claude, usedTokens: 18_400, maxTokens: 200_000, throughput: 64),
            ],
            burnPerMin: 1.92,
            quotaForecast: [
                "claude": "Claude weekly quota runs out Wed 15:12",
                "codex": "Codex weekly quota runs out tomorrow 08:30",
            ],
            quotaFetchedAt: now.addingTimeInterval(-46),
            profile: ProfileStats(
                sessions: 202, messages: 31_256, totalTokens: 66_800_000, activeDays: 28,
                currentStreak: 22, longestStreak: 22, peakHour: 16,
                favoriteModel: "anthropic/claude-opus-4-8", favoriteModelProvider: .claude,
                calendar: profileCal)
        )
    }
}
