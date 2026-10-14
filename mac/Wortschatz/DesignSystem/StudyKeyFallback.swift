import AppKit
import SwiftUI
import WortschatzCore

extension View {
    /// Keys that would otherwise be lost on a study screen. When an answer was typed right, its
    /// field goes away while it still has the keyboard focus, and for a moment the window itself
    /// can hold the focus before SwiftUI hands it to the screen: Return then did nothing and the
    /// praise could not be skipped. While the window holds the focus like that, Return, digits,
    /// arrows and letters go to `handle` (it returns whether it used the key). Esc and shortcuts
    /// with ⌘ or ⌃ keep going through the menus.
    func studyKeyFallback(_ handle: @escaping (KeyInput, _ isRepeat: Bool) -> Bool) -> some View {
        modifier(StudyKeyFallbackModifier(handle: handle))
    }
}

private struct StudyKeyFallbackModifier: ViewModifier {
    let handle: (KeyInput, Bool) -> Bool

    @State private var monitor = StudyKeyMonitor()

    func body(content: Content) -> some View {
        content
            .background { HostWindowReader { monitor.window = $0 } }
            .onAppear { monitor.start(handle) }
            .onDisappear { monitor.stop() }
    }
}

@MainActor
private final class StudyKeyMonitor {
    /// The study screen's own window: keys of other windows (Settings) are never taken.
    weak var window: NSWindow?
    private var token: Any?

    func start(_ handle: @escaping (KeyInput, Bool) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let used = MainActor.assumeIsolated { self?.route(event, to: handle) ?? false }
            return used ? nil : event
        }
    }

    /// Hands the key to `handle` while the window itself holds the keyboard focus.
    private func route(_ event: NSEvent, to handle: (KeyInput, Bool) -> Bool) -> Bool {
        guard let window = event.window, window === self.window, window.isKeyWindow,
            window.firstResponder === window, window.attachedSheet == nil, let input = Self.input(for: event)
        else { return false }
        return handle(input, event.isARepeat)
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// The study key for a key press, nil for Esc, shortcuts and keys the screens leave alone.
    private static func input(for event: NSEvent) -> KeyInput? {
        let flags = event.modifierFlags
        guard flags.isDisjoint(with: [.command, .control]) else { return nil }
        let key: KeyEquivalent
        switch event.keyCode {
        case 36, 76: key = .return
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 53: return nil
        case 51: key = .delete
        case 117: key = .deleteForward
        default:
            guard let character = event.charactersIgnoringModifiers?.first else { return nil }
            key = KeyEquivalent(character)
        }
        var modifiers: EventModifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return LearnKeyRouter.input(key: key, characters: event.characters ?? "", modifiers: modifiers)
    }
}

/// Reports the window the view is in (and nil when it leaves it).
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onWindow = onWindow
    }
}

private final class WindowReportingView: NSView {
    var onWindow: (NSWindow?) -> Void

    init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
    }
}
