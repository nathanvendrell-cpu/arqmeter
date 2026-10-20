import Foundation
import SQLite3

public struct HistoricalSource: Sendable {
    public let harnessID: String
    public let root: URL
    public let historyRoot: URL?
    public let antigravityBrainRoot: URL?

    public init(harnessID: String, root: URL, historyRoot: URL? = nil, antigravityBrainRoot: URL? = nil) {
        self.harnessID = harnessID
        self.root = root
        self.historyRoot = historyRoot
        self.antigravityBrainRoot = antigravityBrainRoot
    }

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        [Self(harnessID: "codex", root: home.appendingPathComponent(".codex/sessions")),
         Self(harnessID: "claude-code", root: home.appendingPathComponent(".claude/projects")),
         Self(harnessID: "gemini-cli", root: home.appendingPathComponent(".gemini/tmp"),
              historyRoot: home.appendingPathComponent(".gemini/history"),
              antigravityBrainRoot: home.appendingPathComponent(".gemini/antigravity/brain")),
         Self(harnessID: "ollama", root: home.appendingPathComponent(".ollama/logs"))]
    }
}

public enum CoverageMetric: String, CaseIterable, Sendable {
    case inputTokens, outputTokens, cachedInputTokens, reasoningTokens, durationSeconds, costUSD

    func measurement(_ record: UnifiedUsageRecord) -> (present: Bool, estimated: Bool) {
        switch self {
        case .inputTokens: return Self.quality(record.inputTokens)
        case .outputTokens: return Self.quality(record.outputTokens)
        case .cachedInputTokens: return Self.quality(record.cachedInputTokens)
        case .reasoningTokens: return Self.quality(record.reasoningTokens)
        case .durationSeconds: return Self.quality(record.durationSeconds)
        case .costUSD: return Self.quality(record.costUSD)
        }
    }

    private static func quality<T>(_ measurement: UsageMeasurement<T>) -> (Bool, Bool) {
        switch measurement {
        case .measured: return (true, false)
        case .estimated: return (true, true)
        case .unavailable: return (false, false)
        }
    }
}

public struct MetricCoverage: Sendable {
    public let observed: Int
    public let estimated: Int
    public let unavailable: Int
    public var measured: Int { observed - estimated }
}

public struct HistoricalCoverage: Sendable {
    public let harnessID: String
    public let periodStart: Date
    public let periodEnd: Date
    public let trackingSince: Date?
    public let lastScan: Date?
    public let earliestEvent: Date?
    public let latestEvent: Date?
    public let eventCount: Int
    public let providerIDs: [String]
    public let modelIDs: [String]
    public let knownGaps: [String]
    public let inventoryComplete: Bool
    public let metrics: [CoverageMetric: MetricCoverage]
    public let latestQuotaRemainingPercent: Int?
    public let quotaSampledAt: Date?

    /// This is a file-observation claim, not a billing/account completeness claim.
    public var continuouslyObserved: Bool {
        guard let trackingSince, trackingSince <= periodStart,
              let lastScan, lastScan >= periodEnd.addingTimeInterval(-180) else { return false }
        return inventoryComplete && knownGaps.isEmpty
    }
}

/// Reduced, measured Codex events for the local projects view. This is not
/// account-wide usage, and a missing metric never becomes a measured zero.
public struct HistoricalCodexProjectEvent: Sendable {
    public let sessionID: String
    public let projectPath: String?
    public let lastEvent: Date
    public let input: Int64
    public let output: Int64
    public let cachedInput: Int64?
}

public struct HistoricalCodexProjectActivity: Sendable {
    public let events: [HistoricalCodexProjectEvent]
    public let eventCount: Int
    public let unavailableCount: Int
    public let scanComplete: Bool
    public let lastScan: Date?
}

public enum ComparabilityVerdict: String, Sendable {
    case comparable
    case partiallyComparable
    case insufficientCoverage
}

public struct UsageComparability: Sendable {
    public let verdict: ComparabilityVerdict
    public let reasons: [String]
}

public enum HistoricalComparability {
    public static func compare(_ left: HistoricalCoverage, _ right: HistoricalCoverage,
                               metric: CoverageMetric) -> UsageComparability {
        guard left.periodStart == right.periodStart, left.periodEnd == right.periodEnd else {
            return UsageComparability(verdict: .insufficientCoverage, reasons: ["Fenêtres temporelles différentes"])
        }
        let a = left.metrics[metric] ?? MetricCoverage(observed: 0, estimated: 0, unavailable: left.eventCount)
        let b = right.metrics[metric] ?? MetricCoverage(observed: 0, estimated: 0, unavailable: right.eventCount)
        var reasons: [String] = []
        if left.eventCount == 0 || right.eventCount == 0 { reasons.append("Aucun événement dans au moins une source") }
        if a.observed == 0 || b.observed == 0 { reasons.append("Métrique \(metric.rawValue) absente d'au moins une source") }
        if !reasons.isEmpty { return UsageComparability(verdict: .insufficientCoverage, reasons: reasons) }
        if !left.continuouslyObserved || !right.continuouslyObserved {
            reasons.append("Capture de fichiers non certifiée continue sur toute la période")
        }
        if a.unavailable > 0 || b.unavailable > 0 { reasons.append("Métrique absente sur certains événements") }
        if a.estimated > 0 || b.estimated > 0 { reasons.append("Certaines valeurs sont dérivées, pas directement mesurées") }
        if !left.knownGaps.isEmpty || !right.knownGaps.isEmpty { reasons.append("Trous de lecture connus") }
        if left.harnessID != right.harnessID {
            reasons.append("Harness différents : définitions des tokens et charges de travail non démontrées équivalentes")
        }
        if left.providerIDs != right.providerIDs || left.modelIDs != right.modelIDs {
            reasons.append("Providers ou modèles observés différents ou indisponibles")
        }
        if reasons.isEmpty {
            reasons.append("Même période et métrique mesurée ; la charge de travail peut néanmoins différer")
            return UsageComparability(verdict: .comparable, reasons: reasons)
        }
        return UsageComparability(verdict: .partiallyComparable, reasons: reasons)
    }
}

public enum HistoricalUsageError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String { if case .sqlite(let message) = self { return message }; return "" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Single-writer store. A file's complete-line cursor and its normalized events
/// commit in one transaction, so a crash cannot advance past uncommitted data.
public final class HistoricalUsageStore {
    private var db: OpaquePointer?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HistoricalUsageError.sqlite("Ouverture SQLite impossible : \(url.path)")
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS events (event_id TEXT PRIMARY KEY, harness TEXT NOT NULL, timestamp REAL NOT NULL, output_tokens INTEGER, payload BLOB NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS events_period ON events(harness, timestamp)")
        try execute("CREATE TABLE IF NOT EXISTS checkpoints (harness TEXT NOT NULL, path TEXT NOT NULL, inode TEXT NOT NULL, offset INTEGER NOT NULL, tracking_since REAL NOT NULL, last_scan REAL NOT NULL, gap TEXT, state BLOB NOT NULL, PRIMARY KEY(harness, path))")
        try execute("CREATE TABLE IF NOT EXISTS source_scans (harness TEXT PRIMARY KEY, tracking_since REAL NOT NULL, last_scan REAL NOT NULL, inventory_complete INTEGER NOT NULL, diagnostic TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS source_scan_ranges (harness TEXT PRIMARY KEY, inventoried_since REAL)")
        try execute("CREATE TABLE IF NOT EXISTS quota_samples (harness TEXT NOT NULL, timestamp REAL NOT NULL, remaining_percent INTEGER NOT NULL, provenance TEXT NOT NULL, PRIMARY KEY(harness, timestamp))")
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
    }

    private func bind(_ data: Data, to statement: OpaquePointer?, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), sqliteTransient) }
    }

    fileprivate func checkpoint(harness: String, path: String) throws -> FileCheckpoint? {
        let query = try prepare("SELECT inode, offset, tracking_since, last_scan, gap, state FROM checkpoints WHERE harness=? AND path=?")
        defer { sqlite3_finalize(query) }
        bind(harness, to: query, at: 1); bind(path, to: query, at: 2)
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        let blob = sqlite3_column_blob(query, 5)
        let size = Int(sqlite3_column_bytes(query, 5))
        guard size > 0, let blob else {
            throw HistoricalUsageError.sqlite("Checkpoint sans état : \(harness) · \(path)")
        }
        let state = try JSONDecoder().decode(ParserState.self, from: Data(bytes: blob, count: size))
        return FileCheckpoint(inode: String(cString: sqlite3_column_text(query, 0)),
                              offset: UInt64(sqlite3_column_int64(query, 1)),
                              trackingSince: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)),
                              lastScan: Date(timeIntervalSince1970: sqlite3_column_double(query, 3)),
                              gap: sqlite3_column_type(query, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(query, 4)),
                              state: state)
    }

    fileprivate func commit(records: [UnifiedUsageRecord], checkpoint: FileCheckpoint,
                            harness: String, path: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let insert = try prepare("INSERT INTO events(event_id,harness,timestamp,output_tokens,payload) VALUES(?,?,?,?,?) ON CONFLICT(event_id) DO UPDATE SET timestamp=excluded.timestamp, output_tokens=excluded.output_tokens, payload=excluded.payload WHERE excluded.output_tokens >= COALESCE(events.output_tokens,-1)")
            defer { sqlite3_finalize(insert) }
            for record in records {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(record.eventID, to: insert, at: 1)
                bind(record.harnessID, to: insert, at: 2)
                sqlite3_bind_double(insert, 3, record.timestamp.timeIntervalSince1970)
                if let output = record.outputTokens.value { sqlite3_bind_int64(insert, 4, output) }
                else { sqlite3_bind_null(insert, 4) }
                bind(try JSONEncoder().encode(record), to: insert, at: 5)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
            }
            let update = try prepare("INSERT INTO checkpoints(harness,path,inode,offset,tracking_since,last_scan,gap,state) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(harness,path) DO UPDATE SET inode=excluded.inode,offset=excluded.offset,last_scan=excluded.last_scan,gap=excluded.gap,state=excluded.state")
            defer { sqlite3_finalize(update) }
            bind(harness, to: update, at: 1); bind(path, to: update, at: 2)
            bind(checkpoint.inode, to: update, at: 3)
            sqlite3_bind_int64(update, 4, Int64(checkpoint.offset))
            sqlite3_bind_double(update, 5, checkpoint.trackingSince.timeIntervalSince1970)
            sqlite3_bind_double(update, 6, checkpoint.lastScan.timeIntervalSince1970)
            if let gap = checkpoint.gap { bind(gap, to: update, at: 7) } else { sqlite3_bind_null(update, 7) }
            bind(try JSONEncoder().encode(checkpoint.state), to: update, at: 8)
            guard sqlite3_step(update) == SQLITE_DONE else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    fileprivate func recordScan(harness: String, at date: Date, complete: Bool,
                                inventoriedSince: Date?, diagnostic: String?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
        let query = try prepare("INSERT INTO source_scans(harness,tracking_since,last_scan,inventory_complete,diagnostic) VALUES(?,?,?,?,?) ON CONFLICT(harness) DO UPDATE SET last_scan=excluded.last_scan,inventory_complete=excluded.inventory_complete,diagnostic=excluded.diagnostic")
        defer { sqlite3_finalize(query) }
        bind(harness, to: query, at: 1)
        sqlite3_bind_double(query, 2, date.timeIntervalSince1970)
        sqlite3_bind_double(query, 3, date.timeIntervalSince1970)
        sqlite3_bind_int(query, 4, complete ? 1 : 0)
        if let diagnostic { bind(diagnostic, to: query, at: 5) } else { sqlite3_bind_null(query, 5) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
        let range = try prepare("INSERT INTO source_scan_ranges(harness,inventoried_since) VALUES(?,?) ON CONFLICT(harness) DO UPDATE SET inventoried_since=excluded.inventoried_since")
        defer { sqlite3_finalize(range) }
        bind(harness, to: range, at: 1)
        if let inventoriedSince { sqlite3_bind_double(range, 2, inventoriedSince.timeIntervalSince1970) }
        else { sqlite3_bind_null(range, 2) }
        guard sqlite3_step(range) == SQLITE_DONE else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func saveQuota(harness: String, remainingPercent: Int, at date: Date, provenance: String) throws {
        guard (0...100).contains(remainingPercent) else { return }
        let query = try prepare("INSERT OR IGNORE INTO quota_samples VALUES(?,?,?,?)")
        defer { sqlite3_finalize(query) }
        bind(harness, to: query, at: 1)
        sqlite3_bind_double(query, 2, date.timeIntervalSince1970)
        sqlite3_bind_int(query, 3, Int32(remainingPercent))
        bind(provenance, to: query, at: 4)
        guard sqlite3_step(query) == SQLITE_DONE else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    public func records(harness: String? = nil, from start: Date, to end: Date) throws -> [UnifiedUsageRecord] {
        let query = try prepare("SELECT payload FROM events WHERE timestamp>=? AND timestamp<? AND (? IS NULL OR harness=?) ORDER BY timestamp")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(query, 2, end.timeIntervalSince1970)
        if let harness { bind(harness, to: query, at: 3); bind(harness, to: query, at: 4) }
        else { sqlite3_bind_null(query, 3); sqlite3_bind_null(query, 4) }
        var result: [UnifiedUsageRecord] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(query, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(query, 0)))
            result.append(try JSONDecoder().decode(UnifiedUsageRecord.self, from: data))
        }
        return result
    }

    /// Indexed timestamp only; no session content or token total is loaded.
    public func latestEventDate(harness: String) throws -> Date? {
        let query = try prepare("SELECT MAX(timestamp) FROM events WHERE harness=?")
        defer { sqlite3_finalize(query) }
        bind(harness, to: query, at: 1)
        guard sqlite3_step(query) == SQLITE_ROW else {
            throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_column_type(query, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(query, 0))
    }

    /// Stream the indexed Codex period into session/workspace totals. Keeping
    /// only the reduced groups avoids retaining a 30-day event array in the UI.
    /// Bounds match the local live window: (start, end].
    public func codexProjectActivity(from start: Date, to end: Date) throws -> HistoricalCodexProjectActivity {
        struct Key: Hashable { let session: String; let workspace: String? }
        struct Accumulator {
            var lastEvent: Date
            var input: Int64 = 0
            var output: Int64 = 0
            var cached: Int64 = 0
            var cacheComplete = true
        }
        let query = try prepare("SELECT payload FROM events WHERE harness='codex' AND timestamp>? AND timestamp<=? ORDER BY timestamp")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(query, 2, end.timeIntervalSince1970)
        var groups: [Key: Accumulator] = [:]
        var eventCount = 0, unavailableCount = 0
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
            eventCount += 1
            guard let blob = sqlite3_column_blob(query, 0) else { unavailableCount += 1; continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(query, 0)))
            let record = try JSONDecoder().decode(UnifiedUsageRecord.self, from: data)
            guard record.harnessID == "codex", case .measured(let input) = record.inputTokens,
                  case .measured(let output) = record.outputTokens else {
                unavailableCount += 1
                continue
            }
            let key = Key(session: record.sessionID, workspace: record.projectPath)
            var value = groups[key] ?? Accumulator(lastEvent: record.timestamp)
            let (newInput, inputOverflow) = value.input.addingReportingOverflow(input)
            let (newOutput, outputOverflow) = value.output.addingReportingOverflow(output)
            guard !inputOverflow, !outputOverflow else { throw HistoricalUsageError.sqlite("Total de projet hors limites") }
            value.input = newInput
            value.output = newOutput
            value.lastEvent = max(value.lastEvent, record.timestamp)
            if case .measured(let cached) = record.cachedInputTokens {
                let (newCached, cachedOverflow) = value.cached.addingReportingOverflow(cached)
                guard !cachedOverflow else { throw HistoricalUsageError.sqlite("Cache de projet hors limites") }
                value.cached = newCached
            } else { value.cacheComplete = false }
            groups[key] = value
        }
        let scan = try prepare("SELECT tracking_since,last_scan,inventory_complete FROM source_scans WHERE harness='codex'")
        defer { sqlite3_finalize(scan) }
        let scanStep = sqlite3_step(scan)
        guard scanStep == SQLITE_ROW || scanStep == SQLITE_DONE else {
            throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        let scanRow = scanStep == SQLITE_ROW
        let tracking = scanRow ? Date(timeIntervalSince1970: sqlite3_column_double(scan, 0)) : nil
        let lastScan = scanRow ? Date(timeIntervalSince1970: sqlite3_column_double(scan, 1)) : nil
        var inventoried = scanRow && sqlite3_column_int(scan, 2) == 1
        let range = try prepare("SELECT inventoried_since FROM source_scan_ranges WHERE harness='codex'")
        defer { sqlite3_finalize(range) }
        let rangeStep = sqlite3_step(range)
        guard rangeStep == SQLITE_ROW || rangeStep == SQLITE_DONE else {
            throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        if rangeStep == SQLITE_ROW, sqlite3_column_type(range, 0) != SQLITE_NULL {
            inventoried = inventoried || start > Date(timeIntervalSince1970: sqlite3_column_double(range, 0))
        }
        let gaps = try prepare("SELECT tracking_since,gap FROM checkpoints WHERE harness='codex' AND gap IS NOT NULL")
        defer { sqlite3_finalize(gaps) }
        var knownGap = false
        while true {
            let gapStep = sqlite3_step(gaps)
            if gapStep == SQLITE_DONE { break }
            guard gapStep == SQLITE_ROW else { throw HistoricalUsageError.sqlite(String(cString: sqlite3_errmsg(db))) }
            if start < Date(timeIntervalSince1970: sqlite3_column_double(gaps, 0)) { knownGap = true }
        }
        let complete = tracking.map { $0 <= start } == true && inventoried && !knownGap &&
            lastScan.map { $0 >= end.addingTimeInterval(-180) } == true && unavailableCount == 0
        let events = groups.map { key, value in
            HistoricalCodexProjectEvent(sessionID: key.session, projectPath: key.workspace,
                lastEvent: value.lastEvent, input: value.input, output: value.output,
                cachedInput: value.cacheComplete ? value.cached : nil)
        }
        return HistoricalCodexProjectActivity(events: events, eventCount: eventCount,
            unavailableCount: unavailableCount, scanComplete: complete, lastScan: lastScan)
    }

    public func coverage(harness: String, from start: Date, to end: Date) throws -> HistoricalCoverage {
        let records = try records(harness: harness, from: start, to: end)
        let query = try prepare("SELECT tracking_since,last_scan,inventory_complete,diagnostic FROM source_scans WHERE harness=?")
        defer { sqlite3_finalize(query) }
        bind(harness, to: query, at: 1)
        var tracking: Date?, lastScan: Date?, complete = false
        var scanDiagnostic: String?
        var gaps: [String] = []
        if sqlite3_step(query) == SQLITE_ROW {
            tracking = Date(timeIntervalSince1970: sqlite3_column_double(query, 0))
            lastScan = Date(timeIntervalSince1970: sqlite3_column_double(query, 1))
            complete = sqlite3_column_int(query, 2) == 1
            if sqlite3_column_type(query, 3) != SQLITE_NULL { scanDiagnostic = String(cString: sqlite3_column_text(query, 3)) }
        }
        let range = try prepare("SELECT inventoried_since FROM source_scan_ranges WHERE harness=?")
        defer { sqlite3_finalize(range) }
        bind(harness, to: range, at: 1)
        if sqlite3_step(range) == SQLITE_ROW, sqlite3_column_type(range, 0) != SQLITE_NULL {
            let since = Date(timeIntervalSince1970: sqlite3_column_double(range, 0))
            complete = complete || start > since
        }
        if !complete, let scanDiagnostic { gaps.append(scanDiagnostic) }
        let files = try prepare("SELECT tracking_since,gap FROM checkpoints WHERE harness=?")
        defer { sqlite3_finalize(files) }
        bind(harness, to: files, at: 1)
        while sqlite3_step(files) == SQLITE_ROW {
            let fileStart = Date(timeIntervalSince1970: sqlite3_column_double(files, 0))
            if sqlite3_column_type(files, 1) != SQLITE_NULL && start < fileStart {
                gaps.append(String(cString: sqlite3_column_text(files, 1)))
            }
        }
        if let tracking, start < tracking { gaps.append("Période antérieure au début de la surveillance ARQMETER") }
        let metrics = Dictionary(uniqueKeysWithValues: CoverageMetric.allCases.map { metric in
            let qualities = records.map { metric.measurement($0) }
            let observed = qualities.filter(\.present).count
            return (metric, MetricCoverage(observed: observed,
                estimated: qualities.filter(\.estimated).count,
                unavailable: records.count - observed))
        })
        let quota = try prepare("SELECT remaining_percent,timestamp FROM quota_samples WHERE harness=? AND timestamp>=? AND timestamp<? ORDER BY timestamp DESC LIMIT 1")
        defer { sqlite3_finalize(quota) }
        bind(harness, to: quota, at: 1)
        sqlite3_bind_double(quota, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(quota, 3, end.timeIntervalSince1970)
        let quotaFound = sqlite3_step(quota) == SQLITE_ROW
        return HistoricalCoverage(harnessID: harness, periodStart: start, periodEnd: end,
            trackingSince: tracking, lastScan: lastScan, earliestEvent: records.first?.timestamp,
            latestEvent: records.last?.timestamp, eventCount: records.count,
            providerIDs: Array(Set(records.map { $0.providerID ?? "unknown" })).sorted(),
            modelIDs: Array(Set(records.map { $0.modelID ?? "unknown" })).sorted(),
            knownGaps: Array(Set(gaps)).sorted(), inventoryComplete: complete, metrics: metrics,
            latestQuotaRemainingPercent: quotaFound ? Int(sqlite3_column_int(quota, 0)) : nil,
            quotaSampledAt: quotaFound ? Date(timeIntervalSince1970: sqlite3_column_double(quota, 1)) : nil)
    }
}

fileprivate struct ParserState: Codable {
    var sessionID: String?
    var projectPath: String?
    var providerID: String?
    var modelID: String?
    var lastCumulative: Int64?
    var occurrences: [String: Int] = [:]
    var skipUntilNewline = false
    var lastObservedSize: UInt64?
    var lastObservedModificationDate: Date?
    var needsCatchUp = false
    var antigravityParserRevision: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionID, projectPath, providerID, modelID, lastCumulative, occurrences, skipUntilNewline,
             lastObservedSize, lastObservedModificationDate, needsCatchUp, antigravityParserRevision
    }

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try box.decodeIfPresent(String.self, forKey: .sessionID)
        projectPath = try box.decodeIfPresent(String.self, forKey: .projectPath)
        providerID = try box.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try box.decodeIfPresent(String.self, forKey: .modelID)
        lastCumulative = try box.decodeIfPresent(Int64.self, forKey: .lastCumulative)
        occurrences = try box.decodeIfPresent([String: Int].self, forKey: .occurrences) ?? [:]
        skipUntilNewline = try box.decodeIfPresent(Bool.self, forKey: .skipUntilNewline) ?? false
        lastObservedSize = try box.decodeIfPresent(UInt64.self, forKey: .lastObservedSize)
        lastObservedModificationDate = try box.decodeIfPresent(Date.self, forKey: .lastObservedModificationDate)
        needsCatchUp = try box.decodeIfPresent(Bool.self, forKey: .needsCatchUp) ?? false
        antigravityParserRevision = try box.decodeIfPresent(Int.self, forKey: .antigravityParserRevision)
    }
}

fileprivate struct FileCheckpoint {
    var inode: String
    var offset: UInt64
    var trackingSince: Date
    var lastScan: Date
    var gap: String?
    var state: ParserState
}

public struct HistoricalScanResult: Sendable {
    public let harnessID: String
    public let filesScanned: Int
    public let recordsRead: Int
    public let complete: Bool
    public let diagnostic: String?
    public let readFailures: Int
    /// Only for a bounded recent pass; never implies historical completeness.
    public let pendingRecentWork: Bool

    public init(harnessID: String, filesScanned: Int, recordsRead: Int,
                complete: Bool, diagnostic: String?, readFailures: Int = 0,
                pendingRecentWork: Bool = false) {
        self.harnessID = harnessID
        self.filesScanned = filesScanned
        self.recordsRead = recordsRead
        self.complete = complete
        self.diagnostic = diagnostic
        self.readFailures = readFailures
        self.pendingRecentWork = pendingRecentWork
    }
}

public final class HistoricalUsageEngine {
    public let store: HistoricalUsageStore
    public let sources: [HistoricalSource]
    public var maxFilesPerSource = 80
    public var maxBytesPerSource = 32 * 1024 * 1024
    public var maxBytesPerFile = 4 * 1024 * 1024
    public var bootstrapTailBytes = 512 * 1024
    /// A foreground-only Claude tail pass. The regular 120-second inventory
    /// remains authoritative for source coverage and historical diagnostics.
    public var recentClaudeMaxFiles = 4
    public var recentClaudeMaxBytes = 2 * 1024 * 1024
    public var recentClaudeMaxBytesPerFile = 1024 * 1024
    public var recentClaudeFileAge: TimeInterval = 5 * 60

    public init(store: HistoricalUsageStore, sources: [HistoricalSource] = HistoricalSource.defaults()) {
        self.store = store
        self.sources = sources
    }

    public func scan(now: Date = Date()) throws -> [HistoricalScanResult] {
        try sources.map { try scan($0, now: now) }
    }

    /// Imports only recently modified Claude session tails through the same
    /// checkpoints, transactions and event identities as the historical scan.
    /// Deliberately does not write source_scans: a quick tail is not a complete
    /// inventory, even if every chosen file was read successfully.
    public func scanRecentClaude(now: Date = Date()) throws -> HistoricalScanResult {
        guard let source = sources.first(where: { $0.harnessID == "claude-code" }),
              FileManager.default.isReadableFile(atPath: source.root.path) else {
            return HistoricalScanResult(harnessID: "claude-code", filesScanned: 0,
                recordsRead: 0, complete: false, diagnostic: "Source absente ou illisible",
                pendingRecentWork: true)
        }
        let candidates = UsageFiles.files(in: source.root, extension: "jsonl", recursive: true)
            .compactMap { file -> (URL, Date)? in
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= now.addingTimeInterval(-recentClaudeFileAge) else { return nil }
                return (file, modified)
            }
            .sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        // Inspect metadata/checkpoints for every recently touched file, but
        // never its content until it has a real delta. Unchanged files cannot
        // consume the four-file work budget or starve a fifth active session.
        var changed: [URL] = []
        var pendingUnterminated = 0, failures = 0
        for (file, _) in candidates {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue,
                      let modified = attributes[.modificationDate] as? Date else {
                    failures += 1
                    continue
                }
                let previous = try store.checkpoint(harness: source.harnessID, path: file.path)
                let delta = previous == nil || previous!.inode != inode || previous!.offset > size ||
                    previous!.state.needsCatchUp ||
                    previous!.state.lastObservedSize != size ||
                    previous!.state.lastObservedModificationDate != modified
                if delta { changed.append(file) }
                else if previous!.offset < size { pendingUnterminated += 1 }
            } catch { failures += 1 }
        }
        var budget = max(0, recentClaudeMaxBytes)
        var scanned = 0, count = 0, pendingBytes = 0
        for file in changed.prefix(max(0, recentClaudeMaxFiles)) where budget > 0 {
            do {
                let result = try scanFile(file, source: source, now: now,
                    budget: min(budget, max(1, recentClaudeMaxBytesPerFile)),
                    rescanSameSizeChange: true)
                budget -= result.bytesRead
                count += result.recordsRead
                scanned += 1
                if result.pendingBytes { pendingBytes += 1 }
            } catch { failures += 1 }
        }
        let limited = changed.count > scanned
        let pending = limited || pendingBytes > 0 || pendingUnterminated > 0 || failures > 0
        return HistoricalScanResult(harnessID: source.harnessID, filesScanned: scanned,
            recordsRead: count, complete: false,
            diagnostic: "Passe récente bornée · couverture historique inchangée\(pending ? " · import en attente" : "")\(failures > 0 ? " · \(failures) erreur(s)" : "")",
            readFailures: failures, pendingRecentWork: pending)
    }

    public func scanRecentGemini(now: Date = Date()) throws -> HistoricalScanResult {
        guard let source = sources.first(where: { $0.harnessID == "gemini-cli" }),
              isSourceReadable(source) else {
            return HistoricalScanResult(harnessID: "gemini-cli", filesScanned: 0,
                recordsRead: 0, complete: false, diagnostic: "Source absente ou illisible",
                pendingRecentWork: true)
        }
        let candidates = candidateFiles(for: source)
            .compactMap { file -> (URL, Date)? in
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= now.addingTimeInterval(-recentClaudeFileAge) else { return nil }
                return (file, modified)
            }
            .sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        var changed: [URL] = []
        var pendingUnterminated = 0, failures = 0
        for (file, _) in candidates {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue,
                      let modified = attributes[.modificationDate] as? Date else {
                    failures += 1
                    continue
                }
                let previous = try store.checkpoint(harness: source.harnessID, path: file.path)
                let delta = previous == nil || previous!.inode != inode || previous!.offset > size ||
                    (file.lastPathComponent == "transcript.jsonl" && previous!.state.antigravityParserRevision != 1) ||
                    previous!.state.needsCatchUp ||
                    previous!.state.lastObservedSize != size ||
                    previous!.state.lastObservedModificationDate != modified
                if delta { changed.append(file) }
                else if previous!.offset < size { pendingUnterminated += 1 }
            } catch { failures += 1 }
        }
        var budget = max(0, recentClaudeMaxBytes)
        var scanned = 0, count = 0, pendingBytes = 0
        for file in changed.prefix(max(0, recentClaudeMaxFiles)) where budget > 0 {
            do {
                let result = try scanFile(file, source: source, now: now,
                    budget: min(budget, max(1, recentClaudeMaxBytesPerFile)),
                    rescanSameSizeChange: true)
                budget -= result.bytesRead
                count += result.recordsRead
                scanned += 1
                if result.pendingBytes { pendingBytes += 1 }
            } catch { failures += 1 }
        }
        let limited = changed.count > scanned
        let pending = limited || pendingBytes > 0 || pendingUnterminated > 0 || failures > 0
        return HistoricalScanResult(harnessID: source.harnessID, filesScanned: scanned,
            recordsRead: count, complete: false,
            diagnostic: "Passe récente bornée · couverture historique inchangée\(pending ? " · import en attente" : "")\(failures > 0 ? " · \(failures) erreur(s)" : "")",
            readFailures: failures, pendingRecentWork: pending)
    }

    private func isSourceReadable(_ source: HistoricalSource) -> Bool {
        let manager = FileManager.default
        if manager.isReadableFile(atPath: source.root.path) { return true }
        if let brain = source.antigravityBrainRoot, manager.isReadableFile(atPath: brain.path) { return true }
        return false
    }

    private func candidateFiles(for source: HistoricalSource) -> [URL] {
        let ext = source.harnessID == "ollama" ? "log" : "jsonl"
        var files = UsageFiles.files(in: source.root, extension: ext, recursive: source.harnessID != "ollama")
            .filter { file in
                switch source.harnessID {
                case "codex": return file.lastPathComponent.hasPrefix("rollout-")
                case "gemini-cli": return file.pathComponents.contains("chats")
                case "ollama": return file.lastPathComponent.hasPrefix("server")
                default: return true
                }
            }
        if source.harnessID == "gemini-cli", let brain = source.antigravityBrainRoot {
            files.append(contentsOf: UsageFiles.antigravityTranscriptFiles(in: brain))
        }
        return files
    }

    private func scan(_ source: HistoricalSource, now: Date) throws -> HistoricalScanResult {
        guard isSourceReadable(source) else {
            try store.recordScan(harness: source.harnessID, at: now, complete: false,
                                 inventoriedSince: nil, diagnostic: "Source absente ou illisible")
            return HistoricalScanResult(harnessID: source.harnessID, filesScanned: 0, recordsRead: 0,
                                        complete: false, diagnostic: "Source absente ou illisible")
        }
        let all = candidateFiles(for: source)
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        var budget = maxBytesPerSource
        var scanned = 0, count = 0, failures = 0
        var oldestInventoried: Date?
        for file in all.prefix(maxFilesPerSource) where budget > 0 {
            do {
                let result = try scanFile(file, source: source, now: now,
                                          budget: min(budget, maxBytesPerFile))
                budget -= result.bytesRead
                count += result.recordsRead
                scanned += 1
                if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    oldestInventoried = min(oldestInventoried ?? modified, modified)
                } else { failures += 1 }
            } catch { failures += 1 }
        }
        let complete = failures == 0 && all.count <= maxFilesPerSource && scanned == all.count
        let diagnostic: String? = complete ? nil : "Inventaire/lecture partiel(le) : \(scanned)/\(all.count) fichiers, \(failures) erreur(s)"
        try store.recordScan(harness: source.harnessID, at: now, complete: complete,
                             inventoriedSince: failures == 0 ? oldestInventoried : nil, diagnostic: diagnostic)
        return HistoricalScanResult(harnessID: source.harnessID, filesScanned: scanned,
                                    recordsRead: count, complete: complete, diagnostic: diagnostic,
                                    readFailures: failures)
    }

    private func scanFile(_ file: URL, source: HistoricalSource, now: Date,
                          budget: Int, rescanSameSizeChange: Bool = false) throws
                          -> (bytesRead: Int, recordsRead: Int, pendingBytes: Bool) {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue else {
            throw HistoricalUsageError.sqlite("Fichier non régulier ou inode indisponible : \(file.path)")
        }
        let previous = try store.checkpoint(harness: source.harnessID, path: file.path)
        let modified = attributes[.modificationDate] as? Date
        // One bounded replay repairs model attribution from the unfinished
        // Antigravity importer. Stable event IDs upsert, never delete history.
        let antigravity = source.harnessID == "gemini-cli" && file.lastPathComponent == "transcript.jsonl"
        let parserUpgrade = antigravity && previous != nil && previous!.state.antigravityParserRevision != 1
        let sameSizeChange = rescanSameSizeChange && previous != nil &&
            previous!.offset == size && previous!.state.lastObservedSize == size &&
            previous!.state.lastObservedModificationDate != modified
        let rotated = previous != nil && (previous!.inode != inode || previous!.offset > size || sameSizeChange || parserUpgrade)
        let start: UInt64
        if parserUpgrade { start = 0 }
        else if let previous, !rotated { start = previous.offset }
        else { start = size > UInt64(bootstrapTailBytes) ? size - UInt64(bootstrapTailBytes) : 0 }
        var state = rotated ? ParserState() : previous?.state ?? ParserState()
        if previous == nil || rotated { seedMetadata(file: file, source: source, state: &state) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        var pending = Data(), records: [UnifiedUsageRecord] = []
        var consumed = 0, lastComplete = start, dropping = false
        var discardFirst = state.skipUntilNewline || (start > 0 && (try? byteBefore(start, in: handle)) != 10)
        try handle.seek(toOffset: start)
        while consumed < budget, let chunk = try handle.read(upToCount: min(64 * 1024, budget - consumed)), !chunk.isEmpty {
            let chunkStart = start + UInt64(consumed)
            consumed += chunk.count
            var segmentStart = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                let end = chunkStart + UInt64(index - chunk.startIndex) + 1
                if !discardFirst && !dropping {
                    pending.append(chunk[segmentStart..<index])
                    if pending.count <= 4 * 1024 * 1024 {
                        records.append(contentsOf: parse(pending, file: file, source: source,
                                                         inode: inode, lineEnd: end, state: &state))
                    }
                }
                pending.removeAll(keepingCapacity: true)
                dropping = false
                discardFirst = false
                state.skipUntilNewline = false
                segmentStart = chunk.index(after: index)
                lastComplete = end
            }
            if segmentStart < chunk.endIndex && !dropping {
                pending.append(chunk[segmentStart..<chunk.endIndex])
                if pending.count > 4 * 1024 * 1024 { pending.removeAll(keepingCapacity: false); dropping = true }
            }
        }
        let skippedLongLine = dropping || (pending.count >= 4 * 1024 * 1024 && size > start + UInt64(consumed))
        if (discardFirst || skippedLongLine) && lastComplete < start + UInt64(consumed) {
            // The first tail fragment or an oversized line is intentionally
            // skipped. Persist the skip state without persisting its content.
            lastComplete = start + UInt64(consumed)
            state.skipUntilNewline = true
        }
        var gap = (previous == nil || rotated) && start > 0
            ? "Préfixe de \(file.lastPathComponent) non relu (amorçage borné ou rotation)" : previous?.gap
        if skippedLongLine { gap = [gap, "Ligne > 4 Mio ignorée dans \(file.lastPathComponent)"].compactMap { $0 }.joined(separator: " ; ") }
        state.lastObservedSize = size
        state.lastObservedModificationDate = modified
        state.needsCatchUp = start + UInt64(consumed) < size
        if antigravity { state.antigravityParserRevision = 1 }
        let checkpoint = FileCheckpoint(inode: inode, offset: lastComplete,
            trackingSince: previous?.trackingSince ?? now, lastScan: now, gap: gap, state: state)
        try store.commit(records: records, checkpoint: checkpoint, harness: source.harnessID, path: file.path)
        return (consumed, records.count, lastComplete < size)
    }

    private func byteBefore(_ offset: UInt64, in handle: FileHandle) throws -> UInt8? {
        guard offset > 0 else { return nil }
        try handle.seek(toOffset: offset - 1)
        return try handle.read(upToCount: 1)?.first
    }

    private func seedMetadata(file: URL, source: HistoricalSource, state: inout ParserState) {
        if source.harnessID == "gemini-cli" {
            let parts = file.pathComponents
            if let chats = parts.lastIndex(of: "chats"), chats > 0, let root = source.historyRoot {
                let marker = root.appendingPathComponent(parts[chats - 1]).appendingPathComponent(".project_root")
                let cwd = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                state.projectPath = cwd.flatMap { $0.hasPrefix("/") && $0 != "/" ? $0 : nil }
            }
        }
        guard source.harnessID == "codex" || source.harnessID == "gemini-cli",
              let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), let newline = data.firstIndex(of: 10),
              let object = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] else { return }
        if source.harnessID == "gemini-cli" { state.sessionID = object["sessionId"] as? String }
        if source.harnessID == "codex", object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any] {
            state.projectPath = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            state.providerID = payload["model_provider"] as? String
            state.sessionID = payload["id"] as? String
        }
    }

    private func parse(_ line: Data, file: URL, source: HistoricalSource, inode: String,
                       lineEnd: UInt64, state: inout ParserState) -> [UnifiedUsageRecord] {
        if source.harnessID == "ollama" {
            guard let text = String(data: line, encoding: .utf8) else { return [] }
            return LocalModelAdapter.parse(text, occurrences: &state.occurrences, file: file,
                eventIDOverride: "ollama:\(UsageIdentity.hash(file.path)):\(inode):\(lineEnd)").map { [$0] } ?? []
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        switch source.harnessID {
        case "claude-code": return ClaudeCodeAdapter.parse(object, file: file).map { [$0] } ?? []
        case "gemini-cli":
            if let session = object["sessionId"] as? String { state.sessionID = session }
            let messages = (object["$set"] as? [String: Any])?["messages"] as? [[String: Any]]
            return (messages ?? [object]).compactMap { GeminiAdapter.parse($0, session: state.sessionID,
                projectPath: state.projectPath, file: file) }
        case "codex":
            guard let payload = object["payload"] as? [String: Any] else { return [] }
            if object["type"] as? String == "session_meta" {
                state.projectPath = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
                state.providerID = payload["model_provider"] as? String
                state.sessionID = payload["id"] as? String
                return []
            }
            if object["type"] as? String == "turn_context" {
                state.modelID = payload["model"] as? String
                return []
            }
            guard payload["type"] as? String == "token_count",
                  let date = UsageFiles.date(object["timestamp"] as? String),
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let input = UsageFiles.integer(usage["input_tokens"]),
                  let output = UsageFiles.integer(usage["output_tokens"]),
                  input > 0 || output > 0 else { return [] }
            if let cumulative = UsageFiles.integer((info["total_token_usage"] as? [String: Any])?["total_tokens"]) {
                if cumulative == state.lastCumulative { return [] }
                state.lastCumulative = cumulative
            }
            return CodexUsageNormalizer().normalize(CodexLocalUsage(
                eventID: "codex:\(file.path):\(inode):\(lineEnd)", timestamp: date,
                projectPath: state.projectPath, sessionID: state.sessionID ?? file.lastPathComponent,
                inputTokens: input, outputTokens: output,
                cachedInputTokens: UsageFiles.integer(usage["cached_input_tokens"]),
                providerID: state.providerID, modelID: state.modelID,
                reasoningTokens: UsageFiles.integer(usage["reasoning_output_tokens"]))).map { [$0] } ?? []
        default: return []
        }
    }
}
