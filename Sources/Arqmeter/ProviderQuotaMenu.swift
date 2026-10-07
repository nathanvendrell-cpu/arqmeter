import AppKit
import ArqmeterCore

/// Only the menu button changes. Its existing target/action remains untouched.
@MainActor enum ProviderQuotaMenu {
    static func apply(to button: NSStatusBarButton, codexRemaining: Int?, codexSampledAt: Date?,
                      codexReset: Date?, claude: ClaudeQuotaReport?, now: Date,
                      orderedIDs: [String] = ["claude-code", "codex"],
                      claudeMode: ClaudeMenuQuotaMode = .both,
                      cli: ClaudeCLIQuotaReport? = ClaudeCLIQuotaReport.read()) {
        let codex = ControlReadout.quota(codexRemaining, sampledAt: codexSampledAt, now: now, resetsAt: codexReset)
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: claude, cli: cli, at: now)
        let readout = snapshot.readout
        let claudeText = claudeMode.text(readout: readout) ?? ClaudeCLIQuotaReader.shared.compactState
        let codexText = codex.map { "\($0) %" } ?? "— %"
        button.title = ""
        button.imagePosition = .imageOnly
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = image(claude: claudeText, codex: codexText, orderedIDs: orderedIDs, claudeMode: claudeMode,
                                 claudeIsLastKnown: snapshot.isLastKnown)
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "fr_FR"); date.dateFormat = "d MMM à HH:mm"
        let claudeTip: String
        if let readout, claudeMode.text(readout: readout) != nil {
            let windows = claudeMode.periods.map { period -> String in
                let name = period == .fiveHour ? "5 h" : "Semaine"
                guard let window = readout.window(period) else { return "\(name) : pas de relevé actuel" }
                let reset = window.resetsAt.map { " · reset \(date.string(from: $0))" }
                    ?? window.resetLabel.map { " · \($0)" } ?? ""
                return "\(name) : \(window.remainingPercent) % restants\(reset)"
            }.joined(separator: "\n")
            let status = snapshot.isLastKnown ? "Dernier relevé · non actualisé" : "Relevé reçu"
            claudeTip = "Claude · \(status)\n\(windows)\n\(readout.provenance) · reçu à \(date.string(from: readout.observedAt))"
        } else {
            claudeTip = "Claude Code · \(claudeMode.periods.map { $0.rawValue }.joined(separator: " puis ")) · " + ClaudeCLIQuotaReader.shared.state
        }
        let codexTip = codex.map { "Codex · \($0) % restants · 7 jours" + (codexReset.map { " · reset \(date.string(from: $0))" } ?? "") } ?? "Codex · quota officiel absent ou périmé"
        let tips = orderedIDs.map { id in
            switch id {
            case "claude-code": return claudeTip
            case "codex": return codexTip
            default: return SourceDisplay.name(id) + " · activité locale dans ARQMETER · quota non fourni"
            }
        }
        button.toolTip = tips.joined(separator: "\n") + "\nCliquer pour afficher ou masquer ARQMETER. Quotas séparés, jamais additionnés."
        button.setAccessibilityLabel("ARQMETER. " + tips.joined(separator: ". "))
    }

    private static func image(claude: String, codex: String, orderedIDs: [String] = ["claude-code", "codex"],
                              claudeMode: ClaudeMenuQuotaMode = .both, claudeIsLastKnown: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let slot = ceil(("100 %" as NSString).size(withAttributes: attributes).width)
        let quotaSlot = claudeMode == .both
            ? ceil(("100 % - 100 %" as NSString).size(withAttributes: attributes).width) : slot
        // Reserve the freshness marker even while current: no width jump when
        // the passive source is silent. The quota digits keep their size.
        let claudeSlot = quotaSlot + 14
        let entries = orderedIDs.filter(SourceDisplay.order.contains).map { id -> (CGPath?, String, CGFloat) in
            if id == "claude-code" { return (ProviderMenuGlyphs.claude, claude, 19 + claudeSlot) }
            if id == "codex" { return (ProviderMenuGlyphs.codex, codex, 19 + slot) }
            let label = id == "ollama" ? "Ollama" : "Gemini"
            return (nil, label, ceil((label as NSString).size(withAttributes: attributes).width))
        }
        let size = NSSize(width: entries.reduce(12) { $0 + $1.2 } + CGFloat(max(0, entries.count - 1)) * 16, height: 22)
        let result = NSImage(size: size, flipped: false) { bounds in
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5).fill()
            var x: CGFloat = 6
            for pair in entries {
                if let path = pair.0 { ProviderMenuGlyphs.draw(path, in: .init(x: x, y: 4, width: 14, height: 14)) }
                let text = pair.1 as NSString
                let isClaude = pair.0 === ProviderMenuGlyphs.claude
                let markerWidth: CGFloat = isClaude ? 14 : 0
                text.draw(at: .init(x: x + pair.2 - markerWidth - text.size(withAttributes: attributes).width, y: 3), withAttributes: attributes)
                if isClaude && claudeIsLastKnown,
                   let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: "Dernier relevé, non actualisé") {
                    clock.draw(in: .init(x: x + pair.2 - 10, y: 6, width: 10, height: 10))
                }
                x += pair.2 + 16
            }
            return true
        }
        result.isTemplate = false
        return result
    }

    static func selfTest() throws {
        print("Diagnostic menu : Claude=\(ProviderMenuGlyphs.claude != nil), Codex=\(ProviderMenuGlyphs.codex != nil), largeur=\(image(claude: "100 %", codex: "100 %").size.width)")
        guard ProviderMenuGlyphs.claude != nil, ProviderMenuGlyphs.codex != nil,
              image(claude: "100 % - 100 %", codex: "100 %").size.width <= 270 else {
            throw NSError(domain: "ProviderQuotaMenu", code: 1)
        }
        print("Menu : deux logos vectoriels valides, deux fenêtres Claude sans réduction des textes : OK")
        guard image(claude: "100 % - 100 %", codex: "100 %", orderedIDs: SourceDisplay.order).size.width <= 420 else {
            throw NSError(domain: "ProviderQuotaMenu", code: 4)
        }
        for state in ["…", "!", "?"] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            guard (state as NSString).size(withAttributes: [.font: font]).width <= ("100 %" as NSString).size(withAttributes: [.font: font]).width else {
                throw NSError(domain: "ProviderQuotaMenu", code: 5)
            }
        }
        for mode in ClaudeMenuQuotaMode.allCases {
            let text = mode == .both ? "100 % - 100 %" : "100 %"
            let value = image(claude: text, codex: "100 %", claudeMode: mode)
            guard value.size.width <= (mode == .both ? 270 : 170), value.size.height == 22,
                  value.size == image(claude: text, codex: "100 %", claudeMode: mode, claudeIsLastKnown: true).size else {
                throw NSError(domain: "ProviderQuotaMenu", code: 6)
            }
        }
    }

    /// The same drawing function, with actual values. Not a desktop capture.
    static func render(to url: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let codex = OfficialUsageReader().snapshot()
        let now = Date(), report = ClaudeQuotaReport.read()
        let mode = SourceDisplayPreferences.shared.claudeQuotaMode
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: report, cli: ClaudeCLIQuotaReport.read(), at: now)
        let claude = mode.text(readout: snapshot.readout)
        let value = ControlReadout.quota(codex?.remainingPercent, sampledAt: codex?.timestamp, now: now, resetsAt: codex?.resetsAt)
        let menuImage = image(claude: claude ?? ClaudeCLIQuotaReader.shared.compactState, codex: value.map { "\($0) %" } ?? "— %",
            orderedIDs: SourceDisplayPreferences.shared.orderedVisibleIDs, claudeMode: mode, claudeIsLastKnown: snapshot.isLastKnown)
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
        print("Rendu AppKit hors écran (pas capture macOS). Claude \(claude ?? "non reçu") ; Codex \(value.map(String.init) ?? "absent/périmé") % restants. Quotas réels uniquement.")
    }

    /// Read-only runtime diagnostic; the same preference and readout as the bar.
    static func reportCurrent() {
        let preferences = SourceDisplayPreferences.shared
        let now = Date()
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: ClaudeQuotaReport.read(), cli: ClaudeCLIQuotaReport.read(), at: now)
        let readout = snapshot.readout
        let windows: [[String: Any]] = preferences.claudeQuotaMode.periods.map { period in
            var value: [String: Any] = ["window": period.rawValue]
            if let window = readout?.window(period) {
                value["remainingPercent"] = window.remainingPercent
                if let reset = window.resetsAt { value["resetsAt"] = ISO8601DateFormatter().string(from: reset) }
            }
            return value
        }
        var result: [String: Any] = ["mode": preferences.claudeQuotaMode.rawValue,
                                    "windows": windows,
                                    "text": preferences.claudeQuotaMode.text(readout: readout) ?? "no-current-reading",
                                    "orderedSources": preferences.orderedVisibleIDs,
                                    "freshness": readout == nil ? "unavailable" : snapshot.isLastKnown ? "last-known" : "recent-receipt"]
        if let readout { result["receivedAt"] = ISO8601DateFormatter().string(from: readout.observedAt) }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
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
