import Foundation
import XCTest

final class LaunchAgentConfigurationTests: XCTestCase {
    func testReleaseTemplateKeepsCrashRecoveryButNotNormalQuitRespawn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Resources/com.7agency.arqmeter.launchagent.plist")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(object["Label"] as? String, "com.7agency.arqmeter")
        XCTAssertEqual(object["RunAtLoad"] as? Bool, true)
        let keepAlive = try XCTUnwrap(object["KeepAlive"] as? [String: Any])
        XCTAssertEqual(keepAlive["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(keepAlive.count, 1, "Any additional OR condition could relaunch after a clean Quit")
        let arguments = try XCTUnwrap(object["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments, ["__ARQMETER_EXECUTABLE__"])
    }
}
