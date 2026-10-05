import Foundation
import XCTest
@testable import ArqmeterCore

final class SessionOptimizerTests: XCTestCase {
    private func record(_ index: Int, session: String = "s1", input: Int64 = 50_000,
                        output: Int64 = 500, cache: UsageMeasurement<Int64> = .measured(100),
                        inputQuality: UsageMeasurement<Int64>? = nil) -> UnifiedUsageRecord {
        UnifiedUsageRecord(eventID: "\(session):\(index)",
            timestamp: Date(timeIntervalSince1970: Double(index)), projectPath: "/work/Projet Beta",
            sessionID: session, harnessID: "codex", providerID: "openai", modelID: "gpt-5.6-sol",
            inputTokens: inputQuality ?? .measured(input), outputTokens: .measured(output),
            cachedInputTokens: cache, reasoningTokens: .unavailable, costUSD: .unavailable,
            durationSeconds: .unavailable, executionLocation: .unavailable,
            sourceKind: .codexSessionLog, provenance: "fixture session log")
    }

    func testEvidenceBackedRecommendationsAreOnlyUnquantifiedOpportunities() {
        let records = (0..<5).map { record($0) }
        let items = SessionOptimizer.analyze(records + [records[0]])
        XCTAssertTrue(items.contains { $0.type == .highInputToOutput })
        XCTAssertTrue(items.contains { $0.type == .lowCacheReuse })
        XCTAssertTrue(items.contains { $0.type == .potentialContextRepetition })
        XCTAssertTrue(items.allSatisfy { $0.impactClassification == .theoreticalOpportunity })
        XCTAssertTrue(items.allSatisfy { $0.estimatedImpact.contains("aucun gain avant/après mesuré") })
        XCTAssertTrue(items.allSatisfy { !$0.evidence.isEmpty && !$0.limitations.isEmpty })
        XCTAssertEqual(items.first?.evidence.count, 5, "Duplicate event identity must not duplicate evidence")
    }

    func testPartialAndUnavailableMetricsSuppressUnsupportedAdvice() {
        let partial = (0..<5).map { record($0, cache: .unavailable, inputQuality: .estimated(50_000)) }
        XCTAssertTrue(SessionOptimizer.analyze(partial).isEmpty,
                      "Derived input and absent cache cannot support measured-token recommendations")
        let local = UnifiedUsageRecord(eventID: "local:1", timestamp: Date(), projectPath: nil,
            sessionID: "request:1", harnessID: "ollama", providerID: "ollama", modelID: nil,
            inputTokens: .unavailable, outputTokens: .unavailable, cachedInputTokens: .unavailable,
            reasoningTokens: .unavailable, costUSD: .unavailable,
            durationSeconds: .measured(1.2), executionLocation: .local,
            sourceKind: .ollamaServerLog, provenance: "server log")
        XCTAssertTrue(SessionOptimizer.analyze([local]).isEmpty)
    }

    func testContextGrowthRequiresMultipleMeasuredTurns() {
        let inputs: [Int64] = [8_000, 9_000, 10_000, 25_000, 28_000, 32_000]
        let items = SessionOptimizer.analyze(inputs.enumerated().map { record($0.offset, input: $0.element) })
        XCTAssertTrue(items.contains { $0.type == .contextGrowth })
        let incomplete = inputs.enumerated().map { index, input in
            record(index, input: input, inputQuality: index == 3 ? .unavailable : nil)
        }
        XCTAssertFalse(SessionOptimizer.analyze(incomplete).contains { $0.type == .contextGrowth })
    }

    func testAnomalyNeedsSameHarnessModelBaseline() {
        var records: [UnifiedUsageRecord] = (0..<5).map { record($0, session: "large", input: 50_000) }
        for i in 0..<5 { records.append(record(100 + i, session: "peer-\(i)", input: 20_000)) }
        XCTAssertTrue(SessionOptimizer.analyze(records).contains { $0.type == .anomalousSessionVolume })
        XCTAssertFalse(SessionOptimizer.analyze(Array(records.prefix(5))).contains { $0.type == .anomalousSessionVolume })
    }
}
