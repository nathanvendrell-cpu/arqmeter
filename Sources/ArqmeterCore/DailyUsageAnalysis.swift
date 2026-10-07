import Foundation

/// Analysis of existing observations only. Does not acquire or estimate metrics.
public enum DailyAnalysisPeriod: String, CaseIterable, Sendable {
    case week = "Semaine", month = "Mois"
    public func bounds(at now: Date, page: Int, calendar original: Calendar) -> DateInterval {
        var calendar = original
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let component: Calendar.Component = self == .week ? .weekOfYear : .month
        let current = calendar.dateInterval(of: component, for: now)!
        let start = calendar.date(byAdding: component, value: -max(0, page), to: current.start)!
        let end = calendar.date(byAdding: component, value: 1, to: start)!
        return DateInterval(start: start, end: end)
    }
}

public enum DailyAnalysisMetric: String, CaseIterable, Sendable {
    case total = "Total traité", uncached = "Entrée hors cache", output = "Sortie", cache = "Cache lu", duration = "Durée locale"
    public var unit: String { self == .duration ? "secondes" : "tokens" }
    public var definition: String {
        switch self {
        case .total: return "Entrée, cache inclus, plus sortie. Ce volume n’est ni un coût ni un quota."
        case .uncached: return "Entrée moins cache lu, par événement mesuré. Pour Claude, création de cache incluse."
        case .output: return "Tokens de sortie rapportés par les événements de réponse."
        case .cache: return "Tokens d’entrée réutilisés en cache, déjà inclus dans le total traité."
        case .duration: return "Durée des requêtes locales rapportée par les journaux, pas une vitesse de génération."
        }
    }

    public func measuredValue(_ row: UnifiedUsageRecord) -> Double? {
        func token(_ value: UsageMeasurement<Int64>) -> Int64? {
            guard case .measured(let amount) = value, amount >= 0 else { return nil }
            return amount
        }
        switch self {
        case .total:
            guard let input = token(row.inputTokens), let output = token(row.outputTokens) else { return nil }
            let (total, overflow) = input.addingReportingOverflow(output)
            return overflow ? nil : Double(total)
        case .uncached:
            guard let input = token(row.inputTokens), let cache = token(row.cachedInputTokens), cache <= input else { return nil }
            return Double(input - cache)
        case .output: return token(row.outputTokens).map(Double.init)
        case .cache:
            guard let cache = token(row.cachedInputTokens),
                  token(row.inputTokens).map({ cache <= $0 }) ?? true else { return nil }
            return Double(cache)
        case .duration:
            guard case .measured(let seconds) = row.durationSeconds, seconds.isFinite, seconds >= 0 else { return nil }
            return seconds
        }
    }
}

public struct DailyAnalysisBucket: Identifiable, Sendable {
    public let start: Date
    public let end: Date // Exclusive, using the selected source's calendar.
    public let value: Double?
    public let measuredEvents: Int
    public let eventCount: Int
    public let isToday: Bool
    public let isFuture: Bool
    public var id: Date { start }
    public var metricIsPartial: Bool { measuredEvents < eventCount }
}

public struct DailyAnalysisWindow: Sendable {
    public let interval: DateInterval
    public let buckets: [DailyAnalysisBucket]
    public let metric: DailyAnalysisMetric
    public let timeZone: TimeZone
    public let isOfficialAccount: Bool
    public var total: Double? {
        let values = buckets.compactMap(\.value)
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0, +)
        return sum.isFinite ? sum : nil
    }
    public var observedDays: Int { buckets.filter { $0.value != nil }.count }
    public var elapsedDays: Int { buckets.filter { !$0.isFuture }.count }
    public var metricIsPartial: Bool { buckets.contains(where: \.metricIsPartial) }
    public var isOpenPeriod: Bool { buckets.contains { $0.isToday || $0.isFuture } }

    public static func local(records: [UnifiedUsageRecord], harness: String, project: String? = nil,
                             metric: DailyAnalysisMetric, period: DailyAnalysisPeriod, page: Int,
                             at now: Date, calendar: Calendar = .current) -> Self {
        let interval = period.bounds(at: now, page: page, calendar: calendar)
        let rows = UsageAggregate(records: records.filter {
            $0.harnessID == harness && (project == nil || $0.projectPath == project) &&
                $0.timestamp >= interval.start && $0.timestamp < interval.end && $0.timestamp <= now
        }).records
        let byDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.timestamp) }
        let buckets = days(in: interval, at: now, calendar: calendar).map { start, end, today, future in
            let records = byDay[start] ?? []
            let values = records.compactMap(metric.measuredValue)
            let sum = values.reduce(0, +)
            return DailyAnalysisBucket(start: start, end: end,
                value: !future && !values.isEmpty && sum.isFinite ? sum : nil,
                measuredEvents: values.count, eventCount: records.count, isToday: today, isFuture: future)
        }
        return Self(interval: interval, buckets: buckets, metric: metric,
            timeZone: calendar.timeZone, isOfficialAccount: false)
    }

    /// Official daily buckets are UTC. Do not combine them with machine events.
    /// Conflicting observations of the same day are unavailable, never summed.
    public static func official(days values: [(day: Date, tokens: Int64)], period: DailyAnalysisPeriod,
                                page: Int, at now: Date) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = period.bounds(at: now, page: page, calendar: calendar)
        let groups = Dictionary(grouping: values.filter { $0.tokens >= 0 && calendar.startOfDay(for: $0.day) == $0.day }) { $0.day }
        let buckets = days(in: interval, at: now, calendar: calendar).map { start, end, today, future in
            let values = Set((groups[start] ?? []).map(\.tokens))
            let amount = values.count == 1 ? values.first.map(Double.init) : nil
            return DailyAnalysisBucket(start: start, end: end, value: future ? nil : amount,
                measuredEvents: 0, eventCount: 0, isToday: today, isFuture: future)
        }
        return Self(interval: interval, buckets: buckets, metric: .total,
                    timeZone: calendar.timeZone, isOfficialAccount: true)
    }

    private static func days(in interval: DateInterval, at now: Date, calendar: Calendar) -> [(Date, Date, Bool, Bool)] {
        var result: [(Date, Date, Bool, Bool)] = [], cursor = interval.start
        let today = calendar.startOfDay(for: now)
        while cursor < interval.end, result.count < 32 {
            guard let end = calendar.date(byAdding: .day, value: 1, to: cursor), end > cursor else { break }
            result.append((cursor, end, cursor == today, cursor > today))
            cursor = end
        }
        return result
    }
}
