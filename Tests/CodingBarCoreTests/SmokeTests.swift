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

    func testTokenBreakdownMath() {
        var a = TokenBreakdown(input: 10, output: 5, cacheRead: 100)
        a += TokenBreakdown(input: 5, cacheWrite: 20)
        XCTAssertEqual(a.input, 15)
        XCTAssertEqual(a.cacheWrite, 20)
        XCTAssertEqual(a.total, 15 + 5 + 100 + 20)
    }
}
