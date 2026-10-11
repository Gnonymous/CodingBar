import XCTest
@testable import CodingBarCore

final class StatisticsRegressionTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
    private let noGit = GitCorrelator.RangeOutputs(today: .init(), week: .init(), month: .init())

    func testLatestModelPricesAndAliases() {
        let cases: [(String, String, Double, Double, Double, Double, Double)] = [
            ("gpt-6.1-sol", "openai/gpt-6.1-sol", 2, 10, 0.1, 2.5, 2.5),
            ("claude-sonnet-5-5", "anthropic/claude-sonnet-5-5", 2, 10, 0.1, 2.5, 4),
            ("claude-haiku-5-5", "anthropic/claude-haiku-5-5", 0.1, 0.5, 0.01, 0.125, 0.2),
        ]
        for (raw, canonical, input, output, read, write5m, write1h) in cases {
            XCTAssertEqual(Pricing.normalize(model: raw), canonical)
            XCTAssertEqual(Pricing.normalize(model: canonical), canonical)
            XCTAssertTrue(Pricing.priceIsExact(model: raw))
            XCTAssertEqual(Pricing.cost(model: raw, tokens: .init(input: 10_000), at: now), input / 100, accuracy: 1e-9)
            XCTAssertEqual(Pricing.cost(model: raw, tokens: .init(output: 10_000), at: now), output / 100, accuracy: 1e-9)
            XCTAssertEqual(Pricing.cost(model: raw, tokens: .init(cacheRead: 10_000), at: now), read / 100, accuracy: 1e-9)
            XCTAssertEqual(Pricing.cost(model: raw, tokens: .init(cacheWrite: 10_000), at: now), write5m / 100, accuracy: 1e-9)
            XCTAssertEqual(Pricing.cost(model: raw, tokens: .init(cacheWrite: 10_000), at: now,
                                        cacheWrite1h: 10_000), write1h / 100, accuracy: 1e-9)
        }
        for (alias, canonical) in [
            "sonnet": "anthropic/claude-sonnet-5-5",
            "sonnet-5.5": "anthropic/claude-sonnet-5-5",
            "claude-sonnet-5-5-20261001": "anthropic/claude-sonnet-5-5",
            "haiku": "anthropic/claude-haiku-5-5",
            "haiku-5.5": "anthropic/claude-haiku-5-5",
            "claude-haiku-5-5-20261001": "anthropic/claude-haiku-5-5",
        ] {
            XCTAssertEqual(Pricing.normalize(model: alias), canonical)
        }
        XCTAssertEqual(Pricing.displayName(forCanonicalKey: "openai/gpt-6.1-sol"), "GPT-6.1 Sol")
        XCTAssertEqual(Pricing.displayName(forCanonicalKey: "anthropic/claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(Pricing.displayName(forCanonicalKey: "anthropic/claude-haiku-5-5"), "Haiku 5.5")
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-4-5", tokens: .init(input: 10_000), at: now), 0.01, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(model: "claude-sonnet-5", tokens: .init(cacheRead: 10_000), at: now), 0.002, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(model: "gpt-6-sol", tokens: .init(cacheRead: 10_000), at: now), 0.002, accuracy: 1e-9)
    }

    func testHaikuPromptBoundaryIncludesCacheReadsAndBothWriteDurations() {
        var tokens = TokenBreakdown(input: 20_000, output: 2_000, cacheRead: 50_000, cacheWrite: 30_000, reasoning: 1_000)
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-5-5", tokens: tokens, at: now,
                                    cacheWrite1h: 10_000), 0.0085, accuracy: 1e-9)
        tokens.input += 1
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-5-5", tokens: tokens, at: now,
                                    cacheWrite1h: 10_000), 0.0425005, accuracy: 1e-9)
        let key = Pricing.normalize(model: "claude-haiku-5-5")
        XCTAssertEqual(Pricing.inputPrice(forCanonicalKey: key, billingInputTokens: 100_001), 0.5)
        XCTAssertEqual(Pricing.cacheReadPrice(forCanonicalKey: key, billingInputTokens: 100_001), 0.05)
    }

    func testGPT61PromptBoundaryUsesAbsolutePromptAndBillsReasoningOnce() {
        let tokens = TokenBreakdown(input: 20_000, output: 2_000, cacheRead: 50_000, cacheWrite: 30_000, reasoning: 1_000)
        XCTAssertEqual(Pricing.cost(model: "gpt-6.1-sol", tokens: tokens, at: now,
                                    billingInputTokens: 272_000), 0.15, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(model: "gpt-6.1-sol", tokens: tokens, at: now,
                                    billingInputTokens: 272_001), 0.285, accuracy: 1e-9)
    }

    func testAllProjectsRemainAvailableAndDetailsReconcile() {
        let records = (0..<12).flatMap { project in
            [0, 3, 20].map { days in
                record(project: "/CodingBar/tests/project-\(project)",
                       date: Calendar.current.date(byAdding: .day, value: -days, to: now)!,
                       tokens: .init(input: 100 + project, output: 30, cacheRead: 500))
            }
        }
        let snap = Aggregator.aggregate(claudeRecords: [], codexRecords: records, now: now, gitOutput: noGit)
        XCTAssertEqual(snap.projects.count, 12)
        for overview in snap.overviews {
            XCTAssertEqual(overview.projects.count, 12)
            XCTAssertEqual(overview.projects.reduce(0) { $0 + $1.tokens.total }, overview.spend.tokens.total)
            XCTAssertEqual(overview.projects.reduce(0) { $0 + $1.cost }, overview.spend.cost, accuracy: 1e-9)
            for project in overview.projects {
                XCTAssertEqual(project.models.reduce(0) { $0 + $1.tokens.total }, project.tokens.total)
                XCTAssertEqual(project.trend.reduce(0) { $0 + $1.tokens }, project.tokens.total)
                XCTAssertEqual(project.models.reduce(0) { $0 + $1.cost }, project.cost, accuracy: 1e-9)
                XCTAssertEqual(project.trend.reduce(0) { $0 + $1.cost }, project.cost, accuracy: 1e-9)
            }
        }
    }

    func testSnapshotCutoffIncludesNowAndExcludesLaterRecords() {
        let cutoff = now.addingTimeInterval(15 * 60)
        let records = [
            record(project: "/CodingBar/tests/active", date: cutoff.addingTimeInterval(-1), tokens: .init(input: 100)),
            record(project: "/CodingBar/tests/active", date: cutoff, tokens: .init(input: 200)),
            record(project: "/CodingBar/tests/future", date: cutoff.addingTimeInterval(1), tokens: .init(input: 500)),
            record(project: "/CodingBar/tests/future", date: cutoff.addingTimeInterval(3600), tokens: .init(input: 1000)),
        ]
        let snap = Aggregator.aggregate(claudeRecords: [], codexRecords: records, now: cutoff, gitOutput: noGit)
        XCTAssertEqual(snap.menu.todayTokens, 300)
        for overview in snap.overviews {
            XCTAssertEqual(overview.spend.tokens.total, 300)
            XCTAssertEqual(overview.models.reduce(0) { $0 + $1.tokens.total }, 300)
            XCTAssertEqual(overview.projects.reduce(0) { $0 + $1.tokens.total }, 300)
            XCTAssertEqual(overview.trend.reduce(0) { $0 + $1.tokens }, 300)
            XCTAssertEqual(overview.trend.reduce(0) { $0 + $1.cost }, overview.spend.cost, accuracy: 1e-9)
        }
    }

    func testCodexDirectoryChangesApplyToModernAndLegacyUsage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["cwd": "/project-a"]],
            ["type": "turn_context", "payload": ["cwd": "/project-b"]],
            legacyUsage(total: 100, last: 100),
            ["type": "turn_context", "payload": ["cwd": "/project-c", "model": "gpt-6.1-sol"]],
            legacyUsage(total: 300, last: 200),
            ["type": "turn_context", "payload": ["cwd": "/project-d", "model": "gpt-6-astra"]],
            ["type": "token_usage_record", "timestamp": "2026-10-11T02:00:00Z",
             "payload": ["response_id": "response-1", "usage": ["input_tokens": 300, "output_tokens": 10]]],
            ["type": "turn_context", "payload": ["cwd": "", "model": "gpt-6.1-sol"]],
            ["type": "token_usage_record", "timestamp": "2026-10-11T02:01:00Z",
             "payload": ["response_id": "response-2", "usage": ["input_tokens": 400, "output_tokens": 20]]],
        ]
        let lines = try rows.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let records = CodexScanner.parseFile(url)
        XCTAssertEqual(records.map(\.cwd), ["/project-b", "/project-c", "/project-d", "/project-d"])
        XCTAssertEqual(records.map(\.model), ["unknown", "gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-sol"])
        XCTAssertEqual(records.map(\.tokens.total), [100, 200, 310, 420])
    }

    private func legacyUsage(total: Int, last: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": "2026-10-11T01:00:00Z", "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "output_tokens": 0],
            "last_token_usage": ["input_tokens": last, "output_tokens": 0]]]]
    }

    private func record(project: String, date: Date, tokens: TokenBreakdown) -> RawRecord {
        RawRecord(provider: .codex, model: "gpt-6.1-sol", timestamp: date, cwd: project,
                  tokens: tokens, toolName: nil, toolNames: [], messageId: nil,
                  sessionKey: project, hasInterrupt: false)
    }
}
