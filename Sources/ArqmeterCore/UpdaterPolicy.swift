import Foundation

/// This policy does not fetch, inspect histories, install or implement crypto.
/// Sparkle owns signed-feed/archive verification and transactional replacement.
public struct UpdaterConfiguration: Equatable {
    public let feedURL: URL
    public let publicKey: String
    public let downloadHosts: Set<String>

    public init(info: [String: Any]) throws {
        guard let value = info["SUFeedURL"] as? String, let feed = URL(string: value),
              Self.secureURL(feed),
              let key = info["SUPublicEDKey"] as? String,
              let rawKey = Data(base64Encoded: key), rawKey.count == 32, rawKey.contains(where: { $0 != 0 }),
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SUSendProfileInfo"] as? Bool == false else { throw UpdatePolicyError.notConfigured }
        let additional = info["ARQUpdateDownloadHosts"] as? [String] ?? []
        guard additional.allSatisfy({ host in
            guard let url = URL(string: "https://" + host), Self.secureURL(url) else { return false }
            return url.host?.lowercased() == host.lowercased() && url.path.isEmpty
        }) else { throw UpdatePolicyError.notConfigured }
        feedURL = feed; publicKey = key
        downloadHosts = Set(additional.map { $0.lowercased() } + [feed.host!.lowercased()])
    }

    public static func secureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
            url.user == nil && url.password == nil && url.fragment == nil && url.query == nil &&
            (url.port == nil || url.port == 443)
    }
}

public enum UpdatePolicyError: Error, Equatable {
    case notConfigured, downgradeOrSameVersion, incompatible, channel, unsafeDownload, invalidFeed, packageInstaller
}

public enum UpdaterPolicy {
    public static let prereleaseDefaultsKey = "updates.includePrerelease"
    public static func validate(configuration: UpdaterConfiguration, versionIsNewer: Bool,
                                compatible: Bool, channel: String?, includePrerelease: Bool,
                                download: URL?, signedFeed: Bool, applicationArchive: Bool) throws {
        guard signedFeed else { throw UpdatePolicyError.invalidFeed }
        guard versionIsNewer else { throw UpdatePolicyError.downgradeOrSameVersion }
        guard compatible else { throw UpdatePolicyError.incompatible }
        guard channel == nil || (channel == "prerelease" && includePrerelease) else { throw UpdatePolicyError.channel }
        guard applicationArchive else { throw UpdatePolicyError.packageInstaller }
        guard let download, UpdaterConfiguration.secureURL(download),
              configuration.downloadHosts.contains(download.host!.lowercased()) else { throw UpdatePolicyError.unsafeDownload }
    }
}
