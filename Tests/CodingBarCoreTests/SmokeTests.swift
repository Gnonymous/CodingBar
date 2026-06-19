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

    func testTokenBreakdownMath() {
        var a = TokenBreakdown(input: 10, output: 5, cacheRead: 100)
        a += TokenBreakdown(input: 5, cacheWrite: 20)
        XCTAssertEqual(a.input, 15)
        XCTAssertEqual(a.cacheWrite, 20)
        XCTAssertEqual(a.total, 15 + 5 + 100 + 20)
    }
}
