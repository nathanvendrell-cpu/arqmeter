import XCTest
@testable import ArqmeterCore

final class ClaudeWebQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let url = URL(string: "https://claude.ai/settings/usage")!
    private func parse(_ json: String, url: URL? = nil) throws -> ClaudeWebQuotaReport {
        try .decode(Data(json.utf8), pageURL: url ?? self.url, loadedAt: now, observedAt: now)
    }
    // Synthetic parser fixtures ONLY. Never written into a user's quota cache.
    private let both = #"{"recognized":true,"session":{"usedPercent":25,"resetLabel":"Resets in 3 hr","resetISO":null},"weekly":{"usedPercent":4,"resetLabel":"Resets Thursday","resetISO":null}}"#
    func testIndependentWindowsAndMostConstrainingMenu() throws {
        let report = try parse(both)
        let view = try XCTUnwrap(ClaudePlanQuotaReadout.make(statusLine: nil, web: report, webSelected: true, at: now))
        XCTAssertEqual(view.session?.remainingPercent, 75)
        XCTAssertEqual(view.weekly?.remainingPercent, 96)
        XCTAssertEqual(view.preferred?.period, .fiveHour)
        XCTAssertNil(view.session?.resetsAt) // no invented epoch from prose
    }
    func testZeroIsRealExhaustionNotHiddenByWeekly() throws {
        let report = try parse(both.replacingOccurrences(of: "\"usedPercent\":25", with: "\"usedPercent\":100"))
        XCTAssertEqual(ClaudePlanQuotaReadout.make(statusLine: nil, web: report, webSelected: true, at: now)?.preferred?.window.remainingPercent, 0)
    }
    func testPartialWindowsAndMissingResetAreAccepted() throws {
        let report = try parse(#"{"recognized":true,"session":null,"weekly":{"usedPercent":5,"resetLabel":null,"resetISO":null}}"#)
        XCTAssertNil(report.currentWindow(.fiveHour, at: now))
        XCTAssertEqual(report.currentWindow(.sevenDay, at: now)?.remainingPercent, 95)
    }
    func testUnrecognizedAndContextOnlyAreNotQuota() {
        for json in [#"{"recognized":false}"#, #"{"recognized":true,"context_window":{"used_percentage":19}}"#] {
            XCTAssertThrowsError(try parse(json))
        }
    }
    func testOnlyExactOfficialHTTPSUsageRoute() {
        for value in ["http://claude.ai/settings/usage", "https://claude.ai/chat/x", "https://claude.ai.evil.test/settings/usage", "https://other.test/settings/usage"] {
            XCTAssertThrowsError(try parse(both, url: URL(string: value)!))
        }
    }
    func testInvalidValuesAndAmbiguousResetRejected() {
        for json in [both.replacingOccurrences(of: "\"usedPercent\":25", with: "\"usedPercent\":101"),
                     both.replacingOccurrences(of: "\"usedPercent\":25", with: "\"usedPercent\":null"),
                     both.replacingOccurrences(of: "\"resetISO\":null", with: "\"resetISO\":\"Thursday\"")] {
            XCTAssertThrowsError(try parse(json))
        }
    }
    func testStaleWebChoiceNeverFallsBackToOtherCLIAccount() throws {
        let web = try parse(both)
        let cli = try ClaudeQuotaReport.decodeStatusLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":7,"resets_at":1800008000}}}"#.utf8), receivedAt: now.addingTimeInterval(200))
        let later = now.addingTimeInterval(200)
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: cli, web: web, webSelected: true, at: later))
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: cli, web: nil, webSelected: true, at: later))
        XCTAssertEqual(ClaudePlanQuotaReadout.make(statusLine: cli, web: web, webSelected: false, at: later)?.session?.remainingPercent, 93)
    }
    func testCacheReceiptCannotRenewOldPageLoad() throws {
        XCTAssertThrowsError(try ClaudeWebQuotaReport.decode(Data(both.utf8), pageURL: url, loadedAt: now.addingTimeInterval(-60), observedAt: now))
        let report = try parse(both)
        XCTAssertNil(report.currentWindow(.sevenDay, at: now.addingTimeInterval(180)))
    }
    func testSuppliedResetDateExpiresIndependently() throws {
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(10))
        let report = try parse(both.replacingOccurrences(of: "\"resetISO\":null", with: "\"resetISO\":\"\(iso)\""))
        XCTAssertNotNil(report.currentWindow(.fiveHour, at: now))
        XCTAssertNil(report.currentWindow(.fiveHour, at: now.addingTimeInterval(11)))
    }
}
