import Foundation

public struct UsageSnapshot: Equatable, Sendable {
    public let remainingPercent: Int
    public let timestamp: Date
    public let resetsAt: Date

    public init(remainingPercent: Int, timestamp: Date, resetsAt: Date) {
        self.remainingPercent = remainingPercent
        self.timestamp = timestamp
        self.resetsAt = resetsAt
    }

    public func isValid(at date: Date = Date()) -> Bool {
        resetsAt > date
    }

    fileprivate func merged(with current: UsageSnapshot) -> UsageSnapshot {
        let resetJitterTolerance: TimeInterval = 5 * 60
        let resetDifference = resetsAt.timeIntervalSince(current.resetsAt)

        // Different reset timestamps denote separate reports from Codex.  A
        // session may be flushed late, so timestamp — not order on disk or
        // maximum historical consumption — decides which cycle is current.
        if abs(resetDifference) > resetJitterTolerance {
            return timestamp > current.timestamp ? self : current
        }

        let winner: UsageSnapshot
        if remainingPercent != current.remainingPercent {
            winner = remainingPercent < current.remainingPercent ? self : current
        } else {
            winner = timestamp > current.timestamp ? self : current
        }
        return UsageSnapshot(
            remainingPercent: winner.remainingPercent,
            timestamp: winner.timestamp,
            resetsAt: max(resetsAt, current.resetsAt)
        )
    }
}

public enum FileEventRecoveryAction: Int, Equatable, Sendable {
    case refresh
    case reconcile
    case bootstrap
    case recreateStream
}

public enum FileEventRecoveryPolicy {
    private static let mustScanSubdirectories: UInt32 = 0x00000001
    private static let userDropped: UInt32 = 0x00000002
    private static let kernelDropped: UInt32 = 0x00000004
    private static let eventIDsWrapped: UInt32 = 0x00000008
    private static let rootChanged: UInt32 = 0x00000020
    private static let itemRemoved: UInt32 = 0x00000200
    private static let itemRenamed: UInt32 = 0x00000800

    public static func action(for rawFlags: [UInt32]) -> FileEventRecoveryAction {
        var result = FileEventRecoveryAction.refresh
        for flags in rawFlags {
            if flags & (rootChanged | eventIDsWrapped) != 0 {
                return .recreateStream
            }
            if flags & (mustScanSubdirectories | userDropped | kernelDropped) != 0 {
                result = max(result, .bootstrap)
            } else if flags & (itemRemoved | itemRenamed) != 0 {
                result = max(result, .reconcile)
            }
        }
        return result
    }
}

public struct EventStreamRetryState: Equatable, Sendable {
    public private(set) var shouldRetryOnFallbackTick = false

    public init() {}

    public mutating func recordStartResult(succeeded: Bool) {
        shouldRetryOnFallbackTick = !succeeded
    }
}

public struct PollingCadenceState: Equatable, Sendable {
    public let reconciliationInterval: TimeInterval
    private var lastRefreshUptime: TimeInterval?

    public init(reconciliationInterval: TimeInterval = 12) {
        self.reconciliationInterval = reconciliationInterval
    }

    public mutating func recordRefresh(at uptime: TimeInterval) {
        lastRefreshUptime = uptime
    }

    public func shouldReconcile(at uptime: TimeInterval) -> Bool {
        guard let lastRefreshUptime else { return true }
        return uptime - lastRefreshUptime >= reconciliationInterval
    }
}

private func max(
    _ lhs: FileEventRecoveryAction,
    _ rhs: FileEventRecoveryAction
) -> FileEventRecoveryAction {
    lhs.rawValue >= rhs.rawValue ? lhs : rhs
}

public enum UsageParser {
    private struct Envelope: Decodable {
        let timestamp: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    private struct RateLimits: Decodable {
        let limitID: String?
        let primary: Window?
        let secondary: Window?

        enum CodingKeys: String, CodingKey {
            case limitID = "limit_id"
            case primary
            case secondary
        }
    }

    private struct Window: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }

    private static let decoder = JSONDecoder()
    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let timestampFormatter = ISO8601DateFormatter()

    public static func snapshot(from line: Data) -> UsageSnapshot? {
        guard
            let envelope = try? decoder.decode(Envelope.self, from: line),
            envelope.payload?.type == "token_count",
            let limits = envelope.payload?.rateLimits,
            limits.limitID == "codex",
            let weeklyWindow = [limits.primary, limits.secondary]
                .compactMap({ $0 })
                .first(where: { $0.windowMinutes == 10_080 }),
            let usedPercent = weeklyWindow.usedPercent,
            usedPercent.isFinite,
            let resetTimestamp = weeklyWindow.resetsAt,
            resetTimestamp.isFinite,
            let timestampText = envelope.timestamp,
            let timestamp = fractionalTimestampFormatter.date(from: timestampText)
                ?? timestampFormatter.date(from: timestampText)
        else {
            return nil
        }

        let remaining = Int((100 - usedPercent).rounded())
        return UsageSnapshot(
            remainingPercent: min(100, max(0, remaining)),
            timestamp: timestamp,
            resetsAt: Date(timeIntervalSince1970: resetTimestamp)
        )
    }
}

public enum OfficialUsageParser {
    /// Only a complete reply to our request ends the exchange. Initialization,
    /// notifications and partial JSON must not close stdin prematurely.
    public static func containsCompletedResponse(_ output: Data) -> Bool {
        output.split(separator: 0x0A).contains { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? Int, id == 2 else { return false }
            return object["result"] is [String: Any] || object["error"] is [String: Any]
        }
    }

    private struct Response: Decodable {
        let id: Int?
        let result: Result?
    }

    private struct Result: Decodable {
        let rateLimitsByLimitID: [String: RateLimit]?

        enum CodingKeys: String, CodingKey {
            case rateLimitsByLimitID = "rateLimitsByLimitId"
        }
    }

    private struct RateLimit: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    private struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?
    }

    public static func snapshot(from responseLine: Data) -> UsageSnapshot? {
        guard
            let response = try? JSONDecoder().decode(Response.self, from: responseLine),
            response.id == 2,
            let limit = response.result?.rateLimitsByLimitID?["codex"],
            let weeklyWindow = [limit.primary, limit.secondary]
                .compactMap({ $0 })
                .first(where: { $0.windowDurationMins == 10_080 }),
            let usedPercent = weeklyWindow.usedPercent,
            usedPercent.isFinite,
            let resetsAt = weeklyWindow.resetsAt,
            resetsAt.isFinite
        else {
            return nil
        }

        return UsageSnapshot(
            remainingPercent: min(100, max(0, Int((100 - usedPercent).rounded()))),
            timestamp: Date(),
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }
}

public struct DailyTokenUsage: Equatable, Sendable {
    public let day: String
    public let tokens: Int64

    public init(day: String, tokens: Int64) {
        self.day = day
        self.tokens = tokens
    }
}

public enum OfficialDailyUsageParser {
    private struct Response: Decodable {
        let id: Int?
        let result: Result?
    }

    private struct Result: Decodable {
        let dailyUsageBuckets: [Bucket]?
    }

    private struct Bucket: Decodable {
        let startDate: String
        let tokens: Int64
    }

    public static func dailyTokens(from responseLine: Data) -> [DailyTokenUsage]? {
        guard
            let response = try? JSONDecoder().decode(Response.self, from: responseLine),
            response.id == 2,
            let buckets = response.result?.dailyUsageBuckets
        else { return nil }
        return buckets.map { DailyTokenUsage(day: $0.startDate, tokens: max(0, $0.tokens)) }
    }
}

public final class UsageDirectoryScanner {
    private struct FileState: Equatable {
        let size: UInt64
        let modificationDate: Date
    }

    private struct FileEntry {
        let url: URL
        let state: FileState
    }

    private let sessionsDirectory: URL
    private let bootstrapTailBytes: UInt64
    private var fileStates: [URL: FileState] = [:]
    private var latest: UsageSnapshot?

    public init(sessionsDirectory: URL, bootstrapTailBytes: UInt64 = 4 * 1024 * 1024) {
        self.sessionsDirectory = sessionsDirectory
        self.bootstrapTailBytes = bootstrapTailBytes
    }

    public func bootstrap(now: Date = Date()) -> UsageSnapshot? {
        let entries = files()
        fileStates = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0.state) })
        latest = nil

        for entry in entries.sorted(by: { $0.state.modificationDate > $1.state.modificationDate }) {
            if let latest, entry.state.modificationDate < bootstrapScanBoundary(for: latest) {
                break
            }
            accept(UsageScanner.newestSnapshot(in: entry.url, maxBytes: bootstrapTailBytes))
        }
        return current(now: now)
    }

    private func bootstrapScanBoundary(for snapshot: UsageSnapshot) -> Date {
        let weeklyInterval = TimeInterval(10_080 * 60)
        let cycleStart = snapshot.resetsAt.addingTimeInterval(-weeklyInterval)
        if snapshot.timestamp >= cycleStart && snapshot.timestamp <= snapshot.resetsAt {
            return cycleStart
        }
        return snapshot.timestamp.addingTimeInterval(-weeklyInterval)
    }

    public func refresh(now: Date = Date()) -> UsageSnapshot? {
        let entries = files()
        let newStates = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0.state) })
        let changed = entries.filter { fileStates[$0.url] != $0.state }

        for entry in changed {
            if let previous = fileStates[entry.url], entry.state.size >= previous.size {
                let overlap: UInt64 = 64 * 1024
                let offset = previous.size > overlap ? previous.size - overlap : 0
                accept(UsageScanner.latestSnapshot(
                    in: entry.url,
                    fromOffset: offset,
                    maxBytes: bootstrapTailBytes
                ))
            } else {
                accept(UsageScanner.newestSnapshot(in: entry.url, maxBytes: bootstrapTailBytes))
            }
        }
        fileStates = newStates
        return current(now: now)
    }

    private func accept(_ candidate: UsageSnapshot?) {
        guard let candidate else { return }
        guard let current = latest else {
            latest = candidate
            return
        }

        latest = candidate.merged(with: current)
    }

    private func current(now: Date) -> UsageSnapshot? {
        guard let latest else { return nil }
        guard !latest.isValid(at: now) else { return latest }
        return UsageSnapshot(
            remainingPercent: 100,
            timestamp: latest.resetsAt,
            resetsAt: .distantFuture
        )
    }

    private func files() -> [FileEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var entries: [FileEntry] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]
            ) else {
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard
                fileURL.lastPathComponent.hasPrefix("rollout-"),
                fileURL.pathExtension == "jsonl",
                values.isRegularFile == true,
                let size = values.fileSize,
                let modificationDate = values.contentModificationDate
            else {
                continue
            }
            entries.append(FileEntry(
                url: fileURL,
                state: FileState(size: UInt64(size), modificationDate: modificationDate)
            ))
        }
        return entries
    }
}

public enum UsageScanner {
    public static func newestSnapshot(in fileURL: URL, maxBytes: UInt64) -> UsageSnapshot? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            return nil
        }
        let offset = size > maxBytes ? size - maxBytes : 0
        return latestSnapshot(in: fileURL, fromOffset: offset)
    }

    public static func latestSnapshot(
        in fileURL: URL,
        fromOffset: UInt64,
        maxBytes: UInt64? = nil
    ) -> UsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), fromOffset < end else {
            return nil
        }
        let boundedOffset: UInt64
        if let maxBytes, end - min(fromOffset, end) > maxBytes {
            boundedOffset = end - maxBytes
        } else {
            boundedOffset = fromOffset
        }
        do {
            try handle.seek(toOffset: boundedOffset)
            let data = try handle.readToEnd() ?? Data()
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteIndex = boundedOffset == 0 ? 0 : min(1, lines.count)
            var latest: UsageSnapshot?
            guard lines.count > firstCompleteIndex else { return nil }
            for index in firstCompleteIndex..<lines.count {
                guard let candidate = UsageParser.snapshot(from: Data(lines[index])) else { continue }
                latest = latest.map { candidate.merged(with: $0) } ?? candidate
            }
            return latest
        } catch {
            return nil
        }
    }
}
