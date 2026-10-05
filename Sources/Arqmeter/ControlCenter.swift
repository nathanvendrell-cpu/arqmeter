import AppKit
import ArqmeterCore
import SwiftUI

private enum ProductSection: String, CaseIterable, Identifiable {
    case control = "Vue d’ensemble"
    case sessions = "Sessions"
    case optimizer = "Conseils"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .control: return "square.grid.2x2"
        case .sessions: return "list.bullet.rectangle"
        case .optimizer: return "scope"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .control: return "1"
        case .sessions: return "2"
        case .optimizer: return "3"
        }
    }
}

private struct TrialEditorRequest: Identifiable {
    let id = UUID()
    let existing: ManualTrial?
    let initialBeforeID: String?
    let recommendationID: String?
}

private struct CoverageRequest: Identifiable {
    let id = UUID()
    let coverage: HistoricalCoverage
    let availability: SourceAvailability?
}

final class ControlCenterModel: ObservableObject {
    @Published var snapshot: HistoricalDashboardSnapshot?
    @Published var allSessions: [UsageSession] = []
    @Published var loading = false
    @Published var windowDays = 7
    @Published var selectedSection: String = ProductSection.control.rawValue
    @Published var selectedSessionID: String?
    @Published var selectedRecommendationID: String?
    @Published var ignoredRecommendationIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredRecommendations") ?? [])
    private var requestID = 0
    private var refreshInFlight = false
    private var pendingDays: Int?
    private let readSnapshot: (Int, @escaping (HistoricalDashboardSnapshot) -> Void) -> Void

    init(readSnapshot: @escaping (Int, @escaping (HistoricalDashboardSnapshot) -> Void) -> Void = {
        HistoricalUsageService.shared.snapshot(days: $0, completion: $1)
    }) {
        self.readSnapshot = readSnapshot
    }

    func refresh(days: Int? = nil) {
        requestID += 1
        let current = requestID
        let requestedDays = days ?? windowDays
        if refreshInFlight {
            pendingDays = requestedDays
            return
        }
        refreshInFlight = true
        loading = true
        readSnapshot(requestedDays) { [weak self] snapshot in
            guard let self else { return }
            self.refreshInFlight = false
            if current == self.requestID {
                self.snapshot = snapshot
                self.allSessions = snapshot.sessions
                if !snapshot.sessions.contains(where: { $0.id == self.selectedSessionID }) {
                    self.selectedSessionID = snapshot.sessions.first?.id
                }
                self.loading = false
            }
            if let days = self.pendingDays {
                self.pendingDays = nil
                self.refresh(days: days)
            }
        }
    }

    func ignore(_ id: String) {
        ignoredRecommendationIDs.insert(id)
        UserDefaults.standard.set(Array(ignoredRecommendationIDs).sorted(), forKey: "ignoredRecommendations")
    }

    func restore(_ id: String) {
        ignoredRecommendationIDs.remove(id)
        UserDefaults.standard.set(Array(ignoredRecommendationIDs).sorted(), forKey: "ignoredRecommendations")
    }

    func openSession(_ id: String) {
        selectedSessionID = id
        selectedSection = ProductSection.sessions.rawValue
    }
}

struct StatusPopoverView: View {
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject var sources: SourceDisplayPreferences
    let openControl: () -> Void
    @State private var now = Date()

    private var quotaFresh: Bool {
        ControlReadout.quota(dashboard.remainingPercent, sampledAt: dashboard.officialSampledAt,
                             now: Date(), resetsAt: dashboard.resetsAt) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ARQMETER").font(.system(size: 11, weight: .bold)).tracking(1.7)
                Spacer()
                if sources.primaryID == "codex" && !quotaFresh {
                    Text("À VÉRIFIER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(SourceDisplay.name(sources.primaryID)).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(quotaText(sources.primaryID))
                    .font(.system(size: sources.primaryID == "codex" && quotaFresh ? 23 : 13, weight: .semibold).monospacedDigit())
            }
            if sources.primaryID == "codex", quotaFresh, let reset = dashboard.resetsAt {
                Text("7 jours · réinit. \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(sources.orderedVisibleIDs.filter { $0 != sources.primaryID }, id: \.self) { id in
                HStack {
                    Text(SourceDisplay.name(id)).font(.system(size: 12))
                    Spacer()
                    Text(quotaText(id)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button(action: openControl) {
                Label("Ouvrir Arqmeter", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(17)
        .frame(width: 325)
        .background(.regularMaterial)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func quotaText(_ id: String) -> String {
        guard id == "codex" else { return "Quota non fourni" }
        guard dashboard.officialSampledAt != nil else { return "Quota indisponible" }
        guard quotaFresh, let percent = dashboard.remainingPercent else { return "Mesure périmée" }
        return "\(percent) % restants"
    }
}

struct ControlCenterView: View {
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject private var sourcePreferences = SourceDisplayPreferences.shared
    @State private var readingMode: String
    let onBack: (() -> Void)?
    @StateObject private var product = ControlCenterModel()
    @StateObject private var trials = ManualTrialsModel()
    @State private var harnessFilter = "Tous"
    @State private var projectFilter = "Tous"
    @State private var providerFilter = "Tous"
    @State private var modelFilter = "Tous"
    @State private var comparisonID: String?
    @State private var showCodexDetails = false
    @State private var trialEditor: TrialEditorRequest?
    @State private var coverageRequest: CoverageRequest?
    @State private var showSettings = false
    @State private var keyMonitor: Any?
    @State private var now = Date()

    private let graphite = Color(nsColor: .windowBackgroundColor)
    private let sourceOrder = SourceDisplay.order

    init(dashboard: DashboardModel, initialMode: String? = nil, onBack: (() -> Void)? = nil) {
        self.dashboard = dashboard
        self.onBack = onBack
        _readingMode = State(initialValue: initialMode ??
            UserDefaults.standard.string(forKey: "readingMode") ?? "simple")
    }

    private var sessions: [UsageSession] {
        product.allSessions.filter { session in
            (projectFilter == "Tous" || (projectFilter == "Inconnu" ? session.projectPath == nil : session.projectPath == projectFilter)) &&
            (harnessFilter == "Tous" || session.harnessID == harnessFilter) &&
            (providerFilter == "Tous" || (providerFilter == "Inconnu" ? session.providerID == nil : session.providerID == providerFilter)) &&
            (modelFilter == "Tous" || (modelFilter == "Inconnu" ? session.modelID == nil : session.modelID == modelFilter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if readingMode == "simple" {
                ScrollView {
                    simplePage
                        .frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    ScrollView {
                        Group {
                            switch product.selectedSection {
                            case ProductSection.sessions.rawValue: sessionsPage
                            case ProductSection.optimizer.rawValue: optimizerPage
                            default: controlPage
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                    }
                    .id(product.selectedSection)
                }
            }
        }
        .frame(minWidth: ControlWindowGeometry.minimumSize.width, minHeight: ControlWindowGeometry.minimumSize.height)
        .background { ArqmeterGlassBackdrop() }
        .onAppear {
            product.refresh(days: readingMode == "simple" ? 7 : nil)
            trials.load()
            if readingMode != "simple" { dashboard.startLive(for: "control") }
            installKeyboardMonitor()
        }
        .onChange(of: readingMode) { mode in
            UserDefaults.standard.set(mode, forKey: "readingMode")
            product.refresh(days: mode == "simple" ? 7 : nil)
            if mode == "simple" { dashboard.stopLive(for: "control") } else { dashboard.startLive(for: "control") }
        }
        .onDisappear {
            if onBack == nil { dashboard.stopLive(for: "control") }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arqmeterHistoryUpdated)) { _ in
            product.refresh(days: readingMode == "simple" ? 7 : nil)
            trials.load()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .sheet(isPresented: $showCodexDetails) { DashboardView(model: dashboard) }
        .sheet(item: $trialEditor) { request in
            TrialEditorView(sessions: trials.sessions,
                            existing: request.existing,
                            initialBeforeID: request.initialBeforeID,
                            recommendationID: request.recommendationID,
                            onSave: { trials.save($0) },
                            onCancel: { trialEditor = nil })
        }
        .sheet(item: $coverageRequest) { request in
            SourceCoverageSheet(coverage: request.coverage, availability: request.availability,
                                dashboard: dashboard, openSessions: {
                harnessFilter = request.coverage.harnessID
                product.selectedSection = ProductSection.sessions.rawValue
                readingMode = "detailed"
                coverageRequest = nil
            })
        }
        .sheet(isPresented: $showSettings) { SourceSettingsView(preferences: sourcePreferences) }
        .modifier(ArqmeterWindowFocus())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PILOTAGE").font(.system(size: 12, weight: .semibold))
                .tracking(1.3).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(ProductSection.allCases) { section in
                Button {
                    product.selectedSection = section.rawValue
                } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.system(size: 14, weight: product.selectedSection == section.rawValue ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 13)
                        .background(product.selectedSection == section.rawValue ? InstrumentTheme.blue.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(section.shortcut, modifiers: [.command])
                .accessibilityAddTraits(product.selectedSection == section.rawValue ? [.isSelected] : [])
            }
            Spacer()
            if onBack == nil {
                Button("Retour à Simple") { readingMode = "simple" }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 184)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { windowIdentity; Spacer(); windowControls }
            VStack(alignment: .leading, spacing: 14) {
                windowIdentity
                HStack { Spacer(); windowControls }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var windowIdentity: some View {
        HStack(spacing: 18) {
            if let onBack {
                Button(action: onBack) { Label("Retour à l’aperçu", systemImage: "arrow.left") }
                    .font(.system(size: 13, weight: .medium)).buttonStyle(.bordered)
            }
            Text("ARQMETER").font(.system(size: 14, weight: .bold)).tracking(1.5)
                .foregroundStyle(InstrumentTheme.blue)
        }
        .fixedSize()
    }

    private var windowControls: some View {
        HStack(spacing: 14) {
            if onBack == nil {
                Picker("", selection: $readingMode) {
                    Text("Simple").tag("simple")
                    Text("Détaillée").tag("detailed")
                }
                .labelsHidden().accessibilityLabel("Mode de lecture")
                .pickerStyle(.segmented).frame(width: 210)
            }
            if readingMode != "simple" && product.selectedSection != ProductSection.control.rawValue {
                Picker("Historique", selection: $product.windowDays) {
                    Text("24 h").tag(1)
                    Text("7 j").tag(7)
                    Text("30 j").tag(30)
                    Text("90 j").tag(90)
                    Text("1 an").tag(365)
                }
                .frame(width: 160)
                .onChange(of: product.windowDays) { _ in product.refresh() }
            }
            Button { product.refresh(days: readingMode == "simple" ? 7 : nil) } label: { Image(systemName: "arrow.clockwise") }
                .help("Actualiser les données persistées")
                .accessibilityLabel("Actualiser")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Réglages des sources")
                .accessibilityLabel("Réglages")
        }
        .font(.system(size: 13))
    }

    private var simplePage: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mes sources").font(.system(size: 22, weight: .semibold))
                Spacer()
                Text("\(sourcePreferences.orderedVisibleIDs.count) suivies")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = product.snapshot?.error { notice(error, color: .orange) }
            if let snapshot = product.snapshot {
                VStack(spacing: 0) {
                    ForEach(Array(sourcePreferences.orderedVisibleIDs.enumerated()), id: \.element) { offset, harness in
                        if let coverage = snapshot.coverage.first(where: { $0.harnessID == harness }) {
                            Button {
                                coverageRequest = CoverageRequest(coverage: coverage,
                                    availability: snapshot.availability.first { $0.harnessID == harness })
                            } label: {
                                simpleSourceRow(coverage,
                                    availability: snapshot.availability.first { $0.harnessID == harness })
                            }
                            .buttonStyle(.plain)
                            if offset < sourcePreferences.orderedVisibleIDs.count - 1 { Divider().padding(.leading, 18) }
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                if let advice = simpleAdvice(snapshot) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Un conseil utile")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(simpleAdviceSummary(advice))
                            .font(.system(size: 15, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Voir le conseil") {
                            product.selectedRecommendationID = advice.id
                            product.selectedSection = ProductSection.optimizer.rawValue
                            readingMode = "detailed"
                        }
                        .buttonStyle(.link).font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 12))
                }
            } else if product.loading {
                ProgressView("Lecture des sources…")
            }
            Button("Voir l’activité récente") {
                product.selectedSection = ProductSection.sessions.rawValue
                readingMode = "detailed"
            }
            .buttonStyle(.link).font(.system(size: 12))
        }
    }

    private func simpleAdvice(_ snapshot: HistoricalDashboardSnapshot) -> SessionRecommendation? {
        snapshot.recommendations.first {
            !product.ignoredRecommendationIDs.contains($0.id) &&
                $0.confidence != .low && $0.severity != .info && $0.evidence.count >= 3
        }
    }

    private func simpleAdviceSummary(_ advice: SessionRecommendation) -> String {
        switch advice.type {
        case .highInputToOutput:
            return "Cette session envoie beaucoup de contexte pour ses réponses. Vérifiez ce qui peut être raccourci."
        case .contextGrowth:
            return "Le contexte grossit pendant cette session. Vérifiez les éléments répétés avant de continuer."
        case .anomalousSessionVolume:
            return "Cette session utilise plus de tokens que l’historique du même projet et modèle. Examinez ses étapes."
        default:
            return "\(advice.problem) \(advice.recommendation)"
        }
    }

    private func simpleSourceRow(_ source: HistoricalCoverage, availability: SourceAvailability?) -> some View {
        let isCodex = source.harnessID == "codex"
        let quotaFresh = ControlReadout.quota(dashboard.remainingPercent, sampledAt: dashboard.officialSampledAt,
                                              now: Date(), resetsAt: dashboard.resetsAt) != nil
        let status: String? = {
            if availability?.logRootExists == true && availability?.logRootReadable != true { return "Journaux non lisibles" }
            if availability?.installed != true { return "Outil non détecté" }
            if source.lastScan.map({ now.timeIntervalSince($0) > 300 }) ?? true { return "Collecte à vérifier" }
            if source.eventCount == 0 { return "Aucune activité récente" }
            return nil
        }()
        let needsAttention = status == "Journaux non lisibles" || status == "Collecte à vérifier"
        return HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text(SourceDisplay.name(source.harnessID)).font(.system(size: 14, weight: .medium))
                if let status {
                    Text(status).font(.system(size: 11))
                        .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if isCodex, quotaFresh, let percent = dashboard.remainingPercent {
                    Text("\(percent) % restants")
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    if let reset = dashboard.resetsAt {
                        Text("7 jours · réinit. \(reset.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if isCodex, dashboard.officialSampledAt != nil {
                    Text("Mesure périmée").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                } else {
                    Text(isCodex ? "Quota non disponible" : "Quota non fourni")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 17).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var controlPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Consommation").font(.system(size: 24, weight: .semibold, design: .rounded))
            if let error = product.snapshot?.error { notice(error, color: .orange) }
            if let snapshot = product.snapshot {
                liveConsumption
                weeklySummary
                DisclosureGroup("Sources et statistiques") {
                    sourcesPanel(snapshot).padding(.top, 12)
                }.font(.system(size: 14, weight: .medium))
                DisclosureGroup("Totaux, couverture et interprétation") {
                    activityPanel(snapshot).padding(.top, 12)
                    Button("Quota et cycles Codex") {
                        dashboard.selectedTab = .quota
                        showCodexDetails = true
                    }.buttonStyle(.link).padding(.top, 8)
                }
                .font(.system(size: 13))
            } else {
                liveConsumption
                if product.loading { ProgressView("Lecture de l’historique…") }
            }
        }
    }

    private func sourcesPanel(_ snapshot: HistoricalDashboardSnapshot) -> some View {
        let otherSources = sourceOrder.filter { $0 != "codex" }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Autres sources · \(product.windowDays) j")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            ForEach(otherSources, id: \.self) { harness in
                if let coverage = snapshot.coverage.first(where: { $0.harnessID == harness }) {
                    sourceRow(coverage, availability: snapshot.availability.first { $0.harnessID == harness })
                    if harness != otherSources.last { Divider() }
                }
            }
        }
        .panel()
    }

    private var weeklySummary: some View {
        WeeklySummaryView(model: dashboard.comparison) {
            dashboard.selectedTab = .evolution
            showCodexDetails = true
        }
    }

    private var currentConsumption: ConsumptionWindow? {
        let range = dashboard.consumptionRange
        if range.isOfficial {
            return .official(days: dashboard.comparison.archiveDays, range: range,
                             page: dashboard.consumptionPage)
        }
        guard let local = dashboard.local else { return nil }
        return .local(events: local.events, sampledAt: local.sampledAt,
                      scanComplete: local.scanComplete, range: range)
    }

    private var liveConsumption: some View {
        let range = dashboard.consumptionRange
        let window = currentConsumption
        let fresh = ControlReadout.isFresh(dashboard.local?.sampledAt, now: Date(), within: 10)
        let amount = ControlReadout.dial(window, range: range, sampledAt: dashboard.local?.sampledAt, now: Date())
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(range.isOfficial ? "Codex · compte" : "Codex · ce Mac", systemImage: "waveform.path")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(InstrumentTheme.blue)
                Spacer()
            }
            Picker("Période du cadran", selection: Binding(get: { dashboard.consumptionRange },
                set: { dashboard.setConsumptionRange($0) })) {
                ForEach(ConsumptionRange.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).accessibilityLabel("Période du cadran")
            if !range.isOfficial, fresh, window?.scanComplete == true,
               window?.nonCachedInput != nil || window?.output != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        primaryConsumption(window, range: range, amount: amount)
                            .frame(minWidth: 340, maxWidth: .infinity)
                        TokenBreakdownView(window: window, range: range, sampledAt: dashboard.local?.sampledAt)
                            .frame(minWidth: 340, maxWidth: .infinity)
                    }.frame(minWidth: 740)
                    VStack(spacing: 14) {
                        primaryConsumption(window, range: range, amount: amount)
                        TokenBreakdownView(window: window, range: range, sampledAt: dashboard.local?.sampledAt)
                    }
                }
            } else {
                primaryConsumption(window, range: range, amount: amount)
            }
            if let window, range.isOfficial || (window.scanComplete && fresh) {
                ActivitySparkline(values: window.buckets.map { $0.tokens.map(Double.init) }).frame(height: 36)
            }
            Text(range.isOfficial ? "\(window?.reportedDays ?? 0)/\(window?.calendarDays ?? range.bucketCount) jours relevés · UTC" :
                (fresh ? (window?.scanComplete == true ? "Actualisé à \(dashboard.local?.sampledAt.formatted(.dateTime.hour().minute().second()) ?? "—")" : "Lecture partielle") :
                    (dashboard.local == nil ? "Lecture locale en cours" : "Relevé périmé")))
                .font(.system(size: 13)).foregroundStyle(!range.isOfficial && !fresh && dashboard.local != nil ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            quotaReadout
        }
        .panel()
        .help("Sur 1 min à 24 h : moyenne d’événements réels, comptés à la fin des réponses, pas vitesse instantanée de génération. Entrée, cache inclus, plus sortie. Sur 7/30 j : volumes officiels du compte. Ce cadran n’est ni un quota ni une facture.")
    }

    private func primaryConsumption(_ window: ConsumptionWindow?, range: ConsumptionRange, amount: Double?) -> some View {
        HStack(spacing: 20) {
            TokenInstrument(amount: amount, unit: range.isOfficial ? "tokens" : "tokens/s",
                            periodID: "\(range.rawValue)-\(dashboard.consumptionPage)")
            VStack(alignment: .leading, spacing: 8) {
                Text(range.isOfficial ? "Volume" : "Total · cache inclus")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text(amount.map(TokenDialGeometry.label) ?? "—")
                    .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(range.isOfficial ? "tokens rapportés" : "tokens/s · moyenne")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                if !range.isOfficial {
                    Text(window?.total.map { "\(TokenDialGeometry.label(Double($0))) tokens · \(range.label)" } ?? "Total non mesuré")
                        .font(.system(size: 15, weight: .medium)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quotaReadout: some View {
        let quota = ControlReadout.quota(dashboard.remainingPercent, sampledAt: dashboard.officialSampledAt, now: Date(), resetsAt: dashboard.resetsAt)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quota hebdomadaire").font(.system(size: 13)).foregroundStyle(.secondary)
                if quota != nil, let reset = dashboard.resetsAt {
                    Text("Réinitialisation · \(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Text(quota.map { "\($0) % restants" } ??
                 (dashboard.officialSampledAt == nil ? "En attente" : "Relevé périmé"))
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(quota == nil && dashboard.officialSampledAt != nil ? Color.orange : Color.primary)
        }
    }

    private func sourceRow(_ source: HistoricalCoverage, availability: SourceAvailability?) -> some View {
        let fresh = ControlReadout.isFresh(source.lastScan, now: Date(), within: 300)
        let current = UsageAggregate(records: product.snapshot?.records.filter { $0.harnessID == source.harnessID } ?? [])
        let archived = current.records.isEmpty ? product.snapshot?.olderSourceHistory[source.harnessID] : nil
        let aggregate = archived ?? current
        let latest = aggregate.records.last?.timestamp
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label(source.harnessID)).font(.system(size: 16, weight: .semibold))
                    Text(latest.map { "\(archived == nil ? "Dernier relevé" : "Archive") · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Aucune activité observée")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if let input = aggregate.inputTokens.value {
                        Text("\(TokenDialGeometry.label(Double(input))) tokens d’entrée")
                            .font(.system(size: 16, weight: .medium)).monospacedDigit()
                    } else if let seconds = aggregate.durationSeconds {
                        Text("\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s de calcul local")
                            .font(.system(size: 16, weight: .medium)).monospacedDigit()
                    } else {
                        Text("Pas de mesure sur la période").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if availability?.logRootExists == true && availability?.logRootReadable != true {
                    Text("Accès aux journaux à vérifier").foregroundStyle(.orange)
                } else if source.lastScan != nil && !fresh {
                    Text("Lecture à actualiser").foregroundStyle(.orange)
                } else if aggregate.inputTokens.value != nil && !aggregate.inputTokens.complete {
                    Text(aggregate.inputTokens.containsEstimates ? "Inclut des estimations" : "Mesures partielles").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    coverageRequest = CoverageRequest(coverage: source, availability: availability)
                } label: { Image(systemName: "info.circle") }
                .buttonStyle(.link)
                .accessibilityLabel("Données et provenance de \(label(source.harnessID))")
                .help("Données et provenance")
            }
            .font(.system(size: 13))
        }
        .padding(.vertical, 12)
    }

    private func quotaPanel(_ snapshot: HistoricalDashboardSnapshot) -> some View {
        let quota = ControlReadout.quota(dashboard.remainingPercent, sampledAt: dashboard.officialSampledAt, now: Date(), resetsAt: dashboard.resetsAt)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Limite hebdomadaire Codex").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(quota.map { "\($0) % restants" } ?? "Relevé à vérifier")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(quota == nil && dashboard.officialSampledAt != nil ? Color.orange : Color.primary)
            }
            if quota != nil, let reset = dashboard.resetsAt {
                Text("Réinitialisation le \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(dashboard.officialSampledAt.map { "Source officielle · relevé à \($0.formatted(date: .omitted, time: .shortened))" } ?? "Source officielle en attente")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Détails Codex et cycles") { showCodexDetails = true }
                .buttonStyle(.link)
        }
        .panel()
    }

    private func activityPanel(_ snapshot: HistoricalDashboardSnapshot) -> some View {
        let aggregate = UsageAggregate(records: snapshot.records)
        return VStack(alignment: .leading, spacing: 9) {
            Text("ACTIVITÉ OBSERVÉE · \(product.windowDays) J").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(number(aggregate.inputTokens.value)) entrée · \(number(aggregate.outputTokens.value)) sortie")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text("Couverture entrée \(aggregate.inputTokens.coveredRecords)/\(aggregate.inputTokens.totalRecords) événements ; sortie \(aggregate.outputTokens.coveredRecords)/\(aggregate.outputTokens.totalRecords).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Compteurs hétérogènes : ni coût, ni quota, ni classement. Absence ≠ 0.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Explorer les sessions") { product.selectedSection = ProductSection.sessions.rawValue }
                .buttonStyle(.link)
        }
        .panel()
    }

    private func recommendationsTeaser(_ snapshot: HistoricalDashboardSnapshot) -> some View {
        let recommendations = snapshot.recommendations.filter { !product.ignoredRecommendationIDs.contains($0.id) }
        return Group {
            if let item = recommendations.first {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Une piste à examiner").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button("Voir le conseil") {
                            product.selectedRecommendationID = item.id
                            product.selectedSection = ProductSection.optimizer.rawValue
                        }.buttonStyle(.link)
                    }
                    Text(item.problem).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    Text("\(label(item.harnessID)) · piste à vérifier, pas une économie prouvée")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .panel()
            }
        }
    }

    private var sessionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            intro("Vos sessions", "Choisissez une session pour comprendre sa consommation.")
            DisclosureGroup("Filtrer · \(sessions.count) sessions dans la période") {
                filters.padding(.top, 12)
            }
            .font(.system(size: 14))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    sessionList.frame(maxWidth: .infinity, alignment: .leading)
                    sessionDetail.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 750)
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Session à examiner", selection: $product.selectedSessionID) {
                        Text("Choisir une session").tag(String?.none)
                        ForEach(sessions.prefix(150)) { session in
                            Text("\(session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace inconnu") · \(label(session.harnessID)) · \(session.lastEvent.formatted(date: .abbreviated, time: .shortened))")
                                .tag(String?.some(session.id))
                        }
                    }
                    if sessions.count > 150 { Text("150 premières sessions proposées ; resserrez les filtres.").font(.system(size: 11)).foregroundStyle(.secondary) }
                    sessionDetail
                }
            }
        }
        .onChange(of: projectFilter) { _ in selectFirstVisibleSession() }
        .onChange(of: harnessFilter) { _ in selectFirstVisibleSession() }
        .onChange(of: providerFilter) { _ in selectFirstVisibleSession() }
        .onChange(of: modelFilter) { _ in selectFirstVisibleSession() }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(sessions.count) sessions")
                Spacer()
                Text("Entrée · tokens observés")
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(16)
            Divider()
            if sessions.isEmpty { Text("Aucune session dans cette période ou ces filtres.").font(.system(size: 12)).foregroundStyle(.secondary).padding(15) }
            ForEach(Array(sessions.prefix(150))) { session in
                Button { product.selectedSessionID = session.id } label: { sessionRow(session) }
                    .buttonStyle(.plain)
                Divider()
            }
            if sessions.count > 150 { Text("150 premières sessions affichées ; resserrez les filtres.").font(.system(size: 11)).foregroundStyle(.secondary).padding(12) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    }

    private func selectFirstVisibleSession() {
        if !sessions.contains(where: { $0.id == product.selectedSessionID }) {
            product.selectedSessionID = sessions.first?.id
            comparisonID = nil
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                filterPicker("Projet", selection: $projectFilter, values: Set(product.allSessions.compactMap(\.projectPath)))
                filterPicker("Harness", selection: $harnessFilter, values: Set(product.allSessions.map(\.harnessID)))
                filterPicker("Provider", selection: $providerFilter, values: Set(product.allSessions.compactMap(\.providerID)))
                filterPicker("Modèle", selection: $modelFilter, values: Set(product.allSessions.compactMap(\.modelID)))
            }
            .frame(minWidth: 760)
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    filterPicker("Projet", selection: $projectFilter, values: Set(product.allSessions.compactMap(\.projectPath)))
                    filterPicker("Harness", selection: $harnessFilter, values: Set(product.allSessions.map(\.harnessID)))
                }
                HStack(spacing: 8) {
                    filterPicker("Provider", selection: $providerFilter, values: Set(product.allSessions.compactMap(\.providerID)))
                    filterPicker("Modèle", selection: $modelFilter, values: Set(product.allSessions.compactMap(\.modelID)))
                }
            }
        }
    }

    private func filterPicker(_ title: String, selection: Binding<String>, values: Set<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Tous").tag("Tous")
            if title != "Harness" { Text("Inconnu").tag("Inconnu") }
            ForEach(values.sorted(), id: \.self) { value in
                let display: String = title == "Projet" ?
                    "\(URL(fileURLWithPath: value).lastPathComponent) · \(URL(fileURLWithPath: value).deletingLastPathComponent().lastPathComponent)" : value
                Text(display).tag(value).help(value)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sessionRow(_ session: UsageSession) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace inconnu")
                    .font(.system(size: 14, weight: .medium))
                Text("\(label(session.harnessID)) · \(session.modelID ?? "modèle inconnu") · \(session.lastEvent.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            Text(number(session.aggregate.inputTokens.value))
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(session.aggregate.inputTokens.complete ? Color.primary : Color.secondary)
        }
        .padding(16)
        .background(product.selectedSessionID == session.id ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var sessionDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = sessions.first(where: { $0.id == product.selectedSessionID }) {
                Text(session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Projet inconnu")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("\(label(session.harnessID)) · \(session.providerID ?? "fournisseur inconnu") · \(session.modelID ?? "modèle inconnu")")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                detailLine("Période", "\(session.firstEvent.formatted(date: .abbreviated, time: .shortened)) → \(session.lastEvent.formatted(date: .abbreviated, time: .shortened))")
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    tokenMetric("Tokens d’entrée", session.aggregate.inputTokens)
                    tokenMetric("Tokens de sortie", session.aggregate.outputTokens)
                }
                DisclosureGroup("Autres mesures") {
                    VStack(alignment: .leading, spacing: 14) {
                        metricLine("Cache entrée · inclus dans l’entrée", session.aggregate.cachedInputTokens)
                        metricLine("Raisonnement", session.aggregate.reasoningTokens)
                        detailLine("Durée", session.aggregate.durationSeconds.map { String(format: "%.1f s · %d/%d événements", $0, session.aggregate.durationCoverage, session.aggregate.records.count) } ?? "Non mesurée")
                    }.padding(.top, 12)
                }
                DisclosureGroup("Provenance et événements") {
                VStack(alignment: .leading, spacing: 12) {
                detailLine("Identité", session.sessionID)
                detailLine("Workspace", session.projectPath ?? "Inconnu")
                ForEach(session.provenances, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("\(session.aggregate.records.count) événements dédupliqués. Aucun prompt n’est affiché ni conservé par cette vue.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(Array(session.aggregate.records.prefix(50)), id: \.eventID) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.system(size: 11, weight: .medium))
                            Text("Entrée \(number(event.inputTokens.value)) · sortie \(number(event.outputTokens.value)) · \(event.sourceKind.rawValue)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(event.eventID).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                    if session.aggregate.records.count > 50 {
                        Text("50 premiers événements affichés ; \(session.aggregate.records.count) au total.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)
                }
                Button("Créer un essai depuis cette session") {
                    trialEditor = TrialEditorRequest(existing: nil, initialBeforeID: session.id, recommendationID: nil)
                }
                .buttonStyle(.link)
                comparisonPicker(session)
            } else {
                Text("Sélectionnez une session pour voir mesures, couverture et provenance.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .panel()
    }

    private func comparisonPicker(_ session: UsageSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Comparaison descriptive").font(.system(size: 12, weight: .semibold))
            Picker("Comparer avec", selection: $comparisonID) {
                Text("Aucune").tag(String?.none)
                ForEach(sessions.filter { $0.id != session.id }.prefix(50)) { other in
                    Text("\(label(other.harnessID)) · \(other.modelID ?? "?") · \(other.lastEvent.formatted(date: .abbreviated, time: .shortened))")
                        .tag(String?.some(other.id))
                }
            }
            if let other = sessions.first(where: { $0.id == comparisonID }) {
                let result = SessionUsageComparison(session, other)
                detailLine("Δ entrée", result.inputDifference.map { "\($0) tokens" } ?? "Non comparable / mesure partielle")
                detailLine("Δ sortie", result.outputDifference.map { "\($0) tokens" } ?? "Non comparable / mesure partielle")
                ForEach(result.warnings, id: \.self) { Text("• \($0)").font(.system(size: 11)).foregroundStyle(.orange) }
            }
        }
    }

    private var optimizerPage: some View {
        let active = (product.snapshot?.recommendations ?? [])
            .filter { !product.ignoredRecommendationIDs.contains($0.id) }
        let recommendations = active.filter { $0.id == product.selectedRecommendationID } +
            active.filter { $0.id != product.selectedRecommendationID }
        let highlighted = recommendations.first { $0.id == product.selectedRecommendationID }
        let ignored = (product.snapshot?.recommendations ?? []).filter { product.ignoredRecommendationIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 17) {
            intro("Conseils et essais", "Une piste à tester. Un gain seulement s’il est démontré.")
            if let highlighted { recommendationCard(highlighted) }
            trialSection
            if recommendations.isEmpty { notice("Aucune piste active sur la période choisie.", color: .secondary) }
            ForEach(Array(recommendations.filter { $0.id != highlighted?.id }.prefix(30)), id: \.id) { item in
                DisclosureGroup {
                    recommendationCard(item).padding(.top, 14)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.problem).font(.system(size: 15, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(label(item.harnessID)) · \(item.evidence.count) événements · à vérifier")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                Divider()
            }
            if recommendations.count > 30 { Text("30 premières pistes affichées. Réduisez la période pour affiner.").font(.system(size: 11)).foregroundStyle(.secondary) }
            if !ignored.isEmpty {
                DisclosureGroup("Pistes ignorées (\(ignored.count))") {
                    ForEach(ignored, id: \.id) { item in
                        HStack {
                            Text(item.problem).font(.system(size: 11)).lineLimit(2)
                            Spacer()
                            Button("Réactiver") { product.restore(item.id) }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private func recommendationCard(_ item: SessionRecommendation) -> some View {
        let resolvedModel = product.allSessions.first { $0.id == "\(item.harnessID):\(item.sessionID)" }?.modelID
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(item.problem).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(severityLabel(item.severity)) · confiance \(confidenceLabel(item.confidence))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Action proposée · \(item.recommendation)").font(.system(size: 14))
            DisclosureGroup("Pourquoi ce conseil · preuves et limites") {
            VStack(alignment: .leading, spacing: 12) {
            Text("Observation · \(item.observedData)").font(.system(size: 13))
            Text("Impact estimé, non démontré · \(item.estimatedImpact)").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Limite · \(item.limitations)").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Preuves · \(item.evidence.count) événements · \(label(item.harnessID)) · \(resolvedModel ?? item.modelID ?? "modèle inconnu")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            DisclosureGroup("Identifiants de preuve") {
                ForEach(Array(item.evidence.prefix(30)), id: \.self) { eventID in
                    Text(eventID).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                if item.evidence.count > 30 { Text("\(item.evidence.count - 30) autres événements dans la session.").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            }
            .padding(.top, 12)
            }
            HStack(spacing: 15) {
                Button("Ouvrir la session") { product.openSession("\(item.harnessID):\(item.sessionID)") }
                Button("Ignorer") { product.ignore(item.id) }
                // The manual-trial action is wired to the persistent domain store below.
                if let session = product.allSessions.first(where: { $0.id == "\(item.harnessID):\(item.sessionID)" }) {
                    Button("Préparer un essai") { prepareTrial(for: session, recommendation: item) }
                }
            }
            .buttonStyle(.link)
        }
        .panel()
    }

    private func prepareTrial(for session: UsageSession, recommendation: SessionRecommendation) {
        trialEditor = TrialEditorRequest(existing: nil, initialBeforeID: session.id, recommendationID: recommendation.id)
    }

    private var trialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Essais manuels").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Nouvel essai") {
                    trialEditor = TrialEditorRequest(existing: nil, initialBeforeID: nil, recommendationID: nil)
                }
            }
            if let error = trials.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if trials.trials.isEmpty {
                Text("Aucun essai enregistré. Choisissez une session de référence, un changement et un critère vérifiable.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(trials.trials) { trial in
                let result = ManualTrialEvaluator.evaluate(trial, records: trials.records)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(trial.testedChange).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Modifier") {
                            trialEditor = TrialEditorRequest(existing: trial, initialBeforeID: nil, recommendationID: nil)
                        }
                        .buttonStyle(.link)
                    }
                    Text("\(trial.before.primary.harnessID) · \(trial.before.primary.modelID ?? "modèle inconnu") · créé le \(trial.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(result.conclusion).font(.system(size: 12))
                    DisclosureGroup("Mesures, conditions et provenance") {
                    VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(result.differences.enumerated()), id: \.offset) { _, difference in
                        Text("\(difference.metric.rawValue) · avant \(decimal(difference.before)) → après \(decimal(difference.after)) · Δ \(decimal(difference.delta)) [\(difference.scope.rawValue)]")
                            .font(.system(size: 11).monospacedDigit())
                    }
                    DisclosureGroup("Sessions liées et provenance") {
                        ForEach(Array((result.before + result.after).enumerated()), id: \.offset) { _, summary in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(summary.role?.rawValue ?? "Principale") · \(summary.reference.harnessID) · \(summary.reference.sessionID) · \(summary.eventCount) événements")
                                    .font(.system(size: 11, weight: .medium))
                                ForEach(summary.provenances, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(.secondary) }
                                ForEach(summary.limitations, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(.orange) }
                            }
                        }
                    }
                    ForEach(result.reasons, id: \.self) { reason in
                        Text("• \(reason)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    }
                    .padding(.top, 12)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .panel()
    }

    private var routingPage: some View {
        VStack(alignment: .leading, spacing: 15) {
            intro("Routing", "Recommandations uniquement ; aucune redirection automatique n’est active.")
            notice("Aucune règle de routage validée. ARQMETER ne modifie ni les configurations, ni les modèles, ni les destinations de vos outils.", color: .secondary)
            Text("Les données actuelles ne prouvent pas l’équivalence des tâches, la qualité des sorties ou les coûts complets entre providers. Les essais manuels servent d’abord à documenter ces conditions.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func intro(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metricLine(_ title: String, _ value: UsageMetricTotal) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text("\(number(value.value)) · \(value.coveredRecords)/\(value.totalRecords) \(value.containsEstimates ? "estimé" : value.complete ? "mesuré" : "partiel")")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(value.complete ? Color.primary : Color.secondary)
        }
    }

    private func tokenMetric(_ title: String, _ metric: UsageMetricTotal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(metric.value.map { TokenDialGeometry.label(Double($0)) } ?? "Non mesurés")
                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(metric.value == nil ? "Aucune donnée fournie" : metric.containsEstimates ? "Inclut des estimations" : metric.complete ? "Mesurés" : "Couverture partielle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(number(metric.value)) tokens · \(metric.coveredRecords)/\(metric.totalRecords) événements")
    }

    private func label(_ harness: String) -> String {
        switch harness {
        case "codex": return "Codex"
        case "claude-code": return "Claude Code"
        case "gemini-cli": return "Gemini CLI"
        case "ollama": return "Ollama local"
        default: return harness
        }
    }

    private func severityLabel(_ severity: RecommendationSeverity) -> String {
        switch severity { case .high: return "Priorité élevée"; case .moderate: return "À examiner"; case .info: return "Information" }
    }

    private func confidenceLabel(_ confidence: RecommendationConfidence) -> String {
        switch confidence { case .high: return "élevée"; case .medium: return "moyenne"; case .low: return "faible" }
    }

    private func number(_ value: Int64?) -> String {
        value.map { $0.formatted() } ?? "indisponible"
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [product] event in
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control),
                  let windowTitle = NSApp.keyWindow?.title,
                  windowTitle == "ARQMETER — Centre de contrôle" || windowTitle == "ARQMETER — Aperçu",
                  let key = event.charactersIgnoringModifiers?.first else { return event }
            switch key {
            case "1": product.selectedSection = ProductSection.control.rawValue
            case "2": product.selectedSection = ProductSection.sessions.rawValue
            case "3": product.selectedSection = ProductSection.optimizer.rawValue
            default: return event
            }
            return nil
        }
    }

    private func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

private struct SourceCoverageSheet: View {
    let coverage: HistoricalCoverage
    let availability: SourceAvailability?
    @ObservedObject var dashboard: DashboardModel
    let openSessions: () -> Void
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(SourceDisplay.name(coverage.harnessID)).font(.system(size: 21, weight: .semibold))
                if coverage.harnessID == "codex" {
                    let fresh = ControlReadout.quota(dashboard.remainingPercent, sampledAt: dashboard.officialSampledAt,
                                                    now: Date(), resetsAt: dashboard.resetsAt) != nil
                    Text(fresh ? dashboard.remainingPercent.map { "\($0) % de quota restants" } ?? "Quota indisponible" : "Quota officiel périmé")
                        .font(.system(size: 17, weight: .medium))
                    if let reset = dashboard.resetsAt {
                        Text("Fenêtre de 7 jours · \(fresh ? "réinitialisation" : "dernier reset annoncé") \(reset.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Quota non fourni par cette source.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("Voir ses sessions") { openSessions() }.buttonStyle(.link)
                Divider()
                Text("Collecte et couverture").font(.system(size: 14, weight: .semibold))
                Text("Période \(coverage.periodStart.formatted(date: .abbreviated, time: .shortened)) → \(coverage.periodEnd.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Installation détectée : \(availability?.installed == true ? "oui" : "non") · racine de journaux : \(availability?.logRootReadable == true ? "lisible" : availability?.logRootExists == true ? "accès refusé" : "absente")")
                    .font(.system(size: 12))
                Text(availability?.logRootPath ?? "Chemin inconnu")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Dernier scan : \(coverage.lastScan.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "inconnu") · dernier événement : \(coverage.latestEvent.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "aucun")")
                    .font(.system(size: 12))
                Divider()
                Text("Qualité des métriques · événements observés uniquement")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(CoverageMetric.allCases, id: \.self) { metric in
                    let item = coverage.metrics[metric]
                    HStack {
                        Text(metric.rawValue)
                        Spacer()
                        Text("mesurée \(item?.measured ?? 0) · dérivée \(item?.estimated ?? 0) · indisponible \(item?.unavailable ?? 0)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
                Divider()
                DisclosureGroup("Lacunes connues (\(coverage.knownGaps.count))") {
                    if coverage.knownGaps.isEmpty {
                        Text("Aucune lacune signalée. Cela ne prouve pas l’exhaustivité du compte ou des événements antérieurs à l’installation.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(coverage.knownGaps.enumerated()), id: \.offset) { _, gap in
                        Text("• \(gap)").font(.system(size: 11)).textSelection(.enabled)
                    }
                }
            }
            .padding(21)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(.regularMaterial)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

struct SourceSettingsView: View {
    @ObservedObject var preferences: SourceDisplayPreferences
    var connection: ClaudeOfficialPage = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Réglages des sources").font(.system(size: 20, weight: .semibold))
            Text("Affichez plusieurs sources et choisissez leur ordre. Vous pouvez aussi glisser leurs cartes dans l’onglet Quota.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            ForEach(preferences.orderedIDs, id: \.self) { id in
                HStack {
                    Toggle(SourceDisplay.name(id), isOn: Binding(
                        get: { preferences.visibleIDs.contains(id) },
                        set: { preferences.setVisible(id, $0) }))
                        .disabled(preferences.visibleIDs.count == 1 && preferences.visibleIDs.contains(id))
                    Spacer()
                    Button { preferences.moveStep(id, direction: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(preferences.orderedIDs.first == id)
                        .accessibilityLabel("Monter \(SourceDisplay.name(id))")
                    Button { preferences.moveStep(id, direction: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(preferences.orderedIDs.last == id)
                        .accessibilityLabel("Descendre \(SourceDisplay.name(id))")
                }
                .buttonStyle(.borderless)
            }
            Divider()
            ClaudeDesktopConnectionControls()
            ClaudeOfficialConnectionControls(connection: connection)
            Picker("Source principale des détails", selection: Binding(
                get: { preferences.primaryID },
                set: { preferences.setPrimary($0) })) {
                    ForEach(preferences.orderedVisibleIDs, id: \.self) { id in
                        Text(SourceDisplay.name(id)).tag(id)
                    }
                }
            Text("Un quota non fourni reste inconnu : il n’est jamais converti en zéro ni ajouté à celui d’une autre source.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(23)
        .frame(width: 430)
        .background(.regularMaterial)
    }
}

private extension View {
    func panel() -> some View {
        self.padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
    }
}
