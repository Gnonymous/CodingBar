import Foundation

// MARK: - Fuel pillar: live context-window gauge for the most-recent Claude session.

enum FuelCalculator {

    // Maximum context window by model family
    static func maxTokens(forModel model: String) -> Int {
        let lower = model.lowercased()
        if lower.contains("[1m]") || lower.contains("-1m") || lower.contains(" 1m") {
            return 1_000_000   // 1M-context variants (e.g. claude-opus-4-8[1m])
        }
        return 200_000  // default Claude context window
    }

    // MARK: - FuelGauge

    /// Build a FuelGauge from already-parsed Claude records.
    /// Returns (gauge, active, throughput).
    static func build(
        from claudeRecords: [RawRecord],
        now: Date
    ) -> (gauge: FuelGauge?, active: Bool, throughput: Double) {

        // Find the most-recently-modified Claude session file
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return (nil, false, 0)
        }

        var latestMtime: Date = .distantPast
        var latestFileURL: URL? = nil

        if let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if mtime > latestMtime {
                    latestMtime = mtime
                    latestFileURL = fileURL
                }
            }
        }

        guard let sessionURL = latestFileURL else {
            return (nil, false, 0)
        }

        // Active = modified within last 90 seconds
        let isActive = now.timeIntervalSince(latestMtime) <= 90

        // Parse that session file to get per-turn data for fuel & throughput
        let sessionRecords = claudeRecords.filter {
            $0.sessionKey == sessionURL.deletingPathExtension().lastPathComponent
        }

        guard !sessionRecords.isEmpty else {
            return (nil, isActive, 0)
        }

        // Sort by timestamp
        let sorted = sessionRecords.sorted { $0.timestamp < $1.timestamp }

        // usedTokens = input context size from the latest turn
        // The best proxy is: last turn's input_tokens + cache_read + cache_creation
        // (this is the full context fed to the model on that turn)
        let last = sorted.last!
        let usedTokens = last.tokens.input + last.tokens.cacheRead + last.tokens.cacheWrite
        // Detect 1M-context models even when the model string lacks the marker:
        // if the live context already exceeds the assumed window, it must be larger.
        var maxTok = maxTokens(forModel: last.model)
        if usedTokens > maxTok { maxTok = 1_000_000 }

        // Estimate remaining turns from average context GROWTH per turn so far
        // (total context / turns ≈ what each turn adds), far more realistic than
        // using output tokens alone.
        let turns = max(sorted.count, 1)
        let avgGrowthPerTurn = max(usedTokens / turns, 1)
        let remaining = max(0, maxTok - usedTokens)
        let estRemainingTurns = remaining / avgGrowthPerTurn

        // Throughput: tokens/sec based on last minute of activity
        var throughput: Double = 0
        if isActive {
            let oneMinuteAgo = now.addingTimeInterval(-60)
            let recentTurns = sorted.filter { $0.timestamp >= oneMinuteAgo }
            let recentTokens = recentTurns.reduce(0) { $0 + $1.tokens.output }
            let window = min(60.0, now.timeIntervalSince(oneMinuteAgo))
            if window > 0 && recentTokens > 0 {
                throughput = Double(recentTokens) / window
            }
        }

        // Session name = last path component of cwd, or "session"
        let cwd = last.cwd
        let sessionName = cwd.isEmpty ? "session"
            : URL(fileURLWithPath: cwd).lastPathComponent

        let gauge = FuelGauge(
            sessionName: sessionName,
            usedTokens: usedTokens,
            maxTokens: maxTok,
            estRemainingTurns: estRemainingTurns
        )

        return (gauge, isActive, throughput)
    }

    // MARK: - Live sessions + burn rate

    /// Build the list of parallel live sessions and the current $/minute burn rate.
    /// A session is "live" if its latest record is within 90s of `now`. Burn rate is
    /// the cost of all tokens (any provider) consumed in the last 60 seconds.
    static func liveSessions(
        claudeRecords: [RawRecord],
        codexRecords: [RawRecord],
        now: Date
    ) -> (sessions: [LiveSession], burnPerMin: Double) {

        let minuteAgo = now.addingTimeInterval(-60)

        // Burn rate: $ spent over the last minute (≈ $/min).
        var burn: Double = 0
        for r in claudeRecords where r.timestamp >= minuteAgo && r.timestamp <= now {
            burn += Pricing.cost(model: r.model, tokens: r.tokens)
        }
        for r in codexRecords where r.timestamp >= minuteAgo && r.timestamp <= now {
            burn += Pricing.cost(model: r.model, tokens: r.tokens)
        }

        // Group Claude records by session; surface those active within 90s.
        var bySession: [String: [RawRecord]] = [:]
        for r in claudeRecords where !r.sessionKey.isEmpty {
            bySession[r.sessionKey, default: []].append(r)
        }

        var sessions: [LiveSession] = []
        for (key, recs) in bySession {
            // Skip sidecar transcripts (sub-agent / workflow logs live *under* a
            // project dir but aren't user-facing coding sessions).
            if key.hasPrefix("agent-") { continue }

            let sorted = recs.sorted { $0.timestamp < $1.timestamp }
            guard let last = sorted.last,
                  now.timeIntervalSince(last.timestamp) <= 90 else { continue }

            let used = last.tokens.input + last.tokens.cacheRead + last.tokens.cacheWrite
            var maxTok = maxTokens(forModel: last.model)
            if used > maxTok { maxTok = 1_000_000 }

            let recentOut = sorted.filter { $0.timestamp >= minuteAgo }
                .reduce(0) { $0 + $1.tokens.output }
            let tput = recentOut > 0 ? Double(recentOut) / 60.0 : 0

            let mkey = Pricing.normalize(model: last.model)
            let name = last.cwd.isEmpty ? "session"
                : URL(fileURLWithPath: last.cwd).lastPathComponent

            sessions.append(LiveSession(
                name: name,
                model: Pricing.displayName(forCanonicalKey: mkey),
                provider: Pricing.provider(forCanonicalKey: mkey),
                usedTokens: used,
                maxTokens: maxTok,
                throughput: tput
            ))
        }

        // Collapse multiple session files for the same project into one row
        // (a user thinks in projects, not transcript files). Throughput sums;
        // context shows the fullest; model/provider come from the busiest one.
        var merged: [String: LiveSession] = [:]
        var order: [String] = []
        for s in sessions.sorted(by: { $0.throughput > $1.throughput }) {
            if var m = merged[s.name] {
                m.throughput += s.throughput
                if Double(s.usedTokens) / Double(max(s.maxTokens, 1))
                    > Double(m.usedTokens) / Double(max(m.maxTokens, 1)) {
                    m.usedTokens = s.usedTokens; m.maxTokens = s.maxTokens
                }
                merged[s.name] = m
            } else {
                merged[s.name] = s
                order.append(s.name)
            }
        }
        let deduped = order.compactMap { merged[$0] }.sorted { $0.throughput > $1.throughput }
        return (Array(deduped.prefix(5)), burn)
    }
}
