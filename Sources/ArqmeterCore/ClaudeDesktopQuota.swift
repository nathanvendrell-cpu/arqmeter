import Foundation

/// Only labeled plan meters read from Claude Desktop's official Usage panel.
/// Observation freshness does not establish the server's measurement time.
public struct ClaudeDesktopQuotaReport: Codable, Equatable, Sendable {
    public struct Meter: Sendable {
        public let label: String
        public let usedPercent: Double
        public let resetLabel: String?
        public init(label: String, usedPercent: Double, resetLabel: String?) {
            self.label = label; self.usedPercent = usedPercent; self.resetLabel = resetLabel
        }
    }
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercent: Double
        public let resetLabel: String?
        public var remainingPercent: Int {
            Int(ClaudeDesktopQuotaReport.canonicalPercent(100 - usedPercent).rounded(.down))
        }
    }
    public let observedAt: Date
    public let session: Window?
    public let weekly: Window?
    public static let selectedKey = "claudeQuotaSourceDesktopSelected"
    public static let sourceBundleID = "com.anthropic.claudefordesktop"

    // Fraction-to-percent multiplication can land one ULP above an integer.
    // Remove only machine-scale noise (two representable steps), not decimals.
    private static func canonicalPercent(_ value: Double) -> Double {
        let integer = value.rounded()
        return abs(value - integer) <= 2 * max(value.ulp, integer.ulp) ? integer : value
    }

    /// Numeric AXValue needs a proven unit, never assume fraction vs percent.
    /// An explicit native "percent used" label must agree with the bounded value.
    public static func percentage(value: Double?, minimum: Double?, maximum: Double?,
                                  nativeUsedLabel: String?, isBoolean: Bool = false) -> Double? {
        guard !isBoolean, let value, value.isFinite else { return nil }
        var textPercent: Double?
        if let text = nativeUsedLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           let regex = try? NSRegularExpression(pattern: #"^(\d+(?:[.,]\d+)?)\s*%\s*(?:utilis[ée]s?|used)$"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            textPercent = Double(text[range].replacingOccurrences(of: ",", with: "."))
        }
        let percent: Double
        if minimum == 0, maximum == 100 { percent = value }
        else if minimum == 0, maximum == 1 { percent = value * 100 }
        else {
            guard minimum == nil, maximum == nil, let textPercent, textPercent == value else { return nil }
            percent = textPercent
        }
        guard percent.isFinite, (0...100).contains(percent),
              textPercent.map({ abs($0 - percent) <= 2 * max($0.ulp, percent.ulp) }) ?? true else { return nil }
        return canonicalPercent(percent)
    }

    public init(meters: [Meter], observedAt: Date) throws {
        guard meters.count <= 16 else { throw CocoaError(.fileReadCorruptFile) }
        func window(_ labels: Set<String>) throws -> Window? {
            let matches = meters.filter { labels.contains($0.label) }
            guard !matches.isEmpty else { return nil }
            let values = try matches.map { meter -> Window in
                guard meter.usedPercent.isFinite, (0...100).contains(meter.usedPercent) else { throw CocoaError(.fileReadCorruptFile) }
                let reset = meter.resetLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard reset == nil || (reset!.count <= 120 && !reset!.contains("\n") && !reset!.contains("http")) else { throw CocoaError(.fileReadCorruptFile) }
                return Window(usedPercent: Self.canonicalPercent(meter.usedPercent), resetLabel: reset?.isEmpty == false ? reset : nil)
            }
            guard Set(values.map(\.usedPercent)).count == 1,
                  Set(values.compactMap(\.resetLabel)).count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
            return values.first
        }
        session = try window(["Session actuelle", "Limite de session", "Current session", "Session limit"])
        weekly = try window(["Cette semaine", "Hebdomadaire · tous les modèles", "This week", "All models", "Weekly · all models"])
        guard session != nil || weekly != nil else { throw CocoaError(.fileReadCorruptFile) }
        self.observedAt = observedAt
    }
    public func currentWindow(_ period: ClaudeQuotaReport.Period, at now: Date) -> Window? {
        let age = now.timeIntervalSince(observedAt)
        guard age >= -5, age < 180, let value = period == .fiveHour ? session : weekly,
              value.usedPercent.isFinite, (0...100).contains(value.usedPercent) else { return nil }
        return value
    }
    public static var cacheURL: URL {
        ClaudeQuotaReport.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-desktop-quota.json")
    }
    public static func read(url: URL = cacheURL) -> Self? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public static func readActive(defaults: UserDefaults = .standard) -> Self? {
        defaults.bool(forKey: selectedKey) ? read() : nil
    }
    public func save(url: URL = cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
