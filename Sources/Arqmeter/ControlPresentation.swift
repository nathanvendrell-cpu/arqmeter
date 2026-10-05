import Foundation

enum ControlWindowGeometry {
    static let initialSize = CGSize(width: 1120, height: 740)
    static let minimumSize = CGSize(width: 800, height: 560)
}

// Presentation policy only: reads existing measurements, never changes them.
enum ControlReadout {
    static func isFresh(_ sampledAt: Date?, now: Date, within seconds: TimeInterval) -> Bool {
        guard let sampledAt else { return false }
        let age = now.timeIntervalSince(sampledAt)
        return age >= -5 && age < seconds
    }

    static func quota(_ percent: Int?, sampledAt: Date?, now: Date, resetsAt: Date? = nil) -> Int? {
        guard resetsAt.map({ $0 > now }) ?? true else { return nil }
        guard isFresh(sampledAt, now: now, within: 180), let percent,
              (0...100).contains(percent) else { return nil }
        return percent
    }

    static func dial(_ window: ConsumptionWindow?, range: ConsumptionRange,
                     sampledAt: Date?, now: Date) -> Double? {
        if range.isOfficial { return window?.total.map(Double.init) }
        guard isFresh(sampledAt, now: now, within: 10) else { return nil }
        return window?.tokensPerSecond
    }

    static func componentRate(_ tokens: Int64?, window: ConsumptionWindow?, range: ConsumptionRange,
                              sampledAt: Date?, now: Date) -> Double? {
        guard !range.isOfficial, isFresh(sampledAt, now: now, within: 10),
              let window, window.scanComplete, let tokens, tokens >= 0 else { return nil }
        let duration = window.end.timeIntervalSince(window.start)
        guard duration > 0, duration.isFinite else { return nil }
        return Double(tokens) / duration
    }
}

// Reads the comparison engine's existing qualification. No invented savings.
struct WeeklyReadout {
    let change: Double?
    let basis: String
    let note: String
    let reductionPerWorkUnit: Bool

    var headline: String {
        guard let change else { return basis == "tokens" ? "Écart non calculable" : "Comparaison incomplète" }
        if basis != "tokens" {
            return change < 0 ? "Moins de tokens par unité livrée" : change > 0
                ? "Plus de tokens par unité livrée" : "Rendement inchangé"
        }
        return change < 0 ? "Consommation en baisse" : change > 0
            ? "Consommation en hausse" : "Consommation stable"
    }

    static func make(_ comparison: PeriodComparison) -> WeeklyReadout {
        let before = comparison.before, after = comparison.after
        guard before.start < after.start, before.complete, after.complete,
              before.covered, after.covered,
              before.reportedDays == before.calendarDays,
              after.reportedDays == after.calendarDays else {
            return WeeklyReadout(change: nil, basis: "Relevés incomplets",
                                 note: "Comparaison en attente", reductionPerWorkUnit: false)
        }
        if let change = comparison.workUnitChange, let unit = after.workUnits?.unit {
            return WeeklyReadout(change: change, basis: "tokens par \(unit)",
                                 note: "\(before.tier.label) · rendement observé",
                                 reductionPerWorkUnit: change < 0)
        }
        let change = comparison.totalChange ?? (before.tokens > 0
            ? (Double(after.tokens) / Double(before.tokens) - 1) * 100 : nil)
        let note: String
        if before.tier.knownTier == nil || after.tier.knownTier == nil {
            note = "Abonnement à renseigner"
        } else if before.tier != after.tier {
            note = "Abonnements différents"
        } else {
            note = "\(before.tier.label) · écart de consommation"
        }
        return WeeklyReadout(change: change, basis: "tokens", note: note,
                             reductionPerWorkUnit: false)
    }
}

enum ComparisonPresentation {
    static func periodLabel(_ period: ComparisonPeriod) -> String {
        guard period.scale == .week else { return period.title }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM yy"
        return formatter.string(from: period.start) + " – " + formatter.string(from: period.end.addingTimeInterval(-1))
    }
    static func missingDeltaReason(_ comparison: PeriodComparison) -> String {
        if comparison.before.start >= comparison.after.start { return "Choisir une période Après plus récente." }
        if comparison.before.tokens == 0 && comparison.before.complete && comparison.before.covered {
            return "Référence à zéro : pas de pourcentage calculable."
        }
        return "Deux périodes complètes sont nécessaires pour calculer l’écart."
    }
}

enum ControlPresentationSelfTest {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ControlPresentation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try check(ControlWindowGeometry.initialSize == CGSize(width: 1120, height: 740) &&
                  ControlWindowGeometry.minimumSize == CGSize(width: 800, height: 560),
                  "Même géométrie pour la fenêtre complète et ses aperçus ; minimum conservé")
        let empty = ConsumptionWindow.local(events: [], sampledAt: now, scanComplete: true, range: .minute)
        let partial = ConsumptionWindow.local(events: [], sampledAt: now, scanComplete: false, range: .minute)
        let measured = ConsumptionWindow(start: now.addingTimeInterval(-60), end: now, buckets: [],
            total: 600, input: 500, output: 100, cachedInput: 400,
            reportedDays: nil, calendarDays: nil, scanComplete: true)
        try check(ControlReadout.dial(measured, range: .minute, sampledAt: now, now: now) == 10,
                  "600 tokens sur une minute donnent 10 tokens/s, pas un pourcentage")
        try check(ControlReadout.componentRate(120, window: measured, range: .minute,
                  sampledAt: now, now: now) == 2, "Composante réelle : 120 tokens / 60 s")
        try check(ControlReadout.componentRate(0, window: measured, range: .minute,
                  sampledAt: now, now: now) == 0, "Composante à zéro mesuré")
        try check(ControlReadout.componentRate(nil, window: measured, range: .minute,
                  sampledAt: now, now: now) == nil, "Composante absente sans zéro inventé")
        try check(ControlReadout.componentRate(120, window: measured, range: .minute,
                  sampledAt: now.addingTimeInterval(-10), now: now) == nil, "Composante périmée masquée")
        try check(ControlReadout.componentRate(120, window: partial, range: .minute,
                  sampledAt: now, now: now) == nil, "Composante partielle sans faux débit")
        try check(ControlReadout.componentRate(120, window: measured, range: .week,
                  sampledAt: now, now: now) == nil, "Historique officiel sans ventilation inventée")
        try check(ControlReadout.dial(empty, range: .minute, sampledAt: now, now: now) == 0, "Zéro mesuré conservé")
        try check(ControlReadout.dial(nil, range: .minute, sampledAt: nil, now: now) == nil, "Lecture absente distincte de zéro")
        try check(ControlReadout.dial(partial, range: .minute, sampledAt: now, now: now) == nil, "Scan incomplet sans faux débit")
        try check(ControlReadout.dial(empty, range: .minute, sampledAt: now.addingTimeInterval(-10), now: now) == nil, "Débit périmé masqué")
        let noDays = ConsumptionWindow.official(days: [], range: .week, page: 0, now: now)
        try check(ControlReadout.dial(noDays, range: .week, sampledAt: nil, now: now) == nil, "Historique officiel vide sans zéro inventé")
        try check(ControlReadout.dial(measured, range: .week, sampledAt: nil, now: now) == 600,
                  "La vue historique expose un volume, jamais un débit ou un quota")
        try check(ControlReadout.quota(0, sampledAt: now, now: now) == 0, "Quota épuisé distinct d'un quota absent")
        try check(ControlReadout.quota(nil, sampledAt: now, now: now) == nil, "Quota absent")
        try check(ControlReadout.quota(98, sampledAt: now.addingTimeInterval(-180), now: now) == nil, "Ancien quota non présenté comme actuel")
        try check(ControlReadout.quota(101, sampledAt: now, now: now) == nil, "Quota hors bornes refusé")
        try check(ControlReadout.quota(74, sampledAt: now, now: now, resetsAt: now) == nil,
                  "Quota au reset non présenté comme actuel")
        try check(ControlReadout.quota(74, sampledAt: now, now: now, resetsAt: now.addingTimeInterval(-1)) == nil,
                  "Ancien cycle expiré masqué même si le relevé est récent")
        try check(ControlReadout.quota(74, sampledAt: now, now: now, resetsAt: now.addingTimeInterval(60)) == 74,
                  "Cycle officiel non expiré conservé")
        let paintClock = now.addingTimeInterval(-20)
        try check(ControlReadout.quota(74, sampledAt: now, now: paintClock) == nil &&
                  ControlReadout.quota(74, sampledAt: now, now: now) == 74,
                  "Horloge de mesure distincte d’une ancienne horloge de peinture")
        try check(!ControlReadout.isFresh(now.addingTimeInterval(60), now: now, within: 180), "Horodatage futur non fiable")
        try check(ConsumptionRange.allCases.count == 6 && ConsumptionRange.minute.localDuration == 60 &&
                  ConsumptionRange.tenMinutes.localDuration == 600 && ConsumptionRange.hour.localDuration == 3600,
                  "Périodes existantes conservées")
        func period(_ date: Date, tokens: Int64, tier: PeriodTier = .unknown,
                    reported: Int = 7, covered: Bool = true, complete: Bool = true,
                    units: WorkUnitAnnotation? = nil) -> ComparisonPeriod {
            ComparisonPeriod(scale: .week, start: date, end: date.addingTimeInterval(604800),
                title: "S", tokens: tokens, reportedDays: reported, activeDays: 5,
                calendarDays: 7, covered: covered, complete: complete, tier: tier,
                workflow: .unknown, workUnits: units)
        }
        let prior = now.addingTimeInterval(-604800)
        let unknown = WeeklyReadout.make(.make(before: period(prior, tokens: 100),
                                             after: period(now, tokens: 80)))
        try check(abs((unknown.change ?? 0) + 20) < 0.0001 && !unknown.reductionPerWorkUnit &&
                  unknown.note == "Abonnement à renseigner", "Plan inconnu : écart observé, pas gain")
        let partialWeek = WeeklyReadout.make(.make(before: period(prior, tokens: 100, reported: 6),
                                                 after: period(now, tokens: 80)))
        try check(partialWeek.change == nil, "Jours manquants sans faux pourcentage")
        let outOfCoverage = WeeklyReadout.make(.make(before: period(prior, tokens: 100, covered: false),
                                                   after: period(now, tokens: 80)))
        try check(outOfCoverage.change == nil, "Hors couverture sans faux gain")
        let unfinished = WeeklyReadout.make(.make(before: period(prior, tokens: 100),
                                                after: period(now, tokens: 80, complete: false)))
        try check(unfinished.change == nil, "Semaine en cours non comparable")
        let zeroReference = WeeklyReadout.make(.make(before: period(prior, tokens: 0),
                                                   after: period(now, tokens: 80)))
        try check(zeroReference.change == nil, "Référence zéro sans division par zéro")
        try check(zeroReference.headline == "Écart non calculable", "Référence zéro explicitée sans faux manque")
        let mixed = WeeklyReadout.make(.make(before: period(prior, tokens: 100, tier: .known(.x5)),
                                            after: period(now, tokens: 80, tier: .known(.x20))))
        try check(mixed.note == "Abonnements différents" && !mixed.reductionPerWorkUnit,
                  "x5/x20 : pas de gain assimilé")
        let normalized = WeeklyReadout.make(.make(
            before: period(prior, tokens: 100, tier: .known(.x5),
                           units: WorkUnitAnnotation(periodKey: "a", count: 10, unit: "tâche")),
            after: period(now, tokens: 80, tier: .known(.x5),
                          units: WorkUnitAnnotation(periodKey: "b", count: 10, unit: "tâche"))))
        try check(abs((normalized.change ?? 0) + 20) < 0.0001 && normalized.reductionPerWorkUnit,
                  "Même plan et travail annoté : rendement réellement normalisé")
        try check(normalized.headline == "Moins de tokens par unité livrée", "Gain normalisé explicite")
        try check(mixed.headline == "Consommation en baisse" && !mixed.reductionPerWorkUnit,
                  "Volume en baisse entre abonnements différents, pas gain")
        try check(partialWeek.headline == "Comparaison incomplète", "Comparaison incomplète lisible")
        let rawIncrease = WeeklyReadout.make(.make(before: period(prior, tokens: 100), after: period(now, tokens: 120)))
        try check(rawIncrease.headline == "Consommation en hausse", "Hausse lisible sans faux gain")
        let stable = WeeklyReadout.make(.make(before: period(prior, tokens: 100), after: period(now, tokens: 100)))
        try check(stable.headline == "Consommation stable", "Volume stable explicite")
        let calendarWeek = period(Date(timeIntervalSince1970: 1_789_948_800), tokens: 100)
        try check(ComparisonPresentation.periodLabel(calendarWeek).hasSuffix("27 sept. 26"),
                  "Dates hebdomadaires UTC sans décalage au lundi local")
        try ProjectActivitySelfTest.run()
        try LiveReadDemandSelfTest.run()
        try ControlRefreshSelfTest.run()
        try OfficialDailyRefreshSelfTest.run()
        try InstrumentSelfTest.run()
    }
}
