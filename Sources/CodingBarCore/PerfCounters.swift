import Foundation

/// Counters that let `--self-test` assert a refresh pass *reuses* work instead of
/// redoing it. Two steps dominated the pass and both rebuilt state that had not
/// changed: decoding the on-disk scan cache (745 ms of ~2 s here, 10 MB of binary
/// plist, once per pass) and recounting 30 days of `git log --numstat` per repo
/// (951 ms). Both are now memoized, and a regression in either is silent — the app
/// still shows correct numbers, it just burns a core every 30 seconds again. These
/// counters make that regression assertable from the CLT-only self-test, which cannot
/// reach the internal types directly.
public enum PerfCounters {
    /// Times the scan cache has been read from disk this process. Should be 1.
    public static var scanCacheDiskReads: Int { Scanner.diskDecodeCount }

    /// Times the git ranges were recomputed rather than served from memory.
    public static var gitRangeRecomputes: Int { GitCorrelator.recomputeCount }

    /// The window a computed set of git ranges stays valid for.
    public static var gitRangeTTL: TimeInterval { GitCorrelator.rangeTTL }

    /// Drive the memoized git-range path directly, without needing a real repository —
    /// a non-repo path yields empty ranges but still exercises the cache decision.
    public static func probeGitRanges(at path: String, now: Date) {
        _ = GitCorrelator.buildRanges(cwds: [path], now: now)
    }
}
