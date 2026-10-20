import Foundation
import CryptoKit

// Official sign_update, isolated ephemeral seeds, offline synthetic payload.
// No Keychain, production key, provider, HTTP, app installation or GUI.
enum FixtureFailure: Error { case invalidArguments, timeout, assertion }
guard CommandLine.arguments.count == 3 else { throw FixtureFailure.invalidArguments }
let tool = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let products = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let directory = products.appendingPathComponent("signature-fixture-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: directory) }

func run(_ args: [String]) throws -> (Int32, Data) {
    let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
    process.executableURL = tool; process.arguments = args
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe; process.standardError = pipe
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    if done.wait(timeout: .now() + 10) == .timedOut {
        process.terminate()
        if done.wait(timeout: .now() + 2) == .timedOut {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        throw FixtureFailure.timeout
    }
    return (process.terminationStatus, pipe.fileHandleForReading.readDataToEndOfFile())
}
func keyFile(_ name: String) throws -> URL {
    let seed = Curve25519.Signing.PrivateKey().rawRepresentation
    let file = directory.appendingPathComponent(name)
    try Data(seed.base64EncodedString().utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return file
}
func require(_ condition: Bool) throws { if !condition { throw FixtureFailure.assertion } }
let key = try keyFile("ephemeral-key"), wrong = try keyFile("other-ephemeral-key")
let payload = directory.appendingPathComponent("synthetic-archive-bytes.zip")
try Data("synthetic byte signature fixture, not an installable archive".utf8).write(to: payload)
let (signed, output) = try run(["--ed-key-file", key.path, "-p", payload.path])
try require(signed == 0)
let signature = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
try require(Data(base64Encoded: signature)?.count == 64)
try require(try run(["--ed-key-file", key.path, "--verify", payload.path, signature]).0 == 0)
try require(try run(["--ed-key-file", wrong.path, "--verify", payload.path, signature]).0 != 0)
try Data("tampered synthetic bytes".utf8).write(to: payload)
try require(try run(["--ed-key-file", key.path, "--verify", payload.path, signature]).0 != 0)
let feed = directory.appendingPathComponent("appcast.xml")
try Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Synthetic fixture</title></channel></rss>".utf8).write(to: feed)
try require(try run(["--ed-key-file", key.path, "-p", feed.path]).0 == 0)
try require(try run(["--ed-key-file", key.path, "--verify", feed.path]).0 == 0)
let text = try String(contentsOf: feed, encoding: .utf8)
try text.replacingOccurrences(of: "Synthetic fixture", with: "Tampered fixture").write(to: feed, atomically: true, encoding: .utf8)
try require(try run(["--ed-key-file", key.path, "--verify", feed.path]).0 != 0)
print("Official Sparkle Ed25519 fixtures passed: payload/feed accepted, tampering/wrong key refused; ephemeral keys removed on exit; no install.")
