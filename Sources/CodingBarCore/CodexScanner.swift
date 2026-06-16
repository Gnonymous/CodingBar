import Foundation

public enum CodexScanner {

    static func scan() -> (records: [RawRecord], quota: [QuotaWindow]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return ([], [])
        }

        let scanner = Scanner()
        var allRecords: [RawRecord] = []

        // We track the latest rate_limits seen across all files
        // (mtime of the file serves as a proxy for "most recent")
        var latestRateLimits: [String: Any]? = nil
        var latestRateLimitsMtime: Double = 0

        // We need to collect rate_limits while scanning; Scanner caches records but
        // not rate_limits. We do a second pass for rate_limits using the raw files
        // since they are lightweight to check.

        // First pass: use Scanner for token records
        let records = scanner.scan(directory: sessionsDir) { fileURL in
            parseFile(fileURL)
        }
        allRecords = records

        // Second pass: collect latest rate_limits from raw files (not cached by Scanner)
        if let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                      fileURL.pathExtension == "jsonl" else { continue }

                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

                // Only examine files newer than what we've seen
                if mtime <= latestRateLimitsMtime && latestRateLimits != nil { continue }

                if let rl = extractLatestRateLimits(from: fileURL) {
                    latestRateLimits = rl
                    latestRateLimitsMtime = mtime
                }
            }
        }

        let quota = buildQuota(from: latestRateLimits)
        return (allRecords, quota)
    }

    // MARK: - File parsing (for Scanner cache)

    static func parseFile(_ fileURL: URL) -> [RawRecord] {
        guard fileURL.lastPathComponent.hasPrefix("rollout-") else { return [] }
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let sessionKey = fileURL.deletingPathExtension().lastPathComponent
        let iso = makeISO8601Formatter()

        var cwd = ""
        var model = "unknown"
        var records: [RawRecord] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }

            guard let type = obj["type"] as? String else { continue }

            switch type {
            case "session_meta":
                if cwd.isEmpty,
                   let payload = obj["payload"] as? [String: Any],
                   let c = payload["cwd"] as? String {
                    cwd = c
                }

            case "turn_context":
                if model == "unknown",
                   let payload = obj["payload"] as? [String: Any],
                   let m = payload["model"] as? String {
                    model = m
                }

            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" else {
                    continue
                }

                guard let info = payload["info"] as? [String: Any],
                      let lastUsage = info["last_token_usage"] as? [String: Any] else {
                    continue
                }

                let inputTokens     = lastUsage["input_tokens"] as? Int ?? 0
                let cachedTokens    = lastUsage["cached_input_tokens"] as? Int ?? 0
                let outputTokens    = lastUsage["output_tokens"] as? Int ?? 0
                let reasoningTokens = lastUsage["reasoning_output_tokens"] as? Int ?? 0

                // Only accumulate non-zero turns
                guard inputTokens + outputTokens > 0 else { continue }

                // Extract timestamp (try from obj first, then payload)
                var timestamp = Date()
                if let tsStr = obj["timestamp"] as? String ?? payload["timestamp"] as? String {
                    timestamp = iso.date(from: tsStr) ?? Date()
                }

                // Codex: input_tokens INCLUDES cached; net = input - cached
                let netInput = max(0, inputTokens - cachedTokens)

                let tokens = TokenBreakdown(
                    input: netInput,
                    output: outputTokens,
                    cacheRead: cachedTokens,
                    cacheWrite: 0,
                    reasoning: reasoningTokens
                )

                // Update model from turn_context seen so far (may be "unknown" initially)
                let record = RawRecord(
                    provider: .codex,
                    model: model,
                    timestamp: timestamp,
                    cwd: cwd,
                    tokens: tokens,
                    toolName: nil,
                    messageId: nil,
                    sessionKey: sessionKey
                )
                records.append(record)

            default:
                break
            }
        }

        return records
    }

    // MARK: - Rate limits extraction

    private static func extractLatestRateLimits(from fileURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        var latest: [String: Any]? = nil

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }

            guard let type = obj["type"] as? String, type == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            latest = rl
        }

        return latest
    }

    // MARK: - Quota building

    private static func buildQuota(from rateLimits: [String: Any]?) -> [QuotaWindow] {
        guard let rl = rateLimits else { return [] }

        var windows: [QuotaWindow] = []

        // primary (5h window = 300 min)
        if let primary = rl["primary"] as? [String: Any],
           let usedPct = primary["used_percent"] as? Double,
           let windowMin = primary["window_minutes"] as? Int {
            let label: String
            if windowMin == 300 {
                label = "5h"
            } else {
                label = "\(windowMin)m"
            }
            let resetAt: Date?
            if let resetsTs = primary["resets_at"] as? Double {
                resetAt = Date(timeIntervalSince1970: resetsTs)
            } else {
                resetAt = nil
            }
            let remaining = max(0, min(1, 1.0 - usedPct / 100.0))
            windows.append(QuotaWindow(provider: .codex, label: label, remaining: remaining, resetAt: resetAt))
        }

        // secondary (7d/周 window = 10080 min)
        if let secondary = rl["secondary"] as? [String: Any],
           let usedPct = secondary["used_percent"] as? Double,
           let windowMin = secondary["window_minutes"] as? Int {
            let label: String
            if windowMin == 10080 {
                label = "周"
            } else if windowMin >= 1440 {
                label = "\(windowMin / 1440)d"
            } else {
                label = "\(windowMin)m"
            }
            let resetAt: Date?
            if let resetsTs = secondary["resets_at"] as? Double {
                resetAt = Date(timeIntervalSince1970: resetsTs)
            } else {
                resetAt = nil
            }
            let remaining = max(0, min(1, 1.0 - usedPct / 100.0))
            windows.append(QuotaWindow(provider: .codex, label: label, remaining: remaining, resetAt: resetAt))
        }

        return windows
    }

    // MARK: - Helpers

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
