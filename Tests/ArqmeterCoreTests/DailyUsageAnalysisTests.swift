import XCTest
@testable import ArqmeterCore

final class DailyUsageAnalysisTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private var now: Date { date("2026-10-07T10:00:00Z") }
    private func row(_ id: String, at time: String = "2026-10-05T12:00:00Z", harness: String = "codex",
                     project: String? = "/fixture/alpha", input: UsageMeasurement<Int64> = .measured(100),
                     output: UsageMeasurement<Int64> = .measured(20), cache: UsageMeasurement<Int64> = .measured(80),
                     duration: UsageMeasurement<Double> = .unavailable) -> UnifiedUsageRecord {
        .init(eventID: id, timestamp: date(time), projectPath: project, sessionID: "fixture", harnessID: harness,
            providerID: nil, modelID: nil, inputTokens: input, outputTokens: output, cachedInputTokens: cache,
            reasoningTokens: .unavailable, costUSD: .unavailable, durationSeconds: duration,
            executionLocation: .unavailable, sourceKind: .codexSessionLog, provenance: "Synthetic fixture")
    }
    private func local(_ rows: [UnifiedUsageRecord], metric: DailyAnalysisMetric = .total, project: String? = nil,
                       period: DailyAnalysisPeriod = .week, page: Int = 0) -> DailyAnalysisWindow {
        .local(records: rows, harness: "codex", project: project, metric: metric,
            period: period, page: page, at: now, calendar: utc)
    }
    func testWeekIsMondayThroughSundayWithUnknownAndFutureDays() {
        let value = local([row("a"), row("b", at: "2026-10-06T12:00:00Z"), row("future", at: "2026-10-08T12:00:00Z")])
        XCTAssertEqual(value.interval.start, date("2026-10-05T00:00:00Z"))
        XCTAssertEqual(value.buckets.count, 7)
        XCTAssertEqual(value.total, 240)
        XCTAssertEqual(value.observedDays, 2)
        XCTAssertEqual(value.elapsedDays, 3)
        XCTAssertNil(value.buckets[2].value)
        XCTAssertTrue(value.buckets[2].isToday)
        XCTAssertTrue(value.buckets[3].isFuture)
        XCTAssertNil(value.buckets[3].value)
    }
    func testWholeMonthAndPreviousPeriodBoundaries() {
        let value = local([row("outside", at: "2026-09-30T23:59:59Z"), row("inside", at: "2026-10-01T00:00:00Z")], period: .month)
        XCTAssertEqual(value.buckets.count, 31)
        XCTAssertEqual(value.total, 120)
        XCTAssertEqual(local([], page: 1).interval.end, date("2026-10-05T00:00:00Z"))
        XCTAssertEqual(local([], period: .month, page: 1).buckets.count, 30)
        XCTAssertEqual(local([], page: -5).interval, local([]).interval)
    }
    func testMeasuredZeroIsNotMissingAndEstimatesAreNotSummed() {
        let value = local([row("zero", input: .measured(0), output: .measured(0)),
            row("estimated", input: .estimated(500)), row("missing", input: .unavailable)])
        XCTAssertEqual(value.buckets[0].value, 0)
        XCTAssertEqual(value.buckets[0].measuredEvents, 1)
        XCTAssertEqual(value.buckets[0].eventCount, 3)
        XCTAssertTrue(value.metricIsPartial)
        XCTAssertNil(local([row("estimated", input: .estimated(500))]).total)
        XCTAssertNil(local([]).total)
    }
    func testDedupHarnessProjectAndOutsidePeriod() {
        let a = row("a")
        let value = local([a, a, row("other", harness: "claude-code"), row("beta", project: "/fixture/beta"),
            row("unknown", project: nil), row("old", at: "2026-10-04T23:59:59Z")], project: "/fixture/alpha")
        XCTAssertEqual(value.total, 120)
        XCTAssertEqual(value.buckets[0].eventCount, 1)
        XCTAssertEqual(local([a, row("unknown", project: nil)]).total, 240)
    }
    func testUncachedAndCacheNotDoubleCounted() {
        let a = row("a")
        XCTAssertEqual(local([a], metric: .uncached).total, 20)
        XCTAssertEqual(local([a], metric: .cache).total, 80)
        XCTAssertEqual(local([a], metric: .output).total, 20)
        XCTAssertNil(local([row("bad", cache: .measured(101))], metric: .uncached).total)
        XCTAssertNil(local([row("bad", cache: .measured(-1))], metric: .cache).total)
        XCTAssertNil(local([row("overflow", input: .measured(.max), output: .measured(1))]).total)
    }
    func testOfficialUTCZeroMissingDuplicatesAndNoFutureInjection() {
        let monday = date("2026-10-05T00:00:00Z"), tuesday = date("2026-10-06T00:00:00Z")
        let value = DailyAnalysisWindow.official(days: [(monday, 0), (monday, 0), (tuesday, 100),
            (tuesday, 200), (date("2026-10-08T00:00:00Z"), 999)], period: .week, page: 0, at: now)
        XCTAssertEqual(value.total, 0)
        XCTAssertEqual(value.observedDays, 1)
        XCTAssertEqual(value.buckets[0].value, 0)
        XCTAssertNil(value.buckets[1].value)
        XCTAssertNil(value.buckets[3].value)
        XCTAssertTrue(value.isOfficialAccount)
        XCTAssertEqual(value.timeZone.secondsFromGMT(), 0)
    }
    func testLocalDurationAndUnknownModelAreUsableWithoutFakeTokens() {
        let value = DailyAnalysisWindow.local(records: [row("local", harness: "ollama", input: .unavailable,
            output: .unavailable, cache: .unavailable, duration: .measured(120))], harness: "ollama",
            metric: .duration, period: .week, page: 0, at: now, calendar: utc)
        XCTAssertEqual(value.total, 120)
        XCTAssertEqual(value.metric.unit, "secondes")
    }
    func testCalendarDaysAcrossDSTAreNotFixed24HourBuckets() {
        var calendar = utc; calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let value = DailyAnalysisWindow.local(records: [], harness: "codex", metric: .total,
            period: .week, page: 0, at: date("2026-10-25T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(value.buckets.count, 7)
        XCTAssertEqual(value.buckets.last!.end.timeIntervalSince(value.buckets.last!.start), 25 * 3600)
    }
}
