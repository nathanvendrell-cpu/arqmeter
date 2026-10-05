import Foundation
import ArqmeterCore
import SwiftUI

final class SourcesValidationModel: ObservableObject {
    @Published private(set) var usage: UnifiedUsage?
    @Published private(set) var historical: HistoricalDashboardSnapshot?
    var windowDays = 7
    @Published private(set) var loading = false
    private var scanning = false

    func refresh(codex: LocalTokenSummary?, quota: Int?, quotaSampledAt: Date?) {
        loadHistorical()
        guard !scanning else { return }
        scanning = true
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let local = codex ?? LocalActivityStore().refresh()
            let codexSource = CodexAdapter(records: local.unifiedEvents,
                installed: true, readable: local.scanComplete,
                quotaRemainingPercent: quota, quotaSampledAt: quotaSampledAt).read()
            var sources = [codexSource]
            DispatchQueue.main.async { self?.usage = UnifiedUsage(sources: [codexSource]) }
            let adapters: [any UnifiedUsageAdapter] = [LocalModelAdapter(), GeminiAdapter(), ClaudeCodeAdapter()]
            for adapter in adapters {
                sources.append(adapter.read())
                let order = ["codex", "claude-code", "gemini-cli", "ollama"]
                let current = UnifiedUsage(sources: sources.sorted {
                    (order.firstIndex(of: $0.harnessID) ?? 99) < (order.firstIndex(of: $1.harnessID) ?? 99)
                })
                DispatchQueue.main.async { self?.usage = current }
            }
            DispatchQueue.main.async {
                self?.loading = false
                self?.scanning = false
            }
        }
    }

    func loadHistorical(days: Int? = nil) {
        if let days { windowDays = days }
        HistoricalUsageService.shared.snapshot(days: windowDays) { [weak self] result in self?.historical = result }
    }
}

struct SourcesValidationView: View {
    @ObservedObject var sourceModel: SourcesValidationModel
    let codex: LocalTokenSummary?
    let codexQuota: Int?
    let quotaSampledAt: Date?

    private let accent = Color(red: 0.36, green: 0.71, blue: 1)
    @State private var section: ValidationSection = .sources

    private enum ValidationSection: String, CaseIterable {
        case sources = "Sources"
        case coverage = "Couverture"
        case optimizer = "Optimizer"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sources vérifiées").font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text("Mesures locales · valeurs manquantes explicites")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Connecté = outil présent et journaux lisibles ; pas une validation de l'authentification.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { sourceModel.refresh(codex: codex, quota: codexQuota, quotaSampledAt: quotaSampledAt) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Relire les sources")
                }
                Picker("Section", selection: $section) {
                    ForEach(ValidationSection.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                if sourceModel.loading { ProgressView("Lecture des journaux…").font(.system(size: 11)) }
                if section == .sources, let usage = sourceModel.usage {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .top),
                                        GridItem(.flexible(), alignment: .top)], spacing: 10) {
                        ForEach(usage.sources, id: \.harnessID) { source in
                            sourceCard(source)
                        }
                    }
                    let global = usage.aggregate()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TOTAL OBSERVÉ").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(accent)
                        Text("\(format(global.inputTokens.value)) entrée · \(format(global.outputTokens.value)) sortie")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Couverture entrée : \(global.inputTokens.coveredRecords)/\(global.inputTokens.totalRecords) événements · les durées Ollama n’ont pas de tokens.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Attention : Codex couvre ici 24 h ; Claude, Gemini et Ollama couvrent les journaux disponibles. Ce total n’est pas un relevé de facturation.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                }
                if section == .coverage { coverageSection }
                if section == .optimizer { optimizerSection }
            }
            .padding(14)
        }
        .frame(width: 690, height: 650)
        .background(.ultraThinMaterial)
        .onAppear {
            if sourceModel.usage == nil {
                sourceModel.refresh(codex: codex, quota: codexQuota, quotaSampledAt: quotaSampledAt)
            } else { sourceModel.loadHistorical() }
        }
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Historique ARQMETER")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Picker("Période", selection: Binding(get: { sourceModel.windowDays }, set: { sourceModel.loadHistorical(days: $0) })) {
                    Text("24 h").tag(1)
                    Text("7 j").tag(7)
                    Text("30 j").tag(30)
                }
                .labelsHidden()
                .frame(width: 120)
            }
            Text("La couverture décrit les fichiers observés, pas l'exhaustivité du compte. Aucun pourcentage n'est calculé quand le passé n'est pas vérifiable.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let error = sourceModel.historical?.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
            ForEach(sourceModel.historical?.coverage ?? [], id: \.harnessID) { item in
                let scan = sourceModel.historical?.scanResults.first { $0.harnessID == item.harnessID }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(display(item.harnessID)).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(item.continuouslyObserved ? "Fenêtre suivie" : "Couverture partielle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.continuouslyObserved ? .green : .orange)
                    }
                    Text("Suivi depuis : \(item.trackingSince?.formatted(.dateTime.day().month().hour().minute()) ?? "non démarré") · dernier scan : \(item.lastScan?.formatted(.dateTime.hour().minute().second()) ?? "—")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(item.eventCount) événements · \(scan.map { "\($0.filesScanned) fichiers lus" } ?? "inventaire en attente") · dernier événement : \(item.latestEvent?.formatted(.dateTime.day().month().hour().minute()) ?? "aucun")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Providers : \(item.providerIDs.joined(separator: ", ").isEmpty ? "indisponibles" : item.providerIDs.joined(separator: ", ")) · modèles : \(item.modelIDs.count) observé(s)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    metricLine(item, .inputTokens, name: "Entrée")
                    metricLine(item, .outputTokens, name: "Sortie")
                    metricLine(item, .cachedInputTokens, name: "Cache")
                    metricLine(item, .reasoningTokens, name: "Raisonnement")
                    metricLine(item, .durationSeconds, name: "Durée")
                    metricLine(item, .costUSD, name: "Coût")
                    Text("Quota officiel : \(item.latestQuotaRemainingPercent.map { "\($0)% restants" } ?? "indisponible")\(item.quotaSampledAt.map { " · lu à \($0.formatted(.dateTime.hour().minute()))" } ?? "")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if item.harnessID != "codex", let verdict = sourceModel.historical?.comparability[item.harnessID] {
                        Text("vs Codex · \(verdict.verdict.rawValue) · \(verdict.reasons.joined(separator: "; "))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ForEach(item.knownGaps.prefix(2), id: \.self) { gap in
                        Text("Trou connu : \(gap)").font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            if sourceModel.historical == nil {
                ProgressView("Lecture de l'historique…")
            }
        }
    }

    private func metricLine(_ item: HistoricalCoverage, _ metric: CoverageMetric, name: String) -> some View {
        let value = item.metrics[metric]
        return Text("\(name) : \(value?.measured ?? 0) mesurés · \(value?.estimated ?? 0) dérivés · \(value?.unavailable ?? 0) indisponibles")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var optimizerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optimisation des sessions · opportunités uniquement")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Aucun gain chiffré sans mesure avant/après. Les prompts et réponses ne sont pas stockés dans cet historique.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            let items = sourceModel.historical?.recommendations ?? []
            if items.isEmpty {
                Text("Aucune recommandation étayée dans la fenêtre observée.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            ForEach(items.prefix(50)) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Observation : \(item.observedData)")
                        Text("Problème : \(item.problem)")
                        Text("Action : \(item.recommendation)")
                        Text("Impact : \(item.estimatedImpact)")
                        Text("Preuves : \(item.evidence.count) événement(s) · \(item.evidence.prefix(3).joined(separator: ", "))")
                        Text("Limites : \(item.limitations)")
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 7)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.type.rawValue).font(.system(size: 12, weight: .semibold))
                        Text("\(display(item.harnessID)) · \(item.modelID ?? "modèle inconnu") · confiance \(item.confidence.rawValue) · \(item.severity.rawValue)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            if items.count > 50 {
                Text("50 recommandations affichées sur \(items.count) · filtrage à prévoir.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func display(_ harness: String) -> String {
        ["codex": "Codex", "claude-code": "Claude Code", "gemini-cli": "Gemini CLI", "ollama": "Ollama"][harness] ?? harness
    }

    private func sourceCard(_ source: UsageSourceSnapshot) -> some View {
        let record = source.lastRecord
        let quota = source.quotaRemainingPercent.value
        let total = UsageAggregate(records: source.records)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(source.displayName).font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Circle().fill(source.installed && source.readable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(source.installed && source.readable ? "Connecté" : "Non connecté")
                    .font(.system(size: 10, weight: .medium))
            }
            Text("Dernière donnée : \(record?.timestamp.formatted(.dateTime.day().month().year().hour().minute()) ?? "aucune")")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let record, Date().timeIntervalSince(record.timestamp) > 7 * 24 * 60 * 60 {
                Text("Historique ancien · pas d'activité récente prouvée")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 8) {
                datum("Provider", record?.providerID ?? "indisponible")
                datum("Modèle", record?.modelID ?? "indisponible")
            }
            HStack(alignment: .top, spacing: 8) {
                datum("Dernier événement E / S", "\(format(record?.inputTokens.value)) / \(format(record?.outputTokens.value))")
                datum("Quota", quota.map { "\($0)% restants" } ?? "indisponible")
            }
            datum("Projet / workspace", record?.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "indisponible")
                .help(record?.projectPath ?? "Chemin de travail indisponible")
            Text("Total observé : \(format(total.inputTokens.value)) entrée / \(format(total.outputTokens.value)) sortie · couverture \(total.inputTokens.coveredRecords)/\(total.inputTokens.totalRecords)")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text("\(source.records.count) événements · \(source.coverage)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Qualité : tokens \(record.map { quality($0.inputTokens, plural: true) } ?? "indisponibles") · quota \(quality(source.quotaRemainingPercent, plural: false))")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if let record {
                Text("Provenance : \(record.provenance)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let duration = record.durationSeconds.value {
                    Text("Durée mesurée : \(duration.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if quota != nil {
                Text("Quota lu à \(source.quotaSampledAt?.formatted(.dateTime.hour().minute()) ?? "—") · distinct des tokens")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let diagnostic = source.diagnostic {
                Text(diagnostic).font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.14), lineWidth: 0.7) }
    }

    private func datum(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.grouping(.automatic))
    }

    private func quality<Value>(_ value: UsageMeasurement<Value>, plural: Bool) -> String where Value: Equatable & Sendable {
        switch value {
        case .measured: return plural ? "mesurés" : "mesuré"
        case .estimated: return plural ? "estimés" : "estimé"
        case .unavailable: return plural ? "indisponibles" : "indisponible"
        }
    }

}
