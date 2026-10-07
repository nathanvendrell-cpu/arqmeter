import Foundation
import CoreFoundation

/// Public Claude Agent SDK 0.3.291 control protocol, without any `user` message.
/// No model question or behavioral transcript scan is requested by this meter.
public enum ClaudeUsageControl {
    public static func request(id: String, subtype: String) throws -> Data {
        guard ["initialize", "get_usage"].contains(subtype) else { throw ClaudeCLIQuotaReport.Failure.unsupported }
        var request: [String: Any] = ["subtype": subtype]
        if subtype == "get_usage" { request["skip_behaviors"] = true }
        var bytes = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id,
                                                               "request": request], options: [.sortedKeys])
        bytes.append(10)
        return bytes
    }

    public static let arguments = ["--print", "--output-format", "stream-json", "--verbose",
        "--input-format", "stream-json", "--no-session-persistence", "--safe-mode", "--tools", "",
        "--no-chrome", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--settings", "{\"disableAllHooks\":true}"]

    public static func response(_ data: Data, requestID: String,
                                onPublicError: ((ClaudeCLIQuotaReport.Failure) -> Void)? = nil) throws -> [String: Any]? {
        guard data.count <= 1024 * 1024,
              let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = frame["type"] as? String else { throw ClaudeCLIQuotaReport.Failure.unsupported }
        // No permission grant, hook execution or model output is legitimate here.
        if ["assistant", "user", "result", "control_request"].contains(type) { throw ClaudeCLIQuotaReport.Failure.unsupported }
        guard type == "control_response" else { return nil }
        guard let envelope = frame["response"] as? [String: Any],
              envelope["request_id"] as? String == requestID else { return nil }
        if envelope["subtype"] as? String == "error" {
            let category = failure(envelope["error"] as? String ?? "")
            onPublicError?(category) // Category only; never retain the public error's raw text.
            throw category
        }
        guard envelope["subtype"] as? String == "success",
              let payload = envelope["response"] as? [String: Any] else { throw ClaudeCLIQuotaReport.Failure.unsupported }
        return payload
    }

    /// Canonical public CLI auth status, not AccountInfo's unconstrained optional label.
    /// No identities or token/key fields are returned or stored.
    public static func subscription(fromPublicAuth data: Data) throws -> String {
        guard data.count <= 64 * 1024,
              let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeCLIQuotaReport.Failure.unsupported }
        guard auth["loggedIn"] as? Bool == true else { throw ClaudeCLIQuotaReport.Failure.authentication }
        guard auth["authMethod"] as? String == "claude.ai", auth["apiProvider"] as? String == "firstParty",
              let plan = auth["subscriptionType"] as? String,
              ["pro", "max", "team", "enterprise"].contains(plan.lowercased()) else { throw ClaudeCLIQuotaReport.Failure.unavailable }
        return plan.lowercased()
    }

    public static func subscription(fromInitialize payload: [String: Any], publicAuthSubscription: String? = nil) throws -> String {
        if let verified = publicAuthSubscription {
            guard ["pro", "max", "team", "enterprise"].contains(verified),
                  let account = payload["account"] as? [String: Any] else { throw ClaudeCLIQuotaReport.Failure.unavailable }
            // SDK AccountInfo.apiProvider? and subscriptionType? are optional.
            // A present conflicting provider is NOT silently accepted.
            if let provider = account["apiProvider"], !(provider is NSNull), provider as? String != "firstParty" {
                throw ClaudeCLIQuotaReport.Failure.unavailable
            }
            if let raw = account["subscriptionType"], !(raw is NSNull), !(raw is String) { throw ClaudeCLIQuotaReport.Failure.unsupported }
            if let raw = account["subscriptionType"] as? String,
               ["pro", "max", "team", "enterprise"].contains(raw.lowercased()), raw.lowercased() != verified {
                throw ClaudeCLIQuotaReport.Failure.unavailable
            }
            return verified
        }
        guard let account = payload["account"] as? [String: Any],
              account["apiProvider"] as? String == "firstParty",
              let plan = account["subscriptionType"] as? String,
              ["pro", "max", "team", "enterprise"].contains(plan.lowercased()) else {
            throw ClaudeCLIQuotaReport.Failure.unavailable
        }
        return plan.lowercased()
    }

    /// Fixed allowlist, not a scrubbed copy of the provider payload. No identities,
    /// session/model_usage/behaviors, quota values, reset strings or free text.
    public struct UsageDiagnostic: Codable, Equatable {
        public enum Kind: String, Codable { case absent, null, boolean, number, string, object, array, other }
        public enum Plan: String, Codable { case absent, null, canonical, otherString, invalidType }
        public enum Utilization: String, Codable { case absent, null, boolean, invalidType, nonFinite, outOfRange, valid }
        public enum Reset: String, Codable { case absent, null, invalidType, invalidDate, elapsed, future }
        public enum Rejection: String, Codable {
            case invalidVerifiedSubscription, availabilityAbsent, availabilityNull, availabilityFalse, availabilityInvalidType
            case planAbsent, planNull, planInvalidType, planConflict
            case limitsAbsent, limitsNull, limitsInvalidType, unexpectedPayload
            case liveMarkerAbsent, liveMarkerNull, liveMarkerInvalidType, noValidWindow
        }
        public struct Window: Codable, Equatable {
            public let kind: Kind
            public let utilization: Utilization?
            public let reset: Reset?
        }
        public let availabilityKind: Kind
        public let rateLimitsAvailable: Bool?
        public let planKind: Kind
        public let subscriptionType: Plan
        public let canonicalPlanMatches: Bool?
        public let limitsKind: Kind
        public let modelScopedKind: Kind?
        public let fiveHour: Window?
        public let sevenDay: Window?
        public fileprivate(set) var rejection: Rejection?
    }

    public struct UsageEvaluation {
        public let diagnostic: UsageDiagnostic
        public let result: Result<ClaudeCLIQuotaReport, ClaudeCLIQuotaReport.Failure>
    }

    private static func kind(_ value: Any?) -> UsageDiagnostic.Kind {
        guard let value else { return .absent }
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number
        }
        if value is String { return .string }
        if value is [String: Any] { return .object }
        if value is [Any] { return .array }
        return .other
    }

    private static func inspectWindow(_ value: Any?, observedAt: Date) -> (UsageDiagnostic.Window, ClaudeCLIQuotaReport.Window?) {
        let valueKind = kind(value)
        guard let raw = value as? [String: Any] else { return (.init(kind: valueKind, utilization: nil, reset: nil), nil) }
        let utilization: UsageDiagnostic.Utilization
        let number = raw["utilization"] as? NSNumber
        switch kind(raw["utilization"]) {
        case .absent: utilization = .absent
        case .null: utilization = .null
        case .boolean: utilization = .boolean
        case .number:
            if !number!.doubleValue.isFinite { utilization = .nonFinite }
            else if !(0...100).contains(number!.doubleValue) { utilization = .outOfRange }
            else { utilization = .valid }
        default: utilization = .invalidType
        }
        let reset: UsageDiagnostic.Reset
        var date: Date?
        switch kind(raw["resets_at"]) {
        case .absent: reset = .absent
        case .null: reset = .null
        case .string:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let text = raw["resets_at"] as! String
            date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            reset = date == nil ? .invalidDate : date! > observedAt ? .future : .elapsed
        default: reset = .invalidType
        }
        let diagnostic = UsageDiagnostic.Window(kind: valueKind, utilization: utilization, reset: reset)
        guard utilization == .valid, reset == .future, let number, let date else { return (diagnostic, nil) }
        return (diagnostic, .init(usedPercent: number.doubleValue, resetLabel: nil, expiresAt: date))
    }

    /// SDK 0.3.291 documents model_scoped as absent for cached answers; [] means
    /// the endpoint answered without per-model buckets. Without that evidence
    /// we reject the response instead of renewing an old quota's observation time.
    public static func report(_ payload: [String: Any], observedAt: Date, subscription: String) throws -> ClaudeCLIQuotaReport {
        try evaluate(payload, observedAt: observedAt, subscription: subscription).result.get()
    }

    /// One validation path for the report and its rejection reason; diagnostics
    /// cannot relax the live-marker, quota, subscription or freshness guards.
    public static func evaluate(_ payload: [String: Any], observedAt: Date, subscription: String) -> UsageEvaluation {
        let canonical = ["pro", "max", "team", "enterprise"]
        let availabilityKind = kind(payload["rate_limits_available"])
        let planKind = kind(payload["subscription_type"])
        let plan = payload["subscription_type"] as? String
        let planClass: UsageDiagnostic.Plan
        switch planKind {
        case .absent: planClass = .absent
        case .null: planClass = .null
        case .string: planClass = canonical.contains(plan!.lowercased()) ? .canonical : .otherString
        default: planClass = .invalidType
        }
        let limits = payload["rate_limits"] as? [String: Any]
        let session = limits.map { inspectWindow($0["five_hour"], observedAt: observedAt) }
        let weekly = limits.map { inspectWindow($0["seven_day"], observedAt: observedAt) }
        var diagnostic = UsageDiagnostic(availabilityKind: availabilityKind,
            rateLimitsAvailable: availabilityKind == .boolean ? payload["rate_limits_available"] as? Bool : nil,
            planKind: planKind, subscriptionType: planClass,
            canonicalPlanMatches: planClass == .canonical ? plan!.lowercased() == subscription : nil,
            limitsKind: kind(payload["rate_limits"]), modelScopedKind: limits.map { kind($0["model_scoped"]) },
            fiveHour: session?.0, sevenDay: weekly?.0, rejection: nil)
        func rejected(_ reason: UsageDiagnostic.Rejection, _ failure: ClaudeCLIQuotaReport.Failure) -> UsageEvaluation {
            diagnostic.rejection = reason
            return .init(diagnostic: diagnostic, result: .failure(failure))
        }
        guard canonical.contains(subscription) else { return rejected(.invalidVerifiedSubscription, .unavailable) }
        // Retain the original validation rule; shape recording is advisory only.
        guard payload["rate_limits_available"] as? Bool == true else {
            let reason: UsageDiagnostic.Rejection = availabilityKind == .absent ? .availabilityAbsent
                : availabilityKind == .null ? .availabilityNull
                : availabilityKind == .boolean ? .availabilityFalse : .availabilityInvalidType
            return rejected(reason, .unavailable)
        }
        guard let plan else {
            return rejected(planKind == .absent ? .planAbsent : planKind == .null ? .planNull : .planInvalidType, .unavailable)
        }
        if canonical.contains(plan.lowercased()), plan.lowercased() != subscription { return rejected(.planConflict, .unavailable) }
        guard let limits else {
            return rejected(diagnostic.limitsKind == .absent ? .limitsAbsent : diagnostic.limitsKind == .null ? .limitsNull : .limitsInvalidType, .unavailable)
        }
        guard payload["behaviors"] == nil || payload["behaviors"] is NSNull else { return rejected(.unexpectedPayload, .unsupported) }
        guard limits["model_scoped"] is [Any] else {
            let marker = kind(limits["model_scoped"])
            return rejected(marker == .absent ? .liveMarkerAbsent : marker == .null ? .liveMarkerNull : .liveMarkerInvalidType, .lastKnown)
        }
        guard session?.1 != nil || weekly?.1 != nil else { return rejected(.noValidWindow, .unsupported) }
        return .init(diagnostic: diagnostic, result: .success(.init(observedAt: observedAt, session: session?.1, weekly: weekly?.1,
                     transportKind: "official-get-usage-live", subscriptionType: subscription)))
    }

    public static func failure(_ publicError: String) -> ClaudeCLIQuotaReport.Failure {
        let value = publicError.lowercased()
        if value.contains("rate limit") || value.contains("rate_limit") || value.contains("429") { return .limited }
        if value.contains("auth") || value.contains("login") || value.contains("401") { return .authentication }
        if value.contains("timed out") || value.contains("timeout") { return .timeout }
        return .unsupported
    }
}
