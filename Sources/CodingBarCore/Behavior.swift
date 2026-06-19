import Foundation

enum Behavior {

    // MARK: - Tool classification

    /// Map a tool name to one of the five ToolMix buckets. Covers Claude tool names
    /// and Codex `function_call` names (exec_command/write_stdin run a shell, so they
    /// land in `run`; Codex edits files *through* exec_command, so there's no separate
    /// write bucket for it).
    static func bucket(toolName: String) -> WritableKeyPath<ToolMix, Int> {
        switch toolName {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return \.write
        case "Read", "Grep", "Glob", "LS", "view_image":
            return \.read
        case "Bash", "exec_command", "write_stdin":
            return \.run
        case "WebSearch", "WebFetch":
            return \.search
        default:
            return \.other
        }
    }

    static func toolMix(from records: [RawRecord], todayStart: Date, now: Date) -> ToolMix {
        var mix = ToolMix()
        for r in records {
            guard r.timestamp >= todayStart, r.timestamp <= now else { continue }
            for name in r.toolNames {
                let kp = bucket(toolName: name)
                mix[keyPath: kp] += 1
            }
        }
        return mix
    }

    // MARK: - Rhythm (all-time Claude sessions)

    static func rhythm(from records: [RawRecord]) -> Rhythm {
        // Group Claude records by sessionKey
        var sessions: [String: (count: Int, minTS: Date, maxTS: Date, hasInterrupt: Bool)] = [:]
        for r in records where r.provider == .claude {
            var s = sessions[r.sessionKey] ?? (count: 0, minTS: r.timestamp, maxTS: r.timestamp, hasInterrupt: false)
            s.count += 1
            if r.timestamp < s.minTS { s.minTS = r.timestamp }
            if r.timestamp > s.maxTS { s.maxTS = r.timestamp }
            if r.hasInterrupt { s.hasInterrupt = true }
            sessions[r.sessionKey] = s
        }

        guard !sessions.isEmpty else { return Rhythm() }

        let values = Array(sessions.values)
        let totalTurns = values.reduce(0) { $0 + $1.count }
        let turnsPerSession = Double(totalTurns) / Double(values.count)

        let totalMinutes = values.reduce(0.0) { acc, s in
            acc + s.maxTS.timeIntervalSince(s.minTS) / 60.0
        }
        let avgMinutes = totalMinutes / Double(values.count)

        let interruptedCount = values.filter { $0.hasInterrupt }.count
        let interruptRate = Double(interruptedCount) / Double(values.count)

        return Rhythm(
            turnsPerSession: (turnsPerSession * 10).rounded() / 10,
            avgMinutes: (avgMinutes * 10).rounded() / 10,
            interruptRate: (interruptRate * 1000).rounded() / 1000
        )
    }

    // MARK: - Heatmap (last 7 days, 7 rows Mon-Sun × 12 cols 2h buckets)

    static func heatmap(from records: [RawRecord], now: Date) -> Heatmap {
        let cal = Calendar.current
        guard let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) else {
            return Heatmap(cells: Array(repeating: Array(repeating: 0, count: 12), count: 7), peakLabel: "")
        }

        var grid: [[Int]] = Array(repeating: Array(repeating: 0, count: 12), count: 7)

        for r in records {
            guard r.timestamp >= sevenDaysAgo && r.timestamp <= now else { continue }
            let weekday = cal.component(.weekday, from: r.timestamp)
            // Convert Sunday=1..Saturday=7 → Mon=0..Sun=6
            let row = (weekday + 5) % 7
            let hour = cal.component(.hour, from: r.timestamp)
            let col = min(hour / 2, 11)   // 0=00:00-02:00, ..., 11=22:00-24:00
            let volume = r.tokens.total
            grid[row][col] += volume
        }

        var maxVal = 0
        var peakCol = 0
        for row in 0..<7 {
            for col in 0..<12 {
                if grid[row][col] > maxVal {
                    maxVal = grid[row][col]
                    peakCol = col
                }
            }
        }

        let normalized: [[Double]] = grid.map { row in
            row.map { val in
                maxVal > 0 ? min(1.0, Double(val) / Double(maxVal)) : 0
            }
        }

        let startHour = peakCol * 2
        let endHour = startHour + 2
        let peakLabel: String
        if maxVal > 0 {
            peakLabel = String(format: "%02d:00–%02d:00", startHour, endHour == 24 ? 24 : endHour)
        } else {
            peakLabel = ""
        }

        return Heatmap(cells: normalized, peakLabel: peakLabel)
    }

    // MARK: - Entry point

    static func build(from records: [RawRecord], todayStart: Date, now: Date) -> Habits {
        let mix = toolMix(from: records, todayStart: todayStart, now: now)
        let rhy = rhythm(from: records)
        let heat = heatmap(from: records, now: now)
        return Habits(toolMix: mix, rhythm: rhy, heatmap: heat)
    }
}
