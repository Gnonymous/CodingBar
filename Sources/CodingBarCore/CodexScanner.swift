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

        let records = scanner.scan(directory: sessionsDir) { fileURL in
            parseFile(fileURL)
        }
        var seenResponses = Set<String>()
        return records.filter { record in
            guard let id = record.messageId else { return true }
            return seenResponses.insert(id).inserted
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
        // Modern rollouts write one token_usage_record per response, followed by a
        // token_count snapshot of the same usage. Once the former appears, the latter
        // must be ignored. Older rollouts only have token_count; their cumulative
        // counter may already include earlier files, so the first request (or a reset)
        // must come from last_token_usage, not the cumulative total.
        var hasModernUsage = false
        var seenResponses = Set<String>()
        var previousTotal: [String: Any]?
        // Codex tool calls (`function_call` response items, e.g. exec_command) arrive
        // before the turn's usage record; buffer their names and attach them to the
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

            case "token_usage_record":
                guard let payload = obj["payload"] as? [String: Any],
                      let usage = payload["usage"] as? [String: Any] else { return }
                let responseID = (payload["response_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let responseID, seenResponses.contains(responseID) {
                    pendingTools.removeAll(keepingCapacity: true)
                    return
                }
                guard let timestamp = iso.date(from: obj["timestamp"] as? String) else {
                    pendingTools.removeAll(keepingCapacity: true)
                    return
                }
                guard let record = makeRecord(usage: usage, billingInputTokens: usage["input_tokens"] as? Int,
                                              timestamp: timestamp, responseID: responseID) else {
                    pendingTools.removeAll(keepingCapacity: true)
                    return
                }
                if let responseID { _ = seenResponses.insert(responseID) }
                hasModernUsage = true
                records.append(record)
                pendingTools.removeAll(keepingCapacity: true)

            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" else {
                    return
                }
                if hasModernUsage { return }
                guard let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any] else {
                    return
                }
                let last = info["last_token_usage"] as? [String: Any]
                let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                            "output_tokens", "reasoning_output_tokens"]
                let reset = previousTotal.map { previous in
                    keys.contains { (total[$0] as? Int ?? 0) < (previous[$0] as? Int ?? 0) }
                } ?? true
                let usage: [String: Any]?
                if reset {
                    usage = last
                } else {
                    var delta: [String: Any] = [:]
                    for key in keys {
                        delta[key] = (total[key] as? Int ?? 0) - (previousTotal?[key] as? Int ?? 0)
                    }
                    usage = delta
                }
                previousTotal = total
                guard let usage,
                      (usage["input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0) > 0 else {
                    return
                }

                // Unparseable/absent timestamp → DROP rather than fall back to Date().
                // Clear this turn's buffered tools too (they belong to the dropped record,
                // not the next one). NOTE: the Δ≤0 guard above must NOT clear — that's a
                // replay of the same turn whose tools still belong to the eventual record.
                guard let timestamp = iso.date(from: obj["timestamp"] as? String ?? payload["timestamp"] as? String) else {
                    pendingTools.removeAll(keepingCapacity: true); return
                }

                if let record = makeRecord(usage: usage, billingInputTokens: last?["input_tokens"] as? Int,
                                           timestamp: timestamp, responseID: nil) {
                    records.append(record)
                }
                pendingTools.removeAll(keepingCapacity: true)

            default:
                break
            }
            }
        }

        return records

        func makeRecord(usage: [String: Any], billingInputTokens: Int?, timestamp: Date,
                        responseID: String?) -> RawRecord? {
            let totalInput = max(0, usage["input_tokens"] as? Int ?? 0)
            let cacheRead = max(0, usage["cached_input_tokens"] as? Int ?? 0)
            let cacheWrite = max(0, usage["cache_write_input_tokens"] as? Int ?? 0)
            let totalOutput = max(0, usage["output_tokens"] as? Int ?? 0)
            guard totalInput + totalOutput > 0 else { return nil }
            let reasoning = min(max(0, usage["reasoning_output_tokens"] as? Int ?? 0), totalOutput)
            let tokens = TokenBreakdown(input: max(0, totalInput - cacheRead - cacheWrite),
                                        output: totalOutput - reasoning, cacheRead: cacheRead,
                                        cacheWrite: cacheWrite, reasoning: reasoning)
            return RawRecord(provider: .codex, model: model, timestamp: timestamp, cwd: cwd,
                             tokens: tokens, billingInputTokens: billingInputTokens.map { max(0, $0) },
                             toolName: pendingTools.first, toolNames: pendingTools,
                             messageId: responseID, sessionKey: sessionKey, hasInterrupt: false)
        }
    }
}
