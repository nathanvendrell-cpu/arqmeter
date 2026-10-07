import Foundation

/// Presentation choice only; never changes collection, quota maths or freshness.
public enum ClaudeMenuQuotaMode: String, CaseIterable, Sendable {
    case fiveHour = "five-hour"
    case sevenDay = "seven-day"
    case both

    public static let preferenceKey = "claudeMenuQuotaWindowMode"
    public var label: String {
        switch self {
        case .fiveHour: return "5 h"
        case .sevenDay: return "Semaine"
        case .both: return "Les deux"
        }
    }
    public var periods: [ClaudeQuotaReport.Period] {
        switch self {
        case .fiveHour: return [.fiveHour]
        case .sevenDay: return [.sevenDay]
        case .both: return [.fiveHour, .sevenDay]
        }
    }
    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .both
    }
    public func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.preferenceKey) }

    /// Fixed identities/order, not the most restrictive available window.
    /// A missing 5 h reading must never be replaced with the weekly percentage.
    public func text(readout: ClaudePlanQuotaReadout?) -> String? {
        let values = periods.map { readout?.window($0)?.remainingPercent }
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.map { $0.map { "\($0) %" } ?? "—" }.joined(separator: " - ")
    }
}

/// Presentation only: a last receipt is not a live quota. Strict currentWindow
/// validation is unchanged for calculations and collectors. Never renews a
/// receipt, merges account surfaces or carries a percentage across its reset.
public struct ClaudeMenuQuotaSnapshot: Sendable {
    public let readout: ClaudePlanQuotaReadout?
    public let isLastKnown: Bool

    public static func make(statusLine: ClaudeQuotaReport?, cli: ClaudeCLIQuotaReport?, at now: Date) -> Self {
        if let current = ClaudePlanQuotaReadout.makeCode(statusLine: statusLine, cli: cli, at: now) {
            return Self(readout: current, isLastKnown: false)
        }
        func valid(_ used: Double, observed: Date, reset: Date?, period: ClaudeQuotaReport.Period) -> Bool {
            let maximumAge: TimeInterval = period == .fiveHour ? 5 * 3600 : 7 * 86400
            let age = now.timeIntervalSince(observed)
            return age >= -5 && age < maximumAge && used.isFinite && (0...100).contains(used)
                && reset.map { $0.timeIntervalSince1970.isFinite && $0 > now } == true
        }
        var candidates: [ClaudePlanQuotaReadout] = []
        if let report = statusLine {
            func window(_ period: ClaudeQuotaReport.Period) -> ClaudePlanQuotaReadout.Window? {
                guard let value = period == .fiveHour ? report.fiveHour : report.sevenDay,
                      valid(value.usedPercentage, observed: report.receivedAt, reset: value.resetsAt, period: period) else { return nil }
                return .init(remainingPercent: value.remainingPercent, resetLabel: nil, resetsAt: value.resetsAt)
            }
            let session = window(.fiveHour), weekly = window(.sevenDay)
            if session != nil || weekly != nil {
                candidates.append(.init(observedAt: report.receivedAt,
                    provenance: "Dernier relevé reçu via Claude Code · fraîcheur serveur non fournie",
                    session: session, weekly: weekly))
            }
        }
        if let report = cli {
            func window(_ period: ClaudeQuotaReport.Period) -> ClaudePlanQuotaReadout.Window? {
                guard let value = period == .fiveHour ? report.session : report.weekly,
                      valid(value.usedPercent, observed: report.observedAt, reset: value.expiresAt, period: period) else { return nil }
                return .init(remainingPercent: value.remainingPercent, resetLabel: value.resetLabel, resetsAt: value.expiresAt)
            }
            let session = window(.fiveHour), weekly = window(.sevenDay)
            if session != nil || weekly != nil {
                candidates.append(.init(observedAt: report.observedAt, provenance: report.provenance,
                    session: session, weekly: weekly))
            }
        }
        let last = candidates.max { $0.observedAt < $1.observedAt }
        return Self(readout: last, isLastKnown: last != nil)
    }
}
