import SwiftUI

struct QuotaMeterView: View {
    let percent: Int?
    let reset: Date?
    let sampledAt: Date?
    let now: Date
    var compact = false
    var handle: AnyView? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var remaining: Int? {
        guard reset.map({ $0 > now }) ?? true else { return nil }
        return ControlReadout.quota(percent, sampledAt: sampledAt, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Quota Codex")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Text("7 jours").font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
                if let handle { handle }
            }
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 10)
                    if let remaining {
                        Circle().trim(from: 0, to: CGFloat(remaining) / 100)
                            .stroke(AngularGradient(colors: [InstrumentTheme.blue, InstrumentTheme.violet,
                                                            InstrumentTheme.blue], center: .center),
                                    style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: remaining)
                    }
                    VStack(spacing: 3) {
                        Text(remaining.map { "\($0) %" } ?? "—")
                            .font(.system(size: compact ? 23 : 27, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("restants").font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
                    }
                }
                .frame(width: compact ? 84 : 122, height: compact ? 84 : 122).padding(5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(remaining.map { "Quota officiel Codex : \($0) pour cent restants" } ?? "Quota non actualisé")
                VStack(alignment: .leading, spacing: 8) {
                    Label("Prochain reset", systemImage: "arrow.clockwise")
                        .font(.system(size: 12)).foregroundStyle(InstrumentTheme.secondary)
                    if let reset {
                        Text(reset.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text("à \(reset.formatted(.dateTime.hour().minute()))")
                            .font(.system(size: 13)).foregroundStyle(InstrumentTheme.secondary)
                        Text(countdown(reset))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(InstrumentTheme.blue)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("En attente du relevé")
                            .font(.system(size: 13)).foregroundStyle(InstrumentTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if remaining == nil {
                Label(sampledAt == nil ? "Relevé en attente" : "Quota à actualiser · nouvelle lecture automatique",
                      systemImage: sampledAt == nil ? "clock" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(sampledAt == nil ? InstrumentTheme.secondary : InstrumentTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Relevé officiel · \(sampledAt?.formatted(.dateTime.hour().minute()) ?? "")")
                    .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
            }
        }
        .padding(16).glassCard()
    }

    private func countdown(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Réinitialisation attendue" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return "Dans " + (formatter.string(from: seconds) ?? "moins d’une minute")
    }
}
