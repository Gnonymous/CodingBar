import XCTest
import Darwin   // task_threads, for the subprocess-leak regression guard
@testable import CodingBarCore

final class SmokeTests: XCTestCase {
    /// Regression for the overnight menu-bar freeze: a git child that outlives its
    /// timeout must be hard-killed and its reader thread reclaimed. The old path
    /// (`terminate()`/SIGTERM, then `waitUntilExit()` on a background thread) leaked
    /// one worker thread per timed-out child, accumulating across the 30s refresh
    /// timer until the GCD 64-thread soft limit wedged the whole pool — the popover
    /// then opened but could not be clicked or dismissed.
    func testTimedOutSubprocessesDoNotLeakThreads() {
        func threadCount() -> Int {
            var threads: thread_act_array_t?
            var count: mach_msg_type_number_t = 0
            guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
            return Int(count)
        }
        // A child that explicitly ignores SIGTERM, so the old terminate()-only path
        // would leave it (and its waitUntilExit thread) alive for the full sleep.
        let sigtermProof = ["-c", "trap '' TERM; sleep 30"]
        let baseline = threadCount()
        for _ in 0..<25 {
            let out = GitCorrelator.runProcess(URL(fileURLWithPath: "/bin/sh"), sigtermProof, timeout: 0.2)
            XCTAssertNil(out)  // must time out, not block
        }
        Thread.sleep(forTimeInterval: 0.5)  // let the SIGKILL'd readers unwind
        let growth = threadCount() - baseline
        XCTAssertLessThan(growth, 8, "timed-out subprocesses leaked ~\(growth) worker threads")
    }

    func testCompletedSubprocessReturnsStdout() {
        let out = GitCorrelator.runProcess(URL(fileURLWithPath: "/bin/echo"), ["hi"], timeout: 5)
        XCTAssertEqual(out?.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    /// A child that writes more than the 64KB pipe buffer to stderr would block on
    /// write if stderr were never drained, stalling here until the timeout. The
    /// runner drains (and discards) stderr, so stdout still returns promptly.
    func testSubprocessDrainsStderrWithoutWedging() {
        let out = GitCorrelator.runProcess(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "yes errline | head -c 200000 1>&2; printf DONE"],
            timeout: 5)
        XCTAssertEqual(out, "DONE")
    }

    /// The scanners switched from `String(...).components(separatedBy: "\n")` to the
    /// memory-friendly `Data.forEachLine`. Guard that it yields the identical set of
    /// non-empty lines so parse output can't silently drift.
    func testDataForEachLineMatchesComponentsSplit() {
        let cases = [
            "{\"a\":1}\n{\"b\":2}\n",
            "{\"a\":1}\n{\"b\":2}",
            "\n\nx\n\n\ny\n",
            "  \n\t\n{\"x\":1}\n",
            "{\"u\":\"héllo 世界 🚀\"}\n{\"v\":\"ünïcödé\"}\n",
            "",
        ]
        for s in cases {
            let data = Data(s.utf8)
            var viaForEach: [String] = []
            data.forEachLine { viaForEach.append($0) }
            let viaComponents = (String(data: data, encoding: .utf8) ?? "")
                .components(separatedBy: "\n").filter { !$0.isEmpty }
            XCTAssertEqual(viaForEach, viaComponents, "line split diverged for \(s.debugDescription)")
        }
    }

    func testSampleSnapshotIsCodable() throws {
        let snap = Snapshot.sample()
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(back.overview.spend.sessions, 7)
        XCTAssertEqual(back.menu.primaryText, "1.2M")
        // The additive ProfileStats field must round-trip too.
        XCTAssertEqual(back.profile.sessions, 202)
        XCTAssertEqual(back.profile.currentStreak, 22)
        XCTAssertEqual(back.profile.calendar.count, 7)
    }

    /// ProfileBuilder derives all-time stats from raw records: distinct sessions,
    /// active days, current/longest streak (current anchors on today/yesterday),
    /// peak hour by tokens, and the most-frequently-used model.
    func testProfileBuilderStatsAndStreaks() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 20))!  // a Sunday
        let base = cal.startOfDay(for: now)
        func rec(_ dayOff: Int, _ hour: Int, _ model: String, _ session: String, _ tok: Int, _ mid: String) -> RawRecord {
            let day = cal.date(byAdding: .day, value: dayOff, to: base)!
            let ts = cal.date(byAdding: .hour, value: hour, to: day)!
            return RawRecord(provider: .claude, model: model, timestamp: ts, cwd: "/p",
                             tokens: TokenBreakdown(input: tok), toolName: nil, toolNames: [],
                             messageId: mid, sessionKey: session, hasInterrupt: false)
        }
        let records = [
            // current run (today, -1, -2) → streak 3; peak hour 14 (900 tok vs 200)
            rec(0,  14, "claude-opus-4-8",   "s1", 500, "m1"),
            rec(-1, 14, "claude-opus-4-8",   "s1", 300, "m2"),
            rec(-2, 14, "claude-opus-4-8",   "s2", 100, "m3"),
            // older 4-day run (-10…-13) → longest 4; one sonnet keeps opus the favorite
            rec(-10, 9, "claude-opus-4-8",   "s2", 50, "m4"),
            rec(-11, 9, "claude-opus-4-8",   "s3", 50, "m5"),
            rec(-12, 9, "claude-sonnet-4-6", "s3", 50, "m6"),
            rec(-13, 9, "claude-opus-4-8",   "s3", 50, "m7"),
        ]
        let p = ProfileBuilder.build(from: records, now: now)
        XCTAssertEqual(p.sessions, 3)
        XCTAssertEqual(p.messages, 7)
        XCTAssertEqual(p.activeDays, 7)
        XCTAssertEqual(p.currentStreak, 3)
        XCTAssertEqual(p.longestStreak, 4)
        XCTAssertEqual(p.peakHour, 14)
        XCTAssertEqual(p.favoriteModel, "anthropic/claude-opus-4-8")
        XCTAssertEqual(p.favoriteModelProvider, .claude)
        XCTAssertEqual(p.calendar.count, 7)
        XCTAssertEqual(p.calendar.first?.count, ProfileBuilder.calendarWeeks)
        XCTAssertEqual(p.calendar.flatMap { $0 }.max(), 1.0)  // the busiest day normalizes to 1
    }

    /// Codex `token_count` events are cumulative snapshots; replayed/duplicate events
    /// used to inflate the summed total. The scanner now takes the positive delta of
    /// `total_token_usage`, which de-duplicates and reconstructs each turn's increment.
    /// Also guards that an unparseable timestamp drops the record (no `Date()` fallback)
    /// while still advancing the cumulative baseline.
    func testCodexScannerDeduplicatesCumulativeTokenCounts() throws {
        func line(_ obj: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }
        func tc(ts: String, input: Int, cached: Int, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ts,
             "payload": ["type": "token_count",
                         "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                        "output_tokens": output, "reasoning_output_tokens": 0]]]]
        }
        let lines = [
            line(["type": "session_meta", "payload": ["cwd": "/tmp/proj"]]),
            line(["type": "turn_context", "payload": ["model": "gpt-5.5-codex"]]),
            line(tc(ts: "2026-06-18T13:00:00.000Z", input: 100, cached: 0,  output: 10)), // A
            line(tc(ts: "2026-06-18T13:00:00.000Z", input: 100, cached: 0,  output: 10)), // dup → skip
            line(tc(ts: "2026-06-18T13:05:00.000Z", input: 300, cached: 50, output: 30)), // C: Δ net150 cache50 out20
            line(tc(ts: "garbage",                  input: 450, cached: 50, output: 40)), // bad ts → drop, baseline→450
            line(tc(ts: "2026-06-18T13:10:00.000Z", input: 600, cached: 50, output: 50)), // E: Δ net150 cache0 out10
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = CodexScanner.parseFile(url)
        XCTAssertEqual(records.count, 3, "duplicate must be skipped and the bad-timestamp record dropped")
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.input }, 100 + 150 + 150)     // net input
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.cacheRead }, 0 + 50 + 0)
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.output }, 10 + 20 + 10)
        XCTAssertEqual(records.first?.model, "gpt-5.5-codex")
    }

    /// Codex `function_call` items (exec_command, view_image, …) buffered before a
    /// turn's token_count must attach to that turn's record so the tool-mix counts Codex.
    func testCodexScannerAttachesFunctionCallToolNames() throws {
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        func fn(_ name: String) -> [String: Any] { ["type": "response_item", "payload": ["type": "function_call", "name": name]] }
        func tc(ts: String, input: Int, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ts,
             "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": 0,
                                                        "output_tokens": output, "reasoning_output_tokens": 0]]]]
        }
        let lines = [
            line(["type": "session_meta", "payload": ["cwd": "/tmp/p"]]),
            line(["type": "turn_context", "payload": ["model": "gpt-5.5-codex"]]),
            line(fn("exec_command")), line(fn("view_image")),
            line(tc(ts: "2026-06-18T13:00:00.000Z", input: 100, output: 10)),
            line(fn("exec_command")),
            line(tc(ts: "2026-06-18T13:05:00.000Z", input: 200, output: 20)),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let recs = CodexScanner.parseFile(url)
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].toolNames, ["exec_command", "view_image"])
        XCTAssertEqual(recs[1].toolNames, ["exec_command"])  // buffer cleared after each emitted record
        XCTAssertEqual(Behavior.bucket(toolName: "exec_command"), \ToolMix.run)
        XCTAssertEqual(Behavior.bucket(toolName: "view_image"), \ToolMix.read)
    }

    /// Claude tags each assistant line with `attribution*` fields (skill / agent / plugin /
    /// MCP server) that drive the `/usage`-style breakdowns. The scanner must lift them onto
    /// the record, and leave a plain turn's attribution empty.
    func testClaudeScannerParsesUsageAttribution() throws {
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        func asst(_ id: String, _ extra: [String: Any]) -> [String: Any] {
            var o: [String: Any] = [
                "type": "assistant", "timestamp": "2026-06-18T13:00:00.000Z", "cwd": "/p",
                "message": ["id": id, "model": "claude-opus-4-8",
                            "usage": ["input_tokens": 100, "output_tokens": 10,
                                      "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
                            "content": []],
            ]
            for (k, v) in extra { o[k] = v }
            return o
        }
        let lines = [
            asst("m1", ["attributionSkill": "hunt", "attributionPlugin": "superpowers"]),
            asst("m2", ["attributionMcpServer": "playwright", "attributionMcpTool": "browser_click"]),
            asst("m3", ["attributionAgent": "general-purpose"]),
            asst("m4", [:]),   // plain turn → empty attribution
        ].map(line)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let recs = ClaudeScanner.parseFile(url)
        XCTAssertEqual(recs.count, 4)
        XCTAssertEqual(recs[0].attribution.skill, "hunt")
        XCTAssertEqual(recs[0].attribution.plugin, "superpowers")
        XCTAssertEqual(recs[1].attribution.mcpServer, "playwright")
        XCTAssertEqual(recs[2].attribution.agent, "general-purpose")
        XCTAssertTrue(recs[3].attribution.isEmpty)
    }

    /// A Codex session that switches model mid-stream (`/model`) must attribute each
    /// turn to the model in effect AT that turn, not freeze on the session's first one
    /// (the `model == "unknown"` guard used to ignore every later turn_context).
    func testCodexScannerTracksMidSessionModelSwitch() throws {
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        func tc(ts: String, input: Int, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ts,
             "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": 0,
                                                        "output_tokens": output, "reasoning_output_tokens": 0]]]]
        }
        let lines = [
            line(["type": "session_meta", "payload": ["cwd": "/tmp/p"]]),
            line(["type": "turn_context", "payload": ["model": "gpt-5.5-codex"]]),
            line(tc(ts: "2026-06-18T13:00:00.000Z", input: 100, output: 10)),   // → gpt-5.5-codex
            line(["type": "turn_context", "payload": ["model": "gpt-5.4-codex"]]),
            line(tc(ts: "2026-06-18T13:05:00.000Z", input: 250, output: 30)),   // → gpt-5.4-codex
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let recs = CodexScanner.parseFile(url)
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].model, "gpt-5.5-codex")
        XCTAssertEqual(recs[1].model, "gpt-5.4-codex", "model after an in-session switch must update")
    }

    /// Two logged cwds inside the SAME repo (repo root + a subdir) must count the repo's
    /// commits/files ONCE, not once per cwd. buildRanges now collapses cwds by their git
    /// top-level; an unscoped `git log` per cwd previously double-counted shared repos.
    func testGitRangesDeduplicateCwdsInSameRepo() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        let sub = repo.appendingPathComponent("Sources")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }

        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        git(["init", "-q"])
        try "hello\n".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", "one", "--no-gpg-sign"])

        let out = GitCorrelator.buildRanges(cwds: [repo.path, sub.path], now: Date())
        XCTAssertEqual(out.today.commits, 1, "same-repo cwds must not double-count commits")
        XCTAssertEqual(out.today.files, 1, "the one changed file must be counted once")
    }

    func testGitRenamePathResolution() {
        XCTAssertEqual(GitCorrelator.resolveNumstatPath("src/{old.swift => new.swift}"), "src/new.swift")
        XCTAssertEqual(GitCorrelator.resolveNumstatPath("dir/{old => new}/f.swift"), "dir/new/f.swift")
        XCTAssertEqual(GitCorrelator.resolveNumstatPath("old.txt => new.txt"), "new.txt")
        XCTAssertEqual(GitCorrelator.resolveNumstatPath("normal/path.swift"), "normal/path.swift")
        // A literal "=>" without git's spaced arrow must pass through untouched.
        XCTAssertEqual(GitCorrelator.resolveNumstatPath("weird=>name.txt"), "weird=>name.txt")
    }

    func testPriceIsExactFlagsOnlyFallbackModels() {
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-opus-4-8"))
        XCTAssertTrue(Pricing.priceIsExact(model: "gpt-5.5-codex"))
        XCTAssertFalse(Pricing.priceIsExact(model: "gpt-5.1"))                 // no table/family match
        XCTAssertFalse(Pricing.priceIsExact(model: "totally-unknown-model"))  // generic fallback rate
    }

    /// The Codex weekly forecast used to linear-regress across quota *resets*: a 14-day
    /// history is a sawtooth (remaining snaps back to ~1 each week), so the blended slope
    /// flattened and the projected zero landed ~5 days out — then it rendered as a bare
    /// weekday ("Mon"), which read as the Monday that had already passed. The fix regresses
    /// only the live window, suppresses zeros falling after the window resets, and always
    /// spells out the day. Guards all three so the regression can't silently return.
    func testWeeklyForecastIgnoresResetsAndDisambiguatesDay() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 12))!  // a Wednesday
        let day = 86_400.0
        let t0 = now.timeIntervalSince1970
        func pt(_ daysFromNow: Double, _ r: Double) -> (t: Double, r: Double) { (t: t0 + daysFromNow * day, r: r) }

        // Live window: declines 1.0 → 0.10 over the last 6 days. Analytic zero: the slope is
        // 0.90 over 6 days = 0.15/day, so r hits 0 at 0.10/0.15 = 0.667 day after now.
        let live = (0...6).map { pt(-6 + Double($0), 1.0 - 0.9 * (Double($0) / 6.0)) }
        let expectedZero = t0 + (2.0 / 3.0) * day

        let resetFar = now.addingTimeInterval(3 * day)   // resets well after the projected zero
        guard let liveZero = Forecaster.predictDepletion(samples: live, resetAt: resetFar, now: now) else {
            return XCTFail("a clean declining window must project a depletion")
        }
        XCTAssertEqual(liveZero.timeIntervalSince1970, expectedZero, accuracy: 3600,
                       "clean declining window should project ~16h out")

        // Prepend a *previous* window (0.30 → 0.05) before the reset jump to 1.0. Regressing
        // the whole sawtooth (the old bug) flattens the slope; the fix trims to the live
        // window, so the answer must be byte-identical to the live-only projection.
        let withReset = [pt(-13, 0.30), pt(-12, 0.20), pt(-11, 0.12), pt(-10, 0.05)] + live
        let trimmedZero = Forecaster.predictDepletion(samples: withReset, resetAt: resetFar, now: now)
        XCTAssertEqual(trimmedZero?.timeIntervalSince1970, liveZero.timeIntervalSince1970,
                       "samples before the reset must not shift the projection")

        // A window that resets before the projected zero never runs out → no forecast.
        let resetSoon = now.addingTimeInterval(0.25 * day)   // before the 0.667-day zero
        XCTAssertNil(Forecaster.predictDepletion(samples: live, resetAt: resetSoon, now: now),
                     "depletion after the reset must be suppressed")

        // Day is always spelled out: today / tomorrow / weekday — never a bare ambiguous one.
        let today15 = cal.date(bySettingHour: 15, minute: 0, second: 0, of: now)!
        let tomorrow0830 = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 8, minute: 30, second: 0, of: now)!)!
        let inThreeDays = cal.date(byAdding: .day, value: 3, to: now)!   // Wed + 3 = Saturday
        XCTAssertEqual(Forecaster.formatDepletion(today15, now: now, language: .en), "today 15:00")
        XCTAssertEqual(Forecaster.formatDepletion(today15, now: now, language: .zh), "今天 15:00")
        XCTAssertEqual(Forecaster.formatDepletion(tomorrow0830, now: now, language: .en), "tomorrow 08:30")
        XCTAssertTrue(Forecaster.formatDepletion(inThreeDays, now: now, language: .en).hasPrefix("Sat "),
                      "3 days out should fall back to the weekday, not today/tomorrow")
    }

    func testTokenBreakdownMath() {
        var a = TokenBreakdown(input: 10, output: 5, cacheRead: 100)
        a += TokenBreakdown(input: 5, cacheWrite: 20)
        XCTAssertEqual(a.input, 15)
        XCTAssertEqual(a.cacheWrite, 20)
        XCTAssertEqual(a.total, 15 + 5 + 100 + 20)
    }
}
