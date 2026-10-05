import Foundation
import Darwin
import ArqmeterCore

struct LocalTokenEvent {
    let date: Date
    let project: String
    let projectPath: String
    let session: String
    let input: Int64
    let output: Int64
    let cached: Int64
    let cachedObserved: Bool
    var eventID: String = ""
    var providerID: String? = nil
    var modelID: String? = nil
    var reasoningTokens: Int64? = nil

    var total: Int64 { input + output }
    var nonCached: Int64? { cachedObserved ? input - cached + output : nil }

    var unified: UnifiedUsageRecord? {
        CodexUsageNormalizer().normalize(CodexLocalUsage(
            eventID: eventID.isEmpty ? nil : eventID,
            timestamp: date,
            projectPath: projectPath.isEmpty ? nil : projectPath,
            sessionID: session,
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cachedObserved ? cached : nil,
            providerID: providerID, modelID: modelID, reasoningTokens: reasoningTokens
        ))
    }
}

struct LocalProjectUsage {
    let name: String
    let path: String
    let input: Int64
    let output: Int64
    let cached: Int64
    let cacheComplete: Bool
    let lastActivity: Date

    var total: Int64 { input + output }
}

struct LocalTokenSummary {
    let total: Int64
    let input: Int64
    let output: Int64
    let cachedInput: Int64
    let cacheComplete: Bool
    let lastFiveMinutes: Int64
    let lastFiveNonCached: Int64?
    let lastHour: Int64
    let activeSessions: Int
    let lastActivity: Date?
    let byHour: [(Date, Int64)]
    let byMinute: [(Date, Int64)]
    let byProject: [LocalProjectUsage]
    let recent: [LocalTokenEvent]
    let events: [LocalTokenEvent]
    let sampledAt: Date
    let scanComplete: Bool

    var unifiedEvents: [UnifiedUsageRecord] { events.compactMap(\.unified) }

    /// nil means the interval falls outside the 24-hour local scan or is not
    /// fully scanned yet. It must not be displayed as measured zero.
    func tokens(between start: Date, and end: Date) -> Int64? {
        guard scanComplete, start <= end, start >= sampledAt.addingTimeInterval(-24 * 60 * 60),
              end <= sampledAt else { return nil }
        return events.reduce(0) { $0 + ($1.date > start && $1.date <= end ? $1.total : 0) }
    }
}

/// Reads only new, complete JSONL lines after the first pass. The live timer is
/// active only while the dashboard is open; no model call is made.
final class LocalActivityStore {
    private struct FileState {
        var offset: Int64 = 0
        var project = "Autre dossier"
        var projectPath = ""
        var providerID: String?
        var modelID: String?
        var lastCumulative: Int64?
    }

    private let sessionsDirectory: URL
    private var files: [URL: FileState] = [:]
    private var events: [LocalTokenEvent] = []
    private var trackedFiles: Set<URL> = []
    private var lastDiscovery: Date?
    private var scanComplete = true
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private let fallbackFormatter = ISO8601DateFormatter()

    init(sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.sessionsDirectory = sessionsDirectory
    }

    func refresh(now: Date = Date()) -> LocalTokenSummary {
        scanComplete = FileManager.default.isReadableFile(atPath: sessionsDirectory.path)
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let available = recentSessionFiles(now: now)
        for url in available {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else {
                scanComplete = false
                continue
            }
            var state = files[url] ?? FileState()
            if size.int64Value < state.offset { state = FileState() }
            if size.int64Value > state.offset {
                readNewLines(at: url, state: &state, cutoff: cutoff, now: now)
                files[url] = state
            }
        }
        events.removeAll { $0.date < cutoff || $0.date > now }
        return summarize(now: now)
    }

    private func recentSessionFiles(now: Date) -> [URL] {
        if lastDiscovery == nil || now.timeIntervalSince(lastDiscovery!) >= 30 {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
            if let enumerator = FileManager.default.enumerator(
                at: sessionsDirectory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                    guard let properties = try? url.resourceValues(forKeys: keys),
                          properties.isRegularFile == true, properties.isSymbolicLink != true,
                          (properties.contentModificationDate ?? .distantPast) >= now.addingTimeInterval(-24 * 60 * 60)
                    else { continue }
                    trackedFiles.insert(url)
                }
            } else {
                scanComplete = false
            }
            lastDiscovery = now
        }
        let calendar = Calendar.current
        let days = [now, calendar.date(byAdding: .day, value: -1, to: now) ?? now]
        for day in days {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let date = components.day else { continue }
            let directory = sessionsDirectory
                .appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, date), isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let properties = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey
                ]), properties.isRegularFile == true, properties.isSymbolicLink != true,
                    (properties.contentModificationDate ?? .distantPast) >= now.addingTimeInterval(-24 * 60 * 60)
                else { continue }
                trackedFiles.insert(url)
            }
        }
        return Array(trackedFiles)
    }

    private func readNewLines(at url: URL, state: inout FileState, cutoff: Date, now: Date) {
        guard let file = fopen(url.path, "r") else { scanComplete = false; return }
        defer { fclose(file) }
        guard fseeko(file, off_t(state.offset), SEEK_SET) == 0 else { scanComplete = false; return }
        let capacity = 64 * 1024
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var pending = Data()
        var droppingLongLine = false
        var lastCompleteOffset = state.offset
        while fgets(buffer, Int32(capacity), file) != nil {
            let count = strlen(buffer)
            guard count > 0 else { continue }
            let ended = buffer[count - 1] == 10
            if !droppingLongLine {
                if pending.count + count <= 1024 * 1024 {
                    pending.append(contentsOf: UnsafeRawBufferPointer(start: buffer, count: count))
                } else {
                    pending.removeAll(keepingCapacity: false)
                    droppingLongLine = true
                }
            }
            if ended {
                if !droppingLongLine {
                    accept(pending, session: url.lastPathComponent,
                           eventID: "codex:\(url.path):\(ftello(file))",
                           state: &state, cutoff: cutoff, now: now)
                }
                pending.removeAll(keepingCapacity: true)
                droppingLongLine = false
                lastCompleteOffset = Int64(ftello(file))
            }
        }
        if ferror(file) != 0 { scanComplete = false }
        state.offset = lastCompleteOffset
    }

    private func accept(_ line: Data, session: String, eventID: String,
                        state: inout FileState, cutoff: Date, now: Date) {
        guard line.range(of: Data(#""type":"session_meta""#.utf8)) != nil ||
              line.range(of: Data(#""type":"turn_context""#.utf8)) != nil ||
              line.range(of: Data(#""type":"token_count""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return }
        if object["type"] as? String == "session_meta", let cwd = payload["cwd"] as? String {
            state.project = Self.projectName(for: cwd)
            state.projectPath = cwd
            state.providerID = payload["model_provider"] as? String
            return
        }
        if object["type"] as? String == "turn_context" {
            state.modelID = payload["model"] as? String
            return
        }
        guard payload["type"] as? String == "token_count",
              let text = object["timestamp"] as? String,
              let date = formatter.date(from: text) ?? fallbackFormatter.date(from: text),
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return }
        let cumulative = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber
        if let cumulative {
            if state.lastCumulative == cumulative.int64Value { return }
            state.lastCumulative = cumulative.int64Value
        }
        guard date >= cutoff && date <= now else { return }
        guard let input = (last["input_tokens"] as? NSNumber)?.int64Value,
              let output = (last["output_tokens"] as? NSNumber)?.int64Value,
              input >= 0, output >= 0 else { return }
        let observedCached = (last["cached_input_tokens"] as? NSNumber)?.int64Value
        guard observedCached.map({ $0 >= 0 && $0 <= input }) ?? true else { return }
        let cached = observedCached ?? 0
        guard input + output > 0 else { return }
        let reasoning = (last["reasoning_output_tokens"] as? NSNumber)?.int64Value
        events.append(LocalTokenEvent(date: date, project: state.project,
                                      projectPath: state.projectPath, session: session,
                                      input: input, output: output, cached: cached,
                                      cachedObserved: observedCached != nil, eventID: eventID,
                                      providerID: state.providerID, modelID: state.modelID,
                                      reasoningTokens: reasoning))
    }

    private func summarize(now: Date) -> LocalTokenSummary {
        let calendar = Calendar.current
        let fiveMinutes = now.addingTimeInterval(-5 * 60)
        let oneHour = now.addingTimeInterval(-60 * 60)
        var hourly: [Date: Int64] = [:]
        var minute: [Date: Int64] = [:]
        var projects: [String: (String, String, Int64, Int64, Int64, Date, Bool)] = [:]
        var input: Int64 = 0
        var output: Int64 = 0
        var cached: Int64 = 0
        var lastFive: Int64 = 0
        var lastFiveNonCached: Int64? = 0
        var lastHour: Int64 = 0
        var activeSessions: Set<String> = []
        var lastActivity: Date?
        for event in events {
            input += event.input
            output += event.output
            cached += event.cached
            let hour = calendar.dateInterval(of: .hour, for: event.date)?.start ?? event.date
            hourly[hour, default: 0] += event.total
            if event.date >= oneHour {
                lastHour += event.total
                let minuteStart = calendar.dateInterval(of: .minute, for: event.date)?.start ?? event.date
                let bucket = calendar.date(byAdding: .minute, value: -(calendar.component(.minute, from: minuteStart) % 2), to: minuteStart) ?? minuteStart
                minute[bucket, default: 0] += event.total
            }
            if event.date >= fiveMinutes {
                lastFive += event.total
                if let amount = event.nonCached, let current = lastFiveNonCached {
                    lastFiveNonCached = current + amount
                } else {
                    lastFiveNonCached = nil
                }
            }
            if event.date >= now.addingTimeInterval(-10 * 60) { activeSessions.insert(event.session) }
            if lastActivity == nil || event.date > lastActivity! { lastActivity = event.date }
            let identity = event.projectPath.isEmpty ? event.project : event.projectPath
            let previous = projects[identity] ?? (event.project, event.projectPath, 0, 0, 0, .distantPast, true)
            projects[identity] = (previous.0, previous.1, previous.2 + event.input,
                                  previous.3 + event.output, previous.4 + event.cached,
                                  max(previous.5, event.date), previous.6 && event.cachedObserved)
        }
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let byHour = (0..<24).map { offset -> (Date, Int64) in
            let date = calendar.date(byAdding: .hour, value: offset - 23, to: currentHour) ?? currentHour
            return (date, hourly[date, default: 0])
        }
        let currentMinute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let bucketStart = calendar.date(byAdding: .minute, value: -(calendar.component(.minute, from: currentMinute) % 2), to: currentMinute) ?? currentMinute
        let byMinute = (0..<30).map { offset -> (Date, Int64) in
            let date = calendar.date(byAdding: .minute, value: (offset - 29) * 2, to: bucketStart) ?? bucketStart
            return (date, minute[date, default: 0])
        }
        let byProject = projects.map { LocalProjectUsage(name: $0.value.0, path: $0.value.1,
            input: $0.value.2, output: $0.value.3, cached: $0.value.4,
            cacheComplete: $0.value.6, lastActivity: $0.value.5) }
            .sorted { $0.total > $1.total }
        return LocalTokenSummary(total: input + output, input: input, output: output,
                                 cachedInput: cached, cacheComplete: events.allSatisfy(\.cachedObserved),
                                 lastFiveMinutes: lastFive,
                                 lastFiveNonCached: lastFiveNonCached, lastHour: lastHour,
                                 activeSessions: activeSessions.count, lastActivity: lastActivity,
                                 byHour: byHour, byMinute: byMinute, byProject: byProject,
                                 recent: Array(events.sorted { $0.date > $1.date }.prefix(8)),
                                 events: events, sampledAt: now, scanComplete: scanComplete)
    }

    private static func projectName(for path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        if let agency = parts.firstIndex(of: "0 - 7AGENCY Projet"), parts.count > agency + 2 {
            return parts[agency + 2]
        }
        return parts.last(where: { $0 != "/" }) ?? "Autre dossier"
    }
}
