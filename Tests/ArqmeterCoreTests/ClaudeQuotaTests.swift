import XCTest
@testable import ArqmeterCore

final class ClaudeQuotaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1791228000)
    func decode(_ json: String) throws -> ClaudeQuotaReport {
        try .decodeStatusLine(Data(json.utf8), receivedAt: now)
    }
    func testRemainingWeeklyFirstAndNoTokenConversion() throws {
        let data = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":26.4,"resets_at":1791230000},"five_hour":{"used_percentage":80,"resets_at":1791229000}},"context_window":{"used_percentage":99},"version":"2.1.199"}"#)
        XCTAssertEqual(data.current(at: now)?.window.remainingPercent, 73)
        XCTAssertEqual(data.current(at: now)?.period, "7 jours")
        XCTAssertEqual(data.cliVersion, "2.1.199")
    }
    func testMissingQuotaIsNotFullAndContextIsIgnored() throws {
        XCTAssertNil(try decode(#"{"context_window":{"used_percentage":26},"cost":{"total_cost_usd":4}}"#).current(at: now))
        XCTAssertNil(try decode(#"{"rate_limits":null}"#).current(at: now))
        XCTAssertNil(try decode(#"{"rate_limits":{}}"#).current(at: now))
    }
    func testIndependentWindowsAndResetBoundary() throws {
        let report = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":1791228000},"five_hour":{"used_percentage":100,"resets_at":1791229000}}}"#)
        XCTAssertEqual(report.current(at: now)?.window.remainingPercent, 0)
        XCTAssertEqual(report.current(at: now)?.period, "5 heures")
        XCTAssertNil(report.current(at: Date(timeIntervalSince1970: 1791229000)))
    }
    func testStaleFutureAndInvalidAreNotCurrent() throws {
        let report = try decode(#"{"rate_limits":{"seven_day":{"used_percentage":0,"resets_at":1791230000}}}"#)
        XCTAssertEqual(report.current(at: now)?.window.remainingPercent, 100)
        XCTAssertNil(report.current(at: now.addingTimeInterval(180)))
        XCTAssertNil(report.current(at: now.addingTimeInterval(-6)))
        XCTAssertNil(try decode(#"{"rate_limits":{"seven_day":{"used_percentage":-1,"resets_at":1791230000}}}"#).current(at: now))
        XCTAssertNil(try decode(#"{"rate_limits":{"seven_day":{"used_percentage":101,"resets_at":1791230000}}}"#).current(at: now))
    }
    func testPartialOrWrongSchemaNotAcceptedAsOAuthCache() throws {
        XCTAssertNil(try decode(#"{"rate_limits":{"five_hour":{"used_percentage":7}}}"#).current(at: now))
        XCTAssertNil(try decode(#"{"seven_day":{"utilization":31,"resets_at":"2026-06-18T03:59:59Z"}}"#).current(at: now))
        XCTAssertThrowsError(try decode(#"{"rate_limits":{"seven_day":{"used_percentage":true,"resets_at":1791230000}}}"#))
    }
    func testCacheHasOnlyQuotaMetadataAndKeepsPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("quota.json")
        let report = try decode(#"{"session_id":"PRIVATE_SESSION","transcript_path":"PRIVATE_PATH","secret":"PRIVATE_SECRET","rate_limits":{"seven_day":{"used_percentage":20,"resets_at":1791230000}}}"#)
        try report.save(url: url)
        XCTAssertEqual(ClaudeQuotaReport.read(url: url), report)
        XCTAssertFalse(try String(contentsOf: url).contains("PRIVATE_"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let absent = try decode(#"{}"#); try absent.save(url: url)
        XCTAssertNil(ClaudeQuotaReport.read(url: url)?.current(at: now))
    }
    func testOversizedAndMalformedInputRejected() {
        XCTAssertThrowsError(try ClaudeQuotaReport.decodeStatusLine(Data(repeating: 32, count: 256 * 1024 + 1), receivedAt: now))
        XCTAssertThrowsError(try decode("not json"))
    }
}
