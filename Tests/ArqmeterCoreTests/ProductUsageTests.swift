import Foundation
import XCTest
@testable import ArqmeterCore

final class ProductUsageTests: XCTestCase {
    private func record(_ id: String, harness: String = "codex", session: String = "s1",
                        model: String? = "m1", project: String? = "/work/one",
                        input: UsageMeasurement<Int64> = .measured(10),
                        output: UsageMeasurement<Int64> = .measured(2),
                        time: TimeInterval = 1) -> UnifiedUsageRecord {
        UnifiedUsageRecord(eventID: id, timestamp: Date(timeIntervalSince1970: time),
            projectPath: project, sessionID: session, harnessID: harness,
            providerID: harness == "codex" ? "openai" : "anthropic", modelID: model,
            inputTokens: input, outputTokens: output,
            cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
            costUSD: .unavailable, durationSeconds: .unavailable,
            executionLocation: .unavailable, sourceKind: .codexSessionLog,
            provenance: "fixture")
    }

    func testSessionsDeduplicateAndRemainSeparatedByHarness() {
        let records = [record("a"), record("a"), record("b", harness: "claude-code")]
        let sessions = UsageSessionIndex.sessions(records)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.aggregate.records.count }, 2)
        XCTAssertEqual(Set(sessions.map(\.id)), ["codex:s1", "claude-code:s1"])
    }

    func testFiltersAndUnknownMetadataAreNotGuessed() {
        let records = [record("a", project: nil), record("b", session: "s2", model: nil, project: "/work/two")]
        XCTAssertEqual(UsageSessionIndex.sessions(records, filter: .init(projectPath: "/work/two")).count, 1)
        XCTAssertNil(UsageSessionIndex.sessions(records).first { $0.sessionID == "s1" }?.projectPath)
        XCTAssertNil(UsageSessionIndex.sessions(records).first { $0.sessionID == "s2" }?.modelID)
        XCTAssertEqual(UsageSessionIndex.sessions(records, filter: .init(from: Date(timeIntervalSince1970: 2))).count, 0)
    }

    func testComparisonOnlyUsesFullyMeasuredTokens() {
        let before = UsageSession(records: [record("a", input: .measured(10))])!
        let after = UsageSession(records: [record("b", session: "s2", input: .measured(7))])!
        XCTAssertEqual(SessionUsageComparison(before, after).inputDifference, -3)
        let partial = UsageSession(records: [record("c", session: "s3", input: .unavailable)])!
        XCTAssertNil(SessionUsageComparison(before, partial).inputDifference)
        XCTAssertTrue(SessionUsageComparison(before, partial).warnings.contains { $0.contains("incomplète") })
    }

    func testConflictingModelAndProjectBecomeUnknown() {
        let session = UsageSession(records: [record("a"), record("b", model: "m2", project: "/work/two")])!
        XCTAssertNil(session.modelID)
        XCTAssertNil(session.projectPath)
    }
}
