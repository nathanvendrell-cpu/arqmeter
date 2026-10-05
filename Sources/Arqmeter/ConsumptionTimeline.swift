import Foundation

enum ConsumptionRange: String, CaseIterable, Identifiable {
    case minute
    case tenMinutes
    case hour
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minute: return "1 min"
        case .tenMinutes: return "10 min"
        case .hour: return "1 h"
        case .day: return "24 h"
        case .week: return "7 j"
        case .month: return "30 j"
        }
    }

    var title: String {
        switch self {
        case .minute: return "Dernière minute"
        case .tenMinutes: return "10 dernières minutes"
        case .hour: return "Dernière heure"
        case .day: return "Dernières 24 heures"
        case .week: return "7 jours glissants"
        case .month: return "30 jours glissants"
        }
    }

    var bucketLabel: String {
        switch self {
        case .minute: return "pas de 5 s"
        case .tenMinutes: return "pas de 1 min"
        case .hour: return "pas de 2 min"
        case .day: return "pas de 1 h"
        case .week, .month: return "par jour UTC"
        }
    }

    var localDuration: TimeInterval? {
        switch self {
        case .minute: return 60
        case .tenMinutes: return 10 * 60
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        case .week, .month: return nil
        }
    }

    var bucketCount: Int {
        switch self {
        case .minute: return 12
        case .tenMinutes: return 10
        case .hour: return 30
        case .day: return 24
        case .week: return 7
        case .month: return 30
        }
    }

    var isOfficial: Bool { localDuration == nil }
}

struct ConsumptionBucket: Identifiable {
    let start: Date
    let end: Date
    /// nil is an unreported official day, not a measured zero.
    let tokens: Int64?

    var id: Date { start }
}

struct ConsumptionWindow {
    let start: Date
    let end: Date
    let buckets: [ConsumptionBucket]
    let total: Int64?
    let input: Int64?
    let output: Int64?
    let cachedInput: Int64?
    let reportedDays: Int?
    let calendarDays: Int?
    let scanComplete: Bool

    var nonCachedInput: Int64? {
        guard let input, let cachedInput else { return nil }
        return max(0, input - cachedInput)
    }

    /// Derived throughput of reported local usage over the whole rolling window.
    /// It is not the model's instantaneous decoding speed. Incomplete scans
    /// and account-wide daily histories cannot establish a live throughput.
    var tokensPerSecond: Double? {
        let seconds = end.timeIntervalSince(start)
        guard scanComplete, reportedDays == nil, let total, seconds > 0 else { return nil }
        return Double(total) / seconds
    }

    static func local(events: [LocalTokenEvent], sampledAt: Date,
                      scanComplete: Bool, range: ConsumptionRange) -> ConsumptionWindow {
        guard let duration = range.localDuration else {
            preconditionFailure("An official range cannot use local events")
        }
        let start = sampledAt.addingTimeInterval(-duration)
        let step = duration / Double(range.bucketCount)
        var amounts = Array(repeating: Int64(0), count: range.bucketCount)
        var input: Int64 = 0
        var output: Int64 = 0
        var cached: Int64 = 0
        var cacheComplete = true
        for event in events where event.date > start && event.date <= sampledAt {
            // A timestamp on a bucket boundary belongs to the preceding
            // interval: (start, end], matching the headline total.
            let offset = event.date.timeIntervalSince(start)
            let index = min(range.bucketCount - 1, max(0, Int(ceil(offset / step)) - 1))
            amounts[index] += event.total
            input += event.input
            output += event.output
            cached += event.cached
            cacheComplete = cacheComplete && event.cachedObserved
        }
        let buckets = (0..<range.bucketCount).map { index in
            ConsumptionBucket(start: start.addingTimeInterval(Double(index) * step),
                              end: start.addingTimeInterval(Double(index + 1) * step),
                              tokens: amounts[index])
        }
        return ConsumptionWindow(start: start, end: sampledAt, buckets: buckets,
                                 total: input + output, input: input, output: output,
                                 cachedInput: cacheComplete ? cached : nil,
                                 reportedDays: nil, calendarDays: nil,
                                 scanComplete: scanComplete)
    }

    static func official(days: [ArchivedDailyTokens], range: ConsumptionRange,
                         page: Int, now: Date = Date()) -> ConsumptionWindow {
        let accountRange: AccountRange = range == .week ? .sevenDays : .thirtyDays
        precondition(range.isOfficial)
        let account = AccountTimeWindow.make(days: days, range: accountRange,
                                             page: page, now: now)
        return ConsumptionWindow(start: account.start, end: account.end,
                                 buckets: account.buckets.map {
                                     ConsumptionBucket(start: $0.start, end: $0.end,
                                                       tokens: $0.tokens)
                                 },
                                 total: account.total, input: nil, output: nil,
                                 cachedInput: nil, reportedDays: account.reportedDays,
                                 calendarDays: account.calendarDays, scanComplete: true)
    }
}
