import Foundation

/// Display preferences only. Never changes ingestion, quotas or histories.
public struct SourceLayout: Equatable, Sendable {
    public static let registryIDs = ["codex", "claude-code", "gemini-cli", "ollama"]
    public private(set) var orderedIDs: [String]
    public private(set) var visibleIDs: Set<String>
    public private(set) var primaryID: String

    public init(order: [String]? = nil, visible: [String]? = nil, primary: String? = nil) {
        var seen = Set<String>()
        let normalizedOrder = ((order ?? []) + Self.registryIDs).filter {
            Self.registryIDs.contains($0) && seen.insert($0).inserted
        }
        let valid = Set(visible ?? Self.registryIDs).intersection(Self.registryIDs)
        let selected = valid.isEmpty ? Set(Self.registryIDs) : valid
        orderedIDs = normalizedOrder
        visibleIDs = selected
        primaryID = primary.flatMap { selected.contains($0) ? $0 : nil }
            ?? normalizedOrder.first(where: selected.contains)!
    }

    public var orderedVisibleIDs: [String] { orderedIDs.filter(visibleIDs.contains) }

    public mutating func setVisible(_ id: String, _ visible: Bool) -> Bool {
        guard Self.registryIDs.contains(id), visible != visibleIDs.contains(id) else { return false }
        guard visible || visibleIDs.count > 1 else { return false }
        if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
        if !visibleIDs.contains(primaryID) { primaryID = orderedVisibleIDs[0] }
        return true
    }

    public mutating func setPrimary(_ id: String) -> Bool {
        guard visibleIDs.contains(id), primaryID != id else { return false }
        primaryID = id
        return true
    }

    /// A drop above/below a card has a stable meaning in both directions.
    public mutating func move(_ id: String, relativeTo target: String, after: Bool) -> Bool {
        guard id != target, orderedIDs.contains(id), orderedIDs.contains(target) else { return false }
        let old = orderedIDs
        orderedIDs.removeAll { $0 == id }
        let index = orderedIDs.firstIndex(of: target)!
        orderedIDs.insert(id, at: index + (after ? 1 : 0))
        return orderedIDs != old
    }

    public mutating func moveStep(_ id: String, direction: Int, visibleOnly: Bool = false) -> Bool {
        let sequence = visibleOnly ? orderedVisibleIDs : orderedIDs
        guard direction == -1 || direction == 1, let index = sequence.firstIndex(of: id),
              sequence.indices.contains(index + direction) else { return false }
        return move(id, relativeTo: sequence[index + direction], after: direction > 0)
    }

    public static func load(from defaults: UserDefaults) -> Self {
        // Existing keys stay intact; only order is new. Missing/unknown IDs are
        // repaired without resetting a valid visibility or primary choice.
        Self(order: defaults.stringArray(forKey: "orderedSourceIDs"),
             visible: defaults.stringArray(forKey: "visibleSourceIDs"),
             primary: defaults.string(forKey: "primarySourceID"))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(orderedIDs, forKey: "orderedSourceIDs")
        defaults.set(orderedVisibleIDs, forKey: "visibleSourceIDs")
        defaults.set(primaryID, forKey: "primarySourceID")
    }
}
