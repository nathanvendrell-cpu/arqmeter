import Foundation
import ArqmeterCore

enum UTCDay {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    static func date(_ text: String) -> Date? {
        guard text.count == 10 else { return nil }
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              let result = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              string(result) == text else { return nil }
        return result
    }

    static func string(_ date: Date) -> String {
        let value = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", value.year ?? 0, value.month ?? 0, value.day ?? 0)
    }

    static func next(_ day: String) -> String? {
        guard let date = date(day), let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return string(next)
    }
}

struct ArchivedDailyTokens: Codable, Equatable {
    let day: String
    let tokens: Int64
}

struct OfficialCoverageSpan: Codable, Equatable {
    let firstDay: String
    let lastDay: String
}

private struct DailyArchiveFile: Codable {
    var version = 1
    var days: [ArchivedDailyTokens] = []
    var spans: [OfficialCoverageSpan] = []
    var lastReadAt: Date?
}

/// Archives only the account's official daily buckets. Missing days are kept
/// missing, not silently converted to zero. No additional model call is made.
final class OfficialDailyArchive {
    private let url: URL?
    private var file: DailyArchiveFile
    private(set) var writable: Bool
    private(set) var lastSaveSucceeded = true

    var days: [ArchivedDailyTokens] { file.days }
    var spans: [OfficialCoverageSpan] { file.spans }
    var lastReadAt: Date? { file.lastReadAt }

    init(url: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arqmeter/official-daily-history.json")) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(DailyArchiveFile.self, from: data),
               decoded.version == 1,
               decoded.days.allSatisfy({ UTCDay.date($0.day) != nil && $0.tokens >= 0 }),
               Set(decoded.days.map(\.day)).count == decoded.days.count,
               decoded.spans.allSatisfy({ UTCDay.date($0.firstDay) != nil &&
                   UTCDay.date($0.lastDay) != nil && $0.firstDay <= $0.lastDay }) {
                file = decoded
                writable = true
            } else {
                file = DailyArchiveFile()
                writable = false // Preserve unreadable on-disk history.
            }
        } else {
            file = DailyArchiveFile()
            writable = true
        }
    }

    @discardableResult
    func merge(_ buckets: [DailyTokenUsage], at date: Date = Date()) -> Bool {
        guard !buckets.isEmpty else { return false }
        var incoming: [String: Int64] = [:]
        for bucket in buckets {
            guard UTCDay.date(bucket.day) != nil, bucket.tokens >= 0,
                  incoming[bucket.day] == nil else { return false }
            incoming[bucket.day] = bucket.tokens
        }
        let keys = incoming.keys.sorted()
        guard let first = keys.first, let last = keys.last else { return false }
        var merged = Dictionary(uniqueKeysWithValues: file.days.map { ($0.day, $0.tokens) })
        var changed = false
        for (day, tokens) in incoming where merged[day] != tokens {
            merged[day] = tokens
            changed = true
        }
        let newDays = merged.keys.sorted().map { ArchivedDailyTokens(day: $0, tokens: merged[$0]!) }
        let newSpans = Self.mergeSpans(file.spans + [OfficialCoverageSpan(firstDay: first, lastDay: last)])
        changed = changed || newSpans != file.spans
        let shouldSave = changed || file.lastReadAt.map { date.timeIntervalSince($0) >= 6 * 60 * 60 } ?? true
        file.days = newDays
        file.spans = newSpans
        file.lastReadAt = date
        if shouldSave { lastSaveSucceeded = save() }
        return true
    }

    private static func mergeSpans(_ spans: [OfficialCoverageSpan]) -> [OfficialCoverageSpan] {
        var result: [OfficialCoverageSpan] = []
        for span in spans.sorted(by: { $0.firstDay < $1.firstDay }) {
            if let last = result.last,
               span.firstDay <= (UTCDay.next(last.lastDay) ?? last.lastDay) {
                result[result.count - 1] = OfficialCoverageSpan(firstDay: last.firstDay,
                    lastDay: max(last.lastDay, span.lastDay))
            } else {
                result.append(span)
            }
        }
        return result
    }

    private func save() -> Bool {
        guard let url else { return true }
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

enum SubscriptionTier: String, CaseIterable, Codable, Identifiable {
    case x5 = "x5"
    case x20 = "x20"
    var id: String { rawValue }
}

struct SubscriptionChange: Codable, Equatable, Identifiable {
    let effectiveDay: String
    let tier: SubscriptionTier
    var id: String { effectiveDay }
}

struct WorkflowChange: Codable, Equatable, Identifiable {
    let effectiveDay: String
    let name: String
    var id: String { effectiveDay }
}

struct WorkUnitAnnotation: Codable, Equatable, Identifiable {
    let periodKey: String
    let count: Int
    let unit: String
    var id: String { periodKey }
}

private struct ComparisonAnnotationsFile: Codable {
    var version = 1
    var subscriptions: [SubscriptionChange] = []
    var workflows: [WorkflowChange] = []
    var workUnits: [WorkUnitAnnotation] = []
}

final class ComparisonAnnotationsStore {
    private let url: URL?
    private var file: ComparisonAnnotationsFile
    private(set) var writable: Bool
    private(set) var lastSaveSucceeded = true

    var subscriptions: [SubscriptionChange] { file.subscriptions }
    var workflows: [WorkflowChange] { file.workflows }
    var workUnits: [WorkUnitAnnotation] { file.workUnits }

    init(url: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arqmeter/comparison-annotations.json")) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(ComparisonAnnotationsFile.self, from: data),
               decoded.version == 1,
               Set(decoded.subscriptions.map(\.effectiveDay)).count == decoded.subscriptions.count,
               Set(decoded.workflows.map(\.effectiveDay)).count == decoded.workflows.count,
               Set(decoded.workUnits.map(\.periodKey)).count == decoded.workUnits.count,
               decoded.subscriptions.allSatisfy({ UTCDay.date($0.effectiveDay) != nil }),
               decoded.workflows.allSatisfy({ UTCDay.date($0.effectiveDay) != nil && !$0.name.isEmpty }),
               decoded.workUnits.allSatisfy({ $0.count > 0 && !$0.unit.isEmpty }) {
                file = decoded
                writable = true
            } else {
                file = ComparisonAnnotationsFile()
                writable = false // An unreadable file is not overwritten.
            }
        } else {
            file = ComparisonAnnotationsFile()
            writable = true
        }
    }

    @discardableResult
    func setSubscription(day: String, tier: SubscriptionTier) -> Bool {
        guard writable, UTCDay.date(day) != nil else { return false }
        file.subscriptions.removeAll { $0.effectiveDay == day }
        file.subscriptions.append(SubscriptionChange(effectiveDay: day, tier: tier))
        file.subscriptions.sort { $0.effectiveDay < $1.effectiveDay }
        lastSaveSucceeded = save()
        return lastSaveSucceeded
    }

    @discardableResult
    func setWorkflow(day: String, name: String) -> Bool {
        let normalized = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard writable, UTCDay.date(day) != nil, !normalized.isEmpty else { return false }
        file.workflows.removeAll { $0.effectiveDay == day }
        file.workflows.append(WorkflowChange(effectiveDay: day, name: normalized))
        file.workflows.sort { $0.effectiveDay < $1.effectiveDay }
        lastSaveSucceeded = save()
        return lastSaveSucceeded
    }

    @discardableResult
    func setWorkUnits(periodKey: String, count: Int, unit: String) -> Bool {
        let normalized = String(unit.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard writable, count > 0, !normalized.isEmpty, periodKey.contains("|") else { return false }
        file.workUnits.removeAll { $0.periodKey == periodKey }
        file.workUnits.append(WorkUnitAnnotation(periodKey: periodKey, count: count, unit: normalized))
        lastSaveSucceeded = save()
        return lastSaveSucceeded
    }

    @discardableResult
    func removeSubscription(day: String) -> Bool {
        guard writable, file.subscriptions.contains(where: { $0.effectiveDay == day }) else { return false }
        file.subscriptions.removeAll { $0.effectiveDay == day }
        lastSaveSucceeded = save()
        return lastSaveSucceeded
    }

    @discardableResult
    func removeWorkflow(day: String) -> Bool {
        guard writable, file.workflows.contains(where: { $0.effectiveDay == day }) else { return false }
        file.workflows.removeAll { $0.effectiveDay == day }
        lastSaveSucceeded = save()
        return lastSaveSucceeded
    }

    private func save() -> Bool {
        guard let url else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
