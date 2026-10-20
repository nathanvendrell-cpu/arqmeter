import Foundation
import ArqmeterCore

/// CLI-only model wiring fixture. All reads are injected; no real profile,
/// database, provider, quota request or GUI is opened.
enum ClaudeRecentRecipe {
    static func selfTest() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "ClaudeRecentRecipe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("arqmeter-claude-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let suite = "com.7agency.arqmeter.tests.claude-recent.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw NSError(domain: "ClaudeRecentRecipe", code: 2)
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SourceDisplayPreferences(defaults: defaults)
        var pending: [(TimeInterval, RecentClaudeCompletion)] = []
        let dashboard = DashboardModel(quotaHistoryStore: QuotaHistoryStore(url: nil),
            comparison: ComparisonModel(archiveURL: nil, annotationsURL: nil),
            localActivityStore: LocalActivityStore(sessionsDirectory: temp),
            readPrimaryHistory: { _, _, _, completion in completion([], nil) },
            readRecentClaude: { duration, completion in pending.append((duration, completion)) },
            primaryAvailability: { _ in (true, true) })
        dashboard.selectPrimarySource("claude-code")
        dashboard.setRecentClaudeVisible(true, for: "fixture")
        try check(pending.isEmpty, "Hidden/inactive reader scheduled work")
        dashboard.startLive(for: "fixture")
        defer {
            dashboard.setRecentClaudeVisible(false, for: "fixture")
            dashboard.stopLive(for: "fixture")
        }
        let now = Date()
        dashboard.refreshVisibleClaude(now: now)
        try check(pending.count == 1 && pending[0].0 == 60,
            "Visible Claude was not refreshed by the live path")
        func record(_ id: String, at date: Date, complete: Bool = true,
                    input: Int64 = 18) -> UnifiedUsageRecord {
            UnifiedUsageRecord(eventID: id, timestamp: date, projectPath: nil,
                sessionID: "fixture", harnessID: "claude-code", providerID: "anthropic",
                modelID: nil, inputTokens: .measured(input),
                outputTokens: complete ? .measured(2) : .unavailable,
                cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
                costUSD: .unavailable, durationSeconds: .unavailable,
                executionLocation: .cloud, sourceKind: .init("test.fixture"),
                provenance: "synthetic fixture")
        }
        pending[0].1([record("first", at: now.addingTimeInterval(-5))], nil, now, false,
                     now.addingTimeInterval(-5))
        try check(dashboard.primaryReadout?.completeTotalTokens == 20,
            "Measured Claude event did not reach the readout")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(2))
        try check(pending.count == 1, "Throttle allowed another scan after two seconds")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(16))
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(32))
        try check(pending.count == 2 && dashboard.primaryReadout?.completeTotalTokens == 20,
            "In-flight read duplicated work or cleared a valid number")
        pending[1].1([record("partial", at: now.addingTimeInterval(15), complete: false)], nil,
                     now.addingTimeInterval(16), false, now.addingTimeInterval(15))
        try check(dashboard.primaryReadout?.completeTotalTokens == nil &&
                  dashboard.primaryReadout?.aggregate.records.count == 1,
            "Incomplete tokens became zero or a complete total")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(75))
        try check(pending.count == 3 && pending[2].0 == 60,
            "Rolling minute did not advance")
        pending[2].1([], nil, now.addingTimeInterval(75), false, now.addingTimeInterval(15))
        try check(dashboard.primaryReadout?.aggregate.records.isEmpty == true &&
                  dashboard.primaryReadout?.completeTotalTokens == nil &&
                  dashboard.primaryReadout?.periodStart == now.addingTimeInterval(15),
            "Expired event remained in the minute or empty usage became zero")
        let emptyPair = CodexClaudePairOverview(model: dashboard, preferences: preferences, codexWindow: nil)
        try check(emptyPair.claudeSummary == "Pas de mesure sur cette période" &&
                  emptyPair.claudeLastEvent?.contains("Dernier événement indexé") == true,
            "Empty period hid the dated earlier index event or implied a measured zero")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(91))
        try check(pending.count == 4, "Later Claude read was not scheduled")
        dashboard.selectPrimarySource("codex")
        pending[3].1([record("late", at: now.addingTimeInterval(90))], nil,
                     now.addingTimeInterval(91), false, now.addingTimeInterval(90))
        try check(dashboard.primaryReadout == nil && dashboard.primaryHistoryID == "codex",
            "Late Claude callback overwrote Codex")
        dashboard.selectPrimarySource("claude-code")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(92))
        try check(pending.count == 5, "Re-selecting Claude did not reset throttle")
        dashboard.setConsumptionRange(.tenMinutes)
        pending[4].1([record("wrong-range", at: now)], nil, now.addingTimeInterval(92), false, now)
        try check(pending.count == 6 && dashboard.consumptionRange == .tenMinutes,
            "Superseded period was not retried after in-flight cleanup")
        pending[5].1([record("current", at: Date().addingTimeInterval(-1))], nil, Date(), false, Date())
        try check(dashboard.primaryReadout?.completeTotalTokens == 20,
            "Current period did not receive its own Claude result")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(120))
        try check(pending.count == 7 && dashboard.primaryReadout?.completeTotalTokens == 20,
            "A pending read cleared the last valid measurement")
        pending[6].1([record("fresh-partial-coverage", at: Date().addingTimeInterval(-1), input: 28)],
                     nil, Date(), true, Date())
        try check(dashboard.primaryReadout?.completeTotalTokens == 30 && dashboard.primaryHistoryPending &&
                  CodexClaudePairOverview(model: dashboard, preferences: preferences,
                      codexWindow: nil).claudeSummary.contains("dernier relevé"),
            "A complete measured event was blocked by another session's pending data")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(136))
        try check(pending.count == 8, "Pending reader did not retry")
        pending[7].1([], nil, Date(), true, Date())
        try check(dashboard.primaryReadout?.completeTotalTokens == 30 && dashboard.primaryHistoryPending,
            "Incomplete import erased a dated previous measurement")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(152))
        try check(pending.count == 9, "Failed-read fixture was not scheduled")
        pending[8].1([], "synthetic read failure", Date(), true, nil)
        try check(dashboard.primaryReadout?.completeTotalTokens == 30 &&
                  dashboard.primaryHistoryError == "synthetic read failure",
            "Failed quick read erased the last valid measurement or hid its error")
        dashboard.setRecentClaudeVisible(true, for: "second")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(168))
        try check(pending.count == 10, "Second consumer did not share the live reader")
        dashboard.setRecentClaudeVisible(false, for: "fixture")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(184))
        try check(pending.count == 10, "Removing one of two consumers restarted or cancelled the shared read")
        pending[9].1([record("second-consumer", at: Date().addingTimeInterval(-1))], nil, Date(), false, Date())
        try check(dashboard.primaryReadout?.completeTotalTokens == 20 && !dashboard.primaryHistoryPending,
            "Second consumer's result was lost after the first closed")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(200))
        try check(pending.count == 11, "Stop/reopen fixture did not start an old request")
        dashboard.setRecentClaudeVisible(false, for: "second")
        dashboard.stopLive(for: "fixture")
        dashboard.setRecentClaudeVisible(true, for: "reopened")
        dashboard.startLive(for: "reopened")
        try check(pending.count == 12, "Reopen was blocked by a cancelled in-flight callback")
        pending[10].1([record("stale", at: Date().addingTimeInterval(-1), input: 900)], nil, Date(), false, Date())
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(220))
        try check(pending.count == 12 && dashboard.primaryReadout?.completeTotalTokens == 20,
            "Old callback overwrote data or unlocked a newer in-flight request")
        pending[11].1([], nil, Date(), false, Date().addingTimeInterval(80))
        try check(dashboard.primaryReadout?.aggregate.records.isEmpty == true &&
                  dashboard.primaryReadout?.completeTotalTokens == nil,
            "Reopened reader did not apply the new empty window")
        try check(CodexClaudePairOverview(model: dashboard, preferences: preferences,
                  codexWindow: nil).claudeLastEvent == nil,
            "A future-index timestamp was presented as a known past event")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(236))
        try check(pending.count == 13, "Empty reader did not retry")
        pending[12].1([], nil, Date(), true, Date().addingTimeInterval(-80))
        try check(dashboard.primaryHistoryPending &&
                  dashboard.primaryReadout?.completeTotalTokens == nil &&
                  CodexClaudePairOverview(model: dashboard, preferences: preferences,
                      codexWindow: nil).claudeSummary == "Import récent en attente",
            "Pending empty read became a zero measurement")
        dashboard.setRecentClaudeVisible(false, for: "reopened")
        dashboard.stopLive(for: "reopened")
        dashboard.refreshVisibleClaude(now: now.addingTimeInterval(260))
        try check(pending.count == 13, "No consumer still scheduled scans")
        print("Claude recent readout: bounded pending, two consumers, stop/reopen, throttle, races and missing metrics PASS; synthetic only")
    }
}
