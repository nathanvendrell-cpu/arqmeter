import AppKit
import SwiftUI
import ArqmeterCore

enum DailyAnalysisRecipe {
    @MainActor static func selfTest() throws {
        let now = UTCDay.date("2026-10-07")!.addingTimeInterval(12 * 3600)
        var pending: [([UnifiedUsageRecord], String?) -> Void] = []
        var harnesses: [String] = []
        let model = DailyAnalysisModel(read: { harness, start, end, completion in
            guard start < end else { return }
            harnesses.append(harness); pending.append(completion)
        })
        model.refresh(days: [ArchivedDailyTokens(day: "2026-10-05", tokens: 500)], at: now)
        guard model.window?.total == 500, harnesses.isEmpty else { throw failure("Account read unexpectedly queried local events") }
        model.source = .codex; model.refresh(days: [], at: now)
        model.source = .claude; model.refresh(days: [], at: now)
        guard model.window == nil, model.loading, harnesses == ["codex", "claude-code"] else { throw failure("Source transition leaked previous values") }
        let row = UnifiedUsageRecord(eventID: "fixture", timestamp: now.addingTimeInterval(-60), projectPath: "/fixture/project",
            sessionID: "fixture", harnessID: "claude-code", providerID: nil, modelID: nil,
            inputTokens: .measured(100), outputTokens: .measured(20), cachedInputTokens: .measured(80),
            reasoningTokens: .unavailable, costUSD: .unavailable, durationSeconds: .unavailable,
            executionLocation: .unavailable, sourceKind: .claudeCodeSessionLog, provenance: "Synthetic fixture")
        pending[0]([row], nil)
        guard model.window == nil else { throw failure("Old asynchronous response won selection") }
        pending[1]([row], nil)
        guard model.window?.total == 120, !model.loading else { throw failure("Current source response missing") }
        model.metric = .uncached; model.prepare()
        guard model.window?.total == 20 else { throw failure("Metric selector mismatch") }
        model.project = "/fixture/unknown"; model.prepare()
        guard model.window?.total == nil else { throw failure("Project filter ignored") }
        model.project = ""; model.prepare()
        guard model.window?.total == 20 else { throw failure("All projects did not restore population") }
        model.source = .ollama; model.refresh(days: [], at: now)
        guard model.metric == .duration, harnesses.last == "ollama" else { throw failure("Local source unit mismatch") }
        pending[2]([], "Synthetic read error")
        guard model.window?.total == nil, model.error != nil else { throw failure("Empty/error became measured zero") }
        print("Daily analysis: calendar/source/metric/project filters, async race, empty/error and account isolation PASS; synthetic inputs only")
    }

    /// Production view, optionally supplied actual official daily archive. No
    /// network, collectors, preferences or databases are written. Not a desktop capture.
    @MainActor static func render(to output: URL, width: CGFloat, real: Bool, month: Bool = false, empty: Bool = false) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let comparison = ComparisonModel(archiveURL: nil, annotationsURL: nil)
        let model = DailyAnalysisModel(renderOnly: true)
        if month { model.period = .month }
        let date = real ? Date() : UTCDay.date("2026-10-07")!.addingTimeInterval(12 * 3600)
        let data = real ? OfficialDailyArchive().days : empty ? [] : [
            ArchivedDailyTokens(day: "2026-10-01", tokens: 1_400_000),
            ArchivedDailyTokens(day: "2026-10-02", tokens: 2_100_000),
            ArchivedDailyTokens(day: "2026-10-05", tokens: 1_800_000),
            ArchivedDailyTokens(day: "2026-10-06", tokens: 2_700_000),
            ArchivedDailyTokens(day: "2026-10-07", tokens: 750_000),
        ]
        comparison.archiveDays = data
        model.loadForRender(days: data, at: date)
        let root = VStack(alignment: .leading, spacing: 12) {
            Text(real ? "Consommation · archive réelle du compte" : "Consommation · données synthétiques de recette")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            DailyAnalysisPanel(comparison: comparison, model: model)
        }.padding(20).frame(width: width).foregroundStyle(InstrumentTheme.text)
            .background(InstrumentTheme.paper).tint(InstrumentTheme.blue).environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = InstrumentTheme.windowAppearance
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width == width, size.height > 0, size.height < 1_100 else { throw failure("Unbounded layout") }
        window.setContentSize(size); hosting.frame = .init(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw failure("Bitmap unavailable") }
        bitmap.size = size; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG unavailable") }
        try png.write(to: output, options: .atomic)
        print("Production analysis view rendered offscreen: \(Int(size.width))×\(Int(size.height)) pt, \(real ? "real local archive" : "synthetic data"); no account request or user data mutation. NOT a desktop capture.")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DailyAnalysisRecipe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
