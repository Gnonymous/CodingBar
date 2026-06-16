import Foundation

// MARK: - Forecast pillar: linear-extrapolate Codex weekly quota depletion.

enum Forecaster {

    // MARK: - Quota history persistence

    private struct QuotaSample: Codable {
        var date: Double        // timeIntervalSince1970
        var provider: String
        var label: String
        var remaining: Double   // 0...1
    }

    private static var historyURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("CodingBar")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("quota-history.json")
    }

    private static func loadHistory() -> [QuotaSample] {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([QuotaSample].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveHistory(_ samples: [QuotaSample]) {
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: historyURL)
    }

    // MARK: - Record current quota snapshot

    static func recordAndForecast(quota: [QuotaWindow], now: Date) -> Insight? {
        var history = loadHistory()

        // Append today's samples (deduplicate by rounding to the nearest hour)
        let roundedNow = (now.timeIntervalSince1970 / 3600).rounded() * 3600
        for window in quota {
            // Skip if we already have a sample for this provider+label in this hour
            let alreadyExists = history.contains {
                $0.provider == window.provider.rawValue &&
                $0.label == window.label &&
                abs($0.date - roundedNow) < 3600
            }
            if !alreadyExists {
                history.append(QuotaSample(
                    date: now.timeIntervalSince1970,
                    provider: window.provider.rawValue,
                    label: window.label,
                    remaining: window.remaining
                ))
            }
        }

        // Prune to last 14 days
        let cutoff = now.timeIntervalSince1970 - 14 * 86400
        history = history.filter { $0.date >= cutoff }
        saveHistory(history)

        // Forecast for Codex weekly window ("周")
        let weekSamples = history
            .filter { $0.provider == Provider.codex.rawValue && $0.label == "周" }
            .sorted { $0.date < $1.date }

        guard weekSamples.count >= 2 else { return nil }

        // Linear regression: remaining ~ a + b * t
        // Find when remaining == 0
        let n = Double(weekSamples.count)
        let sumT = weekSamples.reduce(0.0) { $0 + $1.date }
        let sumR = weekSamples.reduce(0.0) { $0 + $1.remaining }
        let sumT2 = weekSamples.reduce(0.0) { $0 + $1.date * $1.date }
        let sumTR = weekSamples.reduce(0.0) { $0 + $1.date * $1.remaining }

        let denom = n * sumT2 - sumT * sumT
        guard abs(denom) > 1e-9 else { return nil }

        let b = (n * sumTR - sumT * sumR) / denom   // slope (should be negative)
        let a = (sumR - b * sumT) / n                 // intercept

        // Only emit if trend is clearly decreasing (slope significantly negative)
        guard b < -1e-9 else { return nil }

        // t at remaining == 0: a + b*t = 0  →  t = -a/b
        let tZero = -a / b
        guard tZero > now.timeIntervalSince1970 else { return nil }  // already depleted?

        let predictedDate = Date(timeIntervalSince1970: tZero)

        // Format: "周额度预计 周四 15:00 见底"
        let cal = Calendar.current
        let weekdayIndex = cal.component(.weekday, from: predictedDate)  // 1=Sun .. 7=Sat
        let hour = cal.component(.hour, from: predictedDate)
        let minute = cal.component(.minute, from: predictedDate)

        let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekdayLabel = weekdayNames[weekdayIndex - 1]
        let timeLabel = String(format: "%02d:%02d", hour, minute)

        let text = "周额度预计 \(weekdayLabel) \(timeLabel) 见底"
        return Insight(kind: .forecast, text: text)
    }
}
