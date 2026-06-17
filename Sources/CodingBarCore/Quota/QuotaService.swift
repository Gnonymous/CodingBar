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

        // Claude windows first, then Codex (panel renders them grouped in order).
        let windows = c.windows + x.windows
        let notes = [c.note, x.note].compactMap { $0 }

        cachedWindows = windows
        cachedNotes = notes
        lastFetch = now
        return Result(windows: windows, notes: notes)
    }

    /// Shorter retry window when the last fetch yielded nothing (likely a
    /// transient failure or missing credential), full TTL once we have data.
    private func ttl() -> TimeInterval {
        cachedWindows.isEmpty ? failureTTL : cacheTTL
    }
}
