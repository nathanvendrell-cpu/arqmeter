import Darwin
import Foundation
import ArqmeterCore

@MainActor
final class AntigravityQuotaReader {
    static let shared = AntigravityQuotaReader()

    private struct Endpoint: Sendable, Equatable {
        let pid: Int32
        let port: Int
        let csrfToken: String
    }

    private final class LoopbackDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // The credential belongs to this local server only.
            completionHandler(nil)
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Data, Int)?
        func save(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
            lock.lock(); defer { lock.unlock() }
            if error == nil, let data, let response = response as? HTTPURLResponse {
                value = (data, response.statusCode)
            }
        }
        func read() -> (Data, Int)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private let queue = DispatchQueue(label: "com.7agency.arqmeter.antigravity-quota", qos: .utility)
    private var cachedEndpoint: Endpoint?
    private var inFlight = false
    private var lastAttemptAt: Date?
    private var lastDiskWriteAt: Date?
    private var lastSavedPercent: Int?
    private(set) var currentReport: GeminiQuotaReport?

    private init() {
        currentReport = GeminiQuotaReport.read()
    }

    func latestReport() -> GeminiQuotaReport? {
        if let currentReport { return currentReport }
        let disk = GeminiQuotaReport.read()
        currentReport = disk
        return disk
    }

    func refreshIfNeeded(now: Date = Date(), onUpdate: (@MainActor (GeminiQuotaReport?) -> Void)? = nil) {
        guard !inFlight else { return }
        let interval: TimeInterval = cachedEndpoint != nil ? 4.0 : 12.0
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < interval { return }
        refresh(now: now, onUpdate: onUpdate)
    }

    func refresh(now: Date = Date(), onUpdate: (@MainActor (GeminiQuotaReport?) -> Void)? = nil) {
        guard !inFlight else { return }
        inFlight = true
        lastAttemptAt = now
        let endpoint = cachedEndpoint
        let previousReport = currentReport ?? GeminiQuotaReport.read()
        let lastWriteAt = lastDiskWriteAt
        let lastPercent = lastSavedPercent

        queue.async { [weak self] in
            let outcome = Self.poll(cached: endpoint, previous: previousReport, now: Date())
            var didWriteDisk = false
            if let report = outcome.report {
                let newPercent = report.snapshot?.primaryWindow.remainingPercent
                let shouldWrite = lastWriteAt == nil ||
                    Date().timeIntervalSince(lastWriteAt!) >= 30 ||
                    newPercent != lastPercent ||
                    (report.snapshot == nil && previousReport?.snapshot != nil)
                if shouldWrite {
                    do {
                        try GeminiQuotaReport.write(report)
                        didWriteDisk = true
                    } catch {
                        // Keep the valid in-memory reading; retry persistence
                        // on the next poll rather than claiming a failed save.
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.cachedEndpoint = outcome.endpoint
                if didWriteDisk {
                    self.lastDiskWriteAt = Date()
                    if let pct = outcome.report?.snapshot?.primaryWindow.remainingPercent {
                        if self.lastSavedPercent != pct, let observedAt = outcome.report?.snapshot?.observedAt {
                            HistoricalUsageService.shared.recordGeminiQuota(pct, at: observedAt)
                        }
                        self.lastSavedPercent = pct
                    }
                }
                let changed = self.currentReport?.snapshot?.primaryWindow.remainingPercent != outcome.report?.snapshot?.primaryWindow.remainingPercent ||
                    self.currentReport?.snapshot?.primaryWindow.resetsAt != outcome.report?.snapshot?.primaryWindow.resetsAt ||
                    (self.currentReport?.snapshot == nil) != (outcome.report?.snapshot == nil)
                self.currentReport = outcome.report
                if changed {
                    onUpdate?(outcome.report)
                }
            }
        }
    }

    private nonisolated static func poll(cached: Endpoint?, previous: GeminiQuotaReport?,
                                         now: Date) -> (report: GeminiQuotaReport?, endpoint: Endpoint?) {
        if let cached, kill(cached.pid, 0) == 0,
           let snapshot = fetchSnapshot(port: cached.port, csrfToken: cached.csrfToken, observedAt: now) {
            let report = GeminiQuotaReport(observedAt: now, snapshot: snapshot, lastKnown: snapshot, diagnostic: nil)
            return (report, cached)
        }
        for candidate in discoverCandidates().prefix(4) {
            for port in listeningPorts(for: candidate.pid).prefix(4) {
                if let snapshot = fetchSnapshot(port: port, csrfToken: candidate.csrfToken, observedAt: now) {
                    let endpoint = Endpoint(pid: candidate.pid, port: port, csrfToken: candidate.csrfToken)
                    let report = GeminiQuotaReport(observedAt: now, snapshot: snapshot, lastKnown: snapshot, diagnostic: nil)
                    return (report, endpoint)
                }
            }
        }
        let fallbackLastKnown = previous?.snapshot ?? previous?.lastKnown
        if let fallbackLastKnown {
            let report = GeminiQuotaReport(
                observedAt: previous?.observedAt,
                snapshot: nil,
                lastKnown: fallbackLastKnown,
                diagnostic: "Antigravity LanguageServer non actif · dernier relevé conservé"
            )
            return (report, nil)
        }
        return (previous, nil)
    }

    private nonisolated static func discoverCandidates() -> [(pid: Int32, csrfToken: String)] {
        guard let output = runCommand("/bin/ps", arguments: ["-ax", "-o", "pid=,command="]) else { return [] }
        var results: [(pid: Int32, csrfToken: String, priority: Int)] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("--csrf_token") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first, let pid = Int32(first), pid > 1 else { continue }
            // Never send this credential to another product's language server.
            let command = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
            guard command.hasPrefix("/Applications/Antigravity.app/Contents/Resources/bin/language_server ") else { continue }
            guard let tokenIdx = parts.firstIndex(of: "--csrf_token"), tokenIdx + 1 < parts.count else { continue }
            let token = parts[tokenIdx + 1]
            guard !token.isEmpty else { continue }
            let priority = (line.contains("Antigravity.app") || line.contains("antigravity")) ? 0 : 1
            results.append((pid: pid, csrfToken: token, priority: priority))
        }
        return results.sorted { $0.priority < $1.priority }.map { ($0.pid, $0.csrfToken) }
    }

    private nonisolated static func listeningPorts(for pid: Int32) -> [Int] {
        guard let output = runCommand("/usr/sbin/lsof", arguments: ["-Pan", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"]) else {
            return []
        }
        var ports: Set<Int> = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let range = line.range(of: "127.0.0.1:") else { continue }
            let after = line[range.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let port = Int(digits), port > 0 && port <= 65535 {
                ports.insert(port)
            }
        }
        // Try higher ports first: Antigravity binds HTTP on the port after HTTPS.
        return ports.sorted(by: >)
    }

    private nonisolated static func fetchSnapshot(port: Int, csrfToken: String, observedAt: Date) -> GeminiQuotaSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetCascadeModelConfigData") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data("{}".utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: configuration, delegate: LoopbackDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.save(data, response, error)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 1.8) == .timedOut {
            task.cancel()
            return nil
        }
        guard let (data, statusCode) = box.read(), statusCode == 200 else { return nil }
        return GeminiQuotaReport.parseLanguageServerConfig(data, observedAt: observedAt)
    }

    private nonisolated static func runCommand(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
