import ArqmeterCore
import Foundation
import SwiftUI

final class ManualTrialsModel: ObservableObject {
    @Published private(set) var trials: [ManualTrial] = []
    @Published private(set) var records: [UnifiedUsageRecord] = []
    @Published private(set) var sessions: [UsageSession] = []
    @Published var error: String?

    static var previewTestURL: URL? {
        guard CommandLine.arguments.contains("--preview"),
              CommandLine.arguments.contains("--preview-test-trials") else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("arqmeter-preview-trials-\(ProcessInfo.processInfo.processIdentifier).sqlite3")
    }

    private let url = ManualTrialsModel.previewTestURL ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arqmeter/manual-trials.sqlite3")

    func load() {
        do { trials = try ManualTrialStore(url: url).allTrials(); error = nil }
        catch { self.error = "Essais indisponibles : \(error)" }
        HistoricalUsageService.shared.allRecordedEvents { [weak self] records, sessions, error in
            self?.records = records
            self?.sessions = sessions
            if let error { self?.error = error }
        }
    }

    @discardableResult
    func save(_ trial: ManualTrial) -> Bool {
        do {
            _ = try ManualTrialStore(url: url).upsert(trial)
            trials = try ManualTrialStore(url: url).allTrials()
            error = nil
            return true
        } catch {
            self.error = "Enregistrement impossible : \(error)"
            return false
        }
    }
}

struct TrialEditorView: View {
    let sessions: [UsageSession]
    let existing: ManualTrial?
    let recommendationID: String?
    let onSave: (ManualTrial) -> Bool
    let onCancel: () -> Void

    @State private var beforeID: String
    @State private var afterID: String
    @State private var testedChange: String
    @State private var workDescription: String
    @State private var successCriteria: String
    @State private var quality: TrialEvidenceStatus
    @State private var equivalence: TrialEvidenceStatus
    @State private var checkOutcome: TrialCheckOutcome
    @State private var checkEvidence: String
    @State private var beforeAssociated: [TrialAssociatedSession]
    @State private var afterAssociated: [TrialAssociatedSession]
    @State private var attachSide = "Avant"
    @State private var attachRole: TrialAssociatedRole = .preparation
    @State private var attachID = ""
    @State private var validationError: String?

    init(sessions: [UsageSession], existing: ManualTrial? = nil,
         initialBeforeID: String? = nil, recommendationID: String? = nil,
         onSave: @escaping (ManualTrial) -> Bool, onCancel: @escaping () -> Void) {
        self.sessions = sessions
        self.existing = existing
        self.recommendationID = recommendationID ?? existing?.recommendationID
        self.onSave = onSave
        self.onCancel = onCancel
        _beforeID = State(initialValue: existing.map { "\($0.before.primary.harnessID):\($0.before.primary.sessionID)" } ?? initialBeforeID ?? "")
        _afterID = State(initialValue: existing?.after.map { "\($0.primary.harnessID):\($0.primary.sessionID)" } ?? "")
        _testedChange = State(initialValue: existing?.testedChange ?? "")
        _workDescription = State(initialValue: existing?.workDescription ?? "")
        _successCriteria = State(initialValue: existing?.successCriteria ?? "")
        _quality = State(initialValue: existing?.validation.quality ?? .notAssessed)
        _equivalence = State(initialValue: existing?.validation.workEquivalence ?? .notAssessed)
        _checkOutcome = State(initialValue: existing?.validation.checks.first?.outcome ?? .inconclusive)
        _checkEvidence = State(initialValue: existing?.validation.checks.first?.evidence ?? "")
        _beforeAssociated = State(initialValue: existing?.before.associated ?? [])
        _afterAssociated = State(initialValue: existing?.after?.associated ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(existing == nil ? "Nouvel essai manuel" : "Modifier l’essai")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Annuler", action: onCancel)
                Button("Enregistrer", action: save).buttonStyle(.borderedProminent)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text("Décrivez le travail et le changement sans coller de prompt complet. Les validations sont vos assertions, pas une preuve automatique d’équivalence.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Session avant", selection: $beforeID) { sessionOptions(includeNone: false) }
                    Picker("Session après", selection: $afterID) { sessionOptions(includeNone: true) }
                    if let before = sessions.first(where: { $0.id == beforeID }), before.modelID == nil {
                        Text("Modèle de référence inconnu : l’essai peut être documenté, mais la comparaison chiffrée sera refusée tant que l’identité du modèle n’est pas établie.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    if let before = sessions.first(where: { $0.id == beforeID }),
                       let after = sessions.first(where: { $0.id == afterID }),
                       (before.harnessID != after.harnessID || before.modelID != after.modelID) {
                        Text("Harness ou modèle différents : la comparaison chiffrée sera refusée.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    TextField("Changement testé", text: $testedChange, axis: .vertical).lineLimit(2...4)
                    TextField("Travail comparable à réaliser", text: $workDescription, axis: .vertical).lineLimit(2...4)
                    TextField("Critère de réussite vérifiable", text: $successCriteria, axis: .vertical).lineLimit(2...4)
                    Divider()
                    Text("Travail associé explicitement suivi").font(.system(size: 13, weight: .semibold))
                    Text("Ajoutez préparation, tentatives et modèle local si ces sessions font partie de ce même travail. Sinon elles restent hors comparaison.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Picker("Côté", selection: $attachSide) {
                            Text("Avant").tag("Avant")
                            Text("Après").tag("Après")
                        }.frame(width: 125)
                        Picker("Rôle", selection: $attachRole) {
                            Text("Préparation").tag(TrialAssociatedRole.preparation)
                            Text("Retry").tag(TrialAssociatedRole.retry)
                            Text("Traitement local").tag(TrialAssociatedRole.localProcessing)
                        }.frame(width: 165)
                        Picker("Session", selection: $attachID) { sessionOptions(includeNone: true) }
                        Button("Ajouter") { addAssociation() }.disabled(attachID.isEmpty)
                    }
                    associatedList("Avant", beforeAssociated)
                    associatedList("Après", afterAssociated)
                    Divider()
                    HStack {
                        evidencePicker("Qualité vérifiée", selection: $quality)
                        evidencePicker("Travail équivalent", selection: $equivalence)
                    }
                    Picker("Résultat du critère", selection: $checkOutcome) {
                        Text("Concluant").tag(TrialCheckOutcome.passed)
                        Text("Échec").tag(TrialCheckOutcome.failed)
                        Text("Non concluant").tag(TrialCheckOutcome.inconclusive)
                    }
                    TextField("Preuve courte du contrôle (facultatif)", text: $checkEvidence, axis: .vertical).lineLimit(2...4)
                    if let validationError { Text(validationError).font(.system(size: 11)).foregroundStyle(.red) }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 620)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func sessionOptions(includeNone: Bool) -> some View {
        if includeNone { Text("Aucune").tag("") }
        ForEach(sessions) { session in
            Text("\(session.harnessID) · \(session.modelID ?? "modèle ?") · \(session.lastEvent.formatted(date: .abbreviated, time: .shortened)) · \(session.sessionID.prefix(12))")
                .tag(session.id)
        }
    }

    private func evidencePicker(_ title: String, selection: Binding<TrialEvidenceStatus>) -> some View {
        Picker(title, selection: selection) {
            Text("Non vérifié").tag(TrialEvidenceStatus.notAssessed)
            Text("Vérifié par moi").tag(TrialEvidenceStatus.supported)
            Text("Non vérifié / invalide").tag(TrialEvidenceStatus.notSupported)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func associatedList(_ title: String, _ values: [TrialAssociatedSession]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold))
                ForEach(values.indices, id: \.self) { index in
                    HStack {
                        Text("\(values[index].role.rawValue) · \(values[index].session.harnessID) · \(values[index].session.sessionID)")
                            .font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Button("Retirer") {
                            if title == "Avant" { beforeAssociated.remove(at: index) }
                            else { afterAssociated.remove(at: index) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func reference(_ id: String) -> TrialSessionReference? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        return TrialSessionReference(harnessID: session.harnessID, providerID: session.providerID,
                                     modelID: session.modelID, sessionID: session.sessionID)
    }

    private func addAssociation() {
        if attachSide == "Après" && afterID.isEmpty {
            validationError = "Choisissez d’abord une session après pour y rattacher une étape."
            return
        }
        guard let reference = reference(attachID) else { return }
        let association = TrialAssociatedSession(role: attachRole, session: reference)
        if attachSide == "Avant" { beforeAssociated.append(association) }
        else { afterAssociated.append(association) }
        attachID = ""
    }

    private func save() {
        guard let before = reference(beforeID) else { validationError = "Choisissez une session avant."; return }
        let after = afterID.isEmpty ? nil : reference(afterID)
        if !afterID.isEmpty && after == nil { validationError = "La session après n’est plus dans l’historique."; return }
        if after == nil && !afterAssociated.isEmpty {
            validationError = "Les étapes après exigent une session après."
            return
        }
        let descriptions = [testedChange, workDescription, successCriteria]
        if descriptions.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.count > 600 }) {
            validationError = "Changement, travail et critère sont requis (600 caractères maximum chacun)."
            return
        }
        let references = [before] + beforeAssociated.map(\.session) + (after.map { [$0] } ?? []) + afterAssociated.map(\.session)
        let identities = references.map { "\($0.harnessID):\($0.sessionID)" }
        if Set(identities).count != identities.count {
            validationError = "Une même session ne peut être liée deux fois au même essai."
            return
        }
        let validation = TrialValidation(quality: quality, workEquivalence: equivalence,
            checks: [TrialValidationCheck(criterion: successCriteria, outcome: checkOutcome, evidence: checkEvidence)])
        var trial = existing ?? ManualTrial(recommendationID: recommendationID,
            before: TrialSide(primary: before), testedChange: testedChange,
            workDescription: workDescription, successCriteria: successCriteria)
        trial.before = TrialSide(primary: before, associated: beforeAssociated)
        trial.after = after.map { TrialSide(primary: $0, associated: afterAssociated) }
        trial.testedChange = testedChange
        trial.workDescription = workDescription
        trial.successCriteria = successCriteria
        trial.validation = validation
        if onSave(trial) { onCancel() }
        else { validationError = "Enregistrement impossible ; vérifiez le stockage local et réessayez." }
    }
}
