import Foundation

public enum ClaudeScanner {

    /// Accepts a pre-created `Scanner` so the same on-disk cache is loaded ONCE per
    /// Aggregator.run() and shared with the Codex scan, instead of each provider
    /// instantiating its own Scanner and re-decoding the same cache file twice (a real
    /// peak-memory cost — the cache decode goes through `JSONSerialization`, which keeps
    /// a full NSDictionary tree alive alongside the Swift struct).
    static func scan(scanner: Scanner) -> (records: [RawRecord], seenIds: Set<String>) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return ([], [])
        }

        var seenIds = Set<String>()
        var allRecords: [RawRecord] = []

        let records = scanner.scan(directory: projectsDir) { fileURL in
            parseFile(fileURL)
        }

        // Dedup by message.id across all files
        for record in records {
            if let mid = record.messageId {
                guard seenIds.insert(mid).inserted else { continue }
            }
            allRecords.append(record)
        }

        return (allRecords, seenIds)
    }

    static func parseFile(_ fileURL: URL) -> [RawRecord] {
        // Memory-map: the OS pages the file in/out so a large transcript doesn't pin
        // its whole size in resident memory, and forEachLine decodes one line at a time.
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return []
        }

        let sessionKey = fileURL.deletingPathExtension().lastPathComponent
        let iso = ISO8601Parser()

        var records: [RawRecord] = []

        // Drain JSONSerialization's autoreleased NSDictionary/NSString tree per line.
        // Without this, every parsed line's NSObject tree piles up in the pool until the
        // run loop drains it — and Aggregator.run() runs in a detached Task with no
        // natural drain point, so a single big file would inflate RSS by hundreds of MB
        // of "virtual" autoreleased intermediates before any of them are reclaimed.
        data.forEachLine { line in
            autoreleasepool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                return
            }

            guard let type = obj["type"] as? String, type == "assistant" else { return }

            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                return
            }

            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let cacheWrite  = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead   = usage["cache_read_input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0

            guard inputTokens + outputTokens + cacheRead + cacheWrite > 0 else { return }

            let model = message["model"] as? String ?? "unknown"
            let messageId = message["id"] as? String

            // Unparseable/absent timestamp → DROP rather than fall back to Date()
            // (which would mis-bucket the record into "today" and inflate it).
            guard let timestamp = iso.date(from: obj["timestamp"] as? String) else { return }

            let cwd = obj["cwd"] as? String ?? ""

            // Collect ALL tool_use names in this turn's content array
            var allToolNames: [String] = []
            if let contentArray = message["content"] as? [[String: Any]] {
                for item in contentArray {
                    if let itemType = item["type"] as? String,
                       itemType == "tool_use",
                       let name = item["name"] as? String {
                        allToolNames.append(name)
                    }
                }
            }
            let toolName = allToolNames.first

            // Usage attribution: Claude Code tags each assistant line (top-level, alongside
            // `usage`) with what drove the turn — a skill, subagent, plugin, or MCP server.
            // These power the `/usage`-style "what's contributing" breakdowns. Absent on
            // plain coding turns, so most records carry an empty Attribution.
            func attr(_ key: String) -> String? {
                guard let v = obj[key] as? String, !v.isEmpty else { return nil }
                return v
            }
            let attribution = Attribution(
                skill: attr("attributionSkill"),
                agent: attr("attributionAgent"),
                plugin: attr("attributionPlugin"),
                mcpServer: attr("attributionMcpServer")
            )

            let tokens = TokenBreakdown(
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: 0
            )

            let record = RawRecord(
                provider: .claude,
                model: model,
                timestamp: timestamp,
                cwd: cwd,
                tokens: tokens,
                toolName: toolName,
                toolNames: allToolNames,
                messageId: messageId,
                sessionKey: sessionKey,
                hasInterrupt: trimmed.contains("[Request interrupted"),
                attribution: attribution
            )
            records.append(record)
            }
        }

        return records
    }
}
