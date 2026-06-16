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

            // Get file signature
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  let size = attrs[.size] as? Int64 else {
                continue
            }
            let sig = FileSignature(mtime: mtime, size: size)

            // Check cache hit
            if let entry = cache[path],
               entry.sig.mtime == sig.mtime,
               entry.sig.size == sig.size {
                results += entry.records.map(rawRecord(from:))
                continue
            }

            // Cache miss — parse
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

    private func rawRecord(from c: CachedRecord) -> RawRecord {
        RawRecord(
            provider: Provider(rawValue: c.provider) ?? .claude,
            model: c.model,
            timestamp: Date(timeIntervalSince1970: c.timestamp),
            cwd: c.cwd,
            tokens: TokenBreakdown(input: c.input, output: c.output, cacheRead: c.cacheRead, cacheWrite: c.cacheWrite, reasoning: c.reasoning),
            toolName: c.toolName,
            toolNames: c.toolNames,
            messageId: c.messageId,
            sessionKey: c.sessionKey,
            hasInterrupt: c.hasInterrupt
        )
    }

    private func cachedRecord(from r: RawRecord) -> CachedRecord {
        CachedRecord(
            provider: r.provider.rawValue,
            model: r.model,
            timestamp: r.timestamp.timeIntervalSince1970,
            cwd: r.cwd,
            input: r.tokens.input,
            output: r.tokens.output,
            cacheRead: r.tokens.cacheRead,
            cacheWrite: r.tokens.cacheWrite,
            reasoning: r.tokens.reasoning,
            toolName: r.toolName,
            toolNames: r.toolNames,
            messageId: r.messageId,
            sessionKey: r.sessionKey,
            hasInterrupt: r.hasInterrupt
        )
    }

    // MARK: Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func saveCache() {
        // Ensure directory exists
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL)
    }
}
