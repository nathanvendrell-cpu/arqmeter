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

    func testCachedGrowthWithFallingUncachedInputIsInformationalAndKeepsProof() {
        let rows = (0..<6).map {
            record($0, input: $0 < 3 ? 10_000 : 30_000,
                cache: .measured($0 < 3 ? 5_000 : 29_000))
        }
        let growth = SessionOptimizer.analyze(rows).first { $0.type == .contextGrowth }
        XCTAssertEqual(growth?.basis, .cacheRead)
        XCTAssertEqual(growth?.severity, .info)
        XCTAssertTrue(growth?.observedData.contains("baisse malgré la hausse du total") == true)
        XCTAssertEqual(growth?.evidence.count, 6)
        XCTAssertEqual(growth?.tokenEvidence.totalInput, 120_000)
        XCTAssertEqual(growth?.tokenEvidence.cacheRead, 102_000)
        XCTAssertEqual(growth?.tokenEvidence.uncachedInput, 18_000)
        XCTAssertTrue(growth?.recommendation.contains("Ne pas réinitialiser") == true)
    }

    func testRealUncachedGrowthDetectedEvenWithStableTotalInput() {
        let rows = (0..<6).map { record($0, input: 50_000,
            cache: .measured($0 < 3 ? 49_000 : 20_000)) }
        let growth = SessionOptimizer.analyze(rows).first { $0.type == .contextGrowth }
        XCTAssertEqual(growth?.basis, .uncachedInput)
        XCTAssertEqual(growth?.severity, .moderate)
        XCTAssertTrue(growth?.observedData.contains("1000 → 30000") == true)
        XCTAssertEqual(growth?.tokenEvidence.uncachedInput, 93_000)
        XCTAssertGreaterThan(growth!.basis.priority, RecommendationBasis.cacheRead.priority)
    }

    func testCachedRatioDoesNotBecomeAnUncachedLoadAdvice() {
        let ratio = SessionOptimizer.analyze((0..<5).map {
            record($0, cache: .measured(49_000))
        }).first { $0.type == .highInputToOutput }
        XCTAssertEqual(ratio?.basis, .cacheRead)
        XCTAssertEqual(ratio?.tokenEvidence.uncachedInput, 5_000)
        XCTAssertEqual(ratio?.severity, .info)
        XCTAssertTrue(ratio?.recommendation.contains("ni reset ni compactage") == true)
        let real = SessionOptimizer.analyze((0..<5).map {
            record($0, cache: .measured(0))
        }).first { $0.type == .highInputToOutput }
        XCTAssertEqual(real?.basis, .uncachedInput)
        XCTAssertEqual(real?.impactClassification, .theoreticalOpportunity)
    }

    func testMissingPartialEstimatedOrInvalidCacheNeverPromotesGrowth() {
        for scenario in ["absent", "partial", "estimated", "negative", "aboveInput"] {
            let rows = (0..<6).map { i -> UnifiedUsageRecord in
                let input: Int64 = i < 3 ? 10_000 : 30_000
                let cache: UsageMeasurement<Int64>
                switch scenario {
                case "absent": cache = .unavailable
                case "partial": cache = i == 0 ? .unavailable : .measured(100)
                case "estimated": cache = i == 0 ? .estimated(100) : .measured(100)
                case "negative": cache = i == 0 ? .measured(-1) : .measured(100)
                default: cache = i == 0 ? .measured(input + 1) : .measured(100)
                }
                return record(i, input: input, cache: cache)
            }
            let item = SessionOptimizer.analyze(rows).first { $0.type == .contextGrowth }
            XCTAssertEqual(item?.basis, .measurementLimited, scenario)
            XCTAssertEqual(item?.severity, .info, scenario)
            XCTAssertFalse(item!.tokenEvidence.completeUncached, scenario)
            XCTAssertTrue(item?.observedData.contains("incomplet ou invalide") == true, scenario)
            if scenario == "estimated" { XCTAssertEqual(item?.tokenEvidence.cacheEstimatedEvents, 1) }
            if scenario == "negative" || scenario == "aboveInput" {
                XCTAssertEqual(item?.tokenEvidence.invalidCacheEvents, 1)
            }
        }
    }

    func testMixedModelsKeepDescriptiveRatioWithoutUncachedPriority() {
        let items = SessionOptimizer.analyze((0..<6).map {
            record($0, cache: .measured(0), model: $0 < 3 ? "model-a" : "model-b")
        })
        let ratio = items.first { $0.type == .highInputToOutput }
        XCTAssertEqual(ratio?.basis, .measurementLimited)
        XCTAssertFalse(ratio!.tokenEvidence.comparableModelProvider)
        XCTAssertFalse(items.contains { $0.type == .contextGrowth })
    }

    func testZeroOutputDoesNotInventRatioOrHideMeasuredUncachedGrowth() {
        let items = SessionOptimizer.analyze((0..<6).map {
            record($0, input: 50_000, output: 0, cache: .measured($0 < 3 ? 49_000 : 20_000))
        })
        XCTAssertFalse(items.contains { $0.type == .highInputToOutput })
        XCTAssertEqual(items.first { $0.type == .contextGrowth }?.basis, .uncachedInput)
        XCTAssertTrue(items.allSatisfy { $0.impactClassification == .theoreticalOpportunity })
    }

    func testClaudeCreationCacheRemainsPartOfUncachedInput() {
        let rows = (0..<3).compactMap { i in ClaudeCodeAdapter.parse([
            "type": "assistant", "sessionId": "claude-fixture", "cwd": "/fixture/project",
            "timestamp": "2026-01-01T00:00:0\(i)Z",
            "message": ["id": "message-\(i)", "model": "claude-fixture-model",
                "usage": ["input_tokens": 10, "output_tokens": 500,
                    "cache_creation_input_tokens": 20_000, "cache_read_input_tokens": 80_000]]
        ], file: URL(fileURLWithPath: "/fixture/session.jsonl")) }
        XCTAssertEqual(rows.count, 3)
        let ratio = SessionOptimizer.analyze(rows).first { $0.type == .highInputToOutput }
        XCTAssertEqual(ratio?.tokenEvidence.totalInput, 300_030)
        XCTAssertEqual(ratio?.tokenEvidence.cacheRead, 240_000)
        XCTAssertEqual(ratio?.tokenEvidence.uncachedInput, 60_030)
        XCTAssertTrue(ratio!.tokenEvidence.uncachedIncludesCacheCreation)
        XCTAssertTrue(ratio!.tokenEvidence.uncachedLabel.contains("création incluse"))
        XCTAssertTrue(SessionOptimizer.analyze(rows).allSatisfy {
            $0.impactClassification == .theoreticalOpportunity && $0.estimatedImpact.contains("aucun gain")
        })
    }
}
