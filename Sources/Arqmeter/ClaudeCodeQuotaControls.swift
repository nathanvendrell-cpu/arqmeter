import SwiftUI
import ArqmeterCore

/// The single active quota source is the already-connected Claude Code account.
/// No embedded browser, manual reload, model prompt or connection mutation here.
struct ClaudeCodeQuotaControls: View {
    @ObservedObject private var reader = ClaudeCLIQuotaReader.shared
    @ObservedObject private var preferences = SourceDisplayPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code · quota automatique").font(.system(size: 13, weight: .semibold))
            Picker("Dans la barre de menus", selection: Binding(
                get: { preferences.claudeQuotaMode },
                set: { preferences.setClaudeQuotaMode($0) })) {
                ForEach(ClaudeMenuQuotaMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Fenêtres de quota Claude dans la barre de menus")
            Text("Pourcentages restants · 5 h en premier, semaine ensuite.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Utilise la connexion existante de Claude Code : relevés de l’activité, puis lecture automatique si nécessaire. Aucune page Web à ouvrir.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(reader.state).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = reader.nextAttemptAt, next > Date() {
                Text("Prochaine lecture autorisée : \(next.formatted(.dateTime.hour().minute().second()))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
