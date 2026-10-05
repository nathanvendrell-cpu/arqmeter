import AppKit
import SwiftUI
import WebKit
import ArqmeterCore

/// Opt-in browser connection: login is performed by the user on Claude's page.
/// WebKit owns authentication; Arqmeter never accesses its cookie/credential APIs.
@MainActor final class ClaudeOfficialPage: NSObject, ObservableObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = ClaudeOfficialPage()
    static let usageURL = URL(string: "https://claude.ai/settings/usage")!
    @Published private(set) var state = "Non connecté"
    private let defaults: UserDefaults
    private let cacheURL: URL
    private var web: WKWebView?
    private var window: NSWindow?
    private var timer: Timer?
    private var timeout: DispatchWorkItem?
    private var generation = 0
    private var failures = 0
    private var loadedAt: Date?
    private var busy = false
    private var stopped = true
    private var activeNavigation: WKNavigation?

    init(defaults: UserDefaults = .standard, cacheURL: URL = ClaudeWebQuotaReport.cacheURL) {
        self.defaults = defaults; self.cacheURL = cacheURL
        super.init()
    }
    var enabled: Bool { defaults.bool(forKey: ClaudeWebQuotaReport.enabledKey) }
    var report: ClaudeWebQuotaReport? { enabled ? ClaudeWebQuotaReport.read(url: cacheURL) : nil }
    var selected: Bool { defaults.bool(forKey: ClaudeWebQuotaReport.selectedKey) }
    func startIfEnabled() { if enabled && selected { stopped = false; refresh() } }
    func connect() {
        stopped = false
        defaults.set(true, forKey: ClaudeWebQuotaReport.selectedKey)
        prepare()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        if !busy { refresh() }
    }
    func suspend() {
        defaults.set(false, forKey: ClaudeWebQuotaReport.enabledKey)
        stop(); state = "Suivi arrêté"
        // Keep browser's session and old measurements; do not delete user data.
    }
    func useCodeSource() {
        suspend(); defaults.set(false, forKey: ClaudeWebQuotaReport.selectedKey)
        state = "Source choisie : Claude Code"
    }
    func stop() {
        stopped = true; generation += 1; timer?.invalidate(); timer = nil
        timeout?.cancel(); timeout = nil; busy = false
        web?.stopLoading(); web?.navigationDelegate = nil
        window?.delegate = nil; window?.orderOut(nil)
        window = nil; web = nil; activeNavigation = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        if !enabled { stop() }
        return false
    }
    private func prepare() {
        guard web == nil else { return }
        let config = WKWebViewConfiguration()
        // Dedicated browser session, never imported from Chrome/Claude Desktop.
        if #available(macOS 14, *) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "29B7F810-5351-4A72-9534-114E81ED01E1")!)
        } else { config.websiteDataStore = .default() }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 650), configuration: config)
        view.navigationDelegate = self
        let panel = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Connecter Claude — page officielle"
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.contentView = view; panel.center()
        web = view; window = panel
    }
    private func refresh() {
        guard !stopped, !busy else { return }
        prepare(); timer?.invalidate(); timer = nil
        busy = true; generation += 1
        state = "Actualisation de la page officielle…"
        armTimeout()
        if web?.url == Self.usageURL { activeNavigation = web?.reloadFromOrigin() }
        else {
            var request = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "GET"; activeNavigation = web?.load(request)
        }
    }
    private func armTimeout() {
        timeout?.cancel()
        let current = generation
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.generation == current, self.busy else { return }
            self.web?.stopLoading(); self.failed("Page non chargée")
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: deadline)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !stopped else { return }
        generation += 1; activeNavigation = navigation; loadedAt = nil; busy = true
        armTimeout()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, navigation === activeNavigation else { return }
        guard let url = webView.url, url.scheme == "https", url.host == "claude.ai", url.path == "/settings/usage" else {
            timeout?.cancel(); busy = false; state = "Connexion requise sur la page officielle"
            defaults.set(false, forKey: ClaudeWebQuotaReport.enabledKey)
            timer?.invalidate(); timer = nil
            return
        }
        loadedAt = Date(); extract(attempt: 0, generation: generation)
    }
    private func extract(attempt: Int, generation current: Int) {
        guard !stopped, current == generation else { return }
        guard let web, let url = web.url, let loadedAt,
              let scriptURL = Bundle.main.url(forResource: "claude-official-usage", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else { failed("Lecteur de quota absent"); return }
        web.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, !self.stopped, self.generation == current else { return }
            guard self.web?.url == url else {
                self.timeout?.cancel(); self.busy = false
                self.defaults.set(false, forKey: ClaudeWebQuotaReport.enabledKey)
                self.state = "Connexion requise sur la page officielle"; return
            }
            let now = Date()
            if error == nil, let result, JSONSerialization.isValidJSONObject(result),
               let data = try? JSONSerialization.data(withJSONObject: result),
               let report = try? ClaudeWebQuotaReport.decode(data, pageURL: url, loadedAt: loadedAt, observedAt: now),
               (try? report.save(url: self.cacheURL)) != nil {
                self.timeout?.cancel(); self.busy = false; self.failures = 0
                self.defaults.set(true, forKey: ClaudeWebQuotaReport.enabledKey)
                self.state = "Page officielle · relevé à \(now.formatted(.dateTime.hour().minute()))"
                self.schedule(after: 60)
            } else if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.extract(attempt: attempt + 1, generation: current) }
            } else { self.failed("Quota non reconnu · dernier relevé conservé, sans le rafraîchir") }
        }
    }
    private func failed(_ message: String) {
        guard !stopped else { return }
        generation += 1; timeout?.cancel(); busy = false
        state = message; failures = min(failures + 1, 4)
        if enabled { schedule(after: min(900, 60 * pow(2, Double(failures)))) }
    }
    private func schedule(after interval: TimeInterval) {
        guard !stopped, enabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.stopped, self.enabled { self.refresh() } }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === activeNavigation { failed("Actualisation échouée") }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === activeNavigation { failed("Connexion à la page échouée") }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed("Lecteur interrompu") }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == "https" ? .allow : .cancel)
    }
    static func lifecycleSelfTest() throws {
        let suite = "com.7agency.arqmeter.web-lifecycle-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClaudeWebQuotaReport.enabledKey)
        let service = ClaudeOfficialPage(defaults: defaults, cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        service.stopped = false
        let obsoleteGeneration = service.generation
        service.schedule(after: 60)
        service.stop()
        let stoppedGeneration = service.generation
        service.extract(attempt: 1, generation: obsoleteGeneration)
        service.failed("late callback")
        service.schedule(after: 60)
        service.refresh()
        guard service.generation == stoppedGeneration, service.timer == nil,
              service.timeout == nil, service.web == nil, service.window == nil, !service.busy else {
            throw NSError(domain: "ClaudeOfficialPageLifecycle", code: 1)
        }
        print("Claude browser lifecycle: delayed/failed callbacks after stop cannot refresh or rearm a timer; no user defaults/cache modified: OK")
    }
}

struct ClaudeOfficialConnectionControls: View {
    @ObservedObject var connection: ClaudeOfficialPage
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Connecter Claude") { connection.connect() }
                if connection.enabled { Button("Arrêter le suivi") { connection.suspend() } }
                if connection.selected { Button("Utiliser Claude Code") { connection.useCodeSource() } }
            }
            Text(connection.state).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Connexion personnelle sur claude.ai. Lecture du quota affiché, toutes les 60 s ; aucun appel modèle. La fraîcheur serveur n’est pas fournie par la page.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
