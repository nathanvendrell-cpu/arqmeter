import Foundation
import CoreFoundation

public struct GeminiQuotaWindow: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let modelId: String
    public let remainingFraction: Double
    public let remainingPercent: Int
    public let usedPercent: Int
    public let resetsAt: Date?
    public let windowMinutes: Int?

    public init(id: String, label: String, modelId: String, remainingFraction: Double,
                remainingPercent: Int? = nil, resetsAt: Date?, windowMinutes: Int? = nil) {
        let clampedFraction = min(1.0, max(0.0, remainingFraction))
        let computedRemaining = remainingPercent ?? min(100, max(0, Int((clampedFraction * 100.0).rounded())))
        self.id = id
        self.label = label
        self.modelId = modelId
        self.remainingFraction = clampedFraction
        self.remainingPercent = min(100, max(0, computedRemaining))
        self.usedPercent = 100 - self.remainingPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

public struct GeminiQuotaSnapshot: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let provenance: String
    public let primaryWindow: GeminiQuotaWindow
    public let allWindows: [GeminiQuotaWindow]

    public init(observedAt: Date, provenance: String,
                primaryWindow: GeminiQuotaWindow, allWindows: [GeminiQuotaWindow]) {
        self.observedAt = observedAt
        self.provenance = provenance
        self.primaryWindow = primaryWindow
        self.allWindows = allWindows
    }

    public func isExpired(at now: Date) -> Bool {
        if let resetsAt = primaryWindow.resetsAt { return resetsAt <= now }
        return false
    }
}

public struct GeminiMenuQuotaSnapshot: Equatable, Sendable {
    public let readout: GeminiQuotaSnapshot?
    public let isLastKnown: Bool

    public init(readout: GeminiQuotaSnapshot?, isLastKnown: Bool) {
        self.readout = readout
        self.isLastKnown = isLastKnown
    }

    public static func make(report: GeminiQuotaReport?, at now: Date,
                            recentThreshold: TimeInterval = 180) -> GeminiMenuQuotaSnapshot {
        if let current = report?.snapshot, !current.isExpired(at: now),
           current.observedAt <= now.addingTimeInterval(5) {
            let fresh = now.timeIntervalSince(current.observedAt) <= recentThreshold
            return GeminiMenuQuotaSnapshot(readout: current, isLastKnown: !fresh)
        }
        if let last = report?.lastKnown, !last.isExpired(at: now),
           last.observedAt <= now.addingTimeInterval(5) {
            return GeminiMenuQuotaSnapshot(readout: last, isLastKnown: true)
        }
        return GeminiMenuQuotaSnapshot(readout: nil, isLastKnown: false)
    }
}

public struct GeminiQuotaReport: Codable, Equatable, Sendable {
    public let observedAt: Date?
    public let snapshot: GeminiQuotaSnapshot?
    public let lastKnown: GeminiQuotaSnapshot?
    public let diagnostic: String?

    public init(observedAt: Date?, snapshot: GeminiQuotaSnapshot?,
                lastKnown: GeminiQuotaSnapshot?, diagnostic: String? = nil) {
        self.observedAt = observedAt
        self.snapshot = snapshot
        self.lastKnown = lastKnown
        self.diagnostic = diagnostic
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arqmeter/gemini-quota.json")
    }

    public static func read(from url: URL = defaultURL()) -> GeminiQuotaReport? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GeminiQuotaReport.self, from: data)
    }

    public static func write(_ report: GeminiQuotaReport, to url: URL = defaultURL()) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func parseLanguageServerConfig(_ data: Data, observedAt: Date = Date(),
                                                 provenance: String = "Antigravity · LanguageServer local") -> GeminiQuotaSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configs = root["clientModelConfigs"] as? [[String: Any]] else { return nil }
        var windows: [GeminiQuotaWindow] = []
        for entry in configs {
            guard let quotaInfo = entry["quotaInfo"] as? [String: Any] else { continue }
            let label = (entry["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Gemini"
            let aliasModel = (entry["modelOrAlias"] as? [String: Any])?["model"] as? String
            let modelId = (entry["modelId"] as? String) ?? aliasModel ?? label
            // A reset timestamp alone is not a measured zero. Nor does it
            // prove a seven-day window: Antigravity exposes several limits.
            guard let number = quotaInfo["remainingFraction"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let fraction = number.doubleValue
            guard fraction.isFinite, (0...1).contains(fraction) else { continue }
            let resetsAt = UsageFiles.date(quotaInfo["resetTime"] as? String)
            windows.append(GeminiQuotaWindow(
                id: modelId,
                label: label,
                modelId: modelId,
                remainingFraction: fraction,
                resetsAt: resetsAt,
                windowMinutes: nil
            ))
        }
        guard !windows.isEmpty else { return nil }
        let primary = windows.first {
            $0.modelId == "gemini-4-argon-high" ||
            $0.label.localizedCaseInsensitiveContains("Gemini 4 Argon (High)")
        } ?? windows.first {
            $0.modelId.localizedCaseInsensitiveContains("gemini-4-argon") ||
            $0.label.localizedCaseInsensitiveContains("Gemini 4 Argon") ||
            $0.modelId == "MODEL_PLACEHOLDER_M417"
        } ?? windows.first {
            $0.modelId.localizedCaseInsensitiveContains("gemini") ||
            $0.label.localizedCaseInsensitiveContains("Gemini")
        }
        guard let primary else { return nil }
        return GeminiQuotaSnapshot(
            observedAt: observedAt,
            provenance: provenance,
            primaryWindow: primary,
            allWindows: windows
        )
    }
}
