import XCTest
import Foundation
import Darwin
@testable import ArqmeterCore

final class ClaudeCLIReaderLeaseTests: XCTestCase {
    private struct Paths {
        let root: URL
        var lock: URL { root.appendingPathComponent("reader.lock") }
        var policy: URL { root.appendingPathComponent("reader-state.json") }
        var diagnostic: URL { root.appendingPathComponent("reader-diagnostic.json") }
        var quota: URL { root.appendingPathComponent("reader-quota.json") }
    }
    private struct Transport: Encodable { let childPID: Int32 = 0; let usageRequestsSent: Int = 1 }

    private func temporaryPaths() throws -> Paths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArqmeterReaderLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return Paths(root: root)
    }
    private func report(at date: Date) throws -> ClaudeCLIQuotaReport {
        try ClaudeCLIQuotaReport.parse(finalScreen: "Current session\n35% used\nResets in 2h", observedAt: date)
    }
    private func receipt(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func exited(_ process: Process, within seconds: Double) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        if !process.isRunning { process.waitUntilExit(); return true }
        return false
    }
    private func stopFixture(_ process: Process) {
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        XCTAssertTrue(exited(process, within: 3), "Exact fixture PID must be reaped")
    }
    private func boundedLine(from pipe: Pipe, within seconds: Double) -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var bytes = [UInt8]()
        while ProcessInfo.processInfo.systemUptime < deadline && bytes.count < 32 {
            var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN | POLLHUP), revents: 0)
            guard Darwin.poll(&descriptor, 1, 250) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 32)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk.prefix(count))
            if let newline = bytes.firstIndex(of: 10) {
                return String(data: Data(bytes[...newline]), encoding: .utf8)
            }
        }
        return nil
    }

    func testRealInterprocessExclusionAndReleaseAfterOwnerCrash() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var lease: ClaudeCLIReaderLease? = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        XCTAssertNil(try ClaudeCLIReaderLease.acquire(lockURL: paths.lock))

        // This subprocess uses the actual OS flock, not another Swift object.
        let contender = Process()
        contender.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        contender.arguments = ["-c", "import fcntl,os,sys\nfd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600)\ntry:\n fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n sys.exit(0)\nexcept BlockingIOError:\n sys.exit(17)", paths.lock.path]
        try contender.run()
        print("ArqmeterReaderFixture contenderPID=\(contender.processIdentifier)")
        defer { stopFixture(contender) }
        guard exited(contender, within: 5) else { XCTFail("Contender timed out"); return }
        XCTAssertEqual(contender.terminationStatus, 17)

        lease = nil
        let holder = Process()
        let pipe = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,os,sys,time\nfd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600)\nfcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('held',flush=True)\ntime.sleep(30)", paths.lock.path]
        holder.standardOutput = pipe
        try holder.run()
        print("ArqmeterReaderFixture holderPID=\(holder.processIdentifier)")
        pipe.fileHandleForWriting.closeFile()
        defer { stopFixture(holder); pipe.fileHandleForReading.closeFile() }
        guard let signal = boundedLine(from: pipe, within: 5) else { XCTFail("Holder handshake timed out"); return }
        XCTAssertEqual(signal, "held\n")
        XCTAssertNil(try ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        XCTAssertEqual(Darwin.kill(holder.processIdentifier, SIGKILL), 0)
        XCTAssertTrue(exited(holder, within: 3), "Crash fixture must be reaped before reacquisition")
        lease = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        XCTAssertNotNil(lease, "A crashed owner's lock is released by the OS")
        lease = nil
    }

    private func assertUnapplied(generation: Int, selected: Bool, cancelled: Bool, label: String) throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var prior = ClaudeCLIRefreshPolicy()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        prior.record(.limited, at: now)
        try prior.save(url: paths.policy)
        let oldPolicy = try Data(contentsOf: paths.policy)
        let oldQuota = try report(at: now)
        try oldQuota.save(url: paths.quota)
        let oldQuotaData = try Data(contentsOf: paths.quota)
        var lease: ClaudeCLIReaderLease? = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        let attempt = ClaudeCLIReaderLease.Attempt(instanceID: "instance-a", attemptID: label,
                                                   localStartedAt: now.addingTimeInterval(1), generation: 7)
        let accepted = attempt.shouldApply(currentGeneration: generation, selected: selected, cancelled: cancelled)
        XCTAssertFalse(accepted)
        let outcome = try lease!.complete(result: .success(try report(at: now.addingTimeInterval(2))),
                                          transport: Transport(), attempt: attempt, accepted: accepted,
                                          policyURL: paths.policy, diagnosticURL: paths.diagnostic,
                                          quotaURL: paths.quota, at: now.addingTimeInterval(3))
        XCTAssertEqual(outcome.disposition, .notAppliedCancelled)
        XCTAssertEqual(try Data(contentsOf: paths.policy), oldPolicy)
        XCTAssertEqual(try Data(contentsOf: paths.quota), oldQuotaData)
        let unchanged = try lease!.loadPolicy(from: paths.policy)
        XCTAssertEqual(unchanged.lastAttemptAt, prior.lastAttemptAt)
        XCTAssertEqual(unchanged.nextAttemptAt, prior.nextAttemptAt)
        XCTAssertNil(unchanged.attemptID)
        let diagnostic = try receipt(paths.diagnostic)
        XCTAssertEqual(diagnostic["instanceID"] as? String, "instance-a")
        XCTAssertEqual(diagnostic["attemptID"] as? String, label)
        XCTAssertEqual(diagnostic["application"] as? String, "notAppliedCancelled")
        XCTAssertEqual(diagnostic["serverTimestampStatus"] as? String, "unknown")
        XCTAssertTrue(diagnostic["serverObservedAt"] is NSNull)
        lease = nil
        XCTAssertNotNil(try ClaudeCLIReaderLease.acquire(lockURL: paths.lock), "Ownership is reacquired only after cleanup/release")
    }
    func testDifferentGenerationIsExplicitlyUnapplied() throws {
        try assertUnapplied(generation: 8, selected: true, cancelled: false, label: "generation-changed")
    }
    func testDeselectedSourceIsExplicitlyUnapplied() throws {
        try assertUnapplied(generation: 7, selected: false, cancelled: false, label: "source-deselected")
    }
    func testCancelledFlagIsExplicitlyUnapplied() throws {
        try assertUnapplied(generation: 7, selected: true, cancelled: true, label: "cancellation-flag")
    }

    func testParsedRateLimitsNullPreservesQuotaAndCorrelatesStateAndDiagnostic() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = try report(at: now)
        try quota.save(url: paths.quota)
        let oldQuota = try Data(contentsOf: paths.quota)
        let lease = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        let attempt = ClaudeCLIReaderLease.Attempt(instanceID: "instance-b", attemptID: "attempt-null",
                                                   localStartedAt: now, generation: 1)
        let evaluation = ClaudeUsageControl.evaluate(["rate_limits_available": true,
                                                      "subscription_type": "pro", "rate_limits": NSNull()],
                                                     observedAt: now, subscription: "pro")
        XCTAssertEqual(evaluation.diagnostic.limitsKind, .null)
        XCTAssertEqual(evaluation.diagnostic.rejection, .limitsNull)
        if case .failure(let failure) = evaluation.result { XCTAssertEqual(failure, .unavailable) }
        else { XCTFail("A null rate_limits payload must not yield a quota") }
        let outcome = try lease.complete(result: evaluation.result, transport: Transport(), attempt: attempt,
                                         accepted: attempt.shouldApply(currentGeneration: 1, selected: true, cancelled: false),
                                         policyURL: paths.policy, diagnosticURL: paths.diagnostic,
                                         quotaURL: paths.quota, at: now.addingTimeInterval(1))
        XCTAssertEqual(outcome.disposition, .applied)
        XCTAssertEqual(outcome.failure, .unavailable)
        XCTAssertEqual(try Data(contentsOf: paths.quota), oldQuota)
        let policy = try lease.loadPolicy(from: paths.policy)
        let diagnostic = try receipt(paths.diagnostic)
        XCTAssertEqual(policy.instanceID, diagnostic["instanceID"] as? String)
        XCTAssertEqual(policy.attemptID, diagnostic["attemptID"] as? String)
        XCTAssertEqual(policy.localCompletedAt, now.addingTimeInterval(1))
        XCTAssertEqual(policy.serverTimestampStatus, "unknown")
        XCTAssertEqual(diagnostic["application"] as? String, "applied")
        XCTAssertNotNil(diagnostic["localReceivedAt"])
        XCTAssertTrue(diagnostic["serverObservedAt"] is NSNull)
    }

    func testReacquireReloadsNewBackoffAndCompletionRejectsLaterPolicy() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var first: ClaudeCLIReaderLease? = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        XCTAssertTrue(try first!.loadPolicy(from: paths.policy).permits(at: now))
        first = nil
        var later = ClaudeCLIRefreshPolicy(); later.record(.limited, at: now)
        try later.save(url: paths.policy)
        let lease = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        XCTAssertFalse(try lease.loadPolicy(from: paths.policy).permits(at: now.addingTimeInterval(1)))

        let attempt = ClaudeCLIReaderLease.Attempt(instanceID: "instance-c", attemptID: "stale-attempt",
                                                   localStartedAt: now.addingTimeInterval(650))
        var newest = later; newest.record(.limited, at: now.addingTimeInterval(651))
        try newest.save(url: paths.policy) // Simulates a legacy writer during the exchange.
        let saved = try Data(contentsOf: paths.policy)
        let outcome = try lease.complete(result: .success(try report(at: now.addingTimeInterval(652))),
                                         transport: Transport(), attempt: attempt, accepted: true,
                                         policyURL: paths.policy, diagnosticURL: paths.diagnostic,
                                         quotaURL: paths.quota, at: now.addingTimeInterval(653))
        XCTAssertEqual(outcome.disposition, .notAppliedSuperseded)
        XCTAssertEqual(try Data(contentsOf: paths.policy), saved)
        XCTAssertNil(ClaudeCLIQuotaReport.read(url: paths.quota))
        XCTAssertEqual(try receipt(paths.diagnostic)["application"] as? String, "notAppliedSuperseded")
    }

    func testLegacyPolicyDecodesAndCorruptPolicyFailsClosed() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy: [String: Any] = ["lastAttemptAt": now.timeIntervalSinceReferenceDate,
                                     "nextAttemptAt": now.addingTimeInterval(600).timeIntervalSinceReferenceDate,
                                     "failure": "limited", "failures": 2]
        try JSONSerialization.data(withJSONObject: legacy).write(to: paths.policy, options: .atomic)
        let lease = try XCTUnwrap(ClaudeCLIReaderLease.acquire(lockURL: paths.lock))
        let restored = try lease.loadPolicy(from: paths.policy)
        XCTAssertEqual(restored.failure, .limited)
        XCTAssertNil(restored.attemptID)
        XCTAssertFalse(restored.permits(at: now.addingTimeInterval(1)))
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: paths.policy, options: .atomic)
        XCTAssertThrowsError(try lease.loadPolicy(from: paths.policy))
        let outcome = try lease.complete(result: .failure(.unavailable), transport: Transport(),
                                         attempt: .init(instanceID: "instance-d", attemptID: "corrupt-state", localStartedAt: now),
                                         accepted: true, policyURL: paths.policy, diagnosticURL: paths.diagnostic,
                                         quotaURL: paths.quota, at: now.addingTimeInterval(2))
        XCTAssertEqual(outcome.disposition, .notAppliedPolicyUnreadable)
        XCTAssertEqual(try Data(contentsOf: paths.policy), corrupt)
        XCTAssertNil(ClaudeCLIQuotaReport.read(url: paths.quota))
    }
}
