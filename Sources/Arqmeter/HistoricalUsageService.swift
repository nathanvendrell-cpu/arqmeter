import Foundation
import ArqmeterCore

extension Notification.Name {
    static let arqmeterHistoryUpdated = Notification.Name("com.7agency.arqmeter.history-updated")
    static let arqmeterAnalysisRefreshRequested = Notification.Name("com.7agency.arqmeter.analysis-refresh-requested")
}

struct HistoricalDashboardSnapshot {
    let records: [UnifiedUsageRecord]
    let sessions: [UsageSession]
    let availability: [SourceAvailability]
    let coverage: [HistoricalCoverage]
    /// Older local records are kept separate from the selected period, so the
    /// daily view cannot mistake an archive for activity happening now.
    let olderSourceHistory: [String: UsageAggregate]
    let recommendations: [SessionRecommendation]
    let comparability: [String: UsageComparability]
    let scanResults: [HistoricalScanResult]
    let error: String?
}

/// The complete inventory runs on its own 120-second timer. A visible Claude
/// readout may request a bounded tail on the same serial queue from the
/// existing live tick. Neither path contacts a model or external service.
final class HistoricalUsageService {
    static let shared = HistoricalUsageService()
    private let queue = DispatchQueue(label: "com.7agency.arqmeter.history", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var engine: HistoricalUsageEngine?
    private var recentScans: [HistoricalScanResult] = []
    private var lastError: String?

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            do {
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Arqmeter/historical-usage.sqlite3")
                self.engine = HistoricalUsageEngine(store: try HistoricalUsageStore(url: url))
            } catch { self.lastError = "Historique local indisponible : \(error)"; return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(120), leeway: .seconds(15))
            timer.setEventHandler { [weak self] in
                guard let self, let engine = self.engine else { return }
                do { self.recentScans = try engine.scan(); self.lastError = nil }
                catch { self.lastError = "Lecture historique incomplète : \(error)" }
                // Publish after the serial scan/commit, not from a second UI timer
                // whose phase can show the previous historical scan for 2 more minutes.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .arqmeterHistoryUpdated, object: nil)
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            engine = nil
        }
    }

    func recordOfficialCodexQuota(_ percent: Int, at date: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.engine?.store.saveQuota(harness: "codex", remainingPercent: percent,
                    at: date, provenance: "Codex app-server · account/rateLimits/read")
            } catch { self.lastError = "Échantillon quota non enregistré : \(error)" }
        }
    }

    func snapshot(days: Int = 7, completion: @escaping (HistoricalDashboardSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let end = Date()
            let start = end.addingTimeInterval(-Double(max(1, min(days, 365))) * 24 * 60 * 60)
            var coverage: [HistoricalCoverage] = []
            var recommendations: [SessionRecommendation] = []
            var records: [UnifiedUsageRecord] = []
            var sessions: [UsageSession] = []
            var olderSourceHistory: [String: UsageAggregate] = [:]
            var comparisons: [String: UsageComparability] = [:]
            do {
                if let store = self.engine?.store {
                    for harness in ["codex", "claude-code", "gemini-cli", "ollama"] {
                        coverage.append(try store.coverage(harness: harness, from: start, to: end))
                    }
                    records = try store.records(from: start, to: end)
                    for harness in ["claude-code", "gemini-cli", "ollama"] where
                        !records.contains(where: { $0.harnessID == harness }) {
                        let archived = try store.records(harness: harness,
                            from: Date(timeIntervalSince1970: 0), to: end)
                        if !archived.isEmpty {
                            olderSourceHistory[harness] = UsageAggregate(records: archived)
                        }
                    }
                    sessions = UsageSessionIndex.sessions(records)
                    let lastByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.lastEvent) })
                    recommendations = SessionOptimizer.analyze(records).sorted { left, right in
                        // Prioritize measured uncached load, not repeated cached context.
                        // This ranks opportunities only; no quality, cost or gain inferred.
                        if left.basis.priority != right.basis.priority {
                            return left.basis.priority > right.basis.priority
                        }
                        func severity(_ value: RecommendationSeverity) -> Int {
                            switch value { case .high: return 3; case .moderate: return 2; case .info: return 1 }
                        }
                        func confidence(_ value: RecommendationConfidence) -> Int {
                            switch value { case .high: return 3; case .medium: return 2; case .low: return 1 }
                        }
                        if severity(left.severity) != severity(right.severity) { return severity(left.severity) > severity(right.severity) }
                        if confidence(left.confidence) != confidence(right.confidence) { return confidence(left.confidence) > confidence(right.confidence) }
                        let leftDate = lastByID["\(left.harnessID):\(left.sessionID)"] ?? .distantPast
                        let rightDate = lastByID["\(right.harnessID):\(right.sessionID)"] ?? .distantPast
                        return leftDate == rightDate ? left.id < right.id : leftDate > rightDate
                    }
                    if let codex = coverage.first {
                        for other in coverage.dropFirst() {
                            comparisons[other.harnessID] = HistoricalComparability.compare(codex, other,
                                metric: .inputTokens)
                        }
                    }
                }
            } catch { self.lastError = "Lecture historique incomplète : \(error)" }
            let result = HistoricalDashboardSnapshot(records: records,
                sessions: sessions,
                availability: SourceAvailabilityProbe.detect(), coverage: coverage,
                olderSourceHistory: olderSourceHistory,
                recommendations: recommendations, comparability: comparisons,
                scanResults: self.recentScans, error: self.lastError)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Targeted read of the existing store, no scan, recommendation pass or new
    /// timer. Calendar navigation does not change the sessions/Optimizer scope.
    func analysisRecords(harness: String, from start: Date, to end: Date,
                         completion: @escaping ([UnifiedUsageRecord], String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let records: [UnifiedUsageRecord], errorMessage: String?
            do {
                if let store = self.engine?.store {
                    records = try store.records(harness: harness, from: start, to: end)
                    errorMessage = self.lastError
                } else { records = []; errorMessage = "Historique local pas encore disponible" }
            } catch { records = []; errorMessage = "Lecture de cette période impossible" }
            DispatchQueue.main.async { completion(records, errorMessage) }
        }
    }

    /// Reduced local Codex events for 7/30-day project periods. The 120-second
    /// importer remains the sole source of these indexed records.
    func codexProjectActivity(from start: Date, to end: Date,
                              completion: @escaping (HistoricalCodexProjectActivity?, String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let activity: HistoricalCodexProjectActivity?, errorMessage: String?
            do {
                guard let store = self.engine?.store else {
                    DispatchQueue.main.async { completion(nil, "Historique local pas encore disponible") }
                    return
                }
                activity = try store.codexProjectActivity(from: start, to: end)
                errorMessage = nil
            } catch {
                activity = nil
                errorMessage = "Lecture des projets impossible"
            }
            DispatchQueue.main.async { completion(activity, errorMessage) }
        }
    }

    /// Foreground Claude tail + indexed read on the existing serial SQLite
    /// queue. No quota request, independent scanner or coverage publication.
    func recentClaudeRecords(duration: TimeInterval,
                             completion: @escaping ([UnifiedUsageRecord], String?, Date, Bool, Date?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let records: [UnifiedUsageRecord], errorMessage: String?
            do {
                guard let engine = self.engine else {
                    DispatchQueue.main.async { completion([], "Historique local pas encore disponible", Date(), true, nil) }
                    return
                }
                let result = try engine.scanRecentClaude()
                // Date the window after the queued scan. A 120-second
                // inventory may have occupied this same serial queue since
                // the UI requested the pass.
                let end = Date()
                records = try engine.store.records(harness: "claude-code",
                    from: end.addingTimeInterval(-duration), to: end)
                let lastKnownAt: Date?
                let lastDateUnavailable: Bool
                do {
                    lastKnownAt = try engine.store.latestEventDate(harness: "claude-code")
                        .flatMap { $0 <= end ? $0 : nil }
                    lastDateUnavailable = false
                } catch {
                    lastKnownAt = nil
                    lastDateUnavailable = true
                }
                errorMessage = result.readFailures > 0 ? "Lecture récente de Claude partielle" :
                    result.diagnostic == "Source absente ou illisible" ? result.diagnostic :
                    lastDateUnavailable ? "Date du dernier événement indisponible" : nil
                DispatchQueue.main.async { completion(records, errorMessage, end, result.pendingRecentWork, lastKnownAt) }
            } catch {
                DispatchQueue.main.async { completion([], "Lecture récente de Claude impossible", Date(), true, nil) }
            }
        }
    }

    func allRecordedEvents(completion: @escaping ([UnifiedUsageRecord], [UsageSession], String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let records = try self.engine?.store.records(from: Date(timeIntervalSince1970: 0), to: Date()) ?? []
                let sessions = UsageSessionIndex.sessions(records)
                DispatchQueue.main.async { completion(records, sessions, nil) }
            } catch {
                DispatchQueue.main.async { completion([], [], "Lecture des preuves des essais impossible : \(error)") }
            }
        }
    }
}
