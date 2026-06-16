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
}
