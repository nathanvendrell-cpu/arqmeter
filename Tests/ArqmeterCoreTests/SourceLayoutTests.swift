import XCTest
@testable import ArqmeterCore

final class SourceLayoutTests: XCTestCase {
    func testMissingOrderKeepsLegacyChoicesAndPrimary() {
        let layout = SourceLayout(visible: ["claude-code", "ollama"], primary: "ollama")
        XCTAssertEqual(layout.orderedVisibleIDs, ["claude-code", "ollama"])
        XCTAssertEqual(layout.primaryID, "ollama")
    }
    func testSanitizeUnknownAndDuplicateIDsWithoutLosingHiddenOrder() {
        let layout = SourceLayout(order: ["ollama", "bad", "ollama", "claude-code"], visible: ["bad", "codex"])
        XCTAssertEqual(layout.orderedIDs, ["ollama", "claude-code", "codex", "gemini-cli"])
        XCTAssertEqual(layout.orderedVisibleIDs, ["codex"])
    }
    func testEmptyAndUnknownSelectionsRecoverSafely() {
        XCTAssertEqual(SourceLayout(visible: []).visibleIDs.count, 4)
        XCTAssertEqual(SourceLayout(visible: ["bad"], primary: "bad").primaryID, "codex")
    }
    func testMultipleSourcesHiddenAndShownKeepOrder() {
        var layout = SourceLayout(order: ["claude-code", "codex", "ollama", "gemini-cli"])
        XCTAssertTrue(layout.setVisible("codex", false))
        XCTAssertEqual(layout.orderedVisibleIDs, ["claude-code", "ollama", "gemini-cli"])
        XCTAssertTrue(layout.setVisible("codex", true))
        XCTAssertEqual(layout.orderedVisibleIDs, ["claude-code", "codex", "ollama", "gemini-cli"])
    }
    func testCannotHideLastOrSetHiddenPrimary() {
        var layout = SourceLayout(visible: ["claude-code"], primary: "claude-code")
        XCTAssertFalse(layout.setVisible("claude-code", false))
        XCTAssertFalse(layout.setPrimary("codex"))
        XCTAssertFalse(layout.setVisible("bad", true))
    }
    func testDropDownwardAndUpwardBeforeAndAfter() {
        var layout = SourceLayout()
        XCTAssertTrue(layout.move("codex", relativeTo: "gemini-cli", after: true))
        XCTAssertEqual(layout.orderedIDs, ["claude-code", "gemini-cli", "codex", "ollama"])
        XCTAssertTrue(layout.move("ollama", relativeTo: "claude-code", after: false))
        XCTAssertEqual(layout.orderedIDs, ["ollama", "claude-code", "gemini-cli", "codex"])
        XCTAssertFalse(layout.move("ollama", relativeTo: "ollama", after: true))
        XCTAssertFalse(layout.move("bad", relativeTo: "codex", after: true))
    }
    func testKeyboardBoundariesAndVisibleOnlyMovement() {
        var layout = SourceLayout(visible: ["codex", "ollama"])
        XCTAssertFalse(layout.moveStep("codex", direction: -1))
        XCTAssertFalse(layout.moveStep("ollama", direction: 1))
        XCTAssertTrue(layout.moveStep("ollama", direction: -1, visibleOnly: true))
        XCTAssertEqual(layout.orderedVisibleIDs, ["ollama", "codex"])
    }
    func testPrimaryFallbackUsesChosenOrder() {
        var layout = SourceLayout(order: ["ollama", "claude-code", "codex", "gemini-cli"], primary: "codex")
        XCTAssertTrue(layout.setVisible("codex", false))
        XCTAssertEqual(layout.primaryID, "ollama")
    }
    func testPersistenceAndLegacyMigrationLeaveOtherPreferencesUntouched() throws {
        let name = "com.7agency.arqmeter.tests.layout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["claude-code", "codex"], forKey: "visibleSourceIDs")
        defaults.set("claude-code", forKey: "primarySourceID")
        defaults.set("2025-12", forKey: "quotaMonth")
        defaults.set("detailed", forKey: "readingMode")
        var layout = SourceLayout.load(from: defaults)
        XCTAssertTrue(layout.move("claude-code", relativeTo: "codex", after: false))
        layout.save(to: defaults)
        let reloaded = SourceLayout.load(from: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertEqual(reloaded, layout)
        XCTAssertEqual(defaults.string(forKey: "quotaMonth"), "2025-12")
        XCTAssertEqual(defaults.string(forKey: "readingMode"), "detailed")
    }
}
