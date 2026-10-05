import Foundation

/// A session is identified by the harness that wrote it and its own stable ID.
/// Conflicting metadata stays unknown instead of borrowing the first event.
public struct UsageSession: Identifiable, Sendable {
    public let id: String
    public let harnessID: String
    public let sessionID: String
    public let providerID: String?
    public let modelID: String?
    public let projectPath: String?
    public let firstEvent: Date
    public let lastEvent: Date
    public let aggregate: UsageAggregate
    public let provenances: [String]

    public init?(records: [UnifiedUsageRecord]) {
        let aggregate = UsageAggregate(records: records)
        guard let first = aggregate.records.first, let last = aggregate.records.last else { return nil }
        guard aggregate.records.allSatisfy({ $0.harnessID == first.harnessID && $0.sessionID == first.sessionID }) else { return nil }
        self.id = "\(first.harnessID):\(first.sessionID)"
        self.harnessID = first.harnessID
        self.sessionID = first.sessionID
        self.providerID = Self.consistent(aggregate.records.map(\.providerID))
        self.modelID = Self.consistent(aggregate.records.map(\.modelID))
        self.projectPath = Self.consistent(aggregate.records.map(\.projectPath))
        self.firstEvent = first.timestamp
        self.lastEvent = last.timestamp
        self.aggregate = aggregate
        self.provenances = Array(Set(aggregate.records.map(\.provenance))).sorted()
    }

    private static func consistent(_ values: [String?]) -> String? {
        let nonempty = Set(values.compactMap { $0?.isEmpty == false ? $0 : nil })
        return nonempty.count == 1 ? nonempty.first : nil
    }
}

public struct UsageSessionFilter: Sendable {
    public var projectPath: String?
    public var harnessID: String?
    public var providerID: String?
    public var modelID: String?
    public var from: Date?
    public var to: Date?

    public init(projectPath: String? = nil, harnessID: String? = nil, providerID: String? = nil,
                modelID: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.projectPath = projectPath
        self.harnessID = harnessID
        self.providerID = providerID
        self.modelID = modelID
        self.from = from
        self.to = to
    }
}

public enum UsageSessionIndex {
    public static func sessions(_ records: [UnifiedUsageRecord], filter: UsageSessionFilter = .init()) -> [UsageSession] {
        let unique = UsageAggregate(records: records).records
        let groups = Dictionary(grouping: unique, by: { "\($0.harnessID):\($0.sessionID)" })
        return groups.values.compactMap(UsageSession.init).filter { session in
            (filter.projectPath == nil || session.projectPath == filter.projectPath) &&
            (filter.harnessID == nil || session.harnessID == filter.harnessID) &&
            (filter.providerID == nil || session.providerID == filter.providerID) &&
            (filter.modelID == nil || session.modelID == filter.modelID) &&
            (filter.from == nil || session.lastEvent >= filter.from!) &&
            (filter.to == nil || session.firstEvent < filter.to!)
        }.sorted { $0.lastEvent > $1.lastEvent }
    }
}

/// This is a descriptive observation, not an efficiency or quality verdict.
public struct SessionUsageComparison: Sendable {
    public let leftID: String
    public let rightID: String
    public let inputDifference: Int64?
    public let outputDifference: Int64?
    public let warnings: [String]

    public init(_ left: UsageSession, _ right: UsageSession) {
        leftID = left.id
        rightID = right.id
        var warnings: [String] = []
        if left.harnessID != right.harnessID { warnings.append("Harness différents : métriques et conventions potentiellement différentes.") }
        if left.modelID == nil || right.modelID == nil || left.modelID != right.modelID {
            warnings.append("Modèle inconnu ou différent ; efficacité non comparable.")
        }
        if left.projectPath == nil || right.projectPath == nil || left.projectPath != right.projectPath {
            warnings.append("Workspace inconnu ou différent.")
        }
        if !left.aggregate.inputTokens.complete || !right.aggregate.inputTokens.complete {
            warnings.append("Couverture des tokens d’entrée incomplète ou estimée.")
        }
        if !left.aggregate.outputTokens.complete || !right.aggregate.outputTokens.complete {
            warnings.append("Couverture des tokens de sortie incomplète ou estimée.")
        }
        inputDifference = Self.difference(left.aggregate.inputTokens, right.aggregate.inputTokens)
        outputDifference = Self.difference(left.aggregate.outputTokens, right.aggregate.outputTokens)
        warnings.append("La difficulté, la qualité et le travail préparatoire ne sont pas établis par ces journaux.")
        self.warnings = warnings
    }

    private static func difference(_ left: UsageMetricTotal, _ right: UsageMetricTotal) -> Int64? {
        guard left.complete, right.complete, let a = left.value, let b = right.value else { return nil }
        let (result, overflow) = b.subtractingReportingOverflow(a)
        return overflow ? nil : result
    }
}
