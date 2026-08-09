import Foundation

public enum CodexScanner {

    /// Token usage records only. Codex *quota* now comes from the live usage API
    /// (see `CodexQuotaFetcher`), not from the `rate_limits` snapshots embedded in
    /// the rollout logs, so this no longer does the second rate-limit pass.
    /// Accepts a pre-created `Scanner` shared with `ClaudeScanner` so the on-disk cache
    /// is loaded once per Aggregator.run() — see ClaudeScanner.scan for the rationale.
    static func scan(scanner: Scanner) -> [RawRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir = home
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return []
        }

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
        var prevInput = 0, prevCached = 0, prevCacheWrite = 0, prevOutput = 0, prevReasoning = 0
        // Codex tool calls (`function_call` response items, e.g. exec_command) arrive
        // before the turn's `token_count`; buffer their names and attach them to the
        // next emitted record so the habits tool-mix counts Codex, not just Claude.
        var pendingTools: [String] = []

        // Drain JSONSerialization's autoreleased NSDictionary/NSString tree per line —
        // see ClaudeScanner for the rationale. Rollouts are commonly the largest jsonl
        // files in the corpus, so this is even more important here than for Claude.
        data.forEachLine { line in
            autoreleasepool {
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
                // Adopt the model on EVERY turn_context, not only the first. A Codex
                // session can switch model mid-stream (`/model`), and each later
                // token_count delta must be priced/attributed under the model in
                // effect at that turn — freezing on the first one mis-prices every
                // turn after a switch and skews model composition + fuel classification.
                if let payload = obj["payload"] as? [String: Any],
                   let m = payload["model"] as? String, !m.isEmpty {
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
                // every real event). Its positive delta remains the billable token count;
                // `last_token_usage.input_tokens` is retained only as the absolute prompt
                // size needed to select OpenAI's >272K long-context price tier.
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else {
                    return
                }
                let last = info["last_token_usage"] as? [String: Any]
                let billingInputTokens = (last?["input_tokens"] as? Int).map { max(0, $0) }

                let curInput      = total["input_tokens"] as? Int ?? 0
                let curCached     = total["cached_input_tokens"] as? Int ?? 0
                let curCacheWrite = total["cache_write_input_tokens"] as? Int ?? 0
                let curOutput     = total["output_tokens"] as? Int ?? 0
                let curReasoning  = total["reasoning_output_tokens"] as? Int ?? 0

                // Δ of the cumulative counter. A counter that *drops* (post-compaction
                // reset) starts a fresh baseline so those turns aren't lost.
                let reset = curInput < prevInput || curOutput < prevOutput
                let dInput      = reset ? curInput      : curInput - prevInput
                let dCached     = reset ? curCached     : curCached - prevCached
                let dCacheWrite = reset ? curCacheWrite : curCacheWrite - prevCacheWrite
                let dOutput     = reset ? curOutput     : curOutput - prevOutput
                let dReasoning  = reset ? curReasoning  : curReasoning - prevReasoning
                prevInput = curInput; prevCached = curCached; prevCacheWrite = curCacheWrite
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

                // Codex input_tokens includes both cached reads and cache writes. Keep all
                // three buckets disjoint so both total tokens and model-specific cache rates
                // remain correct. Negative subset deltas are treated as zero after a reset.
                let cacheRead = max(0, dCached)
                let cacheWrite = max(0, dCacheWrite)
                let netInput = max(0, dInput - cacheRead - cacheWrite)

                // Codex's output_tokens already includes reasoning_output_tokens. Split
                // the subset into its own bucket so TokenBreakdown.total and Pricing.cost
                // count it once rather than adding the same reasoning tokens twice.
                let reasoning = min(max(0, dReasoning), max(0, dOutput))
                let tokens = TokenBreakdown(
                    input: netInput,
                    output: max(0, dOutput - reasoning),
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    reasoning: reasoning
                )

                let record = RawRecord(
                    provider: .codex,
                    model: model,
                    timestamp: timestamp,
                    cwd: cwd,
                    tokens: tokens,
                    billingInputTokens: billingInputTokens,
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
        }

        return records
    }
}
