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
    public var id: String { model }
    public var model: String
    public var provider: Provider
    public var tokens: TokenBreakdown
    public var cost: Double
    public init(model: String, provider: Provider, tokens: TokenBreakdown, cost: Double) {
        self.model = model; self.provider = provider; self.tokens = tokens; self.cost = cost
    }
}

public struct ProjectStat: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var tokens: TokenBreakdown
    public var cost: Double
    public var lastActive: Date
    public init(name: String, path: String, tokens: TokenBreakdown, cost: Double, lastActive: Date) {
        self.name = name; self.path = path; self.tokens = tokens; self.cost = cost; self.lastActive = lastActive
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

    /// The single window surfaced in the menu bar: Claude 5h preferred, else
    /// Codex 5h, else the most-depleted window. Keeps the menu bar meaning one
    /// fixed, predictable thing ("how much of my Claude 5h window is used").
    var menuWindow: QuotaWindow? {
        first { $0.provider == .claude && $0.label == "5h" }
            ?? first { $0.provider == .codex && $0.label == "5h" }
            ?? self.min { $0.remaining < $1.remaining }
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

public enum Range: String, Codable, Sendable, CaseIterable { case today, week, month }

public struct Overview: Codable, Sendable {
    public var range: Range
    public var spend: PeriodTotals
    public var output: OutputStat
    public var deltaVsPrevPct: Double
    public var trend: [DayPoint]
    public init(range: Range, spend: PeriodTotals, output: OutputStat, deltaVsPrevPct: Double, trend: [DayPoint]) {
        self.range = range; self.spend = spend; self.output = output
        self.deltaVsPrevPct = deltaVsPrevPct; self.trend = trend
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
    public var overview: Overview
    public var habits: Habits
    public var projects: [ProjectStat]
    public var models: [ModelStat]
    public var cache: CacheStat
    public var quota: [QuotaWindow]
    /// Provider-level degradation notes for the quota section, e.g. "Claude 需重新登录".
    /// Empty when all quota fetches succeeded.
    public var quotaNotes: [String]
    public var coach: [Insight]
    public var fuel: FuelGauge?
    public init(generatedAt: Date, menu: MenuSummary, overview: Overview, habits: Habits,
                projects: [ProjectStat], models: [ModelStat], cache: CacheStat,
                quota: [QuotaWindow], coach: [Insight], fuel: FuelGauge?,
                quotaNotes: [String] = []) {
        self.generatedAt = generatedAt; self.menu = menu; self.overview = overview; self.habits = habits
        self.projects = projects; self.models = models; self.cache = cache; self.quota = quota
        self.coach = coach; self.fuel = fuel; self.quotaNotes = quotaNotes
    }
}
