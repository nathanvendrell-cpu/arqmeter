import AppKit
import Sparkle
import ArqmeterCore

/// Sparkle's standard UI owns progress, version/notes, Install and Relaunch,
/// Later, cancellation and download/signature errors. No home-grown installer.
@MainActor final class ArqmeterUpdater: NSObject, SPUUpdaterDelegate {
    private let bundle: Bundle
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?
    private var configuration: UpdaterConfiguration? {
        try? UpdaterConfiguration(info: bundle.infoDictionary ?? [:])
    }

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.bundle = bundle; self.defaults = defaults
        super.init()
    }

    func startIfConfigured() {
        guard controller == nil, configuration != nil else { return }
        let candidate = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        controller = candidate
        candidate.startUpdater()
    }

    func addMenuItems(to menu: NSMenu) {
        let check = NSMenuItem(title: "Rechercher les mises à jour…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = controller?.updater.canCheckForUpdates ?? true
        menu.addItem(check)
        let prerelease = NSMenuItem(title: "Inclure les préversions", action: #selector(togglePrerelease), keyEquivalent: "")
        prerelease.target = self
        prerelease.state = defaults.bool(forKey: UpdaterPolicy.prereleaseDefaultsKey) ? .on : .off
        menu.addItem(prerelease)
    }

    @objc private func checkForUpdates() {
        guard configuration != nil else {
            let alert = NSAlert()
            alert.messageText = "Mises à jour non configurées"
            alert.informativeText = "Le flux HTTPS signé et sa clé publique de publication ne sont pas encore configurés. Aucune installation ne sera tentée. Vos réglages et historiques sont conservés."
            alert.addButton(withTitle: "Fermer")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        startIfConfigured()
        guard let controller, controller.updater.canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    @objc private func togglePrerelease() {
        defaults.set(!defaults.bool(forKey: UpdaterPolicy.prereleaseDefaultsKey),
                     forKey: UpdaterPolicy.prereleaseDefaultsKey)
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        defaults.bool(forKey: UpdaterPolicy.prereleaseDefaultsKey) ? ["prerelease"] : []
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard let configuration,
              let installed = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw NSError(domain: "com.7agency.arqmeter.updater", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Configuration de mise à jour absente."])
        }
        do {
            try UpdaterPolicy.validate(configuration: configuration,
                versionIsNewer: SUStandardVersionComparator.default.compareVersion(item.versionString, toVersion: installed) == .orderedDescending,
                compatible: item.isMacOsUpdate && item.minimumOperatingSystemVersionIsOK &&
                    item.maximumOperatingSystemVersionIsOK && item.minimumUpdateVersionIsOK && item.arm64HardwareRequirementIsOK,
                channel: item.channel, includePrerelease: defaults.bool(forKey: UpdaterPolicy.prereleaseDefaultsKey),
                download: item.fileURL, signedFeed: item.signingValidationStatus == .succeeded,
                applicationArchive: item.installationType == "application")
        } catch {
            throw NSError(domain: "com.7agency.arqmeter.updater", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Mise à jour refusée : version, canal, compatibilité, signature du flux ou origine du téléchargement non conforme. L’application actuelle reste en place."])
        }
    }

    static func selfTest() throws {
        let suite = "com.7agency.arqmeter.updater.menu.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw UpdatePolicyError.notConfigured }
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = ArqmeterUpdater(defaults: defaults), menu = NSMenu()
        updater.addMenuItems(to: menu)
        guard menu.items.count == 2,
              menu.items[0].title == "Rechercher les mises à jour…",
              menu.items[0].target === updater, menu.items[1].state == .off,
              SUStandardVersionComparator.default.compareVersion("20261012.24", toVersion: "20261012.23") == .orderedDescending,
              SUStandardVersionComparator.default.compareVersion("20261012.23", toVersion: "20261012.24") == .orderedAscending
        else { throw UpdatePolicyError.incompatible }
        // No start/check, provider, UI window, defaults.standard write or install.
    }
}
