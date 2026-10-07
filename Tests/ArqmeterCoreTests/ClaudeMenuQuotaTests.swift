import XCTest
@testable import ArqmeterCore

final class ClaudeMenuQuotaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_364_800)
    func readout(_ windows: String, at date: Date? = nil) throws -> ClaudePlanQuotaReadout? {
        let data = Data("{\"rate_limits\":{\(windows)}}".utf8)
        let report = try ClaudeQuotaReport.decodeStatusLine(data, receivedAt: now)
        return ClaudePlanQuotaReadout.makeCode(statusLine: report, cli: nil, at: date ?? now)
    }
    let five = #""five_hour":{"used_percentage":86,"resets_at":1791377400}"#
    let week = #""seven_day":{"used_percentage":76,"resets_at":1791432000}"#

    func testBothUsesFiveHoursThenWeekNotMostRestrictive() throws {
        let value = try readout("\(five),\(week)")
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: value), "14 % - 24 %")
        XCTAssertEqual(ClaudeMenuQuotaMode.fiveHour.text(readout: value), "14 %")
        XCTAssertEqual(ClaudeMenuQuotaMode.sevenDay.text(readout: value), "24 %")
        let reversed = try readout(#""five_hour":{"used_percentage":62,"resets_at":1791377400},"seven_day":{"used_percentage":76,"resets_at":1791432000}"#)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: reversed), "38 % - 24 %")
    }
    func testMissingWindowNeverUsesTheOtherAsFallback() throws {
        let weekly = try readout(week)
        XCTAssertNil(ClaudeMenuQuotaMode.fiveHour.text(readout: weekly))
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: weekly), "— - 24 %")
        let session = try readout(five)
        XCTAssertNil(ClaudeMenuQuotaMode.sevenDay.text(readout: session))
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: session), "14 % - —")
        XCTAssertNil(ClaudeMenuQuotaMode.both.text(readout: nil))
        XCTAssertNil(ClaudeMenuQuotaMode.both.text(readout: try readout("")))
    }
    func testStaleAndResetRemainUnavailable() throws {
        XCTAssertNil(ClaudeMenuQuotaMode.both.text(readout: try readout("\(five),\(week)", at: now.addingTimeInterval(180))))
        let expired = try readout(#""five_hour":{"used_percentage":86,"resets_at":1791364800},"seven_day":{"used_percentage":76,"resets_at":1791432000}"#)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: expired), "— - 24 %")
    }
    func testLiveReadingsChangeIndependentNumbers() throws {
        let earlier = try readout(#""five_hour":{"used_percentage":53,"resets_at":1791377400},"seven_day":{"used_percentage":75,"resets_at":1791432000}"#)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: earlier), "47 % - 25 %")
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: try readout("\(five),\(week)")), "14 % - 24 %")
    }
    func testZeroAndHundredAreRealValuesNotMissing() throws {
        let value = try readout(#""five_hour":{"used_percentage":100,"resets_at":1791377400},"seven_day":{"used_percentage":0,"resets_at":1791432000}"#)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.text(readout: value), "0 % - 100 %")
    }
    func testModePersistsAndDoesNotModifyOtherPreferences() throws {
        let name = "arqmeter-window-test.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { first.removePersistentDomain(forName: name) }
        first.set("keep", forKey: "unrelated")
        XCTAssertEqual(ClaudeMenuQuotaMode.load(from: first), .both)
        for mode in ClaudeMenuQuotaMode.allCases {
            mode.save(to: first)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
            XCTAssertEqual(ClaudeMenuQuotaMode.load(from: reopened), mode)
            XCTAssertEqual(reopened.string(forKey: "unrelated"), "keep")
        }
        first.set("unsupported-old-value", forKey: ClaudeMenuQuotaMode.preferenceKey)
        XCTAssertEqual(ClaudeMenuQuotaMode.load(from: first), .both)
        XCTAssertEqual(ClaudeMenuQuotaMode.both.periods, [.fiveHour, .sevenDay])
    }
}
