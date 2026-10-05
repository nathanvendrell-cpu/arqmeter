import Foundation
import SQLite3

public struct HistoricalSource: Sendable {
    public let harnessID: String
    public let root: URL
    public let historyRoot: URL?

    public init(harnessID: String, root: URL, historyRoot: URL? = nil) {
        self.harnessID = harnessID
        self.root = root
        self.historyRoot = historyRoot
    }

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        [Self(harnessID: "codex", root: home.appendingPathComponent(".codex/sessions")),
         Self(harnessID: "claude-code", root: home.appendingPathComponent(".claude/projects")),
         Self(harnessID: "gemini-cli", root: home.appendingPathComponent(".gemini/tmp"),
              historyRoot: home.appendingPathComponent(".gemini/history")),
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

    private enum CodingKeys: String, CodingKey {
        case sessionID, projectPath, providerID, modelID, lastCumulative, occurrences, skipUntilNewline
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
}

public final class HistoricalUsageEngine {
    public let store: HistoricalUsageStore
    public let sources: [HistoricalSource]
    public var maxFilesPerSource = 80
    public var maxBytesPerSource = 32 * 1024 * 1024
    public var maxBytesPerFile = 4 * 1024 * 1024
    public var bootstrapTailBytes = 512 * 1024

    public init(store: HistoricalUsageStore, sources: [HistoricalSource] = HistoricalSource.defaults()) {
        self.store = store
        self.sources = sources
    }

    public func scan(now: Date = Date()) throws -> [HistoricalScanResult] {
        try sources.map { try scan($0, now: now) }
    }

    private func scan(_ source: HistoricalSource, now: Date) throws -> HistoricalScanResult {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: source.root.path) else {
            try store.recordScan(harness: source.harnessID, at: now, complete: false,
                                 inventoriedSince: nil, diagnostic: "Source absente ou illisible")
            return HistoricalScanResult(harnessID: source.harnessID, filesScanned: 0, recordsRead: 0,
                                        complete: false, diagnostic: "Source absente ou illisible")
        }
        let ext = source.harnessID == "ollama" ? "log" : "jsonl"
        let all = UsageFiles.files(in: source.root, extension: ext, recursive: source.harnessID != "ollama")
            .filter { file in
                switch source.harnessID {
                case "codex": return file.lastPathComponent.hasPrefix("rollout-")
                case "gemini-cli": return file.pathComponents.contains("chats")
                case "ollama": return file.lastPathComponent.hasPrefix("server")
                default: return true
                }
            }
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
                                    recordsRead: count, complete: complete, diagnostic: diagnostic)
    }

    private func scanFile(_ file: URL, source: HistoricalSource, now: Date,
                          budget: Int) throws -> (bytesRead: Int, recordsRead: Int) {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue else {
            throw HistoricalUsageError.sqlite("Fichier non régulier ou inode indisponible : \(file.path)")
        }
        let previous = try store.checkpoint(harness: source.harnessID, path: file.path)
        let rotated = previous != nil && (previous!.inode != inode || previous!.offset > size)
        let start: UInt64
        if let previous, !rotated { start = previous.offset }
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
        let checkpoint = FileCheckpoint(inode: inode, offset: lastComplete,
            trackingSince: previous?.trackingSince ?? now, lastScan: now, gap: gap, state: state)
        try store.commit(records: records, checkpoint: checkpoint, harness: source.harnessID, path: file.path)
        return (consumed, records.count)
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
