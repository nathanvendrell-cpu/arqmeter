import AppKit
import SwiftUI
import ArqmeterCore

/// Test-only offscreen rendering. Never activates an app, starts a collector,
/// opens a user window or writes an archive/preferences file.
enum WeeklyQuotaRecipe {
    @MainActor static func render(arguments: [String]) throws {
        guard arguments.count >= 2 else { throw failure("Mois AAAA-MM et sortie PNG requis") }
        let parts = arguments[0].split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]), (1900...9999).contains(parts[0])
        else { throw failure("Mois invalide") }
        let output = URL(fileURLWithPath: arguments[1])
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let model = AccountTimelineModel()
        model.selectQuotaMonth(QuotaCalendarMonth(year: parts[0], month: parts[1]))
        let points = QuotaHistoryStore().points // Read-only: record is never called.
        let archive = OfficialDailyArchive()
        let now = Date()
        let monthCycles = WeeklyQuotaTimeline.inMonth(model.quotaMonth,
            cycles: WeeklyQuotaTimeline.cycles(points.map {
                WeeklyQuotaObservation(observedAt: $0.date, resetsAt: $0.resetsAt,
                    remainingPercent: $0.remainingPercent, source: "codex", limit: "weekly")
            }, now: now), calendar: calendar)
        if arguments.contains("previous") { model.selectedQuotaCycleID = monthCycles.first?.id }
        model.quotaTokensExpanded = arguments.contains("expanded")
        model.setRange(.thirtyDays)
        let content: AnyView
        if arguments.contains("tokens") {
            content = AnyView(AccountTokenTimelineCard(model: model, days: archive.days))
        } else {
            content = AnyView(AccountTimelineCard(model: model, days: archive.days,
                quotaPoints: points, liveQuota: nil, calendar: calendar, now: now))
        }
        let root = content.padding(12).frame(width: 420)
            .background {
                ZStack {
                    Color(red: 0.12, green: 0.13, blue: 0.16)
                    LinearGradient(colors: [InstrumentTheme.blue.opacity(0.08), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .foregroundStyle(InstrumentTheme.text).tint(InstrumentTheme.blue)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = InstrumentTheme.windowAppearance
        window.contentView = hosting
        // Not ordered in / made key. AppKit's backing view is drawn in memory.
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, size.height < 1_000 else { throw failure("Taille de rendu invalide") }
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw failure("Bitmap indisponible") }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG indisponible") }
        try png.write(to: output, options: .atomic)
        window.contentView = nil
        window.close()
        print("Rendu hors écran : \(Int(size.width)) × \(Int(size.height)) pt / \(bitmap.pixelsWide) × \(bitmap.pixelsHigh) px ; mois \(arguments[0]) ; \(monthCycles.count) cycles observés ; archive utilisateur en lecture seule")
    }

    static func selfTest() throws {
        let store = QuotaHistoryStore(url: nil) // Never touches the user archive.
        let dashboard = DashboardModel(quotaHistoryStore: store)
        let model = dashboard.accountTimeline
        let chosen = QuotaCalendarMonth(year: 2025, month: 12)
        model.selectQuotaMonth(chosen)
        model.selectedQuotaCycleID = "remembered-cycle"
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        dashboard.apply(snapshot: UsageSnapshot(remainingPercent: 75, timestamp: date,
            resetsAt: date.addingTimeInterval(604_800)))
        dashboard.apply(snapshot: UsageSnapshot(remainingPercent: 74,
            timestamp: date.addingTimeInterval(60), resetsAt: date.addingTimeInterval(604_800)))
        dashboard.apply(snapshot: UsageSnapshot(remainingPercent: 100,
            timestamp: date.addingTimeInterval(120), resetsAt: date.addingTimeInterval(2 * 604_800)))
        _ = WeeklyQuotaTimeline.cycles(store.points.map {
            WeeklyQuotaObservation(observedAt: $0.date, resetsAt: $0.resetsAt,
                remainingPercent: $0.remainingPercent, source: "codex", limit: "weekly")
        }, now: date)
        guard dashboard.quotaHistory.count == 3,
              model.quotaMonth == chosen, model.selectedQuotaCycleID == "remembered-cycle"
        else { throw failure("Actualisation ayant déplacé la sélection du mois") }
        model.selectQuotaMonth(.init(year: 2026, month: 1))
        guard model.selectedQuotaCycleID == nil else { throw failure("Sélection d’un cycle hors mois") }
        let history = QuotaHistoryStore(url: nil)
        let old = Calendar.current.date(byAdding: .month, value: -2, to: date)!
        _ = history.record(UsageSnapshot(remainingPercent: 55, timestamp: old,
            resetsAt: old.addingTimeInterval(604_800)))
        _ = history.record(UsageSnapshot(remainingPercent: 75, timestamp: date,
            resetsAt: date.addingTimeInterval(604_800)))
        guard history.points.count == 2, history.points.first?.date == old,
              QuotaHistoryStore.maximumPoints == 10_000 else {
            throw failure("Historique mensuel tronqué à 14 jours ou non borné")
        }
        let cap = QuotaHistoryStore(url: nil)
        for index in 0...QuotaHistoryStore.maximumPoints {
            let timestamp = date.addingTimeInterval(Double(index))
            _ = cap.record(UsageSnapshot(remainingPercent: index % 2, timestamp: timestamp,
                resetsAt: date.addingTimeInterval(604_800)))
        }
        guard cap.points.count == QuotaHistoryStore.maximumPoints,
              cap.points.first?.date == date.addingTimeInterval(1) else {
            throw failure("Borne de conservation non respectée")
        }
        print("Carte quota : mois maintenu pendant l’actualisation ; sélection réinitialisée uniquement par navigation ; relevés anciens conservés ; borne 10 000 ; aucune écriture utilisateur : OK")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WeeklyQuotaRecipe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
