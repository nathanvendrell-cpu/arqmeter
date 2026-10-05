import Foundation
import ArqmeterCore

enum ComparisonScale: String, CaseIterable, Identifiable {
    case week = "Semaines"
    case month = "Mois"
    case quarter = "Trimestres"
    case year = "Années"

    var id: String { rawValue }
    var key: String {
        switch self {
        case .week: return "week"
        case .month: return "month"
        case .quarter: return "quarter"
        case .year: return "year"
        }
    }

    func start(containing date: Date) -> Date {
        let calendar = UTCDay.calendar
        switch self {
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .month: return calendar.dateInterval(of: .month, for: date)?.start ?? date
        case .quarter:
            let parts = calendar.dateComponents([.year, .month], from: date)
            let firstMonth = ((max(1, parts.month ?? 1) - 1) / 3) * 3 + 1
            return calendar.date(from: DateComponents(year: parts.year, month: firstMonth, day: 1)) ?? date
        case .year: return calendar.dateInterval(of: .year, for: date)?.start ?? date
        }
    }

    func end(after start: Date) -> Date {
        let calendar = UTCDay.calendar
        switch self {
        case .week: return calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start
        case .month: return calendar.date(byAdding: .month, value: 1, to: start) ?? start
        case .quarter: return calendar.date(byAdding: .month, value: 3, to: start) ?? start
        case .year: return calendar.date(byAdding: .year, value: 1, to: start) ?? start
        }
    }

    func title(for start: Date) -> String {
        let calendar = UTCDay.calendar
        let parts = calendar.dateComponents([.year, .month, .weekOfYear, .yearForWeekOfYear, .quarter], from: start)
        switch self {
        case .week:
            return String(format: "S%02d · %d", parts.weekOfYear ?? 0, parts.yearForWeekOfYear ?? 0)
        case .month:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: start).capitalized
        case .quarter:
            return "T\(((max(1, parts.month ?? 1) - 1) / 3) + 1) · \(parts.year ?? 0)"
        case .year:
            return "\(parts.year ?? 0)"
        }
    }
}

enum PeriodTier: Equatable {
    case known(SubscriptionTier)
    case mixed
    case unknown

    var label: String {
        switch self {
        case .known(let tier): return tier.rawValue
        case .mixed: return "Mixte"
        case .unknown: return "Abonnement ?"
        }
    }

    var knownTier: SubscriptionTier? {
        if case .known(let tier) = self { return tier }
        return nil
    }
}

enum PeriodWorkflow: Equatable {
    case known(String)
    case mixed
    case unknown

    var label: String {
        switch self {
        case .known(let name): return name
        case .mixed: return "Workflow mixte"
        case .unknown: return "Workflow non annoté"
        }
    }
}

struct ComparisonPeriod: Identifiable {
    let scale: ComparisonScale
    let start: Date
    let end: Date
    let title: String
    let tokens: Int64
    let reportedDays: Int
    let activeDays: Int
    let calendarDays: Int
    let covered: Bool
    let complete: Bool
    let tier: PeriodTier
    let workflow: PeriodWorkflow
    let workUnits: WorkUnitAnnotation?

    var id: String { "\(scale.key)|\(UTCDay.string(start))" }
    var tokensPerActiveDay: Double? {
        activeDays > 0 ? Double(tokens) / Double(activeDays) : nil
    }
    var tokensPerWorkUnit: Double? {
        guard let workUnits, workUnits.count > 0 else { return nil }
        return Double(tokens) / Double(workUnits.count)
    }
}

struct PeriodComparison {
    let before: ComparisonPeriod
    let after: ComparisonPeriod
    let reason: String?

    var isComparable: Bool { reason == nil }
    var totalChange: Double? {
        guard isComparable, before.tokens > 0 else { return nil }
        return (Double(after.tokens) / Double(before.tokens) - 1) * 100
    }
    var activeDayChange: Double? {
        guard isComparable, let first = before.tokensPerActiveDay, first > 0,
              let second = after.tokensPerActiveDay else { return nil }
        return (second / first - 1) * 100
    }
    var workUnitChange: Double? {
        guard isComparable, let beforeUnit = before.workUnits, let afterUnit = after.workUnits,
              beforeUnit.unit == afterUnit.unit,
              let first = before.tokensPerWorkUnit, first > 0,
              let second = after.tokensPerWorkUnit else { return nil }
        return (second / first - 1) * 100
    }

    static func make(before: ComparisonPeriod, after: ComparisonPeriod) -> PeriodComparison {
        let reason: String?
        if before.start >= after.start {
            reason = "Choisir une période A antérieure à B."
        } else if !before.complete || !after.complete {
            reason = "Une période est encore en cours."
        } else if !before.covered || !after.covered {
            reason = "Une période sort de la plage des relevés officiels archivés."
        } else if before.reportedDays != before.calendarDays || after.reportedDays != after.calendarDays {
            reason = "Des jours de relevé manquent dans au moins une période."
        } else if before.tier.knownTier == nil || after.tier.knownTier == nil {
            reason = "Renseigner un seul abonnement sur toute la durée de chaque période."
        } else if before.tier.knownTier != after.tier.knownTier {
            reason = "x5 et x20 ne sont pas comparés comme un gain de workflow."
        } else {
            reason = nil
        }
        return PeriodComparison(before: before, after: after, reason: reason)
    }
}

enum ComparisonEngine {
    static func periods(scale: ComparisonScale, days: [ArchivedDailyTokens],
                        spans: [OfficialCoverageSpan], subscriptions: [SubscriptionChange],
                        workflows: [WorkflowChange], workUnits: [WorkUnitAnnotation],
                        now: Date = Date()) -> [ComparisonPeriod] {
        guard let earliest = spans.map(\.firstDay).min().flatMap(UTCDay.date),
              !days.isEmpty else { return [] }
        let calendar = UTCDay.calendar
        let today = calendar.startOfDay(for: now)
        let unitsByKey = Dictionary(uniqueKeysWithValues: workUnits.map { ($0.periodKey, $0) })
        var start = scale.start(containing: earliest)
        var result: [ComparisonPeriod] = []
        for _ in 0..<1200 where start <= today {
            let end = scale.end(after: start)
            guard end > start else { break }
            let firstDay = UTCDay.string(start)
            let afterLastDay = UTCDay.string(end)
            let lastDay = UTCDay.string(calendar.date(byAdding: .day, value: -1, to: end) ?? start)
            let buckets = days.filter { $0.day >= firstDay && $0.day < afterLastDay }
            let key = "\(scale.key)|\(firstDay)"
            result.append(ComparisonPeriod(scale: scale, start: start, end: end,
                title: scale.title(for: start),
                tokens: buckets.reduce(0) { $0 + $1.tokens },
                reportedDays: buckets.count,
                activeDays: buckets.filter { $0.tokens > 0 }.count,
                calendarDays: calendar.dateComponents([.day], from: start, to: end).day ?? 0,
                covered: spans.contains { $0.firstDay <= firstDay && $0.lastDay >= lastDay },
                complete: end <= today,
                tier: tier(for: firstDay, until: afterLastDay, changes: subscriptions),
                workflow: workflow(for: firstDay, until: afterLastDay, changes: workflows),
                workUnits: unitsByKey[key]))
            start = end
        }
        return result.reversed()
    }

    private static func tier(for first: String, until end: String,
                             changes: [SubscriptionChange]) -> PeriodTier {
        let ordered = changes.sorted { $0.effectiveDay < $1.effectiveDay }
        guard let starting = ordered.last(where: { $0.effectiveDay <= first })?.tier else {
            return ordered.contains(where: { $0.effectiveDay < end }) ? .mixed : .unknown
        }
        return ordered.contains(where: { $0.effectiveDay > first && $0.effectiveDay < end && $0.tier != starting })
            ? .mixed : .known(starting)
    }

    private static func workflow(for first: String, until end: String,
                                 changes: [WorkflowChange]) -> PeriodWorkflow {
        let ordered = changes.sorted { $0.effectiveDay < $1.effectiveDay }
        guard let starting = ordered.last(where: { $0.effectiveDay <= first })?.name else {
            return ordered.contains(where: { $0.effectiveDay < end }) ? .mixed : .unknown
        }
        return ordered.contains(where: { $0.effectiveDay > first && $0.effectiveDay < end && $0.name != starting })
            ? .mixed : .known(starting)
    }
}

final class ComparisonModel: ObservableObject {
    @Published var scale: ComparisonScale = .week
    @Published var baselineKey = ""
    @Published var candidateKey = ""
    @Published var planDate = Date()
    @Published var planTier: SubscriptionTier = .x5
    @Published var workflowDate = Date()
    @Published var workflowName = ""
    @Published var annotationsExpanded = false
    @Published var workloadExpanded = false
    @Published var timelinePage = 0
    @Published var focusedPeriodKey = ""
    @Published var workUnitDrafts: [String: String] = [:]
    @Published var workUnitLabel = "tâches livrées"
    @Published var pendingSubscriptionDeletion: String?
    @Published var pendingWorkflowDeletion: String?
    @Published var archiveDays: [ArchivedDailyTokens]
    @Published var coverageSpans: [OfficialCoverageSpan]
    @Published var subscriptions: [SubscriptionChange]
    @Published var workflows: [WorkflowChange]
    @Published var workUnits: [WorkUnitAnnotation]
    @Published var lastOfficialRead: Date?
    @Published var warning: String?

    private let archive: OfficialDailyArchive
    private let annotations: ComparisonAnnotationsStore

    init(archiveURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arqmeter/official-daily-history.json"),
         annotationsURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arqmeter/comparison-annotations.json")) {
        archive = OfficialDailyArchive(url: archiveURL)
        annotations = ComparisonAnnotationsStore(url: annotationsURL)
        archiveDays = archive.days
        coverageSpans = archive.spans
        lastOfficialRead = archive.lastReadAt
        subscriptions = annotations.subscriptions
        workflows = annotations.workflows
        workUnits = annotations.workUnits
        workUnitLabel = annotations.workUnits.first?.unit ?? "tâches livrées"
        annotationsExpanded = subscriptions.isEmpty
        if !archive.writable || !annotations.writable {
            warning = "Un fichier d’historique est illisible ; il est conservé sans être écrasé."
        }
    }

    var periods: [ComparisonPeriod] {
        ComparisonEngine.periods(scale: scale, days: archiveDays, spans: coverageSpans,
                                 subscriptions: subscriptions, workflows: workflows,
                                 workUnits: workUnits)
    }

    var visiblePeriods: [ComparisonPeriod] {
        Array(periods.dropFirst(timelinePage * 8).prefix(8).reversed())
    }

    var focusedPeriod: ComparisonPeriod? {
        visiblePeriods.first(where: { $0.id == focusedPeriodKey }) ?? visiblePeriods.last
    }

    var selectedBefore: ComparisonPeriod? {
        let available = periods
        if let selected = available.first(where: { $0.id == baselineKey }) { return selected }
        let after = selectedAfter
        return available.first(where: { $0.complete && $0.start < (after?.start ?? .distantFuture) &&
            $0.tier.knownTier != nil && $0.tier == after?.tier })
            ?? available.first(where: { $0.complete && $0.start < (after?.start ?? .distantFuture) })
    }

    var selectedAfter: ComparisonPeriod? {
        let available = periods
        return available.first(where: { $0.id == candidateKey })
            ?? available.first(where: { $0.complete && $0.covered })
            ?? available.first
    }

    var comparison: PeriodComparison? {
        guard let before = selectedBefore, let after = selectedAfter else { return nil }
        return .make(before: before, after: after)
    }

    /// The daily glance always uses the two latest finished weeks. It does not
    /// inherit a possibly unrelated manual A/B selection from the full panel.
    var latestWeeklyComparison: PeriodComparison? {
        let finished = ComparisonEngine.periods(scale: .week, days: archiveDays,
            spans: coverageSpans, subscriptions: subscriptions,
            workflows: workflows, workUnits: workUnits).filter(\.complete)
        guard finished.count >= 2 else { return nil }
        return .make(before: finished[1], after: finished[0])
    }

    func setScale(_ value: ComparisonScale) {
        scale = value
        baselineKey = ""
        candidateKey = ""
        timelinePage = 0
        focusedPeriodKey = ""
    }

    func acceptOfficialDays(_ days: [DailyTokenUsage], at date: Date = Date()) {
        guard archive.merge(days, at: date) else {
            warning = "Le relevé quotidien officiel n’a pas pu être archivé (dates ou doublons invalides)."
            return
        }
        archiveDays = archive.days
        coverageSpans = archive.spans
        lastOfficialRead = date
        warning = archive.lastSaveSucceeded ? nil : "Le relevé est visible mais son archivage local a échoué."
    }

    func addSubscription() {
        let day = localDay(planDate)
        if annotations.setSubscription(day: day, tier: planTier) {
            subscriptions = annotations.subscriptions
            warning = nil
        } else {
            warning = "L’annotation d’abonnement n’a pas pu être enregistrée."
        }
    }

    func addWorkflow() {
        let day = localDay(workflowDate)
        if annotations.setWorkflow(day: day, name: workflowName) {
            workflows = annotations.workflows
            workflowName = ""
            warning = nil
        } else {
            warning = "Le changement de workflow n’a pas pu être enregistré."
        }
    }

    func removeSubscription(day: String) {
        if annotations.removeSubscription(day: day) { subscriptions = annotations.subscriptions }
        else { warning = "La suppression de l’annotation a échoué." }
    }

    func removeWorkflow(day: String) {
        if annotations.removeWorkflow(day: day) { workflows = annotations.workflows }
        else { warning = "La suppression de l’annotation a échoué." }
    }

    func saveWorkUnits(periodKey: String, count: Int, unit: String) {
        if annotations.setWorkUnits(periodKey: periodKey, count: count, unit: unit) {
            workUnits = annotations.workUnits
            warning = nil
        } else {
            warning = "Le volume de travail n’a pas pu être enregistré."
        }
    }

    private func localDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
