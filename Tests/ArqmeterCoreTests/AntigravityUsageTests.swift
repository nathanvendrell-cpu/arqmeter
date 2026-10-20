import Foundation
import XCTest
import SQLite3
@testable import ArqmeterCore

final class AntigravityUsageTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T16:00:00Z")!

    private func quota(_ entries: String) -> GeminiQuotaSnapshot? {
        GeminiQuotaReport.parseLanguageServerConfig(Data("{\"clientModelConfigs\":[\(entries)]}".utf8), observedAt: now)
    }

    func testMissingQuotaIsNotZeroAndNonGeminiIsNotAFallback() {
        XCTAssertNil(quota(#"{"label":"Gemini","quotaInfo":{"resetTime":"2026-10-27T12:00:00Z"}}"#))
        XCTAssertNil(quota(#"{"label":"Claude","modelId":"claude-sonnet","quotaInfo":{"remainingFraction":0.8}}"#))
        XCTAssertNil(quota(#"{"label":"Gemini","quotaInfo":{"remainingFraction":true}}"#))
        XCTAssertNil(quota(#"{"label":"Gemini","quotaInfo":{"remainingFraction":-0.2}}"#))
        XCTAssertNil(quota(#"{"label":"Gemini","quotaInfo":{"remainingFraction":1.2}}"#))
        XCTAssertNil(quota(""))
    }

    func testMeasuredZeroAndNoInventedWindowOrReset() throws {
        let snapshot = try XCTUnwrap(quota(#"{"label":"Gemini 4 Argon (High)","modelId":"gemini-4-argon-high","quotaInfo":{"remainingFraction":0}}"#))
        XCTAssertEqual(snapshot.primaryWindow.remainingPercent, 0)
        XCTAssertEqual(snapshot.primaryWindow.usedPercent, 100)
        XCTAssertNil(snapshot.primaryWindow.windowMinutes)
        XCTAssertNil(snapshot.primaryWindow.resetsAt)
        let report = GeminiQuotaReport(observedAt: now, snapshot: snapshot, lastKnown: snapshot)
        XCTAssertFalse(GeminiMenuQuotaSnapshot.make(report: report, at: now).isLastKnown)
        XCTAssertTrue(GeminiMenuQuotaSnapshot.make(report: report, at: now.addingTimeInterval(181)).isLastKnown)
    }

    func testExpiredAndFutureReceiptsAreUnavailable() throws {
        let snapshot = try XCTUnwrap(quota(#"{"label":"Gemini","quotaInfo":{"remainingFraction":0.7,"resetTime":"2026-10-20T17:00:00Z"}}"#))
        let report = GeminiQuotaReport(observedAt: now, snapshot: snapshot, lastKnown: snapshot)
        XCTAssertNil(GeminiMenuQuotaSnapshot.make(report: report, at: now.addingTimeInterval(3600)).readout)
        XCTAssertNil(GeminiMenuQuotaSnapshot.make(report: report, at: now.addingTimeInterval(-60)).readout)
        let failedPoll = GeminiQuotaReport(observedAt: now, snapshot: nil, lastKnown: snapshot, diagnostic: "offline")
        XCTAssertTrue(GeminiMenuQuotaSnapshot.make(report: failedPoll, at: now).isLastKnown)
    }

    func testUnknownModelAndWorkspaceRemainUnknownAndDuplicateIsStable() throws {
        let file = URL(fileURLWithPath: "/fixture/brain/conversation/.system_generated/logs/transcript.jsonl")
        let message: [String: Any] = ["source": "MODEL", "status": "DONE", "step_index": 3,
            "created_at": "2026-10-20T15:00:00Z", "input_tokens": 30, "cache_read_tokens": 70, "output_tokens": 5]
        let record = try XCTUnwrap(GeminiAdapter.parse(message, session: nil, projectPath: nil, file: file))
        XCTAssertEqual(record.inputTokens, .measured(100))
        XCTAssertEqual(record.cachedInputTokens, .measured(70))
        XCTAssertNil(record.modelID)
        XCTAssertNil(record.providerID)
        XCTAssertNil(record.projectPath)
        XCTAssertEqual(record.sourceKind, .antigravitySessionLog)
        XCTAssertEqual(record.eventID, GeminiAdapter.parse(message, session: nil, projectPath: nil, file: file)?.eventID)
        var invalid = message
        invalid["input_tokens"] = -10
        XCTAssertNil(GeminiAdapter.parse(invalid, session: nil, projectPath: nil, file: file))
        invalid = message; invalid["status"] = "RUNNING"
        XCTAssertNil(GeminiAdapter.parse(invalid, session: nil, projectPath: nil, file: file))
        invalid = message; invalid["model"] = "claude-sonnet"
        XCTAssertEqual(GeminiAdapter.parse(invalid, session: nil, projectPath: nil, file: file)?.providerID, "anthropic")
    }

    func testRecentAndHistoricalPassesDeduplicateWithoutImportingFullTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arqmeter-antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let brain = root.appendingPathComponent("brain")
        let logs = brain.appendingPathComponent("conv-a/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let line = #"{"source":"MODEL","status":"DONE","step_index":1,"created_at":"2026-10-20T15:00:00Z","input_tokens":10,"cache_read_tokens":20,"output_tokens":4}"#
        try (line + "\n" + line + "\n").write(to: logs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logs.appendingPathComponent("transcript.jsonl").path)
        try (line.replacingOccurrences(of: "\"step_index\":1", with: "\"step_index\":2") + "\n")
            .write(to: logs.appendingPathComponent("transcript_full.jsonl"), atomically: true, encoding: .utf8)
        let source = HistoricalSource(harnessID: "gemini-cli", root: root.appendingPathComponent("missing-tmp"), antigravityBrainRoot: brain)
        let store = try HistoricalUsageStore(url: root.appendingPathComponent("history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store, sources: [source])
        let first = try engine.scanRecentGemini(now: now)
        XCTAssertEqual(first.filesScanned, 1)
        XCTAssertEqual(first.readFailures, 0)
        _ = try engine.scan(now: now)
        let second = try engine.scanRecentGemini(now: now)
        XCTAssertEqual(second.filesScanned, 0)
        let records = try store.records(harness: "gemini-cli", from: now.addingTimeInterval(-86400), to: now)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(UsageAggregate(records: records).inputTokens.value, 30)

        // Emulate the unfinished importer's checkpoint and invented model in
        // this disposable database only. Replaying must repair, not duplicate.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("history.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE checkpoints SET state=CAST(json_remove(CAST(state AS TEXT),'$.antigravityParserRevision') AS BLOB)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE events SET payload=CAST(json_set(CAST(payload AS TEXT),'$.modelID','gemini-4-argon-high','$.providerID','google') AS BLOB)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try engine.scanRecentGemini(now: now).filesScanned, 1)
        let repaired = try store.records(harness: "gemini-cli", from: now.addingTimeInterval(-86400), to: now)
        XCTAssertEqual(repaired.count, 1)
        XCTAssertNil(repaired.first?.modelID)
        XCTAssertNil(repaired.first?.providerID)
        XCTAssertEqual(repaired.first?.inputTokens.value, 30)
        XCTAssertEqual(try engine.scanRecentGemini(now: now).filesScanned, 0)
        let empty = HistoricalUsageEngine(store: store, sources: [])
        XCTAssertEqual(try empty.scanRecentGemini(now: now).diagnostic, "Source absente ou illisible")
    }
}
