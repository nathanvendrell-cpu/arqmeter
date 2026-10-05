import AppKit
import Foundation
import ArqmeterCore
import SwiftUI

enum DashboardTab: String, CaseIterable, Identifiable {
    case direct = "Direct"
    case dossiers = "Dossiers"
    case quota = "Quota"
    case evolution = "Évolution"
    var id: String { rawValue }
}

final class DashboardModel: ObservableObject {
    @Published var selectedTab: DashboardTab = .direct
    @Published var remainingPercent: Int?
    @Published var resetsAt: Date?
    @Published var officialSampledAt: Date?
    @Published var quotaHistory: [QuotaHistoryPoint] = []
    @Published var daily: [DailyTokenUsage] = []
    @Published var cycleHistory: CycleTokenHistory?
    @Published var local: LocalTokenSummary?
    @Published var consumptionRange: ConsumptionRange = .minute
    @Published var consumptionPage = 0
    @Published var selectedConsumptionBucket: Int?
    @Published var hoveredHourIndex: Int?
    @Published var isLoading = false
    @Published var isLive = false
    @Published var quotaHistoryExpanded = false
    let comparison = ComparisonModel()
    let accountTimeline = AccountTimelineModel()
    private var lastLoad: Date?
    private let scanner = LocalActivityStore()
    private let cycleReader = CycleHistoryReader()
    private let quotaHistoryStore: QuotaHistoryStore
    private let scanQueue = DispatchQueue(label: "com.7agency.arqmeter.live", qos: .utility)
    private var liveTimer: Timer?
    private var isScanning = false
    private var liveDemand = LiveReadDemand()

    init(quotaHistoryStore: QuotaHistoryStore = QuotaHistoryStore()) {
        self.quotaHistoryStore = quotaHistoryStore
        quotaHistory = quotaHistoryStore.points
    }

    func apply(snapshot: UsageSnapshot) {
        let changed = resetsAt.map { abs($0.timeIntervalSince(snapshot.resetsAt)) > 5 * 60 } ?? true
        remainingPercent = snapshot.remainingPercent
        resetsAt = snapshot.resetsAt
        officialSampledAt = snapshot.timestamp
        if quotaHistoryStore.record(snapshot) { quotaHistory = quotaHistoryStore.points }
        if changed {
            cycleHistory = nil
            lastLoad = nil
            if isLive { load() }
        }
    }

    func apply(daily: [DailyTokenUsage]) {
        self.daily = daily
        comparison.acceptOfficialDays(daily)
    }

    func setConsumptionRange(_ range: ConsumptionRange) {
        consumptionRange = range
        consumptionPage = 0
        selectedConsumptionBucket = nil
    }

    func startLive(for consumer: String = "default") {
        liveDemand.acquire(consumer)
        guard !isLive else { return }
        isLive = true
        load()
        refreshLocal()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshLocal()
            self?.load()
        }
        liveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopLive(for consumer: String = "default") {
        liveDemand.release(consumer)
        guard !liveDemand.active else { return }
        isLive = false
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func stopAllLive() {
        liveDemand.clear()
        stopLive()
    }

    private func refreshLocal() {
        guard isLive, !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let summary = self.scanner.refresh()
            DispatchQueue.main.async {
                self.isScanning = false
                if self.isLive { self.local = summary }
            }
        }
    }

    func load() {
        if let lastLoad, Date().timeIntervalSince(lastLoad) < 120 { return }
        guard !isLoading else { return }
        isLoading = true
        let reset = resetsAt
        let cycleReader = self.cycleReader
        let previousDaily = daily
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Daily data arrives from the shared official monitor. Opening a
            // window must not launch a second full account-usage request loop.
            let history = reset.map { cycleReader.read(resetAt: $0, daily: previousDaily) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.resetsAt == reset else { self.isLoading = false; self.load(); return }
                self.cycleHistory = history
                self.lastLoad = Date()
                self.isLoading = false
            }
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var sourcePreferences: SourceDisplayPreferences
    @StateObject private var sourcesModel: SourcesValidationModel
    private let providedConnection: ClaudeOfficialPage?
    @MainActor private var sourceConnection: ClaudeOfficialPage { providedConnection ?? .shared }
    @State private var showingSources = false
    @State private var showingSourceSettings = false
    @State private var now = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openDetails: (() -> Void)?
    let onWindowDrag: ((NSEvent?) -> Void)?
    private let blue = InstrumentTheme.blue
    private let cyan = InstrumentTheme.cyan
    private let violet = InstrumentTheme.violet
    private let mint = InstrumentTheme.mint
    private let muted = InstrumentTheme.secondary
    private var officialQuotaFresh: Bool {
        ControlReadout.quota(model.remainingPercent, sampledAt: model.officialSampledAt,
                             now: Date(), resetsAt: model.resetsAt) != nil
    }

    private var currentQuotaObservation: WeeklyQuotaObservation? {
        guard officialQuotaFresh, let percent = model.remainingPercent,
              let reset = model.resetsAt, let date = model.officialSampledAt else { return nil }
        return WeeklyQuotaObservation(observedAt: date, resetsAt: reset,
            remainingPercent: percent, source: "codex", limit: "weekly")
    }

    init(model: DashboardModel, openDetails: (() -> Void)? = nil,
         onWindowDrag: ((NSEvent?) -> Void)? = nil,
         sourcePreferences: SourceDisplayPreferences = .shared,
         sourcesModel: SourcesValidationModel = SourcesValidationModel(),
         sourceConnection: ClaudeOfficialPage? = nil) {
        self.model = model
        self._sourcePreferences = ObservedObject(wrappedValue: sourcePreferences)
        self._sourcesModel = StateObject(wrappedValue: sourcesModel)
        self.providedConnection = sourceConnection
        self.openDetails = openDetails
        self.onWindowDrag = onWindowDrag
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                tabBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.white.opacity(0.025))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.7) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.selectedTab {
                    case .direct:
                        sourceSummary
                        DisclosureGroup("Analyse de la période") {
                            directCard.padding(.top, 8)
                        }
                        .font(.system(size: 12, weight: .medium))
                    case .dossiers:
                        ProjectListPanel(local: model.local, now: Date())
                    case .quota:
                        LiveProviderQuotaCards(connection: sourceConnection, dashboard: model, preferences: sourcePreferences,
                            historical: sourcesModel.historical)
                        DisclosureGroup("Historique et répartition") {
                            currentCycleCard
                            cycleCard
                            AccountTimelineCard(model: model.accountTimeline,
                                                days: model.comparison.archiveDays,
                                                quotaPoints: model.quotaHistory,
                                                liveQuota: currentQuotaObservation)
                            historyCard
                        }
                        .font(.system(size: 12, weight: .medium))
                        .help("Le quota et les tokens sont deux mesures différentes, sans conversion directe.")
                    case .evolution:
                        ComparisonPanel(model: model.comparison)
                    }
                }
                .padding(12)
            }
            .id(model.selectedTab)
            HStack {
                Button("Sources et mesures") { showingSources = true }
                    .foregroundStyle(muted)
                Spacer()
                if openDetails != nil {
                    Button { openDetails?() } label: {
                        Label("Voir les détails", systemImage: "arrow.up.right.square")
                    }
                    .foregroundStyle(blue)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.white.opacity(0.025))
        }
        .frame(width: 420, height: 650)
        .background { ArqmeterGlassBackdrop() }
        .foregroundStyle(InstrumentTheme.text)
        .tint(blue)
        .sheet(isPresented: $showingSources) {
            SourcesValidationView(sourceModel: sourcesModel, codex: model.local,
                                  codexQuota: model.remainingPercent,
                                  quotaSampledAt: model.officialSampledAt)
        }
        .sheet(isPresented: $showingSourceSettings) {
            SourceSettingsView(preferences: sourcePreferences, connection: sourceConnection)
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onAppear {
            if model.selectedTab == .quota { sourcesModel.loadHistorical() }
        }
        .onChange(of: model.selectedTab) {
            if $0 == .quota { sourcesModel.loadHistorical() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arqmeterHistoryUpdated)) { _ in
            if model.selectedTab == .quota { sourcesModel.loadHistorical() }
        }
        .modifier(ArqmeterWindowFocus())
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(DashboardTab.allCases) { tab in
                let selected = model.selectedTab == tab
                Button {
                    model.selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(selected ? InstrumentTheme.text : muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white.opacity(0.17))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(.white.opacity(0.34), lineWidth: 0.7)
                                    }
                                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                            }
                        }
                }
                .buttonStyle(InstrumentButtonStyle(selected: selected))
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .arqmeterGlass(radius: 14)
        .padding(.bottom, 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.selectedTab)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ARQMETER").font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(2.2).foregroundStyle(blue)
                    Text("Activité").font(.system(size: 21, weight: .semibold, design: .rounded))
                }
                Spacer()
            }
            .overlay { ArqmeterWindowDragHandle(onDrag: onWindowDrag).help("Glisser pour déplacer la fenêtre") }
            Button { showingSourceSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(blue)
                    .frame(width: 36, height: 36)
                    .background(blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(blue.opacity(0.25), lineWidth: 0.8)
                    }
            }
            .buttonStyle(InstrumentButtonStyle())
            .help("Réglages des sources affichées")
            .accessibilityLabel("Réglages des sources")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var sourceSummary: some View {
        VStack(spacing: 0) {
            if sourcePreferences.visibleIDs.contains("codex") {
                codexGlance
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Les mesures des sources suivies sont dans les statistiques.")
                        .font(.system(size: 13)).foregroundStyle(muted)
                    Button("Choisir les sources du HUD") { showingSourceSettings = true }
                        .buttonStyle(.plain).foregroundStyle(blue)
                }
                .padding(14)
            }
        }
        .arqmeterGlass(radius: 15)
    }

    private var codexGlance: some View {
        let quotaFresh = officialQuotaFresh
        let range = model.consumptionRange
        let window = consumptionWindow
        let localFresh = ControlReadout.isFresh(model.local?.sampledAt, now: Date(), within: 10)
        let dialAmount = ControlReadout.dial(window, range: range, sampledAt: model.local?.sampledAt, now: Date())
        return VStack(alignment: .leading, spacing: 4) {
            consumptionRangePicker
            HStack(spacing: 12) {
                TokenInstrument(amount: dialAmount, unit: range.isOfficial ? "tokens" : "tokens/s",
                                periodID: "\(range.rawValue)-\(model.consumptionPage)")
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(range.isOfficial ? cyan : (localFresh && model.isLive ? mint : muted))
                            .frame(width: 5, height: 5)
                        Text("Codex")
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(blue)
                    }
                    if !range.isOfficial {
                        Text("Total · cache inclus").font(.system(size: 12)).foregroundStyle(muted)
                    }
                    Text(dialAmount.map(TokenDialGeometry.label) ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .help(range.isOfficial ? "\(window?.total?.formatted() ?? "Aucune mesure") tokens rapportés" :
                              "Débit calculé : tokens d’entrée (cache inclus) + sortie, divisés par la durée de \(range.title). Mesure dérivée des relevés réels, pas vitesse de génération instantanée.")
                    Text(range.isOfficial ? "tokens rapportés" : "tokens/s · moyenne")
                        .font(.system(size: 12)).foregroundStyle(muted)
                    if !range.isOfficial {
                        Text(window?.total.map { "\(compact($0)) tokens · \(range.label)" } ?? "Total en attente")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(InstrumentTheme.text)
                    }
                    if let window, range.isOfficial || (window.scanComplete && localFresh) {
                        ActivitySparkline(values: window.buckets.map { $0.tokens.map(Double.init) })
                            .frame(height: 18)
                        if range.isOfficial {
                            Text("\(window.reportedDays ?? 0)/\(window.calendarDays ?? range.bucketCount) jours relevés")
                                .font(.system(size: 11)).foregroundStyle(muted)
                        } else {
                            Text("Actualisé à \(model.local?.sampledAt.formatted(.dateTime.hour().minute().second()) ?? "—")")
                                .font(.system(size: 11)).foregroundStyle(muted)
                        }
                    } else {
                        Text(model.local == nil ? "Lecture locale…" :
                             (localFresh ? "Lecture locale partielle" : "Relevé local périmé"))
                            .font(.system(size: 11)).foregroundStyle(localFresh || model.local == nil ? muted : InstrumentTheme.alert)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TokenBreakdownView(window: window, range: range, sampledAt: model.local?.sampledAt)
                .padding(.top, 4)
            Text(quotaFresh ? model.remainingPercent.map { remaining in
                "Quota · \(remaining) % restants" + (model.resetsAt.map {
                    " · jusqu’au \($0.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
                } ?? "")
            } ?? "Quota non fourni" : (model.officialSampledAt == nil ? "Quota en attente" : "Quota périmé · à vérifier"))
                .font(.system(size: 12)).foregroundStyle(!quotaFresh && model.officialSampledAt != nil ? InstrumentTheme.alert : muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help("Les tokens incluent l’entrée (dont le cache) et la sortie. Sur 1 min à 24 h : événements reçus sur ce Mac, comptés à la fin des réponses. Sur 7/30 j : journées officielles du compte, pas un flux temps réel. Le quota est indépendant du cadran.")
    }

    private var consumptionRangePicker: some View {
        HStack(spacing: 4) {
            ForEach(ConsumptionRange.allCases) { choice in
                Button { model.setConsumptionRange(choice) } label: {
                    Text(choice.label)
                        .font(.system(size: 11, weight: model.consumptionRange == choice ? .bold : .medium,
                                      design: .rounded))
                        .foregroundStyle(model.consumptionRange == choice ? InstrumentTheme.text : muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(model.consumptionRange == choice ? blue.opacity(0.24) : .white.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(InstrumentButtonStyle(selected: model.consumptionRange == choice))
                .accessibilityLabel("Consommation sur \(choice.title)")
            }
        }
    }

    private var cycleCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let history = model.cycleHistory {
                sectionHeader("Fenêtre de quota", icon: "arrow.triangle.2.circlepath",
                              source: officialQuotaFresh ? model.remainingPercent.map { "\($0)% RESTANTS" } ?? "CYCLE OFFICIEL"
                                                         : "RELEVÉ ANCIEN", color: mint)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(compact(history.currentLocal))
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens sur ce Mac · cycle actuel")
                        .font(.system(size: 11)).foregroundStyle(muted.opacity(0.88))
                }
                HStack {
                    Text("Depuis le \(history.currentStart.formatted(.dateTime.day().month().hour().minute()))")
                    Spacer()
                    Text("Reset le \(history.resetAt.formatted(.dateTime.day().month().hour().minute()))")
                }
                .font(.system(size: 10)).foregroundStyle(muted.opacity(0.78))
                Rectangle().fill(.primary.opacity(0.09)).frame(height: 1)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CYCLE PRÉCÉDENT · CE MAC")
                            .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(muted.opacity(0.85))
                        Text(compact(history.previousLocal))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(history.localComplete ? "Journaux disponibles" : "Lecture partielle")
                            .font(.system(size: 9)).foregroundStyle(muted.opacity(0.78))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("COMPTE · JOURS COMPLETS")
                            .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(muted.opacity(0.85))
                        Text(history.previousAccountFullDaysTokens.map(compact) ?? "—")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(history.previousAccountFullDaysTokens == nil
                             ? "Historique indisponible"
                             : "\(history.previousAccountFullDays) jours · total partiel")
                            .font(.system(size: 9)).foregroundStyle(muted.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Les tokens et le % de quota ont des règles de calcul différentes.")
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.76))
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(mint)
                    Text(model.isLoading ? "Synchronisation de la fenêtre de quota…" : "Fenêtre de quota en attente du relevé officiel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted.opacity(0.85))
                    Spacer(minLength: 0)
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(14)
        .glassCard()
    }

    private var directCard: some View {
        let range = model.consumptionRange
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(range.isOfficial ? cyan : (model.isLive ? mint : Color.gray))
                        .frame(width: 7, height: 7)
                    Text(range.isOfficial ? "RELEVÉS DU COMPTE" :
                         (model.isLive ? "SURVEILLANCE ACTIVE" : "EN PAUSE"))
                        .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.7)
                        .foregroundStyle(range.isOfficial ? cyan : (model.isLive ? mint : Color.secondary))
                }
                Spacer()
                Text(range.isOfficial ? "Source officielle" : "Événements Codex · ce Mac")
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.8))
            }
            if !sourcePreferences.visibleIDs.contains("codex") { consumptionRangePicker }
            if range.isOfficial && model.comparison.archiveDays.isEmpty {
                placeholder("Historique officiel en attente du premier relevé.")
            } else if let window = consumptionWindow {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(range.title)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(muted)
                        if !sourcePreferences.visibleIDs.contains("codex") {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(window.total.map(compact) ?? "—")
                                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                Text(range.isOfficial ? "tokens rapportés" :
                                     (window.scanComplete ? "tokens traités" : "tokens observés · partiel"))
                                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.8))
                            }
                        }
                    }
                    Spacer(minLength: 2)
                    if let reported = window.reportedDays, let expected = window.calendarDays {
                        Text("\(reported)/\(expected) j relevés")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(cyan)
                    }
                }
                .help("\(window.total?.formatted() ?? "Aucun relevé") tokens · \(range.title)")
                if !range.isOfficial {
                    HStack(spacing: 7) {
                        metric("Entrée hors cache", value: window.nonCachedInput, color: mint)
                        metric("Entrée cache", value: window.cachedInput, color: cyan)
                        metric("Sortie", value: window.output, color: violet)
                    }
                } else {
                    officialConsumptionNavigation(window)
                }
                consumptionGraph(window, range: range)
                Text(range.isOfficial
                     ? "Compte entier · jours UTC. Les jours sans relevé ne valent pas zéro."
                       + (model.consumptionPage == 0 ? " Aujourd’hui est en cours." : "")
                     : "Ce Mac uniquement · tokens comptés à la fin de chaque réponse, pas pendant sa génération."
                       + (window.scanComplete ? "" : " Lecture locale incomplète."))
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if range.isOfficial {
                        Text(model.comparison.lastOfficialRead.map {
                            "Lu le \($0.formatted(.dateTime.day().month().hour().minute()))"
                        } ?? "Relevé officiel non daté")
                    } else {
                        Text(model.local?.lastActivity.map {
                            "Dernier événement à \($0.formatted(.dateTime.hour().minute().second()))"
                        } ?? "Aucun événement récent")
                    }
                    Spacer()
                    Text(range.isOfficial ? "Jours UTC" :
                         "Lu à \(model.local?.sampledAt.formatted(.dateTime.hour().minute().second()) ?? "—")")
                }
                .font(.system(size: 9)).foregroundStyle(muted.opacity(0.67))
            } else {
                placeholder("Lecture des sessions locales…")
            }
        }
        .padding(14)
        .glassCard()
    }

    private var consumptionWindow: ConsumptionWindow? {
        let range = model.consumptionRange
        if range.isOfficial {
            return .official(days: model.comparison.archiveDays, range: range,
                             page: model.consumptionPage)
        }
        guard let local = model.local else { return nil }
        return .local(events: local.events, sampledAt: local.sampledAt,
                      scanComplete: local.scanComplete, range: range)
    }

    private func officialConsumptionNavigation(_ window: ConsumptionWindow) -> some View {
        let oldest = model.comparison.archiveDays.first?.day
        let canGoOlder = oldest.map { $0 < UTCDay.string(window.start) } ?? false
        return HStack(spacing: 9) {
            Button {
                model.consumptionPage += 1
                model.selectedConsumptionBucket = nil
            } label: { Image(systemName: "chevron.left") }
                .disabled(!canGoOlder)
                .accessibilityLabel("Voir les \(model.consumptionRange.label) précédents")
            Spacer()
            Text("\(consumptionDate(window.start, official: true)) – \(consumptionDate(window.end.addingTimeInterval(-24 * 60 * 60), official: true))")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
            Spacer()
            Button {
                model.consumptionPage = max(0, model.consumptionPage - 1)
                model.selectedConsumptionBucket = nil
            } label: { Image(systemName: "chevron.right") }
                .disabled(model.consumptionPage == 0)
                .accessibilityLabel("Voir les \(model.consumptionRange.label) suivants")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(muted)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Dernières consommations", icon: "clock.arrow.circlepath", source: "PAR RÉPONSE", color: violet)
            if let local = model.local {
                if local.recent.isEmpty {
                    placeholder("Aucun événement dans les dernières 24 h")
                } else {
                    ForEach(Array(local.recent.prefix(6).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Text(event.date.formatted(.dateTime.hour().minute().second()))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted.opacity(0.75))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.project).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text("Entrée \(compact(event.input)) · Sortie \(compact(event.output)) · Cache \(event.cachedObserved ? compact(event.cached) : "—")")
                                    .font(.system(size: 9)).foregroundStyle(muted.opacity(0.75)).lineLimit(1)
                            }
                            Spacer(minLength: 3)
                            Text(compact(event.total))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(violet)
                        }
                        .help("\(event.project)\(event.projectPath.isEmpty ? "" : "\n\(event.projectPath)")\n\(event.date.formatted()) · \(event.total.formatted()) tokens")
                        if event.session != local.recent.prefix(6).last?.session || event.date != local.recent.prefix(6).last?.date {
                            Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
                        }
                    }
                }
                Text("La valeur augmente à la fin d’une réponse Codex, pas token par token pendant sa génération.")
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                placeholder("Chargement…")
            }
        }
        .padding(16)
        .glassCard()
    }

    private var quotaCard: some View {
        QuotaMeterView(percent: model.remainingPercent, reset: model.resetsAt,
                       sampledAt: model.officialSampledAt, now: Date())
    }

    private var currentCycleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ce cycle sur ce Mac", systemImage: "desktopcomputer")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            if let history = model.cycleHistory {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(compact(history.currentLocal))
                        .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("tokens traités").font(.system(size: 12)).foregroundStyle(muted)
                }
                Text("Depuis le \(history.currentStart.formatted(.dateTime.day().month(.abbreviated))) · cache inclus")
                    .font(.system(size: 12)).foregroundStyle(muted)
                if !history.localComplete {
                    Label("Lecture partielle", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(InstrumentTheme.alert)
                }
            } else {
                Text("Lecture du cycle en cours…").font(.system(size: 12)).foregroundStyle(muted)
            }
        }
        .padding(16).glassCard()
        .help("Volume observé localement, pas un quota. Les tokens ne se convertissent pas directement en pourcentage d’abonnement.")
    }

    private var quotaUnavailableCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(cyan)
                .frame(width: 38, height: 38)
                .background(cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Quota officiel indisponible ou ancien")
                    .font(.system(size: 12, weight: .semibold))
                Text("ARQMETER réessaie automatiquement. Les tokens restent consultables ci-dessous.")
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassCard()
    }

    private var historyCard: some View {
        let points = model.quotaHistory
        let limit = model.quotaHistoryExpanded ? 6 : 2
        return VStack(alignment: .leading, spacing: 11) {
            sectionHeader("Variations du quota", icon: "point.3.connected.trianglepath.dotted",
                          source: "RELEVÉS OFFICIELS", color: blue)
            if points.isEmpty {
                placeholder("L’historique commencera au premier relevé officiel.")
            } else {
                ForEach(Array(points.indices.suffix(limit).reversed()), id: \.self) { index in
                    let point = points[index]
                    let previous = index > 0 ? points[index - 1] : nil
                    let sameCycle = previous.map { abs(point.resetsAt.timeIntervalSince($0.resetsAt)) <= 5 * 60 } ?? false
                    let delta = previous.map { point.remainingPercent - $0.remainingPercent } ?? 0
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(!sameCycle ? mint : (delta < 0 ? violet : blue))
                            .frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(point.date.formatted(.dateTime.day().month().hour().minute()))
                                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                Spacer()
                                Text(!sameCycle ? (previous == nil ? "Premier relevé" : "Nouveau cycle")
                                     : "\(delta > 0 ? "+" : "")\(delta) pt")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(!sameCycle ? mint : (delta < 0 ? violet : blue))
                            }
                            Text(previous.map { "\($0.remainingPercent)% → \(point.remainingPercent)% restants" }
                                 ?? "\(point.remainingPercent)% restants")
                                .font(.system(size: 10)).foregroundStyle(muted.opacity(0.84))
                            if sameCycle, let previous {
                                if let tokens = model.local?.tokens(between: previous.date, and: point.date) {
                                    Text("Même intervalle · ce Mac : \(compact(tokens)) tokens, cache inclus")
                                        .help("\(tokens.formatted()) tokens locaux entre les deux relevés ; aucune attribution causale")
                                } else {
                                    Text("Activité locale de cet intervalle indisponible")
                                }
                            }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(muted.opacity(0.73))
                    }
                    if index != points.indices.suffix(limit).first {
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.7)
                    }
                }
                if points.count > 2 {
                    Button(model.quotaHistoryExpanded ? "Réduire" : "Voir les \(min(6, points.count)) derniers relevés") {
                        model.quotaHistoryExpanded.toggle()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(InstrumentButtonStyle())
                    .foregroundStyle(blue)
                    .accessibilityLabel(model.quotaHistoryExpanded
                        ? "Réduire les variations du quota" : "Afficher plus de variations du quota")
                }
                Text("Historique enregistré depuis le \(points[0].date.formatted(.dateTime.day().month().year().hour().minute())). Une coïncidence temporelle ne prouve pas la cause d’une variation.")
                    .font(.system(size: 9)).foregroundStyle(muted.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .glassCard()
    }

    private var localOverviewCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeader("Activité par dossier", icon: "folder.fill", source: "LOCAL · 24 H", color: violet)
            if let local = model.local {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(compact(local.total)).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("tokens · cache inclus").font(.system(size: 11)).foregroundStyle(muted.opacity(0.83))
                    Spacer()
                    Text("\(local.byProject.count) dossiers")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(violet)
                }
                .help("\(local.total.formatted()) tokens locaux")
                HStack(spacing: 8) {
                    metric("Entrée", value: local.input, color: blue)
                    metric("Sortie", value: local.output, color: violet)
                    metric("Dont cache", value: local.cacheComplete ? local.cachedInput : nil, color: cyan)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Rythme horaire").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let peak = local.byHour.max(by: { $0.1 < $1.1 }), peak.1 > 0 {
                            Text("Pic \(peak.0.formatted(.dateTime.hour())) · \(compact(peak.1))")
                                .font(.system(size: 10)).foregroundStyle(muted.opacity(0.76))
                        }
                    }
                    activityGraph(local.byHour, leftLabel: "-24 h", middleLabel: "-12 h",
                                  hoveredIndex: Binding(get: { model.hoveredHourIndex },
                                                        set: { model.hoveredHourIndex = $0 }))
                }
            } else {
                placeholder("Analyse des sessions locales…")
            }
        }
        .padding(16)
        .glassCard()
    }

    private var projectListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Détail des dossiers", icon: "square.stack.3d.up", source: "PART DU TOTAL", color: violet)
            if let local = model.local {
                if local.byProject.isEmpty {
                    placeholder("Aucune activité récente")
                } else {
                    ForEach(Array(local.byProject.enumerated()), id: \.offset) { _, project in
                        projectRow(project, total: local.total)
                    }
                }
                Text("Nom dérivé du dossier de travail de la session ; il peut différer du nom du projet.")
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                placeholder("Analyse des sessions locales…")
            }
        }
        .padding(16)
        .glassCard()
    }

    private var resetLabel: String {
        guard let date = model.resetsAt else { return "Indisponible" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func sectionHeader(_ title: String, icon: String, source: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            sourceBadge(source, color: color)
        }
    }

    private func sourceBadge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.15), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.27), lineWidth: 0.7) }
    }

    private func metric(_ title: String, value: Int64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(.system(size: 11)).foregroundStyle(muted)
            }
            Text(value.map(compact) ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.11), lineWidth: 0.7)
        }
        .help(value.map { "\(title) : \($0.formatted()) tokens" } ?? "\(title) : donnée indisponible")
    }

    private func consumptionGraph(_ window: ConsumptionWindow,
                                  range: ConsumptionRange) -> some View {
        let peak = window.buckets.compactMap(\.tokens).max()
        let maximum = max(Int64(1), peak ?? 1)
        let selected = model.selectedConsumptionBucket
        return VStack(spacing: 8) {
            HStack {
                Text("Pic \(peak.map(compact) ?? "—")")
                Spacer()
                Text(range.bucketLabel)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(muted)

            HStack(alignment: .bottom, spacing: range == .month || range == .hour ? 3 : 5) {
                ForEach(Array(window.buckets.enumerated()), id: \.offset) { index, bucket in
                    Button { model.selectedConsumptionBucket = index } label: {
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if let tokens = bucket.tokens {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(tokens == 0 ? Color.white.opacity(0.20) :
                                              (selected == index ? cyan : blue))
                                        .frame(height: tokens == 0 ? 2 :
                                               max(4, (geometry.size.height - 3) *
                                                   CGFloat(tokens) / CGFloat(maximum)))
                                } else {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(muted.opacity(0.44),
                                                      style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                        .frame(height: 9)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(InstrumentButtonStyle(selected: selected == index))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(consumptionBucketLabel(bucket, range: range)) : \(bucket.tokens.map { "\($0.formatted()) tokens" } ?? "aucun relevé")")
                    .help("\(consumptionBucketLabel(bucket, range: range)) · \(bucket.tokens.map { "\($0.formatted()) tokens" } ?? "aucun relevé")")
                }
            }
            .frame(height: 93)

            if let selected, window.buckets.indices.contains(selected) {
                let bucket = window.buckets[selected]
                HStack(spacing: 5) {
                    Text(consumptionBucketLabel(bucket, range: range))
                    Spacer(minLength: 2)
                    Text(bucket.tokens.map { "\($0.formatted()) tokens" } ?? "Pas de relevé")
                        .fontWeight(.semibold)
                        .foregroundStyle(InstrumentTheme.text)
                }
                .font(.system(size: 10)).foregroundStyle(muted)
            } else {
                HStack {
                    Text(consumptionDate(window.start, range: range))
                    Spacer()
                    Text(consumptionDate(window.start.addingTimeInterval(
                        window.end.timeIntervalSince(window.start) / 2), range: range))
                    Spacer()
                    Text(range.isOfficial ?
                         consumptionDate(window.end.addingTimeInterval(-24 * 60 * 60), range: range) :
                         "maintenant")
                }
                .font(.system(size: 10)).foregroundStyle(muted)
            }
        }
        .padding(11)
        .background(.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.10), lineWidth: 0.7)
        }
    }

    private func consumptionBucketLabel(_ bucket: ConsumptionBucket,
                                        range: ConsumptionRange) -> String {
        if range.isOfficial { return consumptionDate(bucket.start, range: range) }
        let sameDay = Calendar.current.isDate(bucket.start, inSameDayAs: bucket.end)
        let start = localBucketDate(bucket.start, includeDay: range == .day || !sameDay)
        let end = localBucketDate(bucket.end, includeDay: !sameDay)
        return "\(start) – \(end)"
    }

    private func localBucketDate(_ date: Date, includeDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = .current
        formatter.dateFormat = includeDay ? "d MMM HH:mm:ss" : "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func consumptionDate(_ date: Date, range: ConsumptionRange) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = range.isOfficial ? TimeZone(secondsFromGMT: 0) : .current
        switch range {
        case .minute: formatter.dateFormat = "HH:mm:ss"
        case .tenMinutes, .hour: formatter.dateFormat = "HH:mm"
        case .day: formatter.dateFormat = "d MMM HH:mm"
        case .week, .month: formatter.dateFormat = "d MMM yy"
        }
        return formatter.string(from: date)
    }

    private func consumptionDate(_ date: Date, official: Bool) -> String {
        consumptionDate(date, range: official ? .week : .day)
    }

    private func activityGraph(_ points: [(Date, Int64)], leftLabel: String, middleLabel: String,
                               hoveredIndex: Binding<Int?>) -> some View {
        let maximum = max(1, points.map(\.1).max() ?? 1)
        return VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack {
                    ForEach(1..<4, id: \.self) { level in
                        Path { path in
                            let y = geometry.size.height * CGFloat(level) / 4
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(.white.opacity(0.09), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                    }
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height))
                        for (index, point) in points.enumerated() {
                            let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, points.count - 1))
                            let y = geometry.size.height - 5 - (geometry.size.height - 10) * CGFloat(point.1) / CGFloat(maximum)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [violet.opacity(0.30), blue.opacity(0.14), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in
                        for (index, point) in points.enumerated() {
                            let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, points.count - 1))
                            let y = geometry.size.height - 5 - (geometry.size.height - 10) * CGFloat(point.1) / CGFloat(maximum)
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(LinearGradient(colors: [blue, violet], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        Circle().fill(violet).frame(width: 6, height: 6)
                            .position(x: geometry.size.width,
                                      y: geometry.size.height - 5 - (geometry.size.height - 10) * CGFloat(last.1) / CGFloat(maximum))
                    }
                    if let index = hoveredIndex.wrappedValue, points.indices.contains(index) {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, points.count - 1))
                        let y = geometry.size.height - 5 - (geometry.size.height - 10) * CGFloat(points[index].1) / CGFloat(maximum)
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(InstrumentTheme.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        Circle().fill(InstrumentTheme.text).frame(width: 8, height: 8).position(x: x, y: y)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let ratio = max(0, min(1, location.x / max(1, geometry.size.width)))
                        hoveredIndex.wrappedValue = Int((ratio * CGFloat(max(0, points.count - 1))).rounded())
                    case .ended:
                        hoveredIndex.wrappedValue = nil
                    }
                }
            }
            .frame(height: 58)
            Group {
                if let index = hoveredIndex.wrappedValue, points.indices.contains(index) {
                    HStack {
                        Text(points[index].0.formatted(.dateTime.day().month().hour().minute()))
                        Spacer()
                        Text("\(points[index].1.formatted()) tokens")
                            .fontWeight(.semibold).foregroundStyle(InstrumentTheme.text)
                    }
                } else {
                    HStack {
                        Text(leftLabel)
                        Spacer()
                        Text(middleLabel)
                        Spacer()
                        Text("maintenant")
                    }
                }
            }
            .font(.system(size: 9)).foregroundStyle(muted.opacity(0.78))
        }
        .padding(10)
        .background(.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.10), lineWidth: 0.7)
        }
    }

    private func projectRow(_ project: LocalProjectUsage, total: Int64) -> some View {
        let share = total > 0 ? Double(project.total) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(project.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Int((share * 100).rounded()))%")
                    .foregroundStyle(violet)
                Text(compact(project.total)).foregroundStyle(muted.opacity(0.83))
            }
            .font(.system(size: 11)).monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(violet.opacity(0.11))
                    Capsule().fill(LinearGradient(colors: [blue, violet], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * share)
                }
            }
            .frame(height: 4)
            HStack(spacing: 6) {
                Text("E \(compact(project.input))")
                Text("S \(compact(project.output))")
                Text(project.cacheComplete ? "Cache \(compact(project.cached))" : "Cache —")
                Spacer()
                Text(project.lastActivity.formatted(.dateTime.hour().minute()))
            }
            .font(.system(size: 9)).foregroundStyle(muted.opacity(0.77))
        }
        .padding(.vertical, 5)
        .help("\(project.name)\(project.path.isEmpty ? "" : "\n\(project.path)")\n\(project.total.formatted()) tokens locaux · dernière activité \(project.lastActivity.formatted())")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(muted.opacity(0.82))
            .frame(maxWidth: .infinity, minHeight: 46)
    }

    private func compact(_ value: Int64) -> String {
        let number = Double(value)
        let french = Locale(identifier: "fr_FR")
        if value >= 1_000_000_000 {
            return "\((number / 1_000_000_000).formatted(.number.precision(.fractionLength(2)).locale(french))) Md"
        }
        if value >= 1_000_000 {
            return "\((number / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(french))) M"
        }
        if value >= 10_000 {
            return "\((number / 1_000).formatted(.number.precision(.fractionLength(0)).locale(french))) k"
        }
        if value >= 1_000 {
            return "\((number / 1_000).formatted(.number.precision(.fractionLength(1)).locale(french))) k"
        }
        return value.formatted()
    }
}

// Same measured window and scale policy as the main dial; no new ingestion.
struct TokenBreakdownView: View {
    let window: ConsumptionWindow?
    let range: ConsumptionRange
    let sampledAt: Date?

    var body: some View {
        let input = ControlReadout.componentRate(window?.nonCachedInput, window: window,
            range: range, sampledAt: sampledAt, now: Date())
        let output = ControlReadout.componentRate(window?.output, window: window,
            range: range, sampledAt: sampledAt, now: Date())
        if input != nil || output != nil {
            HStack(alignment: .top, spacing: 12) {
                if let input {
                    component("Entrée hors cache", amount: input, total: window?.nonCachedInput, id: "input")
                }
                if let output {
                    component("Sortie", amount: output, total: window?.output, id: "output")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    private func component(_ title: String, amount: Double, total: Int64?, id: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
            TokenInstrument(amount: amount, unit: "tokens/s", periodID: "\(id)-\(range.rawValue)")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(TokenDialGeometry.label(amount))
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("tokens/s").font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
            }
            if let total {
                Text("\(TokenDialGeometry.label(Double(total))) tokens")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(InstrumentTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .help("\(title) · débit moyen sur \(range.label), dérivé des réponses terminées sur ce Mac. Le total traité inclut aussi l’entrée en cache.")
    }
}

struct WeeklySummaryView: View {
    @ObservedObject var model: ComparisonModel
    let openComparison: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Semaine après semaine", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 6)
                Button("Comparer", action: openComparison).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(InstrumentTheme.blue)
            }
            if let comparison = model.latestWeeklyComparison {
                let readout = WeeklyReadout.make(comparison)
                let maximum = max(Int64(1), comparison.before.tokens, comparison.after.tokens)
                HStack(alignment: .bottom, spacing: 12) {
                    period(comparison.before, maximum: maximum, color: InstrumentTheme.blue)
                    period(comparison.after, maximum: maximum, color: InstrumentTheme.violet)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let change = readout.change {
                            Text(percent(change))
                                .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(readout.reductionPerWorkUnit ? InstrumentTheme.mint : InstrumentTheme.text)
                            Text(readout.basis).font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("À comparer").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(InstrumentTheme.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Text(readout.note).font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("En attente de deux semaines terminées")
                    .font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
            }
        }
        .padding(12).glassCard()
        .help("Un écart de volume n’est pas un gain de workflow. Le rendement par tâche nécessite des semaines complètes, le même abonnement et une charge annotée comparable ; ce n’est pas une preuve causale.")
    }

    private func period(_ period: ComparisonPeriod, maximum: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(period.title.components(separatedBy: " · ").first ?? period.title)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(InstrumentTheme.secondary)
            Text(TokenDialGeometry.label(Double(period.tokens)))
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(3, geometry.size.width * CGFloat(period.tokens) / CGFloat(maximum)))
            }
            .frame(height: 4).background(.white.opacity(0.10), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(period.title) · \(period.tokens.formatted()) tokens · \(period.tier.label)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(period.title), \(period.tokens.formatted()) tokens, \(period.tier.label)")
    }

    private func percent(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR")))
        return "\(value > 0 ? "+" : "")\(number) %"
    }
}

private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(ArqmeterGlassSurface())
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}
