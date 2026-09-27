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
        func tc(ts: String, input: Int, cached: Int, cacheWrite: Int = 0, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ts,
             "payload": ["type": "token_count",
                         "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                        "cache_write_input_tokens": cacheWrite,
                                                        "output_tokens": output, "reasoning_output_tokens": 0],
                                  "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                       "cache_write_input_tokens": cacheWrite,
                                                       "output_tokens": output, "reasoning_output_tokens": 0]]]]
        }
        let lines = [
            line(["type": "session_meta", "payload": ["cwd": "/tmp/proj"]]),
            line(["type": "turn_context", "payload": ["model": "gpt-5.5-codex"]]),
            line(tc(ts: "2026-06-18T13:00:00.000Z", input: 100, cached: 0,  cacheWrite: 20, output: 10)), // A: fresh80 write20
            line(tc(ts: "2026-06-18T13:00:00.000Z", input: 100, cached: 0,  cacheWrite: 20, output: 10)), // dup → skip
            line(tc(ts: "2026-06-18T13:05:00.000Z", input: 300, cached: 50, cacheWrite: 40, output: 30)), // C: Δ fresh130 read50 write20 out20
            line(tc(ts: "garbage",                  input: 450, cached: 50, cacheWrite: 40, output: 40)), // bad ts → drop, baseline→450
            line(tc(ts: "2026-06-18T13:10:00.000Z", input: 600, cached: 50, cacheWrite: 50, output: 50)), // E: Δ fresh140 write10 out10
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = CodexScanner.parseFile(url)
        XCTAssertEqual(records.count, 3, "duplicate must be skipped and the bad-timestamp record dropped")
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.input }, 80 + 130 + 140)
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.cacheRead }, 0 + 50 + 0)
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.cacheWrite }, 20 + 20 + 10)
        XCTAssertEqual(records.reduce(0) { $0 + $1.tokens.output }, 10 + 20 + 10)
        XCTAssertEqual(records.first?.model, "gpt-5.5-codex")
    }

    func testCodexScannerSeparatesReasoningAndPreservesBillingContext() throws {
        let event: [String: Any] = [
            "type": "event_msg", "timestamp": "2026-08-09T13:00:00.000Z",
            "payload": ["type": "token_count", "info": [
                "total_token_usage": [
                    "input_tokens": 300_000, "cached_input_tokens": 100_000,
                    "cache_write_input_tokens": 50_000,
                    "output_tokens": 100, "reasoning_output_tokens": 40,
                ],
                "last_token_usage": [
                    "input_tokens": 300_000, "cached_input_tokens": 100_000,
                    "cache_write_input_tokens": 50_000,
                    "output_tokens": 100, "reasoning_output_tokens": 40,
                ],
            ]],
        ]
        let lines = [
            ["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]],
            event,
        ]
        let data = try lines.map {
            String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
        }.joined(separator: "\n").data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try XCTUnwrap(CodexScanner.parseFile(url).first)
        XCTAssertEqual(record.tokens.input, 150_000)
        XCTAssertEqual(record.tokens.cacheRead, 100_000)
        XCTAssertEqual(record.tokens.cacheWrite, 50_000)
        XCTAssertEqual(record.tokens.output, 60, "output_tokens already contains reasoning")
        XCTAssertEqual(record.tokens.reasoning, 40)
        XCTAssertEqual(record.tokens.total, 300_100)
        XCTAssertEqual(record.billingInputTokens, 300_000)
    }

    func testModernCodexUsageRecordsIgnoreCumulativeSnapshotsAndDeduplicateResponses() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func usage(_ id: String, _ timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
            ["type": "token_usage_record", "timestamp": timestamp,
             "payload": ["response_id": id,
                         "usage": ["input_tokens": input, "cached_input_tokens": cached,
                                   "cache_write_input_tokens": 0, "output_tokens": output,
                                   "reasoning_output_tokens": 0]]]
        }
        let snapshot: [String: Any] = ["type": "event_msg", "timestamp": "2026-09-27T10:00:01Z",
            "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 50_000_000, "cached_input_tokens": 45_000_000,
                                      "output_tokens": 900_000, "reasoning_output_tokens": 0],
                "last_token_usage": ["input_tokens": 300, "cached_input_tokens": 200,
                                     "output_tokens": 10, "reasoning_output_tokens": 0]]]]
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["cwd": "/tmp/project"]],
            ["type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command"]],
            usage("resp-1", "2026-09-27T10:00:00Z", input: 300, cached: 200, output: 10),
            snapshot,
            usage("resp-1", "2026-09-27T10:00:02Z", input: 300, cached: 200, output: 10),
            ["type": "turn_context", "payload": ["model": "gpt-6-luna"]],
            usage("resp-2", "2026-09-27T10:05:00Z", input: 400, cached: 300, output: 20),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines.map(line).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = CodexScanner.parseFile(url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.model), ["gpt-6-astra", "gpt-6-luna"])
        XCTAssertEqual(records.map(\.messageId), ["resp-1", "resp-2"])
        XCTAssertEqual(records.map(\.tokens.input), [100, 100])
        XCTAssertEqual(records.map(\.tokens.cacheRead), [200, 300])
        XCTAssertEqual(records.map(\.tokens.output), [10, 20])
        XCTAssertEqual(records.first?.billingInputTokens, 300)
        XCTAssertEqual(records.first?.toolNames, ["exec_command"])
    }

    func testLegacyCodexFirstCounterAndResetUseLastTurnUsage() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func count(_ timestamp: String, total: Int, last: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": timestamp,
             "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": total, "cached_input_tokens": 0,
                                      "output_tokens": total / 10, "reasoning_output_tokens": 0],
                "last_token_usage": ["input_tokens": last, "cached_input_tokens": 0,
                                     "output_tokens": last / 10, "reasoning_output_tokens": 0]]]]
        }
        let lines: [[String: Any]] = [
            ["type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            count("2026-09-27T10:00:00Z", total: 5_000_000, last: 100),
            count("2026-09-27T10:00:01Z", total: 5_000_000, last: 100),
            count("2026-09-27T10:05:00Z", total: 5_000_200, last: 200),
            count("2026-09-27T10:10:00Z", total: 300, last: 50),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try lines.map(line).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = CodexScanner.parseFile(url)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.tokens.input), [100, 200, 50])
        XCTAssertEqual(records.map(\.tokens.output), [10, 20, 5])
    }

    /// Codex `function_call` items (exec_command, view_image, …) buffered before a
    /// turn's token_count must attach to that turn's record so the tool-mix counts Codex.
    func testCodexScannerAttachesFunctionCallToolNames() throws {
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        func fn(_ name: String) -> [String: Any] { ["type": "response_item", "payload": ["type": "function_call", "name": name]] }
        func tc(ts: String, input: Int, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ts,
             "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": 0,
                                                        "output_tokens": output, "reasoning_output_tokens": 0],
                                                  "last_token_usage": ["input_tokens": input, "cached_input_tokens": 0,
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

    func testClaudeScannerPreservesGPTModelAndUsage() throws {
        let record: [String: Any] = [
            "type": "assistant", "timestamp": "2026-08-09T13:00:00.000Z", "cwd": "/p",
            "message": [
                "id": "gpt-turn", "model": "gpt-5.6-sol", "content": [],
                "usage": [
                    "input_tokens": 100, "output_tokens": 10,
                    "cache_read_input_tokens": 250_000, "cache_creation_input_tokens": 30_000,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try XCTUnwrap(ClaudeScanner.parseFile(url).first)
        XCTAssertEqual(parsed.provider, .claude)
        XCTAssertEqual(parsed.model, "gpt-5.6-sol")
        XCTAssertEqual(parsed.tokens, TokenBreakdown(input: 100, output: 10,
                                                      cacheRead: 250_000, cacheWrite: 30_000))
        XCTAssertNil(parsed.billingInputTokens, "Claude prompt size is derived from its absolute usage fields")
    }

    func testClaudeScannerPreservesOneHourCacheWrites() throws {
        let record: [String: Any] = [
            "type": "assistant", "timestamp": "2026-07-01T13:00:00.000Z", "cwd": "/p",
            "message": [
                "id": "m1", "model": "claude-fable-5", "content": [],
                "usage": [
                    "input_tokens": 100, "output_tokens": 10,
                    "cache_read_input_tokens": 50, "cache_creation_input_tokens": 80,
                    "cache_creation": ["ephemeral_1h_input_tokens": 60],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try XCTUnwrap(ClaudeScanner.parseFile(url).first)
        XCTAssertEqual(parsed.tokens.cacheWrite, 80)
        XCTAssertEqual(parsed.cacheWrite1h, 60)
    }

    func testClaudeStreamingMessageUsesFinalUsageAndContent() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func assistant(_ output: Int, content: [[String: Any]]) -> [String: Any] {
            ["type": "assistant", "timestamp": "2026-09-27T10:00:00Z", "cwd": "/tmp/project",
             "message": ["id": "msg-1", "model": "claude-opus-5-5", "content": content,
                         "usage": ["input_tokens": 2, "cache_read_input_tokens": 200_000,
                                   "cache_creation_input_tokens": 100, "output_tokens": output]]]
        }
        let lines = [assistant(2, content: []),
                     assistant(432, content: [["type": "tool_use", "name": "Bash"]])]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.map(line).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = ClaudeScanner.parseFile(url)
        let result = ClaudeScanner.deduplicate(parsed)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].tokens.output, 432)
        XCTAssertEqual(result.records[0].toolNames, ["Bash"])
        XCTAssertEqual(result.seenIds, ["msg-1"])
    }

    /// A Codex session that switches model mid-stream (`/model`) must attribute each
    /// turn to the model in effect AT that turn, not freeze on the session's first one
    /// (the `model == "unknown"` guard used to ignore every later turn_context).
    func testCodexScannerTracksMidSessionModelSwitch() throws {
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
        func tc(ts: String, input: Int, output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": ts,
             "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": 0,
                                                        "output_tokens": output, "reasoning_output_tokens": 0],
                                                  "last_token_usage": ["input_tokens": input, "cached_input_tokens": 0,
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

    /// `git log --numstat` over 30 days per repo is the most expensive single step in a
    /// refresh pass — profiled at 951 ms of a ~2 s pass, re-run every 30 seconds to
    /// rebuild commit history that had not moved. Within the TTL the result must come
    /// from memory even if the repo gains a commit; past it, the recount must see it.
    func testGitRangesAreMemoizedWithinTTL() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }

        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        func commit(_ name: String) throws {
            try "x\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
            git(["add", "."])
            git(["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "-m", name, "--no-gpg-sign"])
        }
        git(["init", "-q"])
        try commit("a.txt")

        // Midday so that advancing past the TTL below cannot cross into the next day,
        // which would legitimately invalidate the entry for a different reason.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        XCTAssertEqual(GitCorrelator.buildRanges(cwds: [repo.path], now: now).today.commits, 1)

        try commit("b.txt")
        XCTAssertEqual(GitCorrelator.buildRanges(cwds: [repo.path], now: now).today.commits, 1,
                       "within the TTL the memoized ranges must be reused, not recomputed")

        let later = now.addingTimeInterval(GitCorrelator.rangeTTL + 1)
        XCTAssertEqual(GitCorrelator.buildRanges(cwds: [repo.path], now: later).today.commits, 2,
                       "past the TTL the recount must pick up the new commit")
    }

    /// Aggregator.run() builds a fresh Scanner on every pass, and the on-disk scan cache
    /// is 10 MB of binary plist here — decoding it per pass cost 745 ms of a ~2 s refresh
    /// to rebuild state that was already in memory. It must be decoded once per process.
    func testScannerDecodesDiskCacheOncePerProcess() {
        _ = Scanner()                       // warm the process-wide store
        let before = Scanner.diskDecodeCount
        _ = Scanner(); _ = Scanner(); _ = Scanner()
        XCTAssertEqual(Scanner.diskDecodeCount, before,
                       "later Scanners must reuse the in-memory cache, not re-read the file")
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
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-opus-5-5"))
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-fable-5-1"))
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-mythos-5-1"))
        XCTAssertTrue(Pricing.priceIsExact(model: "gpt-6-astra"))
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-opus-4-8"))
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-sonnet-5"))
        XCTAssertTrue(Pricing.priceIsExact(model: "gpt-5.6-sol"))
        XCTAssertTrue(Pricing.priceIsExact(model: "openrouter/openai/gpt-5.4-mini"))
        XCTAssertFalse(Pricing.priceIsExact(model: "gpt-5.5-codex"))          // observed alias, family estimate
        XCTAssertFalse(Pricing.priceIsExact(model: "gpt-5.6-codex"))          // unknown model, generic fallback
        XCTAssertFalse(Pricing.priceIsExact(model: "totally-unknown-model"))
        XCTAssertEqual(Pricing.cost(model: "sonnet-proxy/unknown-model",
                                    tokens: TokenBreakdown(input: 1_000_000), at: Date()), 3,
                       "a router name must not select a Claude family estimate")
    }

    func testModelIdentityIncludesLogProviderForRoutedModels() {
        let tokens = TokenBreakdown(input: 100)
        let claude = ModelStat(model: "openai/gpt-6-luna", provider: .claude, tokens: tokens, cost: 0.1)
        let codex = ModelStat(model: "openai/gpt-6-luna", provider: .codex, tokens: tokens, cost: 0.1)
        XCTAssertNotEqual(claude.id, codex.id)

        let now = Date(timeIntervalSince1970: 1_790_500_000)
        let record = RawRecord(provider: .claude, model: "gpt-6-luna", timestamp: now,
                               cwd: "/tmp/project", tokens: tokens, toolName: nil, toolNames: [],
                               messageId: "routed", sessionKey: "claude-session", hasInterrupt: false)
        let profile = ProfileBuilder.build(from: [record], now: now)
        XCTAssertEqual(profile.favoriteModel, "openai/gpt-6-luna")
        XCTAssertEqual(profile.favoriteModelProvider, .claude)
    }

    func testPricingUsesCacheDurationAndSonnetFivePermanentPrice() {
        let millionTokens = TokenBreakdown(input: 1_000_000, output: 1_000_000,
                                           cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let july = Date(timeIntervalSince1970: 1_783_555_200)       // 2026-07-01 UTC
        let september = Date(timeIntervalSince1970: 1_788_220_800)  // 2026-09-01 UTC

        XCTAssertEqual(Pricing.normalize(model: "claude-sonnet-5"), "anthropic/claude-sonnet-5")
        XCTAssertEqual(Pricing.cost(model: "claude-fable-5", tokens: millionTokens,
                                    at: july, cacheWrite1h: 1_000_000), 81, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-opus-4-8", tokens: millionTokens,
                                    at: july, cacheWrite1h: 1_000_000), 40.5, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-sonnet-5", tokens: millionTokens,
                                    at: july, cacheWrite1h: 1_000_000), 16.2, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-sonnet-5", tokens: millionTokens,
                                    at: september, cacheWrite1h: 1_000_000), 16.2, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-opus-5-5", tokens: millionTokens,
                                    at: september, cacheWrite1h: 1_000_000), 32.2, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-fable-5-1", tokens: millionTokens,
                                    at: september, cacheWrite1h: 1_000_000), 80.25, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-mythos-5-1", tokens: millionTokens,
                                    at: september, cacheWrite1h: 1_000_000), 80.25, accuracy: 0.000_001)
    }

    func testOpenAIModelPricesAndAliasesMatchCurrentTable() {
        let date = Date(timeIntervalSince1970: 1_786_233_600)  // 2026-08-09 UTC
        let hundredK = 100_000
        let cases: [(raw: String, canonical: String, input: Double, cached: Double, output: Double)] = [
            ("gpt-6-astra", "openai/gpt-6-astra", 10, 1, 50),
            ("gpt-6-sol", "openai/gpt-6-sol", 2, 0.2, 10),
            ("gpt-6-luna", "openai/gpt-6-luna", 0.1, 0.01, 0.5),
            ("gpt-5.6-sol", "openai/gpt-5.6-sol", 4, 0.4, 20),
            ("gpt-5.6-terra", "openai/gpt-5.6-terra", 2, 0.2, 12),
            ("gpt-5.6-luna", "openai/gpt-5.6-luna", 0.2, 0.02, 1.2),
            ("gpt-5.5", "openai/gpt-5.5", 5, 0.5, 30),
            ("gpt-5.5-pro", "openai/gpt-5.5-pro", 30, 30, 180),
            ("gpt-5.4", "openai/gpt-5.4", 2.5, 0.25, 15),
            ("gpt-5.4-pro", "openai/gpt-5.4-pro", 30, 30, 180),
            ("gpt-5.4-mini", "openai/gpt-5.4-mini", 0.75, 0.075, 4.5),
            ("gpt-5.4-nano", "openai/gpt-5.4-nano", 0.2, 0.02, 1.25),
            ("gpt-5.3-codex", "openai/gpt-5.3-codex", 1.75, 0.175, 14),
            ("gpt-5.2", "openai/gpt-5.2", 1.75, 0.175, 14),
            ("gpt-5.2-pro", "openai/gpt-5.2-pro", 21, 21, 168),
            ("gpt-5.2-codex", "openai/gpt-5.2-codex", 1.75, 0.175, 14),
            ("gpt-5.1", "openai/gpt-5.1", 1.25, 0.125, 10),
            ("gpt-5.1-codex", "openai/gpt-5.1-codex", 1.25, 0.125, 10),
            ("gpt-5.1-codex-max", "openai/gpt-5.1-codex-max", 1.25, 0.125, 10),
            ("gpt-5.1-codex-mini", "openai/gpt-5.1-codex-mini", 0.25, 0.025, 2),
            ("gpt-5", "openai/gpt-5", 1.25, 0.125, 10),
            ("gpt-5-pro", "openai/gpt-5-pro", 15, 15, 120),
            ("gpt-5-mini", "openai/gpt-5-mini", 0.25, 0.025, 2),
            ("gpt-5-nano", "openai/gpt-5-nano", 0.05, 0.005, 0.4),
            ("gpt-5-codex", "openai/gpt-5-codex", 1.25, 0.125, 10),
            ("codex-mini-latest", "openai/codex-mini-latest", 1.5, 0.375, 6),
            ("gpt-4.1", "openai/gpt-4.1", 2, 0.5, 8),
            ("gpt-4.1-mini", "openai/gpt-4.1-mini", 0.4, 0.1, 1.6),
            ("gpt-4.1-nano", "openai/gpt-4.1-nano", 0.1, 0.025, 0.4),
            ("gpt-4o", "openai/gpt-4o", 2.5, 1.25, 10),
            ("gpt-4o-mini", "openai/gpt-4o-mini", 0.15, 0.075, 0.6),
            ("o3-pro", "openai/o3-pro", 20, 20, 80),
            ("o3", "openai/o3", 2, 0.5, 8),
            ("o4-mini", "openai/o4-mini", 1.1, 0.275, 4.4),
            ("o1-pro", "openai/o1-pro", 150, 150, 600),
            ("o1", "openai/o1", 15, 7.5, 60),
            ("o1-mini", "openai/o1-mini", 1.1, 0.55, 4.4),
            ("o3-mini", "openai/o3-mini", 1.1, 0.55, 4.4),
        ]

        for c in cases {
            XCTAssertEqual(Pricing.normalize(model: c.raw), c.canonical, c.raw)
            XCTAssertTrue(Pricing.priceIsExact(model: c.raw), c.raw)
            XCTAssertEqual(Pricing.cost(model: c.raw, tokens: .init(input: hundredK), at: date,
                                        billingInputTokens: hundredK), c.input / 10, accuracy: 0.000_001, c.raw)
            XCTAssertEqual(Pricing.cost(model: c.raw, tokens: .init(cacheRead: hundredK), at: date,
                                        billingInputTokens: hundredK), c.cached / 10, accuracy: 0.000_001, c.raw)
            XCTAssertEqual(Pricing.cost(model: c.raw, tokens: .init(output: hundredK), at: date,
                                        billingInputTokens: hundredK), c.output / 10, accuracy: 0.000_001, c.raw)
        }

        XCTAssertEqual(Pricing.normalize(model: "gpt-5.6"), "openai/gpt-5.6-sol")
        XCTAssertTrue(Pricing.priceIsExact(model: "gpt-5.6"))
        XCTAssertEqual(Pricing.normalize(model: "openrouter/openai/gpt-5.6-sol"), "openai/gpt-5.6-sol")
        XCTAssertEqual(Pricing.normalize(model: "my-sonnet-proxy/gpt-5.5"), "openai/gpt-5.5")
        for (snapshot, canonical) in [
            "gpt-5.5-2026-04-23": "openai/gpt-5.5",
            "gpt-5.5-pro-2026-04-23": "openai/gpt-5.5-pro",
            "gpt-5.4-2026-03-05": "openai/gpt-5.4",
            "gpt-5.4-pro-2026-03-05": "openai/gpt-5.4-pro",
            "gpt-5.4-mini-2026-03-17": "openai/gpt-5.4-mini",
            "gpt-5.4-nano-2026-03-17": "openai/gpt-5.4-nano",
            "gpt-5.2-2025-12-11": "openai/gpt-5.2",
            "gpt-5.2-pro-2025-12-11": "openai/gpt-5.2-pro",
            "gpt-5.1-2025-11-13": "openai/gpt-5.1",
            "gpt-5-2025-08-07": "openai/gpt-5",
            "gpt-5-pro-2025-10-06": "openai/gpt-5-pro",
            "gpt-5-mini-2025-08-07": "openai/gpt-5-mini",
            "gpt-5-nano-2025-08-07": "openai/gpt-5-nano",
            "gpt-4o-2024-11-20": "openai/gpt-4o",
        ] {
            XCTAssertEqual(Pricing.normalize(model: snapshot), canonical, snapshot)
            XCTAssertTrue(Pricing.priceIsExact(model: snapshot), snapshot)
        }
        XCTAssertEqual(Pricing.normalize(model: "gpt-5.6-codex"), "gpt-5.6-codex")
    }

    func testOpenAILongContextAndCacheWritePricing() {
        let date = Date(timeIntervalSince1970: 1_786_233_600)
        let tokens = TokenBreakdown(input: 100_000, output: 100_000,
                                    cacheRead: 100_000, cacheWrite: 100_000)

        XCTAssertEqual(Pricing.cost(model: "gpt-5.6-sol", tokens: tokens, at: date,
                                    billingInputTokens: 272_000), 2.94, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "gpt-5.6-sol", tokens: tokens, at: date,
                                    billingInputTokens: 272_001), 4.88, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "gpt-6-astra", tokens: tokens, at: date,
                                    billingInputTokens: 272_000), 7.35, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "gpt-6-astra", tokens: tokens, at: date,
                                    billingInputTokens: 272_001), 12.2, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "gpt-6-sol", tokens: tokens, at: date,
                                    billingInputTokens: 272_001), 2.44, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "gpt-6-luna", tokens: tokens, at: date,
                                    billingInputTokens: 272_001), 0.122, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "gpt-5.4-mini", tokens: tokens, at: date,
                                    billingInputTokens: 500_000), 0.5325, accuracy: 0.000_001,
                       "models without a long-context surcharge must keep their base price")
    }

    func testLiveBurnUsesCodexAbsolutePromptForLongContextPricing() {
        let now = Date(timeIntervalSince1970: 1_786_233_600)
        let record = RawRecord(
            provider: .codex, model: "gpt-5.6-sol", timestamp: now, cwd: "/p",
            tokens: TokenBreakdown(input: 10_000, output: 200),
            billingInputTokens: 300_001,
            toolName: nil, toolNames: [], messageId: nil,
            sessionKey: "codex-live", hasInterrupt: false
        )
        let result = FuelCalculator.liveSessions(claudeRecords: [], codexRecords: [record], now: now)
        let expected = Pricing.cost(model: record.model, tokens: record.tokens, at: now,
                                    billingInputTokens: record.billingInputTokens)
        XCTAssertEqual(result.burnPerMin, expected, accuracy: 0.000_001)
    }

    func testCacheStatsIncludeCodexAndLongContextSavings() {
        let now = Date(timeIntervalSince1970: 1_786_233_600)
        let record = RawRecord(
            provider: .codex, model: "gpt-5.6-terra", timestamp: now, cwd: "/p",
            tokens: TokenBreakdown(input: 100_000, cacheRead: 900_000),
            billingInputTokens: 300_001,
            toolName: nil, toolNames: [], messageId: nil,
            sessionKey: "codex-cache", hasInterrupt: false
        )
        let cache = Aggregator.cacheStat(from: [record])
        XCTAssertEqual(cache.hitRate, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(cache.savedUSD, 3.24, accuracy: 0.000_001)
    }

    /// `normalize` resolved the Opus family with a bare `contains("opus")` that returned
    /// 4.8, so every `claude-opus-5` record was renamed and merged into the 4.8 row —
    /// 11,616 turns and ~$1,127 hidden on one real machine. Each known tier must
    /// resolve to itself, while unknown versions retain their ID and approximate price.
    func testEveryModelTierResolvesToItselfAndUnknownsRemainVisible() {
        for (raw, expected) in [
            ("claude-opus-5-5", "anthropic/claude-opus-5-5"),
            ("claude-opus-5", "anthropic/claude-opus-5"),
            ("claude-opus-4-8", "anthropic/claude-opus-4-8"),
            ("claude-opus-4-7", "anthropic/claude-opus-4-7"),
            ("claude-opus-4-6", "anthropic/claude-opus-4-6"),
            ("claude-opus-4-5-20251101", "anthropic/claude-opus-4-5"),
            ("claude-opus-4-1-20250805", "anthropic/claude-opus-4-1"),
            ("claude-fable-5-1", "anthropic/claude-fable-5-1"),
            ("claude-fable-5", "anthropic/claude-fable-5"),
            ("claude-mythos-5-1", "anthropic/claude-mythos-5-1"),
            ("claude-mythos-5", "anthropic/claude-mythos-5"),
            ("claude-sonnet-5", "anthropic/claude-sonnet-5"),
            ("claude-sonnet-4-6", "anthropic/claude-sonnet-4-6"),
        ] {
            XCTAssertEqual(Pricing.normalize(model: raw), expected, "\(raw) must keep its own identity")
        }

        // Dated variants match a known base; future versions remain distinct.
        XCTAssertEqual(Pricing.normalize(model: "claude-opus-5-20260315"), "anthropic/claude-opus-5")
        XCTAssertEqual(Pricing.normalize(model: "claude-opus-9"), "claude-opus-9")
        XCTAssertFalse(Pricing.priceIsExact(model: "claude-opus-9"))
        XCTAssertEqual(Pricing.normalize(model: "claude-sonnet-9"), "claude-sonnet-9")
        XCTAssertFalse(Pricing.priceIsExact(model: "claude-sonnet-9"))

        // The bare selectors Claude Code writes when you pick a family, not a version.
        XCTAssertEqual(Pricing.normalize(model: "opus"), "anthropic/claude-opus-5-5")
        XCTAssertEqual(Pricing.normalize(model: "sonnet"), "anthropic/claude-sonnet-5")
    }

    /// "Unknown → newest" is only safe while every known tier is enumerated. Opus 4.1 costs
    /// 3x the 4.5+ tiers and Mythos 5 is Fable-tier, so a missing row for either is not a
    /// cosmetic gap — it bills real usage at a fraction of its rate, with no visible symptom.
    func testOffTierModelsAreNotBilledAtTheNewestTiersRate() {
        let millionTokens = TokenBreakdown(input: 1_000_000, output: 1_000_000,
                                           cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let july = Date(timeIntervalSince1970: 1_783_555_200)

        // $5 + $25 + $0.5 + $6.25 = $36.75 (5-minute cache writes).
        XCTAssertEqual(Pricing.cost(model: "claude-opus-5", tokens: millionTokens, at: july),
                       36.75, accuracy: 0.000_001)
        // $15 + $75 + $1.5 + $18.75 = $110.25 — 3x the Opus 5 tier.
        XCTAssertEqual(Pricing.cost(model: "claude-opus-4-1", tokens: millionTokens, at: july),
                       110.25, accuracy: 0.000_001)
        XCTAssertEqual(Pricing.cost(model: "claude-mythos-5", tokens: millionTokens, at: july),
                       Pricing.cost(model: "claude-fable-5", tokens: millionTokens, at: july),
                       accuracy: 0.000_001, "Mythos 5 shares the Fable 5 tier")

        XCTAssertTrue(Pricing.priceIsExact(model: "claude-opus-5"))
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-opus-4-1"))
        XCTAssertTrue(Pricing.priceIsExact(model: "claude-mythos-5"))

        XCTAssertEqual(Pricing.displayName(forCanonicalKey: "anthropic/claude-opus-5"), "Opus 5")
        XCTAssertEqual(Pricing.displayName(forCanonicalKey: "anthropic/claude-mythos-5"), "Mythos 5")
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

    /// The Claude usage endpoint moved its model-scoped weekly caps out of the top-level
    /// `seven_day_opus` / `seven_day_sonnet` fields (now always null) and into a `limits[]`
    /// array, where a sub-cap is a `weekly_scoped` entry naming its model. Parsing only the
    /// legacy tiers therefore dropped the Fable weekly cap on the floor — the panel showed
    /// 5h and 7d and nothing else. Guards the new path, the legacy fallback, and the merge
    /// rule that keeps the two from double-counting.
    func testClaudeQuotaParsesScopedWeeklyLimits() {
        // Real response shape (2026-08): legacy sub-cap fields null, limits[] carries Fable.
        let current = ClaudeQuotaFetcher.parse(Data("""
        {"five_hour":{"utilization":37.0,"resets_at":"2026-08-03T23:40:00.568125+00:00"},
         "seven_day":{"utilization":14.0,"resets_at":"2026-08-09T23:00:00.568151+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,
         "limits":[
           {"kind":"session","group":"session","percent":37,"severity":"normal","resets_at":"2026-08-03T23:40:00.568125+00:00","scope":null,"is_active":true},
           {"kind":"weekly_all","group":"weekly","percent":14,"severity":"normal","resets_at":"2026-08-09T23:00:00.568151+00:00","scope":null,"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":13,"severity":"normal","resets_at":"2026-08-09T23:00:00.568411+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
        """.utf8))
        XCTAssertEqual(current.map(\.label), ["5h", "7d", "7d·Fable"],
                       "limits[] must yield all three windows with no duplicates from the legacy tiers")
        guard let fable = current.first(where: { $0.label == "7d·Fable" }) else {
            return XCTFail("the Fable weekly sub-cap must survive parsing")
        }
        XCTAssertEqual(fable.remaining, 0.87, accuracy: 0.000_001, "percent is utilization, not remaining")
        XCTAssertNotNil(fable.resetAt)
        XCTAssertEqual(fable.id, "claude-7d·Fable",
                       "the id is the forecast key the panel pins a scoped line to")

        // Legacy-only accounts (no limits[] at all) keep working unchanged.
        let legacy = ClaudeQuotaFetcher.parse(Data(
            #"{"five_hour":{"utilization":7.0,"resets_at":null},"seven_day":{"utilization":20.0,"resets_at":null},"seven_day_opus":null,"seven_day_sonnet":{"utilization":2.0,"resets_at":null}}"#.utf8))
        XCTAssertEqual(legacy.map(\.label), ["5h", "7d", "7d·Sonnet"])

        // A limits[] missing a window (renamed kind) falls back to the legacy tier for it
        // instead of dropping the row; a label both sources report resolves to limits[].
        let merged = ClaudeQuotaFetcher.parse(Data(
            #"{"five_hour":{"utilization":7.0,"resets_at":null},"seven_day":{"utilization":20.0,"resets_at":null},"limits":[{"kind":"weekly_all","percent":14,"resets_at":null,"scope":null}]}"#.utf8))
        XCTAssertEqual(merged.map(\.label).sorted(), ["5h", "7d"])
        XCTAssertEqual(merged.first { $0.label == "7d" }?.remaining ?? 0, 0.86, accuracy: 0.000_001,
                       "limits[] wins over the legacy tier for the same label")

        // Entries we can't label unambiguously are dropped, never rendered as a second
        // anonymous "7d" bar sitting next to the real one.
        let unlabelable = ClaudeQuotaFetcher.parse(Data(
            #"{"limits":[{"kind":"weekly_all","percent":10,"resets_at":null,"scope":null},{"kind":"weekly_scoped","percent":50,"resets_at":null,"scope":{"model":{"id":null,"display_name":null}}},{"kind":"future_kind","percent":90,"resets_at":null,"scope":null}]}"#.utf8))
        XCTAssertEqual(unlabelable.map(\.label), ["7d"])
    }

    func testCodexMenuQuotaUsesWeeklyWindow() {
        let windows = [
            QuotaWindow(provider: .codex, label: "5h", remaining: 0.91, resetAt: nil),
            QuotaWindow(provider: .codex, label: "7d", remaining: 0.26, resetAt: nil),
        ]

        XCTAssertEqual(windows.menuWindow(preferring: .codex)?.label, "7d")
    }

    func testCodexMenuQuotaNeverFallsBackToFiveHourWindow() {
        let codexFiveHourOnly = [
            QuotaWindow(provider: .codex, label: "5h", remaining: 0.91, resetAt: nil),
        ]
        XCTAssertNil(codexFiveHourOnly.menuWindow(preferring: .codex))

        let withClaude = [
            QuotaWindow(provider: .claude, label: "5h", remaining: 0.72, resetAt: nil),
        ] + codexFiveHourOnly
        XCTAssertEqual(withClaude.menuWindow(preferring: .codex)?.provider, .claude)
    }

    /// A model-scoped weekly cap burns on its own curve — for a model priced above the plan
    /// average it usually empties well before the overall week — so it needs its own
    /// depletion line, keyed by window id rather than the shared provider key.
    func testForecastCoversScopedWeeklyWindowsIndependently() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 12))!
        let day = 86_400.0, t0 = now.timeIntervalSince1970
        func pt(_ daysFromNow: Double, _ r: Double) -> (t: Double, r: Double) { (t: t0 + daysFromNow * day, r: r) }

        // Plan-wide week: 1.0 → 0.60 over 6 days ⇒ zero ~9 days out.
        let planWide = (0...6).map { pt(-6 + Double($0), 1.0 - 0.4 * (Double($0) / 6.0)) }
        // Scoped cap: 1.0 → 0.10 over the same 6 days ⇒ zero ~16h out, far sooner.
        let scoped = (0...6).map { pt(-6 + Double($0), 1.0 - 0.9 * (Double($0) / 6.0)) }
        let resetAt = now.addingTimeInterval(3 * day)

        XCTAssertNil(Forecaster.predictDepletion(samples: planWide, resetAt: resetAt, now: now),
                     "the plan-wide week resets before it empties — no line")
        guard let scopedZero = Forecaster.predictDepletion(samples: scoped, resetAt: resetAt, now: now) else {
            return XCTFail("the scoped cap empties before its reset and must project")
        }
        XCTAssertEqual(scopedZero.timeIntervalSince1970, t0 + (2.0 / 3.0) * day, accuracy: 3600)

        // The two windows are distinct history series, so a scoped label can't be folded
        // into the plan-wide one: QuotaWindow.id is what keeps them apart end-to-end.
        let planWindow = QuotaWindow(provider: .claude, label: "7d", remaining: 0.6, resetAt: resetAt)
        let scopedWindow = QuotaWindow(provider: .claude, label: "7d·Fable", remaining: 0.1, resetAt: resetAt)
        XCTAssertNotEqual(planWindow.id, scopedWindow.id)
        XCTAssertEqual(scopedWindow.label.split(separator: "·").dropFirst().joined(separator: "·"), "Fable",
                       "the scope suffix is what names the forecast line (\"Claude Fable\")")
    }

    func testTokenBreakdownMath() {
        var a = TokenBreakdown(input: 10, output: 5, cacheRead: 100)
        a += TokenBreakdown(input: 5, cacheWrite: 20)
        XCTAssertEqual(a.input, 15)
        XCTAssertEqual(a.cacheWrite, 20)
        XCTAssertEqual(a.total, 15 + 5 + 100 + 20)
    }
}
