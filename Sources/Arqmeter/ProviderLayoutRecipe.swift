import AppKit
import SwiftUI
import ArqmeterCore

/// Isolated QA: real readouts, a SQLite backup (never the live database), no
/// imports/collectors and a separate preference domain. Not a production capture.
@MainActor enum ProviderLayoutRecipe {
    static let suite = "com.7agency.arqmeter.providerlayoutqa"

    static func preferencesRoundtrip(stage: String) throws {
        let defaults = UserDefaults(suiteName: suite)!
        if stage == "write" {
            var layout = SourceLayout(visible: ["codex", "claude-code", "ollama"], primary: "ollama")
            _ = layout.move("claude-code", relativeTo: "codex", after: false)
            layout.save(to: defaults)
            defaults.synchronize()
            print("QA preferences written in isolated domain \(suite)")
        } else {
            let layout = SourceLayout.load(from: defaults)
            guard layout.orderedVisibleIDs == ["claude-code", "codex", "ollama"],
                  layout.primaryID == "ollama" else { throw failure("Preferences not retained across processes") }
            print("QA preferences after process restart: Claude, Codex, Ollama; Gemini hidden; primary Ollama: OK")
        }
    }

    static func native(database: URL) throws {
        guard database.lastPathComponent == "provider-qa-history.sqlite3",
              database.path.contains("/build/.provider-layout-") else {
            throw failure("Owned SQLite backup required; production database is refused")
        }
        let store = try HistoricalUsageStore(url: database)
        let now = Date(), start = now.addingTimeInterval(-7 * 86400)
        let records = try store.records(from: start, to: now)
        var older: [String: UsageAggregate] = [:]
        for id in SourceDisplay.order where !records.contains(where: { $0.harnessID == id }) {
            let archived = try store.records(harness: id, from: Date(timeIntervalSince1970: 0), to: now)
            if !archived.isEmpty { older[id] = UsageAggregate(records: archived) }
        }
        let snapshot = HistoricalDashboardSnapshot(records: records, sessions: UsageSessionIndex.sessions(records),
            availability: SourceAvailabilityProbe.detect(),
            coverage: try SourceDisplay.order.map { try store.coverage(harness: $0, from: start, to: now) },
            olderSourceHistory: older, recommendations: [], comparability: [:], scanResults: [], error: nil)
        let sourceModel = SourcesValidationModel(readOnlySnapshot: snapshot)
        let dashboard = DashboardModel(quotaHistoryStore: QuotaHistoryStore(url: nil))
        if let quota = OfficialUsageReader().snapshot() { dashboard.apply(snapshot: quota) }
        dashboard.selectedTab = .quota
        let preferences = SourceDisplayPreferences(defaults: UserDefaults(suiteName: suite)!)
        let application = NSApplication.shared
        // This isolated recipe has a normal app identity so native QA can
        // select it without confusing it with the production menu-bar agent.
        application.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ARQMETER — Fournisseurs (TEST isolé)"
        window.appearance = InstrumentTheme.windowAppearance
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.contentView = ArqmeterHostingView(rootView: DashboardView(model: dashboard,
            sourcePreferences: preferences, sourcesModel: sourceModel))
        window.center()
        let close = Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { _ in
            MainActor.assumeIsolated { application.stop(nil) }
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                application.postEvent(event, atStart: true)
            }
        }
        defer {
            close.invalidate(); dashboard.stopAllLive()
            window.contentView = nil; window.close()
        }
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: false)
        }
        print("Provider layout QA PID \(ProcessInfo.processInfo.processIdentifier); actual quotas/absent Claude; private backup; isolated preferences; automatic shutdown 240 s")
        fflush(stdout)
        application.run()
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "ProviderLayoutRecipe", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
