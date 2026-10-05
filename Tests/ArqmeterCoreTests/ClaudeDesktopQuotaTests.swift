import XCTest
@testable import ArqmeterCore

final class ClaudeDesktopQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Synthetic examples only; never saved in a user cache.
    private func report(session: Double = 72, weekly: Double = 31) throws -> ClaudeDesktopQuotaReport {
        try .init(meters: [
            .init(label: "Session actuelle", usedPercent: session, resetLabel: "Réinitialisation à 10:00"),
            .init(label: "Cette semaine", usedPercent: weekly, resetLabel: "Réinitialisation le jeudi 06:00")], observedAt: now)
    }
    func testIndependentRemainingWindowsAndProvenance() throws {
        let value = try report()
        let view = try XCTUnwrap(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil,
            desktop: value, desktopSelected: true, at: now))
        XCTAssertEqual(view.session?.remainingPercent, 28)
        XCTAssertEqual(view.weekly?.remainingPercent, 69)
        XCTAssertEqual(view.preferred?.period, .fiveHour)
        XCTAssertNil(view.session?.resetsAt, "Do not invent an epoch from a native label")
        XCTAssertTrue(view.provenance.contains("Application Claude"))
    }
    func testExhaustedSessionIsNotHiddenByWeekly() throws {
        let value = try report(session: 100, weekly: 12)
        XCTAssertEqual(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil,
            desktop: value, desktopSelected: true, at: now)?.preferred?.window.remainingPercent, 0)
    }
    func testContextAndProductSharesAreNeverQuota() {
        for label in ["Fenêtre de contexte", "Contexte", "Claude Code", "Crédits de session cloud", "Discussion"] {
            XCTAssertThrowsError(try ClaudeDesktopQuotaReport(meters: [.init(label: label, usedPercent: 64, resetLabel: nil)], observedAt: now))
        }
    }
    func testEmptyPartialAndConflictingMeters() throws {
        XCTAssertThrowsError(try ClaudeDesktopQuotaReport(meters: [], observedAt: now))
        let partial = try ClaudeDesktopQuotaReport(meters: [.init(label: "Limite de session", usedPercent: 42, resetLabel: nil)], observedAt: now)
        XCTAssertNotNil(partial.session); XCTAssertNil(partial.weekly)
        XCTAssertThrowsError(try ClaudeDesktopQuotaReport(meters: [
            .init(label: "Session actuelle", usedPercent: 42, resetLabel: nil),
            .init(label: "Limite de session", usedPercent: 43, resetLabel: nil)], observedAt: now))
    }
    func testInvalidMeterAndUnsafeResetRejected() {
        for value in [-1.0, 101, .nan, .infinity] { XCTAssertThrowsError(try report(session: value)) }
        XCTAssertThrowsError(try ClaudeDesktopQuotaReport(meters: [.init(label: "Session actuelle", usedPercent: 42, resetLabel: "https://example.test/private")], observedAt: now))
    }
    func testStaleDesktopNeverFallsBackToOtherAccount() throws {
        let value = try report()
        let later = now.addingTimeInterval(180)
        let cli = try ClaudeQuotaReport.decodeStatusLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":3,"resets_at":1800008000}}}"#.utf8), receivedAt: later)
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: cli, web: nil, desktop: value, desktopSelected: true, at: later))
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: cli, web: nil, desktop: nil, desktopSelected: true, at: now))
        XCTAssertEqual(ClaudePlanQuotaReadout.make(statusLine: cli, web: nil, desktop: value, desktopSelected: false, at: later)?.session?.remainingPercent, 97)
    }
    func testObservationAgeAndUnselectedSource() throws {
        let value = try report()
        XCTAssertNil(value.currentWindow(.fiveHour, at: now.addingTimeInterval(-6)))
        XCTAssertNil(value.currentWindow(.sevenDay, at: now.addingTimeInterval(180)))
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil, desktop: value, desktopSelected: false, at: now))
    }
    func testPercentageUnitMustBeProvenAndNativeLabelMustAgree() {
        let p = ClaudeDesktopQuotaReport.percentage
        XCTAssertEqual(p(14, 0, 100, "14 % utilisés", false), 14)
        XCTAssertEqual(p(0.14, 0, 1, "14 % utilisés", false), 14)
        XCTAssertEqual(p(0, nil, nil, "0 % utilisés", false), 0)
        XCTAssertEqual(p(100, nil, nil, "100 % used", false), 100)
        XCTAssertNil(p(0.14, nil, nil, "14 % utilisés", false))
        XCTAssertNil(p(14, 0, 100, "15 % utilisés", false))
        XCTAssertNil(p(1, 0, 100, "1 % used", true))
        XCTAssertNil(p(nil, 0, 100, nil, false))
        XCTAssertNil(p(0, nil, nil, "", false))
        XCTAssertNil(p(1, 0, 50, nil, false))
        XCTAssertNil(p(2, 0, 1, nil, false))
    }
    func testMachineNoiseDoesNotConsumeAnExtraPercentButRealDecimalsDo() throws {
        let fraction = try XCTUnwrap(ClaudeDesktopQuotaReport.percentage(
            value: 0.14, minimum: 0, maximum: 1, nativeUsedLabel: "14 % utilisés"))
        XCTAssertEqual(try report(session: fraction).session?.remainingPercent, 86)
        XCTAssertEqual(try report(session: 14.000000000000002).session?.remainingPercent, 86)
        let decimal = try XCTUnwrap(ClaudeDesktopQuotaReport.percentage(
            value: 0.141, minimum: 0, maximum: 1, nativeUsedLabel: "14,1 % utilisés"))
        XCTAssertEqual(decimal, 14.1, accuracy: 0.00000000000001)
        XCTAssertEqual(try report(session: decimal).session?.remainingPercent, 85)
        XCTAssertEqual(try report(session: 14.1).session?.usedPercent, 14.1)
    }
}
