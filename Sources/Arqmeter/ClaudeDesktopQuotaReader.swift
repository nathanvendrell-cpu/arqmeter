import AppKit
import ApplicationServices
import ArqmeterCore

/// Passive accessibility reads only. Never presses Claude controls, opens a
/// conversation, activates/restarts Claude, reads inputs or accesses credentials.
enum ClaudeDesktopAXReader {
    enum Failure: String, Error, Sendable {
        case permission = "Accessibilité à autoriser pour Arqmeter"
        case absent = "Application Claude fermée"
        case panel = "Ouvrir Claude → Paramètres → Utilisation"
        case unreadable = "Panneau Claude non lisible"
        case budget = "Lecture bornée incomplète"
    }
    final class Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var exhausted = false
        var incomplete = false
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, !exhausted else { exhausted = true; return nil }
            // Best-effort OS-call timeout, not a hard real-time scheduler promise.
            AXUIElementSetMessagingTimeout(element, Float(min(0.15, remaining)))
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            if ProcessInfo.processInfo.systemUptime >= deadline { exhausted = true; return nil }
            if error != .success && error != .attributeUnsupported && error != .noValue { incomplete = true }
            return error == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            value(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
        }
        func role(_ element: AXUIElement) -> String {
            value(element, kAXRoleAttribute as String) as? String ?? ""
        }
    }
    static func quotaLabel(_ element: AXUIElement, budget: Budget) -> String? {
        let allowed: Set<String> = ["Session actuelle", "Limite de session", "Current session", "Session limit",
            "Cette semaine", "Hebdomadaire · tous les modèles", "This week", "All models", "Weekly · all models"]
        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
            if let text = budget.value(element, attribute) as? String, allowed.contains(text) { return text }
        }
        return nil
    }
    // Never inspect a text field or the message tree's text. Only inspect direct
    // heading/static siblings near an already identified plan meter.
    static func officialScopeAndReset(_ element: AXUIElement, budget: Budget) -> (Bool, String?, String?) {
        var current = element
        var reset: String?
        var official = false
        var percentLabel: String?
        for _ in 0..<4 {
            guard !budget.exhausted, let parentValue = budget.value(current, kAXParentAttribute as String),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            let siblings = budget.children(parent)
            guard siblings.count <= 80 else { budget.exhausted = true; break }
            for sibling in siblings {
                guard !budget.exhausted else { break }
                let r = budget.role(sibling)
                if r == "AXHeading" {
                    let title = (budget.value(sibling, kAXTitleAttribute as String) as? String)
                        ?? (budget.value(sibling, kAXDescriptionAttribute as String) as? String) ?? ""
                    if ["Votre utilisation", "Your usage", "Usage", "Utilisation"].contains(title) { official = true }
                }
            }
            if let index = siblings.firstIndex(where: { CFEqual($0, current) }), index > 0 {
                for sibling in siblings[max(0, index - 2)..<index] where budget.role(sibling) == kAXStaticTextRole as String {
                    guard let text = budget.value(sibling, kAXValueAttribute as String) as? String, text.count <= 120 else { continue }
                    if text.hasPrefix("Réinitialisation") || text.hasPrefix("Resets ") { reset = reset ?? text }
                    if ["Limites d'utilisation du forfait", "Plan usage limits"].contains(text) { official = true }
                }
                if index + 1 < siblings.count, budget.role(siblings[index + 1]) == kAXStaticTextRole as String {
                    if let text = budget.value(siblings[index + 1], kAXValueAttribute as String) as? String,
                       text.count <= 32, text.contains("%") { percentLabel = percentLabel ?? text }
                }
            }
            current = parent
        }
        return (official, reset, percentLabel)
    }
    static func read(pid: pid_t) -> Result<ClaudeDesktopQuotaReport, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        let budget = Budget()
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let windows = budget.value(root, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let main = budget.value(root, kAXMainWindowAttribute as String)
        let window: AXUIElement
        if let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
            window = unsafeBitCast(main, to: AXUIElement.self)
        } else if windows.count == 1 { window = windows[0] }
        else { return .failure(.unreadable) }
        var queue = [window], offset = 0
        var meters: [ClaudeDesktopQuotaReport.Meter] = []
        while offset < queue.count, offset < 1600 {
            guard !budget.exhausted else { return .failure(.budget) }
            guard !budget.incomplete else { return .failure(.unreadable) }
            let element = queue[offset]; offset += 1
            let r = budget.role(element)
            if r == "AXWebArea", let urlValue = budget.value(element, kAXURLAttribute as String),
               let url = urlValue as? URL,
               !(url.host == "claude.ai" || (url.isFileURL && url.path.hasPrefix("/Applications/Claude.app/Contents/Resources/"))) {
                continue
            }
            if r == kAXProgressIndicatorRole as String || r == kAXLevelIndicatorRole as String,
               let label = quotaLabel(element, budget: budget) {
                let scope = officialScopeAndReset(element, budget: budget)
                if scope.0, let amount = budget.value(element, kAXValueAttribute as String) as? NSNumber {
                    let minimum = budget.value(element, kAXMinValueAttribute as String) as? NSNumber
                    let maximum = budget.value(element, kAXMaxValueAttribute as String) as? NSNumber
                    guard ![minimum, maximum].compactMap({ $0 }).contains(where: { CFGetTypeID($0) == CFBooleanGetTypeID() }) else {
                        return .failure(.unreadable)
                    }
                    let min = minimum?.doubleValue
                    let max = maximum?.doubleValue
                    let nativeLabel = (budget.value(element, kAXValueDescriptionAttribute as String) as? String) ?? scope.2
                    if let percent = ClaudeDesktopQuotaReport.percentage(value: amount.doubleValue, minimum: min, maximum: max,
                        nativeUsedLabel: nativeLabel, isBoolean: CFGetTypeID(amount) == CFBooleanGetTypeID()) {
                        meters.append(.init(label: label, usedPercent: percent, resetLabel: scope.1))
                    }
                }
            }
            if ![kAXStaticTextRole as String, kAXTextFieldRole as String, kAXTextAreaRole as String].contains(r) {
                let children = budget.children(element)
                guard queue.count + children.count <= 2400 else { return .failure(.budget) }
                queue.append(contentsOf: children)
            }
        }
        guard !budget.exhausted, offset == queue.count else { return .failure(.budget) }
        guard !budget.incomplete else { return .failure(.unreadable) }
        guard let report = try? ClaudeDesktopQuotaReport(meters: meters, observedAt: Date()) else {
            return .failure(offset >= 1600 ? .budget : .panel)
        }
        return .success(report)
    }
}

@MainActor final class ClaudeDesktopQuotaReader: ObservableObject {
    static let shared = ClaudeDesktopQuotaReader()
    @Published private(set) var state = "Claude connecté · lecture non activée"
    private var timer: Timer?
    private var generation = 0
    private var busy = false
    private let queue = DispatchQueue(label: "com.7agency.arqmeter.claude-desktop", qos: .utility)
    var selected: Bool { UserDefaults.standard.bool(forKey: ClaudeDesktopQuotaReport.selectedKey) }
    var authorized: Bool { AXIsProcessTrusted() }
    private func recordState(elapsed: Double? = nil, foregroundUnchanged: Bool? = nil) {
        struct Diagnostic: Encodable {
            let observedAt: Date
            let processID: Int32
            let bundleID: String?
            let accessibilityTrusted: Bool
            let state: String
            let elapsedSeconds: Double?
            let foregroundUnchanged: Bool?
        }
        let diagnostic = Diagnostic(observedAt: Date(), processID: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier, accessibilityTrusted: authorized, state: state,
            elapsedSeconds: elapsed, foregroundUnchanged: foregroundUnchanged)
        let url = ClaudeDesktopQuotaReport.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-desktop-reader-state.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(diagnostic).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* No diagnostics failure is converted into a quota. */ }
    }
    func startIfSelected() {
        guard selected else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }
    func select() {
        ClaudeCLIQuotaReader.shared.stop()
        ClaudeOfficialPage.shared.suspend()
        UserDefaults.standard.set(false, forKey: ClaudeWebQuotaReport.selectedKey)
        UserDefaults.standard.set(true, forKey: ClaudeDesktopQuotaReport.selectedKey)
        startIfSelected()
    }
    func stop() { generation += 1; timer?.invalidate(); timer = nil; busy = false }
    func requestAuthorization() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func refresh() {
        guard selected, !busy else { return }
        guard authorized else { state = ClaudeDesktopAXReader.Failure.permission.rawValue; recordState(); return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == ClaudeDesktopQuotaReport.sourceBundleID }) else {
            state = ClaudeDesktopAXReader.Failure.absent.rawValue; recordState(); return
        }
        busy = true
        let token = generation, pid = app.processIdentifier
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        queue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let result = ClaudeDesktopAXReader.read(pid: pid)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.selected else { return }
                self.busy = false
                switch result {
                case .failure(let error): self.state = error.rawValue
                case .success(let report):
                    do {
                        try report.save()
                        self.state = "Application Claude · observé à \(report.observedAt.formatted(.dateTime.hour().minute().second()))"
                    } catch { self.state = "Relevé Claude non enregistré" }
                }
                self.recordState(elapsed: elapsed,
                    foregroundUnchanged: before == NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
        }
    }
    static func probe() {
        // Read-only diagnostic in the installed application's own signing identity.
        guard AXIsProcessTrusted() else { print("Claude Desktop: accessibility=false; no UI or user cache read"); return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == ClaudeDesktopQuotaReport.sourceBundleID }) else {
            print("Claude Desktop: application absent"); return
        }
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let result = ClaudeDesktopAXReader.read(pid: app.processIdentifier)
        switch result {
        case .failure(let error): print("Claude Desktop: \(error.rawValue)")
        case .success(let report):
            if let data = try? JSONEncoder().encode(report), let text = String(data: data, encoding: .utf8) { print(text) }
        }
        print("Claude Desktop: foreground unchanged=\(before == NSWorkspace.shared.frontmostApplication?.bundleIdentifier); cache not written")
    }
}
