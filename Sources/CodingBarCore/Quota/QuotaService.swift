import Foundation

// MARK: - QuotaService: concurrent fetch of both providers with a TTL cache.
//
// Quota lives behind a network call, so unlike the 30s local-log refresh this is
// cached for 5 minutes (30s retry after a failure) to avoid hammering the usage
// endpoints. A single actor instance owns the cache; the UI asks for `current()`
// on its own cadence and gets a cheap cache hit most of the time.

public actor QuotaService {
    public static let shared = QuotaService()

    public struct Result: Sendable {
        public var windows: [QuotaWindow]
        public var notes: [String]
        /// When the *displayed* windows were last actually fetched over the network
        /// (oldest across providers that have data) — NOT when we last polled. Drives
        /// an honest "X ago" label that ages during TTL cache-hits and failure streaks
        /// instead of resetting to "just now". nil when nothing is displayed.
        public var fetchedAt: Date?
        /// Per-provider last-success time (provider.rawValue → date) for per-group labels.
        public var fetchedAtByProvider: [String: Date]
        public init(windows: [QuotaWindow], notes: [String], fetchedAt: Date? = nil,
                    fetchedAtByProvider: [String: Date] = [:]) {
            self.windows = windows
            self.notes = notes
            self.fetchedAt = fetchedAt
            self.fetchedAtByProvider = fetchedAtByProvider
        }
    }

    private let cacheTTL: TimeInterval
    private let failureTTL: TimeInterval
    // Last *successful* windows per provider, so a transient failure (429, 5xx,
    // network blip) keeps showing the previous reading instead of blanking out.
    private var lastClaude: [QuotaWindow] = []
    private var lastCodex: [QuotaWindow] = []
    // When each provider's currently-held windows were actually fetched (a real
    // success). Updated ONLY on the success branch of merge(); a transient failure
    // keeps the old timestamp so the data's true age stays visible.
    private var claudeSuccessAt: Date?
    private var codexSuccessAt: Date?
    private var cachedWindows: [QuotaWindow] = []
    private var cachedNotes: [String] = []
    private var cachedFetchedAt: Date?
    private var cachedFetchedByProvider: [String: Date] = [:]
    private var lastFetch: Date?

    public init(cacheTTL: TimeInterval = 300, failureTTL: TimeInterval = 30) {
        self.cacheTTL = cacheTTL
        self.failureTTL = failureTTL
    }

    /// Returns the cached result when still fresh, otherwise fetches Claude and
    /// Codex concurrently and updates the cache. `force` bypasses the TTL (used by
    /// the manual refresh button).
    public func current(now: Date = Date(), force: Bool = false) async -> Result {
        if !force, let last = lastFetch, now.timeIntervalSince(last) < ttl() {
            // Cache hit: no network this poll, so the freshness clock must NOT advance.
            return Result(windows: cachedWindows, notes: cachedNotes,
                          fetchedAt: cachedFetchedAt, fetchedAtByProvider: cachedFetchedByProvider)
        }

        async let claude = ClaudeQuotaFetcher().fetch(now: now)
        async let codex = CodexQuotaFetcher().fetch(now: now)
        let (claudeResult, codexResult) = await (claude, codex)

        var notes: [String] = []
        let claudeWindows = merge(claudeResult, into: &lastClaude, successAt: &claudeSuccessAt, now: now, notes: &notes)
        let codexWindows = merge(codexResult, into: &lastCodex, successAt: &codexSuccessAt, now: now, notes: &notes)

        cachedWindows = claudeWindows + codexWindows
        cachedNotes = notes
        lastFetch = now

        // Freshness reflects each provider's last *success*; the global label uses the
        // oldest among providers that currently show data ("at least this stale").
        var byProvider: [String: Date] = [:]
        if !claudeWindows.isEmpty, let t = claudeSuccessAt { byProvider[Provider.claude.rawValue] = t }
        if !codexWindows.isEmpty, let t = codexSuccessAt { byProvider[Provider.codex.rawValue] = t }
        cachedFetchedByProvider = byProvider
        cachedFetchedAt = byProvider.values.min()

        return Result(windows: cachedWindows, notes: notes,
                      fetchedAt: cachedFetchedAt, fetchedAtByProvider: byProvider)
    }

    /// Resolve one provider's fetch against its last-good cache:
    /// - success (non-empty) → adopt and remember it
    /// - auth failure (401/403/expired) → drop the stale data and surface the note
    /// - transient failure → keep the last-good silently (only surface a note if we
    ///   have nothing cached yet)
    private func merge(_ result: QuotaFetchResult, into last: inout [QuotaWindow],
                       successAt: inout Date?, now: Date, notes: inout [String]) -> [QuotaWindow] {
        if !result.windows.isEmpty {
            last = result.windows
            successAt = now                 // a real fetch advances the freshness clock
        } else if result.authFailed {
            last = []
            successAt = nil
            if let n = result.note { notes.append(n) }
        } else if last.isEmpty, let n = result.note {
            notes.append(n)
        }
        // Transient failure with cached data: keep `last` AND its old successAt (stale).
        return last
    }

    /// Shorter retry window only when we have *nothing* cached at all.
    private func ttl() -> TimeInterval {
        cachedWindows.isEmpty ? failureTTL : cacheTTL
    }
}
