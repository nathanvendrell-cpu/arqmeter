import Foundation

/// Presence and filesystem access are distinct from account authentication or
/// healthy operation. No source is scanned while producing this inventory.
public struct SourceAvailability: Sendable {
    public let harnessID: String
    public let installed: Bool
    public let logRootExists: Bool
    public let logRootReadable: Bool
    public let logRootPath: String
}

public enum SourceAvailabilityProbe {
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SourceAvailability] {
        let manager = FileManager.default
        let installed: [String: Bool] = [
            "codex": UsageFiles.installed("codex") || manager.fileExists(atPath: "/Applications/Codex.app"),
            "claude-code": UsageFiles.installed("claude"),
            "gemini-cli": UsageFiles.installed("gemini") || manager.fileExists(atPath: "/Applications/Antigravity.app"),
            "ollama": UsageFiles.installed("ollama")
        ]
        return HistoricalSource.defaults(home: home).map { source in
            let brainPath = source.antigravityBrainRoot?.path
            let brainExists = brainPath.map { manager.fileExists(atPath: $0) } ?? false
            let brainReadable = brainPath.map { manager.isReadableFile(atPath: $0) } ?? false
            let rootExists = manager.fileExists(atPath: source.root.path) || brainExists
            let rootReadable = manager.isReadableFile(atPath: source.root.path) || brainReadable
            let displayPath = (brainReadable ? brainPath : nil) ?? source.root.path
            return SourceAvailability(harnessID: source.harnessID,
                installed: installed[source.harnessID] ?? false,
                logRootExists: rootExists,
                logRootReadable: rootReadable,
                logRootPath: displayPath)
        }
    }
}
