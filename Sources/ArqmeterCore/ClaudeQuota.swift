import Foundation

/// Official Claude Code statusLine fields only. Never reads credentials,
/// private endpoints, token counts, transcripts or third-party quota caches.
public struct ClaudeQuotaReport: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercentage: Double
        public let resetsAt: Date
        public var remainingPercent: Int { Int((100 - usedPercentage).rounded(.down)) }
    }
    public let receivedAt: Date
    public let cliVersion: String?
    public let fiveHour: Window?
    public let sevenDay: Window?

    public enum Period: String, CaseIterable, Sendable {
        case fiveHour = "5 heures"
        case sevenDay = "7 jours"
    }

    public static func decodeStatusLine(_ data: Data, receivedAt: Date) throws -> Self {
        struct Input: Decodable {
            struct Limits: Decodable {
                struct RawWindow: Decodable { let used_percentage: Double?; let resets_at: Double? }
                let five_hour: RawWindow?; let seven_day: RawWindow?
            }
            let version: String?; let rate_limits: Limits?
        }
        guard data.count <= 256 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let input = try JSONDecoder().decode(Input.self, from: data)
        func window(_ value: Input.Limits.RawWindow?) -> Window? {
            guard let used = value?.used_percentage, let reset = value?.resets_at,
                  used.isFinite, (0...100).contains(used), reset.isFinite, reset > 0 else { return nil }
            return Window(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        let version = input.version.flatMap { $0.count <= 32 && $0.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) ? $0 : nil }
        return Self(receivedAt: receivedAt, cliVersion: version,
                    fiveHour: window(input.rate_limits?.five_hour), sevenDay: window(input.rate_limits?.seven_day))
    }

    /// Weekly first; independently absent/expired windows never become 100%.
    public func current(at now: Date) -> (window: Window, period: String)? {
        if let window = currentWindow(.sevenDay, at: now) { return (window, Period.sevenDay.rawValue) }
        if let window = currentWindow(.fiveHour, at: now) { return (window, Period.fiveHour.rawValue) }
        return nil
    }

    /// Each real window can be shown independently, with exactly the same
    /// receipt/reset validation as the compact menu counter.
    public func currentWindow(_ period: Period, at now: Date) -> Window? {
        let age = now.timeIntervalSince(receivedAt)
        guard age >= -5, age < 180 else { return nil }
        guard let window = period == .fiveHour ? fiveHour : sevenDay,
              window.usedPercentage.isFinite, (0...100).contains(window.usedPercentage),
              window.resetsAt.timeIntervalSince1970.isFinite, window.resetsAt > now else { return nil }
        return window
    }

    public static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arqmeter/claude-quota.json")
    }
    public static func read(url: URL = cacheURL) -> Self? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public func save(url: URL = cacheURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
