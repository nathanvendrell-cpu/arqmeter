import AppKit
import ArqmeterCore
import ArqmeterPTY
import Darwin

private final class ClaudeProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Official interactive builtin only: no prompt argument, SDK print mode, private API, credentials or hooks.
private enum ClaudeCLICollector {
    struct Diagnostic: Codable {
        var childPID: Int32 = 0
        var builtinSent = false
        var builtinResultObserved = false
        var trustConfirmed = false
        var leaderReaped = false
        var processGroupEmpty = false
        var elapsedSeconds: Double = 0
        var signalResults: [Int32] = []
        var signalErrors: [Int32] = []
        var lastReapResult: Int32 = 0
        var publicScreenStates: [String] = []
        var stateTimeline: [String] = []
        var terminalDiagnostic = ""
        var promptUsageObserved = false
        var autocompleteObserved = false
        var usageTabsObserved = false
        var subscriptionHeaderObserved = false
    }
    static func read(executable: URL, directory: URL, cancellation: ClaudeProbeCancellation,
                     onDiagnostic: ((Diagnostic) -> Void)? = nil,
                     onFinalPanel: ((String) -> Void)? = nil,
                     setupOnly: Bool = false,
                     testArguments: [String]? = nil, deadlineSeconds: Double = 40) -> Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure> {
        let began = ProcessInfo.processInfo.systemUptime
        var diagnostic = Diagnostic()
        defer { diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - began; onDiagnostic?(diagnostic) }
        let arguments = testArguments ?? [executable.path, "--safe-mode", "--tools", "", "--no-chrome", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        // No API key/helper/third-party provider environment is imported from Arqmeter.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ClaudeCLIContext.environment(home: home, username: NSUserName())
        let argv = arguments.map { strdup($0) } + [nil]
        let env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var fd: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            arq_quota_spawn(executable.path, a.baseAddress, e.baseAddress, directory.path, &fd)
        }}
        guard pid > 0, fd >= 0 else { return .failure(.absent) }
        diagnostic.childPID = pid
        var status: Int32 = 0, reaped = false
        func pollExit() -> Bool {
            if !reaped { diagnostic.lastReapResult = arq_quota_reap(pid, &status); reaped = diagnostic.lastReapResult != 0 }
            return reaped
        }
        func send(_ text: String) { let bytes = Array(text.utf8); _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) } }
        func wait(_ seconds: Double) {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                let exited = pollExit()
                if exited && arq_quota_group_exists(pid) == 0 { break }
                if fd >= 0 {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if Darwin.poll(&descriptor, 1, 0) > 0 {
                        var discard = [UInt8](repeating: 0, count: 16384)
                        _ = discard.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    }
                }
                usleep(50_000)
            }
        }
        var cleaned = false
        func cleanup() {
            guard !cleaned else { return }; cleaned = true
            if !pollExit() {
                send("\u{1b}"); usleep(100_000); send("\u{3}"); usleep(150_000); send("\u{3}"); wait(1)
            }
            // Closing the master terminates the terminal and can unblock the CLI's final output.
            // Reaping/group checks happen AFTER this, not immediately before close.
            Darwin.close(fd); fd = -1
            if arq_quota_group_exists(pid) != 0 {
                let code = arq_quota_signal(pid, SIGTERM)
                diagnostic.signalResults.append(code); diagnostic.signalErrors.append(code < 0 ? errno : 0); wait(2)
            }
            if arq_quota_group_exists(pid) != 0 {
                let code = arq_quota_signal(pid, SIGKILL)
                diagnostic.signalResults.append(code); diagnostic.signalErrors.append(code < 0 ? errno : 0); wait(2)
            }
            _ = pollExit()
        }
        defer { cleanup() }
        func collect() -> Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure> {
        var display = ClaudeCLITerminal()
        defer {
            // Opt-in private diagnostic only, never saved by the background reader.
            let lines = display.screen.components(separatedBy: "\n")
            if let index = lines.firstIndex(where: { $0.contains("Settings") && $0.contains("Usage") && $0.contains("Stats") }) {
                onFinalPanel?(lines[index...].joined(separator: "\n"))
            }
        }
        var buffer = [UInt8](repeating: 0, count: 16384)
        let start = ProcessInfo.processInfo.systemUptime
        var typedAt: Double?, sentAt: Double?, stableReport: ClaudeCLIQuotaReport?, stableSince = start
        var inputReadySince: Double?
        var stableTrust: ClaudeCLITrustPrompt.State?, trustReadySince = start
        var trustSelected = false, trustConfirmed = false
        // This is a private, empty app-owned directory, never a user project or global trust bypass.
        let ownsEmptyDirectory = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
            && (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        while ProcessInfo.processInfo.systemUptime - start < deadlineSeconds, !pollExit() {
            if cancellation.cancelled { return .failure(.stopped) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&descriptor, 1, 100) > 0 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { display.push(Data(buffer.prefix(count))) }
            }
            guard display.valid else { return .failure(.unsupported) }
            let screen = display.screen, now = ProcessInfo.processInfo.systemUptime
            diagnostic.subscriptionHeaderObserved = diagnostic.subscriptionHeaderObserved || ClaudeCLIContext.hasSubscriptionHeader(screen)
            diagnostic.publicScreenStates = ["Claude Code", "Safe mode:", "Accessing workspace:", "Show session cost, plan usage", "Loading usage data", "Error: Usage endpoint is rate limited", "Current session", "Current week (all models)", "Sign in"].filter(screen.contains)
            diagnostic.terminalDiagnostic = display.diagnostic
            for item in diagnostic.publicScreenStates where !diagnostic.stateTimeline.contains(item) { diagnostic.stateTimeline.append(item) }
            let lines = screen.split(separator: "\n").map(String.init)
            let promptUsage = lines.contains { line in
                line.hasPrefix("❯") && line.dropFirst().trimmingCharacters(in: .whitespaces) == "/usage"
            }
            let autocomplete = screen.contains("/usage") && screen.contains("Show session cost, plan usage")
            diagnostic.promptUsageObserved = diagnostic.promptUsageObserved || promptUsage
            diagnostic.autocompleteObserved = diagnostic.autocompleteObserved || autocomplete
            diagnostic.usageTabsObserved = diagnostic.usageTabsObserved || (screen.contains("Settings") && screen.contains("Usage") && screen.contains("Stats"))
            if setupOnly {
                if screen.contains("Accessing workspace:"), screen.contains("Enter to confirm") {
                    let setupLines = screen.components(separatedBy: "\n")
                    if let index = setupLines.firstIndex(where: { $0.contains("Accessing workspace:") }) {
                        onFinalPanel?(setupLines[index...].joined(separator: "\n"))
                    }
                    return .failure(.trust) // Inspect only: never accept trust or send /usage.
                }
                continue
            }
            switch ClaudeCLITrustPrompt.assess(screen, expectedPath: directory.path, ownsEmptyDirectory: ownsEmptyDirectory) {
            case .absent: break
            case .incomplete: continue
            case .rejected: return .failure(.trust)
            case .ready(let selectedYes):
                let ready = ClaudeCLITrustPrompt.State.ready(selectedYes: selectedYes)
                if stableTrust != ready { stableTrust = ready; trustReadySince = now }
                if now - trustReadySince < 0.2 { continue }
                if !trustSelected, !selectedYes {
                    trustSelected = true; send("\u{1b}[B")
                } else if trustSelected, !trustConfirmed, selectedYes {
                    trustConfirmed = true; diagnostic.trustConfirmed = true; send("\r")
                }
            }
            if !setupOnly, typedAt == nil, ClaudeCLIContext.hasSubscriptionHeader(screen), screen.contains("Claude Code"), screen.contains("Safe mode:"),
               lines.contains(where: { $0.hasPrefix("❯") && $0.contains("Try ") }) {
                typedAt = now; send("/usage")
            }
            if let typedAt, sentAt == nil {
                if promptUsage && autocomplete {
                    if inputReadySince == nil { inputReadySince = now }
                    if now - typedAt >= 1, now - (inputReadySince ?? now) >= 0.5 {
                        sentAt = now; diagnostic.builtinSent = true; send("\r")
                    }
                } else { inputReadySince = nil }
            }
            if let sentAt, now - sentAt >= 1 {
                do {
                    let report = try ClaudeCLIQuotaReport.parse(finalScreen: screen, observedAt: Date())
                    // Compare only quota contents. The TUI wall-time/cursor can repaint continuously.
                    if !report.hasSameDisplayedValues(as: stableReport) {
                        stableReport = report; stableSince = now
                    }
                    if now - sentAt >= 4, now - stableSince >= 2 {
                        diagnostic.builtinResultObserved = true; return .success(report)
                    }
                }
                catch let error as ClaudeCLIQuotaReport.Failure where error == .limited || error == .lastKnown {
                    diagnostic.builtinResultObserved = true; return .failure(error)
                }
                catch { stableReport = nil; stableSince = now }
            }
            if sentAt == nil, screen.contains("Sign in") || screen.contains("Select login method") { return .failure(.authentication) }
        }
        return .failure(cancellation.cancelled ? .stopped : .timeout)
        }
        let result = collect()
        cleanup()
        diagnostic.leaderReaped = reaped; diagnostic.processGroupEmpty = arq_quota_group_exists(pid) == 0
        guard reaped, arq_quota_group_exists(pid) == 0 else { return .failure(.cleanup) }
        return result
    }
}

@MainActor final class ClaudeCLIQuotaReader: ObservableObject {
    static let shared = ClaudeCLIQuotaReader()
    @Published private(set) var state = "En attente du quota officiel Claude Code"
    private let queue = DispatchQueue(label: "com.7agency.arqmeter.claude-cli-quota", qos: .utility)
    private var timer: Timer?, busy = false, generation = 0
    private var cancellation: ClaudeProbeCancellation?
    private var policy: ClaudeCLIRefreshPolicy
    private let stateURL = ClaudeQuotaReport.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-cli-reader-state.json")
    var selected: Bool {
        SourceDisplayPreferences.shared.visibleIDs.contains("claude-code")
    }
    var nextAttemptAt: Date? { policy.nextAttemptAt }
    var compactState: String { busy ? "…" : policy.failure == .limited ? "!" : policy.failure == .authentication ? "?" : "—" }
    init() {
        let url = ClaudeQuotaReport.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-cli-reader-state.json")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
           let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(ClaudeCLIRefreshPolicy.self, from: data) { policy = stored }
        else { policy = .init() }
        state = policy.failure?.message ?? "En attente du quota officiel Claude Code"
    }
    func startIfSelected() {
        guard selected else { stop(); return }
        refresh()
    }
    func stop(waitForCleanup: Bool = false) {
        generation += 1; timer?.invalidate(); timer = nil; cancellation?.cancel(); cancellation = nil
        if waitForCleanup { queue.sync {} }
        busy = false
    }
    private func schedule(notBefore: Date? = nil) {
        guard selected, policy.failure != .cleanup else { return }
        let next = max(policy.nextAttemptAt ?? .distantPast, notBefore ?? .distantPast)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func refresh() {
        guard selected, !busy, policy.failure != .cleanup else { return }
        if let passive = ClaudeQuotaReport.read(), passive.current(at: Date()) != nil {
            state = "Claude Code · relevé reçu automatiquement à \(passive.receivedAt.formatted(.dateTime.hour().minute().second()))"
            // Do not clear a persisted server refusal or renew passive freshness.
            schedule(notBefore: passive.receivedAt.addingTimeInterval(180)); return
        }
        guard policy.permits(at: Date()) else { schedule(); return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { completed(.failure(.absent)); return }
        let directory = stateURL.deletingLastPathComponent().appendingPathComponent("claude-code-quota-reader", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { completed(.failure(.trust)); return }
        busy = true; timer?.invalidate(); timer = nil
        state = "Lecture du quota officiel Claude Code…"
        let token = generation, cancellation = ClaudeProbeCancellation(); self.cancellation = cancellation
        queue.async { [weak self] in
            var diagnostic = ClaudeUsageControlReader.Diagnostic()
            let result = ClaudeUsageControlReader.read(executable: executable, directory: directory, cancelled: { cancellation.cancelled },
                onDiagnostic: { diagnostic = $0 })
            // Operational metadata only: no terminal frame, path, transcript or identity.
            // Records control-exchange metadata and cleanup, never account identities.
            struct Receipt: Encodable { let observedAt: Date; let transport: ClaudeUsageControlReader.Diagnostic }
            let diagnosticURL = directory.deletingLastPathComponent().appendingPathComponent("claude-cli-last-reader-diagnostic.json")
            if let data = try? JSONEncoder().encode(Receipt(observedAt: Date(), transport: diagnostic)), data.count <= 4096 {
                try? data.write(to: diagnosticURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.selected else { return }
                self.busy = false; self.cancellation = nil; self.completed(result)
            }
        }
    }
    private func completed(_ result: Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure>) {
        switch result {
        case .success(let report):
            do { try report.save(); policy.record(nil, at: Date()); state = "Claude Code · observé à \(report.observedAt.formatted(.dateTime.hour().minute().second()))" }
            catch { policy.record(.unsupported, at: Date()); state = "Relevé Claude non enregistré" }
        case .failure(let error): policy.record(error, at: Date()); state = error.message
        }
        // A failure never overwrites the real quota report or renews its observation time.
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(policy).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch { state += " · état non enregistré" }
        schedule()
    }
    /// Same native transport as the normal app, read-only cache/preferences. No WebKit/UI collectors.
    nonisolated static func probe(directory: URL, diagnosticPanelURL: URL? = nil, setupOnly: Bool = false) {
        var diagnostic = ClaudeCLICollector.Diagnostic()
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        let result = ClaudeCLICollector.read(executable: executable, directory: directory,
            cancellation: ClaudeProbeCancellation(), onDiagnostic: { diagnostic = $0 }, onFinalPanel: { panel in
                guard let url = diagnosticPanelURL, panel.utf8.count <= 16384 else { return }
                let ownedPathMarker = "ARQMETER_OWNED_DIRECTORY_PATH"
                var filtered = panel.replacingOccurrences(of: directory.path, with: ownedPathMarker)
                for pattern in [#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                                #"/Users/[^\s]+"#,
                                #"(?i)(?:sk-ant-|sk-)[A-Za-z0-9_-]+"#,
                                #"(?i)(?:bearer\s+)[A-Za-z0-9._-]+"#,
                                #"[A-Za-z0-9_-]{48,}"#] {
                    filtered = filtered.replacingOccurrences(of: pattern, with: "[masqué]", options: .regularExpression)
                }
                filtered = filtered.replacingOccurrences(of: ownedPathMarker, with: directory.path)
                do {
                    try Data(filtered.utf8).write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch { fputs("Private panel diagnostic was not saved\n", stderr) }
            }, setupOnly: setupOnly, deadlineSeconds: setupOnly ? 8 : 40)
        struct Receipt: Encodable {
            let observedAt: Date
            let failure: ClaudeCLIQuotaReport.Failure?
            let report: ClaudeCLIQuotaReport?
            let transport: ClaudeCLICollector.Diagnostic
            let quotaCacheWritten = false
            let preferencesWritten = false
            let modelPromptSent = false
        }
        let report: ClaudeCLIQuotaReport?, failure: ClaudeCLIQuotaReport.Failure?
        switch result { case .success(let value): report = value; failure = nil; case .failure(let error): report = nil; failure = error }
        let receipt = Receipt(observedAt: Date(), failure: failure, report: report, transport: diagnostic)
        if let data = try? JSONEncoder().encode(receipt), let text = String(data: data, encoding: .utf8) { print(text) }
    }
    /// Process-lifecycle fixture only: no provider, no quota, no user cache/preferences.
    nonisolated static func cleanupProbe() {
        var diagnostic = ClaudeCLICollector.Diagnostic()
        let result = ClaudeCLICollector.read(executable: URL(fileURLWithPath: "/bin/sleep"),
            directory: URL(fileURLWithPath: "/private/tmp"), cancellation: ClaudeProbeCancellation(),
            onDiagnostic: { diagnostic = $0 }, testArguments: ["/bin/sleep", "20"], deadlineSeconds: 0.25)
        if case .failure(let error) = result { print("Lifecycle fixture result: \(error.rawValue)") }
        if let data = try? JSONEncoder().encode(diagnostic), let text = String(data: data, encoding: .utf8) { print(text) }
    }
    nonisolated static func replayErrorFrame(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count < 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frame = object["throughErrorFrame"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        var display = ClaudeCLITerminal(); display.push(Data(frame.utf8))
        let containsExactError = display.screen.contains("Error: Usage endpoint is rate limited")
        print("Offline actual-frame replay: containsExactError=\(containsExactError); \(display.diagnostic); no network/cache/preferences writes")
        do { _ = try ClaudeCLIQuotaReport.parse(finalScreen: display.screen, observedAt: Date()); print("Unexpected fresh quota") }
        catch let error as ClaudeCLIQuotaReport.Failure { print("Offline parsed failure: \(error.rawValue)") }
    }
}
