import Foundation
import XCTest
@testable import ArqmeterCore

final class PrimarySourceReadoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, harness: String, secondsAgo: TimeInterval,
                        input: UsageMeasurement<Int64>, output: UsageMeasurement<Int64>,
                        duration: UsageMeasurement<Double> = .unavailable) -> UnifiedUsageRecord {
        UnifiedUsageRecord(eventID: id, timestamp: now.addingTimeInterval(-secondsAgo),
            projectPath: nil, sessionID: id, harnessID: harness, providerID: harness,
            modelID: nil, inputTokens: input, outputTokens: output,
            cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
            costUSD: .unavailable, durationSeconds: duration, executionLocation: .local,
            sourceKind: .init("test.fixture"), provenance: "synthetic fixture")
    }

    private func source(_ harness: String, records: [UnifiedUsageRecord]) -> UsageSourceSnapshot {
        UsageSourceSnapshot(harnessID: harness, installed: true, readable: true,
            records: records, coverage: "synthetic")
    }

    func testPrimarySwitchNeverFallsBackToCodex() {
        let usage = UnifiedUsage(sources: [
            source("codex", records: [record("c", harness: "codex", secondsAgo: 10,
                input: .measured(1_000), output: .measured(100))]),
            source("claude-code", records: [record("a", harness: "claude-code", secondsAgo: 20,
                input: .measured(12), output: .measured(3))])
        ])
        let start = now.addingTimeInterval(-60)
        XCTAssertEqual(PrimarySourceReadout(usage: usage, primaryID: "codex", from: start, to: now)?.completeTotalTokens, 1_100)
        let claude = PrimarySourceReadout(usage: usage, primaryID: "claude-code", from: start, to: now)
        XCTAssertEqual(claude?.harnessID, "claude-code")
        XCTAssertEqual(claude?.completeTotalTokens, 15)
        XCTAssertEqual(claude?.observedTokensPerSecond, 0.25)
        XCTAssertEqual(claude?.tokenBuckets(count: 3), [nil, 15, nil])
        XCTAssertNil(PrimarySourceReadout(usage: usage, primaryID: "gemini-cli", from: start, to: now))
    }

    func testEmptyOrOutsidePeriodIsUnavailableNotMeasuredZero() {
        let usage = UnifiedUsage(sources: [source("gemini-cli", records: [
            record("old", harness: "gemini-cli", secondsAgo: 3_600,
                input: .measured(50), output: .measured(5))])])
        let selected = PrimarySourceReadout(usage: usage, primaryID: "gemini-cli",
            from: now.addingTimeInterval(-60), to: now)
        XCTAssertNotNil(selected)
        XCTAssertNil(selected?.completeTotalTokens)
        XCTAssertNil(selected?.observedTokensPerSecond)
        XCTAssertEqual(selected?.tokenBuckets(count: 3), [nil, nil, nil])
        XCTAssertNil(selected?.lastEventAt)
        XCTAssertEqual(selected?.aggregate.records.count, 0)
    }

    func testPartialTokensAndDurationOnlyRemainSeparate() {
        let usage = UnifiedUsage(sources: [
            source("claude-code", records: [
                record("partial", harness: "claude-code", secondsAgo: 10,
                    input: .measured(9), output: .unavailable)]),
            source("ollama", records: [
                record("local", harness: "ollama", secondsAgo: 5,
                    input: .unavailable, output: .unavailable, duration: .measured(1.25))])
        ])
        let start = now.addingTimeInterval(-60)
        let claude = PrimarySourceReadout(usage: usage, primaryID: "claude-code", from: start, to: now)
        XCTAssertNil(claude?.completeTotalTokens)
        XCTAssertEqual(claude?.aggregate.inputTokens.value, 9)
        XCTAssertEqual(claude?.tokenBuckets(count: 3), [nil, nil, nil], "Incomplete token events must not draw a zero or a bar")
        let ollama = PrimarySourceReadout(usage: usage, primaryID: "ollama", from: start, to: now)
        XCTAssertNil(ollama?.completeTotalTokens)
        XCTAssertNil(ollama?.aggregate.inputTokens.value)
        XCTAssertEqual(ollama?.aggregate.durationSeconds, 1.25)
    }

    func testEstimatedTokensCannotBePresentedAsCompleteMeasurement() {
        let usage = UnifiedUsage(sources: [source("gemini-cli", records: [
            record("estimate", harness: "gemini-cli", secondsAgo: 2,
                input: .estimated(7), output: .measured(2))])])
        let selected = PrimarySourceReadout(usage: usage, primaryID: "gemini-cli",
            from: now.addingTimeInterval(-60), to: now)
        XCTAssertNil(selected?.completeTotalTokens)
        XCTAssertTrue(selected?.aggregate.inputTokens.containsEstimates == true)
    }

    func testMislabelledSourceCannotImportAnotherHarnessMeasurement() {
        let usage = UnifiedUsage(sources: [source("claude-code", records: [
            record("codex-in-wrong-source", harness: "codex", secondsAgo: 2,
                input: .measured(5_000), output: .measured(500))])])
        let selected = PrimarySourceReadout(usage: usage, primaryID: "claude-code",
            from: now.addingTimeInterval(-60), to: now)
        XCTAssertEqual(selected?.aggregate.records.count, 0)
        XCTAssertNil(selected?.completeTotalTokens)
    }
}
