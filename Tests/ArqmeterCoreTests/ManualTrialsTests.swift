import Foundation
import XCTest
@testable import ArqmeterCore

final class ManualTrialsTests: XCTestCase {
    private let codexBefore = TrialSessionReference(harnessID: "codex", providerID: "openai",
                                                     modelID: "gpt-5.6-sol", sessionID: "before")
    private let codexAfter = TrialSessionReference(harnessID: "codex", providerID: "openai",
                                                    modelID: "gpt-5.6-sol", sessionID: "after")

    private func trial(after: TrialSide? = nil, validation: TrialValidation = .init()) -> ManualTrial {
        ManualTrial(recommendationID: "before:context-growth", before: TrialSide(primary: codexBefore),
                    after: after, testedChange: "Réduire les fichiers de contexte transmis",
                    workDescription: "Corriger le même lot de trois anomalies", successCriteria: "Tests verts et comportement inchangé",
                    validation: validation)
    }

    private func record(_ id: String, session: String, harness: String = "codex",
                        provider: String? = "openai", model: String? = "gpt-5.6-sol",
                        input: UsageMeasurement<Int64> = .measured(100),
                        output: UsageMeasurement<Int64> = .measured(10),
                        duration: UsageMeasurement<Double> = .unavailable) -> UnifiedUsageRecord {
        UnifiedUsageRecord(eventID: id, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                           projectPath: "/work/Projet Beta", sessionID: session,
                           harnessID: harness, providerID: provider, modelID: model,
                           inputTokens: input, outputTokens: output,
                           cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
                           costUSD: .unavailable, durationSeconds: duration,
                           executionLocation: harness == "ollama" ? .local : .unavailable,
                           sourceKind: harness == "ollama" ? .ollamaServerLog : .codexSessionLog,
                           provenance: "Fixture de test")
    }

    func testPersistRestartAndUpdateValidationWithoutCopiedMetrics() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arqmeter-trials-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("manual.sqlite3")
        let original = trial()
        do {
            let store = try ManualTrialStore(url: url)
            let saved = try store.upsert(original, at: Date(timeIntervalSince1970: 123))
            XCTAssertEqual(saved.updatedAt, Date(timeIntervalSince1970: 123))
            XCTAssertEqual(try store.allTrials(), [saved])
        }
        do {
            let store = try ManualTrialStore(url: url)
            var restored = try XCTUnwrap(store.trial(id: original.id))
            XCTAssertEqual(restored.testedChange, original.testedChange)
            XCTAssertNil(restored.after)
            restored.after = TrialSide(primary: codexAfter)
            restored.validation = TrialValidation(quality: .supported, workEquivalence: .supported,
                checks: [TrialValidationCheck(criterion: "Tests", outcome: .passed, evidence: "Suite locale verte")])
            let updated = try store.upsert(restored, at: Date(timeIntervalSince1970: 456))
            XCTAssertEqual(try store.allTrials().count, 1, "Updating an ID must not duplicate the trial")
            XCTAssertEqual(try store.trial(id: original.id), updated)
            XCTAssertEqual(updated.createdAt, original.createdAt)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStoreRejectsEmptyOversizedAndDuplicateLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arqmeter-trials-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ManualTrialStore(url: folder.appendingPathComponent("manual.sqlite3"))
        var empty = trial()
        empty.workDescription = "  "
        XCTAssertThrowsError(try store.upsert(empty))
        var oversized = trial()
        oversized.workDescription = String(repeating: "x", count: 601)
        XCTAssertThrowsError(try store.upsert(oversized), "Full prompts should not fit in a trial note")
        var duplicated = trial(after: TrialSide(primary: codexBefore))
        XCTAssertThrowsError(try store.upsert(duplicated))
        duplicated.after = TrialSide(primary: codexAfter,
            associated: [TrialAssociatedSession(role: .retry, session: codexAfter)])
        XCTAssertThrowsError(try store.upsert(duplicated))
        XCTAssertTrue(try store.allTrials().isEmpty)
    }

    func testComparisonMeasuredOnlyDeduplicatesAndIsCautious() {
        let before = record("event-1", session: "before", input: .measured(100), output: .measured(10))
        let after = record("event-2", session: "after", input: .measured(80), output: .measured(8))
        let result = ManualTrialEvaluator.evaluate(trial(after: TrialSide(primary: codexAfter)),
                                                    records: [before, before, after])
        XCTAssertEqual(result.verdict, .observedDifference)
        XCTAssertEqual(result.before[0].eventCount, 1)
        XCTAssertEqual(result.differences.first { $0.metric == .inputTokens && $0.scope == .primarySessions }?.delta,
                       Decimal(-20))
        XCTAssertNil(result.differences.first { $0.metric == .durationSeconds })
        XCTAssertNil(result.differences.first { $0.metric == .costUSD })
        XCTAssertEqual(result.conclusion, "Différence de consommation observée ; gain de workflow non établi.")
    }

    func testQualityAndEquivalenceNeedExplicitPassedValidation() {
        let records = [record("b", session: "before"), record("a", session: "after", input: .measured(90))]
        let unchecked = TrialValidation(quality: .supported, workEquivalence: .supported)
        XCTAssertEqual(ManualTrialEvaluator.evaluate(trial(after: TrialSide(primary: codexAfter), validation: unchecked),
                                                     records: records).verdict, .observedDifference)
        let checked = TrialValidation(quality: .supported, workEquivalence: .supported,
            checks: [TrialValidationCheck(criterion: "Tests", outcome: .passed, evidence: "Tests verts")])
        let result = ManualTrialEvaluator.evaluate(trial(after: TrialSide(primary: codexAfter), validation: checked),
                                                    records: records)
        XCTAssertEqual(result.verdict, .validatedSinglePair)
        XCTAssertTrue(result.conclusion.contains("non généralisable"))
    }

    func testMismatchedOrUnknownModelsAndHarnessesBlockComparison() {
        let records = [record("b", session: "before"), record("a", session: "after")]
        let unknown = TrialSessionReference(harnessID: "codex", providerID: "openai", modelID: nil, sessionID: "after")
        let changedModel = TrialSessionReference(harnessID: "codex", providerID: "openai", modelID: "gpt-other", sessionID: "after")
        let changedHarness = TrialSessionReference(harnessID: "claude-code", providerID: "anthropic",
                                                   modelID: "gpt-5.6-sol", sessionID: "after")
        for reference in [unknown, changedModel, changedHarness] {
            let comparison = ManualTrialEvaluator.evaluate(trial(after: TrialSide(primary: reference)), records: records)
            XCTAssertEqual(comparison.verdict, .incompatibleSessions)
            XCTAssertTrue(comparison.differences.isEmpty)
        }
    }

    func testMissingAndEstimatedValuesAreNotMeasuredZeros() {
        let records = [record("b", session: "before", input: .measured(100), output: .unavailable),
                       record("a", session: "after", input: .estimated(80), output: .measured(8))]
        let result = ManualTrialEvaluator.evaluate(trial(after: TrialSide(primary: codexAfter)), records: records)
        XCTAssertEqual(result.verdict, .insufficientMeasuredData)
        XCTAssertTrue(result.differences.isEmpty)
        XCTAssertEqual(result.before[0].metrics[.outputTokens], .unavailable)
        XCTAssertEqual(result.after[0].metrics[.inputTokens], .estimated(Decimal(80)))
    }

    func testAssociatedPreparationAndLocalWorkStayVisibleWithoutMixedTokenTotal() {
        let prep = TrialSessionReference(harnessID: "codex", providerID: "openai", modelID: "gpt-5.6-sol", sessionID: "prep")
        let local = TrialSessionReference(harnessID: "ollama", providerID: "ollama", modelID: nil, sessionID: "local")
        var experiment = trial(after: TrialSide(primary: codexAfter,
            associated: [TrialAssociatedSession(role: .localProcessing, session: local)]))
        experiment.before.associated = [TrialAssociatedSession(role: .preparation, session: prep)]
        let records = [record("b", session: "before"), record("p", session: "prep", input: .measured(20)),
                       record("a", session: "after", input: .measured(80)),
                       record("l", session: "local", harness: "ollama", provider: "ollama", model: nil,
                              input: .unavailable, output: .unavailable, duration: .measured(5))]
        let result = ManualTrialEvaluator.evaluate(experiment, records: records)
        XCTAssertEqual(result.after[1].role, .localProcessing)
        XCTAssertEqual(result.after[1].metrics[.durationSeconds], .measured(Decimal(5)))
        XCTAssertTrue(result.differences.allSatisfy { $0.scope == .primarySessions },
                      "Different tokenizers must not be summed into one trial total")
        XCTAssertTrue(result.reasons.contains { $0.contains("non additionnés") })
    }

    func testHomogeneousPreparationAndRetryIncludedInWholeTrialDifference() {
        let prep = TrialSessionReference(harnessID: "codex", providerID: "openai", modelID: "gpt-5.6-sol", sessionID: "prep")
        let retry = TrialSessionReference(harnessID: "codex", providerID: "openai", modelID: "gpt-5.6-sol", sessionID: "retry")
        var experiment = trial(after: TrialSide(primary: codexAfter,
            associated: [TrialAssociatedSession(role: .retry, session: retry)]))
        experiment.before.associated = [TrialAssociatedSession(role: .preparation, session: prep)]
        let records = [record("b", session: "before", input: .measured(100)),
                       record("p", session: "prep", input: .measured(20)),
                       record("a", session: "after", input: .measured(80)),
                       record("r", session: "retry", input: .measured(15))]
        let result = ManualTrialEvaluator.evaluate(experiment, records: records)
        let complete = result.differences.first { $0.metric == .inputTokens && $0.scope == .completeTrial }
        XCTAssertEqual(complete?.before, Decimal(120))
        XCTAssertEqual(complete?.after, Decimal(95))
        XCTAssertEqual(complete?.delta, Decimal(-25))
    }

    func testWaitingForAfterAndMissingSessionEvents() {
        XCTAssertEqual(ManualTrialEvaluator.evaluate(trial(), records: []).verdict, .waitingForAfterSession)
        XCTAssertEqual(ManualTrialEvaluator.evaluate(trial(after: TrialSide(primary: codexAfter)), records: []).verdict,
                       .incompatibleSessions)
    }
}
