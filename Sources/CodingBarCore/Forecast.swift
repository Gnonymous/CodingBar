import Foundation

public enum Forecaster {

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

    // `recordAndForecast` (called from Aggregator.run, on the local-refresh detached
    // task) and `forecastByProvider` (called from refreshQuota's detached task) both
    // touch quota-history.json and can run concurrently. Serialize the read-modify-write
    // so the two passes can't interleave into a corrupt/truncated history file.
    private static let historyLock = NSLock()

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

    public static func recordAndForecast(quota: [QuotaWindow], now: Date) -> Insight? {
        historyLock.lock()
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
        historyLock.unlock()

        // Forecast for Codex weekly window ("7d")
        let weekSamples = history
            .filter { $0.provider == Provider.codex.rawValue && $0.label == "7d" }
            .sorted { $0.date < $1.date }

        guard let tZero = regressZero(weekSamples),
              tZero > now.timeIntervalSince1970 else { return nil }
        let text = "周额度预计 " + formatDepletion(Date(timeIntervalSince1970: tZero)) + " 见底"
        return Insight(kind: .forecast, text: text)
    }

    /// For each provider that has a weekly window, forecast when it depletes.
    /// Returns `[Provider.rawValue: "<Name> 周额度预计 <weekday> <time> 见底"]`.
    /// Reads the history persisted by `recordAndForecast`, so call that first.
    public static func forecastByProvider(quota: [QuotaWindow], now: Date) -> [String: String] {
        historyLock.lock()
        let history = loadHistory()
        historyLock.unlock()
        var out: [String: String] = [:]
        for provider in [Provider.claude, Provider.codex] {
            guard quota.contains(where: { $0.provider == provider && $0.label == "7d" }) else { continue }
            let samples = history
                .filter { $0.provider == provider.rawValue && $0.label == "7d" }
                .sorted { $0.date < $1.date }
            guard let tZero = regressZero(samples), tZero > now.timeIntervalSince1970 else { continue }
            let name = provider == .claude ? "Claude" : "Codex"
            out[provider.rawValue] = "\(name) 周额度预计 " + formatDepletion(Date(timeIntervalSince1970: tZero)) + " 见底"
        }
        return out
    }

    /// Linear-regress `remaining ~ a + b·t` over the samples and return the time
    /// (epoch seconds) at which remaining hits 0, or nil if the trend isn't a
    /// clear decline.
    private static func regressZero(_ samples: [QuotaSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let n = Double(samples.count)
        let sumT = samples.reduce(0.0) { $0 + $1.date }
        let sumR = samples.reduce(0.0) { $0 + $1.remaining }
        let sumT2 = samples.reduce(0.0) { $0 + $1.date * $1.date }
        let sumTR = samples.reduce(0.0) { $0 + $1.date * $1.remaining }
        let denom = n * sumT2 - sumT * sumT
        guard abs(denom) > 1e-9 else { return nil }
        let b = (n * sumTR - sumT * sumR) / denom   // slope (should be negative)
        let a = (sumR - b * sumT) / n
        guard b < -1e-9 else { return nil }          // only emit on a clear decline
        return -a / b
    }

    /// "周四 15:00" — weekday + HH:mm of a predicted depletion date.
    private static func formatDepletion(_ date: Date) -> String {
        let cal = Calendar.current
        let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let wd = weekdayNames[cal.component(.weekday, from: date) - 1]
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date)
        return wd + " " + String(format: "%02d:%02d", h, m)
    }
}
