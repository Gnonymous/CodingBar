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
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func saveCache() {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL)
    }
}
