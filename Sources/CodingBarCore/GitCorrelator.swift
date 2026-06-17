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

    // MARK: - Per-repo stats

    private static func stats(for cwd: String, todaySinceStr: String) -> (added: Int, removed: Int, commits: Int, files: Set<String>) {
        guard isGitRepo(at: cwd) else { return (0, 0, 0, []) }

        // Commit count
        let commitCountStr = run(args: ["-C", cwd, "rev-list", "--count",
                                        "--since=\(todaySinceStr)", "HEAD"], timeout: 5.0) ?? ""
        let commits = Int(commitCountStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        // Numstat for line additions/deletions and unique files
        let numstat = run(args: ["-C", cwd, "log",
                                 "--since=\(todaySinceStr)",
                                 "--numstat",
                                 "--pretty=tformat:"], timeout: 5.0) ?? ""

        var added = 0
        var removed = 0
        var files = Set<String>()

        for line in numstat.components(separatedBy: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let addStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let delStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let file  = String(parts[2]).trimmingCharacters(in: .whitespaces)

            // Binary files show "-" for add/remove counts
            if addStr != "-", let a = Int(addStr) { added += a }
            if delStr != "-", let d = Int(delStr) { removed += d }
            if !file.isEmpty { files.insert(file) }
        }

        return (added, removed, commits, files)
    }

    // MARK: - Entry point

    /// Accumulate git output across the given cwds since `since` (range start).
    /// `cwds` should be ordered most-active first; only the top few are checked to
    /// bound latency, so passing them activity-sorted keeps the result meaningful.
    static func build(fromCwds cwds: [String], since: Date, now: Date) -> OutputStat {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let sinceStr = fmt.string(from: since)

        var totalAdded = 0
        var totalRemoved = 0
        var totalCommits = 0
        var totalFiles = Set<String>()

        // Only check up to 10 cwds (most-active first) to keep latency bounded
        for cwd in cwds.prefix(10) {
            guard !cwd.isEmpty,
                  FileManager.default.fileExists(atPath: cwd) else { continue }
            let s = stats(for: cwd, todaySinceStr: sinceStr)
            totalAdded += s.added
            totalRemoved += s.removed
            totalCommits += s.commits
            s.files.forEach { totalFiles.insert($0) }
        }

        return OutputStat(
            added: totalAdded,
            removed: totalRemoved,
            commits: totalCommits,
            files: totalFiles.count
        )
    }
}
