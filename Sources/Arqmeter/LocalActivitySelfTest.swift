import Foundation
import ArqmeterCore

enum LocalActivitySelfTest {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arqmeter-live-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let directory = root.appendingPathComponent(
            String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-fixture.jsonl")
        let time = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        let meta = #"{"type":"session_meta","payload":{"cwd":"/tmp/FixtureProject","model_provider":"openai"}}"#
        let context = #"{"type":"turn_context","payload":{"model":"gpt-6-sol"}}"#
        func token(_ input: Int, _ output: Int, _ cache: Int, _ cumulative: Int) -> String {
            "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cached_input_tokens\":\(cache)},\"total_token_usage\":{\"total_tokens\":\(cumulative)}}}}"
        }
        let first = token(10, 1, 4, 11)
        let second = token(10, 2, 6, 23)
        try Data("\(meta)\n\(context)\n\(first)\n\(second)\n\(second)\n".utf8).write(to: file)
        let scanner = LocalActivityStore(sessionsDirectory: root)
        let baseline = scanner.refresh(now: now)
        let baselineMinute = ConsumptionWindow.local(events: baseline.events, sampledAt: now,
                                                     scanComplete: baseline.scanComplete, range: .minute)
        guard baseline.total == 23, baseline.cachedInput == 10,
              baselineMinute.total == 23, baselineMinute.tokensPerSecond == Double(23) / 60,
              baseline.lastFiveNonCached == 13, baseline.byProject.first?.name == "FixtureProject",
              baseline.byProject.first?.path == "/tmp/FixtureProject",
              baseline.recent.count == 2,
              baseline.unifiedEvents.count == 2,
              baseline.unifiedEvents.allSatisfy({ $0.sourceKind == .codexSessionLog &&
                  $0.providerID == "openai" && $0.modelID == "gpt-6-sol" && !$0.eventID.isEmpty }),
              baseline.tokens(between: now.addingTimeInterval(-11), and: now.addingTimeInterval(-9)) == 23,
              baseline.tokens(between: now.addingTimeInterval(-25 * 60 * 60), and: now) == nil
        else { throw Failure.incorrectBaseline }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(token(5, 2, 1, 30).utf8))
        let partial = scanner.refresh(now: now)
        guard partial.total == 23 else { throw Failure.partialLineCounted }
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let updated = scanner.refresh(now: now)
        let updatedMinute = ConsumptionWindow.local(events: updated.events, sampledAt: now,
                                                    scanComplete: updated.scanComplete, range: .minute)
        let expiredMinute = ConsumptionWindow.local(events: updated.events, sampledAt: now.addingTimeInterval(61),
                                                    scanComplete: updated.scanComplete, range: .minute)
        let retainedTenMinutes = ConsumptionWindow.local(events: updated.events, sampledAt: now.addingTimeInterval(61),
                                                         scanComplete: updated.scanComplete, range: .tenMinutes)
        guard updated.total == 30, updated.cachedInput == 11,
              updated.lastFiveNonCached == 19, updated.recent.count == 3,
              updatedMinute.total == 30, updatedMinute.tokensPerSecond == 0.5,
              expiredMinute.total == 0, expiredMinute.tokensPerSecond == 0,
              retainedTenMinutes.total == 30, retainedTenMinutes.tokensPerSecond == 0.05,
              TokenDialGeometry.fraction(amount: updatedMinute.tokensPerSecond, maximum: 1) == 0.5,
              TokenDialGeometry.fraction(amount: expiredMinute.tokensPerSecond, maximum: 1) == 0 else {
            throw Failure.incrementalMismatch
        }
        let repeated = scanner.refresh(now: now)
        guard repeated.total == updated.total else { throw Failure.duplicateCounted }

        let secondFile = directory.appendingPathComponent("rollout-same-name.jsonl")
        let secondMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/another/FixtureProject"}}"#
        try Data("\(secondMeta)\n\(token(10, 0, 0, 10))\n".utf8).write(to: secondFile)
        let distinct = scanner.refresh(now: now)
        guard distinct.byProject.count == 2,
              Set(distinct.byProject.map(\.path)) == Set(["/tmp/FixtureProject", "/tmp/another/FixtureProject"]),
              distinct.total == 40 else { throw Failure.projectIdentityMismatch }
        try FileManager.default.removeItem(at: secondFile)

        let cycleFile = directory.appendingPathComponent("rollout-cycle-fixture.jsonl")
        let reset = now.addingTimeInterval(24 * 60 * 60)
        let cycleStart = reset.addingTimeInterval(-7 * 24 * 60 * 60)
        let older = reset.addingTimeInterval(-14 * 24 * 60 * 60)
        func cycleEvent(_ date: Date, _ count: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: date)
            return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(count)}}}}"
        }
        let cycleLines = [cycleEvent(older.addingTimeInterval(-30), 2),
                          cycleEvent(older.addingTimeInterval(30), 12),
                          cycleEvent(cycleStart.addingTimeInterval(-30), 32),
                          cycleEvent(cycleStart.addingTimeInterval(30), 45),
                          cycleEvent(now.addingTimeInterval(-30), 75)]
        try Data((cycleLines.joined(separator: "\n") + "\n").utf8).write(to: cycleFile)
        let history = CycleHistoryReader(directory: root).read(resetAt: reset, daily: [], now: now)
        guard history.previousLocal == 30, history.currentLocal == 73,
              history.localComplete else {
            fputs("Cycle obtenu : précédent \(history.previousLocal), actuel \(history.currentLocal), complet \(history.localComplete)\n", stderr)
            throw Failure.cycleMismatch
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let previousStart = reset.addingTimeInterval(-14 * 24 * 60 * 60)
        let days = (1...6).map { offset in
            DailyTokenUsage(day: dayFormatter.string(from: previousStart.addingTimeInterval(Double(offset) * 24 * 60 * 60)),
                            tokens: 100)
        }
        let boundaryDay = dayFormatter.string(from: cycleStart)
        let withLowBoundary = CycleHistoryReader(directory: root).read(resetAt: reset,
            daily: days + [DailyTokenUsage(day: boundaryDay, tokens: 10)], now: now)
        let withHighBoundary = CycleHistoryReader(directory: root).read(resetAt: reset,
            daily: days + [DailyTokenUsage(day: boundaryDay, tokens: 900)], now: now)
        guard withLowBoundary.previousAccountFullDaysTokens == 600,
              withHighBoundary.previousAccountFullDaysTokens == 600 else { throw Failure.accountEstimateDrift }

        let quotaURL = root.appendingPathComponent("history/quota.json")
        let store = QuotaHistoryStore(url: quotaURL)
        let firstReset = now.addingTimeInterval(7 * 24 * 60 * 60)
        let nextReset = now.addingTimeInterval(14 * 24 * 60 * 60)
        func quota(_ percent: Int, _ seconds: TimeInterval, _ reset: Date) -> UsageSnapshot {
            UsageSnapshot(remainingPercent: percent, timestamp: now.addingTimeInterval(seconds), resetsAt: reset)
        }
        guard store.record(quota(50, 0, firstReset)),
              !store.record(quota(50, 1, firstReset)),
              store.record(quota(49, 2, firstReset)),
              store.record(quota(51, 3, firstReset)),
              store.record(quota(100, 4, nextReset)),
              !store.record(quota(48, 1, firstReset)),
              store.points.count == 4,
              QuotaHistoryStore(url: quotaURL).points == store.points
        else { throw Failure.quotaHistoryMismatch }

        try checkConsumptionTimeline()
    }

    private static func checkConsumptionTimeline() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ seconds: TimeInterval, _ input: Int64, _ output: Int64,
                   _ cached: Int64 = 0) -> LocalTokenEvent {
            LocalTokenEvent(date: now.addingTimeInterval(seconds), project: "Fixture",
                            projectPath: "/tmp/Fixture", session: "fixture",
                            input: input, output: output, cached: cached, cachedObserved: true)
        }
        let events = [event(-61, 20, 0), event(-60, 30, 0),
                      event(-59, 10, 1, 4), event(-10, 5, 2, 1),
                      event(0, 3, 4), event(1, 1_000, 0)]
        let minute = ConsumptionWindow.local(events: events, sampledAt: now,
                                              scanComplete: true, range: .minute)
        guard minute.total == 25, minute.input == 18, minute.output == 7,
              minute.cachedInput == 5, minute.nonCachedInput == 13,
              minute.buckets.count == 12,
              minute.buckets[0].tokens == 11, minute.buckets[9].tokens == 7,
              minute.buckets[11].tokens == 7,
              minute.buckets.compactMap(\.tokens).reduce(0, +) == minute.total else {
            throw Failure.consumptionTimelineMismatch
        }
        for range in [ConsumptionRange.tenMinutes, .hour, .day] {
            let window = ConsumptionWindow.local(events: events, sampledAt: now,
                                                 scanComplete: true, range: range)
            guard window.buckets.count == range.bucketCount,
                  window.buckets.compactMap(\.tokens).reduce(0, +) == window.total,
                  window.total == 75 else { throw Failure.consumptionTimelineMismatch }
        }
        let partial = ConsumptionWindow.local(events: events, sampledAt: now,
                                               scanComplete: false, range: .minute)
        guard partial.total == minute.total, !partial.scanComplete,
              partial.tokensPerSecond == nil else { throw Failure.consumptionTimelineMismatch }
        let today = UTCDay.calendar.startOfDay(for: now)
        let yesterday = UTCDay.calendar.date(byAdding: .day, value: -1, to: today)!
        let days = [ArchivedDailyTokens(day: UTCDay.string(yesterday), tokens: 100),
                    ArchivedDailyTokens(day: UTCDay.string(today), tokens: 200)]
        for range in [ConsumptionRange.week, .month] {
            let window = ConsumptionWindow.official(days: days, range: range, page: 0, now: now)
            let older = ConsumptionWindow.official(days: days, range: range, page: 1, now: now)
            guard window.buckets.count == range.bucketCount,
                  window.tokensPerSecond == nil,
                  window.reportedDays == 2, window.total == 300,
                  window.buckets[range.bucketCount - 1].tokens == 200,
                  window.buckets[range.bucketCount - 2].tokens == 100,
                  window.buckets[range.bucketCount - 3].tokens == nil,
                  older.total == nil, older.end == window.start else {
                throw Failure.consumptionTimelineMismatch
            }
        }
    }

    enum Failure: Error {
        case incorrectBaseline
        case partialLineCounted
        case incrementalMismatch
        case duplicateCounted
        case projectIdentityMismatch
        case cycleMismatch
        case accountEstimateDrift
        case quotaHistoryMismatch
        case consumptionTimelineMismatch
    }
}
