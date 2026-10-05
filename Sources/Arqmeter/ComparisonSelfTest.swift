import Foundation
import ArqmeterCore

enum ComparisonSelfTest {
    enum Failure: Error {
        case invalidDateAccepted
        case archiveMismatch
        case annotationMismatch
        case periodMismatch
        case planBoundaryMismatch
        case accountTimelineMismatch
        case corruptArchiveOverwritten
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arqmeter-comparison-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard UTCDay.date("2026-02-30") == nil else { throw Failure.invalidDateAccepted }
        let archiveURL = root.appendingPathComponent("archive.json")
        let annotationURL = root.appendingPathComponent("annotations.json")
        let now = UTCDay.date("2026-09-28")!
        let buckets = [
            DailyTokenUsage(day: "2026-09-14", tokens: 100),
            DailyTokenUsage(day: "2026-09-15", tokens: 50),
            DailyTokenUsage(day: "2026-09-21", tokens: 80),
            DailyTokenUsage(day: "2026-09-22", tokens: 40),
            DailyTokenUsage(day: "2026-09-27", tokens: 0),
        ]
        let archive = OfficialDailyArchive(url: archiveURL)
        guard archive.merge(buckets, at: now), archive.days.count == 5,
              archive.spans == [OfficialCoverageSpan(firstDay: "2026-09-14", lastDay: "2026-09-27")],
              !archive.merge(buckets + [buckets[0]], at: now),
              !archive.merge([DailyTokenUsage(day: "2026-09-21", tokens: -1)], at: now),
              OfficialDailyArchive(url: archiveURL).days == archive.days
        else { throw Failure.archiveMismatch }

        let latest = AccountTimeWindow.make(days: archive.days, range: .sevenDays, page: 0, now: now)
        let previous = AccountTimeWindow.make(days: archive.days, range: .sevenDays, page: 1, now: now)
        let quarter = AccountTimeWindow.make(days: archive.days, range: .ninetyDays, page: 0, now: now)
        guard UTCDay.string(latest.start) == "2026-09-22", latest.total == 40,
              latest.reportedDays == 2, latest.buckets.count == 7,
              latest.buckets.last?.tokens == nil,
              UTCDay.string(previous.start) == "2026-09-15", previous.total == 130,
              previous.reportedDays == 2, quarter.buckets.count == 13,
              quarter.total == 270, quarter.reportedDays == 5
        else { throw Failure.accountTimelineMismatch }

        let annotations = ComparisonAnnotationsStore(url: annotationURL)
        guard annotations.setSubscription(day: "2026-09-01", tier: .x5),
              annotations.setWorkflow(day: "2026-09-01", name: "Base"),
              annotations.setWorkflow(day: "2026-09-21", name: "Nouveau"),
              annotations.setWorkUnits(periodKey: "week|2026-09-14", count: 3, unit: "tâches"),
              annotations.setWorkUnits(periodKey: "week|2026-09-21", count: 3, unit: "tâches"),
              ComparisonAnnotationsStore(url: annotationURL).workUnits.count == 2
        else { throw Failure.annotationMismatch }

        func weeks() -> [ComparisonPeriod] {
            ComparisonEngine.periods(scale: .week, days: archive.days, spans: archive.spans,
                subscriptions: annotations.subscriptions, workflows: annotations.workflows,
                workUnits: annotations.workUnits, now: now)
        }
        guard let before = weeks().first(where: { $0.id == "week|2026-09-14" }),
              let after = weeks().first(where: { $0.id == "week|2026-09-21" }),
              before.tokens == 150, after.tokens == 120,
              before.activeDays == 2, after.activeDays == 2,
              before.reportedDays == 2, after.reportedDays == 3,
              before.complete && after.complete && before.covered && after.covered,
              before.tier == .known(.x5), after.tier == .known(.x5),
              before.workflow == .known("Base"), after.workflow == .known("Nouveau"),
              weeks().first(where: { $0.id == "week|2026-09-28" })?.complete == false
        else { throw Failure.periodMismatch }
        let incompleteComparison = PeriodComparison.make(before: before, after: after)
        guard !incompleteComparison.isComparable,
              incompleteComparison.reason?.contains("jours de relevé") == true
        else { throw Failure.periodMismatch }
        func withEveryDayReported(_ period: ComparisonPeriod) -> ComparisonPeriod {
            ComparisonPeriod(scale: period.scale, start: period.start, end: period.end,
                title: period.title, tokens: period.tokens,
                reportedDays: period.calendarDays, activeDays: period.activeDays,
                calendarDays: period.calendarDays, covered: period.covered,
                complete: period.complete, tier: period.tier,
                workflow: period.workflow, workUnits: period.workUnits)
        }
        let comparison = PeriodComparison.make(before: withEveryDayReported(before),
                                               after: withEveryDayReported(after))
        guard comparison.isComparable,
              abs((comparison.totalChange ?? 0) + 20) < 0.001,
              abs((comparison.workUnitChange ?? 0) + 20) < 0.001,
              abs((comparison.activeDayChange ?? 0) + 20) < 0.001,
              ComparisonScale.month.start(containing: before.start) == UTCDay.date("2026-09-01"),
              ComparisonScale.quarter.start(containing: before.start) == UTCDay.date("2026-07-01"),
              ComparisonScale.year.start(containing: before.start) == UTCDay.date("2026-01-01"),
              ComparisonEngine.periods(scale: .month, days: archive.days, spans: archive.spans,
                  subscriptions: annotations.subscriptions, workflows: annotations.workflows,
                  workUnits: annotations.workUnits, now: now).first?.covered == false,
              PeriodComparison.make(before: after, after: before).reason != nil
        else { throw Failure.periodMismatch }

        guard annotations.setSubscription(day: "2026-09-24", tier: .x20),
              let mixed = weeks().first(where: { $0.id == "week|2026-09-21" }),
              mixed.tier == .mixed,
              PeriodComparison.make(before: before, after: mixed).reason != nil,
              annotations.removeSubscription(day: "2026-09-24"),
              annotations.setSubscription(day: "2026-09-21", tier: .x20),
              let x20 = weeks().first(where: { $0.id == "week|2026-09-21" }),
              x20.tier == .known(.x20),
              PeriodComparison.make(before: before, after: x20).reason != nil
        else { throw Failure.planBoundaryMismatch }

        let badURL = root.appendingPathComponent("unreadable.json")
        let original = Data("not JSON".utf8)
        try original.write(to: badURL)
        let unreadable = OfficialDailyArchive(url: badURL)
        _ = unreadable.merge(buckets, at: now)
        guard !unreadable.writable, try Data(contentsOf: badURL) == original else {
            throw Failure.corruptArchiveOverwritten
        }
    }
}
