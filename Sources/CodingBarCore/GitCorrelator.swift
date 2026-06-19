import Foundation

enum GitCorrelator {

    /// Run a git command with a hard timeout. Returns stdout or nil on failure/timeout.
    private static func run(args: [String], timeout: TimeInterval = 5.0) -> String? {
        runProcess(URL(fileURLWithPath: "/usr/bin/git"), args, timeout: timeout)
    }

    /// Run `executable` with `args`; returns stdout, or nil on spawn failure, non-zero
    /// exit, or timeout. Thin wrapper over `Subprocess.run` (the event-driven,
    /// thread-leak-free runner born from the overnight "popover frozen" bug — see
    /// `Subprocess.swift`). Kept as a named entry point so the timeout/reaping
    /// behaviour can be regression-tested directly.
    static func runProcess(_ executable: URL, _ args: [String], timeout: TimeInterval) -> String? {
        guard let result = Subprocess.run(executable, args, timeout: timeout),
              result.status == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }

    /// Collapse git's `--numstat -M` rename syntax to the file's *new* path so a moved
    /// file keys to one entry, not two:
    ///   "dir/{old => new}/f.swift" → "dir/new/f.swift"
    ///   "old.swift => new.swift"   → "new.swift"
    /// (Non-rename paths pass through unchanged.)
    static func resolveNumstatPath(_ raw: String) -> String {
        // git's rename syntax always spaces the arrow (" => "); gate on that so a real
        // (non-rename) file whose literal name contains "=>" isn't truncated.
        guard raw.contains(" => ") else { return raw }
        if let l = raw.firstIndex(of: "{"), let r = raw.firstIndex(of: "}"), l < r {
            let prefix = raw[raw.startIndex..<l]
            let suffix = raw[raw.index(after: r)...]
            let newPart = raw[raw.index(after: l)..<r]
                .components(separatedBy: "=>").last?.trimmingCharacters(in: .whitespaces) ?? ""
            return (String(prefix) + newPart + String(suffix)).replacingOccurrences(of: "//", with: "/")
        }
        return raw.components(separatedBy: "=>").last?.trimmingCharacters(in: .whitespaces) ?? raw
    }

    /// The absolute top-level of the git work tree containing `path`, or nil if `path`
    /// is not inside a repo. Used to collapse several logged `cwd`s that live in the
    /// SAME repository (e.g. `repo` and `repo/Sources`) down to one repo, since each
    /// would otherwise run an unscoped `git log` over the whole repo and count the same
    /// commits again. Doubles as the is-a-repo check.
    private static func gitToplevel(at path: String) -> String? {
        guard let out = run(args: ["-C", path, "rev-parse", "--show-toplevel"], timeout: 3.0) else { return nil }
        let top = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    public struct RangeOutputs: Sendable {
        public var today: OutputStat
        public var week: OutputStat
        public var month: OutputStat
    }

    /// One `git log` per repo over the last 30 days (with commit timestamps), then
    /// bucket additions/deletions/commits/files into today / last-7d / last-30d
    /// (cumulative). Computing all three together keeps the panel ranges instant
    /// AND mutually consistent — no per-tap recompute, no async race.
    /// The caller passes today's cwds first (scanned unconditionally) followed by
    /// the top monthly-volume cwds; the `prefix` below is a latency backstop sized
    /// to fit that union without re-truncating today's repos.
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

        // Collapse the candidate cwds to unique repositories by their git top-level,
        // preserving first-seen order (the caller puts today's cwds first, so a repo
        // seen today wins). Running one `git log` per cwd would otherwise count the
        // same commits once per cwd whenever two cwds share a repo.
        var repos: [String] = []
        var seenRepos = Set<String>()
        for cwd in cwds.prefix(20) {
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd),
                  let top = gitToplevel(at: cwd), !seenRepos.contains(top) else { continue }
            seenRepos.insert(top)
            repos.append(top)
        }

        for repo in repos {
            // "@<unix-ts>" header before each commit, then its numstat rows.
            // `--no-merges` drops merge commits so a merge's whole combined diff isn't
            // counted as fresh output (it still over-counts non-AI/hand-written commits
            // in the repo — the panel labels this as approximate git attribution).
            // `-M` detects renames so a moved file is one row (resolved to its new path
            // below) instead of a delete+add that double-counts it in the file set.
            let out = run(args: ["-C", repo, "log", "--since=\(sinceStr)", "--no-merges", "-M",
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
                let file = resolveNumstatPath(String(parts[2].trimmingCharacters(in: .whitespaces)))
                let key = repo + "/" + file
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
