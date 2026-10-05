import SwiftUI

struct ComparisonPanel: View {
    @ObservedObject var model: ComparisonModel
    private let blue = InstrumentTheme.blue
    private let violet = InstrumentTheme.violet
    private let mint = InstrumentTheme.mint
    private let muted = InstrumentTheme.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            overviewCard
            comparisonCard
            DisclosureGroup("Historique des périodes") {
                trendCard.padding(.top, 8)
            }
            .font(.system(size: 12, weight: .medium))
            annotationsCard
        }
        .onAppear { model.annotationsExpanded = false }
        .confirmationDialog("Supprimer cette période d’abonnement ?",
            isPresented: Binding(get: { model.pendingSubscriptionDeletion != nil },
                                 set: { if !$0 { model.pendingSubscriptionDeletion = nil } })) {
            Button("Supprimer l’annotation", role: .destructive) {
                if let day = model.pendingSubscriptionDeletion { model.removeSubscription(day: day) }
                model.pendingSubscriptionDeletion = nil
            }
        } message: {
            Text("Le type d’abonnement redeviendra inconnu pour les dates concernées.")
        }
        .confirmationDialog("Supprimer ce changement de workflow ?",
            isPresented: Binding(get: { model.pendingWorkflowDeletion != nil },
                                 set: { if !$0 { model.pendingWorkflowDeletion = nil } })) {
            Button("Supprimer l’annotation", role: .destructive) {
                if let day = model.pendingWorkflowDeletion { model.removeWorkflow(day: day) }
                model.pendingWorkflowDeletion = nil
            }
        } message: {
            Text("Les périodes concernées n’auront plus cette étiquette de workflow.")
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Comparer ma consommation")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
            }
            Picker("Échelle", selection: Binding(get: { model.scale }, set: { model.setScale($0) })) {
                Text("Semaine").tag(ComparisonScale.week)
                Text("Mois").tag(ComparisonScale.month)
                Text("Trimestre").tag(ComparisonScale.quarter)
                Text("Année").tag(ComparisonScale.year)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Échelle de comparaison")
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
        .help("Relevés officiels Codex archivés. Comparaison d’abonnements identiques uniquement pour le rendement ; une baisse de volume seule ne prouve pas un meilleur workflow.")
    }

    private var trendCard: some View {
        let periods = model.periods
        let visible = model.visiblePeriods
        let maximum = max(Int64(1), periods.map(\.tokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(violet)
                Text("Historique · \(model.scale.rawValue.lowercased())")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text("TOKENS RAPPORTÉS")
                    .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.4)
                    .foregroundStyle(violet)
            }
            if periods.isEmpty {
                Text("Archive en attente du relevé quotidien officiel.")
                    .font(.system(size: 11)).foregroundStyle(muted.opacity(0.8))
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                HStack(spacing: 8) {
                    Button {
                        model.timelinePage += 1
                        model.focusedPeriodKey = ""
                    } label: { Image(systemName: "chevron.left") }
                    .disabled((model.timelinePage + 1) * 8 >= periods.count)
                    .accessibilityLabel("Périodes plus anciennes")
                    Spacer()
                    Text("\(visible.first?.title ?? "—") → \(visible.last?.title ?? "—")")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    Button {
                        model.timelinePage = max(0, model.timelinePage - 1)
                        model.focusedPeriodKey = ""
                    } label: { Image(systemName: "chevron.right") }
                    .disabled(model.timelinePage == 0)
                    .accessibilityLabel("Périodes plus récentes")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(muted)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(visible) { period in
                        periodColumn(period, maximum: maximum)
                    }
                }
                .frame(height: 135)

                if let focus = model.focusedPeriod {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(focus.title)
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(focus.reportedDays)/\(focus.calendarDays) jours rapportés · \(focus.tier.label)\(!focus.complete ? " · en cours" : (!focus.covered ? " · partielle" : ""))")
                                .font(.system(size: 9)).foregroundStyle(muted.opacity(0.76))
                        }
                        Spacer()
                        Text(compact(focus.tokens))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Button("A") { model.baselineKey = focus.id }
                            .accessibilityLabel("Choisir \(focus.title) comme référence A")
                        Button("B") { model.candidateKey = focus.id }
                            .accessibilityLabel("Choisir \(focus.title) comme période B")
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 10))
                    .padding(9)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Échelle constante sur tout l’historique · un jour absent n’est pas un zéro.")
                    .font(.system(size: 9)).foregroundStyle(muted.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .glassCard()
    }

    private func periodColumn(_ period: ComparisonPeriod, maximum: Int64) -> some View {
        let color = tierColor(period.tier)
        return Button { model.focusedPeriodKey = period.id } label: {
            VStack(spacing: 4) {
                HStack(spacing: 1) {
                    if model.selectedBefore?.id == period.id { marker("A", color: blue) }
                    if model.selectedAfter?.id == period.id { marker("B", color: violet) }
                }
                .frame(height: 14)
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if period.reportedDays == 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(muted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                .frame(height: 9)
                        } else {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(color.opacity(!period.complete || !period.covered
                                    ? 0.36 : (model.focusedPeriod?.id == period.id ? 1 : 0.72)))
                                .frame(height: max(3, geometry.size.height * CGFloat(period.tokens) / CGFloat(maximum)))
                        }
                    }
                }
                Text(shortTitle(period))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(muted.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(period.title), \(period.tokens.formatted()) tokens, \(period.tier.label), \(period.reportedDays) jours rapportés")
        .help("\(period.title) · \(period.tokens.formatted()) tokens · \(period.reportedDays)/\(period.calendarDays) jours · \(period.tier.label) · \(period.workflow.label)\(period.complete ? "" : " · en cours")")
    }

    private func shortTitle(_ period: ComparisonPeriod) -> String {
        switch period.scale {
        case .week: return period.title.components(separatedBy: " · ").first ?? "S—"
        case .month:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "MMM"
            return formatter.string(from: period.start).capitalized
        case .quarter: return period.title.components(separatedBy: " · ").first ?? "T—"
        case .year: return period.title
        }
    }

    private var comparisonCard: some View {
        let periods = model.periods
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex · compte")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                Spacer()
                if let tier = model.comparison?.before.tier.knownTier,
                   model.comparison?.after.tier.knownTier == tier {
                    Text("Même abonnement · \(tier.rawValue)")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
            }
            if periods.count < 2 {
                Text("Il faut deux périodes dans l’archive pour comparer à cette échelle.")
                    .font(.system(size: 11)).foregroundStyle(muted.opacity(0.8))
            } else {
                if let comparison = model.comparison {
                    comparisonResult(comparison)
                } else {
                    Text("Deux périodes terminées sont nécessaires pour une comparaison.")
                        .font(.system(size: 13)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Choisir les périodes") {
                    VStack(spacing: 8) {
                        Picker("Avant", selection: Binding(
                            get: { model.selectedBefore?.id ?? "" }, set: { model.baselineKey = $0 })) {
                            ForEach(Array(periods.reversed())) { period in
                                Text("\(period.title) · \(period.tier.label)").tag(period.id)
                            }
                        }.pickerStyle(.menu)
                        Picker("Après", selection: Binding(
                            get: { model.selectedAfter?.id ?? "" }, set: { model.candidateKey = $0 })) {
                            ForEach(Array(periods.reversed())) { period in
                                Text("\(period.title) · \(period.tier.label)").tag(period.id)
                            }
                        }.pickerStyle(.menu)
                    }.padding(.top, 8)
                }.font(.system(size: 12, weight: .medium))
            }
        }
        .padding(14)
        .glassCard()
    }

    @ViewBuilder
    private func comparisonResult(_ comparison: PeriodComparison) -> some View {
        let readout = WeeklyReadout.make(comparison)
        let maximum = max(Int64(1), comparison.before.tokens, comparison.after.tokens)
        Text(readout.headline)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
        if let change = readout.change {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(abs(change).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR")))) %")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(readout.reductionPerWorkUnit ? mint : InstrumentTheme.text)
                Text(readout.basis == "tokens" ? "de tokens \(change < 0 ? "en moins" : change > 0 ? "en plus" : "d’écart")" : readout.basis)
                    .font(.system(size: 12)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(ComparisonPresentation.missingDeltaReason(comparison))
                .font(.system(size: 12)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 10) {
            comparedValue("Avant", period: comparison.before, maximum: maximum, color: blue)
            comparedValue("Après", period: comparison.after, maximum: maximum, color: violet)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(readout.basis != "tokens" && readout.change != nil ? "Rendement observé à travail livré comparable" : "Gain de workflow : pas encore mesuré")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(readout.reductionPerWorkUnit ? mint : muted)
                .fixedSize(horizontal: false, vertical: true)
                .help(comparison.reason ?? "Écart observé, sans attribution causale au workflow.")
            if comparison.before.tier.knownTier == nil || comparison.after.tier.knownTier == nil {
                Button("Renseigner l’abonnement") { model.annotationsExpanded = true }
                    .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(blue)
            } else if comparison.before.tier != comparison.after.tier {
                Text("Abonnements différents · comparer deux périodes du même plan")
                    .font(.system(size: 12)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if comparison.isComparable {
            workloadEditor(comparison)
        }
        DisclosureGroup("Comprendre ce résultat") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Jours actifs : \(comparison.before.activeDays) → \(comparison.after.activeDays)")
                if let change = comparison.activeDayChange { Text("Par jour actif : \(delta(change))") }
                Text("Workflow A : \(comparison.before.workflow.label)")
                Text("Workflow B : \(comparison.after.workflow.label)")
                Text("Relevés : \(comparison.before.reportedDays)/\(comparison.before.calendarDays) jours → \(comparison.after.reportedDays)/\(comparison.after.calendarDays) jours")
                if let reason = comparison.reason { Text(reason) }
                if let first = model.archiveDays.first?.day, let last = model.archiveDays.last?.day {
                    Text("Archive : \(first) → \(last)")
                }
                Text(model.lastOfficialRead.map { "Dernière lecture : \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Archive locale")
                Text("Une baisse de volume ne prouve pas un gain de workflow. Le rendement par tâche exige le même abonnement et un travail annoté comparable ; sa qualité doit être vérifiée.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).foregroundStyle(muted).padding(.top, 8)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func comparedValue(_ title: String, period: ComparisonPeriod, maximum: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            Text(ComparisonPresentation.periodLabel(period))
                .font(.system(size: 12)).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(compact(period.tokens)).font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color).frame(width: geometry.size.width * CGFloat(period.tokens) / CGFloat(maximum))
                }
            }
            .frame(height: 5)
            if !period.complete || !period.covered || period.reportedDays != period.calendarDays {
                Text("\(period.reportedDays)/\(period.calendarDays) jours relevés\(period.complete ? "" : " · en cours")")
                    .font(.system(size: 11)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .help("\(period.title) : \(period.tokens.formatted()) tokens rapportés · \(period.tier.label)")
    }

    private func workloadEditor(_ comparison: PeriodComparison) -> some View {
        DisclosureGroup("Travail livré · optionnel", isExpanded: Binding(
            get: { model.workloadExpanded }, set: { model.workloadExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Unité identique pour A et B", text: Binding(
                    get: { model.workUnitLabel }, set: { model.workUnitLabel = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                HStack(spacing: 7) {
                    workUnitField("A", period: comparison.before)
                    workUnitField("B", period: comparison.after)
                    Button("Enregistrer") {
                        let first = model.workUnitDrafts[comparison.before.id]
                            ?? comparison.before.workUnits.map { String($0.count) } ?? ""
                        let second = model.workUnitDrafts[comparison.after.id]
                            ?? comparison.after.workUnits.map { String($0.count) } ?? ""
                        guard let countA = Int(first), countA > 0,
                              let countB = Int(second), countB > 0,
                              !model.workUnitLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            model.warning = "Saisir la même unité et un nombre positif pour A et B."
                            return
                        }
                        model.saveWorkUnits(periodKey: comparison.before.id, count: countA,
                                            unit: model.workUnitLabel)
                        model.saveWorkUnits(periodKey: comparison.after.id, count: countB,
                                            unit: model.workUnitLabel)
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                }
                Text("Exemple : tâches livrées avec le même critère de validation. Une session seule n’indique pas la valeur produite.")
                    .font(.system(size: 9)).foregroundStyle(muted.opacity(0.69))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 7)
        }
        .font(.system(size: 10, weight: .medium))
    }

    private func workUnitField(_ label: String, period: ComparisonPeriod) -> some View {
        TextField(label, text: Binding(
            get: { model.workUnitDrafts[period.id] ?? period.workUnits.map { String($0.count) } ?? "" },
            set: { model.workUnitDrafts[period.id] = $0 }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)
            .accessibilityLabel("Nombre d’unités de travail pour \(label)")
    }

    private var annotationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: Binding(
                get: { model.annotationsExpanded }, set: { model.annotationsExpanded = $0 })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Dates saisies par vous · jamais déduites automatiquement des tokens.")
                        .font(.system(size: 9)).foregroundStyle(muted.opacity(0.72))
                    planEditor
                    Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
                    workflowEditor
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Image(systemName: "tag.fill").foregroundStyle(blue)
                    Text("Abonnements & workflows")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            }
            .accentColor(blue)
        }
        .padding(14)
        .glassCard()
    }

    private var planEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ABONNEMENT · DATE DE DÉBUT")
                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(muted.opacity(0.74))
            HStack(spacing: 6) {
                DatePicker("", selection: Binding(get: { model.planDate }, set: { model.planDate = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().frame(maxWidth: 125)
                    .accessibilityLabel("Date de début de l’abonnement")
                Picker("", selection: Binding(get: { model.planTier }, set: { model.planTier = $0 })) {
                    ForEach(SubscriptionTier.allCases) { tier in Text(tier.rawValue).tag(tier) }
                }
                .labelsHidden().frame(width: 65)
                .accessibilityLabel("Type d’abonnement")
                Spacer(minLength: 0)
                Button("Ajouter") { model.addSubscription() }
                    .font(.system(size: 10)).buttonStyle(.bordered)
            }
            ForEach(model.subscriptions.reversed()) { change in
                HStack {
                    Text(change.effectiveDay).monospacedDigit()
                    Spacer()
                    badge(change.tier.rawValue, color: tierColor(.known(change.tier)))
                    Button {
                        model.pendingSubscriptionDeletion = change.effectiveDay
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(muted.opacity(0.65))
                    .accessibilityLabel("Supprimer l’abonnement du \(change.effectiveDay)")
                }
                .font(.system(size: 10))
            }
        }
    }

    private var workflowEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CHANGEMENT DE WORKFLOW")
                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(muted.opacity(0.74))
            HStack(spacing: 6) {
                DatePicker("", selection: Binding(get: { model.workflowDate }, set: { model.workflowDate = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().frame(maxWidth: 125)
                    .accessibilityLabel("Date du changement de workflow")
                TextField("Nom du workflow", text: Binding(
                    get: { model.workflowName }, set: { model.workflowName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                Button("Ajouter") { model.addWorkflow() }
                    .font(.system(size: 10)).buttonStyle(.bordered)
            }
            ForEach(model.workflows.reversed()) { change in
                HStack {
                    Text(change.effectiveDay).monospacedDigit()
                    Text(change.name).lineLimit(1)
                    Spacer()
                    Button {
                        model.pendingWorkflowDeletion = change.effectiveDay
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(muted.opacity(0.65))
                    .accessibilityLabel("Supprimer le workflow du \(change.effectiveDay)")
                }
                .font(.system(size: 10))
                .help(change.name)
            }
        }
    }

    private func marker(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func tierColor(_ tier: PeriodTier) -> Color {
        switch tier {
        case .known(.x5): return blue
        case .known(.x20): return violet
        case .mixed: return .orange
        case .unknown: return muted.opacity(0.68)
        }
    }

    private func compact(_ value: Int64) -> String {
        let number = Double(value)
        let french = Locale(identifier: "fr_FR")
        if value >= 1_000_000_000 {
            return "\((number / 1_000_000_000).formatted(.number.precision(.fractionLength(2)).locale(french))) Md"
        }
        if value >= 1_000_000 {
            return "\((number / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(french))) M"
        }
        if value >= 10_000 {
            return "\((number / 1_000).formatted(.number.precision(.fractionLength(0)).locale(french))) k"
        }
        return value.formatted()
    }

    private func delta(_ value: Double) -> String {
        let french = Locale(identifier: "fr_FR")
        let magnitude = abs(value).formatted(.number.precision(.fractionLength(1)).locale(french))
        return "\(value > 0 ? "+" : (value < 0 ? "−" : ""))\(magnitude) %"
    }
}
