import AppKit
import SwiftUI

private struct ArqmeterWindowFocusedKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var arqmeterWindowFocused: Bool {
        get { self[ArqmeterWindowFocusedKey.self] }
        set { self[ArqmeterWindowFocusedKey.self] = newValue }
    }
}

/// One focus state for all background layers, not just the outer window.
struct ArqmeterWindowFocus: ViewModifier {
    @State private var focused = true
    func body(content: Content) -> some View {
        content.environment(\.arqmeterWindowFocused, focused)
            .background { ArqmeterFocusProbe { focused = $0 } }
    }
}

/// One window-level backdrop. Interior cards must not stack opaque materials.
struct ArqmeterGlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arqmeterWindowFocused) private var focused
    var body: some View {
        if reduceTransparency {
            InstrumentTheme.paper
        } else if #available(macOS 26.0, *) {
            // Do not frost the entire desktop once with a dense standard
            // material, then ask interior glass to refract that grey surface.
            Group {
                if focused {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.66))
                        .glassEffect(.clear.tint(.white.opacity(0.16)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    // No full-window white frosting while working elsewhere.
                    // Keep content opaque; only the background becomes clear.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.025))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
                        }
                }
            }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
        } else {
            WindowBackdrop()
                .opacity(focused ? 1 : 0.08)
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.035), .clear, .black.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
    }

    private struct WindowBackdrop: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .active
            view.isEmphasized = false
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

/// Window-local notifications only: no global pointer hook, hover activation,
/// polling or background animation. Observers belong to this displayed view.
private struct ArqmeterFocusProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = Probe(); view.onChange = onChange; return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Probe)?.onChange = onChange
    }
    private final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name,
                    object: window, queue: .main) { [weak self] _ in self?.refresh() })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name,
                    object: NSApp, queue: .main) { [weak self] _ in self?.refresh() })
            }
            refresh()
        }
        private func refresh() {
            let active = window?.isKeyWindow == true && NSApp.isActive
            guard last != active else { return }
            last = active
            if CommandLine.arguments.contains("--glass-native-test") {
                print("QA focus : active=\(active), visible=\(window?.isVisible ?? false), frame=\(window?.frame ?? .zero)")
                fflush(stdout)
            }
            DispatchQueue.main.async { [weak self] in self?.onChange?(active) }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct ArqmeterGlassSurface: ViewModifier {
    var radius: CGFloat = 24
    var shadow: CGFloat = 8
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arqmeterWindowFocused) private var focused

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(InstrumentTheme.paper, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.24), lineWidth: 0.8).allowsHitTesting(false) }
        } else if #available(macOS 26.0, *) {
            finish(content.background {
                if focused {
                    shape.fill(.clear).glassEffect(.clear.tint(.white.opacity(0.12)), in: shape)
                } else {
                    // Interior cards must not continue blurring an otherwise
                    // transparent window. Preserve the rim, not a white veil.
                    shape.fill(.white.opacity(0.04))
                }
            }, shape: shape)
        } else {
            finish(content.background {
                if focused { shape.fill(.ultraThinMaterial) }
                else { shape.fill(.white.opacity(0.04)) }
            }, shape: shape)
        }
    }

    private func finish<V: View>(_ content: V, shape: RoundedRectangle) -> some View {
        content
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.03)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(focused ? 1 : 0.35).allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(0.66), location: 0),
                    .init(color: .white.opacity(0.10), location: 0.46),
                    .init(color: .white.opacity(0.32), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                    .opacity(focused ? 1 : 0.40).allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(focused ? 0.20 : 0.06), radius: shadow, y: 3)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

extension View {
    func arqmeterGlass(radius: CGFloat, shadow: CGFloat = 4) -> some View {
        modifier(ArqmeterGlassSurface(radius: radius, shadow: shadow))
    }
}

/// Hosting itself must not fill an opaque NSWindow behind the SwiftUI glass.
final class ArqmeterHostingView<Content: View>: NSHostingView<Content> {
    private var appearanceObserver: NSObjectProtocol?
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyGlassAppearance()
        if appearanceObserver == nil {
            appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.applyGlassAppearance() }
        }
    }
    private func applyGlassAppearance() {
        appearance = InstrumentTheme.windowAppearance
        window?.appearance = InstrumentTheme.windowAppearance
    }
    deinit {
        if let appearanceObserver { NSWorkspace.shared.notificationCenter.removeObserver(appearanceObserver) }
    }
}

/// Drag only the heading, never intercept the period buttons, charts or gear.
struct ArqmeterWindowDragHandle: NSViewRepresentable {
    var onDrag: ((NSEvent?) -> Void)? = nil
    func makeNSView(context: Context) -> NSView {
        let view = Handle(); view.onDrag = onDrag; return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Handle)?.onDrag = onDrag
    }
    private final class Handle: NSView {
        var onDrag: ((NSEvent?) -> Void)?
        override func isAccessibilityElement() -> Bool { onDrag != nil }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { "Déplacer la fenêtre" }
        override func accessibilityPerformPress() -> Bool {
            guard let onDrag else { return false }
            onDrag(nil) // Detach without requiring a pointer gesture (VoiceOver).
            return true
        }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            // A title click also detaches the HUD. Track only this gesture;
            // AppKit's system move path is unreliable for borderless panels.
            if let onDrag { onDrag(event) }
            else if let window = window as? ArqmeterHUDWindow {
                window.drag(from: window.convertPoint(toScreen: event.locationInWindow))
            }
        }
    }
}

/// Same HUD, no imposed title bar or extra layout when detached from the menu.
final class ArqmeterHUDWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func drag(from pointer: NSPoint) {
        let origin = frame.origin
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--glass-native-test") {
            print("QA move début : \(frame)"); fflush(stdout)
        }
        // Only during mouse-down: no global monitor or idle loop. A missed
        // mouse-up still ends when AppKit reports the button released.
        while isVisible {
            let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                until: Date().addingTimeInterval(0.25), inMode: .eventTracking, dequeue: true)
            // Use this gesture's event coordinates, not the global cursor:
            // synthesized/accessibility input can have a different cursor.
            if let event, let eventWindow = event.window {
                let current = eventWindow.convertPoint(toScreen: event.locationInWindow)
                setFrameOrigin(NSPoint(x: origin.x + current.x - pointer.x,
                                       y: origin.y + current.y - pointer.y))
            }
            if event?.type == .leftMouseUp || NSEvent.pressedMouseButtons & 1 == 0 { break }
        }
        if CommandLine.arguments.contains("--glass-native-test") {
            print("QA move fin : \(frame)"); fflush(stdout)
        }
    }
}

final class ArqmeterPopoverController<Content: View>: NSViewController {
    private let root: Content
    private var accessibilityObserver: NSObjectProtocol?
    init(rootView: Content) { root = rootView; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Code-only controller") }
    override func loadView() { view = ArqmeterHostingView(rootView: root) }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.isOpaque = false
        view.window?.backgroundColor = .clear
        configureNativeBackdrop()
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.configureNativeBackdrop() }
        }
    }

    private func configureNativeBackdrop() {
        guard #available(macOS 26.0, *),
              let frame = view.superview as? NSVisualEffectView else { return }
        // Public NSVisualEffectView API, restricted to our own popover's
        // immediate frame. Mask only its effect, NOT the hosted text/controls.
        // The content provides clear native glass, with no second .popover blur.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            frame.maskImage = nil
        } else {
            frame.maskImage = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
                NSColor.clear.setFill()
                rect.fill(using: .copy)
                return true
            }
        }
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }
}
