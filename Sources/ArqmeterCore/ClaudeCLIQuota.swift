import Foundation

/// A normal macOS user identity is required by the official CLI's credential lookup.
/// This allowlist deliberately does not inherit provider keys, helpers or proxy settings.
public enum ClaudeCLIContext {
    public static func environment(home: String, username: String) -> [String] {
        ["HOME=\(home)", "USER=\(username)", "PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
         "TERM=xterm-256color", "LANG=en_US.UTF-8", "DISABLE_AUTOUPDATER=1"]
    }
    public static func hasSubscriptionHeader(_ screen: String) -> Bool {
        ["Claude Pro", "Claude Max", "Claude Team", "Claude Enterprise", "Claude Free"].contains(where: screen.contains)
    }
}

/// PTY fragments are not complete prompts. Only the known full frame for the
/// exact empty app-owned directory can authorize a key.
public enum ClaudeCLITrustPrompt {
    public enum State: Equatable { case absent, incomplete, rejected, ready(selectedYes: Bool) }
    public static func assess(_ screen: String, expectedPath: String, ownsEmptyDirectory: Bool) -> State {
        guard screen.contains("Accessing workspace:") else { return .absent }
        guard ownsEmptyDirectory else { return .rejected }
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let selectedNo = lines.contains("❯ No, exit") && lines.contains("Yes, I trust this folder")
        let selectedYes = lines.contains("❯ Yes, I trust this folder") && lines.contains("No, exit")
        guard screen.contains("Quick safety check: Is this a project you created or one you trust?"),
              screen.contains("Enter to confirm · Esc to cancel"), selectedNo || selectedYes else { return .incomplete }
        guard let index = lines.firstIndex(of: "Accessing workspace:"),
              let path = lines.dropFirst(index + 1).first(where: { !$0.isEmpty }) else { return .incomplete }
        guard path == expectedPath else { return .rejected }
        return .ready(selectedYes: selectedYes)
    }
}

/// Final rendered official /usage screen only. API costs/context percentages are never plan quotas.
public struct ClaudeCLIQuotaReport: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercent: Double
        public let resetLabel: String?
        public let expiresAt: Date?
        public var remainingPercent: Int { Int((100 - usedPercent).rounded(.down)) }
    }
    public let observedAt: Date
    public let session: Window?
    public let weekly: Window?
    public var transportKind: String? = nil
    public var subscriptionType: String? = nil
    public func hasSameDisplayedValues(as other: Self?) -> Bool {
        func same(_ a: Window?, _ b: Window?) -> Bool {
            if a == nil && b == nil { return true }
            guard let a, let b else { return false }
            return a.usedPercent == b.usedPercent && a.resetLabel == b.resetLabel
        }
        return same(session, other?.session) && same(weekly, other?.weekly)
    }
    public enum Failure: String, Error, Codable, Sendable {
        case limited, lastKnown, authentication, unavailable, trust, unsupported, timeout, absent, stopped, cleanup
        public var message: String {
            switch self {
            case .limited: return "Anthropic limite la lecture du quota · nouvelle tentative différée"
            case .lastKnown: return "Relevé Claude non certifié actuel · dernier quota conservé"
            case .authentication: return "Connexion Claude Code requise"
            case .unavailable: return "Quota officiel Claude non reçu · connexion conservée"
            case .trust: return "Dossier du lecteur à confirmer dans Claude Code"
            case .unsupported: return "Quota officiel non reconnu · dernier relevé conservé"
            case .timeout: return "Claude Code n’a pas répondu · nouvelle tentative différée"
            case .absent: return "Claude Code non installé"
            case .stopped: return "Suivi Claude Code arrêté"
            case .cleanup: return "Lecteur Claude Code non fermé · suivi suspendu"
            }
        }
    }
    public static func parse(finalScreen: String, observedAt: Date) throws -> Self {
        guard finalScreen.utf8.count <= 32768 else { throw Failure.unsupported }
        let lowered = finalScreen.lowercased()
        if lowered.contains("error: usage endpoint is rate limited") { throw Failure.limited }
        if lowered.contains("last-known usage") || lowered.contains("last known usage") { throw Failure.lastKnown }
        let lines = finalScreen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func window(_ labels: Set<String>) throws -> Window? {
            let matches = lines.indices.filter { labels.contains(lines[$0]) }
            guard matches.count <= 1 else { throw Failure.unsupported }
            guard let index = matches.first else { return nil }
            var used: Double?, reset: String?
            for line in lines.dropFirst(index + 1).prefix(6) {
                if line.hasPrefix("Current ") || line.hasPrefix("This week") || line == "Usage credits" { break }
                let regex = try NSRegularExpression(pattern: #"^(?:[█▌▏▎▍▐░▒▓━─\s]+)?([0-9]+(?:\.[0-9]+)?)% used$"#)
                let range = NSRange(line.startIndex..., in: line)
                if let match = regex.firstMatch(in: line, range: range), let valueRange = Range(match.range(at: 1), in: line) {
                    guard used == nil, let amount = Double(line[valueRange]), (0...100).contains(amount) else { throw Failure.unsupported }
                    used = amount
                }
                if line.hasPrefix("Resets "), line.count <= 120 { reset = line }
            }
            guard let used else { return nil }
            // Only an explicit relative reset yields a conservative expiry bound, not a fabricated display date.
            var expiry: Date?
            if let reset, let regex = try? NSRegularExpression(pattern: #"^Resets in (?:(\d+)h ?)?(?:(\d+)m)?$"#),
               let match = regex.firstMatch(in: reset, range: NSRange(reset.startIndex..., in: reset)) {
                func number(_ i: Int) -> Int { Range(match.range(at: i), in: reset).flatMap { Int(reset[$0]) } ?? 0 }
                expiry = observedAt.addingTimeInterval(Double(number(1) * 3600 + number(2) * 60))
            }
            return Window(usedPercent: used, resetLabel: reset, expiresAt: expiry)
        }
        let session = try window(["Current session"])
        let weekly = try window(["Current week (all models)", "This week (all models)"])
        guard session != nil || weekly != nil else { throw Failure.unsupported }
        return Self(observedAt: observedAt, session: session, weekly: weekly)
    }
    public func currentWindow(_ period: ClaudeQuotaReport.Period, at now: Date) -> Window? {
        let age = now.timeIntervalSince(observedAt)
        guard age >= -5, age < 180, let value = period == .fiveHour ? session : weekly,
              value.usedPercent.isFinite, (0...100).contains(value.usedPercent), value.expiresAt.map({ $0 > now }) ?? true else { return nil }
        return value
    }
    public var provenance: String {
        transportKind == "official-get-usage-live"
            ? "Claude Code · quota officiel reçu du serveur"
            : "Claude Code · /usage officiel · fraîcheur serveur non fournie"
    }
    public static var cacheURL: URL { ClaudeQuotaReport.cacheURL.deletingLastPathComponent().appendingPathComponent("claude-cli-official-quota.json") }
    public static func read(url: URL = cacheURL) -> Self? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public func save(url: URL = cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Persist the retry deadline, not a new timestamp on an old measurement. Relaunch/wake cannot defeat backoff.
public struct ClaudeCLIRefreshPolicy: Codable, Equatable, Sendable {
    public private(set) var nextAttemptAt: Date?
    public private(set) var lastAttemptAt: Date?
    public private(set) var failure: ClaudeCLIQuotaReport.Failure?
    public private(set) var failures = 0
    public init() {}
    public func permits(at now: Date) -> Bool { nextAttemptAt.map { now >= $0 } ?? true }
    public mutating func record(_ error: ClaudeCLIQuotaReport.Failure?, at now: Date) {
        let previousFailure = failure, previousDeadline = nextAttemptAt
        lastAttemptAt = now; failure = error
        failures = error == nil ? 0 : error == previousFailure ? min(6, failures + 1) : 1
        let delay: Double = error == nil ? 120 : error == .limited ? min(3600, 600 * pow(2, Double(failures - 1))) : min(1800, 120 * pow(2, Double(failures - 1)))
        nextAttemptAt = now.addingTimeInterval(delay)
        if error != nil, previousFailure == .limited, let previousDeadline, previousDeadline > nextAttemptAt! {
            nextAttemptAt = previousDeadline
        }
    }
}

/// Bounded terminal display buffer. ANSI position/erase operations are applied; old stream text is not searched.
public struct ClaudeCLITerminal: Sendable {
    private var cells = Array(repeating: Array(repeating: Character(" "), count: 160), count: 50)
    private var x = 0, y = 0, savedX = 0, savedY = 0
    private var mode = 0, sequence = "", pending = Data(), total = 0
    public private(set) var valid = true
    public init() {}
    public var screen: String { cells.map { String($0).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }
    public var diagnostic: String { "mode=\(mode); bytes=\(total); pending=\(pending.count); cursor=\(x),\(y); lines=\(cells.filter { $0.contains(where: { $0 != " " }) }.count)" }
    public mutating func push(_ data: Data) {
        total += data.count; guard total <= 256 * 1024 else { valid = false; return }
        pending.append(data)
        guard let text = String(data: pending, encoding: .utf8) else { if pending.count > 65536 { valid = false }; return }
        pending.removeAll(keepingCapacity: true)
        // CRLF is one extended grapheme in Swift String. Controls must be processed as scalar bytes.
        for scalar in text.unicodeScalars {
            let c = Character(String(scalar))
            if mode == 3 { if c == "\u{7}" { mode = 0 } else if c == "\u{1b}" { mode = 4 }; continue }
            if mode == 4 { mode = c == "\\" ? 0 : 3; continue }
            if mode == 5 { mode = 0; continue }
            if mode == 1 {
                mode = 0
                if c == "[" { mode = 2; sequence = "" }
                else if c == "]" { mode = 3 }
                else if c == "(" { mode = 5 }
                else if c == "7" { savedX = x; savedY = y }
                else if c == "8" { x = savedX; y = savedY }
                continue
            }
            if mode == 2 {
                if c.asciiValue.map({ (0x40...0x7e).contains($0) }) == true { apply(c); mode = 0 }
                else { sequence.append(c); if sequence.count > 64 { valid = false; mode = 0 } }
                continue
            }
            switch c {
            case "\u{1b}": mode = 1
            case "\r": x = 0
            case "\n": y += 1; if y >= 50 { cells.removeFirst(); cells.append(Array(repeating: " ", count: 160)); y = 49 }
            case "\u{8}": x = max(0, x - 1)
            case "\t": x = min(159, (x / 8 + 1) * 8)
            default:
                if c.asciiValue.map({ $0 < 32 || $0 == 127 }) == true { continue }
                if x >= 160 { x = 0; y = min(49, y + 1) }
                cells[y][x] = c; x += 1
            }
        }
    }
    private mutating func apply(_ final: Character) {
        let p = sequence.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func arg(_ i: Int, _ fallback: Int = 1) -> Int { i < p.count && p[i] != 0 ? p[i] : fallback }
        switch final {
        case "A": y = max(0, y - arg(0))
        case "B": y = min(49, y + arg(0))
        case "C": x = min(159, x + arg(0))
        case "D": x = max(0, x - arg(0))
        case "G": x = min(159, max(0, arg(0) - 1))
        case "H", "f": y = min(49, max(0, arg(0) - 1)); x = min(159, max(0, arg(1) - 1))
        case "J":
            if arg(0, 0) >= 2 { cells = Array(repeating: Array(repeating: " ", count: 160), count: 50) }
            else { for row in y..<50 { for col in (row == y ? min(x,159) : 0)..<160 { cells[row][col] = " " } } }
        case "K":
            let a = arg(0, 0), begin = a == 0 ? min(x,159) : 0, end = a == 1 ? min(x + 1,160) : 160
            for col in begin..<end { cells[y][col] = " " }
        case "h": if sequence == "?1049" { cells = Array(repeating: Array(repeating: " ", count: 160), count: 50); x = 0; y = 0 }
        default: break
        }
    }
}
