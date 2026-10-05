import Foundation

/// Read-only presentation identity. Does not rewrite recorded workspaces or sessions.
public struct UsageProjectIdentity: Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let provenance: String
    public var identified: Bool { id != "unassigned" }
}

public final class UsageProjectResolver {
    private struct Project { let id: String; let name: String; let roots: [String] }
    private let projects: [String: Project]
    private let assignments: [String: String]
    private let canonical: (String) -> String
    private let repository: (String) -> String?
    private var pathCache: [String: UsageProjectIdentity] = [:]

    public init(registry: Data?, canonical: @escaping (String) -> String = UsageProjectResolver.canonicalPath,
                repository: @escaping (String) -> String? = UsageProjectResolver.repositoryRoot) {
        self.canonical = canonical
        self.repository = repository
        let object = registry.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var parsed: [String: Project] = [:]
        for (id, value) in object?["local-projects"] as? [String: [String: Any]] ?? [:] {
            guard let name = value["name"] as? String, !name.isEmpty,
                  let roots = value["rootPaths"] as? [String], !roots.isEmpty else { continue }
            parsed[id] = Project(id: id, name: name, roots: roots.filter { $0.hasPrefix("/") }.map(canonical))
        }
        projects = parsed
        var mapped: [String: String] = [:]
        let hosts = object?["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        for (session, value) in object?["thread-project-assignments"] as? [String: [String: Any]] ?? [:] {
            guard value["projectKind"] as? String == "local",
                  hosts[session] == nil || hosts[session] == "local",
                  let id = value["projectId"] as? String, parsed[id] != nil else { continue }
            mapped[session] = id
        }
        assignments = mapped
    }

    public func resolve(session: String, workspace: String) -> UsageProjectIdentity {
        let sessionID = Self.sessionID(session)
        if let id = assignments[sessionID], let project = projects[id] {
            return identity(project, provenance: "Projet affecté dans Codex")
        }
        guard workspace.hasPrefix("/") else { return Self.unassigned }
        if let cached = pathCache[workspace] { return cached }
        let path = canonical(workspace)
        let repo = repository(workspace).map(canonical)
        let matches = projects.values.compactMap { project -> (Project, Int)? in
            let length = project.roots.filter { root in
                Self.contains(root, path) || repo.map { Self.contains(root, $0) } == true
            }.map(\.count).max()
            return length.map { (project, $0) }
        }
        let deepest = matches.map(\.1).max()
        let best = matches.filter { $0.1 == deepest }
        let result: UsageProjectIdentity
        if best.count == 1 {
            result = identity(best[0].0, provenance: repo == path ? "Dossier du projet" : "Dossier / dépôt du projet")
        } else if best.count > 1 {
            // Shared roots such as BRAIN do not identify which saved project was used.
            result = Self.unassigned
        } else if let repo {
            result = UsageProjectIdentity(id: "repo:" + repo, name: URL(fileURLWithPath: repo).lastPathComponent,
                                          path: repo, provenance: "Racine Git commune aux worktrees")
        } else {
            result = Self.unassigned
        }
        pathCache[workspace] = result
        return result
    }

    private func identity(_ project: Project, provenance: String) -> UsageProjectIdentity {
        UsageProjectIdentity(id: "project:" + project.id, name: project.name,
                             path: project.roots.first ?? "", provenance: provenance)
    }

    public static let unassigned = UsageProjectIdentity(id: "unassigned", name: "Hors projet identifié",
                                                        path: "", provenance: "Affectation inconnue ou ambiguë")
    public static func sessionID(_ value: String) -> String {
        let stem = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        let suffix = String(stem.suffix(36))
        return UUID(uuidString: suffix) != nil ? suffix : stem
    }
    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
    }

    /// Reads Git pointer files only. No subprocess, network, or repository mutation.
    public static func repositoryRoot(_ path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<40 {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return directory.path }
                if let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") {
                    let pointer = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitdir = URL(fileURLWithPath: pointer, relativeTo: directory).standardizedFileURL
                    if let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) {
                        let commonDir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                                            relativeTo: gitdir).standardizedFileURL
                        if commonDir.lastPathComponent == ".git" { return commonDir.deletingLastPathComponent().path }
                    } else { return directory.path }
                }
                return nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }
}
