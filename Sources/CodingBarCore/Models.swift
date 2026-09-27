import Foundation

// MARK: - Shared contracts between the data layer (CodingBarCore) and the UI (CodingBar).
// Everything here is value-type, Codable and Sendable so the Core can run headless
// (`swift run CodingBar --dump-json`) and the UI just renders a Snapshot.

public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

/// Unified token accounting. `input` is non-cached input tokens.
public struct TokenBreakdown: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reasoning = reasoning
    }

    public var total: Int { input + output + cacheRead + cacheWrite + reasoning }

    public static func + (l: TokenBreakdown, r: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: l.input + r.input, output: l.output + r.output,
                       cacheRead: l.cacheRead + r.cacheRead, cacheWrite: l.cacheWrite + r.cacheWrite,
                       reasoning: l.reasoning + r.reasoning)
    }
    public static func += (l: inout TokenBreakdown, r: TokenBreakdown) { l = l + r }
}

public struct ModelStat: Codable, Sendable, Identifiable {
    public var id: String { provider.rawValue + "·" + model }
    public var model: String
    public var provider: Provider
    public var tokens: TokenBreakdown
    public var cost: Double
    /// false when the price came from a family-keyword guess or the generic fallback
    /// rate rather than a real table entry — the UI flags such rows as approximate.
    public var pricedExact: Bool
    public init(model: String, provider: Provider, tokens: TokenBreakdown, cost: Double, pricedExact: Bool = true) {
        self.model = model; self.provider = provider; self.tokens = tokens; self.cost = cost; self.pricedExact = pricedExact
    }
}

public struct ProjectStat: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var tokens: TokenBreakdown
    public var cost: Double
    public var lastActive: Date
    /// Breakdown for this project's selected range. Empty for older snapshots.
    public var models: [ModelStat]
    public var trend: [DayPoint]
    public init(name: String, path: String, tokens: TokenBreakdown, cost: Double, lastActive: Date,
                models: [ModelStat] = [], trend: [DayPoint] = []) {
        self.name = name; self.path = path; self.tokens = tokens; self.cost = cost; self.lastActive = lastActive
        self.models = models; self.trend = trend
    }

    private enum CodingKeys: String, CodingKey { case name, path, tokens, cost, lastActive, models, trend }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        tokens = try values.decode(TokenBreakdown.self, forKey: .tokens)
        cost = try values.decode(Double.self, forKey: .cost)
        lastActive = try values.decode(Date.self, forKey: .lastActive)
        models = try values.decodeIfPresent([ModelStat].self, forKey: .models) ?? []
        trend = try values.decodeIfPresent([DayPoint].self, forKey: .trend) ?? []
    }
}

public struct DayPoint: Codable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var cost: Double
    public var tokens: Int
    public init(date: Date, cost: Double, tokens: Int) { self.date = date; self.cost = cost; self.tokens = tokens }
}

public struct QuotaWindow: Codable, Sendable, Identifiable {
    public var id: String { "\(provider.rawValue)-\(label)" }
    public var provider: Provider
    public var label: String          // "5h" / "7d" / "周"
    public var remaining: Double       // 0...1 fraction remaining
    public var resetAt: Date?
    public init(provider: Provider, label: String, remaining: Double, resetAt: Date?) {
        self.provider = provider; self.label = label; self.remaining = remaining; self.resetAt = resetAt
    }
}

public extension Array where Element == QuotaWindow {
    /// The most-depleted window's remaining fraction, nil when there is no data.
    var tightestRemaining: Double? { map(\.remaining).min() }

    /// The single window surfaced in the menu bar: Claude 5h preferred, else Codex
    /// 7d. Only these canonical limits are eligible because the menu bar has no label
    /// that could honestly explain an arbitrary fallback window.
    var menuWindow: QuotaWindow? {
        first { $0.provider == .claude && $0.label == "5h" }
            ?? first { $0.provider == .codex && $0.label == "7d" }
    }

    /// Menu-bar window honoring the user's preferred provider: Claude's 5h or Codex's
    /// 7d window. If that canonical window is unavailable, falls back to the other
    /// provider's canonical window; `nil` preference uses the default chain.
    func menuWindow(preferring provider: Provider?) -> QuotaWindow? {
        guard let provider else { return menuWindow }
        let label: String
        switch provider {
        case .claude: label = "5h"
        case .codex: label = "7d"
        }
        return first { $0.provider == provider && $0.label == label } ?? menuWindow
    }
}

public struct CacheStat: Codable, Sendable {
    public var hitRate: Double         // 0...1
    public var savedUSD: Double
    public init(hitRate: Double = 0, savedUSD: Double = 0) { self.hitRate = hitRate; self.savedUSD = savedUSD }
}

public enum InsightKind: String, Codable, Sendable { case tip, forecast, milestone }

public struct Insight: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var kind: InsightKind
    public var text: String
    public var savingUSD: Double?
    public init(kind: InsightKind, text: String, savingUSD: Double? = nil) {
        self.kind = kind; self.text = text; self.savingUSD = savingUSD
    }
}

/// Pillar ②: live "fuel gauge" for the current session.
public struct FuelGauge: Codable, Sendable {
    public var sessionName: String
    public var usedTokens: Int
    public var maxTokens: Int
    public var estRemainingTurns: Int
    public init(sessionName: String, usedTokens: Int, maxTokens: Int, estRemainingTurns: Int) {
        self.sessionName = sessionName; self.usedTokens = usedTokens
        self.maxTokens = maxTokens; self.estRemainingTurns = estRemainingTurns
    }
}

/// One live (or just-active) agent session — drives the panel's "实时燃烧" list.
/// Heavy users run several agents in parallel, so this replaces the single fuel
/// gauge with a per-session breakdown (each session's model / context / speed).
public struct LiveSession: Codable, Sendable, Identifiable {
    public var id: String { name + "·" + model }
    public var name: String              // session name (cwd leaf)
    public var model: String             // display name, e.g. "Opus 4.8"
    public var provider: Provider
    public var usedTokens: Int           // context tokens in use
    public var maxTokens: Int            // context window (200K / 1M …)
    public var throughput: Double        // tokens/sec
    public init(name: String, model: String, provider: Provider, usedTokens: Int, maxTokens: Int, throughput: Double) {
        self.name = name; self.model = model; self.provider = provider
        self.usedTokens = usedTokens; self.maxTokens = maxTokens; self.throughput = throughput
    }
}

/// Pillar ③: behavioral mirror.
public struct ToolMix: Codable, Sendable {
    public var write: Int, read: Int, run: Int, search: Int, other: Int
    public init(write: Int = 0, read: Int = 0, run: Int = 0, search: Int = 0, other: Int = 0) {
        self.write = write; self.read = read; self.run = run; self.search = search; self.other = other
    }
    public var total: Int { write + read + run + search + other }
}

public struct Rhythm: Codable, Sendable {
    public var turnsPerSession: Double
    public var avgMinutes: Double
    public var interruptRate: Double   // 0...1
    public init(turnsPerSession: Double = 0, avgMinutes: Double = 0, interruptRate: Double = 0) {
        self.turnsPerSession = turnsPerSession; self.avgMinutes = avgMinutes; self.interruptRate = interruptRate
    }
}

/// 7 rows (Mon..Sun) x 12 columns (2-hour buckets) of normalized intensity 0...1.
public struct Heatmap: Codable, Sendable {
    public var cells: [[Double]]
    public var peakLabel: String
    public init(cells: [[Double]] = [], peakLabel: String = "") { self.cells = cells; self.peakLabel = peakLabel }
}

/// All-time "profile" stats — the Insights tab's stat-card grid + GitHub-style
/// contribution calendar, modeled on Claude Desktop's Overview. Deliberately
/// independent of the panel's today/week/month range pill: streaks, active days and
/// the favorite model only read meaningfully over a lifetime window. Everything here
/// is still derived 100% locally from the same scanned `RawRecord`s — no new source.
public struct ProfileStats: Codable, Sendable, Equatable {
    public var sessions: Int          // distinct session log files, all-time
    public var messages: Int          // assistant turns (one RawRecord ≈ one reply)
    public var totalTokens: Int       // all-time total across every provider
    public var activeDays: Int        // distinct calendar days with any activity
    public var currentStreak: Int     // consecutive active days ending today (or yesterday)
    public var longestStreak: Int     // longest run of consecutive active days, all-time
    public var peakHour: Int          // 0...23 hour-of-day with the most tokens; -1 = no data
    public var favoriteModel: String  // canonical pricing key of the most-used model; "" = none
    public var favoriteModelProvider: Provider
    /// 7 rows (Mon…Sun) × N week columns of normalized 0...1 daily intensity. A cell is
    /// `-1` for days outside the window (before the first column / future days this week)
    /// so the view can render those as blank gaps rather than zero-intensity squares.
    public var calendar: [[Double]]

    public init(sessions: Int = 0, messages: Int = 0, totalTokens: Int = 0, activeDays: Int = 0,
                currentStreak: Int = 0, longestStreak: Int = 0, peakHour: Int = -1,
                favoriteModel: String = "", favoriteModelProvider: Provider = .claude,
                calendar: [[Double]] = []) {
        self.sessions = sessions; self.messages = messages; self.totalTokens = totalTokens
        self.activeDays = activeDays; self.currentStreak = currentStreak; self.longestStreak = longestStreak
        self.peakHour = peakHour; self.favoriteModel = favoriteModel
        self.favoriteModelProvider = favoriteModelProvider; self.calendar = calendar
    }

    public static let empty = ProfileStats()
}

/// Pillar ①: output correlated from local git.
public struct OutputStat: Codable, Sendable {
    public var added: Int
    public var removed: Int
    public var commits: Int
    public var files: Int
    public init(added: Int = 0, removed: Int = 0, commits: Int = 0, files: Int = 0) {
        self.added = added; self.removed = removed; self.commits = commits; self.files = files
    }
}

public struct PeriodTotals: Codable, Sendable {
    public var cost: Double
    public var tokens: TokenBreakdown
    public var sessions: Int
    public init(cost: Double = 0, tokens: TokenBreakdown = .init(), sessions: Int = 0) {
        self.cost = cost; self.tokens = tokens; self.sessions = sessions
    }
}

/// Spend + tokens for one context-window size band.
public struct ContextBucket: Codable, Sendable, Equatable {
    public var cost: Double
    public var tokens: Int
    public init(cost: Double = 0, tokens: Int = 0) { self.cost = cost; self.tokens = tokens }
    public static func + (l: ContextBucket, r: ContextBucket) -> ContextBucket {
        ContextBucket(cost: l.cost + r.cost, tokens: l.tokens + r.tokens)
    }
}

/// Claude spend grouped by the prompt (context-window) size at each turn — the
/// "what's contributing to your usage" lens from Claude Code's `/usage`. Buckets by total
/// prompt tokens: small ≤50k, mid 50–150k, large >150k. Range-aware (each Overview
/// computes its own, so it follows the panel's range pill). **Claude-only**: a Claude
/// `usage` block is the request's absolute prompt size (input + cache_read +
/// cache_creation), which IS the context; Codex records are per-turn deltas of a running
/// total, so their per-record tokens aren't an absolute context measure — they're excluded.
public struct ContextAttribution: Codable, Sendable, Equatable {
    public var small: ContextBucket
    public var mid: ContextBucket
    public var large: ContextBucket
    public init(small: ContextBucket = .init(), mid: ContextBucket = .init(), large: ContextBucket = .init()) {
        self.small = small; self.mid = mid; self.large = large
    }
    public var totalCost: Double { small.cost + mid.cost + large.cost }
    public var totalTokens: Int { small.tokens + mid.tokens + large.tokens }

    /// Bucket lower bounds (prompt tokens). A turn lands in `mid` above `midThreshold`
    /// and in `large` above `largeThreshold`; the UI labels the bands from these.
    public static let midThreshold = 50_000
    public static let largeThreshold = 150_000
}

/// One named consumer in a usage-attribution table (e.g. the `hunt` skill).
public struct AttributionRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var cost: Double
    public var tokens: Int
    public init(name: String, cost: Double, tokens: Int) { self.name = name; self.cost = cost; self.tokens = tokens }
}

/// Claude spend attributed to what drove each turn — the `/usage` "what's contributing to
/// your usage" tables. Each list is a share of the **Claude total** (`totalCost`/
/// `totalTokens`), so percentages are independent and don't sum to 100 (most turns carry
/// no attribution at all). Range-aware; **Claude-only** (Codex logs lack these tags).
public struct UsageAttribution: Codable, Sendable, Equatable {
    public var skills: [AttributionRow]
    public var subagents: [AttributionRow]
    public var plugins: [AttributionRow]
    public var mcpServers: [AttributionRow]
    public var totalCost: Double      // Claude total in range — the "% of usage" denominator
    public var totalTokens: Int
    public init(skills: [AttributionRow] = [], subagents: [AttributionRow] = [],
                plugins: [AttributionRow] = [], mcpServers: [AttributionRow] = [],
                totalCost: Double = 0, totalTokens: Int = 0) {
        self.skills = skills; self.subagents = subagents; self.plugins = plugins
        self.mcpServers = mcpServers; self.totalCost = totalCost; self.totalTokens = totalTokens
    }
    public var isEmpty: Bool { skills.isEmpty && subagents.isEmpty && plugins.isEmpty && mcpServers.isEmpty }
}

public enum Range: String, Codable, Sendable, CaseIterable { case today, week, month }

public struct Overview: Codable, Sendable {
    public var range: Range
    public var spend: PeriodTotals
    public var output: OutputStat
    /// Percent change vs the previous equal-length period; nil when there's no
    /// prior period to compare (the pill is hidden, mirroring the prototype).
    /// `deltaVsPrevPct` is the cost change; `deltaTokensPct` is the token change —
    /// the panel picks whichever matches the active display metric.
    public var deltaVsPrevPct: Double?
    public var deltaTokensPct: Double?
    public var trend: [DayPoint]
    /// Per-range cost composition so the 构成 (Cost) tab follows the range selector
    /// instead of always showing all-time totals.
    public var models: [ModelStat]
    public var projects: [ProjectStat]
    /// Spend grouped by context-window size at each Claude turn (Claude-only, range-aware).
    public var contextSpend: ContextAttribution
    /// Spend attributed to skills / subagents / plugins / MCP servers (Claude-only, range-aware).
    public var attribution: UsageAttribution
    public init(range: Range, spend: PeriodTotals, output: OutputStat,
                deltaVsPrevPct: Double?, deltaTokensPct: Double? = nil, trend: [DayPoint],
                models: [ModelStat] = [], projects: [ProjectStat] = [],
                contextSpend: ContextAttribution = .init(), attribution: UsageAttribution = .init()) {
        self.range = range; self.spend = spend; self.output = output
        self.deltaVsPrevPct = deltaVsPrevPct; self.deltaTokensPct = deltaTokensPct; self.trend = trend
        self.models = models; self.projects = projects; self.contextSpend = contextSpend
        self.attribution = attribution
    }

    /// Period-over-period change for the given display metric (nil = hide pill).
    public func delta(for metric: MenuMetric) -> Double? {
        metric == .cost ? deltaVsPrevPct : deltaTokensPct
    }
}

public struct Habits: Codable, Sendable {
    public var toolMix: ToolMix
    public var rhythm: Rhythm
    public var heatmap: Heatmap
    public init(toolMix: ToolMix, rhythm: Rhythm, heatmap: Heatmap) {
        self.toolMix = toolMix; self.rhythm = rhythm; self.heatmap = heatmap
    }
}

public enum MenuMetric: String, Codable, Sendable, CaseIterable { case tokens, cost }

/// Everything the menu bar item needs in one place.
/// The menu bar is ALWAYS today (independent of the panel's range selector), so it
/// carries its own today totals rather than reading the (range-aware) overview.
public struct MenuSummary: Codable, Sendable {
    public var metric: MenuMetric
    public var primaryText: String      // e.g. "1.2M" or "$4.20"
    public var todayTokens: Int         // today's total tokens (menu bar)
    public var todayCost: Double         // today's total cost (menu bar)
    public var quotaPercent: Double?    // 0...1 remaining, nil if unavailable
    public var active: Bool             // an agent is currently writing
    public var throughput: Double       // tokens/sec, drives the pulse animation
    public init(metric: MenuMetric, primaryText: String, todayTokens: Int = 0, todayCost: Double = 0,
                quotaPercent: Double?, active: Bool, throughput: Double) {
        self.metric = metric; self.primaryText = primaryText
        self.todayTokens = todayTokens; self.todayCost = todayCost; self.quotaPercent = quotaPercent
        self.active = active; self.throughput = throughput
    }
}

/// Top-level payload produced by the Core and rendered by the UI.
public struct Snapshot: Codable, Sendable {
    public var generatedAt: Date
    public var menu: MenuSummary
    public var overview: Overview            // today (menu/default)
    /// All three ranges precomputed (today / week / month) so the panel switches
    /// instantly and consistently. The UI picks by the user's selected range.
    public var overviews: [Overview]
    public var habits: Habits
    /// All-time profile stats (Insights tab stat-card grid + contribution calendar).
    public var profile: ProfileStats
    public var projects: [ProjectStat]
    public var models: [ModelStat]
    public var cache: CacheStat
    public var quota: [QuotaWindow]
    /// Provider-level degradation notes for the quota section, e.g. "Claude 需重新登录".
    /// Empty when all quota fetches succeeded.
    public var quotaNotes: [String]
    public var coach: [Insight]
    public var fuel: FuelGauge?
    /// Live/just-active sessions (parallel agents) + current burn rate ($/min).
    public var liveSessions: [LiveSession]
    public var burnPerMin: Double
    /// Per-provider quota-depletion forecast text, keyed by `Provider.rawValue`
    /// (e.g. "claude" → "Claude 周额度预计 周三 15:12 见底"). Empty when no history.
    public var quotaForecast: [String: String]
    /// When the online quota was last *successfully* fetched (oldest across providers
    /// that have data) — drives an honest "联网 · X 秒前" that ages during TTL cache-hits
    /// and failure streaks instead of resetting to "刚刚" on every poll.
    public var quotaFetchedAt: Date?
    /// Per-provider last-success time (provider.rawValue → date) for per-group labels.
    public var quotaFetchedByProvider: [String: Date]
    public init(generatedAt: Date, menu: MenuSummary, overview: Overview, habits: Habits,
                projects: [ProjectStat], models: [ModelStat], cache: CacheStat,
                quota: [QuotaWindow], coach: [Insight], fuel: FuelGauge?,
                quotaNotes: [String] = [], overviews: [Overview] = [],
                liveSessions: [LiveSession] = [], burnPerMin: Double = 0,
                quotaForecast: [String: String] = [:], quotaFetchedAt: Date? = nil,
                quotaFetchedByProvider: [String: Date] = [:], profile: ProfileStats = .empty) {
        self.generatedAt = generatedAt; self.menu = menu; self.overview = overview; self.habits = habits
        self.profile = profile
        self.projects = projects; self.models = models; self.cache = cache; self.quota = quota
        self.coach = coach; self.fuel = fuel; self.quotaNotes = quotaNotes
        self.overviews = overviews.isEmpty ? [overview] : overviews
        self.liveSessions = liveSessions; self.burnPerMin = burnPerMin
        self.quotaForecast = quotaForecast; self.quotaFetchedAt = quotaFetchedAt
        self.quotaFetchedByProvider = quotaFetchedByProvider
    }
}
