import Foundation
import XCTest
@testable import ArqmeterCore

final class HistoricalUsageTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arqmeter-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func claudeLine(id: String, output: Int = 2,
                            timestamp: String = "2026-09-29T12:00:00Z") -> String {
        """
        {"type":"assistant","sessionId":"s1","timestamp":"\(timestamp)","cwd":"/work/Projet Beta","message":{"id":"\(id)","model":"claude-sonnet-4","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":\(output)}}}
        """
    }

    func testCodexProjectPeriodStreamsMeasuredSessionsAndKeepsBoundaryAndCoverage() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("codex")
        let meta = #"{"type":"session_meta","payload":{"id":"session-alpha","cwd":"/fixture/project-alpha","model_provider":"openai"}}"#
        func line(_ timestamp: String, cumulative: Int, input: Int, output: Int) -> String {
            """
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(cumulative)},"last_token_usage":{"input_tokens":\(input),"output_tokens":\(output),"cached_input_tokens":1}}}}
            """
        }
        try write([meta, line("2026-09-29T12:00:00Z", cumulative: 10, input: 8, output: 2),
                   line("2026-09-29T12:00:30Z", cumulative: 20, input: 7, output: 3),
                   line("2026-09-29T12:00:31Z", cumulative: 20, input: 7, output: 3),
                   line("2026-09-29T12:01:00Z", cumulative: 30, input: 6, output: 4),
                   line("2026-09-29T12:01:30Z", cumulative: 40, input: 5, output: 5)].joined(separator: "\n") + "\n",
                  to: source.appendingPathComponent("rollout-alpha.jsonl"))
        let betaMeta = #"{"type":"session_meta","payload":{"id":"session-beta","cwd":"/fixture/project-beta"}}"#
        try write(betaMeta + "\n" + line("2026-09-29T12:01:00Z", cumulative: 10, input: 8, output: 2) + "\n",
                  to: source.appendingPathComponent("rollout-beta.jsonl"))
        let oldMeta = #"{"type":"session_meta","payload":{"id":"session-old","cwd":"/fixture/project-alpha"}}"#
        try write(oldMeta + "\n" + line("2026-09-14T12:00:00Z", cumulative: 9, input: 6, output: 3) + "\n",
                  to: source.appendingPathComponent("rollout-old.jsonl"))
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "codex", root: source)])
        let start = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-09-29T12:01:00Z")!
        _ = try engine.scan(now: end)
        let period = try store.codexProjectActivity(from: start, to: end)
        XCTAssertEqual(period.eventCount, 3, "Start excluded, end included; no duplicated cumulative event")
        XCTAssertEqual(period.events.count, 2)
        XCTAssertEqual(period.events.first { $0.sessionID == "session-alpha" }?.input, 13)
        XCTAssertEqual(period.events.first { $0.sessionID == "session-alpha" }?.output, 7)
        XCTAssertEqual(period.events.first { $0.sessionID == "session-beta" }?.projectPath, "/fixture/project-beta")
        XCTAssertEqual(period.events.reduce(0) { $0 + $1.input + $1.output }, 30)
        XCTAssertFalse(period.scanComplete, "An indexed result before tracking began is not complete coverage")
        XCTAssertEqual(try store.codexProjectActivity(from: end, to: end.addingTimeInterval(40)).eventCount, 1)
        let week = try store.codexProjectActivity(from: end.addingTimeInterval(-7 * 24 * 60 * 60), to: end)
        let month = try store.codexProjectActivity(from: end.addingTimeInterval(-30 * 24 * 60 * 60), to: end)
        XCTAssertEqual(month.eventCount, week.eventCount + 1,
            "30-day local project history must include an older session without allocating account totals")
        XCTAssertEqual(month.events.reduce(0) { $0 + $1.input + $1.output },
                       week.events.reduce(0) { $0 + $1.input + $1.output } + 9)
        XCTAssertEqual(try store.latestEventDate(harness: "codex"), end.addingTimeInterval(30))
        XCTAssertNil(try store.latestEventDate(harness: "claude-code"))
    }

    func testRecentClaudeTailImportsWithinMinuteWithoutCompletingInventory() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        let file = temp.appendingPathComponent("claude/project/active.jsonl")
        try write(claudeLine(id: "active", timestamp: stamp) + "\n", to: file)
        let old = temp.appendingPathComponent("claude/project/old.jsonl")
        try write(claudeLine(id: "old", timestamp: stamp) + "\n", to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)],
                                              ofItemAtPath: old.path)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))])
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 1)
        XCTAssertEqual(try store.records(harness: "claude-code", from: now.addingTimeInterval(-60), to: now).count, 1)
        XCTAssertEqual(try store.records(harness: "claude-code", from: now.addingTimeInterval(11),
                                         to: now.addingTimeInterval(71)).count, 0,
                       "Rolling one-minute window must age out the old event")
        let before = try store.coverage(harness: "claude-code", from: now.addingTimeInterval(-60), to: now)
        XCTAssertNil(before.lastScan)
        XCTAssertFalse(before.inventoryComplete, "A tail pass is not a full inventory")
        engine.maxFilesPerSource = 1
        _ = try engine.scan(now: now)
        let partial = try store.coverage(harness: "claude-code", from: now.addingTimeInterval(-60), to: now)
        XCTAssertFalse(partial.inventoryComplete)
        _ = try engine.scanRecentClaude(now: now.addingTimeInterval(1))
        let after = try store.coverage(harness: "claude-code", from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(after.lastScan, partial.lastScan)
        XCTAssertEqual(after.inventoryComplete, partial.inventoryComplete)
    }

    func testRecentClaudeTailUsesCheckpointForPartialLineDedupAndRotation() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5))
        let file = temp.appendingPathComponent("claude/project/active.jsonl")
        try write(claudeLine(id: "m1", timestamp: stamp) + "\n" +
                  claudeLine(id: "m2", timestamp: stamp), to: file)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))])
        let start = now.addingTimeInterval(-60), end = now.addingTimeInterval(1)
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 1)
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 0)
        try append("\n", to: file)
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 1)
        XCTAssertEqual(try store.records(harness: "claude-code", from: start, to: end).count, 2)
        try append(claudeLine(id: "m1", output: 7, timestamp: stamp) + "\n", to: file)
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 1)
        let revised = try store.records(harness: "claude-code", from: start, to: end)
        XCTAssertEqual(revised.count, 2)
        XCTAssertEqual(revised.first { $0.eventID == "claude:s1:m1" }?.outputTokens, .measured(7))
        try write(claudeLine(id: "m3", timestamp: stamp) + "\n", to: file)
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 1)
        XCTAssertEqual(try store.records(harness: "claude-code", from: start, to: end).count, 3)
    }

    func testRecentClaudeAbsentSourceDoesNotAlterCodexOrCreateCoverage() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("missing"))])
        let result = try engine.scanRecentClaude()
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.filesScanned, 0)
        XCTAssertNil(try store.coverage(harness: "claude-code", from: .distantPast,
                                        to: Date()).lastScan)
        XCTAssertTrue(try store.records(harness: "codex", from: .distantPast, to: Date()).isEmpty)
    }

    func testRecentClaudeTailByteBudgetKeepsIncompleteLineForNextPass() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3))
        let file = temp.appendingPathComponent("claude/project/active.jsonl")
        try write(claudeLine(id: "bounded", timestamp: stamp) + "\n", to: file)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))])
        engine.recentClaudeMaxBytes = 20
        engine.recentClaudeMaxBytesPerFile = 20
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 0)
        engine.recentClaudeMaxBytes = 4096
        engine.recentClaudeMaxBytesPerFile = 4096
        XCTAssertEqual(try engine.scanRecentClaude(now: now).recordsRead, 1,
            "A byte-limited pass must not advance past an incomplete JSONL line")
        XCTAssertEqual(try store.records(harness: "claude-code", from: now.addingTimeInterval(-60),
                                         to: now).count, 1)
    }

    func testRecentClaudeTailCatchesUpWithoutFileChangeAfterBudgetLimit() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3))
        let first = claudeLine(id: "first", timestamp: stamp) + "\n"
        let second = claudeLine(id: "second", timestamp: stamp) + "\n"
        let file = temp.appendingPathComponent("claude/project/active.jsonl")
        try write(first + second, to: file)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))])
        let cap = first.utf8.count + 30
        engine.recentClaudeMaxBytes = cap
        engine.recentClaudeMaxBytesPerFile = cap
        let firstPass = try engine.scanRecentClaude(now: now)
        XCTAssertEqual(firstPass.recordsRead, 1)
        XCTAssertTrue(firstPass.pendingRecentWork)
        let secondPass = try engine.scanRecentClaude(now: now.addingTimeInterval(1))
        XCTAssertEqual(secondPass.recordsRead, 1, "Unchanged file still has unread complete data")
        XCTAssertFalse(secondPass.pendingRecentWork)
        XCTAssertEqual(try engine.scanRecentClaude(now: now.addingTimeInterval(2)).recordsRead, 0)
        XCTAssertEqual(try store.records(harness: "claude-code", from: now.addingTimeInterval(-60),
                                         to: now).count, 2)
    }

    func testRecentClaudeTailSkipsFourUnchangedFilesBeforeFifthActiveFile() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3))
        let root = temp.appendingPathComponent("claude")
        let files = (0..<5).map { root.appendingPathComponent("project/session-\($0).jsonl") }
        for (index, file) in files.enumerated() {
            try write(claudeLine(id: "initial-\(index)", timestamp: stamp) + "\n", to: file)
        }
        for file in files.prefix(4) {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2)],
                                              ofItemAtPath: files[4].path)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: root)])
        _ = try engine.scan(now: now)
        try append(claudeLine(id: "fifth-new", timestamp: stamp) + "\n", to: files[4])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1)],
                                              ofItemAtPath: files[4].path)
        let result = try engine.scanRecentClaude(now: now)
        XCTAssertEqual(result.filesScanned, 1, "Four newer unchanged files must not exhaust the cap")
        XCTAssertEqual(result.recordsRead, 1)
        XCTAssertFalse(result.pendingRecentWork)
        XCTAssertEqual(try store.records(harness: "claude-code", from: now.addingTimeInterval(-60),
                                         to: now).count, 6)
    }

    func testRecentClaudeTailFileCapReportsPendingInsteadOfCompleteSilence() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3))
        let root = temp.appendingPathComponent("claude")
        for index in 0..<2 {
            try write(claudeLine(id: "capped-\(index)", timestamp: stamp) + "\n",
                      to: root.appendingPathComponent("project/\(index).jsonl"))
        }
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: root)])
        engine.recentClaudeMaxFiles = 1
        let first = try engine.scanRecentClaude(now: now)
        XCTAssertEqual(first.filesScanned, 1)
        XCTAssertTrue(first.pendingRecentWork)
        let second = try engine.scanRecentClaude(now: now.addingTimeInterval(1))
        XCTAssertEqual(second.filesScanned, 1)
        XCTAssertFalse(second.pendingRecentWork)
    }

    func testRecentClaudeCompleteEventSurvivesAnotherIncompleteSession() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3))
        let root = temp.appendingPathComponent("claude")
        let complete = root.appendingPathComponent("project/complete.jsonl")
        let partial = root.appendingPathComponent("project/partial.jsonl")
        try write(claudeLine(id: "complete", timestamp: stamp) + "\n", to: complete)
        try write(claudeLine(id: "partial", timestamp: stamp), to: partial)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: root)])
        let first = try engine.scanRecentClaude(now: now)
        XCTAssertEqual(first.recordsRead, 1)
        XCTAssertTrue(first.pendingRecentWork)
        XCTAssertEqual(try store.records(harness: "claude-code", from: now.addingTimeInterval(-60),
                                         to: now).count, 1)
        let unchanged = try engine.scanRecentClaude(now: now.addingTimeInterval(1))
        XCTAssertEqual(unchanged.filesScanned, 0)
        XCTAssertTrue(unchanged.pendingRecentWork)
        try append("\n", to: partial)
        let completed = try engine.scanRecentClaude(now: now.addingTimeInterval(2))
        XCTAssertEqual(completed.recordsRead, 1)
        XCTAssertFalse(completed.pendingRecentWork)
    }

    func testIncrementalCheckpointRestartPartialLineAndRevision() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("claude/project/session.jsonl")
        try write(claudeLine(id: "m1") + "\n" + claudeLine(id: "m2"), to: file)
        let database = temp.appendingPathComponent("db/history.sqlite3")
        let source = HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))
        let start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 2_000_000_000)
        do {
            let store = try HistoricalUsageStore(url: database)
            let engine = HistoricalUsageEngine(store: store, sources: [source])
            XCTAssertEqual(try engine.scan().first?.recordsRead, 1)
            XCTAssertEqual(try store.records(from: start, to: end).count, 1)
            XCTAssertEqual(try engine.scan().first?.recordsRead, 0)
            try append("\n", to: file)
            XCTAssertEqual(try engine.scan().first?.recordsRead, 1)
            XCTAssertEqual(try store.records(from: start, to: end).count, 2)
        }
        do {
            let store = try HistoricalUsageStore(url: database)
            let engine = HistoricalUsageEngine(store: store, sources: [source])
            XCTAssertEqual(try engine.scan().first?.recordsRead, 0, "Persisted cursor must survive a new process/store instance")
            try append(claudeLine(id: "m1", output: 7) + "\n", to: file)
            XCTAssertEqual(try engine.scan().first?.recordsRead, 1)
            let records = try store.records(from: start, to: end)
            XCTAssertEqual(records.count, 2, "Streaming revision must update, not double-count")
            XCTAssertEqual(records.first { $0.eventID == "claude:s1:m1" }?.outputTokens, .measured(7))
            try write(claudeLine(id: "m3") + "\n", to: file)
            _ = try engine.scan()
            XCTAssertEqual(try store.records(from: start, to: end).count, 3,
                           "A rotated/replaced file must not erase or duplicate persisted events")
        }
    }

    func testFourSourcesPersistWithMetricGapsAndHistoryGap() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let codex = temp.appendingPathComponent("codex/2026/09/29/rollout-s1.jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"c1","cwd":"/work/Projet Beta","model_provider":"openai"}}"#
        let turn = #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
        let token = #"{"timestamp":"2026-09-29T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10},"last_token_usage":{"input_tokens":8,"output_tokens":2,"cached_input_tokens":3}}}}"#
        try write(meta + "\n" + turn + "\n" + token + "\n" + token + "\n", to: codex)
        try write(claudeLine(id: "m1") + "\n", to: temp.appendingPathComponent("claude/project/session.jsonl"))
        let gemini = temp.appendingPathComponent("gemini/tmp/hash/chats/session.jsonl")
        try write(#"{"sessionId":"g1"}"# + "\n" +
                  #"{"$set":{"messages":[{"id":"g1m1","type":"gemini","timestamp":"2026-09-29T12:00:00Z","model":"gemini-3-flash-preview","tokens":{"input":5,"output":1}},{"id":"g1m2","type":"gemini","timestamp":"2026-09-29T12:00:01Z","model":"gemini-3-flash-preview","tokens":{"input":7,"output":2}}]}}"# + "\n", to: gemini)
        try write("/work/Projet Beta\n", to: temp.appendingPathComponent("gemini/history/hash/.project_root"))
        try write("[GIN] 2026/09/29 - 14:00:00 | 200 | 1.5s | 127.0.0.1 | POST \"/api/chat\"\n",
                  to: temp.appendingPathComponent("ollama/server.log"))
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let sources = [HistoricalSource(harnessID: "codex", root: temp.appendingPathComponent("codex")),
                       HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude")),
                       HistoricalSource(harnessID: "gemini-cli", root: temp.appendingPathComponent("gemini/tmp"),
                                        historyRoot: temp.appendingPathComponent("gemini/history")),
                       HistoricalSource(harnessID: "ollama", root: temp.appendingPathComponent("ollama"))]
        let engine = HistoricalUsageEngine(store: store, sources: sources)
        XCTAssertEqual(try engine.scan().map(\.harnessID), ["codex", "claude-code", "gemini-cli", "ollama"])
        let beginning = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 2_000_000_000)
        let records = try store.records(from: beginning, to: end)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records.filter { $0.harnessID == "codex" }.count, 1, "Duplicate cumulative Codex report")
        XCTAssertEqual(records.filter { $0.harnessID == "gemini-cli" }.count, 2, "All $set messages must be imported")
        XCTAssertEqual(records.first { $0.harnessID == "codex" }?.projectPath, "/work/Projet Beta")
        XCTAssertEqual(records.first { $0.harnessID == "gemini-cli" }?.projectPath, "/work/Projet Beta")
        XCTAssertNil(records.first { $0.harnessID == "ollama" }?.modelID)
        let ollama = try store.coverage(harness: "ollama", from: beginning, to: end)
        XCTAssertEqual(ollama.metrics[.durationSeconds]?.measured, 1)
        XCTAssertEqual(ollama.metrics[.inputTokens]?.unavailable, 1)
        let codexCoverage = try store.coverage(harness: "codex", from: beginning, to: end)
        XCTAssertFalse(codexCoverage.knownGaps.isEmpty, "Pre-monitor history cannot be declared fully covered")
        try store.saveQuota(harness: "codex", remainingPercent: 42,
                            at: Date(timeIntervalSince1970: 1_800_000_000), provenance: "official app-server")
        XCTAssertEqual(try store.coverage(harness: "codex", from: beginning, to: end).latestQuotaRemainingPercent, 42)
        XCTAssertEqual(HistoricalComparability.compare(codexCoverage, ollama, metric: .inputTokens).verdict,
                       .insufficientCoverage)
        XCTAssertEqual(try engine.scan().map(\.recordsRead), [0, 0, 0, 0])
    }

    func testBoundedBootstrapReportsGapAndNoFabricatedPercentage() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("claude/session.jsonl")
        try write(String(repeating: "x", count: 4096) + "\n" + claudeLine(id: "tail") + "\n", to: file)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))])
        engine.bootstrapTailBytes = 1024
        _ = try engine.scan()
        let coverage = try store.coverage(harness: "claude-code", from: Date(timeIntervalSince1970: 0),
                                          to: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(coverage.eventCount, 1)
        XCTAssertTrue(coverage.knownGaps.contains { $0.contains("Préfixe") })
        XCTAssertFalse(coverage.continuouslyObserved)
    }

    func testOversizedLineDoesNotPermanentlyBlockCursor() throws {
        let temp = try root()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("claude/session.jsonl")
        try write(String(repeating: "x", count: 5 * 1024 * 1024) + "\n" + claudeLine(id: "after-long-line") + "\n", to: file)
        let store = try HistoricalUsageStore(url: temp.appendingPathComponent("db/history.sqlite3"))
        let engine = HistoricalUsageEngine(store: store,
            sources: [HistoricalSource(harnessID: "claude-code", root: temp.appendingPathComponent("claude"))])
        engine.bootstrapTailBytes = 8 * 1024 * 1024
        XCTAssertEqual(try engine.scan().first?.recordsRead, 0)
        XCTAssertEqual(try engine.scan().first?.recordsRead, 1)
        let coverage = try store.coverage(harness: "claude-code", from: Date(timeIntervalSince1970: 0),
                                          to: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(coverage.eventCount, 1)
        XCTAssertTrue(coverage.knownGaps.contains { $0.contains("Ligne > 4 Mio") })
    }

    func testComparabilityRequiresSameWindowAndMeasuredMetrics() {
        let now = Date(), later = now.addingTimeInterval(60)
        func coverage(_ harness: String, estimated: Int = 0, unavailable: Int = 0,
                      tracking: Date? = nil) -> HistoricalCoverage {
            HistoricalCoverage(harnessID: harness, periodStart: now, periodEnd: later,
                trackingSince: tracking ?? now, lastScan: later, earliestEvent: now,
                latestEvent: later, eventCount: 2, providerIDs: ["openai"], modelIDs: ["model-a"],
                knownGaps: [], inventoryComplete: true,
                metrics: [.inputTokens: MetricCoverage(observed: 2 - unavailable,
                    estimated: estimated, unavailable: unavailable)],
                latestQuotaRemainingPercent: nil, quotaSampledAt: nil)
        }
        XCTAssertEqual(HistoricalComparability.compare(coverage("a"), coverage("a"), metric: .inputTokens).verdict,
                       .comparable)
        XCTAssertEqual(HistoricalComparability.compare(coverage("a"), coverage("b"), metric: .inputTokens).verdict,
                       .partiallyComparable)
        // The coverage engine populates model sets from observed records; a
        // changed model must lower confidence even within one harness.
        let differentModel = HistoricalCoverage(harnessID: "a", periodStart: now, periodEnd: later,
            trackingSince: now, lastScan: later, earliestEvent: now, latestEvent: later,
            eventCount: 2, providerIDs: ["openai"], modelIDs: ["model-b"], knownGaps: [],
            inventoryComplete: true, metrics: [.inputTokens: MetricCoverage(observed: 2,
                estimated: 0, unavailable: 0)], latestQuotaRemainingPercent: nil, quotaSampledAt: nil)
        XCTAssertEqual(HistoricalComparability.compare(coverage("a"), differentModel,
                                                       metric: .inputTokens).verdict, .partiallyComparable)
        XCTAssertEqual(HistoricalComparability.compare(coverage("a"), coverage("b", estimated: 1), metric: .inputTokens).verdict,
                       .partiallyComparable)
        XCTAssertEqual(HistoricalComparability.compare(coverage("a"), coverage("b", unavailable: 2), metric: .inputTokens).verdict,
                       .insufficientCoverage)
        XCTAssertEqual(HistoricalComparability.compare(coverage("a"), coverage("b", tracking: later), metric: .inputTokens).verdict,
                       .partiallyComparable)
    }
}
