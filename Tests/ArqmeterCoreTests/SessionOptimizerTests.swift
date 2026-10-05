import Foundation
import XCTest
@testable import ArqmeterCore

final class SessionOptimizerTests: XCTestCase {
    private func record(_ index: Int, session: String = "s1", input: Int64 = 50_000,
                        output: Int64 = 500, cache: UsageMeasurement<Int64> = .measured(100),
                        inputQuality: UsageMeasurement<Int64>? = nil,
                        provider: String? = "openai", model: String? = "gpt-5.6-sol",
                        workspace: String? = "/work/Projet Beta") -> UnifiedUsageRecord {
        UnifiedUsageRecord(eventID: "\(session):\(index)",
            timestamp: Date(timeIntervalSince1970: Double(index)), projectPath: workspace,
            sessionID: session, harnessID: "codex", providerID: provider, modelID: model,
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
        var records: [UnifiedUsageRecord] = (0..<5).map { record($0, session: "large", input: 100_000) }
        for i in 0..<5 { records.append(record(100 + i, session: "peer-\(i)", input: 20_000)) }
        XCTAssertTrue(SessionOptimizer.analyze(records).contains { $0.type == .anomalousSessionVolume })
        XCTAssertFalse(SessionOptimizer.analyze(Array(records.prefix(5))).contains { $0.type == .anomalousSessionVolume })
    }

    func testHighRatioIsDescriptiveAndExplainsCacheNotWasteOrQuota() {
        let items = SessionOptimizer.analyze((0..<5).map { record($0, cache: .measured(49_000)) })
        let ratio = items.first { $0.type == .highInputToOutput }
        XCTAssertEqual(ratio?.severity, .info)
        XCTAssertEqual(ratio?.confidence, .low)
        XCTAssertTrue(ratio?.observedData.contains("245000 en cache, 5000 hors cache") == true)
        XCTAssertTrue(ratio?.limitations.contains("quota") == true)
        XCTAssertTrue(ratio?.recommendation.contains("qualité") == true)
        XCTAssertFalse(SessionOptimizer.analyze((0..<5).map { record($0, output: 0) })
            .contains { $0.type == .highInputToOutput }, "No ratio is established against zero output")
    }

    func testMoreResponsesDoNotMakeAnAnomalousSession() {
        var records = (0..<20).map { record($0, session: "long", input: 50_000) }
        for i in 0..<5 { records.append(record(100 + i, session: "peer-\(i)", input: 50_000)) }
        XCTAssertFalse(SessionOptimizer.analyze(records).contains { $0.type == .anomalousSessionVolume })
    }

    func testUnknownOrDifferentMetadataCannotFormAnomalyPeers() {
        for key in ["model", "provider", "workspace"] {
            var records = (0..<5).map { record($0, session: "large", input: 100_000,
                provider: key == "provider" ? nil : "openai",
                model: key == "model" ? nil : "gpt-5.6-sol",
                workspace: key == "workspace" ? nil : "/work/Projet Beta") }
            for i in 0..<5 { records.append(record(100 + i, session: "peer-\(i)", input: 20_000,
                provider: key == "provider" ? nil : "openai",
                model: key == "model" ? nil : "gpt-5.6-sol",
                workspace: key == "workspace" ? nil : "/work/Projet Beta")) }
            XCTAssertFalse(SessionOptimizer.analyze(records).contains { $0.type == .anomalousSessionVolume }, key)
        }
        var records = (0..<5).map { record($0, session: "large", input: 100_000) }
        for i in 0..<5 { records.append(record(100 + i, session: "peer-\(i)", input: 20_000, provider: "other-provider")) }
        XCTAssertFalse(SessionOptimizer.analyze(records).contains { $0.type == .anomalousSessionVolume })
    }

    func testMixedModelsCannotBecomeContextGrowthOrInventAnAttribution() {
        let inputs: [Int64] = [8_000, 9_000, 10_000, 25_000, 28_000, 32_000]
        let items = SessionOptimizer.analyze(inputs.enumerated().map {
            record($0.offset, input: $0.element, model: $0.offset < 3 ? "model-a" : "model-b",
                workspace: $0.offset < 3 ? "/work/A" : "/work/B")
        })
        XCTAssertFalse(items.contains { $0.type == .contextGrowth || $0.type == .lowCacheReuse })
        XCTAssertTrue(items.allSatisfy { $0.modelID == nil && $0.projectPath == nil })
    }

    func testInvalidCacheAndNegativeMeasurementsCannotSupportAdvice() {
        XCTAssertFalse(SessionOptimizer.analyze((0..<5).map { record($0, cache: .measured(-1)) })
            .contains { $0.type == .lowCacheReuse })
        XCTAssertFalse(SessionOptimizer.analyze((0..<5).map { record($0, cache: .measured(60_000)) })
            .contains { $0.type == .lowCacheReuse })
        XCTAssertTrue(SessionOptimizer.analyze((0..<5).map { record($0, input: -1, output: -1) }).isEmpty)
    }
}
