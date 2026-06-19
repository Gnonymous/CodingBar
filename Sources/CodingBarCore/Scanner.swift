import Foundation

// MARK: - RawRecord

struct RawRecord {
    var provider: Provider
    var model: String
    var timestamp: Date
    var cwd: String
    var tokens: TokenBreakdown
    var toolName: String?       // first tool in this turn (backwards compat)
    var toolNames: [String]     // ALL tool_use names in this turn
    var messageId: String?
    var sessionKey: String      // file path stem, used for session counting
    var hasInterrupt: Bool      // true if the raw line contained "[Request interrupted"
}

// MARK: - Robust log timestamp parsing

/// Agent logs are normally fractional-second UTC ISO-8601, but a stray whole-second
/// timestamp is still valid ISO-8601. The scanners used to fall back to `Date()` when
/// the single fractional formatter failed, which silently mis-bucketed such a record
/// into "today" and inflated today's totals. This tries both shapes and returns nil
/// on failure so callers can DROP the record instead of mis-dating it. One instance
/// per parseFile call (scanning is single-threaded per Aggregator.run).
struct ISO8601Parser {
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain.formatOptions = [.withInternetDateTime]
    }
    func date(from s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

// MARK: - Scanner

final class Scanner {

    // MARK: Types

    private struct FileSignature: Codable {
        var mtime: Double
        var size: Int64
    }

    private struct CacheEntry: Codable {
        var sig: FileSignature
        var records: [CachedRecord]
    }

    /// On-disk cache is keyed by mtime+size, so a change to the *parse logic* (not the
    /// file) would otherwise keep serving records produced by the old parser. Bump this
    /// whenever a scanner's output for an unchanged file changes; a version mismatch is
    /// ignored (→ one full rescan with the new parser). v2: Codex switched from summing
    /// `last_token_usage` to the delta of `total_token_usage`.
    private static let cacheVersion = 2

    private struct CacheFile: Codable {
        var version: Int
        var entries: [String: CacheEntry]
    }

    /// Codable mirror of RawRecord (Date as TimeInterval, optionals preserved).
    private struct CachedRecord: Codable {
        var provider: String
        var model: String
        var timestamp: Double
        var cwd: String
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var reasoning: Int
        var toolName: String?
        var toolNames: [String]
        var messageId: String?
        var sessionKey: String
        var hasInterrupt: Bool
    }

    // MARK: State

    private var cache: [String: CacheEntry] = [:]
    private let cacheURL: URL

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("CodingBar") ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheURL = support.appendingPathComponent("scan-cache.json")
        loadCache()
    }

    // MARK: Public API

    func scan(directory: URL, parse: (URL) -> [RawRecord]) -> [RawRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [RawRecord] = []
        var dirty = false

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let path = fileURL.path

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  let size = attrs[.size] as? Int64 else {
                continue
            }
            let sig = FileSignature(mtime: mtime, size: size)

            if let entry = cache[path],
               entry.sig.mtime == sig.mtime,
               entry.sig.size == sig.size {
                results += entry.records.map(rawRecord(from:))
                continue
            }

            let parsed = parse(fileURL)
            let cached = CacheEntry(sig: sig, records: parsed.map(cachedRecord(from:)))
            cache[path] = cached
            dirty = true
            results += parsed
        }

        if dirty { saveCache() }
        return results
    }

    // MARK: Conversion helpers

    private func rawRecord(from cached: CachedRecord) -> RawRecord {
        RawRecord(
            provider: Provider(rawValue: cached.provider) ?? .claude,
            model: cached.model,
            timestamp: Date(timeIntervalSince1970: cached.timestamp),
            cwd: cached.cwd,
            tokens: TokenBreakdown(input: cached.input, output: cached.output, cacheRead: cached.cacheRead, cacheWrite: cached.cacheWrite, reasoning: cached.reasoning),
            toolName: cached.toolName,
            toolNames: cached.toolNames,
            messageId: cached.messageId,
            sessionKey: cached.sessionKey,
            hasInterrupt: cached.hasInterrupt
        )
    }

    private func cachedRecord(from raw: RawRecord) -> CachedRecord {
        CachedRecord(
            provider: raw.provider.rawValue,
            model: raw.model,
            timestamp: raw.timestamp.timeIntervalSince1970,
            cwd: raw.cwd,
            input: raw.tokens.input,
            output: raw.tokens.output,
            cacheRead: raw.tokens.cacheRead,
            cacheWrite: raw.tokens.cacheWrite,
            reasoning: raw.tokens.reasoning,
            toolName: raw.toolName,
            toolNames: raw.toolNames,
            messageId: raw.messageId,
            sessionKey: raw.sessionKey,
            hasInterrupt: raw.hasInterrupt
        )
    }

    // MARK: Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CacheFile.self, from: data),
              decoded.version == Scanner.cacheVersion else {
            return   // missing, unreadable, or stale-version cache → full rescan
        }
        cache = decoded.entries
    }

    private func saveCache() {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = CacheFile(version: Scanner.cacheVersion, entries: cache)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: cacheURL)
    }
}

// MARK: - Memory-friendly jsonl reading

extension Data {
    /// Iterate the file's `\n`-delimited UTF-8 lines without ever materializing the
    /// whole file as one giant `String` or a full array of per-line copies. A big or
    /// fast-growing transcript would otherwise spike to several full-size transient
    /// buffers (Data + String + components array) on every rescan; here peak extra
    /// memory is ~one line. Empty lines are skipped, matching the parsers' own
    /// trim-then-skip. A line that isn't valid UTF-8 is skipped; note this is more
    /// resilient than the old whole-file `String(data:)` decode, which dropped the
    /// *entire* file if any byte was invalid (`\n` is single-byte, so per-line decode
    /// over valid files yields exactly the same lines).
    func forEachLine(_ body: (String) -> Void) {
        let newline: UInt8 = 0x0A
        var start = startIndex
        while start < endIndex {
            let end = self[start...].firstIndex(of: newline) ?? endIndex
            if end > start, let line = String(data: self[start..<end], encoding: .utf8) {
                body(line)
            }
            start = end < endIndex ? index(after: end) : endIndex
        }
    }
}
