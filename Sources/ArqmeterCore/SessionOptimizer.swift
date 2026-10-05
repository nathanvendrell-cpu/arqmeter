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
        // Compare context per response, not total work: a longer session is not
        // an inefficient one. Unknown/conflicting metadata cannot form peers.
        let averages = sessions.mapValues { session -> Double? in
            guard session.allSatisfy({ measured($0.inputTokens).map { $0 >= 0 } == true }),
                  let total = safeSum(session.compactMap { measured($0.inputTokens) }) else { return nil }
            return Double(total) / Double(session.count)
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
            let cache = session.compactMap { measured($0.cachedInputTokens) }
            let validCache = inputs.count == session.count && cache.count == session.count &&
                zip(inputs, cache).allSatisfy { $0 >= 0 && $1 >= 0 && $1 <= $0 }
            let cachedTotal = validCache ? safeSum(cache) : nil
            let homogeneousContext = consistent(session.map(\.providerID)) != nil &&
                consistent(session.map(\.modelID)) != nil
            let evidence = session.map(\.eventID)
            let source = first.provenance

            func add(_ type: RecommendationType, severity: RecommendationSeverity,
                     confidence: RecommendationConfidence, observed: String, problem: String,
                     action: String, limitation: String) {
                result.append(SessionRecommendation(id: "\(key):\(type.rawValue)", type: type,
                    severity: severity, confidence: confidence, harnessID: first.harnessID,
                    sessionID: first.sessionID, modelID: consistent(session.map(\.modelID)),
                    projectPath: consistent(session.map(\.projectPath)), observedData: observed, problem: problem,
                    recommendation: action,
                    estimatedImpact: "Opportunité non quantifiée ; aucun gain avant/après mesuré.",
                    impactClassification: .theoreticalOpportunity,
                    evidence: evidence, limitations: "\(limitation) Source : \(source)"))
            }

            if fullTokens, let inputTotal, let outputTotal, session.count >= 3,
               inputTotal >= 100_000, outputTotal > 0, Double(inputTotal) >= Double(outputTotal) * 15 {
                let cacheObservation = cachedTotal.map { " Dont \($0) en cache, \(inputTotal - $0) hors cache." } ?? " Cache non mesuré sur toute la session."
                add(.highInputToOutput, severity: .info, confidence: .low,
                    observed: "\(inputTotal) tokens d'entrée, \(outputTotal) de sortie sur \(session.count) réponses (ratio ≥ 15:1).\(cacheObservation)",
                    problem: "Entrée élevée par rapport à la sortie : constat, pas gaspillage démontré.",
                    action: "Ne pas réduire le contexte sur ce seul ratio. Si une redondance est confirmée, tester un contexte plus court sur un travail équivalent et vérifier qualité et tokens hors cache avant/après.",
                    limitation: "L'entrée peut inclure du cache et du travail utile aux outils. La sortie ne mesure ni la difficulté ni la qualité ; ces tokens ne donnent pas le coût ni le quota consommé.")
            }

            if inputs.count == session.count, inputs.allSatisfy({ $0 >= 0 }), session.count >= 6, homogeneousContext {
                let firstAverage = inputs.prefix(3).reduce(0.0) { $0 + Double($1) } / 3
                let lastAverage = inputs.suffix(3).reduce(0.0) { $0 + Double($1) } / 3
                if firstAverage > 0, lastAverage >= 20_000, lastAverage >= firstAverage * 2 {
                    add(.contextGrowth, severity: .moderate, confidence: .medium,
                        observed: "Entrée moyenne des 3 premières réponses : \(Int(firstAverage)) ; des 3 dernières : \(Int(lastAverage)) tokens (≥ 2×).",
                        problem: "Le contexte par réponse croît rapidement dans cette session.",
                        action: "Repérer d'abord une répétition réelle. Tester uniquement les éléments confirmés redondants sur un travail équivalent, puis vérifier qualité et tokens hors cache avant/après.",
                        limitation: "Une croissance peut être justifiée par la tâche ; elle ne prouve pas un gaspillage. Aucun contenu n'est inspecté, aucune conversation n'est compactée automatiquement.")
                }
            }

            if validCache, homogeneousContext, session.count >= 3,
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

            if let inputTotal, inputTotal >= 100_000, let current = averages[key] ?? nil,
               let provider = consistent(session.map(\.providerID)),
               let project = consistent(session.map(\.projectPath)),
               let model = consistent(session.map(\.modelID)) {
                let peers = sessions.compactMap { otherKey, other -> Double? in
                    guard otherKey != key, other.first?.harnessID == first.harnessID,
                          consistent(other.map(\.providerID)) == provider,
                          consistent(other.map(\.projectPath)) == project,
                          consistent(other.map(\.modelID)) == model else { return nil }
                    return averages[otherKey] ?? nil
                }.sorted()
                if peers.count >= 5, let median = peers.dropFirst(peers.count / 2).first,
                   median > 0, Double(current) >= Double(median) * 3 {
                    add(.anomalousSessionVolume, severity: .info, confidence: .medium,
                        observed: "\(Int(current)) tokens d'entrée par réponse contre une médiane de \(Int(median)) sur \(peers.count) autres sessions du même harness/provider/modèle/workspace.",
                        problem: "Plus d'entrée par réponse que dans l'historique comparable.",
                        action: "Identifier les tours concernés, sans réduire le contexte automatiquement. Comparer un essai de travail équivalent avec qualité, cache et tokens hors cache avant/après.",
                        limitation: "Moyennes par réponse, pas totaux de sessions de durées différentes. Modèle et workspace homogènes ne prouvent pas que les tâches sont équivalentes ; aucun gaspillage ni gain établi.")
                }
            }

            if session.count >= 2, session.allSatisfy({ $0.executionLocation == .local || $0.sourceKind == .ollamaServerLog }) {
                let durations = session.compactMap { measured($0.durationSeconds) }
                let total = durations.reduce(0, +)
                if durations.count == session.count, durations.allSatisfy({ $0.isFinite && $0 >= 0 }), total.isFinite, total >= 600, total < Double(Int.max) {
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
            guard value >= 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = sum
        }
        return total
    }

    private static func consistent(_ values: [String?]) -> String? {
        guard let value = values.first ?? nil, !value.isEmpty,
              values.allSatisfy({ $0 == value }) else { return nil }
        return value
    }
}
