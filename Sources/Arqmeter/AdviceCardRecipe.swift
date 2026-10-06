import AppKit
import SwiftUI
import ArqmeterCore

/// Shared production card rendered offscreen with clearly labelled synthetic
/// test inputs. No activation, collector, preferences, database or network.
enum AdviceCardRecipe {
    @MainActor static func render(scenario: String, to output: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let rows = (0..<6).map { i -> UnifiedUsageRecord in
            let claude = scenario == "claude-cache"
            let input: Int64 = scenario == "uncached-growth" ? 50_000 : i < 3 ? 10_000 : 30_000
            let cache: UsageMeasurement<Int64> = scenario == "partial-cache" && i == 0 ? .unavailable :
                .measured(scenario == "uncached-growth" ? (i < 3 ? 49_000 : 20_000) : (i < 3 ? 5_000 : 29_000))
            return UnifiedUsageRecord(eventID: "fixture:\(i)", timestamp: Date(timeIntervalSince1970: Double(i)),
                projectPath: "/fixture/project", sessionID: "fixture", harnessID: claude ? "claude-code" : "codex",
                providerID: claude ? "anthropic" : "openai", modelID: "fixture-model",
                inputTokens: .measured(input), outputTokens: .measured(500),
                cachedInputTokens: cache, reasoningTokens: .unavailable, costUSD: .unavailable,
                durationSeconds: .unavailable, executionLocation: .unavailable,
                sourceKind: claude ? .claudeCodeSessionLog : .codexSessionLog,
                provenance: "Cas de test synthétique, pas une session utilisateur")
        }
        guard ["cached-growth", "uncached-growth", "partial-cache", "claude-cache"].contains(scenario),
              let item = SessionOptimizer.analyze(rows).first(where: { $0.type == .contextGrowth })
        else { throw failure("Cas inconnu ou sans conseil") }
        let root = VStack(alignment: .leading, spacing: 14) {
            Text("CONSEILS — CAS DE TEST").font(.system(size: 15, weight: .semibold))
            AdviceCardView(item: item, resolvedModel: item.modelID, proofsExpanded: true,
                onOpenSession: {}, onIgnore: {}, onPrepareTrial: {})
            Text("Données synthétiques · composant réel · aucune base utilisateur")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 720).foregroundStyle(InstrumentTheme.text)
        // Match the accepted clear/light application, not a fabricated dark
        // canvas behind its deliberately dark text. Desktop blur is not tested
        // by this offscreen component render.
        .background(InstrumentTheme.paper)
        .tint(InstrumentTheme.blue).environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = InstrumentTheme.windowAppearance
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, size.height < 1_600 else { throw failure("Taille invalide") }
        window.setContentSize(size); hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw failure("Bitmap indisponible") }
        bitmap.size = size; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG indisponible") }
        try png.write(to: output, options: .atomic)
        print("AdviceCardView hors écran : \(Int(size.width))×\(Int(size.height)) pt, cas \(scenario), données synthétiques marquées ; aucun focus ni collecteur.")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AdviceCardRecipe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
