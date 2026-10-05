import Foundation
import XCTest
@testable import ArqmeterCore

final class UnifiedUsageTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)

    func testCodexLocalEventPreservesMeasuredTokensAndSource() {
        let record = CodexUsageNormalizer().normalize(CodexLocalUsage(
            timestamp: date, projectPath: "/work/project", sessionID: "rollout-1.jsonl",
            inputTokens: 120, outputTokens: 30, cachedInputTokens: 80
        ))
        XCTAssertEqual(record?.harnessID, "codex")
        XCTAssertEqual(record?.projectPath, "/work/project")
        XCTAssertEqual(record?.inputTokens, .measured(120))
        XCTAssertEqual(record?.outputTokens, .measured(30))
        XCTAssertEqual(record?.cachedInputTokens, .measured(80))
        XCTAssertEqual(record?.sourceKind, .codexSessionLog)
    }

    func testUnobservedFieldsRemainUnavailable() {
        let record = CodexUsageNormalizer().normalize(CodexLocalUsage(
            timestamp: date, projectPath: nil, sessionID: "rollout-1.jsonl",
            inputTokens: 1, outputTokens: 0, cachedInputTokens: 0
        ))
        XCTAssertNil(record?.providerID)
        XCTAssertNil(record?.modelID)
        XCTAssertEqual(record?.reasoningTokens, .unavailable)
        XCTAssertEqual(record?.costUSD, .unavailable)
        XCTAssertEqual(record?.durationSeconds, .unavailable)
        XCTAssertEqual(record?.executionLocation, .unavailable)
        XCTAssertNil(record?.costUSD.value)
    }

    func testInvalidOrEmptyEventIsNotNormalized() {
        let invalid = [
            CodexLocalUsage(timestamp: date, projectPath: nil, sessionID: "rollout-1.jsonl",
                            inputTokens: -1, outputTokens: 2, cachedInputTokens: 0),
            CodexLocalUsage(timestamp: date, projectPath: nil, sessionID: "rollout-1.jsonl",
                            inputTokens: 2, outputTokens: 1, cachedInputTokens: 3),
            CodexLocalUsage(timestamp: date, projectPath: nil, sessionID: "rollout-1.jsonl",
                            inputTokens: 0, outputTokens: 0, cachedInputTokens: 0),
            CodexLocalUsage(timestamp: date, projectPath: nil, sessionID: "",
                            inputTokens: 1, outputTokens: 0, cachedInputTokens: 0),
        ]
        XCTAssertTrue(invalid.allSatisfy { CodexUsageNormalizer().normalize($0) == nil })
    }

    func testMeasuredZeroIsDifferentFromUnavailable() {
        XCTAssertEqual(UsageMeasurement<Int64>.measured(0).value, 0)
        XCTAssertNil(UsageMeasurement<Int64>.unavailable.value)
        XCTAssertNotEqual(UsageMeasurement<Int64>.measured(0), .unavailable)
    }

    func testAbsentCacheIsNotMeasuredAsZero() {
        let record = CodexUsageNormalizer().normalize(CodexLocalUsage(
            timestamp: date, projectPath: nil, sessionID: "rollout-1.jsonl",
            inputTokens: 10, outputTokens: 1, cachedInputTokens: nil
        ))
        XCTAssertEqual(record?.cachedInputTokens, .unavailable)
    }
}
