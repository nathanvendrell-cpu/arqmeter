import XCTest
@testable import ArqmeterCore

final class ClaudeMenuStabilityTests: XCTestCase {
    private let received = Date(timeIntervalSince1970: 1_791_364_800)
    private func report(fiveReset: Double = 1_791_377_400, used: Double = 86) throws -> ClaudeQuotaReport {
        try .decodeStatusLine(Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(used),\"resets_at\":\(fiveReset)},\"seven_day\":{\"used_percentage\":76,\"resets_at\":1791432000}}}".utf8), receivedAt: received)
    }
    func testIdleKeepsOriginalReceiptWithoutCallingItCurrent() throws {
        let value = try report(), later = received.addingTimeInterval(600)
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: value, cli: nil, at: later)
        XCTAssertTrue(snapshot.isLastKnown)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: snapshot.readout), "14 % - 24 %")
        XCTAssertEqual(snapshot.readout?.observedAt, received)
        XCTAssertNil(value.current(at: later)) // Existing strict freshness contract preserved.
        XCTAssertFalse(ClaudeMenuQuotaSnapshot.make(statusLine: value, cli: nil, at: received).isLastKnown)
    }
    func testResetInvalidatesOnlyItsOwnWindowNotToHundredPercent() throws {
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: try report(fiveReset: received.addingTimeInterval(300).timeIntervalSince1970),
            cli: nil, at: received.addingTimeInterval(300))
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: snapshot.readout), "— - 24 %")
        XCTAssertNil(ClaudeMenuQuotaMode.fiveHour.text(readout: snapshot.readout))
        XCTAssertNil(ClaudeMenuQuotaSnapshot.make(statusLine: try report(), cli: nil,
            at: Date(timeIntervalSince1970: 1_791_432_000)).readout)
    }
    func testNewReceiptImmediatelyReplacesLastKnownAndClearsMarker() throws {
        let later = received.addingTimeInterval(600)
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1791377400},"seven_day":{"used_percentage":80,"resets_at":1791432000}}}"#.utf8)
        let value = try ClaudeQuotaReport.decodeStatusLine(data, receivedAt: later)
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: value, cli: nil, at: later)
        XCTAssertFalse(snapshot.isLastKnown)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: snapshot.readout), "10 % - 20 %")
    }
    func testInvalidFutureAndMissingReceiptsRemainUnavailable() throws {
        XCTAssertNil(ClaudeMenuQuotaSnapshot.make(statusLine: nil, cli: nil, at: received).readout)
        XCTAssertNil(ClaudeMenuQuotaSnapshot.make(statusLine: try report(), cli: nil,
            at: received.addingTimeInterval(-6)).readout)
        let invalid = try ClaudeQuotaReport.decodeStatusLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":1791377400}}}"#.utf8), receivedAt: received)
        XCTAssertNil(ClaudeMenuQuotaSnapshot.make(statusLine: invalid, cli: nil, at: received.addingTimeInterval(600)).readout)
    }
    func testUnknownResetDoesNotExtendCLIReceiptIndefinitely() throws {
        let cli = try ClaudeCLIQuotaReport.parse(finalScreen: "Current session\n10% used\nResets tomorrow", observedAt: received)
        XCTAssertNil(ClaudeMenuQuotaSnapshot.make(statusLine: nil, cli: cli, at: received.addingTimeInterval(600)).readout)
    }
    func testStaleSurfacesStaySeparateAndLatestReceiptWins() throws {
        let cli = try ClaudeCLIQuotaReport.parse(finalScreen: "Current session\n10% used\nResets in 2h", observedAt: received.addingTimeInterval(60))
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: try report(), cli: cli, at: received.addingTimeInterval(600))
        XCTAssertTrue(snapshot.isLastKnown)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: snapshot.readout), "90 % - —")
        XCTAssertEqual(snapshot.readout?.observedAt, cli.observedAt)
    }
    func testImpossibleOldReceiptCannotSurviveBeyondWindowDuration() throws {
        let value = try report(fiveReset: received.addingTimeInterval(10 * 3600).timeIntervalSince1970)
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: value, cli: nil, at: received.addingTimeInterval(5 * 3600))
        XCTAssertNil(snapshot.readout?.session)
        XCTAssertNotNil(snapshot.readout?.weekly)
    }
}
