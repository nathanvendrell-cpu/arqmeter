import Foundation

public struct UsageSourceSnapshot: Sendable {
    public let harnessID: String
    public let displayName: String
    public let installed: Bool
    public let readable: Bool
    public let records: [UnifiedUsageRecord]
    public let quotaRemainingPercent: UsageMeasurement<Int>
    public let quotaSampledAt: Date?
    public let coverage: String
    public let diagnostic: String?

    public init(harnessID: String, displayName: String? = nil, installed: Bool, readable: Bool,
                records: [UnifiedUsageRecord], coverage: String, diagnostic: String? = nil,
                quotaRemainingPercent: UsageMeasurement<Int> = .unavailable,
                quotaSampledAt: Date? = nil) {
        self.harnessID = harnessID
        self.displayName = displayName ?? harnessID
        self.installed = installed
        self.readable = readable
        self.records = records
        self.quotaRemainingPercent = quotaRemainingPercent
        self.quotaSampledAt = quotaSampledAt
        self.coverage = coverage
        self.diagnostic = diagnostic
    }

    public var lastRecord: UnifiedUsageRecord? { records.max { $0.timestamp < $1.timestamp } }
}

public protocol UnifiedUsageAdapter {
    var harnessID: String { get }
    func read() -> UsageSourceSnapshot
}

public struct CodexAdapter: UnifiedUsageAdapter {
    public let harnessID = "codex"
    private let records: [UnifiedUsageRecord]
    private let installed: Bool
    private let readable: Bool
    private let quotaRemainingPercent: Int?
    private let quotaSampledAt: Date?

    public init(records: [UnifiedUsageRecord], installed: Bool, readable: Bool,
                quotaRemainingPercent: Int? = nil, quotaSampledAt: Date? = nil) {
        self.records = records
        self.installed = installed
        self.readable = readable
        self.quotaRemainingPercent = quotaRemainingPercent
        self.quotaSampledAt = quotaSampledAt
    }

    public func read() -> UsageSourceSnapshot {
        UsageSourceSnapshot(harnessID: harnessID, displayName: "Codex", installed: installed, readable: readable,
                            records: records, coverage: "Journaux locaux · dernières 24 h",
                            quotaRemainingPercent: quotaRemainingPercent.map(UsageMeasurement.measured) ?? .unavailable,
                            quotaSampledAt: quotaSampledAt)
    }
}

/// A stable fingerprint for log lines without storing their prompts or content.
public enum UsageIdentity {
    public static func hash(_ text: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(value, radix: 16)
    }
}

enum UsageFiles {
    static func files(in root: URL, extension ext: String, recursive: Bool) -> [URL] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let urls: [URL]
        if recursive {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        }
        return urls.filter { url in
            guard url.pathExtension == ext, let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.path < $1.path }
    }

    /// Streaming, bounded-memory JSONL reader. An incomplete last line is never imported.
    static func lines(at url: URL, maxLineBytes: Int = 4 * 1024 * 1024,
                      tailBytes: Int? = nil,
                      _ body: (Data, Int) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var discardFirst = false
        if let tailBytes,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
           size > UInt64(tailBytes) {
            try handle.seek(toOffset: size - UInt64(tailBytes))
            discardFirst = true
        }
        var pending = Data()
        var dropping = false
        var lineNumber = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 10 {
                lineNumber += 1
                if discardFirst { discardFirst = false }
                else if !dropping {
                    pending.append(chunk[start..<index])
                    if pending.count <= maxLineBytes {
                        autoreleasepool { body(pending, lineNumber) }
                    }
                }
                pending.removeAll(keepingCapacity: true)
                dropping = false
                start = chunk.index(after: index)
            }
            if start < chunk.endIndex && !dropping {
                pending.append(chunk[start..<chunk.endIndex])
                if pending.count > maxLineBytes { pending.removeAll(keepingCapacity: false); dropping = true }
            }
        }
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return full.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.int64Value
        return result >= 0 ? result : nil
    }

    static func installed(_ name: String) -> Bool {
        let manager = FileManager.default
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return search.contains { manager.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) }
    }
}

public struct ClaudeCodeAdapter: UnifiedUsageAdapter {
    public let harnessID = "claude-code"
    public let root: URL
    public let installed: Bool

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
                installed: Bool? = nil) {
        self.root = root
        self.installed = installed ?? UsageFiles.installed("claude")
    }

    public func read() -> UsageSourceSnapshot {
        let readable = FileManager.default.isReadableFile(atPath: root.path)
        var byID: [String: UnifiedUsageRecord] = [:]
        var failures = 0
        var truncated = 0
        var budget = 64 * 1024 * 1024
        let files = UsageFiles.files(in: root, extension: "jsonl", recursive: true)
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        var scanned = 0
        for file in files where budget > 0 {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            let bytes = min(4 * 1024 * 1024, budget)
            if size > bytes { truncated += 1 }
            budget -= min(size, bytes)
            scanned += 1
            do {
                try UsageFiles.lines(at: file, tailBytes: bytes) { line, _ in
                    guard line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
                          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let record = Self.parse(object, file: file) else { return }
                    if let old = byID[record.eventID] {
                        // Claude may write the same message repeatedly while streaming.
                        if (record.outputTokens.value ?? 0) >= (old.outputTokens.value ?? 0) { byID[record.eventID] = record }
                    } else { byID[record.eventID] = record }
                }
            } catch { failures += 1 }
        }
        return UsageSourceSnapshot(harnessID: harnessID, displayName: "Claude Code", installed: installed, readable: readable,
            records: byID.values.sorted { $0.timestamp < $1.timestamp },
            coverage: "\(scanned)/\(files.count) sessions récentes · lecture bornée à 64 Mio (4 Mio/fichier)",
            diagnostic: "Historique partiel\(truncated > 0 ? " · \(truncated) fichier(s) lus par la fin" : "")\(failures > 0 ? " · \(failures) illisible(s)" : "")")
    }

    static func parse(_ object: [String: Any], file: URL) -> UnifiedUsageRecord? {
        guard object["type"] as? String == "assistant",
              let session = object["sessionId"] as? String, !session.isEmpty,
              let message = object["message"] as? [String: Any],
              let messageID = message["id"] as? String, !messageID.isEmpty,
              let usage = message["usage"] as? [String: Any],
              let date = UsageFiles.date(object["timestamp"] as? String),
              let direct = UsageFiles.integer(usage["input_tokens"]),
              let output = UsageFiles.integer(usage["output_tokens"]) else { return nil }
        let observedCreated = UsageFiles.integer(usage["cache_creation_input_tokens"])
        let observedRead = UsageFiles.integer(usage["cache_read_input_tokens"])
        let created = observedCreated ?? 0
        let read = observedRead ?? 0
        let (first, firstOverflow) = direct.addingReportingOverflow(created)
        let (input, secondOverflow) = first.addingReportingOverflow(read)
        let (combined, combinedOverflow) = input.addingReportingOverflow(output)
        guard !firstOverflow, !secondOverflow, !combinedOverflow, combined > 0 else { return nil }
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard model != "<synthetic>" else { return nil }
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        return UnifiedUsageRecord(eventID: "claude:\(session):\(messageID)", timestamp: date,
            projectPath: cwd, sessionID: session, harnessID: "claude-code",
            providerID: model?.hasPrefix("claude-") == true ? "anthropic" : nil, modelID: model,
            inputTokens: observedCreated != nil && observedRead != nil ? .measured(input) : .estimated(input),
            outputTokens: .measured(output),
            cachedInputTokens: observedRead.map(UsageMeasurement.measured) ?? .unavailable,
            reasoningTokens: .unavailable, costUSD: .unavailable, durationSeconds: .unavailable,
            executionLocation: .cloud, sourceKind: .claudeCodeSessionLog,
            provenance: "\(file.lastPathComponent) · message.usage · entrée = directe + création cache + lecture cache")
    }
}

public struct GeminiAdapter: UnifiedUsageAdapter {
    public let harnessID = "gemini-cli"
    public let root: URL
    public let historyRoot: URL
    public let installed: Bool

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp"),
                historyRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/history"),
                installed: Bool? = nil) {
        self.root = root
        self.historyRoot = historyRoot
        self.installed = installed ?? UsageFiles.installed("gemini")
    }

    public func read() -> UsageSourceSnapshot {
        let readable = FileManager.default.isReadableFile(atPath: root.path)
        var byID: [String: UnifiedUsageRecord] = [:]
        var failures = 0
        for file in UsageFiles.files(in: root, extension: "jsonl", recursive: true)
            where file.pathComponents.contains("chats") {
            let components = file.pathComponents
            guard let chats = components.lastIndex(of: "chats"), chats > 0 else { continue }
            let slug = components[chats - 1]
            let rootFile = historyRoot.appendingPathComponent(slug).appendingPathComponent(".project_root")
            let cwd = (try? String(contentsOf: rootFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = cwd.flatMap { $0.hasPrefix("/") && $0 != "/" ? $0 : nil }
            var session: String?
            do {
                try UsageFiles.lines(at: file) { line, _ in
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    if let value = object["sessionId"] as? String { session = value }
                    let messages = (object["$set"] as? [String: Any])?["messages"] as? [[String: Any]]
                    for message in messages ?? [object] {
                        guard let record = Self.parse(message, session: session, projectPath: projectPath, file: file) else { continue }
                        byID[record.eventID] = record
                    }
                }
            } catch { failures += 1 }
        }
        return UsageSourceSnapshot(harnessID: harnessID, displayName: "Gemini CLI", installed: installed, readable: readable,
            records: byID.values.sorted { $0.timestamp < $1.timestamp },
            coverage: "Messages Gemini des sessions ~/.gemini/tmp/*/chats",
            diagnostic: failures > 0 ? "\(failures) journal(aux) illisible(s) · résultat partiel" : nil)
    }

    static func parse(_ message: [String: Any], session: String?, projectPath: String?, file: URL) -> UnifiedUsageRecord? {
        guard message["type"] as? String == "gemini",
              let session, !session.isEmpty,
              let id = message["id"] as? String, !id.isEmpty,
              let date = UsageFiles.date(message["timestamp"] as? String),
              let tokens = message["tokens"] as? [String: Any],
              let input = UsageFiles.integer(tokens["input"]),
              let output = UsageFiles.integer(tokens["output"]) else { return nil }
        let (combined, overflow) = input.addingReportingOverflow(output)
        guard !overflow, combined > 0 || (UsageFiles.integer(tokens["thoughts"]) ?? 0) > 0 else { return nil }
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return UnifiedUsageRecord(eventID: "gemini:\(session):\(id)", timestamp: date,
            projectPath: projectPath, sessionID: session, harnessID: "gemini-cli",
            providerID: model?.hasPrefix("gemini-") == true ? "google" : nil, modelID: model,
            inputTokens: .measured(input), outputTokens: .measured(output),
            cachedInputTokens: UsageFiles.integer(tokens["cached"]).map(UsageMeasurement.measured) ?? .unavailable,
            reasoningTokens: UsageFiles.integer(tokens["thoughts"]).map(UsageMeasurement.measured) ?? .unavailable,
            costUSD: .unavailable, durationSeconds: .unavailable, executionLocation: .cloud,
            sourceKind: .geminiSessionLog,
            provenance: "\(file.lastPathComponent) · message.tokens · projet via .project_root si présent")
    }
}

public struct LocalModelAdapter: UnifiedUsageAdapter {
    public let harnessID = "ollama"
    public let root: URL
    public let installed: Bool

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/logs"),
                installed: Bool? = nil) {
        self.root = root
        self.installed = installed ?? UsageFiles.installed("ollama")
    }

    public func read() -> UsageSourceSnapshot {
        let readable = FileManager.default.isReadableFile(atPath: root.path)
        var byID: [String: UnifiedUsageRecord] = [:]
        var failures = 0
        for file in UsageFiles.files(in: root, extension: "log", recursive: false)
            where file.lastPathComponent.hasPrefix("server") {
            var occurrences: [String: Int] = [:]
            do {
                try UsageFiles.lines(at: file, maxLineBytes: 64 * 1024) { data, _ in
                    guard let line = String(data: data, encoding: .utf8),
                          let record = Self.parse(line, occurrences: &occurrences, file: file) else { return }
                    byID[record.eventID] = record
                }
            } catch { failures += 1 }
        }
        return UsageSourceSnapshot(harnessID: harnessID, displayName: "Ollama · local", installed: installed, readable: readable,
            records: byID.values.sorted { $0.timestamp < $1.timestamp },
            coverage: "Requêtes HTTP 200 du serveur Ollama · durée seulement",
            diagnostic: failures > 0 ? "\(failures) journal(aux) illisible(s) · résultat partiel" : nil)
    }

    static func parse(_ line: String, occurrences: inout [String: Int], file: URL,
                      eventIDOverride: String? = nil) -> UnifiedUsageRecord? {
        guard line.hasPrefix("[GIN] "),
              line.contains("POST"),
              line.contains("\"/api/chat\"") || line.contains("\"/api/generate\"") else { return nil }
        let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 5, parts[1] == "200" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        guard let date = formatter.date(from: String(parts[0].dropFirst(6))) else { return nil }
        let durationText = parts[2]
        let seconds: Double
        if durationText.hasSuffix("ms") { seconds = (Double(durationText.dropLast(2)) ?? -1) / 1_000 }
        else if durationText.hasSuffix("µs") { seconds = (Double(durationText.dropLast(2)) ?? -1) / 1_000_000 }
        else if durationText.hasSuffix("s") { seconds = Double(durationText.dropLast()) ?? -1 }
        else { return nil }
        guard seconds >= 0 else { return nil }
        let hash = UsageIdentity.hash(line)
        let occurrence = occurrences[hash, default: 0]
        occurrences[hash] = occurrence + 1
        let id = eventIDOverride ?? "ollama:\(hash):\(occurrence)"
        return UnifiedUsageRecord(eventID: id, timestamp: date, projectPath: nil,
            sessionID: "request:\(id)", harnessID: "ollama", providerID: "ollama", modelID: nil,
            inputTokens: .unavailable, outputTokens: .unavailable, cachedInputTokens: .unavailable,
            reasoningTokens: .unavailable, costUSD: .unavailable, durationSeconds: .measured(seconds),
            executionLocation: .local, sourceKind: .ollamaServerLog,
            provenance: "\(file.lastPathComponent) · HTTP 200 /api/chat ou /api/generate · durée serveur ; modèle non journalisé")
    }
}

public struct UsageMetricTotal: Equatable, Sendable {
    public let value: Int64?
    public let coveredRecords: Int
    public let totalRecords: Int
    public let containsEstimates: Bool
    public var complete: Bool { coveredRecords > 0 && coveredRecords == totalRecords && !containsEstimates }
}

public struct UsageAggregate: Sendable {
    public let records: [UnifiedUsageRecord]
    public let inputTokens: UsageMetricTotal
    public let outputTokens: UsageMetricTotal
    public let cachedInputTokens: UsageMetricTotal
    public let reasoningTokens: UsageMetricTotal
    public let durationSeconds: Double?
    public let durationCoverage: Int
    public let costUSD: UsageMeasurement<Decimal>
    public let costCoverage: Int

    public init(records: [UnifiedUsageRecord]) {
        var seen: Set<String> = []
        self.records = records.filter { seen.insert($0.eventID).inserted }.sorted { $0.timestamp < $1.timestamp }
        inputTokens = Self.sum(self.records.map(\.inputTokens))
        outputTokens = Self.sum(self.records.map(\.outputTokens))
        cachedInputTokens = Self.sum(self.records.map(\.cachedInputTokens))
        reasoningTokens = Self.sum(self.records.map(\.reasoningTokens))
        let durations = self.records.compactMap { $0.durationSeconds.value }
        durationCoverage = durations.count
        durationSeconds = durations.isEmpty ? nil : durations.reduce(0, +)
        let costs = self.records.compactMap { $0.costUSD.value }
        costCoverage = costs.count
        if costs.isEmpty { costUSD = .unavailable }
        else {
            let sum = costs.reduce(Decimal(0), +)
            costUSD = self.records.contains { if case .estimated = $0.costUSD { return true }; return false }
                ? .estimated(sum) : .measured(sum)
        }
    }

    private static func sum(_ values: [UsageMeasurement<Int64>]) -> UsageMetricTotal {
        var total: Int64 = 0
        var covered = 0
        var estimated = false
        for value in values {
            guard let number = value.value else { continue }
            let (next, overflow) = total.addingReportingOverflow(number)
            guard !overflow else { return UsageMetricTotal(value: nil, coveredRecords: covered, totalRecords: values.count, containsEstimates: true) }
            total = next
            covered += 1
            if case .estimated = value { estimated = true }
        }
        return UsageMetricTotal(value: covered == 0 ? nil : total, coveredRecords: covered,
                                totalRecords: values.count, containsEstimates: estimated)
    }
}

public struct UnifiedUsage: Sendable {
    public let sources: [UsageSourceSnapshot]
    public let records: [UnifiedUsageRecord]

    public init(sources: [UsageSourceSnapshot]) {
        self.sources = sources
        self.records = UsageAggregate(records: sources.flatMap(\.records)).records
    }

    public func aggregate(from start: Date? = nil, to end: Date? = nil) -> UsageAggregate {
        UsageAggregate(records: records.filter { (start == nil || $0.timestamp >= start!) && (end == nil || $0.timestamp < end!) })
    }

    public func byHarness(from start: Date? = nil, to end: Date? = nil) -> [String: UsageAggregate] {
        groups(\.harnessID, from: start, to: end)
    }

    public func byProvider(from start: Date? = nil, to end: Date? = nil) -> [String: UsageAggregate] {
        groups({ $0.providerID ?? "unknown" }, from: start, to: end)
    }

    public func byModel(from start: Date? = nil, to end: Date? = nil) -> [String: UsageAggregate] {
        groups({ $0.modelID ?? "unknown" }, from: start, to: end)
    }

    public func byProject(from start: Date? = nil, to end: Date? = nil) -> [String: UsageAggregate] {
        groups({ $0.projectPath ?? "unknown" }, from: start, to: end)
    }

    private func groups(_ key: (UnifiedUsageRecord) -> String, from start: Date?, to end: Date?) -> [String: UsageAggregate] {
        Dictionary(grouping: aggregate(from: start, to: end).records, by: key).mapValues(UsageAggregate.init)
    }
}
