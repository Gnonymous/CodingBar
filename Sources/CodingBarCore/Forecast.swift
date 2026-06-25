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
    // so the two passes can't interleave into a corrupt/truncated history file. This is
    // a process-local lock; it relies on main.swift's single-instance policy (it kills
    // older copies of itself) to keep two CodingBar processes from writing the file at
    // once. The locked helpers below use `defer` so a future early-return can't leak it.
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

    /// Locked snapshot of the history file (read-only callers).
    private static func loadHistoryLocked() -> [QuotaSample] {
        historyLock.lock()
        defer { historyLock.unlock() }
        return loadHistory()
    }

    /// Locked read-modify-write: append the current windows (hour-deduped), prune to
    /// 14 days, persist, and return the updated history. The lock spans only the file
    /// I/O — the forecast math runs lock-free on the returned copy.
    private static func appendAndPrune(quota: [QuotaWindow], now: Date) -> [QuotaSample] {
        historyLock.lock()
        defer { historyLock.unlock() }
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
        return history
    }

    public static func recordAndForecast(quota: [QuotaWindow], now: Date, language: AppLanguage = .en) -> Insight? {
        let history = appendAndPrune(quota: quota, now: now)

        // Forecast for the Codex weekly window ("7d")
        let points = history
            .filter { $0.provider == Provider.codex.rawValue && $0.label == "7d" }
            .sorted { $0.date < $1.date }
            .map { Point(t: $0.date, r: $0.remaining) }
        let resetAt = quota.first { $0.provider == .codex && $0.label == "7d" }?.resetAt

        guard let when = predictDepletion(samples: points, resetAt: resetAt, now: now) else { return nil }
        let whenStr = formatDepletion(when, now: now, language: language)
        let text = language.t("Weekly quota runs out \(whenStr)", "周额度预计 \(whenStr) 见底")
        return Insight(kind: .forecast, text: text)
    }

    /// For each provider that has a weekly window, forecast when it depletes.
    /// Returns `[Provider.rawValue: "<Name> 周额度预计 <when> 见底"]`.
    /// Reads the history persisted by `recordAndForecast`, so call that first.
    public static func forecastByProvider(quota: [QuotaWindow], now: Date, language: AppLanguage = .en) -> [String: String] {
        let history = loadHistoryLocked()
        var out: [String: String] = [:]
        for provider in [Provider.claude, Provider.codex] {
            guard let window = quota.first(where: { $0.provider == provider && $0.label == "7d" }) else { continue }
            let points = history
                .filter { $0.provider == provider.rawValue && $0.label == "7d" }
                .sorted { $0.date < $1.date }
                .map { Point(t: $0.date, r: $0.remaining) }
            guard let when = predictDepletion(samples: points, resetAt: window.resetAt, now: now) else { continue }
            let name = provider == .claude ? "Claude" : "Codex"
            let whenStr = formatDepletion(when, now: now, language: language)
            out[provider.rawValue] = language.t("\(name) weekly quota runs out \(whenStr)", "\(name) 周额度预计 \(whenStr) 见底")
        }
        return out
    }

    public typealias Point = (t: Double, r: Double)   // (epoch seconds, remaining 0...1)

    /// Predict when the *current* window hits zero, or nil if it won't run out before it
    /// resets. Public so the self-test / XCTest can exercise the pure math without touching
    /// the disk-backed history.
    public static func predictDepletion(samples: [Point], resetAt: Date?, now: Date) -> Date? {
        guard let tZero = regressZero(currentWindow(samples)),
              tZero > now.timeIntervalSince1970 else { return nil }
        let when = Date(timeIntervalSince1970: tZero)
        // A window that resets before the projected zero never actually "runs out" — its
        // remaining fraction snaps back to 1 at the reset. Emitting a post-reset date is
        // exactly what made the forecast read as nonsense ("runs out next Mon" while the
        // window resets tomorrow), so suppress it.
        if let resetAt, when >= resetAt { return nil }
        return when
    }

    /// Keep only the samples since the most recent reset. A reset shows up as `remaining`
    /// jumping back up versus the prior sample; regressing across that sawtooth blends the
    /// spike with the genuine decline, flattening the slope and pushing the zero-crossing
    /// days past the truth. The live window is the only one whose depletion we can predict.
    private static func currentWindow(_ samples: [Point]) -> [Point] {
        guard !samples.isEmpty else { return samples }
        var start = 0
        // 0.05 is well above the 0.01 quota rounding / sampling noise, so only a real
        // reset (≈0 → ≈1) trips it, not a flat or slightly-jittery decline.
        for i in 1..<samples.count where samples[i].r > samples[i - 1].r + 0.05 { start = i }
        return Array(samples[start...])
    }

    /// Linear-regress `remaining ~ a + b·t` over the samples and return the time
    /// (epoch seconds) at which remaining hits 0, or nil if the trend isn't a
    /// clear decline.
    private static func regressZero(_ samples: [Point]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let n = Double(samples.count)
        let sumT = samples.reduce(0.0) { $0 + $1.t }
        let sumR = samples.reduce(0.0) { $0 + $1.r }
        let sumT2 = samples.reduce(0.0) { $0 + $1.t * $1.t }
        let sumTR = samples.reduce(0.0) { $0 + $1.t * $1.r }
        let denom = n * sumT2 - sumT * sumT
        guard abs(denom) > 1e-9 else { return nil }
        let b = (n * sumTR - sumT * sumR) / denom   // slope (should be negative)
        let a = (sumR - b * sumT) / n
        guard b < -1e-9 else { return nil }          // only emit on a clear decline
        return -a / b
    }

    /// "today 09:08" / "tomorrow 08:30" / "Thu 15:00" — the day is always spelled out so a
    /// multi-day-out forecast can't be misread as a weekday that just passed (a bare "Mon"
    /// five days out reads as the Monday that already went by). Public for tests.
    public static func formatDepletion(_ date: Date, now: Date, language: AppLanguage) -> String {
        let cal = Calendar.current
        let time = String(format: "%02d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date))
        let dayDiff = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if dayDiff == 0 { return language.t("today \(time)", "今天 \(time)") }
        if dayDiff == 1 { return language.t("tomorrow \(time)", "明天 \(time)") }
        let names = language.t("Sun Mon Tue Wed Thu Fri Sat", "周日 周一 周二 周三 周四 周五 周六")
            .split(separator: " ").map(String.init)
        let wd = names[cal.component(.weekday, from: date) - 1]
        return wd + " " + time
    }
}
