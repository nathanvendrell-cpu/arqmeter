import SwiftUI
import ArqmeterCore

/// Shared by the real Conseils page and the offscreen rendering recipe.
/// All measurement/provider semantics come from the core evidence, not the UI.
struct AdviceCardView: View {
    let item: SessionRecommendation
    let resolvedModel: String?
    let onOpenSession: () -> Void
    let onIgnore: () -> Void
    var onPrepareTrial: (() -> Void)?
    @State private var proofsExpanded: Bool

    init(item: SessionRecommendation, resolvedModel: String?, proofsExpanded: Bool = false,
         onOpenSession: @escaping () -> Void, onIgnore: @escaping () -> Void,
         onPrepareTrial: (() -> Void)? = nil) {
        self.item = item; self.resolvedModel = resolvedModel
        self.onOpenSession = onOpenSession; self.onIgnore = onIgnore
        self.onPrepareTrial = onPrepareTrial
        _proofsExpanded = State(initialValue: proofsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.problem).font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.basis.label).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                metric("Contexte total · cumulé", value: item.tokenEvidence.totalInput,
                    covered: item.tokenEvidence.inputMeasuredEvents,
                    estimates: item.tokenEvidence.inputEstimatedEvents,
                    invalid: item.tokenEvidence.invalidInputEvents)
                metric("Cache lu", value: item.tokenEvidence.cacheRead,
                    covered: item.tokenEvidence.cacheMeasuredEvents,
                    estimates: item.tokenEvidence.cacheEstimatedEvents,
                    invalid: item.tokenEvidence.invalidCacheEvents)
                metric(item.tokenEvidence.uncachedLabel, value: item.tokenEvidence.uncachedInput,
                    covered: item.tokenEvidence.pairedMeasuredEvents, estimates: 0,
                    invalid: item.tokenEvidence.invalidInputEvents + item.tokenEvidence.invalidCacheEvents,
                    derived: true)
            }
            Text("Action proposée · \(item.recommendation)").font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Pourquoi ce conseil · preuves et limites", isExpanded: $proofsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Signal : \(severityLabel) · confiance heuristique : \(confidenceLabel)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Observation · \(item.observedData)").font(.system(size: 13))
                    Text(item.tokenEvidence.comparableModelProvider ?
                        "Même provider et modèle ; travail équivalent et qualité non établis." :
                        "Provider ou modèle différent/inconnu : comparaison de charge limitée.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if item.tokenEvidence.uncachedIncludesCacheCreation {
                        Text("L’entrée hors cache inclut l’entrée directe et la création de cache. Elle n’indique pas un coût ni un quota.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Text("Impact non démontré · \(item.estimatedImpact)")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Limite · \(item.limitations)").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Preuves · \(item.evidence.count) événements · \(SourceDisplay.name(item.harnessID)) · \(resolvedModel ?? item.modelID ?? "modèle inconnu")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    DisclosureGroup("Identifiants de preuve") {
                        ForEach(Array(item.evidence.prefix(30)), id: \.self) { eventID in
                            Text(eventID).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                        if item.evidence.count > 30 {
                            Text("\(item.evidence.count - 30) autres événements dans la session.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            HStack(spacing: 15) {
                Button("Ouvrir la session", action: onOpenSession)
                Button("Ignorer", action: onIgnore)
                if let onPrepareTrial { Button("Préparer un essai", action: onPrepareTrial) }
            }
            .buttonStyle(.link)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private var severityLabel: String {
        switch item.severity { case .high: return "priorité élevée"; case .moderate: return "à examiner"; case .info: return "information" }
    }

    private var confidenceLabel: String {
        switch item.confidence { case .high: return "élevée"; case .medium: return "moyenne"; case .low: return "faible" }
    }

    private func metric(_ title: String, value: Int64?, covered: Int, estimates: Int, invalid: Int,
                        derived: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value.map { TokenDialGeometry.label(Double($0)) } ?? "—")
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(coverage(value: value, covered: covered, estimates: estimates, invalid: invalid, derived: derived))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(value.map { "\($0.formatted()) tokens \(derived ? "calculés à partir de mesures" : "mesurés") sur \(covered)/\(item.tokenEvidence.eventCount) événements" } ?? "Mesure non établie")
    }

    private func coverage(value: Int64?, covered: Int, estimates: Int, invalid: Int, derived: Bool) -> String {
        if invalid > 0 { return "\(covered)/\(item.tokenEvidence.eventCount) mesurés · \(invalid) invalide(s)" }
        if estimates > 0 { return "\(covered)/\(item.tokenEvidence.eventCount) mesurés · \(estimates) estimé(s), non ajoutés" }
        if value == nil { return covered == 0 ? "Non mesuré" : "Total non calculable" }
        return covered == item.tokenEvidence.eventCount ?
            "\(covered) événements · \(derived ? "calculé" : "mesuré")" :
            "\(covered)/\(item.tokenEvidence.eventCount) · \(derived ? "calcul partiel" : "somme partielle")"
    }
}
