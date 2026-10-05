import Foundation
import SQLite3

/// An experiment is an annotation over existing usage events. It never stores
/// prompts, responses, copied token totals, inferred prices or quota values.
public struct TrialSessionReference: Hashable, Sendable, Codable {
    public let harnessID: String
    public let providerID: String?
    public let modelID: String?
    public let sessionID: String

    public init(harnessID: String, providerID: String?, modelID: String?, sessionID: String) {
        self.harnessID = harnessID
        self.providerID = providerID
        self.modelID = modelID
        self.sessionID = sessionID
    }
}

public enum TrialAssociatedRole: String, Sendable, Codable {
    case preparation
    case retry
    case localProcessing
}

public struct TrialAssociatedSession: Equatable, Sendable, Codable {
    public var role: TrialAssociatedRole
    public var session: TrialSessionReference

    public init(role: TrialAssociatedRole, session: TrialSessionReference) {
        self.role = role
        self.session = session
    }
}

public struct TrialSide: Equatable, Sendable, Codable {
    public var primary: TrialSessionReference
    /// Explicitly associated work only; no neighboring session is inferred.
    public var associated: [TrialAssociatedSession]

    public init(primary: TrialSessionReference, associated: [TrialAssociatedSession] = []) {
        self.primary = primary
        self.associated = associated
    }
}

public enum TrialEvidenceStatus: String, Sendable, Codable {
    case notAssessed
    case supported
    case notSupported
}

public enum TrialCheckOutcome: String, Sendable, Codable {
    case passed
    case failed
    case inconclusive
}

public struct TrialValidationCheck: Equatable, Sendable, Codable {
    public var criterion: String
    public var outcome: TrialCheckOutcome
    /// Short user-supplied evidence reference or summary, not a transcript.
    public var evidence: String

    public init(criterion: String, outcome: TrialCheckOutcome, evidence: String = "") {
        self.criterion = criterion
        self.outcome = outcome
        self.evidence = evidence
    }
}

public struct TrialValidation: Equatable, Sendable, Codable {
    /// These are user assertions, not ARQMETER's independent verification.
    public var quality: TrialEvidenceStatus
    public var workEquivalence: TrialEvidenceStatus
    public var checks: [TrialValidationCheck]

    public init(quality: TrialEvidenceStatus = .notAssessed,
                workEquivalence: TrialEvidenceStatus = .notAssessed,
                checks: [TrialValidationCheck] = []) {
        self.quality = quality
        self.workEquivalence = workEquivalence
        self.checks = checks
    }
}

public struct ManualTrial: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var recommendationID: String?
    public var before: TrialSide
    public var after: TrialSide?
    /// Brief descriptions only. Full task prompts are not part of this model.
    public var testedChange: String
    public var workDescription: String
    public var successCriteria: String
    public var validation: TrialValidation

    public init(id: UUID = UUID(), createdAt: Date = Date(), recommendationID: String? = nil,
                before: TrialSide, after: TrialSide? = nil, testedChange: String,
                workDescription: String, successCriteria: String,
                validation: TrialValidation = TrialValidation()) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.recommendationID = recommendationID
        self.before = before
        self.after = after
        self.testedChange = testedChange
        self.workDescription = workDescription
        self.successCriteria = successCriteria
        self.validation = validation
    }
}

public enum ManualTrialError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case sqlite(String)

    public var description: String {
        switch self {
        case .invalid(let reason), .sqlite(let reason): return reason
        }
    }
}

/// Small, separate database: a failed trial write cannot advance the usage
/// collector's checkpoints. DELETE journaling avoids persistent WAL sidecars.
public final class ManualTrialStore {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Erreur inconnue"
            sqlite3_close(db)
            throw ManualTrialError.sqlite("Ouverture des essais impossible : \(message)")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("CREATE TABLE IF NOT EXISTS trials (id TEXT PRIMARY KEY, updated_at REAL NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS trials_updated ON trials(updated_at DESC)")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    public func upsert(_ trial: ManualTrial, at date: Date = Date()) throws -> ManualTrial {
        try Self.validate(trial)
        var saved = trial
        saved.updatedAt = date
        let payload = try JSONEncoder().encode(saved)
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT INTO trials(id,updated_at,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at,payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        bind(saved.id.uuidString, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        bind(payload, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return saved
    }

    public func trial(id: UUID) throws -> ManualTrial? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM trials WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw failure() }
        return try decode(statement)
    }

    public func allTrials() throws -> [ManualTrial] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM trials ORDER BY updated_at DESC, id")
        defer { sqlite3_finalize(statement) }
        var result: [ManualTrial] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw failure() }
            result.append(try decode(statement))
        }
    }

    private static func validate(_ trial: ManualTrial) throws {
        for (label, value) in [("changement", trial.testedChange),
                               ("travail", trial.workDescription),
                               ("critères", trial.successCriteria)] {
            let length = value.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard length > 0, length <= 600 else {
                throw ManualTrialError.invalid("Description \(label) requise (600 caractères maximum, sans prompt complet)")
            }
        }
        if let recommendationID = trial.recommendationID, recommendationID.count > 240 {
            throw ManualTrialError.invalid("Identifiant de recommandation trop long")
        }
        let sides = [trial.before] + (trial.after.map { [$0] } ?? [])
        var references = Set<String>()
        for side in sides {
            for reference in [side.primary] + side.associated.map(\.session) {
                guard !reference.harnessID.isEmpty, !reference.sessionID.isEmpty else {
                    throw ManualTrialError.invalid("Harness et identifiant de session requis")
                }
                let identity = reference.harnessID + "\u{1F}" + reference.sessionID
                guard references.insert(identity).inserted else {
                    throw ManualTrialError.invalid("Une session ne peut être liée deux fois au même essai")
                }
            }
        }
        guard trial.validation.checks.count <= 20 else {
            throw ManualTrialError.invalid("Trop de contrôles de validation")
        }
        for check in trial.validation.checks {
            guard !check.criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  check.criterion.count <= 300, check.evidence.count <= 600 else {
                throw ManualTrialError.invalid("Contrôle ou preuve de validation invalide")
            }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient) }
    }

    private func decode(_ statement: OpaquePointer?) throws -> ManualTrial {
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, let blob = sqlite3_column_blob(statement, 0) else {
            throw ManualTrialError.sqlite("Essai stocké sans contenu")
        }
        return try JSONDecoder().decode(ManualTrial.self, from: Data(bytes: blob, count: length))
    }

    private func failure() -> ManualTrialError {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Erreur SQLite inconnue")
    }
}

public enum TrialComparisonVerdict: String, Sendable {
    case waitingForAfterSession
    case incompatibleSessions
    case insufficientMeasuredData
    case observedDifference
    case validatedSinglePair
}

public enum TrialComparisonScope: String, Sendable {
    case primarySessions
    case completeTrial
}

public struct TrialMetricDifference: Sendable {
    public let metric: CoverageMetric
    public let scope: TrialComparisonScope
    public let before: Decimal
    public let after: Decimal
    public let delta: Decimal
}

public struct TrialSessionSummary: Sendable {
    public let reference: TrialSessionReference
    public let role: TrialAssociatedRole?
    public let eventCount: Int
    public let firstEvent: Date?
    public let lastEvent: Date?
    public let provenances: [String]
    public let metrics: [CoverageMetric: UsageMeasurement<Decimal>]
    public let limitations: [String]
}

public struct ManualTrialComparison: Sendable {
    public let verdict: TrialComparisonVerdict
    public let differences: [TrialMetricDifference]
    public let before: [TrialSessionSummary]
    public let after: [TrialSessionSummary]
    public let reasons: [String]
    public let conclusion: String
}

/// Descriptive, same-harness/same-model comparison only. The caller supplies
/// historical records; this function makes no network or model request.
public enum ManualTrialEvaluator {
    public static func evaluate(_ trial: ManualTrial, records: [UnifiedUsageRecord]) -> ManualTrialComparison {
        let before = summaries(for: trial.before, records: records)
        guard let afterSide = trial.after else {
            return ManualTrialComparison(verdict: .waitingForAfterSession, differences: [],
                before: before, after: [], reasons: ["Session après changement non liée"],
                conclusion: "Essai en attente d'une session après changement.")
        }
        let after = summaries(for: afterSide, records: records)
        let left = trial.before.primary, right = afterSide.primary
        var reasons: [String] = []
        if left.harnessID != right.harnessID { reasons.append("Harness différents") }
        if left.modelID == nil || right.modelID == nil { reasons.append("Modèle inconnu sur au moins une session") }
        else if left.modelID != right.modelID { reasons.append("Modèles différents") }
        if let a = left.providerID, let b = right.providerID, a != b { reasons.append("Providers différents") }
        if before[0].eventCount == 0 || after[0].eventCount == 0 { reasons.append("Événements absents sur une session principale") }
        if !before[0].limitations.isEmpty || !after[0].limitations.isEmpty {
            reasons.append("Identité harness/provider/modèle incomplète ou incohérente dans les événements")
        }
        guard reasons.isEmpty else {
            return ManualTrialComparison(verdict: .incompatibleSessions, differences: [], before: before,
                after: after, reasons: reasons, conclusion: "Comparaison refusée : identité des sessions non établie.")
        }

        var differences = metricDifferences(before: before[0].metrics, after: after[0].metrics,
                                            scope: .primarySessions)
        // A token total cannot silently combine different tokenizer/model
        // definitions. Associated sessions remain visible individually.
        let allBefore = [trial.before.primary] + trial.before.associated.map(\.session)
        let allAfter = [afterSide.primary] + afterSide.associated.map(\.session)
        let homogeneous = (allBefore + allAfter).allSatisfy {
            $0.harnessID == left.harnessID && $0.modelID == left.modelID && $0.providerID == left.providerID
        } && (before + after).allSatisfy { $0.eventCount > 0 && $0.limitations.isEmpty }
        if homogeneous && (!trial.before.associated.isEmpty || !afterSide.associated.isEmpty) {
            differences += metricDifferences(before: aggregate(before), after: aggregate(after),
                                             scope: .completeTrial)
        } else if !homogeneous {
            reasons.append("Étapes associées hétérogènes, absentes ou mal identifiées : volumes non additionnés ; consulter leur détail")
        }
        if differences.isEmpty { reasons.append("Aucune métrique mesurée sur les deux côtés") }
        if trial.validation.quality != .supported || trial.validation.workEquivalence != .supported {
            reasons.append("Qualité ou équivalence du travail non établie")
        }
        if !trial.validation.checks.isEmpty,
           trial.validation.checks.contains(where: { $0.outcome != .passed }) {
            reasons.append("Certains critères de validation sont échoués ou inconclusifs")
        }
        reasons.append("Une seule paire de sessions ne démontre pas un résultat reproductible")
        reasons.append("La complétude historique des sessions doit être vérifiée dans la vue Couverture")
        let validated = trial.validation.quality == .supported &&
            trial.validation.workEquivalence == .supported &&
            !trial.validation.checks.isEmpty &&
            trial.validation.checks.allSatisfy { $0.outcome == .passed }
        let verdict: TrialComparisonVerdict = differences.isEmpty ? .insufficientMeasuredData :
            (validated ? .validatedSinglePair : .observedDifference)
        let conclusion: String
        if differences.isEmpty {
            conclusion = "Aucune métrique mesurée comparable ; gain de workflow non établi."
        } else if validated {
            conclusion = "Différence de consommation observée sur une paire validée ; résultat non généralisable."
        } else {
            conclusion = "Différence de consommation observée ; gain de workflow non établi."
        }
        return ManualTrialComparison(verdict: verdict, differences: differences,
                                     before: before, after: after, reasons: reasons, conclusion: conclusion)
    }

    private static func summaries(for side: TrialSide, records: [UnifiedUsageRecord]) -> [TrialSessionSummary] {
        let links: [(TrialSessionReference, TrialAssociatedRole?)] =
            [(side.primary, nil)] + side.associated.map { ($0.session, $0.role) }
        return links.map { reference, role in
                let selected = records.filter { $0.harnessID == reference.harnessID && $0.sessionID == reference.sessionID }
                var seen = Set<String>()
                let unique = selected.filter { $0.eventID.isEmpty || seen.insert($0.eventID).inserted }
                var limitations: [String] = []
                if unique.contains(where: { $0.modelID != reference.modelID || $0.providerID != reference.providerID }) {
                    limitations.append("Modèle ou provider différent/inconnu dans les événements de cette session")
                }
                let dates = unique.map(\.timestamp).sorted()
                return TrialSessionSummary(reference: reference, role: role, eventCount: unique.count,
                                           firstEvent: dates.first, lastEvent: dates.last,
                                           provenances: Array(Set(unique.map(\.provenance))).sorted(),
                                           metrics: metricTotals(unique), limitations: limitations)
        }
    }

    private static func metricTotals(_ records: [UnifiedUsageRecord]) -> [CoverageMetric: UsageMeasurement<Decimal>] {
        var result: [CoverageMetric: UsageMeasurement<Decimal>] = [:]
        for metric in CoverageMetric.allCases {
            guard !records.isEmpty else { result[metric] = .unavailable; continue }
            var total = Decimal(0)
            var estimated = false
            var missing = false
            for record in records {
                let value: UsageMeasurement<Decimal>
                switch metric {
                case .inputTokens: value = decimal(record.inputTokens)
                case .outputTokens: value = decimal(record.outputTokens)
                case .cachedInputTokens: value = decimal(record.cachedInputTokens)
                case .reasoningTokens: value = decimal(record.reasoningTokens)
                case .durationSeconds: value = decimal(record.durationSeconds)
                case .costUSD: value = record.costUSD
                }
                switch value {
                case .measured(let amount): total += amount
                case .estimated(let amount): total += amount; estimated = true
                case .unavailable: missing = true
                }
            }
            result[metric] = missing ? .unavailable : (estimated ? .estimated(total) : .measured(total))
        }
        return result
    }

    private static func decimal(_ value: UsageMeasurement<Int64>) -> UsageMeasurement<Decimal> {
        switch value {
        case .measured(let amount): return .measured(Decimal(amount))
        case .estimated(let amount): return .estimated(Decimal(amount))
        case .unavailable: return .unavailable
        }
    }

    private static func decimal(_ value: UsageMeasurement<Double>) -> UsageMeasurement<Decimal> {
        switch value {
        case .measured(let amount): return .measured(Decimal(amount))
        case .estimated(let amount): return .estimated(Decimal(amount))
        case .unavailable: return .unavailable
        }
    }

    private static func aggregate(_ sessions: [TrialSessionSummary]) -> [CoverageMetric: UsageMeasurement<Decimal>] {
        var result: [CoverageMetric: UsageMeasurement<Decimal>] = [:]
        for metric in CoverageMetric.allCases {
            var total = Decimal(0)
            var valid = true
            for session in sessions {
                guard case .measured(let amount) = session.metrics[metric] ?? .unavailable else {
                    valid = false; break
                }
                total += amount
            }
            result[metric] = valid ? .measured(total) : .unavailable
        }
        return result
    }

    private static func metricDifferences(before: [CoverageMetric: UsageMeasurement<Decimal>],
                                          after: [CoverageMetric: UsageMeasurement<Decimal>],
                                          scope: TrialComparisonScope) -> [TrialMetricDifference] {
        CoverageMetric.allCases.compactMap { metric in
            guard case .measured(let a) = before[metric] ?? .unavailable,
                  case .measured(let b) = after[metric] ?? .unavailable else { return nil }
            return TrialMetricDifference(metric: metric, scope: scope,
                                         before: a, after: b, delta: b - a)
        }
    }
}
