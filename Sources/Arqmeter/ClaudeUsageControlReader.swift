import Foundation
import ArqmeterCore
import ArqmeterPTY
import Darwin

/// One serial, bounded official control exchange. No stdin user/model messages.
enum ClaudeUsageControlReader {
    struct Diagnostic: Codable {
        var childPID: Int32 = 0
        var initializeSent = false
        var initializeConfirmed = false
        var usageRequestsSent = 0
        var skipBehaviors = true
        var subscription: String?
        var liveEndpointEvidence = false
        var modelMessagesReceived = 0
        var bytesReceived = 0
        var leaderReaped = false
        var processGroupEmpty = false
        var elapsedSeconds: Double = 0
        var exitStatus: Int32?
        var signals: [Int32] = []
        var publicAuth: AuthDiagnostic?
        var initializeProviderField: String?
        var initializePlanField: String?
        var usageReply: ClaudeUsageControl.UsageDiagnostic?
        var publicErrorCategory: ClaudeCLIQuotaReport.Failure?
        var publicErrorStage: String?
    }

    struct AuthDiagnostic: Codable {
        var childPID: Int32 = 0
        var leaderReaped = false
        var processGroupEmpty = false
        var subscription: String?
        var failure: ClaudeCLIQuotaReport.Failure?
    }

    /// Public `auth status`, same executable/home/user/env/cwd as the control
    /// reader. Bounded local status read, not login or a quota/model request.
    private static func publicAuth(executable: URL, directory: URL, cancelled: () -> Bool,
                                   onDiagnostic: (AuthDiagnostic) -> Void) -> Result<String, ClaudeCLIQuotaReport.Failure> {
        var diagnostic = AuthDiagnostic()
        defer { onDiagnostic(diagnostic) }
        let argv = [executable.path, "auth", "status", "--json"].map { strdup($0) } + [nil]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ClaudeCLIContext.environment(home: home, username: NSUserName()).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var input: Int32 = -1, output: Int32 = -1, status: Int32 = 0, reaped = false
        let pid = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            arq_quota_spawn_control(executable.path, a.baseAddress, e.baseAddress, directory.path, &input, &output)
        }}
        guard pid > 0 else { diagnostic.failure = .absent; return .failure(.absent) }
        diagnostic.childPID = pid
        close(input)
        var data = Data()
        let end = ProcessInfo.processInfo.systemUptime + 6
        func reap() {
            if !reaped {
                let result = arq_quota_reap(pid, &status)
                reaped = result == pid || (result < 0 && errno == ECHILD)
            }
        }
        func wait(_ seconds: Double) {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            repeat { reap(); if reaped && arq_quota_group_exists(pid) == 0 { return }; usleep(20_000) }
            while ProcessInfo.processInfo.systemUptime < until
        }
        var result: Result<String, ClaudeCLIQuotaReport.Failure> = .failure(.timeout)
        while !cancelled(), ProcessInfo.processInfo.systemUptime < end {
            var descriptor = pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0)
            if Darwin.poll(&descriptor, 1, 50) > 0 {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = chunk.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress, $0.count) }
                if count > 0 { data.append(contentsOf: chunk.prefix(count)) }
                if data.count > 64 * 1024 { result = .failure(.unsupported); break }
                if count == 0 {
                    do { result = .success(try ClaudeUsageControl.subscription(fromPublicAuth: data)) }
                    catch let error as ClaudeCLIQuotaReport.Failure { result = .failure(error) }
                    catch { result = .failure(.unsupported) }
                    break
                }
            }
        }
        if cancelled() { result = .failure(.stopped) }
        close(output); wait(0.25)
        for number in [SIGTERM, SIGKILL] where arq_quota_group_exists(pid) != 0 {
            _ = arq_quota_signal(pid, number); wait(2)
        }
        reap(); diagnostic.leaderReaped = reaped; diagnostic.processGroupEmpty = arq_quota_group_exists(pid) == 0
        guard reaped, diagnostic.processGroupEmpty else { diagnostic.failure = .cleanup; return .failure(.cleanup) }
        switch result {
        case .success(let plan): diagnostic.subscription = plan
        case .failure(let failure): diagnostic.failure = failure
        }
        return result
    }

    static func cleanupSelfTest() throws {
        var diagnostic = Diagnostic()
        let result = read(executable: URL(fileURLWithPath: "/bin/sleep"), directory: URL(fileURLWithPath: "/private/tmp"),
            cancelled: { false }, deadlineSeconds: 0.15, testArguments: ["20"], onDiagnostic: { diagnostic = $0 })
        guard case .failure(.timeout) = result, diagnostic.initializeSent,
              diagnostic.usageRequestsSent == 0, diagnostic.modelMessagesReceived == 0,
              diagnostic.leaderReaped, diagnostic.processGroupEmpty else {
            throw NSError(domain: "ClaudeUsageControlReader", code: 1)
        }
        print("Control lifecycle fixture only; no Claude/model/network/cache/preferences")
        if let text = String(data: try JSONEncoder().encode(diagnostic), encoding: .utf8) { print(text) }
        var authDiagnostic = AuthDiagnostic()
        let authResult = publicAuth(executable: URL(fileURLWithPath: "/usr/bin/true"), directory: URL(fileURLWithPath: "/private/tmp"),
            cancelled: { false }, onDiagnostic: { authDiagnostic = $0 })
        guard case .failure(.unsupported) = authResult,
              authDiagnostic.leaderReaped, authDiagnostic.processGroupEmpty else {
            throw NSError(domain: "ClaudeUsageControlReader", code: 2)
        }
        print("Public-auth EOF lifecycle fixture only; no Claude/model/network/cache/preferences")
        if let text = String(data: try JSONEncoder().encode(authDiagnostic), encoding: .utf8) { print(text) }
        // Exercise the normal diagnostic's Codable boundary and 4096-byte
        // persistence ceiling with synthetic metadata, never an actual request.
        diagnostic.publicAuth = authDiagnostic
        diagnostic.publicErrorCategory = .limited
        diagnostic.publicErrorStage = "get_usage"
        diagnostic.usageReply = ClaudeUsageControl.evaluate([
            "rate_limits_available": false, "subscription_type": "SECRET_LABEL",
            "rate_limits": ["five_hour": ["utilization": true, "resets_at": "SECRET_DATE"]],
            "session": "SECRET_SESSION", "account": ["token": "SECRET_TOKEN"]
        ], observedAt: Date(), subscription: "pro").diagnostic
        struct FixtureReceipt: Codable { let observedAt: Date; let transport: Diagnostic }
        let encoded = try JSONEncoder().encode(FixtureReceipt(observedAt: Date(), transport: diagnostic))
        let decoded = try JSONDecoder().decode(FixtureReceipt.self, from: encoded)
        guard encoded.count <= 4096, !String(decoding: encoded, as: UTF8.self).contains("SECRET"),
              decoded.transport.usageReply == diagnostic.usageReply,
              decoded.transport.usageReply?.rejection == .availabilityFalse else {
            throw NSError(domain: "ClaudeUsageControlReader", code: 3)
        }
        print("Allowlisted normal-receipt roundtrip/4096-byte/privacy fixture PASS; no real provider request")
    }

    static func read(executable: URL, directory: URL, cancelled: () -> Bool,
                     deadlineSeconds: Double = 25,
                     testArguments: [String]? = nil,
                     onDiagnostic: (Diagnostic) -> Void) -> Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure> {
        let began = ProcessInfo.processInfo.systemUptime
        var diagnostic = Diagnostic()
        defer { diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - began; onDiagnostic(diagnostic) }
        let authSubscription: String?
        if testArguments == nil {
            let auth = publicAuth(executable: executable, directory: directory, cancelled: cancelled,
                                  onDiagnostic: { diagnostic.publicAuth = $0 })
            switch auth { case .success(let plan): authSubscription = plan; case .failure(let failure): return .failure(failure) }
        } else { authSubscription = nil }
        let arguments = [executable.path] + (testArguments ?? ClaudeUsageControl.arguments)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let argv = arguments.map { strdup($0) } + [nil]
        let env = ClaudeCLIContext.environment(home: home, username: NSUserName()).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var input: Int32 = -1, output: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            arq_quota_spawn_control(executable.path, a.baseAddress, e.baseAddress, directory.path, &input, &output)
        }}
        guard pid > 0, input >= 0, output >= 0 else { return .failure(.absent) }
        diagnostic.childPID = pid
        var status: Int32 = 0, reaped = false
        func pollExit() {
            guard !reaped else { return }
            let result = arq_quota_reap(pid, &status)
            if result == pid || (result < 0 && errno == ECHILD) { reaped = true; diagnostic.exitStatus = status }
        }
        func waitForExit(_ seconds: Double) {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            repeat {
                pollExit()
                if reaped && arq_quota_group_exists(pid) == 0 { return }
                usleep(20_000)
            } while ProcessInfo.processInfo.systemUptime < end
        }
        var cleaned = false
        func cleanup() {
            guard !cleaned else { return }; cleaned = true
            if input >= 0 { close(input); input = -1 }
            if output >= 0 { close(output); output = -1 }
            waitForExit(0.5)
            if arq_quota_group_exists(pid) != 0 {
                diagnostic.signals.append(SIGTERM); _ = arq_quota_signal(pid, SIGTERM); waitForExit(2)
            }
            if arq_quota_group_exists(pid) != 0 {
                diagnostic.signals.append(SIGKILL); _ = arq_quota_signal(pid, SIGKILL); waitForExit(2)
            }
            pollExit()
            diagnostic.leaderReaped = reaped
            diagnostic.processGroupEmpty = arq_quota_group_exists(pid) == 0
        }
        defer { cleanup() }
        func send(_ data: Data) throws {
            let count = data.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
            guard count == data.count else { throw ClaudeCLIQuotaReport.Failure.stopped }
        }
        let initID = UUID().uuidString, usageID = UUID().uuidString
        var buffered = Data(), subscription: String?
        func collect() -> Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure> {
            do {
                try send(ClaudeUsageControl.request(id: initID, subtype: "initialize"))
                diagnostic.initializeSent = true
                while !cancelled(), ProcessInfo.processInfo.systemUptime - began < deadlineSeconds {
                    pollExit()
                    var descriptor = pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0)
                    if Darwin.poll(&descriptor, 1, 50) > 0 {
                        var chunk = [UInt8](repeating: 0, count: 16384)
                        let count = chunk.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress, $0.count) }
                        if count > 0 { buffered.append(contentsOf: chunk.prefix(count)); diagnostic.bytesReceived += count }
                        else if count == 0 { return .failure(.unsupported) }
                        guard buffered.count <= 1024 * 1024, diagnostic.bytesReceived <= 2 * 1024 * 1024 else { return .failure(.unsupported) }
                        while let newline = buffered.firstIndex(of: 10) {
                            let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
                            if line.isEmpty { continue }
                            if let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                               let type = frame["type"] as? String, ["assistant", "user", "result"].contains(type) {
                                diagnostic.modelMessagesReceived += 1
                            }
                            let expectedID = subscription == nil ? initID : usageID
                            guard let payload = try ClaudeUsageControl.response(line, requestID: expectedID, onPublicError: { category in
                                diagnostic.publicErrorCategory = category
                                diagnostic.publicErrorStage = subscription == nil ? "initialize" : "get_usage"
                            }) else { continue }
                            if subscription == nil {
                                if let account = payload["account"] as? [String: Any] {
                                    diagnostic.initializeProviderField = account["apiProvider"] == nil ? "absent" : account["apiProvider"] as? String == "firstParty" ? "firstParty" : "other"
                                    diagnostic.initializePlanField = account["subscriptionType"] == nil ? "absent" : account["subscriptionType"] is String ? "string-label" : "other-type"
                                }
                                subscription = try ClaudeUsageControl.subscription(fromInitialize: payload, publicAuthSubscription: authSubscription)
                                diagnostic.subscription = subscription; diagnostic.initializeConfirmed = true
                                try send(ClaudeUsageControl.request(id: usageID, subtype: "get_usage"))
                                diagnostic.usageRequestsSent = 1
                            } else {
                                let evaluation = ClaudeUsageControl.evaluate(payload, observedAt: Date(), subscription: subscription!)
                                diagnostic.usageReply = evaluation.diagnostic
                                let report = try evaluation.result.get()
                                diagnostic.liveEndpointEvidence = true
                                return .success(report)
                            }
                        }
                    }
                    if reaped { return .failure(.unsupported) }
                }
                return .failure(cancelled() ? .stopped : .timeout)
            } catch let failure as ClaudeCLIQuotaReport.Failure { return .failure(failure) }
            catch { return .failure(.unsupported) }
        }
        let result = collect(); cleanup()
        guard diagnostic.leaderReaped, diagnostic.processGroupEmpty else { return .failure(.cleanup) }
        return result
    }
}
