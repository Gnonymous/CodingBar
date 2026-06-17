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
        public init(windows: [QuotaWindow], notes: [String]) {
            self.windows = windows
            self.notes = notes
        }
    }

    private let cacheTTL: TimeInterval
    private let failureTTL: TimeInterval
    // Last *successful* windows per provider, so a transient failure (429, 5xx,
    // network blip) keeps showing the previous reading instead of blanking out.
    private var lastClaude: [QuotaWindow] = []
    private var lastCodex: [QuotaWindow] = []
    private var cachedWindows: [QuotaWindow] = []
    private var cachedNotes: [String] = []
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
            return Result(windows: cachedWindows, notes: cachedNotes)
        }

        async let claude = ClaudeQuotaFetcher().fetch(now: now)
        async let codex = CodexQuotaFetcher().fetch(now: now)
        let (c, x) = await (claude, codex)

        var notes: [String] = []
        // Claude first, then Codex (panel renders them grouped in order).
        let claudeWindows = merge(c, into: &lastClaude, notes: &notes)
        let codexWindows = merge(x, into: &lastCodex, notes: &notes)

        cachedWindows = claudeWindows + codexWindows
        cachedNotes = notes
        lastFetch = now
        return Result(windows: cachedWindows, notes: notes)
    }

    /// Resolve one provider's fetch against its last-good cache:
    /// - success (non-empty) → adopt and remember it
    /// - auth failure (401/403/expired) → drop the stale data and surface the note
    /// - transient failure → keep the last-good silently (only surface a note if we
    ///   have nothing cached yet)
    private func merge(_ result: QuotaFetchResult, into last: inout [QuotaWindow], notes: inout [String]) -> [QuotaWindow] {
        if !result.windows.isEmpty {
            last = result.windows
        } else if result.authFailed {
            last = []
            if let n = result.note { notes.append(n) }
        } else if last.isEmpty, let n = result.note {
            notes.append(n)
        }
        return last
    }

    /// Shorter retry window only when we have *nothing* cached at all.
    private func ttl() -> TimeInterval {
        cachedWindows.isEmpty ? failureTTL : cacheTTL
    }
}
