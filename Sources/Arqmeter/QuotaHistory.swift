import Foundation
import ArqmeterCore

struct QuotaHistoryPoint: Codable, Equatable, Identifiable {
    let date: Date
    let remainingPercent: Int
    let resetsAt: Date

    var id: Date { date }
}

/// Stores changes, not every 30-second poll. This history is local and starts
/// when this version of Arqmeter first receives an official observation.
final class QuotaHistoryStore {
    // Current month plus the previous twelve. Same file/encoding; no backfill.
    // The hard cap also bounds parsing and view aggregation (~1 MB of JSON).
    static let retainedMonths = 13
    static let maximumPoints = 10_000
    private let url: URL?
    private let canPersist: Bool
    private(set) var points: [QuotaHistoryPoint]

    init(url: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arqmeter/quota-history.json")) {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([QuotaHistoryPoint].self, from: data) {
                points = decoded.filter { (0...100).contains($0.remainingPercent) }
                    .sorted { $0.date < $1.date }
                canPersist = true
            } else {
                points = []
                canPersist = false // Keep unreadable on-disk data for recovery.
            }
        } else {
            points = []
            canPersist = true
        }
    }

    @discardableResult
    func record(_ snapshot: UsageSnapshot) -> Bool {
        guard (0...100).contains(snapshot.remainingPercent), snapshot.resetsAt > snapshot.timestamp else { return false }
        if let last = points.last {
            guard snapshot.timestamp > last.date else { return false }
            let sameCycle = abs(snapshot.resetsAt.timeIntervalSince(last.resetsAt)) <= 5 * 60
            if sameCycle && snapshot.remainingPercent == last.remainingPercent { return false }
        }
        points.append(QuotaHistoryPoint(date: snapshot.timestamp,
                                        remainingPercent: snapshot.remainingPercent,
                                        resetsAt: snapshot.resetsAt))
        let cutoff = Calendar.current.date(byAdding: .month, value: -Self.retainedMonths,
                                          to: snapshot.timestamp) ?? .distantPast
        points.removeAll { $0.date < cutoff }
        if points.count > Self.maximumPoints { points.removeFirst(points.count - Self.maximumPoints) }
        guard let url, canPersist else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(points).write(to: url, options: .atomic)
        } catch {
            // Keep the in-memory history visible; the next change retries persistence.
        }
        return true
    }
}
