import SwiftUI
import ArqmeterCore

/// Reuses the existing glass card and token timeline; no extra collector/timer.
struct AccountTimelineCard: View {
    @ObservedObject var model: AccountTimelineModel
    let days: [ArchivedDailyTokens]
    let quotaPoints: [QuotaHistoryPoint]
    let liveQuota: WeeklyQuotaObservation?
    var calendar: Calendar = .current
    var now: Date = Date()
    @State private var hoveredID: String?

    private let cyan = InstrumentTheme.cyan
    private let muted = InstrumentTheme.secondary

    private var cycles: [WeeklyQuotaCycle] {
        var observations = quotaPoints.map {
            WeeklyQuotaObservation(observedAt: $0.date, resetsAt: $0.resetsAt,
                remainingPercent: $0.remainingPercent, source: "codex", limit: "weekly")
        }
        if let liveQuota { observations.append(liveQuota) }
        return WeeklyQuotaTimeline.cycles(observations, now: now)
    }

    private var monthCycles: [WeeklyQuotaCycle] {
        WeeklyQuotaTimeline.inMonth(model.quotaMonth, cycles: cycles, calendar: calendar)
    }

    private var selected: WeeklyQuotaCycle? {
        let points = monthCycles
        return points.first { $0.id == (hoveredID ?? model.selectedQuotaCycleID) } ?? points.last
    }

    private var availableMonths: [QuotaCalendarMonth] {
        // Months without an observation remain reachable with the arrows.
        let current = QuotaCalendarMonth(containing: now, calendar: calendar)
        return Set(cycles.map { QuotaCalendarMonth(containing: $0.start, calendar: calendar) } +
                   [current, model.quotaMonth]).sorted {
            $0.year == $1.year ? $0.month > $1.month : $0.year > $1.year
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(cyan)
                Text("Quotas hebdomadaires")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                Text("Codex · 7 j")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(cyan)
                    .help("Pourcentages des limites officielles Codex relevés sur ce Mac. Pas de conversion depuis les tokens.")
            }
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Mois précédent")
                Spacer()
                Menu {
                    ForEach(availableMonths, id: \.self) { month in
                        Button(monthLabel(month)) { model.selectQuotaMonth(month) }
                    }
                } label: {
                    Text(monthLabel(model.quotaMonth))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Choisir le mois et l’année des quotas")
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.quotaMonth == QuotaCalendarMonth(containing: now, calendar: calendar))
                    .accessibilityLabel("Mois suivant")
            }
            .buttonStyle(.borderless).foregroundStyle(muted)

            if let selected {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(selected.usedPercent) %")
                        .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("du quota utilisé")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Spacer(minLength: 4)
                    Text(selected.isCurrent ? "En cours" : "Dernier relevé")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(cyan)
                }
                chart
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dateLabel(selected.start, time: true)) → \(dateLabel(selected.resetsAt, time: true))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                    Text(comparisonLabel(selected))
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Text("Relevé le \(dateLabel(selected.latest.observedAt, time: true))\(selected.isCurrent ? "" : " · pas un total final garanti")")
                        .font(.system(size: 10)).foregroundStyle(muted.opacity(0.86))
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aucun relevé de quota ce mois-ci.")
                        .font(.system(size: 13, weight: .medium))
                    Text("Les tokens ne permettent pas de le reconstituer.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            }
            Text("Chaque cycle est rattaché au mois où il commence.")
                .font(.system(size: 10)).foregroundStyle(muted.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .help("Début calculé : reset officiel moins 7 jours, dans le fuseau du Mac. Seulement les cycles réellement observés. Une rupture signale une période manquante ou un reset révisé. Un relevé d’un cycle clos n’est pas un total final garanti.")
            DisclosureGroup("Tokens détaillés", isExpanded: $model.quotaTokensExpanded) {
                AccountTokenTimelineCard(model: model, days: days)
                    .foregroundStyle(InstrumentTheme.text).padding(.top, 8)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(InstrumentTheme.blue)
        }
        .padding(15).glassCard()
    }

    private var chart: some View {
        let points = monthCycles
        let interval = model.quotaMonth.interval(calendar: calendar)!
        return VStack(spacing: 5) {
            HStack {
                Text("Quota utilisé · 0–100 %")
                Spacer()
                Text("\(points.count) \(points.count == 1 ? "cycle observé" : "cycles observés")")
            }
            .font(.system(size: 10)).foregroundStyle(muted.opacity(0.86))
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for fraction in [0.0, 0.5, 1.0] {
                            let y = chartY(fraction * 100, size: size)
                            path.move(to: CGPoint(x: 8, y: y))
                            path.addLine(to: CGPoint(x: size.width - 8, y: y))
                        }
                    }
                    .stroke(muted.opacity(0.14), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    Path { path in
                        for index in points.indices.dropFirst() {
                            let a = points[index - 1], b = points[index]
                            guard WeeklyQuotaTimeline.canConnect(a, b) else { continue }
                            path.move(to: location(a, interval: interval, size: size))
                            path.addLine(to: location(b, interval: interval, size: size))
                        }
                    }
                    .stroke(cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    ForEach(points) { point in
                        let location = location(point, interval: interval, size: size)
                        Button { model.selectedQuotaCycleID = point.id } label: {
                            Circle().fill(cyan).frame(width: selected?.id == point.id ? 9 : 7)
                                .overlay { Circle().strokeBorder(InstrumentTheme.graphite, lineWidth: 1) }
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).position(location)
                        .onHover { hovering in
                            if hovering { hoveredID = point.id }
                            else if hoveredID == point.id { hoveredID = nil }
                        }
                        .accessibilityLabel("\(dateLabel(point.start)) au \(dateLabel(point.resetsAt)) : \(point.usedPercent) % du quota utilisé\(point.isCurrent ? ", en cours" : ", dernier relevé")")
                        .help("\(point.usedPercent) % utilisés · \(dateLabel(point.start, time: true, year: true)) → \(dateLabel(point.resetsAt, time: true, year: true))\n\(comparisonLabel(point))\nRelevé le \(dateLabel(point.latest.observedAt, time: true, year: true))\(point.isCurrent ? " · en cours" : " · observation, pas un total final garanti")")
                        Text("\(point.usedPercent) %")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(cyan)
                            .position(x: min(size.width - 18, max(18, location.x)), y: location.y - 13)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 80)
            HStack {
                Text(dateLabel(interval.start))
                Spacer()
                Text(dateLabel(interval.end.addingTimeInterval(-1)))
            }
            .font(.system(size: 10)).foregroundStyle(muted.opacity(0.86))
        }
    }

    private func changeMonth(_ offset: Int) {
        model.selectQuotaMonth(model.quotaMonth.shifted(offset, calendar: calendar))
        hoveredID = nil
    }

    private func location(_ point: WeeklyQuotaCycle, interval: DateInterval, size: CGSize) -> CGPoint {
        CGPoint(x: 8 + (size.width - 16) * point.start.timeIntervalSince(interval.start) / interval.duration,
                y: chartY(Double(point.usedPercent), size: size))
    }

    private func chartY(_ percent: Double, size: CGSize) -> CGFloat {
        18 + (size.height - 22) * (1 - percent / 100)
    }

    private func comparisonLabel(_ cycle: WeeklyQuotaCycle) -> String {
        let all = cycles.filter { $0.source == cycle.source && $0.limit == cycle.limit }
        let index = all.firstIndex { $0.id == cycle.id }
        let previous = index.flatMap { $0 > 0 ? all[$0 - 1] : nil }
        switch WeeklyQuotaTimeline.comparison(cycle, previous: previous) {
        case .comparable(let delta): return "\(delta > 0 ? "+" : "")\(delta) points vs cycle précédent · même durée observée"
        case .firstObservation: return "Premier cycle observé · pas de comparaison"
        case .differentLimit: return "Comparaison impossible · limites différentes"
        case .missingOrRevisedCycle: return "Non comparable · reset révisé ou cycle manquant"
        case .differentElapsedTime: return "Non comparable · durées observées différentes"
        }
    }

    private func monthLabel(_ month: QuotaCalendarMonth) -> String {
        guard let date = month.interval(calendar: calendar)?.start else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR"); formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func dateLabel(_ date: Date, time: Bool = false, year: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR"); formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM" + (year ? " yyyy" : "") + (time ? " 'à' HH:mm" : "")
        return formatter.string(from: date)
    }
}
