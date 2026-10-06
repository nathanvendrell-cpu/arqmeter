import XCTest
import ArqmeterPTY
import Darwin
@testable import ArqmeterCore

final class ClaudeCLIQuotaTests: XCTestCase {
    func testFirstLimitedAfterLocalTrustFailuresUsesItsOwnBackoffSequence() {
        var policy = ClaudeCLIRefreshPolicy()
        let now = Date(timeIntervalSince1970: 10000)
        for i in 0..<4 { policy.record(.trust, at: now.addingTimeInterval(Double(i) * 200)) }
        let first = now.addingTimeInterval(1000)
        policy.record(.limited, at: first)
        XCTAssertEqual(policy.failures, 1)
        XCTAssertEqual(policy.nextAttemptAt, first.addingTimeInterval(600))
        policy.record(.limited, at: first.addingTimeInterval(600))
        XCTAssertEqual(policy.failures, 2)
        XCTAssertEqual(policy.nextAttemptAt, first.addingTimeInterval(1800))
    }
    func testExistingLimitedDeadlineCannotBeShortenedByAnotherFailure() {
        var policy = ClaudeCLIRefreshPolicy()
        let now = Date(timeIntervalSince1970: 10000)
        policy.record(.limited, at: now)
        policy.record(.trust, at: now.addingTimeInterval(1))
        XCTAssertEqual(policy.nextAttemptAt, now.addingTimeInterval(600))
    }
    private let trustPath = "/private/fixture-arq-reader"
    private var trustScreen: String {
        "Accessing workspace:\n\n\(trustPath)\n\nQuick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not,\ntake a moment to review what's in this folder first.\n\nClaude Code'll be able to read, edit, and execute files here.\n\nSecurity guide\n\n❯ No, exit\nYes, I trust this folder\n\nEnter to confirm · Esc to cancel"
    }
    func testRealTrustFrameRemainsIncompleteUntilAllPTYChunksArrive() {
        var terminal = ClaudeCLITerminal()
        let parts = trustScreen.components(separatedBy: "\n")
        for line in parts.dropLast() {
            terminal.push(Data((line + "\r\n").utf8))
            XCTAssertEqual(ClaudeCLITrustPrompt.assess(terminal.screen, expectedPath: trustPath, ownsEmptyDirectory: true), .incomplete)
        }
        terminal.push(Data(parts.last!.utf8))
        XCTAssertEqual(ClaudeCLITrustPrompt.assess(terminal.screen, expectedPath: trustPath, ownsEmptyDirectory: true), .ready(selectedYes: false))
    }
    func testRealTrustChoicesRequireSeparateConfirmedSelection() {
        let yes = trustScreen.replacingOccurrences(of: "❯ No, exit\nYes, I trust this folder", with: "No, exit\n❯ Yes, I trust this folder")
        XCTAssertEqual(ClaudeCLITrustPrompt.assess(yes, expectedPath: trustPath, ownsEmptyDirectory: true), .ready(selectedYes: true))
    }
    func testTrustRejectsAnotherPathOrNonOwnedDirectory() {
        XCTAssertEqual(ClaudeCLITrustPrompt.assess(trustScreen, expectedPath: "/private/other", ownsEmptyDirectory: true), .rejected)
        XCTAssertEqual(ClaudeCLITrustPrompt.assess(trustScreen, expectedPath: trustPath, ownsEmptyDirectory: false), .rejected)
    }
    func testOfficialCLIEnvironmentRetainsUserIdentityWithoutProviderSecrets() {
        let environment = ClaudeCLIContext.environment(home: "/Users/fixture", username: "fixture")
        XCTAssertTrue(environment.contains("USER=fixture"))
        XCTAssertTrue(environment.contains("HOME=/Users/fixture"))
        XCTAssertEqual(Set(environment.map { $0.components(separatedBy: "=")[0] }),
                       Set(["HOME", "USER", "PATH", "TERM", "LANG", "DISABLE_AUTOUPDATER"]))
    }
    func testSubscriptionReadinessDoesNotMistakeSessionCostsForAuthentication() {
        XCTAssertTrue(ClaudeCLIContext.hasSubscriptionHeader("Unknown model · Claude Pro"))
        XCTAssertTrue(ClaudeCLIContext.hasSubscriptionHeader("Unknown model · Claude Max"))
        XCTAssertFalse(ClaudeCLIContext.hasSubscriptionHeader("Claude Code\nSession\nTotal cost: $0.0000\nUsage: 0 input, 0 output"))
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Synthetic parser fixtures, never user quota cache or acquisition evidence.
    let screen = "Current session\n██░░ 80% used\nResets in 2h 30m\nCurrent week (all models)\n██░░ 12% used\nResets Friday"
    func testDistinctPeriodsMostConstrainingAndUnknownResetDate() throws {
        let report = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now)
        let view = try XCTUnwrap(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil, cli: report, at: now))
        XCTAssertEqual(view.session?.remainingPercent, 20)
        XCTAssertEqual(view.weekly?.remainingPercent, 88)
        XCTAssertEqual(view.preferred?.period, .fiveHour)
        XCTAssertNil(view.weekly?.resetsAt)
    }
    func testRateLimitAndLastKnownNeverBecomeFresh() {
        for suffix in ["Error: Usage endpoint is rate limited. Please try again in a moment.", "Showing last-known usage (12 minutes ago)"] {
            XCTAssertThrowsError(try ClaudeCLIQuotaReport.parse(finalScreen: screen + "\n" + suffix, observedAt: now))
        }
    }
    func testVersion429DoesNotMeanRateLimit() throws {
        XCTAssertNotNil(try ClaudeCLIQuotaReport.parse(finalScreen: "Claude Code v2.1.429\n" + screen, observedAt: now).weekly)
    }
    func testAPIAndContextPercentagesAreNotPlanQuotas() {
        for value in ["Session\nTotal cost: $3\nContext 80% used", "Current session\nContext 80% used", "Current session\n-1% used", "Current session\n101% used"] {
            XCTAssertThrowsError(try ClaudeCLIQuotaReport.parse(finalScreen: value, observedAt: now))
        }
    }
    func testEmptyPartialAndUnknownModels() throws {
        XCTAssertThrowsError(try ClaudeCLIQuotaReport.parse(finalScreen: "", observedAt: now))
        let partial = try ClaudeCLIQuotaReport.parse(finalScreen: "Unknown model\nCurrent session\n100% used", observedAt: now)
        XCTAssertNil(partial.weekly)
        XCTAssertEqual(partial.currentWindow(.fiveHour, at: now)?.remainingPercent, 0)
    }
    func testFreshnessAndExpiredRelativeReset() throws {
        let report = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now)
        XCTAssertNil(report.currentWindow(.fiveHour, at: now.addingTimeInterval(180)))
        XCTAssertNil(report.currentWindow(.fiveHour, at: now.addingTimeInterval(-6)))
        let expired = try ClaudeCLIQuotaReport.parse(finalScreen: "Current session\n15% used\nResets in 0m", observedAt: now)
        XCTAssertNil(expired.currentWindow(.fiveHour, at: now))
    }
    func testStableDisplayIgnoresReceiptAndLocallyDerivedExpiry() throws {
        let first = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now)
        let later = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now.addingTimeInterval(2))
        XCTAssertNotEqual(first.session?.expiresAt, later.session?.expiresAt)
        XCTAssertTrue(later.hasSameDisplayedValues(as: first))
        let changed = try ClaudeCLIQuotaReport.parse(finalScreen: screen.replacingOccurrences(of: "80%", with: "81%"), observedAt: now)
        XCTAssertFalse(changed.hasSameDisplayedValues(as: first))
    }
    func testSelectedWebOrDesktopNeverSilentlyUsesCLIAccount() throws {
        let report = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now)
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil, webSelected: true, cli: report, at: now))
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil, desktopSelected: true, cli: report, at: now))
    }
    func testHistoryHasExplicitAgeAndCannotRenewObservation() throws {
        let report = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now)
        let later = now.addingTimeInterval(1200)
        XCTAssertNil(ClaudePlanQuotaReadout.make(statusLine: nil, web: nil, cli: report, at: later))
        XCTAssertTrue(try XCTUnwrap(ClaudePlanQuotaReadout.lastKnownDescription(statusLine: nil, web: nil, webSelected: false, desktop: nil, desktopSelected: false, cli: report, at: later)).contains("20 min · non actuel"))
        XCTAssertEqual(report.observedAt, now)
    }
    func testRetryPersistsAcrossRelaunchAndWake() throws {
        var policy = ClaudeCLIRefreshPolicy()
        policy.record(.limited, at: now)
        XCTAssertFalse(policy.permits(at: now.addingTimeInterval(599)))
        let reloaded = try JSONDecoder().decode(ClaudeCLIRefreshPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(reloaded.permits(at: now))
        XCTAssertTrue(reloaded.permits(at: now.addingTimeInterval(600)))
        policy.record(.limited, at: now.addingTimeInterval(600))
        XCTAssertEqual(policy.nextAttemptAt, now.addingTimeInterval(1800))
        policy.record(nil, at: now.addingTimeInterval(1800))
        XCTAssertEqual(policy.nextAttemptAt, now.addingTimeInterval(1920))
        XCTAssertEqual(policy.failures, 0)
    }
    func testFinalDisplayErasesHistoricalQuotaAndHandlesSplitANSI() throws {
        var terminal = ClaudeCLITerminal()
        terminal.push(Data(screen.utf8))
        terminal.push(Data("\u{1b}[2".utf8)); terminal.push(Data("J\u{1b}[HError: Usage endpoint is rate limited.".utf8))
        XCTAssertFalse(terminal.screen.contains("80%"))
        XCTAssertThrowsError(try ClaudeCLIQuotaReport.parse(finalScreen: terminal.screen, observedAt: now))
    }
    func testSelectionRenderedFromCursorUpdates() {
        var terminal = ClaudeCLITerminal()
        terminal.push(Data("\u{1b}[H❯ No, exit\r\n  Yes, I trust this folder".utf8))
        terminal.push(Data("\u{1b}[1;1H \u{1b}[2;1H❯".utf8))
        XCTAssertTrue(terminal.screen.contains("❯ Yes, I trust this folder"))
        XCTAssertFalse(terminal.screen.contains("❯ No, exit"))
    }
    func testGroupedAndChunkSplitCRLFHaveTheSameFinalDisplay() {
        var grouped = ClaudeCLITerminal(), split = ClaudeCLITerminal()
        grouped.push(Data("one\r\ntwo".utf8))
        split.push(Data("one\r".utf8)); split.push(Data("\ntwo".utf8))
        XCTAssertEqual(grouped.screen, split.screen)
        XCTAssertTrue(grouped.screen.hasPrefix("one\ntwo\n"))
    }
    func testInvalidPIDNeverSignalsAnyProcessGroup() {
        var status: Int32 = 0
        for pid: Int32 in [0, -1] {
            XCTAssertEqual(arq_quota_signal(pid, SIGTERM), -1)
            XCTAssertEqual(arq_quota_group_exists(pid), 0)
            XCTAssertEqual(arq_quota_reap(pid, &status), -1)
        }
    }
    func testCacheMetadataPrivateAndFailureCannotAlterQuota() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota.json")
        let report = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: now)
        try report.save(url: url)
        var policy = ClaudeCLIRefreshPolicy(); policy.record(.limited, at: now.addingTimeInterval(300))
        XCTAssertEqual(ClaudeCLIQuotaReport.read(url: url), report)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testNativePTYCleanupIncludesChildrenAfterLeaderExits() throws {
        let arguments: [String] = ["/bin/sh", "-c", "trap '' HUP; sleep 20 & exit 0"]
        let argv = arguments.map { $0.withCString { strdup($0) } } + [nil]
        let env = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var fd: Int32 = -1, status: Int32 = 0
        let pid = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in arq_quota_spawn("/bin/sh", a.baseAddress, e.baseAddress, "/private/tmp", &fd) }}
        guard pid > 0, fd >= 0 else { XCTFail("Task PTY spawn failed"); return }
        var reaped = false
        defer {
            if arq_quota_group_exists(pid) != 0 { _ = arq_quota_signal(pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(3)
            while !reaped && Date() < deadline { reaped = arq_quota_reap(pid, &status) != 0; usleep(20_000) }
            close(fd)
        }
        let deadline = Date().addingTimeInterval(3)
        while !reaped && Date() < deadline { reaped = arq_quota_reap(pid, &status) != 0; usleep(20_000) }
        XCTAssertTrue(reaped)
        XCTAssertNotEqual(arq_quota_group_exists(pid), 0, "Fixture child must survive the leader to exercise group cleanup")
        if arq_quota_group_exists(pid) != 0 { _ = arq_quota_signal(pid, SIGTERM) }
        let childrenDeadline = Date().addingTimeInterval(3)
        while arq_quota_group_exists(pid) != 0 && Date() < childrenDeadline { usleep(20_000) }
        XCTAssertEqual(arq_quota_group_exists(pid), 0)
    }
}
