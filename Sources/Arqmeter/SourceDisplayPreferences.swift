import Combine
import Foundation

enum SourceDisplay {
    static let order = ["codex", "claude-code", "gemini-cli", "ollama"]

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
    @Published private(set) var visibleIDs: Set<String>
    @Published private(set) var primaryID: String
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let visibleKey = "visibleSourceIDs"
    private let primaryKey = "primarySourceID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: visibleKey)
        let valid = Set(saved ?? SourceDisplay.order).intersection(SourceDisplay.order)
        let selected = valid.isEmpty ? Set(SourceDisplay.order) : valid
        visibleIDs = selected
        let preferred = defaults.string(forKey: primaryKey) ?? "codex"
        primaryID = selected.contains(preferred) ? preferred : SourceDisplay.order.first(where: selected.contains) ?? "codex"
    }

    var orderedVisibleIDs: [String] { SourceDisplay.order.filter(visibleIDs.contains) }

    func setVisible(_ id: String, _ visible: Bool) {
        guard SourceDisplay.order.contains(id) else { return }
        var next = visibleIDs
        if visible { next.insert(id) } else { next.remove(id) }
        guard !next.isEmpty, next != visibleIDs else { return }
        visibleIDs = next
        defaults.set(SourceDisplay.order.filter(next.contains), forKey: visibleKey)
        if !next.contains(primaryID) {
            primaryID = SourceDisplay.order.first(where: next.contains) ?? "codex"
            defaults.set(primaryID, forKey: primaryKey)
        }
        onChange?()
    }

    func setPrimary(_ id: String) {
        guard visibleIDs.contains(id), primaryID != id else { return }
        primaryID = id
        defaults.set(id, forKey: primaryKey)
        onChange?()
    }
}
