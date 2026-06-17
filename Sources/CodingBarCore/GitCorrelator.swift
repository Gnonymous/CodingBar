import Foundation

// MARK: - Git correlator: approximate today's code output from local git repos.

enum GitCorrelator {

    // MARK: - Process helper with timeout

    /// Run a git command with a hard timeout. Returns stdout or nil on failure/timeout.
    private static func run(args: [String], timeout: TimeInterval = 5.0) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard stderr

        do { try proc.run() } catch { return nil }

        // Wait with timeout using a background thread
        var output: String? = nil
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            proc.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        output = String(data: data, encoding: .utf8)
        return output
    }

    // MARK: - Check if a directory is a git repo

    private static func isGitRepo(at path: String) -> Bool {
        let result = run(args: ["-C", path, "rev-parse", "--is-inside-work-tree"], timeout: 3.0)
        return result?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - Multi-range output (one git pass per repo, bucketed by commit time)

    public struct RangeOutputs: Sendable {
        public var today: OutputStat
        public var week: OutputStat
        public var month: OutputStat
    }

    /// One `git log` per repo over the last 30 days (with commit timestamps), then
    /// bucket additions/deletions/commits/files into today / last-7d / last-30d
    /// (cumulative). Computing all three together keeps the panel ranges instant
    /// AND mutually consistent — no per-tap recompute, no async race.
    /// `cwds` should be most-active first; only the top 10 are scanned for latency.
    static func buildRanges(cwds: [String], now: Date) -> RangeOutputs {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let todayStart = dayStart.timeIntervalSince1970
        let weekStart  = (cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart).timeIntervalSince1970
        let monthStartDate = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let sinceStr = fmt.string(from: monthStartDate)

        var tA = 0, tR = 0, tC = 0; var tF = Set<String>()
        var wA = 0, wR = 0, wC = 0; var wF = Set<String>()
        var mA = 0, mR = 0, mC = 0; var mF = Set<String>()

        for cwd in cwds.prefix(10) {
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd), isGitRepo(at: cwd) else { continue }
            // "@<unix-ts>" header before each commit, then its numstat rows.
            let out = run(args: ["-C", cwd, "log", "--since=\(sinceStr)",
                                 "--numstat", "--pretty=format:@%ct"], timeout: 6.0) ?? ""
            var ts: Double = 0
            for line in out.components(separatedBy: "\n") {
                if line.hasPrefix("@") {
                    ts = Double(line.dropFirst()) ?? 0
                    mC += 1
                    if ts >= weekStart { wC += 1 }
                    if ts >= todayStart { tC += 1 }
                    continue
                }
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let add = Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0  // "-" (binary) → 0
                let rem = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                let file = String(parts[2].trimmingCharacters(in: .whitespaces))
                let key = cwd + "/" + file
                mA += add; mR += rem; if !file.isEmpty { mF.insert(key) }
                if ts >= weekStart  { wA += add; wR += rem; if !file.isEmpty { wF.insert(key) } }
                if ts >= todayStart { tA += add; tR += rem; if !file.isEmpty { tF.insert(key) } }
            }
        }
        return RangeOutputs(
            today: OutputStat(added: tA, removed: tR, commits: tC, files: tF.count),
            week:  OutputStat(added: wA, removed: wR, commits: wC, files: wF.count),
            month: OutputStat(added: mA, removed: mR, commits: mC, files: mF.count)
        )
    }
}
