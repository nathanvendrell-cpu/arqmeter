import SwiftUI
import ArqmeterCore

struct ProjectActivityGroup: Identifiable {
    let project: UsageProjectIdentity
    var events: [LocalTokenEvent]
    var id: String { project.id }
    var total: Int64 { events.reduce(0) { $0 + $1.total } }
}

final class ProjectActivityPresentation: ObservableObject {
    private var resolver = UsageProjectResolver(registry: nil)
    private let registryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/.codex-global-state.json")

    init(registry: Data? = nil) { resolver = UsageProjectResolver(registry: registry) }

    func reload() {
        // Optional metadata only; never modify Codex's registry or stored usage.
        let size = (try? registryURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        resolver = UsageProjectResolver(registry: size > 0 && size <= 16 * 1024 * 1024
            ? try? Data(contentsOf: registryURL) : nil)
        objectWillChange.send()
    }

    func groups(_ events: [LocalTokenEvent]) -> [ProjectActivityGroup] {
        var result: [String: ProjectActivityGroup] = [:]
        for event in events {
            let project = resolver.resolve(session: event.session, workspace: event.projectPath)
            if result[project.id] == nil { result[project.id] = ProjectActivityGroup(project: project, events: []) }
            result[project.id]?.events.append(event)
        }
        return result.values.sorted {
            if $0.project.identified != $1.project.identified { return $0.project.identified }
            return $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total
        }
    }
}

enum ProjectActivitySelfTest {
    static func run() throws {
        let data = Data(#"{"local-projects":{"p":{"name":"Projet Alpha","rootPaths":["/fixture/project-alpha"]},"i":{"name":"Projet Beta","rootPaths":["/fixture/project-beta"]}}}"#.utf8)
        let model = ProjectActivityPresentation(registry: data)
        let events = [
            LocalTokenEvent(date: Date(), project: "old name", projectPath: "/fixture/project-alpha/a", session: "s1", input: 100, output: 10, cached: 90, cachedObserved: true),
            LocalTokenEvent(date: Date(), project: "another name", projectPath: "/fixture/project-alpha/b", session: "s2", input: 200, output: 20, cached: 0, cachedObserved: false),
            LocalTokenEvent(date: Date(), project: "Projet Beta", projectPath: "/fixture/project-beta", session: "s3", input: 30, output: 3, cached: 0, cachedObserved: true),
            LocalTokenEvent(date: Date(), project: "dans", projectPath: "", session: "s4", input: 7, output: 1, cached: 0, cachedObserved: false)
        ]
        let grouped = model.groups(events)
        guard grouped.count == 3, grouped.first?.project.name == "Projet Alpha", grouped.first?.total == 330,
              grouped.last?.project.identified == false,
              grouped.reduce(0, { $0 + $1.total }) == events.reduce(0, { $0 + $1.total }),
              grouped.reduce(0, { $0 + $1.events.count }) == events.count,
              model.groups([]).isEmpty else {
            throw NSError(domain: "ProjectActivitySelfTest", code: 1)
        }
    }
}

struct ProjectListPanel: View {
    let local: LocalTokenSummary?
    let now: Date
    @StateObject private var presentation = ProjectActivityPresentation()
    @AppStorage("projects.showConversations") private var showConversations = false

    var body: some View {
        let groups = presentation.groups(local?.events ?? [])
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Mes projets", systemImage: "folder.fill")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Menu {
                    Toggle("Afficher les conversations", isOn: $showConversations)
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Options des projets")
            }
            Text("Dernières 24 h · Codex sur ce Mac")
                .font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
            if let local, !local.scanComplete || !ControlReadout.isFresh(local.sampledAt, now: now, within: 10) {
                Label(local.scanComplete ? "Relevé ancien · actualisation en cours" : "Lecture partielle",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(InstrumentTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if groups.isEmpty {
                Text(local == nil ? "Lecture de l’activité…" : "Aucune consommation relevée sur cette période.")
                    .font(.system(size: 13)).foregroundStyle(InstrumentTheme.secondary)
                    .padding(.vertical, 20)
            } else {
                Text("TOKENS TRAITÉS · CACHE INCLUS")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(InstrumentTheme.secondary)
                ForEach(groups) { group in
                    projectRow(group, maximum: groups.map(\.total).max() ?? 1)
                    if group.id != groups.last?.id {
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.7)
                    }
                }
            }
        }
        .padding(16).glassCard()
        .onAppear { presentation.reload() }
    }

    private func projectRow(_ group: ProjectActivityGroup, maximum: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.project.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(compact(group.total))
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(group.project.identified ? InstrumentTheme.text : InstrumentTheme.secondary)
                    .fixedSize()
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.06))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [InstrumentTheme.blue, InstrumentTheme.violet],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * CGFloat(group.total) / CGFloat(max(1, maximum)))
                    }
            }.frame(height: 5)
            if !group.project.identified {
                Text("Aucune affectation fiable à un projet")
                    .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
            }
            if showConversations {
                DisclosureGroup("Conversations de ce projet") {
                    ForEach(Array(Dictionary(grouping: group.events, by: \.session).keys.sorted()), id: \.self) { session in
                        let events = group.events.filter { $0.session == session }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Conversation \(UsageProjectResolver.sessionID(session).prefix(8))")
                                if let last = events.map(\.date).max() {
                                    Text(last.formatted(.dateTime.day().month().hour().minute()))
                                        .foregroundStyle(InstrumentTheme.secondary)
                                }
                            }
                            Spacer(minLength: 6)
                            Text(compact(events.reduce(0) { $0 + $1.total }))
                                .monospacedDigit()
                        }.font(.system(size: 11)).padding(.vertical, 4)
                    }
                }.font(.system(size: 12)).padding(.top, 3)
            }
        }
        .padding(.vertical, 4)
        .help("\(group.project.provenance)\n\(group.project.path)\n\(group.total.formatted()) tokens · 24 h · ce Mac")
    }

    private func compact(_ value: Int64) -> String {
        let divisor: Double = value >= 1_000_000_000 ? 1_000_000_000 : value >= 1_000_000 ? 1_000_000 : value >= 1_000 ? 1_000 : 1
        let suffix = divisor == 1_000_000_000 ? " Md" : divisor == 1_000_000 ? " M" : divisor == 1_000 ? " k" : ""
        return (Double(value) / divisor).formatted(.number.precision(.fractionLength(divisor == 1 ? 0 : 1)).locale(Locale(identifier: "fr_FR"))) + suffix
    }
}
