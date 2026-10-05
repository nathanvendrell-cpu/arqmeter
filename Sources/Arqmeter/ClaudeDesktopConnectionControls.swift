import SwiftUI

struct ClaudeDesktopConnectionControls: View {
    @ObservedObject private var reader = ClaudeDesktopQuotaReader.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Utiliser Claude déjà connecté") { reader.select() }
                if reader.selected && !reader.authorized {
                    Button("Autoriser la lecture") { reader.requestAuthorization() }
                }
            }
            if reader.selected {
                Text(reader.state).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Lecture du panneau Utilisation de Claude, même en arrière-plan, toutes les 60 s. Garder ce panneau ouvert ; pas de seconde connexion ni de déplacement automatique de votre conversation. La fraîcheur serveur n’est pas fournie.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
