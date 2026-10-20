import Foundation
import XCTest
import CryptoKit
@testable import ArqmeterCore

final class UpdaterPolicyTests: XCTestCase {
    private func info() -> [String: Any] {
        ["SUFeedURL": "https://updates.example.test/appcast.xml",
         "SUPublicEDKey": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUSendProfileInfo": false,
         "ARQUpdateDownloadHosts": ["github.com"]]
    }
    private func validate(_ configuration: UpdaterConfiguration, newer: Bool = true,
                          compatible: Bool = true, channel: String? = nil, prerelease: Bool = false,
                          url: String = "https://github.com/fixture/archive.zip", signed: Bool = true,
                          application: Bool = true) throws {
        try UpdaterPolicy.validate(configuration: configuration, versionIsNewer: newer, compatible: compatible,
            channel: channel, includePrerelease: prerelease, download: URL(string: url), signedFeed: signed,
            applicationArchive: application)
    }
    func testMissingConfigurationAndKeysFailClosed() throws {
        XCTAssertThrowsError(try UpdaterConfiguration(info: [:]))
        for key in ["SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUSendProfileInfo"] {
            var values = info(); values.removeValue(forKey: key)
            XCTAssertThrowsError(try UpdaterConfiguration(info: values), key)
        }
        for value in ["", "not-a-key", Data(repeating: 0, count: 32).base64EncodedString()] {
            var values = info(); values["SUPublicEDKey"] = value
            XCTAssertThrowsError(try UpdaterConfiguration(info: values))
        }
    }
    func testOnlyHTTPSWithoutCredentialsOrQueries() throws {
        for value in ["http://updates.example.test/a", "file:///tmp/feed", "https://u:p@example.test/a",
                      "https://example.test/a?token=private", "https://example.test/a#fragment", "https://example.test:444/a"] {
            var values = info(); values["SUFeedURL"] = value
            XCTAssertThrowsError(try UpdaterConfiguration(info: values), value)
        }
    }
    func testSignedStableApplicationAcceptedAndNoDowngrade() throws {
        let config = try UpdaterConfiguration(info: info())
        XCTAssertNoThrow(try validate(config))
        XCTAssertThrowsError(try validate(config, newer: false))
        XCTAssertThrowsError(try validate(config, signed: false))
        XCTAssertThrowsError(try validate(config, compatible: false))
        XCTAssertThrowsError(try validate(config, application: false))
    }
    func testPrereleaseIsExplicitAndUnknownChannelRejected() throws {
        let config = try UpdaterConfiguration(info: info())
        XCTAssertThrowsError(try validate(config, channel: "prerelease"))
        XCTAssertNoThrow(try validate(config, channel: "prerelease", prerelease: true))
        XCTAssertThrowsError(try validate(config, channel: "beta", prerelease: true))
    }
    func testDownloadHostAndTransportRestricted() throws {
        let config = try UpdaterConfiguration(info: info())
        for url in ["http://github.com/a.zip", "https://github.com.attacker.test/a.zip", "https://other.test/a.zip", "file:///tmp/a.zip"] {
            XCTAssertThrowsError(try validate(config, url: url))
        }
        for host in ["github.com/path", "github.com:444", "u:p@github.com", "github.com?key=x"] {
            var values = info(); values["ARQUpdateDownloadHosts"] = [host]
            XCTAssertThrowsError(try UpdaterConfiguration(info: values))
        }
    }
    func testEphemeralEd25519SignatureRejectsTamperingAndWrongKey() throws {
        // In-memory test keys only: no Keychain, disk private key or provider.
        let key = Curve25519.Signing.PrivateKey(), payload = Data("synthetic archive bytes".utf8)
        let signature = try key.signature(for: payload)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: payload))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: Data("tampered".utf8)))
        XCTAssertFalse(Curve25519.Signing.PrivateKey().publicKey.isValidSignature(signature, for: payload))
        // This is crypto fixture validation, not a native Sparkle install proof.
    }
    func testPrereleasePreferenceIsolatedAndPersisted() throws {
        let suite = "com.7agency.arqmeter.updater.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: UpdaterPolicy.prereleaseDefaultsKey))
        defaults.set(true, forKey: UpdaterPolicy.prereleaseDefaultsKey)
        XCTAssertTrue(try XCTUnwrap(UserDefaults(suiteName: suite)).bool(forKey: UpdaterPolicy.prereleaseDefaultsKey))
    }
}
