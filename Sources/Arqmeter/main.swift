import AppKit
import CoreServices
import Darwin
import Foundation
import ArqmeterCore
import SwiftUI

final class UsageMonitor {
    private let sessionsDirectory: URL
    private let onUpdate: (UsageSnapshot?) -> Void
    private let workQueue = DispatchQueue(label: "com.7agency.arqmeter.scan", qos: .utility)
    private lazy var scanner = UsageDirectoryScanner(sessionsDirectory: sessionsDirectory)
    private var stream: FSEventStreamRef?
    private var streamRetryState = EventStreamRetryState()
    private var refreshWorkItem: DispatchWorkItem?
    private var expiryWorkItem: DispatchWorkItem?
    private var fallbackTimer: DispatchSourceTimer?
    private var pollingCadence = PollingCadenceState()
    private var stopped = false

    init(sessionsDirectory: URL, onUpdate: @escaping (UsageSnapshot?) -> Void) {
        self.sessionsDirectory = sessionsDirectory
        self.onUpdate = onUpdate
    }

    func start() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.startEventStream()
            self.bootstrap()
            self.startFallbackTimer()
        }
    }

    func stop() {
        workQueue.sync {
            stopped = true
            refreshWorkItem?.cancel()
            refreshWorkItem = nil
            expiryWorkItem?.cancel()
            expiryWorkItem = nil
            fallbackTimer?.cancel()
            fallbackTimer = nil
            streamRetryState = EventStreamRetryState()
            stopEventStream()
        }
    }

    private func startEventStream() {
        guard !stopped, stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, _, eventFlags, _ in
            guard let info else { return }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
                .map { UInt32($0) }
            Unmanaged<UsageMonitor>.fromOpaque(info)
                .takeUnretainedValue()
                .handleEvent(flags: flags)
        }
        let paths = [sessionsDirectory.path] as CFArray
        guard let candidate = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else {
            streamRetryState.recordStartResult(succeeded: false)
            return
        }
        FSEventStreamSetDispatchQueue(candidate, workQueue)
        guard FSEventStreamStart(candidate) else {
            FSEventStreamInvalidate(candidate)
            FSEventStreamRelease(candidate)
            streamRetryState.recordStartResult(succeeded: false)
            return
        }
        stream = candidate
        streamRetryState.recordStartResult(succeeded: true)
    }

    private func stopEventStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.fallbackTick() }
        fallbackTimer = timer
        timer.resume()
    }

    private func fallbackTick() {
        if stream == nil {
            if streamRetryState.shouldRetryOnFallbackTick {
                startEventStream()
            }
        }
        // FSEvents is an acceleration path, not the sole source of truth.  Codex
        // can append several session files in quick succession and macOS may
        // coalesce those events; a cheap incremental scan every two seconds
        // makes the visible value converge even if an event is missed.
        refresh()
    }

    private var currentUptime: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func handleEvent(flags: [UInt32]) {
        switch FileEventRecoveryPolicy.action(for: flags) {
        case .refresh:
            scheduleRefresh()
        case .reconcile, .bootstrap:
            bootstrap()
        case .recreateStream:
            stopEventStream()
            startEventStream()
            bootstrap()
        }
    }

    private func scheduleRefresh() {
        guard refreshWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWorkItem = nil
            self.refresh()
        }
        refreshWorkItem = item
        workQueue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func bootstrap() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        let snapshot = autoreleasepool { scanner.bootstrap() }
        publish(snapshot)
        pollingCadence.recordRefresh(at: currentUptime)
    }

    private func refresh() {
        let snapshot = autoreleasepool { scanner.refresh() }
        publish(snapshot)
        pollingCadence.recordRefresh(at: currentUptime)
    }

    private func publish(_ snapshot: UsageSnapshot?) {
        expiryWorkItem?.cancel()
        if let snapshot, snapshot.resetsAt != .distantFuture {
            let delay = max(0, snapshot.resetsAt.timeIntervalSinceNow)
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.publish(self.scanner.refresh())
            }
            expiryWorkItem = item
            workQueue.asyncAfter(deadline: .now() + delay, execute: item)
        }
        DispatchQueue.main.async { [onUpdate] in onUpdate(snapshot) }
    }

}

/// Reads the account-owned rate-limit snapshot through the installed Codex
/// runtime. The runtime keeps authentication private; Arqmeter never reads,
/// stores, or transmits credentials itself.
final class OfficialUsageReader {
    private static let codexExecutablePaths = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
    ]

    func snapshot() -> UsageSnapshot? {
        response(method: "account/rateLimits/read")?
            .split(separator: 0x0A)
            .reversed()
            .compactMap { OfficialUsageParser.snapshot(from: Data($0)) }
            .first
    }

    func dailyTokens() -> [DailyTokenUsage]? {
        for _ in 0..<2 {
            if let result = response(method: "account/usage/read", params: "{}")?
                .split(separator: 0x0A)
                .reversed()
                .compactMap({ OfficialDailyUsageParser.dailyTokens(from: Data($0)) })
                .first {
                return result
            }
        }
        return nil
    }

    private func response(method: String, params: String = "null") -> Data? {
        guard let executablePath = Self.codexExecutablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return nil
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let request = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"arqmeter","version":"1"},"capabilities":{}}}"#,
            #"{"method":"initialized"}"#,
            "{\"id\":2,\"method\":\"\(method)\",\"params\":\(params)}",
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(request.utf8))

        // EOF cancels pending app-server requests. Keep stdin open until the
        // requested reply arrives, bounded by the existing five-second timeout.
        let outputFD = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(outputFD, F_GETFL)
        if flags >= 0 { _ = fcntl(outputFD, F_SETFL, flags | O_NONBLOCK) }
        var response = Data()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, response.count < 4_000_000 {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(outputFD, $0.baseAddress, $0.count) }
            if count > 0 {
                response.append(contentsOf: bytes.prefix(count))
                if OfficialUsageParser.containsCompletedResponse(response) { break }
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) || !process.isRunning { break }
            usleep(20_000)
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < graceDeadline { usleep(10_000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()

        return response
    }
}

final class OfficialUsageMonitor {
    private let onUpdate: (UsageSnapshot) -> Void
    private let onDailyUpdate: ([DailyTokenUsage]) -> Void
    private let queue = DispatchQueue(label: "com.7agency.arqmeter.official", qos: .utility)
    private let reader = OfficialUsageReader()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var lastDailyAttempt: Date?
    private var lastDailySucceeded = false
    private var lastQuotaSucceeded = false

    init(onUpdate: @escaping (UsageSnapshot) -> Void,
         onDailyUpdate: @escaping ([DailyTokenUsage]) -> Void) {
        self.onUpdate = onUpdate
        self.onDailyUpdate = onDailyUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.refresh()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }

    private func refresh() {
        guard !stopped else { return }
        let snapshot = reader.snapshot()
        let quotaRecovered = snapshot != nil && !lastQuotaSucceeded
        lastQuotaSucceeded = snapshot != nil
        if let snapshot {
            DispatchQueue.main.async { [onUpdate] in onUpdate(snapshot) }
        }
        let now = Date()
        if OfficialDailyRefreshPolicy.shouldRefresh(lastAttempt: lastDailyAttempt,
            succeeded: lastDailySucceeded, now: now, quotaRecovered: quotaRecovered) {
            lastDailyAttempt = now
            if let daily = reader.dailyTokens() {
                lastDailySucceeded = true
                DispatchQueue.main.async { [onDailyUpdate] in onDailyUpdate(daily) }
            } else {
                lastDailySucceeded = false
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: OfficialUsageMonitor?
    private let dashboard: DashboardModel
    private let nativeQA: Bool
    private var qaAnchor: NSButton?
    private let sourcePreferences = SourceDisplayPreferences.shared
    private let popover = NSPopover()
    private var controlWindow: NSWindow?
    private var codexWindow: NSWindow?
    private var statusTimer: Timer?
    private var presentationConfigured = false

    init(qaDashboard: DashboardModel? = nil) {
        nativeQA = qaDashboard != nil
        dashboard = qaDashboard ?? DashboardModel()
        super.init()
    }

    /// Diagnostic-only anchor; the presentation and drag/toggle callbacks below
    /// are exactly those used by the installed app, without starting collectors.
    func prepareNativeQA(anchor: NSButton) {
        qaAnchor = anchor
        anchor.target = self
        anchor.action = #selector(toggleDashboard)
        if nativeQA {
            applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        }
    }

    func showNativeQAIfNeeded() {
        if nativeQA && !popover.isShown { toggleDashboard() }
    }

    func endNativeQA() {
        popover.performClose(nil)
        codexWindow?.close()
        controlWindow?.close()
        dashboard.stopAllLive()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !presentationConfigured else { return }
        presentationConfigured = true
        if !nativeQA {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.title = "— %"
            statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            statusItem.button?.target = self
            statusItem.button?.action = #selector(toggleDashboard)
        }
        // Remain visible when the user works elsewhere; native focus events
        // reduce the glass coverage. The menu counter remains the hide toggle.
        popover.behavior = .applicationDefined
        popover.appearance = InstrumentTheme.windowAppearance
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 650)
        popover.contentViewController = ArqmeterPopoverController(rootView: DashboardView(
            model: dashboard,
            openDetails: { [weak self] in self?.openControlCenter() },
            onWindowDrag: { [weak self] event in self?.dragOverview(with: event) }))
        if nativeQA {
            toggleDashboard()
            print("QA présentation configurée, popover visible=\(popover.isShown)"); fflush(stdout)
            return
        }
        sourcePreferences.onChange = { [weak self] in self?.updateStatusTitle() }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusTitle() }
        }
        updateStatusTitle()

        let monitor = OfficialUsageMonitor(onUpdate: { [weak self] snapshot in
            guard let self else { return }
            self.dashboard.apply(snapshot: snapshot)
            self.updateStatusTitle()
            HistoricalUsageService.shared.recordOfficialCodexQuota(snapshot.remainingPercent, at: snapshot.timestamp)
        }, onDailyUpdate: { [weak self] daily in
            self?.dashboard.apply(daily: daily)
        })
        self.monitor = monitor
        HistoricalUsageService.shared.start()
        monitor.start()
    }

    @objc private func toggleDashboard() {
        guard let button = qaAnchor ?? statusItem?.button else { return }
        if let window = codexWindow {
            if window.isVisible {
                window.orderOut(nil)
                dashboard.stopLive(for: "detached")
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                dashboard.startLive(for: "detached")
            }
            if nativeQA { print("QA toggle : visible=\(window.isVisible), frame=\(window.frame)"); fflush(stdout) }
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            dashboard.startLive(for: "menu")
            if nativeQA, let content = popover.contentViewController?.view,
               let window = content.window, let screen = window.screen {
                let rect = window.convertToScreen(content.convert(content.bounds, to: nil))
                print("QA header screen top-left x=\(rect.minX + 80), y=\(screen.frame.maxY - rect.maxY + 32); content=\(rect), screen=\(screen.frame)")
                fflush(stdout)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        dashboard.stopLive(for: "menu")
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        let window = makeDetachedOverview()
        dashboard.startLive(for: "detached")
        return window
    }

    private func dragOverview(with event: NSEvent?) {
        let content = popover.contentViewController?.view
        let origin = content?.window?.convertPoint(toScreen: content?.frame.origin ?? .zero)
        let pointer = event.flatMap { event in event.window?.convertPoint(toScreen: event.locationInWindow) }
        let window = makeDetachedOverview()
        if !window.isVisible, let origin { window.setFrameOrigin(origin) }
        // Acquire before closing the menu lease: one live reader, no gap or
        // duplicated two-second timer while transferring the same dashboard.
        dashboard.startLive(for: "detached")
        popover.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if event != nil, let pointer, let hud = window as? ArqmeterHUDWindow {
            hud.drag(from: pointer)
        }
        if nativeQA { print("QA drag : visible=\(window.isVisible), frame=\(window.frame)"); fflush(stdout) }
    }

    private func updateStatusTitle() {
        guard !nativeQA else { return }
        guard let button = statusItem?.button else { return }
        ProviderQuotaMenu.apply(to: button, codexRemaining: dashboard.remainingPercent,
            codexSampledAt: dashboard.officialSampledAt, codexReset: dashboard.resetsAt,
            claude: ClaudeQuotaReport.read(), now: Date())
    }

    private func openControlCenter() {
        popover.performClose(nil)
        codexWindow?.orderOut(nil)
        dashboard.stopLive(for: "detached")
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ControlWindowGeometry.initialSize.width,
                                                    height: ControlWindowGeometry.initialSize.height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "ARQMETER — Centre de contrôle"
            window.minSize = ControlWindowGeometry.minimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.appearance = InstrumentTheme.windowAppearance
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.contentView = ArqmeterHostingView(rootView: ControlCenterView(
                dashboard: dashboard, initialMode: "detailed",
                onBack: { [weak self] in self?.returnToOverview() }))
            window.center()
            controlWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        dashboard.startLive(for: "control")
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func returnToOverview() {
        controlWindow?.close()
        if let window = codexWindow {
            NSApp.setActivationPolicy(.accessory)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            dashboard.startLive(for: "detached")
            return
        }
        guard let button = qaAnchor ?? statusItem?.button else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.accessory)
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.dashboard.startLive(for: "menu")
        }
    }

    private func makeDetachedOverview() -> NSWindow {
        if codexWindow == nil {
            let window = ArqmeterHUDWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.title = "ARQMETER — Activité"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // The heading owns the move gesture; avoid starting a second
            // system background drag over the same mouse-down.
            window.isMovableByWindowBackground = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.appearance = InstrumentTheme.windowAppearance
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.contentView = ArqmeterHostingView(rootView: DashboardView(model: dashboard,
                openDetails: { [weak self] in self?.openControlCenter() }))
            window.center()
            codexWindow = window
        }
        return codexWindow!
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === codexWindow {
            dashboard.stopLive(for: "detached")
        } else if let window = notification.object as? NSWindow, window === controlWindow {
            dashboard.stopLive(for: "control")
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        dashboard.stopAllLive()
        monitor?.stop()
        HistoricalUsageService.shared.stop()
    }
}

if CommandLine.arguments.contains("--menu-quota-self-test") {
    do { try MainActor.assumeIsolated { try ProviderQuotaMenu.selfTest() }; exit(EXIT_SUCCESS) }
    catch { exit(EXIT_FAILURE) }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-menu-quotas"), CommandLine.arguments.count > index + 1 {
    do { try MainActor.assumeIsolated { try ProviderQuotaMenu.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }; exit(EXIT_SUCCESS) }
    catch { exit(EXIT_FAILURE) }
} else if CommandLine.arguments.contains("--capture-claude-status") {
    do {
        var data = Data()
        while data.count <= 256 * 1024,
              let chunk = try FileHandle.standardInput.read(upToCount: min(8192, 256 * 1024 + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
        }
        try ClaudeQuotaReport.decodeStatusLine(data, receivedAt: Date()).save()
        exit(EXIT_SUCCESS)
    } catch { exit(EXIT_FAILURE) }
} else if CommandLine.arguments.contains("--menu-bar-native-test") {
    MainActor.assumeIsolated { ProviderQuotaMenu.nativeTest() }
    exit(EXIT_SUCCESS)
} else if let index = CommandLine.arguments.firstIndex(of: "--render-glass-hud"), CommandLine.arguments.count > index + 1 {
    do {
        try MainActor.assumeIsolated {
            try GlassRecipe.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Rendu HUD échoué : \(error)\n", stderr); exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--glass-native-test") {
    MainActor.assumeIsolated { GlassRecipe.nativeTest() }
    exit(EXIT_SUCCESS)
} else if let index = CommandLine.arguments.firstIndex(of: "--render-quota-card") {
    do {
        try MainActor.assumeIsolated {
            try WeeklyQuotaRecipe.render(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
        }
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Échec du rendu hors écran : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--weekly-quota-self-test") {
    do {
        try WeeklyQuotaRecipe.selfTest()
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Échec de la carte quota : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--presentation-self-test") {
    do {
        try ControlPresentationSelfTest.run()
        print("Présentation : absence/zéro, fraîcheur, périodes et cadran existant : OK")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Échec des tests de présentation : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--instrument-self-test") {
    do {
        try InstrumentSelfTest.run()
        print("Cadran tokens : mesure, échelle stable, bornes, données absentes, courbes lacunaires : OK")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Échec des tests de présentation : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--instrument-visual-test") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 350),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "ARQMETER — TEST isolé des instruments"
    window.appearance = InstrumentTheme.windowAppearance
    window.contentView = NSHostingView(rootView: InstrumentTestView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    application.run()
} else if CommandLine.arguments.contains("--preview") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    HistoricalUsageService.shared.start()
    let model = DashboardModel()
    if !CommandLine.arguments.contains("--preview-no-quota"),
       let snapshot = OfficialUsageReader().snapshot() {
        model.apply(snapshot: snapshot)
        if CommandLine.arguments.contains("--preview-stale-quota") {
            model.officialSampledAt = Date().addingTimeInterval(-600)
        }
    }
    // A normal preview follows the same official quota monitor as the app.
    // A failed first read must not freeze its quota while live tokens update.
    // Deliberate unavailable/stale fixtures remain isolated from this monitor.
    let previewQuotaMonitor = OfficialUsageMonitor(
        onUpdate: { snapshot in model.apply(snapshot: snapshot) },
        onDailyUpdate: { daily in model.apply(daily: daily) })
    if !CommandLine.arguments.contains("--preview-no-quota") &&
       !CommandLine.arguments.contains("--preview-stale-quota") {
        previewQuotaMonitor.start()
    }
    defer { previewQuotaMonitor.stop() }
    let detailsPreview = CommandLine.arguments.contains("--preview-details")
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: detailsPreview ? ControlWindowGeometry.initialSize.width : 420,
                            height: detailsPreview ? ControlWindowGeometry.initialSize.height : 650),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = detailsPreview ? "ARQMETER — TEST vue complète (aperçu)" : "ARQMETER — Aperçu quotidien (TEST)"
    if detailsPreview { window.minSize = ControlWindowGeometry.minimumSize }
    window.appearance = InstrumentTheme.windowAppearance
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    var previewDetailsWindow: NSWindow?
    window.contentView = NSHostingView(rootView: detailsPreview
        ? AnyView(ControlCenterView(dashboard: model, initialMode: "detailed"))
        : AnyView(DashboardView(model: model, openDetails: {
            if previewDetailsWindow == nil {
                let details = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ControlWindowGeometry.initialSize.width,
                                                         height: ControlWindowGeometry.initialSize.height),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                details.title = "ARQMETER — TEST vue complète (aperçu)"
                details.minSize = ControlWindowGeometry.minimumSize
                details.appearance = InstrumentTheme.windowAppearance
                details.contentView = NSHostingView(rootView: ControlCenterView(
                    dashboard: model, initialMode: "detailed", onBack: {
                        previewDetailsWindow?.close()
                        window.makeKeyAndOrderFront(nil)
                        DispatchQueue.main.async { model.startLive() }
                    }))
                details.center()
                previewDetailsWindow = details
            }
            previewDetailsWindow?.makeKeyAndOrderFront(nil)
        })))
    window.center()
    window.makeKeyAndOrderFront(nil)
    model.startLive()
    application.run()
    model.stopLive()
    HistoricalUsageService.shared.stop()
} else if CommandLine.arguments.contains("--stats-self-test") {
    do {
        try LocalActivitySelfTest.run()
        print("Lecture incrémentale, dédoublonnage et ligne partielle : OK")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Échec du test local : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--comparison-self-test") {
    do {
        try ComparisonSelfTest.run()
        print("Archives, périodes, annotations et comparabilité : OK")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Échec du test de comparaison : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--stats-check") {
    let summary = LocalActivityStore().refresh()
    print("\(summary.total) tokens, \(summary.byProject.count) dossiers, \(summary.byHour.count) heures, \(summary.recent.count) événements récents")
    let projects = ProjectActivityPresentation()
    projects.reload()
    let groups = projects.groups(summary.events)
    for group in groups { print("projet | \(group.project.name) | \(group.total) tokens | \(group.project.provenance)") }
    guard groups.reduce(0, { $0 + $1.total }) == summary.total else { exit(EXIT_FAILURE) }
    exit(EXIT_SUCCESS)
} else if CommandLine.arguments.contains("--sources-check") {
    let codex = LocalActivityStore().refresh()
    let official = OfficialUsageReader().snapshot()
    let usage = UnifiedUsage(sources: [
        CodexAdapter(records: codex.unifiedEvents, installed: true, readable: codex.scanComplete,
                     quotaRemainingPercent: official?.remainingPercent,
                     quotaSampledAt: official?.timestamp).read(),
        ClaudeCodeAdapter().read(), GeminiAdapter().read(), LocalModelAdapter().read(),
    ])
    for source in usage.sources {
        let latest = source.lastRecord
        print("\(source.harnessID) | installé=\(source.installed) | lisible=\(source.readable) | événements=\(source.records.count) | dernier=\(latest?.timestamp.description ?? "indisponible") | modèle=\(latest?.modelID ?? "indisponible") | tokens_entrée=\(latest?.inputTokens.value.map(String.init) ?? "indisponible") | quota=\(source.quotaRemainingPercent.value.map(String.init) ?? "indisponible") | projet=\(latest?.projectPath ?? "indisponible")")
        if let diagnostic = source.diagnostic { print("  diagnostic: \(diagnostic)") }
    }
    let total = usage.aggregate()
    print("global | événements=\(total.records.count) | entrée_observée=\(total.inputTokens.value.map(String.init) ?? "indisponible") | couverture=\(total.inputTokens.coveredRecords)/\(total.inputTokens.totalRecords)")
    exit(EXIT_SUCCESS)
} else if CommandLine.arguments.contains("--history-check") {
    do {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arqmeter/historical-usage.sqlite3")
        let store = try HistoricalUsageStore(url: url)
        let results = try HistoricalUsageEngine(store: store).scan()
        let end = Date(), start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        for result in results {
            let coverage = try store.coverage(harness: result.harnessID, from: start, to: end)
            let input = coverage.metrics[.inputTokens]
            print("\(result.harnessID) | fichiers=\(result.filesScanned) | nouveaux/revus=\(result.recordsRead) | historiques_7j=\(coverage.eventCount) | entrée_mesurée=\(input?.measured ?? 0) | entrée_dérivée=\(input?.estimated ?? 0) | entrée_indisponible=\(input?.unavailable ?? 0) | trous=\(coverage.knownGaps.count) | continu=\(coverage.continuouslyObserved)")
            if let diagnostic = result.diagnostic { print("  \(diagnostic)") }
        }
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Historique indisponible : \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--cycle-check") {
    guard let snapshot = OfficialUsageReader().snapshot() else {
        fputs("Cycle officiel indisponible.\n", stderr)
        exit(EXIT_FAILURE)
    }
    let daily = OfficialUsageReader().dailyTokens() ?? []
    let history = CycleHistoryReader().read(resetAt: snapshot.resetsAt, daily: daily)
    print("Cycle actuel local : \(history.currentLocal), précédent local : \(history.previousLocal), journées complètes du compte : \(history.previousAccountFullDaysTokens.map(String.init) ?? "indisponible"), nombre de jours : \(history.previousAccountFullDays), lecture locale complète : \(history.localComplete)")
    exit(EXIT_SUCCESS)
} else if CommandLine.arguments.contains("--print") {
    if let snapshot = OfficialUsageReader().snapshot() {
        print("\(snapshot.remainingPercent) %")
        exit(EXIT_SUCCESS)
    }
    fputs("La limite Codex officielle est indisponible.\n", stderr)
    exit(EXIT_FAILURE)
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
