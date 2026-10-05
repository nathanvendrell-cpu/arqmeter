import Foundation
import XCTest
@testable import ArqmeterCore

final class MultiProviderUsageTests: XCTestCase {
    private let stamp = "2026-09-28T12:00:00.000Z"

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arqmeter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testFourRealShapesCoexistAndPreservePartialMetrics() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude/project/s1.jsonl")
        let claudeLine = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-28T12:00:00.000Z","cwd":"/work/Projet Beta","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":10,"cache_creation_input_tokens":3,"cache_read_input_tokens":5,"output_tokens":4}}}"#
        let synthetic = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-28T12:03:00.000Z","message":{"id":"fake","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        try write(claudeLine + "\n" + claudeLine + "\n" + synthetic + "\n", to: claude)

        let gemini = root.appendingPathComponent("gemini/tmp/project-beta/chats/session.jsonl")
        let header = #"{"sessionId":"g1","projectHash":"hash","startTime":"2026-09-28T12:00:00.000Z"}"#
        let reply = #"{"id":"gm1","type":"gemini","timestamp":"2026-09-28T12:01:00.000Z","model":"gemini-3-flash-preview","tokens":{"input":20,"output":6,"cached":8,"thoughts":2}}"#
        try write(header + "\n" + reply + "\n" + reply + "\n", to: gemini)
        try write("/work/Projet Beta\n", to: root.appendingPathComponent("gemini/history/project-beta/.project_root"))

        let ollama = root.appendingPathComponent("ollama/server.log")
        try write("[GIN] 2026/09/28 - 14:02:00 | 200 | 1.25s | 127.0.0.1 | POST     \"/api/chat\"\n" +
                  "[GIN] 2026/09/28 - 14:03:00 | 404 | 2ms | 127.0.0.1 | POST     \"/api/generate\"\n", to: ollama)

        let codex = CodexUsageNormalizer().normalize(CodexLocalUsage(eventID: "codex:s1:42",
            timestamp: ISO8601DateFormatter().date(from: "2026-09-28T12:02:00Z")!,
            projectPath: "/work/Projet Beta", sessionID: "s1", inputTokens: 30,
            outputTokens: 7, cachedInputTokens: 9))!
        let usage = UnifiedUsage(sources: [
            CodexAdapter(records: [codex], installed: true, readable: true,
                         quotaRemainingPercent: 42, quotaSampledAt: Date()).read(),
            ClaudeCodeAdapter(root: root.appendingPathComponent("claude"), installed: true).read(),
            GeminiAdapter(root: root.appendingPathComponent("gemini/tmp"),
                          historyRoot: root.appendingPathComponent("gemini/history"), installed: true).read(),
            LocalModelAdapter(root: root.appendingPathComponent("ollama"), installed: true).read(),
        ])
        XCTAssertEqual(usage.sources.count, 4)
        XCTAssertEqual(usage.sources.map(\.displayName), ["Codex", "Claude Code", "Gemini CLI", "Ollama · local"])
        XCTAssertEqual(usage.sources[0].quotaRemainingPercent, .measured(42))
        XCTAssertEqual(usage.sources[1].quotaRemainingPercent, .unavailable)
        XCTAssertEqual(usage.records.count, 4, "Claude and Gemini repeated entries must not be counted twice")
        XCTAssertEqual(usage.byHarness().count, 4)
        XCTAssertEqual(usage.byProvider()["unknown"]?.records.count, 1)
        XCTAssertEqual(usage.byModel()["unknown"]?.records.count, 2)
        XCTAssertEqual(usage.byProject()["/work/Projet Beta"]?.records.count, 3)
        XCTAssertEqual(usage.byProject()["unknown"]?.records.count, 1)
        let global = usage.aggregate()
        XCTAssertEqual(global.inputTokens.value, 68)
        XCTAssertEqual(global.outputTokens.value, 17)
        XCTAssertEqual(global.inputTokens.coveredRecords, 3)
        XCTAssertEqual(global.inputTokens.totalRecords, 4)
        XCTAssertFalse(global.inputTokens.complete)
        XCTAssertEqual(global.durationSeconds, 1.25)
        XCTAssertEqual(global.durationCoverage, 1)
        XCTAssertEqual(global.costUSD, .unavailable)
        XCTAssertEqual(global.costCoverage, 0)
        XCTAssertEqual(usage.byHarness()["ollama"]?.inputTokens.value, nil)
        XCTAssertEqual(usage.byHarness()["ollama"]?.records.first?.modelID, nil)
        XCTAssertEqual(usage.byHarness()["claude-code"]?.cachedInputTokens.value, 5)
        XCTAssertEqual(usage.byHarness()["gemini-cli"]?.reasoningTokens.value, 2)
        XCTAssertTrue(usage.records.allSatisfy { !$0.eventID.isEmpty && !$0.provenance.isEmpty })
    }

    func testAbsentProviderAndEmptyHistoryAreNotZeroUsage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = ClaudeCodeAdapter(root: root.appendingPathComponent("missing"), installed: false).read()
        XCTAssertFalse(claude.installed)
        XCTAssertFalse(claude.readable)
        XCTAssertTrue(claude.records.isEmpty)
        let empty = UnifiedUsage(sources: [claude]).aggregate()
        XCTAssertNil(empty.inputTokens.value)
        XCTAssertFalse(empty.inputTokens.complete)
        XCTAssertEqual(empty.inputTokens.totalRecords, 0)
    }

    func testUnknownModelWorkspaceAndTimePeriod() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gemini = root.appendingPathComponent("gemini/tmp/unknown/chats/session.jsonl")
        try write(#"{"sessionId":"g2"}"# + "\n" +
                  #"{"id":"m2","type":"gemini","timestamp":"2026-09-28T12:01:00.000Z","tokens":{"input":1,"output":0}}"# + "\n", to: gemini)
        let source = GeminiAdapter(root: root.appendingPathComponent("gemini/tmp"),
                                   historyRoot: root.appendingPathComponent("gemini/history"), installed: true).read()
        XCTAssertEqual(source.records.count, 1)
        XCTAssertNil(source.records[0].modelID)
        XCTAssertNil(source.records[0].projectPath)
        XCTAssertEqual(source.records[0].cachedInputTokens, .unavailable)
        let usage = UnifiedUsage(sources: [source])
        let start = ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z")!
        XCTAssertTrue(usage.aggregate(from: start).records.isEmpty)
        XCTAssertEqual(usage.byModel()["unknown"]?.inputTokens.value, 1)
    }

    func testNestedGeminiSubagentIsImportedOnce() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("gemini/tmp/work/chats/parent/child.jsonl")
        try write(#"{"sessionId":"child","kind":"subagent"}"# + "\n" +
                  #"{"id":"m1","type":"gemini","timestamp":"2026-09-28T12:01:00.000Z","model":"gemini-3-flash-preview","tokens":{"input":3,"output":2}}"# + "\n", to: file)
        try write("/work/repo", to: root.appendingPathComponent("gemini/history/work/.project_root"))
        let source = GeminiAdapter(root: root.appendingPathComponent("gemini/tmp"),
                                   historyRoot: root.appendingPathComponent("gemini/history"), installed: true).read()
        XCTAssertEqual(source.records.count, 1)
        XCTAssertEqual(source.records[0].projectPath, "/work/repo")
    }

    func testClaudeMissingCacheFieldsIsDerivedNotMeasured() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude/project/session.jsonl")
        try write(#"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-28T12:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":10,"output_tokens":1}}}"# + "\n", to: file)
        let source = ClaudeCodeAdapter(root: root.appendingPathComponent("claude"), installed: true).read()
        XCTAssertEqual(source.records.first?.inputTokens, .estimated(10))
        XCTAssertEqual(source.records.first?.cachedInputTokens, .unavailable)
        XCTAssertFalse(UnifiedUsage(sources: [source]).aggregate().inputTokens.complete)
    }

    func testRepeatedSourceImportsAndCodexIdentityDeduplicate() {
        let raw = CodexLocalUsage(eventID: "codex:file:42", timestamp: Date(), projectPath: nil,
                                  sessionID: "s", inputTokens: 5, outputTokens: 1, cachedInputTokens: nil)
        let record = CodexUsageNormalizer().normalize(raw)!
        let source = CodexAdapter(records: [record, record], installed: true, readable: true).read()
        let usage = UnifiedUsage(sources: [source, source])
        XCTAssertEqual(usage.records.count, 1)
        XCTAssertEqual(usage.aggregate().inputTokens.value, 5)
        XCTAssertEqual(usage.aggregate().cachedInputTokens.value, nil)
    }
}
