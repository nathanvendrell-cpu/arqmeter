import Foundation
import Darwin
import ArqmeterCore

struct CycleTokenHistory {
    let currentLocal: Int64
    let previousLocal: Int64
    let previousAccountFullDaysTokens: Int64?
    let previousAccountFullDays: Int
    let currentStart: Date
    let previousStart: Date
    let resetAt: Date
    let localComplete: Bool
}

/// The official usage endpoint has daily buckets, not reset-aligned token
/// counts. Local JSONL events have timestamps, so their cumulative counters
/// can be sampled at each reset boundary without streaming whole log files.
final class CycleHistoryReader {
    private struct CachedFile {
        let size: Int64
        let modified: Date
        let resetAt: Date
        let lower: Int64?
        let middle: Int64?
        let upper: Int64?
    }

    private let directory: URL
    private var cache: [URL: CachedFile] = [:]
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()
    private let iso = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.directory = directory
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(resetAt: Date, daily: [DailyTokenUsage], now: Date = Date()) -> CycleTokenHistory {
        let currentStart = resetAt.addingTimeInterval(-7 * 24 * 60 * 60)
        let previousStart = currentStart.addingTimeInterval(-7 * 24 * 60 * 60)
        var current: Int64 = 0
        var previous: Int64 = 0
        var complete = true
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator
                where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.contentModificationDate ?? .distantPast) >= previousStart else { continue }
                let modified = values.contentModificationDate ?? .distantFuture
                let started = sessionStart(url)
                let size = Int64(values.fileSize ?? 0)
                guard size > 0 else { continue }
                if let cached = cache[url], cached.size == size, cached.modified == modified,
                   cached.resetAt == resetAt {
                    if let lower = cached.lower, let middle = cached.middle, let upper = cached.upper,
                       lower <= middle, middle <= upper {
                        previous += middle - lower
                        current += upper - middle
                    } else {
                        complete = false
                    }
                    continue
                }
                guard let file = fopen(url.path, "rb") else { complete = false; continue }
                defer { fclose(file) }
                let tail = tailCumulative(in: file, size: size)
                func count(before boundary: Date) -> Int64? {
                    if let started, started >= boundary { return 0 }
                    if modified < boundary { return tail }
                    return cumulative(before: boundary, in: file, size: size)
                }
                let lower = count(before: previousStart)
                let middle = count(before: currentStart)
                let upper = count(before: min(resetAt, now))
                cache[url] = CachedFile(size: size, modified: modified, resetAt: resetAt,
                                        lower: lower, middle: middle, upper: upper)
                if let lower, let middle, let upper, lower <= middle, middle <= upper {
                    previous += middle - lower
                    current += upper - middle
                } else {
                    complete = false
                }
            }
        } else {
            complete = false
        }

        // Bucket boundaries are calendar days. Exclude the two partial days:
        // including the reset day would make the previous-period number grow
        // as the new period is consumed.
        let previousDayStart = calendar.startOfDay(for: previousStart)
        let currentDayStart = calendar.startOfDay(for: currentStart)
        let previousDays = daily.filter { bucket in
            guard let date = Self.dayDate(bucket.day) else { return false }
            return date > previousDayStart && date < currentDayStart
        }
        let accountFullDays = previousDays.isEmpty ? nil :
            previousDays.reduce(Int64(0)) { $0 + $1.tokens }
        return CycleTokenHistory(currentLocal: current, previousLocal: previous,
            previousAccountFullDaysTokens: accountFullDays, previousAccountFullDays: previousDays.count,
            currentStart: currentStart,
            previousStart: previousStart, resetAt: resetAt, localComplete: complete)
    }

    private static func dayDate(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private func sessionStart(_ url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 27, name.hasPrefix("rollout-") else { return nil }
        let stamp = String(name.dropFirst(8).prefix(19))
        guard stamp.count == 19 else { return nil }
        let isoStamp = String(stamp.prefix(13)) + ":" + String(stamp.dropFirst(14).prefix(2))
            + ":" + String(stamp.suffix(2)) + "Z"
        return iso.date(from: isoStamp)
    }

    private func tailCumulative(in file: UnsafeMutablePointer<FILE>, size: Int64) -> Int64? {
        var reach: Int64 = 64 * 1024
        while true {
            let start = max(0, size - reach)
            guard fseeko(file, off_t(start), SEEK_SET) == 0 else { return nil }
            if start > 0 { skipPartialLine(in: file, at: start) }
            var last: Int64?
            while let line = readLine(in: file) {
                if let count = cumulativeValue(line) { last = count }
            }
            if let last { return last }
            if start == 0 { return 0 }
            reach = min(size, reach * 2)
        }
    }

    private func cumulative(before boundary: Date, in file: UnsafeMutablePointer<FILE>, size: Int64) -> Int64? {
        let position = firstLine(atOrAfter: boundary, in: file, size: size)
        guard let position else { return nil }
        var reach: Int64 = 64 * 1024
        while true {
            let start = max(0, position - reach)
            guard fseeko(file, off_t(start), SEEK_SET) == 0 else { return nil }
            if start > 0 { skipPartialLine(in: file, at: start) }
            var last: Int64?
            while Int64(ftello(file)) < position {
                let offset = Int64(ftello(file))
                guard let line = readLine(in: file), offset < position else { break }
                if let count = cumulativeValue(line), let date = timestamp(line), date < boundary {
                    last = count
                }
            }
            if let last { return last }
            if start == 0 { return 0 }
            reach = min(size, reach * 2)
        }
    }

    private func firstLine(atOrAfter boundary: Date, in file: UnsafeMutablePointer<FILE>, size: Int64) -> Int64? {
        var low: Int64 = 0
        var high = size
        while low < high {
            let middle = low + (high - low) / 2
            guard fseeko(file, off_t(middle), SEEK_SET) == 0 else { return nil }
            if middle > 0 { skipPartialLine(in: file, at: middle) }
            let offset = Int64(ftello(file))
            guard offset < size, let line = readLine(in: file) else {
                high = middle
                continue
            }
            let date = timestamp(line) ?? .distantPast
            if date < boundary {
                low = Int64(ftello(file))
            } else {
                high = middle
            }
        }
        guard fseeko(file, off_t(low), SEEK_SET) == 0 else { return nil }
        if low > 0 { skipPartialLine(in: file, at: low) }
        return min(size, Int64(ftello(file)))
    }

    private func skipPartialLine(in file: UnsafeMutablePointer<FILE>, at offset: Int64) {
        guard offset > 0, fseeko(file, off_t(offset - 1), SEEK_SET) == 0 else { return }
        let previous = fgetc(file)
        if previous != 10 { skipLine(in: file) }
    }

    private func skipLine(in file: UnsafeMutablePointer<FILE>) {
        var buffer = [CChar](repeating: 0, count: 8192)
        while buffer.withUnsafeMutableBufferPointer({ fgets($0.baseAddress, Int32($0.count), file) }) != nil {
            let count = strlen(buffer)
            if count > 0 && buffer[count - 1] == 10 { return }
        }
    }

    private func readLine(in file: UnsafeMutablePointer<FILE>) -> Data? {
        var buffer = [CChar](repeating: 0, count: 8192)
        var line = Data()
        var truncated = false
        while buffer.withUnsafeMutableBufferPointer({ fgets($0.baseAddress, Int32($0.count), file) }) != nil {
            let count = strlen(buffer)
            if !truncated && line.count + count <= 1024 * 1024 {
                line.append(contentsOf: buffer.prefix(count).map { UInt8(bitPattern: $0) })
            } else if !truncated {
                line = line.prefix(160)
                truncated = true
            }
            if count > 0 && buffer[count - 1] == 10 {
                return line
            }
        }
        return line.isEmpty ? nil : line
    }

    private func timestamp(_ line: Data) -> Date? {
        guard let text = String(data: line.prefix(160), encoding: .utf8),
              let marker = text.range(of: "\"timestamp\":\"") else { return nil }
        let remainder = text[marker.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        let value = String(remainder[..<end])
        return fractional.date(from: value) ?? iso.date(from: value)
    }

    private func cumulativeValue(_ line: Data) -> Int64? {
        guard line.range(of: Data("\"token_count\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any],
              let count = total["total_tokens"] as? NSNumber else { return nil }
        return max(0, count.int64Value)
    }
}
