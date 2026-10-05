import Foundation

/// A value is never silently converted into a measured zero. The provenance of
/// an estimate belongs to the record that carries it.
public enum UsageMeasurement<Value: Equatable & Sendable & Codable>: Equatable, Sendable, Codable {
    case measured(Value)
    case estimated(Value)
    case unavailable

    public var value: Value? {
        switch self {
        case .measured(let value), .estimated(let value): return value
        case .unavailable: return nil
        }
    }
}

public enum ExecutionLocation: Equatable, Sendable, Codable {
    case local
    case cloud
    case unavailable
}

public struct UsageSourceKind: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let codexSessionLog = Self("codex.session-log")
    public static let codexOfficialAccount = Self("codex.official-account")
    public static let claudeCodeSessionLog = Self("claude-code.session-log")
    public static let geminiSessionLog = Self("gemini-cli.session-log")
    public static let ollamaServerLog = Self("ollama.server-log")
}

/// One source event, not an account-wide total. Other harness adapters can
/// produce the same shape without changing Codex's existing collectors.
public struct UnifiedUsageRecord: Equatable, Sendable, Codable {
    /// Stable within a source, even when its log is scanned again.
    public let eventID: String
    public let timestamp: Date
    public let projectPath: String?
    public let sessionID: String
    public let harnessID: String
    public let providerID: String?
    public let modelID: String?
    public let inputTokens: UsageMeasurement<Int64>
    public let outputTokens: UsageMeasurement<Int64>
    public let cachedInputTokens: UsageMeasurement<Int64>
    public let reasoningTokens: UsageMeasurement<Int64>
    public let costUSD: UsageMeasurement<Decimal>
    public let durationSeconds: UsageMeasurement<Double>
    public let executionLocation: ExecutionLocation
    public let sourceKind: UsageSourceKind
    /// Human-readable evidence boundary; never contains prompt or response text.
    public let provenance: String

    public init(eventID: String = "", timestamp: Date, projectPath: String?, sessionID: String,
                harnessID: String, providerID: String?, modelID: String?,
                inputTokens: UsageMeasurement<Int64>, outputTokens: UsageMeasurement<Int64>,
                cachedInputTokens: UsageMeasurement<Int64>, reasoningTokens: UsageMeasurement<Int64>,
                costUSD: UsageMeasurement<Decimal>, durationSeconds: UsageMeasurement<Double>,
                executionLocation: ExecutionLocation, sourceKind: UsageSourceKind,
                provenance: String = "") {
        self.eventID = eventID
        self.timestamp = timestamp
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.harnessID = harnessID
        self.providerID = providerID
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD
        self.durationSeconds = durationSeconds
        self.executionLocation = executionLocation
        self.sourceKind = sourceKind
        self.provenance = provenance
    }
}

public struct CodexLocalUsage: Equatable, Sendable {
    public let eventID: String?
    public let timestamp: Date
    public let projectPath: String?
    public let sessionID: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cachedInputTokens: Int64?
    public let providerID: String?
    public let modelID: String?
    public let reasoningTokens: Int64?

    public init(eventID: String? = nil, timestamp: Date, projectPath: String?, sessionID: String,
                inputTokens: Int64, outputTokens: Int64, cachedInputTokens: Int64?,
                providerID: String? = nil, modelID: String? = nil, reasoningTokens: Int64? = nil) {
        self.eventID = eventID
        self.timestamp = timestamp
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningTokens = reasoningTokens
    }
}

public protocol UsageNormalizer {
    associatedtype RawEvent: Sendable
    func normalize(_ raw: RawEvent) -> UnifiedUsageRecord?
}

public struct CodexUsageNormalizer: UsageNormalizer {
    public init() {}

    /// Model/provider are present only when adjacent session metadata proved them.
    /// Billing channel, execution location and cost remain unknown.
    public func normalize(_ raw: CodexLocalUsage) -> UnifiedUsageRecord? {
        guard !raw.sessionID.isEmpty,
              raw.inputTokens >= 0, raw.outputTokens >= 0,
              raw.inputTokens > 0 || raw.outputTokens > 0 else { return nil }
        if let cached = raw.cachedInputTokens,
           cached < 0 || cached > raw.inputTokens { return nil }
        if let reasoning = raw.reasoningTokens,
           reasoning < 0 || reasoning > raw.outputTokens { return nil }
        return UnifiedUsageRecord(
            eventID: raw.eventID ?? "codex:\(raw.sessionID):\(raw.timestamp.timeIntervalSince1970):\(raw.inputTokens):\(raw.outputTokens)",
            timestamp: raw.timestamp,
            projectPath: raw.projectPath?.isEmpty == true ? nil : raw.projectPath,
            sessionID: raw.sessionID,
            harnessID: "codex",
            providerID: raw.providerID,
            modelID: raw.modelID,
            inputTokens: .measured(raw.inputTokens),
            outputTokens: .measured(raw.outputTokens),
            cachedInputTokens: raw.cachedInputTokens.map(UsageMeasurement.measured) ?? .unavailable,
            reasoningTokens: raw.reasoningTokens.map(UsageMeasurement.measured) ?? .unavailable,
            costUSD: .unavailable,
            durationSeconds: .unavailable,
            executionLocation: .unavailable,
            sourceKind: .codexSessionLog,
            provenance: "Journal de session Codex · last_token_usage, session_meta et turn_context (ce Mac)"
        )
    }
}
