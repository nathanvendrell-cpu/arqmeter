import Foundation
import XCTest
@testable import ArqmeterCore

final class UsageParserTests: XCTestCase {
    func testFileEventRecoveryPolicy() {
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000001]), .bootstrap)
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000002]), .bootstrap)
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000004]), .bootstrap)
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000020]), .recreateStream)
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000008]), .recreateStream)
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000200]), .reconcile)
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00000800]), .reconcile)
        XCTAssertEqual(
            FileEventRecoveryPolicy.action(for: [0x00000200, 0x00000002, 0x00000020]),
            .recreateStream
        )
        XCTAssertEqual(FileEventRecoveryPolicy.action(for: [0x00001000]), .refresh)
    }

    func testEventStreamRetryPersistsUntilAStartSucceeds() {
        var state = EventStreamRetryState()

        state.recordStartResult(succeeded: false)
        XCTAssertTrue(state.shouldRetryOnFallbackTick)

        state.recordStartResult(succeeded: false)
        XCTAssertTrue(state.shouldRetryOnFallbackTick)

        state.recordStartResult(succeeded: true)
        XCTAssertFalse(state.shouldRetryOnFallbackTick)
        XCTAssertFalse(state.shouldRetryOnFallbackTick)
    }

    func testPollingCadenceReconcilesEveryTwelveSeconds() {
        var cadence = PollingCadenceState()
        XCTAssertTrue(cadence.shouldReconcile(at: 100))

        cadence.recordRefresh(at: 100)
        XCTAssertFalse(cadence.shouldReconcile(at: 102))
        XCTAssertFalse(cadence.shouldReconcile(at: 111.999))
        XCTAssertTrue(cadence.shouldReconcile(at: 112))

        cadence.recordRefresh(at: 112)
        XCTAssertFalse(cadence.shouldReconcile(at: 122))
        XCTAssertTrue(cadence.shouldReconcile(at: 124))
    }

    func testParsesWeeklyCodexLimit() throws {
        let line = #"{"timestamp":"2026-09-09T09:15:07.765Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82.0,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let snapshot = try XCTUnwrap(UsageParser.snapshot(from: Data(line.utf8)))
        XCTAssertEqual(snapshot.remainingPercent, 18)
    }

    func testParsesOfficialWeeklyCodexLimit() throws {
        let line = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":85,"windowDurationMins":10080,"resetsAt":2000000000}}}}}"#
        let snapshot = try XCTUnwrap(OfficialUsageParser.snapshot(from: Data(line.utf8)))
        XCTAssertEqual(snapshot.remainingPercent, 15)
    }

    func testRejectsUnrelatedOfficialResponse() {
        let line = #"{"id":1,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":85,"windowDurationMins":10080,"resetsAt":2000000000}}}}}"#
        XCTAssertNil(OfficialUsageParser.snapshot(from: Data(line.utf8)))
    }

    func testOfficialExchangeWaitsForQuotaAfterInitialization() {
        let initialize = #"{"id":1,"result":{"userAgent":"fixture"}}"# + "\n"
        let notice = #"{"method":"notice","params":{}}"# + "\n"
        let quota = #"{"id":2,"result":{"rateLimitsByLimitId":{}}}"# + "\n"
        XCTAssertFalse(OfficialUsageParser.containsCompletedResponse(Data(initialize.utf8)))
        XCTAssertFalse(OfficialUsageParser.containsCompletedResponse(Data((initialize + notice).utf8)))
        XCTAssertTrue(OfficialUsageParser.containsCompletedResponse(Data((initialize + notice + quota).utf8)))
    }

    func testOfficialExchangeWaitsForPartialReplyToFinish() {
        let first = #"{"id":2,"result":{"rateLimitsByLimitId":"#
        XCTAssertFalse(OfficialUsageParser.containsCompletedResponse(Data(first.utf8)))
        XCTAssertTrue(OfficialUsageParser.containsCompletedResponse(Data((first + "{}}}\n").utf8)))
    }

    func testOfficialExchangeStopsOnErrorWithoutInventingQuota() {
        let error = Data(#"{"id":2,"error":{"code":-32603,"message":"fixture failure"}}"#.utf8)
        XCTAssertTrue(OfficialUsageParser.containsCompletedResponse(error))
        XCTAssertNil(OfficialUsageParser.snapshot(from: error))
        XCTAssertFalse(OfficialUsageParser.containsCompletedResponse(Data()))
        XCTAssertFalse(OfficialUsageParser.containsCompletedResponse(Data("malformed\n".utf8)))
    }

    func testOfficialQuotaMissingIsNotZero() {
        let missing = Data(#"{"id":2,"result":{"rateLimitsByLimitId":{}}}"#.utf8)
        XCTAssertTrue(OfficialUsageParser.containsCompletedResponse(missing))
        XCTAssertNil(OfficialUsageParser.snapshot(from: missing))
    }

    func testOfficialWeeklyQuotaCanBeInSecondaryWindow() throws {
        let line = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":69,"windowDurationMins":10080,"resetsAt":2000000000}}}}}"#
        XCTAssertEqual(try XCTUnwrap(OfficialUsageParser.snapshot(from: Data(line.utf8))).remainingPercent, 31)
    }

    func testOfficialQuotaRefreshUsesLatestReply() throws {
        let older = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":2000000000}}}}}"#
        let newer = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":69,"windowDurationMins":10080,"resetsAt":2000000000}}}}}"#
        XCTAssertEqual(try XCTUnwrap(OfficialUsageParser.snapshot(from: Data(older.utf8))).remainingPercent, 32)
        XCTAssertEqual(try XCTUnwrap(OfficialUsageParser.snapshot(from: Data(newer.utf8))).remainingPercent, 31)
    }

    func testOfficialQuotaValidityEndsAtReset() throws {
        let line = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":69,"windowDurationMins":10080,"resetsAt":2000000000}}}}}"#
        let snapshot = try XCTUnwrap(OfficialUsageParser.snapshot(from: Data(line.utf8)))
        XCTAssertTrue(snapshot.isValid(at: Date(timeIntervalSince1970: 1_999_999_999)))
        XCTAssertFalse(snapshot.isValid(at: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testParsesOfficialDailyTokens() throws {
        let line = #"{"id":2,"result":{"summary":{"lifetimeTokens":100},"dailyUsageBuckets":[{"startDate":"2026-09-26","tokens":42}]}}"#
        let result = try XCTUnwrap(OfficialDailyUsageParser.dailyTokens(from: Data(line.utf8)))
        XCTAssertEqual(result, [DailyTokenUsage(day: "2026-09-26", tokens: 42)])
    }

    func testParsesExactCodexLimitFromSecondaryWindow() throws {
        let line = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":5,"window_minutes":300,"resets_at":2000000000},"secondary":{"used_percent":78,"window_minutes":10080,"resets_at":2000000000}}}}"#
        XCTAssertEqual(try XCTUnwrap(UsageParser.snapshot(from: Data(line.utf8))).remainingPercent, 22)
    }

    func testRejectsSeparateBengalfoxWeeklyLimit() {
        let line = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox","secondary":{"used_percent":0,"window_minutes":10080,"resets_at":2000000000}}}}"#
        XCTAssertNil(UsageParser.snapshot(from: Data(line.utf8)))
    }

    func testRejectsOtherWindowAndLimit() {
        let shortWindow = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":10,"window_minutes":300,"resets_at":2000000000}}}}"#
        let otherLimit = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"other","primary":{"used_percent":10,"window_minutes":10080,"resets_at":2000000000}}}}"#
        XCTAssertNil(UsageParser.snapshot(from: Data(shortWindow.utf8)))
        XCTAssertNil(UsageParser.snapshot(from: Data(otherLimit.utf8)))
    }

    func testClampsAndRoundsRemainingPercentage() throws {
        let line = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":78.4,"window_minutes":10080,"resets_at":2000000000}}}}"#
        XCTAssertEqual(try XCTUnwrap(UsageParser.snapshot(from: Data(line.utf8))).remainingPercent, 22)
    }

    func testSnapshotExpiresAtReset() throws {
        let line = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":78,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let snapshot = try XCTUnwrap(UsageParser.snapshot(from: Data(line.utf8)))
        XCTAssertTrue(snapshot.isValid(at: Date(timeIntervalSince1970: 1_999_999_999)))
        XCTAssertFalse(snapshot.isValid(at: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testExpiredLatestSnapshotBecomesOneHundredPercent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let line = #"{"timestamp":"2026-09-08T23:03:14.102Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":78,"window_minutes":10080,"resets_at":2000000000}}}}"#
        try Data((line + "\n").utf8).write(to: directory.appendingPathComponent("rollout-expired.jsonl"))

        let result = UsageDirectoryScanner(sessionsDirectory: directory)
            .bootstrap(now: Date(timeIntervalSince1970: 2_000_000_001))
        XCTAssertEqual(result?.remainingPercent, 100)
    }

    func testScannerFindsNewestMatchingEventAcrossFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = #"{"timestamp":"2026-09-08T20:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let ignored = #"{"timestamp":"2026-09-08T23:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":99,"window_minutes":300,"resets_at":2000000000}}}}"#
        let separateNewerLimit = #"{"timestamp":"2026-09-08T23:30:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox","secondary":{"used_percent":0,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let newer = #"{"timestamp":"2026-09-08T22:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":78,"window_minutes":10080,"resets_at":2000000000}}}}"#
        try Data((older + "\n" + ignored + "\n" + separateNewerLimit + "\n").utf8).write(to: directory.appendingPathComponent("rollout-a.jsonl"))
        try Data((newer + "\n").utf8).write(to: directory.appendingPathComponent("rollout-b.jsonl"))

        XCTAssertEqual(
            UsageDirectoryScanner(sessionsDirectory: directory).bootstrap(now: Date(timeIntervalSince1970: 1_900_000_000))?.remainingPercent,
            22
        )
    }

    func testScannerIgnoresPartialTrailingLineAndReadsItAfterCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("rollout-partial.jsonl")
        let first = #"{"timestamp":"2026-09-08T20:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":30,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let second = #"{"timestamp":"2026-09-08T22:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":78,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        try Data((first + "\n" + second[..<split]).utf8).write(to: file)

        let scanner = UsageDirectoryScanner(sessionsDirectory: directory)
        XCTAssertEqual(scanner.bootstrap(now: Date(timeIntervalSince1970: 1_900_000_000))?.remainingPercent, 70)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((second[split...] + "\n").utf8))
        try handle.close()

        XCTAssertEqual(scanner.refresh(now: Date(timeIntervalSince1970: 1_900_000_000))?.remainingPercent, 22)
    }

    func testScannerFindsNewNestedRotatedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = #"{"timestamp":"2026-09-09T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":81,"window_minutes":10080,"resets_at":2000000000}}}}"#
        try Data((old + "\n").utf8).write(to: directory.appendingPathComponent("rollout-old.jsonl"))

        let scanner = UsageDirectoryScanner(sessionsDirectory: directory)
        XCTAssertEqual(scanner.bootstrap(now: Date(timeIntervalSince1970: 1_900_000_000))?.remainingPercent, 19)

        let nested = directory.appendingPathComponent("rotated/day", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let new = #"{"timestamp":"2026-09-09T09:15:07.765Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":2000000000}}}}"#
        try Data((new + "\n").utf8).write(to: nested.appendingPathComponent("rollout-new.jsonl"))

        XCTAssertEqual(scanner.refresh(now: Date(timeIntervalSince1970: 1_900_000_000))?.remainingPercent, 18)
    }

    func testScannerKeepsHighestUsageWithinSameResetCycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let used82 = #"{"timestamp":"2026-09-09T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":1789437499}}}}"#
        let staleUsed81 = #"{"timestamp":"2026-09-09T09:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":81,"window_minutes":10080,"resets_at":1789437499}}}}"#
        let accurateFile = directory.appendingPathComponent("rollout-accurate.jsonl")
        let staleFile = directory.appendingPathComponent("rollout-stale-newer.jsonl")
        try Data((used82 + "\n").utf8).write(to: accurateFile)
        try Data((staleUsed81 + "\n").utf8).write(to: staleFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_788_935_000)],
            ofItemAtPath: accurateFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_788_938_000)],
            ofItemAtPath: staleFile.path
        )

        let result = UsageDirectoryScanner(sessionsDirectory: directory)
            .bootstrap(now: Date(timeIntervalSince1970: 1_788_940_000))
        XCTAssertEqual(result?.remainingPercent, 18)
    }

    func testScannerAllowsLowerUsageForNewResetCycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldCycle = #"{"timestamp":"2026-09-09T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":2000000000}}}}"#
        let newCycle = #"{"timestamp":"2026-09-09T09:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":1,"window_minutes":10080,"resets_at":2000600000}}}}"#
        try Data((oldCycle + "\n" + newCycle + "\n").utf8)
            .write(to: directory.appendingPathComponent("rollout-new-reset.jsonl"))

        let result = UsageDirectoryScanner(sessionsDirectory: directory)
            .bootstrap(now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(result?.remainingPercent, 99)
    }

    func testScannerTreatsSmallResetTimestampJitterAsSameCycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let used82 = #"{"timestamp":"2026-09-09T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":1789437499}}}}"#
        let staleUsed81 = #"{"timestamp":"2026-09-09T09:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":81,"window_minutes":10080,"resets_at":1789437503}}}}"#
        try Data((used82 + "\n" + staleUsed81 + "\n").utf8)
            .write(to: directory.appendingPathComponent("rollout-reset-jitter.jsonl"))

        let result = UsageDirectoryScanner(sessionsDirectory: directory)
            .bootstrap(now: Date(timeIntervalSince1970: 1_788_940_000))
        XCTAssertEqual(result?.remainingPercent, 18)
        XCTAssertEqual(result?.resetsAt, Date(timeIntervalSince1970: 1_789_437_503))
    }

    func testScannerAcceptsHigherUsageWhenCodexRevisesResetTimestampBackwards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = #"{"timestamp":"2026-09-09T10:44:27.077Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":84,"window_minutes":10080,"resets_at":1789437499}}}}"#
        let current = #"{"timestamp":"2026-09-09T17:20:48.875Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":95,"window_minutes":10080,"resets_at":1789113013}}}}"#
        try Data((old + "\n" + current + "\n").utf8)
            .write(to: directory.appendingPathComponent("rollout-revised-reset.jsonl"))

        let result = UsageDirectoryScanner(sessionsDirectory: directory)
            .bootstrap(now: Date(timeIntervalSince1970: 1_788_940_000))
        XCTAssertEqual(result?.remainingPercent, 5)
        XCTAssertEqual(result?.resetsAt, Date(timeIntervalSince1970: 1_789_113_013))
    }

    func testScannerDoesNotLetOlderReportWithLaterResetOverrideCurrentUsage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let current = #"{"timestamp":"2026-09-09T17:20:48.875Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":95,"window_minutes":10080,"resets_at":1789113013}}}}"#
        let stale = #"{"timestamp":"2026-09-09T10:44:27.077Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":83,"window_minutes":10080,"resets_at":1789437499}}}}"#
        try Data((current + "\n" + stale + "\n").utf8)
            .write(to: directory.appendingPathComponent("rollout-stale-reset.jsonl"))

        let result = UsageDirectoryScanner(sessionsDirectory: directory)
            .bootstrap(now: Date(timeIntervalSince1970: 1_788_940_000))
        XCTAssertEqual(result?.remainingPercent, 5)
    }

    func testScannerRejectsSymbolicLinkRollout() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = parent.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let outside = parent.appendingPathComponent("outside.jsonl")
        let line = #"{"timestamp":"2026-09-09T09:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":2000000000}}}}"#
        try Data((line + "\n").utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("rollout-linked.jsonl"),
            withDestinationURL: outside
        )

        XCTAssertNil(UsageDirectoryScanner(sessionsDirectory: sessions).bootstrap())
    }

    func testIncrementalReadCapFindsEventAtTail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("rollout-large-append.jsonl")
        let initial = #"{"timestamp":"2026-09-09T08:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":81,"window_minutes":10080,"resets_at":1789437499}}}}"#
        try Data((initial + "\n").utf8).write(to: file)
        let scanner = UsageDirectoryScanner(sessionsDirectory: directory)
        XCTAssertEqual(scanner.bootstrap(now: Date(timeIntervalSince1970: 1_788_940_000))?.remainingPercent, 19)

        let latest = #"{"timestamp":"2026-09-09T09:00:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":82,"window_minutes":10080,"resets_at":1789437499}}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x78, count: 5 * 1024 * 1024))
        try handle.write(contentsOf: Data(("\n" + latest + "\n").utf8))
        try handle.close()

        XCTAssertEqual(scanner.refresh(now: Date(timeIntervalSince1970: 1_788_940_000))?.remainingPercent, 18)
    }
}
