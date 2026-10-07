import Combine
import Foundation
import ArqmeterCore

enum SourceDisplay {
    static let order = SourceLayout.registryIDs

    static func name(_ id: String) -> String {
        switch id {
        case "codex": return "Codex"
        case "claude-code": return "Claude Code"
        case "gemini-cli": return "Gemini CLI"
        case "ollama": return "Ollama local"
        default: return id
        }
    }

    static func menuName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude"
        case "gemini-cli": return "Gemini"
        case "ollama": return "Ollama"
        default: return name(id)
        }
    }
}

/// Presentation preferences only. They never change ingestion or its persisted records.
final class SourceDisplayPreferences: ObservableObject {
    static let shared = SourceDisplayPreferences()
    @Published private(set) var layout: SourceLayout
    @Published private(set) var claudeQuotaMode: ClaudeMenuQuotaMode
    var visibleIDs: Set<String> { layout.visibleIDs }
    var primaryID: String { layout.primaryID }
    var orderedIDs: [String] { layout.orderedIDs }
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = SourceLayout.load(from: defaults)
        claudeQuotaMode = ClaudeMenuQuotaMode.load(from: defaults)
    }

    var orderedVisibleIDs: [String] { layout.orderedVisibleIDs }

    func setClaudeQuotaMode(_ mode: ClaudeMenuQuotaMode) {
        guard mode != claudeQuotaMode else { return }
        claudeQuotaMode = mode
        mode.save(to: defaults)
        onChange?()
    }

    func setVisible(_ id: String, _ visible: Bool) {
        update { $0.setVisible(id, visible) }
    }

    func setPrimary(_ id: String) {
        update { $0.setPrimary(id) }
    }

    func move(_ id: String, relativeTo target: String, after: Bool) {
        update { $0.move(id, relativeTo: target, after: after) }
    }

    func moveStep(_ id: String, direction: Int, visibleOnly: Bool = false) {
        update { $0.moveStep(id, direction: direction, visibleOnly: visibleOnly) }
    }

    private func update(_ change: (inout SourceLayout) -> Bool) {
        var next = layout
        guard change(&next) else { return }
        layout = next
        next.save(to: defaults)
        onChange?()
    }
}
