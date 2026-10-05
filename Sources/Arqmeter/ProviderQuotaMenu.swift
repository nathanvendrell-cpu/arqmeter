import AppKit
import ArqmeterCore

/// Only the menu button changes. Its existing target/action remains untouched.
@MainActor enum ProviderQuotaMenu {
    static func apply(to button: NSStatusBarButton, codexRemaining: Int?, codexSampledAt: Date?,
                      codexReset: Date?, claude: ClaudeQuotaReport?, now: Date) {
        let codex = ControlReadout.quota(codexRemaining, sampledAt: codexSampledAt, now: now, resetsAt: codexReset)
        let claudeCurrent = claude?.current(at: now)
        let claudeValue = claudeCurrent?.window.remainingPercent
        let claudeText = claudeValue.map { "\($0) %" } ?? "— %"
        let codexText = codex.map { "\($0) %" } ?? "— %"
        button.title = ""
        button.imagePosition = .imageOnly
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = image(claude: claudeText, codex: codexText)
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "fr_FR"); date.dateFormat = "d MMM à HH:mm"
        let claudeTip: String
        if let current = claudeCurrent, let received = claude?.receivedAt {
            claudeTip = "Claude · \(claudeText) restants · \(current.period) · reset \(date.string(from: current.window.resetsAt)) · reçu via Claude Code à \(date.string(from: received))"
        } else {
            claudeTip = "Claude · quota \(claude == nil || claude?.fiveHour == nil && claude?.sevenDay == nil ? "non reçu" : "périmé") · en attente d’un relevé officiel de Claude Code"
        }
        let codexTip = codex.map { "Codex · \($0) % restants · 7 jours" + (codexReset.map { " · reset \(date.string(from: $0))" } ?? "") } ?? "Codex · quota officiel absent ou périmé"
        button.toolTip = claudeTip + "\n" + codexTip + "\nCliquer pour afficher ou masquer ARQMETER. Quotas séparés, jamais additionnés."
        button.setAccessibilityLabel("ARQMETER. " + claudeTip + ". " + codexTip)
    }

    private static func image(claude: String, codex: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let slot = ceil(("100 %" as NSString).size(withAttributes: attributes).width)
        let segment = 14 + 5 + slot
        let size = NSSize(width: segment * 2 + 28, height: 22)
        let result = NSImage(size: size, flipped: false) { bounds in
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5).fill()
            for (index, pair) in [(ProviderMenuGlyphs.claude, claude), (ProviderMenuGlyphs.codex, codex)].enumerated() {
                let x = 6 + CGFloat(index) * (segment + 16)
                ProviderMenuGlyphs.draw(pair.0, in: .init(x: x, y: 4, width: 14, height: 14))
                let text = pair.1 as NSString
                text.draw(at: .init(x: x + 19 + slot - text.size(withAttributes: attributes).width, y: 3), withAttributes: attributes)
            }
            return true
        }
        result.isTemplate = false
        return result
    }

    static func selfTest() throws {
        print("Diagnostic menu : Claude=\(ProviderMenuGlyphs.claude != nil), Codex=\(ProviderMenuGlyphs.codex != nil), largeur=\(image(claude: "100 %", codex: "100 %").size.width)")
        guard ProviderMenuGlyphs.claude != nil, ProviderMenuGlyphs.codex != nil,
              image(claude: "100 %", codex: "100 %").size.width <= 150 else {
            throw NSError(domain: "ProviderQuotaMenu", code: 1)
        }
        print("Menu : deux logos vectoriels valides, largeur bornée à 150 pt, cas 100 % / 100 % : OK")
    }

    /// The same drawing function, with actual values. Not a desktop capture.
    static func render(to url: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let codex = OfficialUsageReader().snapshot()
        let now = Date(), report = ClaudeQuotaReport.read()
        let claude = report?.current(at: now)?.window.remainingPercent
        let value = ControlReadout.quota(codex?.remainingPercent, sampledAt: codex?.timestamp, now: now, resetsAt: codex?.resetsAt)
        let menuImage = image(claude: claude.map { "\($0) %" } ?? "— %", codex: value.map { "\($0) %" } ?? "— %")
        let width = Int(menuImage.size.width) + 16, height = 38
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 4, pixelsHigh: height * 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NSError(domain: "ProviderQuotaMenu", code: 2) }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 4, y: 4)
        NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        menuImage.draw(in: .init(x: 8, y: 8, width: menuImage.size.width, height: menuImage.size.height))
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "ProviderQuotaMenu", code: 3) }
        try png.write(to: url, options: .atomic)
        print("Rendu AppKit hors écran (pas capture macOS). Claude \(claude.map(String.init) ?? "non reçu") ; Codex \(value.map(String.init) ?? "absent/périmé") % restants. Quotas réels uniquement.")
    }

    /// Real current data only, no collectors and no fabricated quota fixture.
    static func nativeTest() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        let snapshot = OfficialUsageReader().snapshot()
        apply(to: button, codexRemaining: snapshot?.remainingPercent, codexSampledAt: snapshot?.timestamp,
              codexReset: snapshot?.resetsAt, claude: ClaudeQuotaReport.read(), now: Date())
        defer { NSStatusBar.system.removeStatusItem(item) }
        print("Menu QA : données réelles uniquement ; aucun collecteur. PID \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
        NSApp.run()
    }
}
