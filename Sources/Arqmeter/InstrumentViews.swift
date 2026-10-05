import AppKit
import SwiftUI

// Presentation only. These colours and geometries never alter a usage metric.
enum InstrumentTheme {
    static let blue = Color(red: 0.29, green: 0.57, blue: 1)
    static let cyan = Color(red: 0.34, green: 0.84, blue: 0.95)
    static let violet = Color(red: 0.65, green: 0.53, blue: 0.98)
    static let mint = Color(red: 0.37, green: 0.87, blue: 0.73)
    // The accepted clear/light design is independent of system dark mode.
    static let text = Color(white: 0.06)
    static let secondary = Color(white: 0.22)
    static let paper = Color(white: 0.94)
    static var windowAppearance: NSAppearance? {
        NSAppearance(named: .aqua)
    }
    static let graphite = Color(red: 0.025, green: 0.035, blue: 0.075)
    static let alert = Color(red: 0.96, green: 0.51, blue: 0.43)
}

struct InstrumentButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        InstrumentButton(configuration: configuration, selected: selected, reduceMotion: reduceMotion)
    }

    private struct InstrumentButton: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let reduceMotion: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(InstrumentTheme.blue.opacity(configuration.isPressed ? 0.18 :
                    (hovered ? 0.09 : 0)), in: RoundedRectangle(cornerRadius: 9))
                .brightness(hovered && selected ? 0.045 : 0)
                .opacity(configuration.isPressed ? 0.82 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

enum TokenDialGeometry {
    // This is a labelled display scale in tokens, never a provider limit.
    // Retaining its high-water mark lets the needle fall when events leave
    // the rolling window instead of rescaling every sample to the same angle.
    static func maximum(amount: Double?, retaining previous: Double = 1) -> Double {
        guard let amount, amount > 0, amount.isFinite else { return max(1, previous) }
        let magnitude = pow(10, floor(log10(amount)))
        let coefficient = amount / magnitude
        let rounded = coefficient <= 1 ? 1.0 : coefficient <= 2 ? 2.0 : coefficient <= 5 ? 5.0 : 10.0
        return max(previous, rounded * magnitude)
    }

    static func fraction(amount: Double?, maximum: Double) -> Double? {
        guard let amount, amount >= 0, amount.isFinite, maximum > 0, maximum.isFinite else { return nil }
        return min(1, amount / maximum)
    }

    static func angle(_ fraction: Double) -> Double { 150 + min(1, max(0, fraction)) * 240 }

    static func label(_ amount: Double) -> String {
        let divisor: Double = amount >= 1_000_000_000 ? 1_000_000_000 : amount >= 1_000_000 ? 1_000_000 : amount >= 1_000 ? 1_000 : 1
        let suffix = divisor == 1_000_000_000 ? " Md" : divisor == 1_000_000 ? " M" : divisor == 1_000 ? " k" : ""
        let places = amount > 0 && amount < 1 ? min(6, Int(-floor(log10(amount))) + 1) : 1
        return (amount / divisor).formatted(.number.locale(Locale(identifier: "fr_FR"))
            .precision(.fractionLength(0...places))) + suffix
    }

    static func point(center: CGPoint, radius: Double, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }
}

private struct TokenArc: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: 76), radius: 49,
                    startAngle: .degrees(150), endAngle: .degrees(150 + 240 * progress), clockwise: false)
        return path
    }
}

private struct TokenNeedle: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: 76)
        let angle = TokenDialGeometry.angle(fraction)
        var path = Path()
        path.move(to: TokenDialGeometry.point(center: center, radius: 44, degrees: angle))
        path.addLine(to: TokenDialGeometry.point(center: center, radius: 3, degrees: angle + 90))
        path.addLine(to: TokenDialGeometry.point(center: center, radius: 9, degrees: angle + 180))
        path.addLine(to: TokenDialGeometry.point(center: center, radius: 3, degrees: angle - 90))
        path.closeSubpath()
        return path
    }
}

struct TokenInstrument: View {
    let amount: Double?
    let unit: String
    let periodID: String
    var forceReduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var maximumByPeriod: [String: Double] = [:]
    @State private var readingPulse = false
    @State private var pulseReset: DispatchWorkItem?
    private var maximum: Double {
        TokenDialGeometry.maximum(amount: amount, retaining: maximumByPeriod[periodID] ?? 0)
    }
    private var fraction: Double? { TokenDialGeometry.fraction(amount: amount, maximum: maximum) }
    private var pivotColor: Color {
        fraction == nil ? InstrumentTheme.secondary.opacity(0.4) : InstrumentTheme.blue
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.06)],
                    center: .topLeading, startRadius: 0, endRadius: 98))
                .overlay {
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.015), .white.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.24), radius: 4, y: 3)
                .frame(width: 98, height: 98).position(x: 82, y: 76)
            TokenArc(progress: 1)
                .stroke(LinearGradient(colors: [InstrumentTheme.secondary.opacity(0.42), InstrumentTheme.secondary.opacity(0.14), .black.opacity(0.22)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            if let fraction {
                TokenArc(progress: fraction)
                    .stroke(LinearGradient(colors: [InstrumentTheme.blue, InstrumentTheme.blue.opacity(0.84)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .shadow(color: InstrumentTheme.blue.opacity(readingPulse ? 0.32 : 0.10), radius: 2)
            }
            Canvas { context, size in drawGraduations(context, size: size) }
            if let fraction {
                TokenNeedle(fraction: fraction)
                    .fill(LinearGradient(colors: [InstrumentTheme.text, InstrumentTheme.secondary],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 1, y: 2)
            }
            Circle().fill(LinearGradient(colors: [InstrumentTheme.secondary, InstrumentTheme.graphite],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.7) }
                .overlay {
                    Circle().fill(RadialGradient(colors: [pivotColor, pivotColor.opacity(0.62)],
                        center: .topLeading, startRadius: 0, endRadius: 8)).padding(3)
                }
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                .frame(width: 12, height: 12).position(x: 82, y: 76)
            Text(amount == nil ? "Sans mesure récente" : "\(unit) · échelle auto")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(InstrumentTheme.secondary)
                .position(x: 82, y: 125)
        }
        .frame(width: 164, height: 140)
        .onAppear { retainScale() }
        .onChange(of: amount) { _ in retainScale(); markReading() }
        .onChange(of: periodID) { _ in retainScale(); stopPulse() }
        .onChange(of: reduceMotion) { value in if value { stopPulse() } }
        .onDisappear { stopPulse() }
        .animation(reduceMotion || forceReduceMotion ? nil : .easeOut(duration: 0.42), value: fraction)
        .animation(reduceMotion || forceReduceMotion ? nil : .easeOut(duration: 0.18), value: readingPulse)
        .help("Consommation sur la période choisie. Échelle en \(unit), conservée pendant cette lecture ; ce n’est pas un quota. L’aiguille ne bouge que lorsque la mesure change.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cadran de consommation de tokens")
        .accessibilityValue(amount.map { "\(TokenDialGeometry.label($0)) \(unit), échelle de 0 à \(TokenDialGeometry.label(maximum)) \(unit)" } ?? "Mesure non disponible ou périmée")
    }

    private func retainScale() {
        guard let amount, amount > 0 else { return }
        maximumByPeriod[periodID] = maximum
    }

    // Finite, data-driven highlight; no idle timer, display link or 3D scene.
    private func markReading() {
        stopPulse()
        guard !reduceMotion, !forceReduceMotion, fraction != nil else { return }
        readingPulse = true
        let work = DispatchWorkItem { readingPulse = false; pulseReset = nil }
        pulseReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func stopPulse() { pulseReset?.cancel(); pulseReset = nil; readingPulse = false }

    private func drawGraduations(_ context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: 76)
        for index in 0...20 {
            let major = index % 5 == 0
            let angle = TokenDialGeometry.angle(Double(index) / 20)
            var tick = Path()
            tick.move(to: TokenDialGeometry.point(center: center, radius: 56, degrees: angle))
            tick.addLine(to: TokenDialGeometry.point(center: center, radius: major ? 63 : 59, degrees: angle))
            context.stroke(tick, with: .color(InstrumentTheme.secondary.opacity(major ? 0.8 : 0.38)),
                           lineWidth: major ? 1.2 : 0.7)
        }
        let positions: [Double] = [0, 0.5, 1]
        for position in positions {
            let point: CGPoint = position == 0.5 ? CGPoint(x: center.x, y: 5) :
                TokenDialGeometry.point(center: center, radius: 73,
                                        degrees: TokenDialGeometry.angle(position))
            let label: String = amount == nil ? "—" : TokenDialGeometry.label(maximum * position)
            let tickFont: Font = .system(size: 10, weight: .medium, design: .monospaced)
            let tickText = Text(verbatim: label).font(tickFont).foregroundColor(InstrumentTheme.secondary)
            context.draw(tickText, at: point)
        }
    }
}

enum SparklineGeometry {
    // Keep the original time positions and break the line at every missing sample.
    static func segments(_ values: [Double?], size: CGSize) -> [[CGPoint]] {
        let maximum = max(1, values.compactMap { $0 }.max() ?? 1)
        var segments: [[CGPoint]] = [], current: [CGPoint] = []
        for (index, value) in values.enumerated() {
            guard let value else {
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            current.append(CGPoint(x: Double(index) / Double(max(1, values.count - 1)) * size.width,
                                   y: size.height - max(0, value) / maximum * (size.height - 2)))
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}

struct ActivitySparkline: View {
    let values: [Double?]
    var body: some View {
        Canvas { context, size in
            let baseline = Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: size.height)) }
            context.stroke(baseline, with: .color(InstrumentTheme.secondary.opacity(0.24)), lineWidth: 0.6)
            for segment in SparklineGeometry.segments(values, size: size) {
                var path = Path()
                if let first = segment.first { path.move(to: first) }
                for point in segment.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(InstrumentTheme.cyan), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if segment.count == 1, let point = segment.first {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)), with: .color(InstrumentTheme.cyan))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

enum InstrumentSelfTest {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "InstrumentSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try check(TokenDialGeometry.fraction(amount: 0, maximum: 1_000) == 0, "Aucune consommation pointe sur zéro")
        try check(TokenDialGeometry.fraction(amount: 1_000, maximum: 1_000) == 1, "Borne haute en tokens/s")
        try check(TokenDialGeometry.fraction(amount: nil, maximum: 1_000) == nil, "Mesure inconnue sans aiguille")
        try check(TokenDialGeometry.fraction(amount: -1, maximum: 1_000) == nil, "Mesure négative refusée")
        try check(TokenDialGeometry.fraction(amount: .infinity, maximum: 1_000) == nil, "Débit non fini refusé")
        try check(TokenDialGeometry.maximum(amount: 240_000) == 500_000, "Échelle lisible")
        let retained = TokenDialGeometry.maximum(amount: 900_000)
        try check(TokenDialGeometry.maximum(amount: 100_000, retaining: retained) == 1_000_000,
                  "Échelle stable quand la consommation baisse")
        try check(TokenDialGeometry.maximum(amount: Double(Int64.max)).isFinite, "Très grands volumes sans dépassement")
        try check(TokenDialGeometry.maximum(amount: 0.05, retaining: 0) == 0.05, "Échelle de débit inférieure à un token/s")
        try check(TokenDialGeometry.angle(0) == 150 && TokenDialGeometry.angle(1) == 390, "Bornes du cadran")
        try check(TokenDialGeometry.label(500_000) == "500 k", "Graduations exprimées en tokens, pas en pourcentage")
        try check(TokenDialGeometry.label(1.0 / 86_400) != "0", "Un petit débit positif n’est pas arrondi à zéro")
        let segments = SparklineGeometry.segments([10, nil, 0, 20], size: CGSize(width: 90, height: 20))
        try check(segments.count == 2 && segments[1][0].x == 60, "Trou historique préservé à sa position")
        try check(SparklineGeometry.segments([], size: .zero).isEmpty, "Historique vide sans activité inventée")
    }
}

// Explicit test-only UI: no DashboardModel, adapters, database or quota history.
struct InstrumentTestView: View {
    @State private var rate: Double? = 0
    @State private var reduced = false

    var body: some View {
        VStack(spacing: 16) {
            Text("TEST VISUEL · DONNÉES SIMULÉES")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(InstrumentTheme.blue)
            TokenInstrument(amount: rate, unit: "tokens/s", periodID: "test-minute", forceReduceMotion: reduced)
            Text(rate.map { "\(TokenDialGeometry.label($0)) tokens/s" } ?? "Mesure inconnue")
                .font(.system(size: 24, weight: .semibold)).monospacedDigit()
            HStack {
                Button("0 tokens/s") { rate = 0 }
                Button("4 k/s") { rate = 4_000 }
                Button("10 k/s") { rate = 10_000 }
            }
            HStack {
                Button("Inconnu / périmé") { rate = nil }
                Button("Baisse à 1 k/s") { rate = 1_000 }
            }
            Toggle("Réduire les animations (test)", isOn: $reduced)
            Text("Aucune donnée de test n’est enregistrée.")
                .font(.system(size: 11)).foregroundStyle(InstrumentTheme.secondary)
        }
        .padding(24).frame(width: 420, height: 350)
        .background(InstrumentTheme.paper).foregroundStyle(InstrumentTheme.text)
        .tint(InstrumentTheme.blue)
    }
}
