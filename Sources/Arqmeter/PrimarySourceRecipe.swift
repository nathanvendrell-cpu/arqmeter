import Foundation
import ArqmeterCore

/// Non-GUI fixture for the real DashboardModel selection/callback path. It
/// injects records and never opens a profile, provider CLI, database or window.
enum PrimarySourceRecipe {
    static func selfTest() throws {
        var pending: [(id: String, completion: PrimaryHistoryCompletion)] = []
        let dashboard = DashboardModel(quotaHistoryStore: QuotaHistoryStore(url: nil),
            comparison: ComparisonModel(archiveURL: nil, annotationsURL: nil),
            readPrimaryHistory: { id, _, _, completion in pending.append((id, completion)) },
            primaryAvailability: { _ in (true, true) })
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "PrimarySourceRecipe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func record(_ id: String, harness: String, input: UsageMeasurement<Int64>,
                    output: UsageMeasurement<Int64>, duration: UsageMeasurement<Double> = .unavailable) -> UnifiedUsageRecord {
            UnifiedUsageRecord(eventID: id, timestamp: Date().addingTimeInterval(-1),
                projectPath: nil, sessionID: id, harnessID: harness, providerID: harness,
                modelID: nil, inputTokens: input, outputTokens: output,
                cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
                costUSD: .unavailable, durationSeconds: duration, executionLocation: .local,
                sourceKind: .init("test.fixture"), provenance: "synthetic fixture")
        }

        dashboard.selectPrimarySource("claude-code")
        dashboard.selectPrimarySource("gemini-cli")
        try check(pending.map(\.id) == ["claude-code", "gemini-cli"], "Distinct source reads not issued")
        pending[0].completion([record("c", harness: "claude-code", input: .measured(100), output: .measured(10))], nil)
        try check(dashboard.primaryHistory == nil && dashboard.primaryHistoryLoading,
            "A superseded source result was applied")
        pending[1].completion([
            record("wrong", harness: "codex", input: .measured(10_000), output: .measured(1)),
            record("g", harness: "gemini-cli", input: .measured(4), output: .measured(1))
        ], nil)
        try check(dashboard.primaryReadout?.harnessID == "gemini-cli" &&
                  dashboard.primaryReadout?.completeTotalTokens == 5, "Selected source did not drive the counter")

        dashboard.setConsumptionRange(.hour)
        try check(dashboard.primaryHistory == nil && dashboard.primaryHistoryLoading,
            "Old period remained visible during a new period read")
        dashboard.selectPrimarySource("ollama")
        pending[2].completion([record("late", harness: "gemini-cli", input: .measured(999), output: .measured(1))], nil)
        try check(dashboard.primaryHistoryID == "ollama" && dashboard.primaryHistory == nil,
            "A superseded period result was applied")
        pending[3].completion([record("o", harness: "ollama", input: .unavailable,
            output: .unavailable, duration: .measured(1.5))], nil)
        try check(dashboard.primaryReadout?.harnessID == "ollama" &&
                  dashboard.primaryReadout?.completeTotalTokens == nil &&
                  dashboard.primaryReadout?.aggregate.durationSeconds == 1.5,
            "Duration-only local usage was converted to tokens")

        dashboard.selectPrimarySource("claude-code")
        pending[4].completion([], "synthetic failure")
        try check(dashboard.primaryHistoryError == "synthetic failure" &&
                  dashboard.primaryReadout?.completeTotalTokens == nil,
            "Failed history read retained another source's counter")
        dashboard.selectPrimarySource("codex")
        try check(dashboard.primaryHistory == nil && dashboard.primaryHistoryID == "codex",
            "Codex did not return to its existing live path")
        print("Primary-source selection: source/period races, partial data and failure isolation PASS; synthetic records only")
    }
}
