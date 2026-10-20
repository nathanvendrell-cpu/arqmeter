import AppKit
import Foundation
import ArqmeterCore
import SwiftUI

/// CLI-only integration fixture. Isolated defaults and injected history; no
/// app UI, provider, real profile, database or autonomous collector.
enum PrimaryPairRecipe {
    static func selfTest() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "PrimaryPairRecipe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let suite = "com.7agency.arqmeter.tests.pair.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "PrimaryPairRecipe", code: 2) }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["ollama", "claude-code", "codex"], forKey: "orderedSourceIDs")
        defaults.set(["ollama", "claude-code", "codex"], forKey: "visibleSourceIDs")
        defaults.set("ollama", forKey: "primarySourceID")
        defaults.set("keep", forKey: "unrelatedPreference")
        let preferences = SourceDisplayPreferences(defaults: defaults)
        try check(!preferences.showsCodexAndClaude && preferences.selectedHistoryID == "ollama",
            "Legacy single choice was not migrated intact")
        preferences.showCodexAndClaude()
        try check(preferences.showsCodexAndClaude && preferences.primaryID == "ollama" &&
                  preferences.selectedHistoryID == "claude-code" &&
                  preferences.menuDisplayOrder == ["codex", "claude-code", "ollama"],
            "Pair changed a harness ID, order or selected history")
        let restored = SourceDisplayPreferences(defaults: defaults)
        try check(restored.showsCodexAndClaude && restored.primaryID == "ollama" &&
                  defaults.string(forKey: "unrelatedPreference") == "keep", "Pair persistence changed legacy prefs")
        try check(preferences.claudeQuotaMode.periods == [.fiveHour, .sevenDay],
            "Pair changed Claude's 5 h then week order")
        preferences.setClaudeQuotaMode(.sevenDay)
        try check(preferences.showsCodexAndClaude &&
                  SourceDisplayPreferences(defaults: defaults).claudeQuotaMode == .sevenDay,
            "Claude quota window preference was lost in pair mode")
        preferences.setPrimary("ollama")
        try check(!preferences.showsCodexAndClaude && preferences.primaryID == "ollama",
            "Choosing the old single did not leave pair mode")
        preferences.showCodexAndClaude()
        preferences.setVisible("claude-code", false)
        try check(!preferences.showsCodexAndClaude && preferences.presentationMode == .single &&
                  Array(preferences.orderedIDs.prefix(3)) == ["ollama", "claude-code", "codex"],
            "Hiding a pair member left an invalid pair or changed order")
        preferences.setVisible("claude-code", true)
        try check(!preferences.showsCodexAndClaude, "Pair returned silently after re-showing a source")
        preferences.setVisible("claude-code", false)
        defaults.set(SourcePresentationMode.codexAndClaude.rawValue,
                     forKey: SourcePresentationMode.defaultsKey)
        let recovered = SourceDisplayPreferences(defaults: defaults)
        try check(recovered.presentationMode == .single && recovered.primaryID == "ollama" &&
                  SourcePresentationMode.load(from: defaults) == .single,
            "Persisted pair with a hidden member was not normalized")
        recovered.setVisible("claude-code", true)
        try check(!SourceDisplayPreferences(defaults: defaults).showsCodexAndClaude,
            "Re-showing a hidden source reactivated an invalid persisted pair")

        var pending: [(String, PrimaryHistoryCompletion)] = []
        let dashboard = DashboardModel(quotaHistoryStore: QuotaHistoryStore(url: nil),
            comparison: ComparisonModel(archiveURL: nil, annotationsURL: nil),
            readPrimaryHistory: { id, _, _, completion in pending.append((id, completion)) },
            primaryAvailability: { _ in (true, true) })
        let now = Date()
        let partialJSON = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":25,\"resets_at\":\(now.addingTimeInterval(3600).timeIntervalSince1970)}}}"
        let partial = try ClaudeQuotaReport.decodeStatusLine(Data(partialJSON.utf8), receivedAt: now)
        dashboard.applyClaudeQuota(statusLine: partial, cli: nil, at: now)
        try check(dashboard.remainingPercent == nil &&
                  dashboard.claudeQuotaSnapshot?.readout?.window(.fiveHour)?.remainingPercent == 75,
            "Claude quota was lost when Codex quota was absent")
        dashboard.apply(snapshot: UsageSnapshot(remainingPercent: 61, timestamp: now,
            resetsAt: now.addingTimeInterval(3600)))
        dashboard.applyClaudeQuota(statusLine: nil, cli: nil, at: now)
        try check(dashboard.remainingPercent == 61 && dashboard.claudeQuotaSnapshot?.readout == nil,
            "Missing Claude quota borrowed Codex percentage")
        dashboard.applyClaudeQuota(statusLine: partial, cli: nil, at: now)
        try check(dashboard.claudeQuotaSnapshot?.readout?.window(.fiveHour)?.remainingPercent == 75 &&
                  dashboard.claudeQuotaSnapshot?.readout?.window(.sevenDay) == nil &&
                  dashboard.remainingPercent == 61, "Partial Claude windows were merged or substituted")

        dashboard.selectPrimarySource("claude-code")
        try check(pending.map(\.0) == ["claude-code"], "Pair did not request only Claude indexed history")
        let record = UnifiedUsageRecord(eventID: "pair-claude", timestamp: Date().addingTimeInterval(-1),
            projectPath: nil, sessionID: "fixture", harnessID: "claude-code", providerID: "anthropic",
            modelID: nil, inputTokens: .measured(18), outputTokens: .measured(2),
            cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
            costUSD: .unavailable, durationSeconds: .unavailable, executionLocation: .cloud,
            sourceKind: .init("test.fixture"), provenance: "synthetic fixture")
        pending[0].1([record], nil)
        try check(dashboard.primaryReadout?.completeTotalTokens == 20 && dashboard.remainingPercent == 61 &&
                  dashboard.claudeQuotaSnapshot?.readout?.window(.fiveHour)?.remainingPercent == 75,
            "Independent Codex, Claude tokens and Claude quota did not coexist")
        dashboard.apply(snapshot: UsageSnapshot(remainingPercent: 60, timestamp: now.addingTimeInterval(1),
            resetsAt: now.addingTimeInterval(3600)))
        try check(dashboard.primaryReadout?.completeTotalTokens == 20 && dashboard.remainingPercent == 60 &&
                  dashboard.claudeQuotaSnapshot?.readout?.window(.fiveHour)?.remainingPercent == 75,
            "Codex refresh overwrote the independent Claude measurements")
        dashboard.setConsumptionRange(.hour)
        dashboard.selectPrimarySource("codex")
        pending[1].1([record], nil)
        try check(dashboard.primaryReadout == nil && dashboard.primaryHistory == nil && dashboard.remainingPercent == 60,
            "Old paired Claude result leaked into single Codex")
        dashboard.selectPrimarySource("claude-code")
        let partialTokens = UnifiedUsageRecord(eventID: "pair-partial", timestamp: Date().addingTimeInterval(-1),
            projectPath: nil, sessionID: "fixture", harnessID: "claude-code", providerID: "anthropic",
            modelID: nil, inputTokens: .measured(18), outputTokens: .unavailable,
            cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
            costUSD: .unavailable, durationSeconds: .unavailable, executionLocation: .cloud,
            sourceKind: .init("test.fixture"), provenance: "synthetic fixture")
        pending[2].1([partialTokens], nil)
        try check(dashboard.primaryReadout?.completeTotalTokens == nil && dashboard.remainingPercent == 60,
            "Partial Claude tokens became a measured total")
        try check(CodexClaudePairOverview(model: dashboard, preferences: preferences,
                  codexWindow: nil).claudeSummary == "Mesure partielle ou indisponible",
            "Pair did not label incomplete Claude token data")
        dashboard.refreshPrimaryHistory()
        pending[3].1([], nil)
        try check(dashboard.primaryReadout?.completeTotalTokens == nil && dashboard.remainingPercent == 60,
            "Absent Claude history became zero or hid Codex")
        try check(CodexClaudePairOverview(model: dashboard, preferences: preferences,
                  codexWindow: nil).claudeSummary == "Pas de mesure sur cette période",
            "Pair did not distinguish empty history from partial data")
        // Layout only: the 420-point HUD has 12-point scroll padding on each side.
        // No NSWindow is created or shown, and every model/default comes from this fixture.
        recovered.showCodexAndClaude()
        func offscreenSize() -> NSSize {
            let host = NSHostingView(rootView: CodexClaudePairOverview(model: dashboard,
                preferences: recovered, codexWindow: nil).frame(width: 396))
            return host.fittingSize
        }
        let unknownSize = offscreenSize()
        dashboard.selectPrimarySource("codex")
        dashboard.selectPrimarySource("claude-code")
        try check(dashboard.primaryHistoryLoading && CodexClaudePairOverview(model: dashboard,
                  preferences: recovered, codexWindow: nil).claudeSummary == "Lecture de l’historique…",
            "Pair did not show Claude loading independently")
        let longRecord = UnifiedUsageRecord(eventID: "pair-long", timestamp: Date().addingTimeInterval(-1),
            projectPath: nil, sessionID: "fixture", harnessID: "claude-code", providerID: "anthropic",
            modelID: nil, inputTokens: .measured(Int64.max / 2), outputTokens: .measured(Int64.max / 2),
            cachedInputTokens: .unavailable, reasoningTokens: .unavailable,
            costUSD: .unavailable, durationSeconds: .unavailable, executionLocation: .cloud,
            sourceKind: .init("test.fixture"), provenance: "synthetic fixture")
        pending[4].1([longRecord], nil)
        try check(CodexClaudePairOverview(model: dashboard, preferences: recovered,
                  codexWindow: nil).claudeLastEvent?.contains("Dernier événement") == true,
            "Pair did not date the actual last Claude event")
        dashboard.apply(snapshot: UsageSnapshot(remainingPercent: 100, timestamp: now,
            resetsAt: now.addingTimeInterval(3600)))
        let longSize = offscreenSize()
        try check(unknownSize.width == 396 && longSize.width == 396 &&
                  unknownSize.height.isFinite && longSize.height.isFinite &&
                  unknownSize.height > 0 && longSize.height > 0 &&
                  unknownSize.height <= 650 && longSize.height <= 650,
            "Offscreen pair did not fit the 396-point HUD content width")
        dashboard.refreshPrimaryHistory()
        pending[5].1([], "fixture-error")
        try check(CodexClaudePairOverview(model: dashboard, preferences: recovered,
                  codexWindow: nil).claudeSummary == "Historique indisponible",
            "Pair did not distinguish a read failure from empty history")
        print("Pair offscreen fitting at 396 pt: unknown=\(unknownSize.height), long=\(longSize.height) pt; synthetic, not installed UI")
        print("Codex + Claude: legacy prefs, pair/single/visibility, partial quotas and async independence PASS; synthetic only")
    }
}
