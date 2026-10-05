import Foundation

/// Values rendered on the official, authenticated usage page. Observation time
/// is not a server-provided measurement timestamp; reset text remains text unless
/// the page itself supplies an unambiguous datetime.
public struct ClaudeWebQuotaReport: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercent: Double
        public let resetLabel: String?
        public let resetsAt: Date?
        public var remainingPercent: Int { Int((100 - usedPercent).rounded(.down)) }
    }
    public let observedAt: Date
    public let pageLoadedAt: Date
    public let session: Window?
    public let weekly: Window?
    public static let enabledKey = "claudeOfficialPageMonitoringEnabled"
    public static let selectedKey = "claudeQuotaSourceOfficialPageSelected"

    public static func decode(_ data: Data, pageURL: URL, loadedAt: Date, observedAt: Date) throws -> Self {
        guard pageURL.scheme == "https", pageURL.host == "claude.ai",
              pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "settings/usage",
              data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        struct Input: Decodable {
            struct Item: Decodable { let usedPercent: Double; let resetLabel: String?; let resetISO: String? }
            let recognized: Bool
            let session: Item?
            let weekly: Item?
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.recognized else { throw CocoaError(.fileReadCorruptFile) }
        func window(_ item: Input.Item?) throws -> Window? {
            guard let item else { return nil }
            guard item.usedPercent.isFinite, (0...100).contains(item.usedPercent) else { throw CocoaError(.fileReadCorruptFile) }
            let label = item.resetLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label == nil || (label!.count <= 120 && !label!.contains("\n") && !label!.contains("http")) else { throw CocoaError(.fileReadCorruptFile) }
            let reset = item.resetISO.flatMap { ISO8601DateFormatter().date(from: $0) }
            if item.resetISO != nil && reset == nil { throw CocoaError(.fileReadCorruptFile) }
            return Window(usedPercent: item.usedPercent, resetLabel: label?.isEmpty == false ? label : nil, resetsAt: reset)
        }
        let session = try window(input.session), weekly = try window(input.weekly)
        guard session != nil || weekly != nil, observedAt >= loadedAt,
              observedAt.timeIntervalSince(loadedAt) <= 30 else { throw CocoaError(.fileReadCorruptFile) }
        return Self(observedAt: observedAt, pageLoadedAt: loadedAt, session: session, weekly: weekly)
    }

    public func currentWindow(_ period: ClaudeQuotaReport.Period, at now: Date) -> Window? {
        let age = now.timeIntervalSince(observedAt), loadAge = now.timeIntervalSince(pageLoadedAt)
        guard age >= -5, age < 180, loadAge >= -5, loadAge < 180,
              observedAt >= pageLoadedAt, observedAt.timeIntervalSince(pageLoadedAt) <= 30,
              let value = period == .fiveHour ? session : weekly,
              value.usedPercent.isFinite, (0...100).contains(value.usedPercent),
              value.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return value
    }

    public static var cacheURL: URL {
        ClaudeQuotaReport.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-official-page-quota.json")
    }
    public static func read(url: URL = cacheURL) -> Self? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public static func readActive(defaults: UserDefaults = .standard) -> Self? {
        defaults.bool(forKey: enabledKey) ? read() : nil
    }
    public func save(url: URL = cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One account surface per readout, never combine a window from a Desktop/web
/// account with one from a potentially different CLI account.
public struct ClaudePlanQuotaReadout: Sendable {
    public struct Window: Sendable {
        public let remainingPercent: Int
        public let resetLabel: String?
        public let resetsAt: Date?
    }
    public let observedAt: Date
    public let provenance: String
    public let session: Window?
    public let weekly: Window?
    public func window(_ period: ClaudeQuotaReport.Period) -> Window? { period == .fiveHour ? session : weekly }
    public var preferred: (window: Window, period: ClaudeQuotaReport.Period)? {
        let values: [(window: Window, period: ClaudeQuotaReport.Period)] =
            [(session, .fiveHour), (weekly, .sevenDay)].compactMap { value, period in
                value.map { ($0, period) }
            }
        return values.min { $0.window.remainingPercent < $1.window.remainingPercent }
    }
    public static func make(statusLine: ClaudeQuotaReport?, web: ClaudeWebQuotaReport?, webSelected: Bool = false, at now: Date) -> Self? {
        if webSelected {
            guard let web else { return nil }
            func convert(_ period: ClaudeQuotaReport.Period) -> Window? {
                web.currentWindow(period, at: now).map { Window(remainingPercent: $0.remainingPercent, resetLabel: $0.resetLabel, resetsAt: $0.resetsAt) }
            }
            let session = convert(.fiveHour), weekly = convert(.sevenDay)
            if session != nil || weekly != nil {
                return Self(observedAt: web.observedAt, provenance: "Page officielle · compte connecté dans Arqmeter", session: session, weekly: weekly)
            }
            return nil
        }
        if let statusLine {
            func convert(_ period: ClaudeQuotaReport.Period) -> Window? {
                statusLine.currentWindow(period, at: now).map { Window(remainingPercent: $0.remainingPercent, resetLabel: nil, resetsAt: $0.resetsAt) }
            }
            let session = convert(.fiveHour), weekly = convert(.sevenDay)
            if session != nil || weekly != nil {
                return Self(observedAt: statusLine.receivedAt, provenance: "Reçu via Claude Code · fraîcheur serveur non fournie", session: session, weekly: weekly)
            }
        }
        return nil
    }
}
