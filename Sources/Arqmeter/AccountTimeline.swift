import Foundation
import SwiftUI
import ArqmeterCore

enum AccountRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }
    var label: String { "\(rawValue) j" }
    var groupingDays: Int { self == .ninetyDays ? 7 : 1 }
}

struct AccountTimeBucket: Identifiable {
    let start: Date
    let end: Date // Exclusive, UTC.
    let tokens: Int64?
    let reportedDays: Int
    let calendarDays: Int

    var id: Date { start }
}

struct AccountTimeWindow {
    let start: Date
    let end: Date // Exclusive, UTC.
    let buckets: [AccountTimeBucket]
    let reportedDays: Int
    let calendarDays: Int
    let total: Int64?

    static func make(days: [ArchivedDailyTokens], range: AccountRange,
                     page: Int, now: Date = Date()) -> AccountTimeWindow {
        let calendar = UTCDay.calendar
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let shift = max(0, page) * range.rawValue
        let end = calendar.date(byAdding: .day, value: -shift, to: tomorrow) ?? tomorrow
        let start = calendar.date(byAdding: .day, value: -range.rawValue, to: end) ?? end
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.tokens) })
        var buckets: [AccountTimeBucket] = []
        var position = start
        while position < end {
            let next = min(calendar.date(byAdding: .day, value: range.groupingDays, to: position) ?? end, end)
            var day = position
            var count = 0
            var tokens: Int64 = 0
            while day < next {
                if let value = byDay[UTCDay.string(day)] {
                    count += 1
                    tokens += value
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? next
            }
            buckets.append(AccountTimeBucket(start: position, end: next,
                tokens: count > 0 ? tokens : nil, reportedDays: count,
                calendarDays: calendar.dateComponents([.day], from: position, to: next).day ?? 0))
            position = next
        }
        let count = buckets.reduce(0) { $0 + $1.reportedDays }
        return AccountTimeWindow(start: start, end: end, buckets: buckets,
            reportedDays: count, calendarDays: range.rawValue,
            total: count > 0 ? buckets.compactMap(\.tokens).reduce(0, +) : nil)
    }
}

final class AccountTimelineModel: ObservableObject {
    @Published var range: AccountRange = .sevenDays
    @Published var page = 0
    @Published var selectedBucketID: Date?
    // User navigation only: incoming observations never move the viewed month.
    @Published private(set) var quotaMonth = QuotaCalendarMonth(containing: Date(), calendar: .current)
    @Published var selectedQuotaCycleID: String?
    @Published var quotaTokensExpanded = false

    func selectQuotaMonth(_ month: QuotaCalendarMonth) {
        quotaMonth = month
        selectedQuotaCycleID = nil
    }

    func setRange(_ value: AccountRange) {
        range = value
        page = 0
        selectedBucketID = nil
    }
}

struct AccountTokenTimelineCard: View {
    @ObservedObject var model: AccountTimelineModel
    let days: [ArchivedDailyTokens]

    private let cyan = InstrumentTheme.cyan
    private let blue = InstrumentTheme.blue
    private let muted = InstrumentTheme.secondary

    private var window: AccountTimeWindow {
        AccountTimeWindow.make(days: days, range: model.range, page: model.page)
    }

    private var selected: AccountTimeBucket? {
        window.buckets.first(where: { $0.id == model.selectedBucketID }) ?? window.buckets.last
    }

    private var canGoOlder: Bool {
        guard let first = days.first?.day else { return false }
        return UTCDay.string(window.start) > first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(cyan)
                Text("Historique du compte")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text("OFFICIEL")
                    .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.4)
                    .foregroundStyle(cyan)
            }
            Picker("Fenêtre", selection: Binding(
                get: { model.range }, set: { model.setRange($0) })) {
                ForEach(AccountRange.allCases) { choice in Text(choice.label).tag(choice) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Durée de l’historique officiel")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.total.map(compact) ?? "—")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens rapportés")
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.82))
                Spacer()
                Text("\(window.reportedDays)/\(window.calendarDays) j")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(cyan)
            }
            HStack(spacing: 8) {
                Button { model.page += 1; model.selectedBucketID = nil } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoOlder)
                .accessibilityLabel("Voir la période précédente")
                Spacer()
                Text("\(dateLabel(window.start)) – \(dateLabel(lastDay(before: window.end), year: true))")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                Spacer()
                Button { model.page = max(0, model.page - 1); model.selectedBucketID = nil } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(model.page == 0)
                .accessibilityLabel("Voir la période suivante")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(muted)

            if days.isEmpty {
                Text("Historique officiel en attente du premier relevé.")
                    .font(.system(size: 11)).foregroundStyle(muted.opacity(0.8))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                chart
                if let selected {
                    HStack {
                        Text("\(bucketLabel(selected))\(selected.end > UTCDay.calendar.startOfDay(for: Date()) ? " · en cours" : "")")
                        Spacer()
                        Text(selected.tokens.map { "\($0.formatted()) tokens" } ?? "Pas de relevé")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 10)).foregroundStyle(muted.opacity(0.86))
                }
                Text((model.range == .ninetyDays
                     ? "Barres de 7 jours ; jours sans relevé exclus du total."
                     : "Chaque barre représente un jour UTC ; absence de relevé ≠ zéro.")
                     + (model.page == 0 ? " Aujourd’hui est en cours." : ""))
                    .font(.system(size: 9)).foregroundStyle(muted.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .glassCard()
    }

    private var chart: some View {
        let maximum = max(Int64(1), window.buckets.compactMap(\.tokens).max() ?? 1)
        return VStack(spacing: 5) {
            HStack {
                Text("\(compact(maximum))")
                Spacer()
                Text(model.range == .ninetyDays ? "PAR GROUPE DE 7 J" : "PAR JOUR")
            }
            .font(.system(size: 9)).foregroundStyle(muted.opacity(0.63))
            HStack(alignment: .bottom, spacing: model.range == .thirtyDays ? 3 : 6) {
                ForEach(window.buckets) { bucket in
                    Button { model.selectedBucketID = bucket.id } label: {
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if let tokens = bucket.tokens {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(selected?.id == bucket.id ? cyan : blue)
                                        .frame(height: max(3, geometry.size.height * CGFloat(tokens) / CGFloat(maximum)))
                                } else {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(muted.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                        .frame(height: 8)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(bucketLabel(bucket)) : \(bucket.tokens.map { "\($0.formatted()) tokens" } ?? "aucun relevé")")
                    .help("\(bucketLabel(bucket)) · \(bucket.reportedDays)/\(bucket.calendarDays) jours rapportés · \(bucket.tokens.map { "\($0.formatted()) tokens" } ?? "aucun relevé")")
                }
            }
            .frame(height: 86)
            HStack {
                Text(dateLabel(window.start))
                Spacer()
                Text(dateLabel(lastDay(before: window.end)))
            }
            .font(.system(size: 9)).foregroundStyle(muted.opacity(0.65))
        }
    }

    private func bucketLabel(_ bucket: AccountTimeBucket) -> String {
        if bucket.calendarDays == 1 {
            return dateLabel(bucket.start, year: true)
        }
        return "\(dateLabel(bucket.start)) – \(dateLabel(lastDay(before: bucket.end), year: true))"
    }

    private func lastDay(before end: Date) -> Date {
        UTCDay.calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    private func dateLabel(_ date: Date, year: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = year ? "d MMM yyyy" : "d MMM"
        return formatter.string(from: date)
    }

    private func compact(_ value: Int64) -> String {
        let french = Locale(identifier: "fr_FR")
        if value >= 1_000_000_000 {
            return "\((Double(value) / 1_000_000_000).formatted(.number.precision(.fractionLength(2)).locale(french))) Md"
        }
        if value >= 1_000_000 {
            return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(french))) M"
        }
        return value.formatted()
    }
}
