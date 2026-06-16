import XCTest
@testable import CodingBarCore

final class SmokeTests: XCTestCase {
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
