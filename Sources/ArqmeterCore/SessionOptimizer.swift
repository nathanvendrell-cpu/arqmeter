import Foundation

public enum RecommendationType: String, Sendable {
    case contextGrowth
    case highInputToOutput
    case lowCacheReuse
    case potentialContextRepetition
    case anomalousSessionVolume
    case longLocalRequest
}

public enum RecommendationSeverity: String, Sendable { case info, moderate, high }
public enum RecommendationConfidence: String, Sendable { case low, medium, high }
public enum ImpactClassification: String, Sendable {
    case theoreticalOpportunity
    case estimatedSaving
    case measuredSaving
}

public struct SessionRecommendation: Identifiable, Sendable {
    public let id: String
    public let type: RecommendationType
    public let severity: RecommendationSeverity
    public let confidence: RecommendationConfidence
    public let harnessID: String
    public let sessionID: String
    public let modelID: String?
    public let projectPath: String?
    public let observedData: String
    public let problem: String
    public let recommendation: String
    public let estimatedImpact: String
    public let impactClassification: ImpactClassification
    public let evidence: [String]
    public let limitations: String
}

/// Heuristics on one session only. No prompt text, task complexity, quality, or
/// cross-provider equivalence is inferred from token counts.
public enum SessionOptimizer {
    public static func analyze(_ records: [UnifiedUsageRecord]) -> [SessionRecommendation] {
        let unique = UsageAggregate(records: records).records
        let sessions = Dictionary(grouping: unique, by: { "\($0.harnessID):\($0.sessionID)" })
        let totals = sessions.mapValues { session -> Int64? in
            guard session.allSatisfy({ measured($0.inputTokens) != nil && measured($0.outputTokens) != nil }) else { return nil }
            return safeSum(session.compactMap { measured($0.inputTokens) })
        }
        var result: [SessionRecommendation] = []
        for (key, unsorted) in sessions {
            let session = unsorted.sorted { $0.timestamp < $1.timestamp }
            guard let first = session.first else { continue }
            let inputs = session.compactMap { measured($0.inputTokens) }
            let outputs = session.compactMap { measured($0.outputTokens) }
            let fullTokens = inputs.count == session.count && outputs.count == session.count
            let inputTotal = fullTokens ? safeSum(inputs) : nil
            let outputTotal = fullTokens ? safeSum(outputs) : nil
            let evidence = session.map(\.eventID)
            let source = first.provenance

            func add(_ type: RecommendationType, severity: RecommendationSeverity,
                     confidence: RecommendationConfidence, observed: String, problem: String,
                     action: String, limitation: String) {
                result.append(SessionRecommendation(id: "\(key):\(type.rawValue)", type: type,
                    severity: severity, confidence: confidence, harnessID: first.harnessID,
                    sessionID: first.sessionID, modelID: first.modelID,
                    projectPath: first.projectPath, observedData: observed, problem: problem,
                    recommendation: action,
                    estimatedImpact: "Opportunité non quantifiée ; aucun gain avant/après mesuré.",
                    impactClassification: .theoreticalOpportunity,
                    evidence: evidence, limitations: "\(limitation) Source : \(source)"))
            }

            if fullTokens, let inputTotal, let outputTotal, session.count >= 3,
               inputTotal >= 100_000, Double(inputTotal) >= Double(outputTotal) * 15 {
                add(.highInputToOutput, severity: .moderate, confidence: .medium,
                    observed: "\(inputTotal) tokens d'entrée, \(outputTotal) de sortie sur \(session.count) réponses (ratio ≥ 15:1).",
                    problem: "Le volume de contexte est élevé par rapport à la sortie observée.",
                    action: "Examiner le contexte envoyé à chaque réponse ; raccourcir les éléments redondants si la tâche le permet.",
                    limitation: "La longueur de sortie ne mesure ni son utilité ni la difficulté de la tâche.")
            }

            if inputs.count == session.count, session.count >= 6 {
                let firstAverage = inputs.prefix(3).reduce(0.0) { $0 + Double($1) } / 3
                let lastAverage = inputs.suffix(3).reduce(0.0) { $0 + Double($1) } / 3
                if firstAverage > 0, lastAverage >= 20_000, lastAverage >= firstAverage * 2 {
                    add(.contextGrowth, severity: .moderate, confidence: .medium,
                        observed: "Entrée moyenne des 3 premières réponses : \(Int(firstAverage)) ; des 3 dernières : \(Int(lastAverage)) tokens (≥ 2×).",
                        problem: "Le contexte par réponse croît rapidement dans cette session.",
                        action: "Examiner la croissance du contexte et condenser les éléments répétés avant les prochains tours.",
                        limitation: "Une croissance peut être justifiée par une tâche plus complexe ; aucun contenu n'est inspecté.")
                }
            }

            let cache = session.compactMap { measured($0.cachedInputTokens) }
            if inputs.count == session.count, cache.count == session.count, session.count >= 3,
               let inputTotal = safeSum(inputs), let cached = safeSum(cache), inputTotal >= 100_000,
               Double(cached) / Double(inputTotal) < 0.1 {
                add(.lowCacheReuse, severity: .info, confidence: .medium,
                    observed: "\(cached) / \(inputTotal) tokens d'entrée servis du cache (< 10 %).",
                    problem: "La réutilisation de cache observée est faible.",
                    action: "Vérifier si des préfixes de contexte stables peuvent être conservés entre réponses.",
                    limitation: "Le cache peut dépendre du provider, du modèle et du type de requête ; un faible ratio n'est pas nécessairement une inefficacité.")
            }

            if inputs.count == session.count, inputs.count >= 4 {
                let large = inputs.filter { $0 >= 20_000 }
                if large.count >= 4, let minimum = large.min(), let maximum = large.max(),
                   Double(maximum - minimum) / Double(maximum) <= 0.05 {
                    add(.potentialContextRepetition, severity: .info, confidence: .low,
                        observed: "\(large.count) entrées ≥ 20k tokens, tailles dans une plage de 5 %.",
                        problem: "Un volume de contexte similaire semble revenir plusieurs fois.",
                        action: "Inspecter manuellement les tours concernés pour voir si un contexte identique est renvoyé.",
                        limitation: "Des tailles proches ne prouvent pas une répétition de contenu ; les prompts ne sont pas stockés.")
                }
            }

            if let current = totals[key] ?? nil, current >= 100_000 {
                let peers = sessions.compactMap { otherKey, other -> Int64? in
                    guard otherKey != key, let otherFirst = other.first,
                          otherFirst.harnessID == first.harnessID,
                          first.projectPath != nil,
                          otherFirst.projectPath == first.projectPath,
                          otherFirst.modelID == first.modelID else { return nil }
                    return totals[otherKey] ?? nil
                }.sorted()
                if peers.count >= 5, let median = peers.dropFirst(peers.count / 2).first,
                   median > 0, Double(current) >= Double(median) * 3 {
                    add(.anomalousSessionVolume, severity: .moderate, confidence: .medium,
                        observed: "\(current) tokens d'entrée contre une médiane de \(median) sur \(peers.count) autres sessions du même harness/modèle/workspace.",
                        problem: "Le volume est inhabituel par rapport à cet historique personnel homogène.",
                        action: "Revoir la chronologie de cette session et identifier les tours responsables de la hausse.",
                        limitation: "Les tâches ne sont pas nécessairement équivalentes ; la couverture historique peut être partielle.")
                }
            }

            if session.count >= 2 {
                let durations = session.compactMap { measured($0.durationSeconds) }
                let total = durations.reduce(0, +)
                if durations.count == session.count, total >= 600 {
                    add(.longLocalRequest, severity: .info, confidence: .medium,
                        observed: "\(Int(total)) secondes serveur sur \(session.count) requêtes.",
                        problem: "Cette session locale a une longue durée cumulée.",
                        action: "Vérifier le débit et la taille des requêtes avec une télémétrie locale plus complète.",
                        limitation: "La durée ne permet pas d'attribuer la cause au modèle, au prompt ou au matériel.")
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    private static func measured<T>(_ value: UsageMeasurement<T>) -> T? {
        if case .measured(let amount) = value { return amount }
        return nil
    }

    private static func safeSum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = sum
        }
        return total
    }
}
