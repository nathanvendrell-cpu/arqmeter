import AppKit
import SwiftUI
import Charts
import ArqmeterCore

enum AnalysisSource: String, CaseIterable, Identifiable {
    case account = "Codex · compte", codex = "Codex · ce Mac", claude = "Claude Code · ce Mac"
    case gemini = "Gemini CLI · ce Mac", ollama = "Ollama · local"
    var id: String { rawValue }
    var harness: String {
        switch self { case .account, .codex: return "codex"; case .claude: return "claude-code"
        case .gemini: return "gemini-cli"; case .ollama: return "ollama" }
    }
    var metrics: [DailyAnalysisMetric] {
        self == .account ? [.total] : self == .ollama ? [.duration] : [.total, .uncached, .output, .cache]
    }
}

/// Holds prepared chart rows. Live HUD updates do not reaggregate thousands of
/// records on the main thread. Reads only the selected harness/calendar period.
@MainActor final class DailyAnalysisModel: ObservableObject {
    @Published var source: AnalysisSource = .account
    @Published var metric: DailyAnalysisMetric = .total
    @Published var period: DailyAnalysisPeriod = .week
    @Published var page = 0
    @Published var project = ""
    @Published var selectedDay: Date?
    @Published private(set) var window: DailyAnalysisWindow?
    @Published private(set) var projects: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var rows: [UnifiedUsageRecord] = []
    private var days: [ArchivedDailyTokens] = []
    private var now = Date()
    private var request = 0
    let renderOnly: Bool
    private let read: (String, Date, Date, @escaping ([UnifiedUsageRecord], String?) -> Void) -> Void
    init(renderOnly: Bool = false, read: @escaping (String, Date, Date, @escaping ([UnifiedUsageRecord], String?) -> Void) -> Void = {
        HistoricalUsageService.shared.analysisRecords(harness: $0, from: $1, to: $2, completion: $3)
    }) { self.renderOnly = renderOnly; self.read = read }

    func refresh(days: [ArchivedDailyTokens], at date: Date = Date()) {
        guard !renderOnly else { return }
        request += 1
        let token = request
        self.days = days; now = date; error = nil
        if !source.metrics.contains(metric) { metric = source.metrics[0] }
        if source == .account {
            rows = []; projects = []; project = ""; loading = false
            prepare(); return
        }
        loading = true
        window = nil // Never show the preceding source's values under a new label.
        let bounds = period.bounds(at: now, page: page, calendar: .current)
        read(source.harness, bounds.start, min(bounds.end, now)) { [weak self] rows, error in
            guard let self, token == self.request else { return }
            self.rows = rows; self.error = error; self.loading = false
            self.projects = Array(Set(rows.compactMap(\.projectPath))).sorted()
            if !self.projects.contains(self.project) { self.project = "" }
            self.prepare()
        }
    }
    func prepare() {
        if source == .account {
            window = .official(days: days.compactMap { value in
                UTCDay.date(value.day).map { ($0, value.tokens) }
            }, period: period, page: page, at: now)
        } else {
            window = .local(records: rows, harness: source.harness, project: project.isEmpty ? nil : project,
                metric: metric, period: period, page: page, at: now)
        }
        if !((window?.buckets.contains { $0.start == selectedDay }) ?? false) { selectedDay = nil }
    }
    func loadForRender(days: [ArchivedDailyTokens], rows: [UnifiedUsageRecord] = [], at date: Date) {
        guard renderOnly else { return }
        self.days = days; self.rows = rows; now = date
        projects = Array(Set(rows.compactMap(\.projectPath))).sorted(); prepare()
    }
}

struct DailyAnalysisPanel: View {
    @ObservedObject var comparison: ComparisonModel
    @StateObject private var model: DailyAnalysisModel
    @State private var showingDayTable = false
    init(comparison: ComparisonModel, model: DailyAnalysisModel? = nil) {
        self.comparison = comparison
        _model = StateObject(wrappedValue: model ?? DailyAnalysisModel())
    }
    private var selected: DailyAnalysisBucket? {
        model.window?.buckets.first { $0.start == model.selectedDay }
            ?? model.window?.buckets.first { $0.isToday }
            ?? model.window?.buckets.last { !$0.isFuture }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourcePicker; Spacer(minLength: 8); periodPicker }
                VStack(alignment: .leading, spacing: 12) { sourcePicker; periodPicker }
            }
            HStack(spacing: 12) {
                Button { model.page += 1; model.selectedDay = nil; refresh() } label: { Image(systemName: "chevron.left") }
                    .help("Période précédente").accessibilityLabel("Période précédente")
                Text(periodTitle).font(.system(size: 16, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.page = max(0, model.page - 1); model.selectedDay = nil; refresh() } label: { Image(systemName: "chevron.right") }
                    .disabled(model.page == 0).help("Période suivante").accessibilityLabel("Période suivante")
                Spacer(minLength: 4)
                if model.page > 0 {
                    Button(model.period == .week ? "Cette semaine" : "Ce mois") {
                        model.page = 0; model.selectedDay = nil; refresh()
                    }.buttonStyle(.link)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            if model.loading {
                ProgressView("Lecture de la période…").frame(maxWidth: .infinity, minHeight: 230)
            } else if let window = model.window {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 20) { periodTotal(window); Spacer(); metricPicker }
                    VStack(alignment: .leading, spacing: 10) { periodTotal(window); metricPicker }
                }
                Text(model.source == .account ? "Volumes quotidiens officiels Codex, pas un pourcentage de quota." : model.metric.definition)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if window.observedDays > 0 {
                    dayChart(window)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 25)).foregroundStyle(.secondary)
                        Text("Aucun relevé pour cette période").font(.system(size: 15, weight: .medium))
                        Text(model.source == .account ? "Choisissez une période précédente ou les mesures de ce Mac." :
                            "Les archives d’autres périodes ne sont pas comptées ici.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 170)
                }
                if let selected { dayDetail(selected, in: window) }
                HStack(alignment: .top, spacing: 12) {
                    Text(model.source == .account ? "Compte entier · jours UTC" : "Ce Mac · jours \(window.timeZone.identifier)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(window.observedDays)/\(window.elapsedDays) jours avec une mesure")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if model.source == .account, let read = comparison.lastOfficialRead {
                    Text("Relevé du compte : \(read.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                DisclosureGroup("Valeurs par jour", isExpanded: $showingDayTable) {
                    VStack(spacing: 0) {
                        ForEach(window.buckets) { bucket in
                            HStack {
                                Text(dayTitle(bucket.start, in: window)).font(.system(size: 13))
                                Spacer()
                                Text(bucket.value.map { exact($0, metric: window.metric) } ?? (bucket.isFuture ? "À venir" : "Sans relevé"))
                                    .font(.system(size: 13)).monospacedDigit()
                                if bucket.metricIsPartial { Text("partiel").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }.padding(.vertical, 7)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 13, weight: .medium))
            }
        }
        .padding(20).glassCard()
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .arqmeterHistoryUpdated)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .arqmeterAnalysisRefreshRequested)) { _ in refresh() }
        .onChange(of: comparison.archiveDays) { _ in refresh() }
    }
    private var sourcePicker: some View {
        Picker("Source", selection: Binding(get: { model.source }, set: {
            model.source = $0; model.project = ""; model.selectedDay = nil; refresh()
        })) { ForEach(AnalysisSource.allCases) { Text($0.rawValue).tag($0) } }
            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Source des métriques quotidiennes")
    }
    private var periodPicker: some View {
        Picker("Période", selection: Binding(get: { model.period }, set: {
            model.period = $0; model.page = 0; model.selectedDay = nil; refresh()
        })) { ForEach(DailyAnalysisPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            .labelsHidden().pickerStyle(.segmented).frame(width: 170)
            .accessibilityLabel("Semaine ou mois de l’analyse")
    }
    private var metricPicker: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if model.source.metrics.count > 1 {
                Picker("Mesure", selection: Binding(get: { model.metric }, set: { model.metric = $0; model.prepare() })) {
                    ForEach(model.source.metrics, id: \.self) { Text($0.rawValue).tag($0) }
                }.font(.system(size: 13)).accessibilityLabel("Mesure à analyser")
            }
            if model.source != .account && !model.projects.isEmpty {
                Picker("Dossier", selection: Binding(get: { model.project }, set: { model.project = $0; model.prepare() })) {
                    Text("Tous les dossiers").tag("")
                    ForEach(model.projects, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path).help(path)
                    }
                }.font(.system(size: 13)).accessibilityLabel("Dossier de travail observé dans les événements locaux")
            }
        }
    }
    private func periodTotal(_ window: DailyAnalysisWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(window.total.map(TokenDialGeometry.label) ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(window.metric.unit).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Text("\(model.metric.rawValue) · \(window.isOpenPeriod ? "période en cours" : "période passée")" +
                 (window.metricIsPartial || window.observedDays < window.elapsedDays ? " · relevés partiels" : ""))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.help(model.source == .account ? "Somme des volumes quotidiens officiels disponibles, pas du quota. Les jours non fournis ne sont pas des zéros." : model.metric.definition)
    }
    private func dayChart(_ window: DailyAnalysisWindow) -> some View {
        Chart {
            ForEach(window.buckets) { bucket in
                if let value = bucket.value {
                    BarMark(x: .value("Jour", bucket.start, unit: .day), y: .value(window.metric.unit, value))
                        .foregroundStyle(InstrumentTheme.blue.opacity(bucket.isToday ? 0.55 : 0.85))
                        .cornerRadius(4)
                        .annotation(position: .top) {
                            if model.period == .week {
                                Text(TokenDialGeometry.label(value)).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(InstrumentTheme.text)
                            }
                        }
                        .accessibilityLabel(dayTitle(bucket.start, in: window))
                        .accessibilityValue(exact(value, metric: window.metric) + (bucket.metricIsPartial ? ", partiel" : ""))
                }
            }
            if let selected {
                RuleMark(x: .value("Jour choisi", selected.start.addingTimeInterval(selected.end.timeIntervalSince(selected.start) / 2)))
                    .foregroundStyle(InstrumentTheme.blue.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: window.interval.start...window.interval.end)
        .chartYScale(domain: 0...max(1, (window.buckets.compactMap(\.value).max() ?? 0) * 1.12))
        .chartXAxis { AxisMarks(values: window.buckets.enumerated().compactMap { index, bucket in
            index % (model.period == .week ? 1 : 5) == 0 ? bucket.start : nil
        }) { value in
            AxisValueLabel { if let date = value.as(Date.self) {
                Text(axisLabel(date, in: window)).font(.system(size: 11))
            } }
        } }
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            AxisValueLabel { if let amount = value.as(Double.self) { Text(TokenDialGeometry.label(amount)).font(.system(size: 11)) } }
        } }
        .environment(\.calendar, calendar(window)).environment(\.timeZone, window.timeZone)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = value.location.x - geometry[proxy.plotAreaFrame].origin.x
                        if let date: Date = proxy.value(atX: x) {
                            model.selectedDay = window.buckets.first { $0.start <= date && date < $0.end }?.start
                        }
                    })
                    .onContinuousHover { phase in
                        if case .active(let point) = phase {
                            let x = point.x - geometry[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                model.selectedDay = window.buckets.first { $0.start <= date && date < $0.end }?.start
                            }
                        }
                    }
            }
        }
        .frame(height: 195)
        .accessibilityLabel("Consommation jour par jour, \(window.metric.unit). Les jours sans mesure ne sont pas des zéros.")
    }
    private func dayDetail(_ bucket: DailyAnalysisBucket, in window: DailyAnalysisWindow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dayTitle(bucket.start, in: window)).font(.system(size: 14, weight: .semibold))
                Text(bucket.isFuture ? "À venir" : bucket.metricIsPartial ? "Somme partielle" : bucket.isToday ? "Aujourd’hui · journée en cours" : "Jour sélectionné")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(bucket.value.map { exact($0, metric: window.metric) } ?? "Sans relevé")
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Button { selectAdjacentDay(-1, in: window) } label: { Image(systemName: "chevron.left") }
                .disabled(bucket.start == window.buckets.first?.start)
                .accessibilityLabel("Jour précédent")
            Button { selectAdjacentDay(1, in: window) } label: { Image(systemName: "chevron.right") }
                .disabled(bucket.start == window.buckets.last?.start)
                .accessibilityLabel("Jour suivant")
        }.padding(12).background(InstrumentTheme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .help(bucket.metricIsPartial ? "\(bucket.measuredEvents)/\(bucket.eventCount) événements possèdent cette mesure. Somme partielle." : model.metric.definition)
    }
    private var periodTitle: String {
        guard let window = model.window else { return model.period == .week ? "Cette semaine" : "Ce mois" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "fr_FR"); formatter.timeZone = window.timeZone
        formatter.dateFormat = model.period == .week ? "d MMM" : "LLLL yyyy"
        if model.period == .month { return formatter.string(from: window.interval.start).capitalized }
        let last = window.buckets.last!.start
        return "\(formatter.string(from: window.interval.start)) – \(formatter.string(from: last))"
    }
    private func calendar(_ window: DailyAnalysisWindow) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = window.timeZone; return c
    }
    private func selectAdjacentDay(_ delta: Int, in window: DailyAnalysisWindow) {
        guard let day = selected, let index = window.buckets.firstIndex(where: { $0.start == day.start }),
              window.buckets.indices.contains(index + delta) else { return }
        model.selectedDay = window.buckets[index + delta].start
    }
    private func axisLabel(_ date: Date, in window: DailyAnalysisWindow) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.timeZone = window.timeZone
        f.dateFormat = model.period == .week ? "EEE d" : "d"
        return f.string(from: date)
    }
    private func dayTitle(_ date: Date, in window: DailyAnalysisWindow) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.timeZone = window.timeZone
        f.dateFormat = "EEEE d MMMM"; return f.string(from: date).capitalized
    }
    private func exact(_ value: Double, metric: DailyAnalysisMetric) -> String {
        value.formatted(.number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(metric == .duration ? 0...1 : 0...0))) + " " + metric.unit
    }
    private func refresh() { model.refresh(days: comparison.archiveDays) }
}
