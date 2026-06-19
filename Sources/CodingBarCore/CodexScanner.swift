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
        // Memory-map: the OS pages the file in/out so a large rollout doesn't pin its
        // whole size in resident memory, and forEachLine decodes one line at a time.
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return []
        }

        let sessionKey = fileURL.deletingPathExtension().lastPathComponent
        let iso = ISO8601Parser()

        var cwd = ""
        var model = "unknown"
        var records: [RawRecord] = []
        // Codex `token_count` events carry a CUMULATIVE `total_token_usage` snapshot
        // that grows every turn. We used to sum the per-turn `last_token_usage`, but
        // replayed/duplicate events inflated that sum past the session's real total
        // (measured ~1.3–1.8× across this machine's logs). Taking the positive delta
        // of `total_token_usage` reconstructs each turn's true increment, drops
        // duplicate snapshots (Δ≤0), and preserves per-turn timestamps for bucketing.
        var prevInput = 0, prevCached = 0, prevOutput = 0, prevReasoning = 0
        // Codex tool calls (`function_call` response items, e.g. exec_command) arrive
        // before the turn's `token_count`; buffer their names and attach them to the
        // next emitted record so the habits tool-mix counts Codex, not just Claude.
        var pendingTools: [String] = []

        data.forEachLine { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                return
            }

            guard let type = obj["type"] as? String else { return }

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

            case "response_item":
                if let payload = obj["payload"] as? [String: Any],
                   payload["type"] as? String == "function_call",
                   let name = payload["name"] as? String {
                    pendingTools.append(name)
                }

            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" else {
                    return
                }

                // Every non-null `info` carries `total_token_usage` (verified across
                // every real event); the per-turn `last_token_usage` is no longer used.
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else {
                    return
                }

                let curInput     = total["input_tokens"] as? Int ?? 0
                let curCached    = total["cached_input_tokens"] as? Int ?? 0
                let curOutput    = total["output_tokens"] as? Int ?? 0
                let curReasoning = total["reasoning_output_tokens"] as? Int ?? 0

                // Δ of the cumulative counter. A counter that *drops* (post-compaction
                // reset) starts a fresh baseline so those turns aren't lost.
                let reset = curInput < prevInput || curOutput < prevOutput
                let dInput     = reset ? curInput     : curInput - prevInput
                let dCached    = reset ? curCached    : curCached - prevCached
                let dOutput    = reset ? curOutput    : curOutput - prevOutput
                let dReasoning = reset ? curReasoning : curReasoning - prevReasoning
                prevInput = curInput; prevCached = curCached
                prevOutput = curOutput; prevReasoning = curReasoning

                // No forward progress → a replayed/duplicate snapshot, nothing billed.
                guard dInput + dOutput > 0 else { return }

                // Unparseable/absent timestamp → DROP rather than fall back to Date().
                // Clear this turn's buffered tools too (they belong to the dropped record,
                // not the next one). NOTE: the Δ≤0 guard above must NOT clear — that's a
                // replay of the same turn whose tools still belong to the eventual record.
                guard let timestamp = iso.date(from: obj["timestamp"] as? String ?? payload["timestamp"] as? String) else {
                    pendingTools.removeAll(keepingCapacity: true); return
                }

                // Codex: input_tokens INCLUDES cached; net fresh input = input − cached.
                // Clamp the cached delta at 0 first so a (data-wise unreachable) cached
                // dip without a full reset can never inflate net input above dInput.
                let netInput = max(0, dInput - max(0, dCached))

                let tokens = TokenBreakdown(
                    input: netInput,
                    output: dOutput,
                    cacheRead: max(0, dCached),
                    cacheWrite: 0,
                    reasoning: max(0, dReasoning)
                )

                let record = RawRecord(
                    provider: .codex,
                    model: model,
                    timestamp: timestamp,
                    cwd: cwd,
                    tokens: tokens,
                    toolName: pendingTools.first,
                    toolNames: pendingTools,
                    messageId: nil,
                    sessionKey: sessionKey,
                    hasInterrupt: false
                )
                records.append(record)
                pendingTools.removeAll(keepingCapacity: true)

            default:
                break
            }
        }

        return records
    }
}
