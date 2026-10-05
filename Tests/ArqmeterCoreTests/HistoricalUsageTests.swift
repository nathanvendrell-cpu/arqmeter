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

    private func claudeLine(id: String, output: Int = 2) -> String {
        """
        {"type":"assistant","sessionId":"s1","timestamp":"2026-09-29T12:00:00Z","cwd":"/work/Projet Beta","message":{"id":"\(id)","model":"claude-sonnet-4","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":\(output)}}}
        """
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
