import SwiftUI

/// App-wide toast messages ("Willkommen zurück", "Lernset gelöscht · Rückgängig"), a port of
/// the web app's `toast()`: auto-dismiss after 3.5 s (paused while the pointer is over it),
/// optional action, at most 4 visible, sticky toasts get a close button. Every toast is
/// announced to VoiceOver.
///
/// ```swift
/// @State private var toasts = ToastCenter()
/// ContentView().toastOverlay(toasts)                 // once, at the window root
///
/// @Environment(ToastCenter.self) private var toasts  // anywhere below
/// toasts.show("Lernset gelöscht", systemImage: "trash",
///             action: .init("Rückgängig") { model.undoDelete() })
/// ```
@Observable
final class ToastCenter {
    struct Toast: Identifiable {
        enum Tone: Sendable {
            case neutral, success, warning, danger
            /// The daily streak went on (flame colour).
            case streak
        }

        let id = UUID()
        var message: String
        var tone: Tone
        var systemImage: String
        var action: Action?
        /// nil: stays until closed.
        var duration: Duration?
    }

    struct Action {
        let label: String
        let perform: () -> Void

        init(_ label: String, perform: @escaping () -> Void) {
            self.label = label
            self.perform = perform
        }
    }

    /// Like `MAX_TOASTS` in the web app.
    static let maxVisible = 4
    static let defaultDuration: Duration = .seconds(3.5)

    private(set) var toasts: [Toast] = []

    /// Space at the bottom of the window that toasts keep clear: the height of a floating bar
    /// (the study screens' action bar) registered with `.reservesToastSpace()`.
    private(set) var bottomClearance: CGFloat = 0

    @ObservationIgnored private var clearances: [UUID: CGFloat] = [:]
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var deadlines: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var remaining: [UUID: Duration] = [:]

    init() {}

    /// Shows a toast and returns its id (for `dismiss`).
    @discardableResult
    func show(
        _ message: String,
        tone: Toast.Tone = .neutral,
        systemImage: String? = nil,
        action: Action? = nil,
        duration: Duration? = ToastCenter.defaultDuration
    ) -> Toast.ID {
        let toast = Toast(
            message: message,
            tone: tone,
            systemImage: systemImage ?? Self.defaultSymbol(for: tone),
            action: action,
            duration: duration
        )
        toasts.append(toast)
        while toasts.count > Self.maxVisible, let oldest = toasts.first {
            dismiss(oldest.id)
        }
        if let duration {
            schedule(toast.id, after: duration)
        }
        Announcer.announce(action.map { "\(message). \($0.label) möglich." } ?? message, important: tone == .danger)
        return toast.id
    }

    func dismiss(_ id: Toast.ID) {
        timers[id]?.cancel()
        timers[id] = nil
        deadlines[id] = nil
        remaining[id] = nil
        toasts.removeAll { $0.id == id }
    }

    func dismissAll() {
        for toast in toasts { dismiss(toast.id) }
    }

    /// Keeps toasts above a bar of `height` at the window bottom while `owner` is on screen.
    func reserveBottomSpace(_ height: CGFloat, for owner: UUID) {
        clearances[owner] = height
        updateClearance()
    }

    /// The bar of `owner` went away.
    func releaseBottomSpace(for owner: UUID) {
        clearances[owner] = nil
        updateClearance()
    }

    private func updateClearance() {
        let clearance = clearances.values.max() ?? 0
        if clearance != bottomClearance { bottomClearance = clearance }
    }

    /// Pointer entered the toast: stop its timer.
    func pause(_ id: Toast.ID) {
        guard let deadline = deadlines[id], let timer = timers[id] else { return }
        timer.cancel()
        timers[id] = nil
        // Like the web app: never less than 0.8 s left after a pause.
        remaining[id] = max(.milliseconds(800), deadline - ContinuousClock.now)
    }

    /// Pointer left the toast: continue its timer.
    func resume(_ id: Toast.ID) {
        guard timers[id] == nil, let left = remaining[id] else { return }
        schedule(id, after: left)
    }

    private func schedule(_ id: Toast.ID, after duration: Duration) {
        deadlines[id] = ContinuousClock.now + duration
        remaining[id] = duration
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    private static func defaultSymbol(for tone: Toast.Tone) -> String {
        switch tone {
        case .neutral: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        case .streak: "flame.fill"
        }
    }
}

/// Renders the toasts of a `ToastCenter` as glass capsules stacked at the bottom.
/// Usually added with `.toastOverlay(_:)`.
struct ToastOverlay: View {
    let center: ToastCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ForEach(center.toasts) { toast in
                ToastCapsule(toast: toast, center: center)
                    // A short rise that lands exactly (no scaling: text and glass stay crisp),
                    // and a quicker exit.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .offset(y: 18).combined(with: .opacity).animation(Motion.arrive(0.5)),
                                removal: .offset(y: 8).combined(with: .opacity).animation(Motion.depart(0.2)))
                    )
            }
        }
        .padding(.horizontal, Spacing.l)
        // Above a floating action bar (its own top padding is the gap), else the usual margin.
        .padding(.bottom, max(Spacing.xl, center.bottomClearance))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Motion.animation(Motion.spring, reduceMotion: reduceMotion), value: center.toasts.map(\.id))
        .animation(Motion.animation(Motion.snappy, reduceMotion: reduceMotion), value: center.bottomClearance)
    }
}

private struct ToastCapsule: View {
    let toast: ToastCenter.Toast
    let center: ToastCenter

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action = toast.action {
                Button(action.label) {
                    action.perform()
                    center.dismiss(toast.id)
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accentText)
            }
            if toast.duration == nil {
                Button {
                    center.dismiss(toast.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Schliessen")
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, toast.action == nil && toast.duration != nil ? Spacing.l : Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: 520)
        .fixedSize(horizontal: true, vertical: false)
        .glassSurface(in: Capsule(style: .continuous))
        .onHover { inside in
            if inside { center.pause(toast.id) } else { center.resume(toast.id) }
        }
        .accessibilityElement(children: .contain)
    }

    private var iconColor: Color {
        switch toast.tone {
        case .neutral: Theme.accent
        case .success: Theme.success.fill
        case .warning: Theme.warning.fill
        case .danger: Theme.failure.fill
        case .streak: Theme.flame
        }
    }
}

extension View {
    /// Shows the center's toasts over this view and puts the center into the environment
    /// (`@Environment(ToastCenter.self)`).
    func toastOverlay(_ center: ToastCenter) -> some View {
        overlay { ToastOverlay(center: center) }
            .environment(center)
    }

    /// For a bar floating at the bottom of the window (the study screens' action bar): while it
    /// is on screen, the toasts of the environment's `ToastCenter` stack above it instead of
    /// covering its buttons.
    func reservesToastSpace() -> some View {
        modifier(ToastSpaceReservation())
    }
}

private struct ToastSpaceReservation: ViewModifier {
    @Environment(ToastCenter.self) private var center: ToastCenter?
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                center?.reserveBottomSpace(height, for: owner)
            }
            .onDisappear { center?.releaseBottomSpace(for: owner) }
    }
}
