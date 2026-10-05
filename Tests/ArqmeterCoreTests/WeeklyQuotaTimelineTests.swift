import XCTest
@testable import ArqmeterCore

final class WeeklyQuotaTimelineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Paris")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func observation(start: Date, used: Int, elapsed: Double = 604_700,
                             source: String = "codex", limit: String = "weekly") -> WeeklyQuotaObservation {
        WeeklyQuotaObservation(observedAt: start.addingTimeInterval(elapsed),
            resetsAt: start.addingTimeInterval(604_800), remainingPercent: 100 - used,
            source: source, limit: limit)
    }
    private func cycles(_ points: [WeeklyQuotaObservation]) -> [WeeklyQuotaCycle] {
        WeeklyQuotaTimeline.cycles(points, now: date(2027, 1, 31))
    }

    func testRealFourAndFiveCycleMonthsNoSyntheticFifth() {
        for (month, firstDay, count) in [(10, 7, 4), (12, 1, 5)] {
            let start = date(2026, month, firstDay)
            let points = (0..<count).map {
                observation(start: start.addingTimeInterval(Double($0) * 604_800), used: 20 + $0)
            }
            let result = WeeklyQuotaTimeline.inMonth(.init(year: 2026, month: month),
                cycles: cycles(points), calendar: calendar)
            XCTAssertEqual(result.count, count)
        }
        XCTAssertEqual(WeeklyQuotaTimeline.inMonth(.init(year: 2026, month: 10),
            cycles: [], calendar: calendar).count, 0)
    }

    func testAssignmentByStartAcrossMonthAndYear() {
        let a = observation(start: date(2026, 12, 29), used: 31)
        let b = observation(start: date(2027, 1, 5), used: 40)
        let all = cycles([a, b])
        XCTAssertEqual(WeeklyQuotaTimeline.inMonth(.init(year: 2026, month: 12),
            cycles: all, calendar: calendar).map(\.usedPercent), [31])
        XCTAssertEqual(WeeklyQuotaTimeline.inMonth(.init(year: 2027, month: 1),
            cycles: all, calendar: calendar).map(\.usedPercent), [40])
        XCTAssertEqual(QuotaCalendarMonth(year: 2026, month: 12).shifted(1, calendar: calendar),
                       QuotaCalendarMonth(year: 2027, month: 1))
    }

    func testCalendarMonthIsNotTwentyEightDays() {
        let february = QuotaCalendarMonth(year: 2028, month: 2).interval(calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.day], from: february.start, to: february.end).day, 29)
        let october = QuotaCalendarMonth(year: 2026, month: 10).interval(calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.day], from: october.start, to: october.end).day, 31)
    }

    func testLocalTimeZoneChangesMonthAssignment() {
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = utc.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23))!
        let all = cycles([observation(start: start, used: 22)])
        XCTAssertEqual(WeeklyQuotaTimeline.inMonth(.init(year: 2026, month: 10),
            cycles: all, calendar: calendar).count, 1)
        XCTAssertEqual(WeeklyQuotaTimeline.inMonth(.init(year: 2026, month: 9),
            cycles: all, calendar: utc).count, 1)
    }

    func testLatestObservationNotMaximumAndStableIdentity() {
        let start = date(2026, 10, 2)
        let first = observation(start: start, used: 40, elapsed: 1_000)
        let corrected = observation(start: start, used: 35, elapsed: 2_000)
        let one = cycles([first]), refreshed = cycles([corrected, first, corrected])
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed[0].usedPercent, 35)
        XCTAssertEqual(refreshed[0].id, one[0].id)
    }

    func testSmallResetJitterButDistinctRevisedBoundariesPreserved() {
        let first = observation(start: date(2026, 10, 2), used: 5, elapsed: 2_000)
        let jitter = WeeklyQuotaObservation(observedAt: first.observedAt.addingTimeInterval(30),
            resetsAt: first.resetsAt.addingTimeInterval(81), remainingPercent: 94,
            source: "codex", limit: "weekly")
        let revised = observation(start: date(2026, 10, 5), used: 8, elapsed: 1_000)
        let all = cycles([first, jitter, revised])
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].resetsAt, jitter.resetsAt)
        XCTAssertFalse(WeeklyQuotaTimeline.canConnect(all[0], all[1]))
        XCTAssertEqual(WeeklyQuotaTimeline.comparison(all[1], previous: all[0]), .missingOrRevisedCycle)
    }

    func testJitterDoesNotTransitivelyMergeDifferentResets() {
        let first = observation(start: date(2026, 10, 2), used: 5, elapsed: 2_000)
        let observations = [0.0, 250.0, 500.0].map {
            WeeklyQuotaObservation(observedAt: first.observedAt.addingTimeInterval($0),
                resetsAt: first.resetsAt.addingTimeInterval($0), remainingPercent: 95,
                source: "codex", limit: "weekly")
        }
        XCTAssertEqual(cycles(observations).count, 2)
    }

    func testMissingCycleIsNotZeroOrConnectedLine() {
        let start = date(2026, 10, 2)
        let all = cycles([observation(start: start, used: 30),
                          observation(start: start.addingTimeInterval(2 * 604_800), used: 20)])
        XCTAssertEqual(all.count, 2)
        XCTAssertFalse(WeeklyQuotaTimeline.canConnect(all[0], all[1]))
        XCTAssertEqual(WeeklyQuotaTimeline.comparison(all[1], previous: all[0]), .missingOrRevisedCycle)
    }

    func testPartialWeekNotComparedAgainstFullWeek() {
        let start = date(2026, 10, 2)
        let all = cycles([observation(start: start, used: 80),
                          observation(start: start.addingTimeInterval(604_800), used: 25, elapsed: 86_400)])
        XCTAssertEqual(WeeklyQuotaTimeline.comparison(all[1], previous: all[0]), .differentElapsedTime)
    }

    func testDeltaIsPercentagePointsWithEqualExposureNotTokenPercentage() {
        let start = date(2026, 10, 2)
        let all = cycles([observation(start: start, used: 60),
                          observation(start: start.addingTimeInterval(604_800), used: 45)])
        XCTAssertTrue(WeeklyQuotaTimeline.canConnect(all[0], all[1]))
        XCTAssertEqual(WeeklyQuotaTimeline.comparison(all[1], previous: all[0]), .comparable(points: -15))
    }

    func testDifferentSourceOrLimitCannotCompareOrMerge() {
        let start = date(2026, 10, 2)
        let a = cycles([observation(start: start, used: 30)])[0]
        let b = cycles([observation(start: start, used: 50, source: "other")])[0]
        let c = cycles([observation(start: start, used: 40, limit: "other")])[0]
        XCTAssertEqual(WeeklyQuotaTimeline.comparison(b, previous: a), .differentLimit)
        XCTAssertEqual(WeeklyQuotaTimeline.comparison(c, previous: a), .differentLimit)
        XCTAssertFalse(WeeklyQuotaTimeline.canConnect(a, b))
        XCTAssertEqual(cycles([a.latest, b.latest, c.latest]).count, 3)
    }

    func testInvalidExpiredAtObservationOrFutureReportsIgnored() {
        let now = date(2026, 10, 5)
        let invalid = [-1, 101].map {
            WeeklyQuotaObservation(observedAt: now.addingTimeInterval(-10), resetsAt: now.addingTimeInterval(500),
                remainingPercent: $0, source: "codex", limit: "weekly")
        }
        let future = WeeklyQuotaObservation(observedAt: now.addingTimeInterval(60),
            resetsAt: now.addingTimeInterval(604_800), remainingPercent: 80, source: "codex", limit: "weekly")
        let ended = WeeklyQuotaObservation(observedAt: now, resetsAt: now,
            remainingPercent: 80, source: "codex", limit: "weekly")
        XCTAssertTrue(WeeklyQuotaTimeline.cycles(invalid + [future, ended], now: now).isEmpty)
    }

    func testOnlyLatestBoundaryCurrentEvenWhenOlderResetsOverlap() {
        let start = date(2026, 10, 2)
        let a = observation(start: start, used: 60, elapsed: 86_400)
        let b = observation(start: start.addingTimeInterval(2 * 86_400), used: 5, elapsed: 1_000)
        let result = WeeklyQuotaTimeline.cycles([a, b], now: start.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(result.map(\.isCurrent), [false, true])
    }
}
