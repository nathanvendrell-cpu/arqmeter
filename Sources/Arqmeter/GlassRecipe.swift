import AppKit
import SwiftUI

/// Isolated visual QA, same dashboard/hosting/popover as production. No monitor,
/// SQLite import, official RPC, preference change or user-archive write.
enum GlassRecipe {
    @MainActor private static func model() -> DashboardModel {
        let dashboard = DashboardModel(quotaHistoryStore: QuotaHistoryStore(url: nil))
        dashboard.local = LocalActivityStore().refresh()
        return dashboard
    }

    @MainActor static func render(to output: URL) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let dashboard = model()
        let root = DashboardView(model: dashboard)
        let hosting = ArqmeterHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 650),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = InstrumentTheme.windowAppearance
        window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 650)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 840, pixelsHigh: 1300, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { throw failure("Bitmap unavailable") }
        bitmap.size = NSSize(width: 420, height: 650)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG unavailable") }
        try data.write(to: output, options: .atomic)
        print("HUD réel hors écran 420×650 pt / 840×1300 px ; tokens locaux lus une fois, aucun collecteur ; flou du bureau NON VÉRIFIÉ par ce rendu.")
    }

    /// Run only in a coordinated native QA slot. All task-owned UI is removed.
    @MainActor static func nativeTest() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let dashboard = model()
        let delegate = AppDelegate(qaDashboard: dashboard)
        application.delegate = delegate
        // A second status item can be outside the visible menu bar. Use an
        // explicit visible QA anchor, never mistake an unshown popover for QA.
        let anchor = NSWindow(contentRect: NSRect(x: 60, y: 100, width: 420, height: 50),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        anchor.title = "ARQMETER — ancrage TEST, fermeture automatique"
        anchor.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            anchor.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 60,
                y: screen.visibleFrame.maxY - 100))
        }
        let button = NSButton(title: "Masquer / rouvrir le HUD — TEST", target: nil, action: nil)
        button.frame = NSRect(x: 80, y: 8, width: 260, height: 34)
        anchor.contentView?.addSubview(button)
        delegate.prepareNativeQA(anchor: button)
        let close = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { delegate.endNativeQA() }
            application.stop(nil)
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0)
            if let event { application.postEvent(event, atStart: true) }
        }
        defer {
            close.invalidate(); delegate.endNativeQA()
            anchor.close()
            dashboard.stopAllLive()
        }
        DispatchQueue.main.async {
            anchor.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            delegate.showNativeQAIfNeeded()
        }
        print("TEST natif 120 s — contrôleur de production, même HUD 420×650 ; lecture locale, aucun RPC/import/écriture d’archive ; fermeture automatique des fenêtres TEST.")
        fflush(stdout)
        application.run()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GlassRecipe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
