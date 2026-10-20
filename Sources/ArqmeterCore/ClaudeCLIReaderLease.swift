import Foundation
import Darwin

/// One autonomous reader owns the complete read/commit interval. The lock file
/// is never removed: BSD flock releases the open descriptor on process exit.
/// The descriptor is immutable; ownership moves from the worker to the main
/// completion after child cleanup, and the caller serializes all store methods.
public final class ClaudeCLIReaderLease: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// A contended lock is not an error. Other failures are fail-closed: no
    /// provider call or policy write should follow an unreadable lock path.
    public static func acquire(lockURL: URL) throws -> ClaudeCLIReaderLease? {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              information.st_uid == getuid() else {
            let code = errno == 0 ? EINVAL : errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return ClaudeCLIReaderLease(descriptor: descriptor)
    }

    /// Called only while holding the lease. A missing legacy file is empty;
    /// a corrupt or unreadable file is never silently replaced with defaults.
    public func loadPolicy(from url: URL) throws -> ClaudeCLIRefreshPolicy {
        var information = stat()
        if lstat(url.path, &information) != 0 {
            let code = errno
            if code == ENOENT { return .init() }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              information.st_uid == getuid(), information.st_size <= 4096 else {
            throw ReaderStoreError.invalidPolicy
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClaudeCLIRefreshPolicy.self, from: data)
    }

    public enum ReaderStoreError: Error { case invalidPolicy, oversizedDiagnostic }

    public struct Attempt: Sendable {
        public let instanceID: String
        public let attemptID: String
        public let localStartedAt: Date
        public let generation: Int
        public init(instanceID: String, attemptID: String = UUID().uuidString,
                    localStartedAt: Date = Date(), generation: Int = 0) {
            self.instanceID = instanceID
            self.attemptID = attemptID
            self.localStartedAt = localStartedAt
            self.generation = generation
        }
        public func shouldApply(currentGeneration: Int, selected: Bool, cancelled: Bool) -> Bool {
            generation == currentGeneration && selected && !cancelled
        }
    }

    public enum Disposition: String, Codable, Sendable {
        case applied, notAppliedCancelled, notAppliedSuperseded, notAppliedPolicyUnreadable
    }

    public struct Completion: Sendable {
        public let disposition: Disposition
        public let policy: ClaudeCLIRefreshPolicy?
        public let report: ClaudeCLIQuotaReport?
        public let failure: ClaudeCLIQuotaReport.Failure?
    }

    private struct DiagnosticReceipt<Transport: Encodable>: Encodable {
        let observedAt: Date // Legacy key: also a local receipt timestamp.
        let localReceivedAt: Date
        let serverObservedAt: Date? = nil
        let serverTimestampStatus = "unknown"
        let instanceID: String
        let attemptID: String
        let application: Disposition
        let transport: Transport

        enum CodingKeys: String, CodingKey {
            case observedAt, localReceivedAt, serverObservedAt, serverTimestampStatus
            case instanceID, attemptID, application, transport
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(observedAt, forKey: .observedAt)
            try container.encode(localReceivedAt, forKey: .localReceivedAt)
            try container.encodeNil(forKey: .serverObservedAt)
            try container.encode(serverTimestampStatus, forKey: .serverTimestampStatus)
            try container.encode(instanceID, forKey: .instanceID)
            try container.encode(attemptID, forKey: .attemptID)
            try container.encode(application, forKey: .application)
            try container.encode(transport, forKey: .transport)
        }
    }

    private func saveDiagnostic<Transport: Encodable>(_ transport: Transport, attempt: Attempt,
                                                      disposition: Disposition, at now: Date, to url: URL) throws {
        let receipt = DiagnosticReceipt(observedAt: now, localReceivedAt: now,
                                        instanceID: attempt.instanceID, attemptID: attempt.attemptID,
                                        application: disposition, transport: transport)
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= 4096 else { throw ReaderStoreError.oversizedDiagnostic }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Performs the real cache/policy/diagnostic writes, not a parser-only
    /// simulation. A cancelled or superseded result never changes the policy or
    /// quota. The caller must retain this lease through child cleanup and here.
    public func complete<Transport: Encodable>(result: Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure>,
                                               transport: Transport, attempt: Attempt, accepted: Bool,
                                               policyURL: URL, diagnosticURL: URL, quotaURL: URL,
                                               at now: Date = Date()) throws -> Completion {
        if !accepted {
            try saveDiagnostic(transport, attempt: attempt, disposition: .notAppliedCancelled, at: now, to: diagnosticURL)
            return Completion(disposition: .notAppliedCancelled, policy: nil, report: nil, failure: nil)
        }
        let current: ClaudeCLIRefreshPolicy
        do { current = try loadPolicy(from: policyURL) }
        catch {
            try saveDiagnostic(transport, attempt: attempt, disposition: .notAppliedPolicyUnreadable, at: now, to: diagnosticURL)
            return Completion(disposition: .notAppliedPolicyUnreadable, policy: nil, report: nil, failure: nil)
        }
        if let last = current.lastAttemptAt, last > attempt.localStartedAt {
            try saveDiagnostic(transport, attempt: attempt, disposition: .notAppliedSuperseded, at: now, to: diagnosticURL)
            return Completion(disposition: .notAppliedSuperseded, policy: current, report: nil, failure: nil)
        }

        var policy = current
        var retained: ClaudeCLIQuotaReport?
        var failure: ClaudeCLIQuotaReport.Failure?
        switch result {
        case .success(let report):
            do {
                let previous = ClaudeCLIQuotaReport.read(url: quotaURL)
                let candidate = report.preservingEarlierMatchingControlReceipt(previous)
                if candidate != previous { try candidate.save(url: quotaURL) }
                retained = candidate
            } catch { failure = .unsupported }
        case .failure(let error): failure = error
        }
        policy.record(failure, at: now, instanceID: attempt.instanceID, attemptID: attempt.attemptID)
        try policy.save(url: policyURL)
        try saveDiagnostic(transport, attempt: attempt, disposition: .applied, at: now, to: diagnosticURL)
        return Completion(disposition: .applied, policy: policy, report: retained, failure: failure)
    }
}
