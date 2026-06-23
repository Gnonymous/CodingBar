import Foundation

/// All-time profile stats for the Insights tab — the Claude-Desktop-style stat-card
/// grid plus a GitHub contribution calendar. Every value is derived locally from the
/// already-scanned `RawRecord`s; this adds no new data source and no network path.
enum ProfileBuilder {

    /// Week columns in the contribution calendar. 13 weeks ≈ 90 days keeps the squares
    /// legible inside the 340pt popover instead of shrinking a full year to dust.
    static let calendarWeeks = 13

    static func build(from records: [RawRecord], now: Date) -> ProfileStats {
        guard !records.isEmpty else { return .empty }
        let cal = Calendar.current

        var sessionKeys = Set<String>()
        // Messages = assistant turns. One RawRecord is one reply; dedup by (file, messageId)
        // so a streamed/replayed line can't inflate the count. Records lacking an id (Codex
        // turns are keyed by token_count events, not message ids) each count once.
        var seenMessages = Set<String>()
        var messagesWithoutId = 0
        var totalTokens = 0
        var activeDaySet = Set<Date>()
        var hourTokens = [Int](repeating: 0, count: 24)
        // Favorite = most-frequently used model, not most tokens, so one heavy session
        // doesn't crown a model the user rarely picks.
        var modelCounts: [String: Int] = [:]
        var dayTokens: [Date: Int] = [:]

        for r in records {
            sessionKeys.insert(r.sessionKey)
            if let mid = r.messageId, !mid.isEmpty {
                seenMessages.insert(r.sessionKey + "·" + mid)
            } else {
                messagesWithoutId += 1
            }
            totalTokens += r.tokens.total
            let day = cal.startOfDay(for: r.timestamp)
            activeDaySet.insert(day)
            dayTokens[day, default: 0] += r.tokens.total
            hourTokens[cal.component(.hour, from: r.timestamp)] += r.tokens.total
            modelCounts[Pricing.normalize(model: r.model), default: 0] += 1
        }

        let peakHour: Int = {
            guard let mx = hourTokens.max(), mx > 0 else { return -1 }
            return hourTokens.firstIndex(of: mx) ?? -1
        }()

        // Stable on ties: most uses wins, then the lexicographically smaller key.
        let favorite = modelCounts.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }?.key ?? ""
        let favoriteProvider = favorite.isEmpty ? Provider.claude : Pricing.provider(forCanonicalKey: favorite)

        let (current, longest) = streaks(activeDays: activeDaySet, now: now, cal: cal)
        let calendar = contributionCalendar(dayTokens: dayTokens, now: now, cal: cal)

        return ProfileStats(
            sessions: sessionKeys.count,
            messages: seenMessages.count + messagesWithoutId,
            totalTokens: totalTokens,
            activeDays: activeDaySet.count,
            currentStreak: current,
            longestStreak: longest,
            peakHour: peakHour,
            favoriteModel: favorite,
            favoriteModelProvider: favoriteProvider,
            calendar: calendar
        )
    }

    /// (currentStreak, longestStreak) over a set of active day-starts. The current
    /// streak counts back from today; if today is inactive but yesterday is active it
    /// anchors on yesterday, so the streak doesn't read 0 first thing in the morning.
    private static func streaks(activeDays: Set<Date>, now: Date, cal: Calendar) -> (Int, Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let sorted = activeDays.sorted()

        var longest = 1, run = 1
        for i in 1..<sorted.count {
            if cal.date(byAdding: .day, value: 1, to: sorted[i - 1]) == sorted[i] { run += 1 } else { run = 1 }
            longest = max(longest, run)
        }

        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor: Date
        if activeDays.contains(today) { cursor = today }
        else if activeDays.contains(yesterday) { cursor = yesterday }
        else { return (0, longest) }

        var current = 0
        while activeDays.contains(cursor) {
            current += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return (current, longest)
    }

    /// 7 rows (Mon…Sun) × `calendarWeeks` columns of normalized 0...1 daily intensity.
    /// The rightmost column is the current week; cells in the future (later this week)
    /// are `-1` so the view leaves them blank. In-window days with no activity stay 0
    /// (rendered as the empty track level), matching GitHub's calendar.
    private static func contributionCalendar(dayTokens: [Date: Int], now: Date, cal: Calendar) -> [[Double]] {
        let today = cal.startOfDay(for: now)
        // Monday of the current week. weekday Sun=1..Sat=7 → Mon-index 0..6.
        let weekdayIdx = (cal.component(.weekday, from: today) + 5) % 7
        guard let thisMonday = cal.date(byAdding: .day, value: -weekdayIdx, to: today),
              let startMonday = cal.date(byAdding: .day, value: -7 * (calendarWeeks - 1), to: thisMonday) else {
            return []
        }
        let maxVal = dayTokens.values.max() ?? 0
        var cells = [[Double]](repeating: [Double](repeating: -1, count: calendarWeeks), count: 7)
        for col in 0..<calendarWeeks {
            for row in 0..<7 {
                guard let day = cal.date(byAdding: .day, value: col * 7 + row, to: startMonday) else { continue }
                if day > today { continue }
                let v = dayTokens[day] ?? 0
                cells[row][col] = maxVal > 0 ? min(1.0, Double(v) / Double(maxVal)) : 0
            }
        }
        return cells
    }
}
