import XCTest
@testable import ArqmeterCore

final class ProjectIdentityTests: XCTestCase {
    private let registry = Data(#"{"local-projects":{"a":{"name":"Projet Alpha","rootPaths":["/projects/project-alpha"]},"b":{"name":"Projet Beta","rootPaths":["/projects/project-beta"]}},"thread-project-assignments":{"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa":{"projectKind":"local","projectId":"a"}}}"#.utf8)
    private func resolver(_ data: Data? = nil) -> UsageProjectResolver {
        UsageProjectResolver(registry: data ?? registry, canonical: { $0 }, repository: {
            $0.hasPrefix("/worktrees/project-alpha") ? "/projects/project-alpha" : nil
        })
    }
    func testWorktreesAndSubfoldersBelongToWholeProject() {
        let value = resolver()
        let first = value.resolve(session: "one", workspace: "/projects/project-alpha/site/src")
        let second = value.resolve(session: "two", workspace: "/worktrees/project-alpha-qa/site")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.name, "Projet Alpha")
    }
    func testAssignmentOverridesGenericConversationDirectory() {
        let value = resolver().resolve(session: "rollout-2026-10-04-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl",
                                       workspace: "/Documents/Codex/dans")
        XCTAssertEqual(value.name, "Projet Alpha")
        XCTAssertEqual(value.provenance, "Projet affecté dans Codex")
    }
    func testUnknownWorkspaceNotInvented() {
        XCTAssertFalse(resolver().resolve(session: "x", workspace: "").identified)
        XCTAssertFalse(resolver().resolve(session: "x", workspace: "/Documents/Codex/dans").identified)
        XCTAssertFalse(resolver().resolve(session: "x", workspace: "/projects/project-alpha-copy").identified)
    }
    func testSameNamesDoNotMergeUnrelatedProjects() {
        let data = Data(#"{"local-projects":{"a":{"name":"Projet Alpha","rootPaths":["/a"]},"b":{"name":"Projet Alpha","rootPaths":["/b"]}}}"#.utf8)
        XCTAssertNotEqual(resolver(data).resolve(session: "one", workspace: "/a").id,
                          resolver(data).resolve(session: "two", workspace: "/b").id)
    }
    func testAmbiguousSharedRootsStayUnknown() {
        let data = Data(#"{"local-projects":{"a":{"name":"A","rootPaths":["/brain"]},"b":{"name":"B","rootPaths":["/brain"]}}}"#.utf8)
        XCTAssertFalse(resolver(data).resolve(session: "one", workspace: "/brain/task").identified)
    }
    func testNestedSavedProjectWinsAndCanonicalPathsAreUsed() {
        let data = Data(#"{"local-projects":{"a":{"name":"Parent","rootPaths":["/root"]},"b":{"name":"Child","rootPaths":["/root/child"]}}}"#.utf8)
        let value = UsageProjectResolver(registry: data, canonical: { $0.replacingOccurrences(of: "/alias", with: "/root") }, repository: { _ in nil })
        XCTAssertEqual(value.resolve(session: "one", workspace: "/alias/child/src").name, "Child")
    }
    func testRemoteAssignmentDoesNotOverrideLocalPath() {
        let data = Data(#"{"local-projects":{"a":{"name":"Remote","rootPaths":["/a"]}},"thread-project-assignments":{"s":{"projectKind":"local","projectId":"a"}},"thread-project-membership-host-ids":{"s":"remote"}}"#.utf8)
        XCTAssertFalse(resolver(data).resolve(session: "s", workspace: "/unknown").identified)
    }
    func testMalformedRegistryAndBareSessionIDs() {
        let value = UsageProjectResolver(registry: Data("broken".utf8), canonical: { $0 }, repository: { _ in nil })
        XCTAssertFalse(value.resolve(session: "x", workspace: "/anywhere").identified)
        XCTAssertEqual(UsageProjectResolver.sessionID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    }
    func testActualGitPointerFilesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Arqmeter-project-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("Project")
        let worktree = root.appendingPathComponent("Worktree")
        let gitdir = repo.appendingPathComponent(".git/worktrees/check")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "gitdir: \(gitdir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitdir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        XCTAssertEqual(UsageProjectResolver.canonicalPath(try XCTUnwrap(UsageProjectResolver.repositoryRoot(worktree.appendingPathComponent("src").path))),
                       UsageProjectResolver.canonicalPath(repo.path))
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        XCTAssertEqual(UsageProjectResolver.canonicalPath(alias.path), UsageProjectResolver.canonicalPath(repo.path))
    }
}
