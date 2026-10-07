import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ArqmeterCore

enum SourceCardDrag {
    static let type = UTType(exportedAs: "com.7agency.arqmeter.source-card")
    static func item(_ id: String) -> NSItemProvider {
        let item = NSItemProvider()
        item.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) {
            $0(Data(id.utf8), nil); return nil
        }
        return item
    }
}

struct SourceCardHandle: View {
    let id: String
    @ObservedObject var preferences: SourceDisplayPreferences
    @Binding var dragging: String?
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(InstrumentTheme.secondary)
            .frame(width: 28, height: 28).contentShape(Rectangle())
            .onDrag { dragging = id; return SourceCardDrag.item(id) }
            .help("Glisser cette carte pour la placer avant ou après une autre")
            .accessibilityLabel("Déplacer \(SourceDisplay.name(id))")
            .accessibilityAction(named: Text("Monter")) { preferences.moveStep(id, direction: -1, visibleOnly: true) }
            .accessibilityAction(named: Text("Descendre")) { preferences.moveStep(id, direction: 1, visibleOnly: true) }
    }
}

struct SourceCardDrop: DropDelegate {
    let id: String
    let height: CGFloat
    let preferences: SourceDisplayPreferences
    @Binding var dragging: String?
    @Binding var targeted: Bool
    @Binding var after: Bool
    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && dragging != id && info.hasItemsConforming(to: [SourceCardDrag.type])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        after = info.location.y >= height / 2
        return validateDrop(info: info) ? DropProposal(operation: .move) : nil
    }
    func dropExited(info: DropInfo) { targeted = false }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let source = dragging else { return false }
        preferences.move(source, relativeTo: id, after: info.location.y >= height / 2)
        dragging = nil; targeted = false
        return true
    }
}

private struct SourceDropTarget: ViewModifier {
    let id: String
    @ObservedObject var preferences: SourceDisplayPreferences
    @Binding var dragging: String?
    @State private var height: CGFloat = 100
    @State private var targeted = false
    @State private var after = false
    func body(content: Content) -> some View {
        content
            .background { GeometryReader { proxy in
                Color.clear.onAppear { height = proxy.size.height }
                    .onChange(of: proxy.size.height) { height = $0 }
            } }
            .overlay(alignment: after ? .bottom : .top) {
                if targeted { Capsule().fill(InstrumentTheme.blue).frame(height: 3).allowsHitTesting(false) }
            }
            .onDrop(of: [SourceCardDrag.type], delegate: SourceCardDrop(id: id, height: height,
                preferences: preferences, dragging: $dragging, targeted: $targeted, after: $after))
            .contextMenu {
                Button("Monter") { preferences.moveStep(id, direction: -1, visibleOnly: true) }
                    .disabled(preferences.orderedVisibleIDs.first == id)
                Button("Descendre") { preferences.moveStep(id, direction: 1, visibleOnly: true) }
                    .disabled(preferences.orderedVisibleIDs.last == id)
                Divider()
                Button("Masquer \(SourceDisplay.menuName(id))") { preferences.setVisible(id, false) }
                    .disabled(preferences.visibleIDs.count == 1)
            }
    }
}

struct ProviderQuotaCards: View {
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject var preferences: SourceDisplayPreferences
    let historical: HistoricalDashboardSnapshot?
    let claude: ClaudeQuotaReport?
    let now: Date
    var cli: ClaudeCLIQuotaReport? = nil
    @State private var dragging: String?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(preferences.orderedVisibleIDs, id: \.self) { id in
                card(id).modifier(SourceDropTarget(id: id, preferences: preferences, dragging: $dragging))
            }
        }
        .onDisappear { dragging = nil }
    }

    @ViewBuilder private func card(_ id: String) -> some View {
        let handle = AnyView(SourceCardHandle(id: id, preferences: preferences, dragging: $dragging))
        switch id {
        case "codex":
            QuotaMeterView(percent: dashboard.remainingPercent, reset: dashboard.resetsAt,
                sampledAt: dashboard.officialSampledAt, now: now, compact: true, handle: handle)
        case "claude-code":
            claudeCard(handle: handle)
        default:
            activityCard(id, handle: handle)
        }
    }

    private func claudeCard(handle: AnyView) -> some View {
        let snapshot = ClaudeMenuQuotaSnapshot.make(statusLine: claude, cli: cli, at: now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quota Claude").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                handle
            }
            if snapshot.isLastKnown {
                Label("Dernier relevé · non actualisé", systemImage: "clock")
                    .font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(ClaudeQuotaReport.Period.allCases, id: \.rawValue) { period in
                    let window = snapshot.readout?.window(period)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(period.rawValue).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(InstrumentTheme.secondary)
                        Text(window.map { "\($0.remainingPercent) %" } ?? "— %")
                            .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("restants").font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
                        if let window {
                            Text(window.resetsAt.map { "Reset \($0.formatted(.dateTime.day().month(.abbreviated).hour().minute()))" }
                                 ?? window.resetLabel ?? "")
                                .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if let readout = snapshot.readout {
                Text("\(readout.provenance) · \(readout.observedAt.formatted(.dateTime.hour().minute()))")
                    .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
            } else {
                Text(ClaudeCLIQuotaReader.shared.state)
                    .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = ClaudePlanQuotaReadout.lastKnownDescription(statusLine: claude,
                    web: nil, webSelected: false, desktop: nil, desktopSelected: false, cli: cli, at: now) {
                    Text(last).font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).glassCard()
        .help("Limites du compte connecté, pas du contexte. Source officielle et heure d’observation ; aucune réponse modèle lancée pour les interroger.")
    }

    private func activityCard(_ id: String, handle: AnyView) -> some View {
        let records = historical?.records.filter { $0.harnessID == id } ?? []
        let isOlder = records.isEmpty && historical?.olderSourceHistory[id] != nil
        let aggregate = isOlder ? historical?.olderSourceHistory[id] : UsageAggregate(records: records)
        let last = aggregate?.records.last?.timestamp
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(SourceDisplay.name(id)).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer(); handle
            }
            if let seconds = aggregate?.durationSeconds {
                Text("\(Int(seconds / 60)) min d’activité locale")
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            } else if let tokens = aggregate?.inputTokens.value {
                Text("\(TokenDialGeometry.label(Double(tokens))) tokens d’entrée")
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            } else {
                Text(historical == nil ? "Mesures en attente" : "Aucune activité observée sur 7 jours")
                    .font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
            }
            if let last {
                Text("\(isOlder ? "Historique ancien" : "7 jours observés") · dernier \(last.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Activité locale · pas un quota")
                .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
            if historical?.error != nil {
                Text("Lecture à vérifier").font(.system(size: 11)).foregroundStyle(InstrumentTheme.alert)
            }
        }
        .padding(14).glassCard()
    }
}

/// The two-second cache refresh exists only while the quota panel is displayed;
/// it does not scan providers, contact a model or add a timer to Direct.
struct LiveProviderQuotaCards: View {
    @ObservedObject var dashboard: DashboardModel
    @ObservedObject var preferences: SourceDisplayPreferences
    let historical: HistoricalDashboardSnapshot?
    @State private var report = ClaudeQuotaReport.read()
    @State private var now = Date()
    var body: some View {
        ProviderQuotaCards(dashboard: dashboard, preferences: preferences,
            historical: historical, claude: report, now: now, cli: ClaudeCLIQuotaReport.read())
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) {
                now = $0; report = ClaudeQuotaReport.read()
            }
    }
}
