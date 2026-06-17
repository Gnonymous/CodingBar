import Foundation

public enum CodexScanner {

    /// Token usage records only. Codex *quota* now comes from the live usage API
    /// (see `CodexQuotaFetcher`), not from the `rate_limits` snapshots embedded in
    /// the rollout logs, so this no longer does the second rate-limit pass.
    static func scan() -> [RawRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return []
        }

        let scanner = Scanner()
        return scanner.scan(directory: sessionsDir) { fileURL in
            parseFile(fileURL)
        }
    }

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

                guard inputTokens + outputTokens > 0 else { continue }

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

                let record = RawRecord(
                    provider: .codex,
                    model: model,
                    timestamp: timestamp,
                    cwd: cwd,
                    tokens: tokens,
                    toolName: nil,
                    toolNames: [],
                    messageId: nil,
                    sessionKey: sessionKey,
                    hasInterrupt: false
                )
                records.append(record)

            default:
                break
            }
        }

        return records
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
