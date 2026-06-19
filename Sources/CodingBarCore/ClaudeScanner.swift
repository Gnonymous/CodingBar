import Foundation

public enum ClaudeScanner {

    static func scan() -> (records: [RawRecord], seenIds: Set<String>) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return ([], [])
        }

        let scanner = Scanner()
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
        let iso = makeISO8601Formatter()

        var records: [RawRecord] = []

        data.forEachLine { line in
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

            let tsString = obj["timestamp"] as? String ?? ""
            let timestamp = iso.date(from: tsString) ?? Date()

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
                hasInterrupt: trimmed.contains("[Request interrupted")
            )
            records.append(record)
        }

        return records
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
