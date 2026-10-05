import Foundation

/// An observed limit, never a conversion from a token count.
public struct WeeklyQuotaObservation: Equatable {
    public let observedAt: Date
    public let resetsAt: Date
    public let remainingPercent: Int
    public let source: String
    public let limit: String
    public let windowSeconds: TimeInterval

    public init(observedAt: Date, resetsAt: Date, remainingPercent: Int,
                source: String, limit: String, windowSeconds: TimeInterval = 604_800) {
        self.observedAt = observedAt
        self.resetsAt = resetsAt
        self.remainingPercent = remainingPercent
        self.source = source
        self.limit = limit
        self.windowSeconds = windowSeconds
    }
}

public struct QuotaCalendarMonth: Equatable, Hashable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) { self.year = year; self.month = month }

    public init(containing date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1)
    }

    public func interval(calendar: Calendar) -> DateInterval? {
        guard (1...12).contains(month),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: 1))
        else { return nil }
        return calendar.dateInterval(of: .month, for: date)
    }

    public func shifted(_ amount: Int, calendar: Calendar) -> QuotaCalendarMonth {
        guard let start = interval(calendar: calendar)?.start,
              let date = calendar.date(byAdding: .month, value: amount, to: start)
        else { return self }
        return QuotaCalendarMonth(containing: date, calendar: calendar)
    }
}

public struct WeeklyQuotaCycle: Equatable, Identifiable {
    /// The first boundary seen in this cohort keeps identity stable on refresh.
    public let id: String
    public let source: String
    public let limit: String
    public let start: Date // Derived from the observed reset and declared duration.
    public let resetsAt: Date
    public let latest: WeeklyQuotaObservation
    public let isCurrent: Bool
    public let windowSeconds: TimeInterval

    public var usedPercent: Int { 100 - latest.remainingPercent }
    public var elapsedAtObservation: TimeInterval { latest.observedAt.timeIntervalSince(start) }
}

public enum WeeklyQuotaComparison: Equatable {
    case comparable(points: Int)
    case firstObservation
    case differentLimit
    case missingOrRevisedCycle
    case differentElapsedTime
}

public enum WeeklyQuotaTimeline {
    /// Matches the existing reset-jitter policy. Anchored, not transitive.
    public static let boundaryTolerance: TimeInterval = 300

    public static func cycles(_ observations: [WeeklyQuotaObservation], now: Date) -> [WeeklyQuotaCycle] {
        struct Cohort {
            let first: WeeklyQuotaObservation
            var latest: WeeklyQuotaObservation
        }
        // Group independently per source/limit. No historical/live double import.
        let valid = observations.filter {
            (0...100).contains($0.remainingPercent) && $0.windowSeconds == 604_800 &&
            !$0.source.isEmpty && !$0.limit.isEmpty && $0.observedAt <= now &&
            $0.resetsAt > $0.observedAt &&
            $0.observedAt >= $0.resetsAt.addingTimeInterval(-$0.windowSeconds - boundaryTolerance)
        }
        let families = Dictionary(grouping: valid) {
            [$0.source, $0.limit, String($0.windowSeconds)].joined(separator: "\u{1F}")
        }
        var result: [WeeklyQuotaCycle] = []
        for (family, points) in families {
            // Tie-breaks make duplicate/out-of-order input deterministic.
            let ordered = points.sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
                return $0.remainingPercent > $1.remainingPercent
            }
            var cohorts: [Cohort] = []
            for point in ordered {
                if let last = cohorts.last,
                   abs(point.resetsAt.timeIntervalSince(last.first.resetsAt)) <= boundaryTolerance {
                    cohorts[cohorts.count - 1].latest = point
                } else {
                    cohorts.append(Cohort(first: point, latest: point))
                }
            }
            for (index, cohort) in cohorts.enumerated() {
                let latest = cohort.latest
                result.append(WeeklyQuotaCycle(
                    id: family + ":" + String(cohort.first.resetsAt.timeIntervalSince1970),
                    source: latest.source, limit: latest.limit,
                    start: latest.resetsAt.addingTimeInterval(-latest.windowSeconds),
                    resetsAt: latest.resetsAt, latest: latest,
                    isCurrent: index == cohorts.count - 1 && latest.resetsAt > now,
                    windowSeconds: latest.windowSeconds))
            }
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    /// Assignment is by the cycle's derived start, in the user's calendar zone.
    /// No synthetic week, no monthly allocation, no 28-day sliding window.
    public static func inMonth(_ month: QuotaCalendarMonth, cycles: [WeeklyQuotaCycle],
                               calendar: Calendar) -> [WeeklyQuotaCycle] {
        guard let interval = month.interval(calendar: calendar) else { return [] }
        return cycles.filter { $0.start >= interval.start && $0.start < interval.end }
    }

    public static func canConnect(_ previous: WeeklyQuotaCycle, _ next: WeeklyQuotaCycle) -> Bool {
        previous.source == next.source && previous.limit == next.limit &&
        previous.windowSeconds == next.windowSeconds &&
        abs(next.start.timeIntervalSince(previous.resetsAt)) <= boundaryTolerance
    }

    public static func comparison(_ cycle: WeeklyQuotaCycle,
                                  previous: WeeklyQuotaCycle?) -> WeeklyQuotaComparison {
        guard let previous else { return .firstObservation }
        guard previous.source == cycle.source, previous.limit == cycle.limit,
              previous.windowSeconds == cycle.windowSeconds else { return .differentLimit }
        guard canConnect(previous, cycle) else { return .missingOrRevisedCycle }
        // A partial live week must not look like a saving against a full week.
        guard abs(cycle.elapsedAtObservation - previous.elapsedAtObservation) <= boundaryTolerance
        else { return .differentElapsedTime }
        return .comparable(points: cycle.usedPercent - previous.usedPercent)
    }
}
