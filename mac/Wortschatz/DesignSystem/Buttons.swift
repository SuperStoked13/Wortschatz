import SwiftUI

/// The one primary action of a screen (spec §4.3): a `.glassProminent` button tinted with the
/// accent, with an inline keycap that shows which key triggers it (↩ by default).
///
/// Inside a glass surface (e.g. the "Weiterlernen" hero card) it automatically switches to
/// `.borderedProminent`, because glass must not sit on glass.
///
/// By default the button is also bound to that key (`.keyboardShortcut(.defaultAction)` for ↩).
/// A bound key never triggers it on auto-repeat or right after Return changed the screen
/// (`KeyActionGate`), so one press is one step. Screens whose Return handling runs through a
/// flow reducer pass `bindsShortcut: false` and keep the hint.
///
/// ```swift
/// PrimaryActionButton("Weiter") { model.send(.proceed) }
/// PrimaryActionButton("Lernen", systemImage: "graduationcap.fill") { … }
/// PrimaryActionButton("Speichern", key: .commandReturn) { … }
/// ```
struct PrimaryActionButton: View {
    private let title: Text
    var systemImage: String?
    var key: KeyGlyph?
    var bindsShortcut: Bool
    var tint: Color?
    var isFullWidth: Bool
    var controlSize: ControlSize
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        key: KeyGlyph? = .returnKey,
        bindsShortcut: Bool = true,
        tint: Color? = nil,
        isFullWidth: Bool = false,
        controlSize: ControlSize = .large,
        action: @escaping () -> Void
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.key = key
        self.bindsShortcut = bindsShortcut
        self.tint = tint
        self.isFullWidth = isFullWidth
        self.controlSize = controlSize
        self.action = action
    }

    /// Title from a runtime string ("Weiter zu Runde 3").
    init(
        verbatim title: String,
        systemImage: String? = nil,
        key: KeyGlyph? = .returnKey,
        bindsShortcut: Bool = true,
        tint: Color? = nil,
        isFullWidth: Bool = false,
        controlSize: ControlSize = .large,
        action: @escaping () -> Void
    ) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.key = key
        self.bindsShortcut = bindsShortcut
        self.tint = tint
        self.isFullWidth = isFullWidth
        self.controlSize = controlSize
        self.action = action
    }

    @Environment(\.isOnGlassSurface) private var isOnGlassSurface

    var body: some View {
        Button(action: gatedAction(action, bindsKey: bindsShortcut && key != nil)) {
            ActionButtonLabel(title: title, systemImage: systemImage, key: key, isFullWidth: isFullWidth)
                .fontWeight(.semibold)
        }
        .primaryStyle(onGlass: isOnGlassSurface)
        .tint(tint ?? Theme.accent)
        .controlSize(controlSize)
        .shortcut(bindsShortcut ? key?.keyboardShortcut : nil)
        .shortcutAccessibilityHint(bindsShortcut ? nil : key)
    }
}

/// A secondary action: `.glass` button with an optional keycap
/// ("Weiss ich nicht ⌥↩", "Ich hatte recht ⌘↩", "Beenden esc"). `.bordered` inside a glass surface.
/// A bound key is guarded like `PrimaryActionButton`'s (`KeyActionGate`).
struct SecondaryButton: View {
    private let title: Text
    var systemImage: String?
    var key: KeyGlyph?
    var bindsShortcut: Bool
    var role: ButtonRole?
    var tint: Color?
    var isFullWidth: Bool
    var controlSize: ControlSize
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        key: KeyGlyph? = nil,
        bindsShortcut: Bool = true,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        isFullWidth: Bool = false,
        controlSize: ControlSize = .large,
        action: @escaping () -> Void
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.key = key
        self.bindsShortcut = bindsShortcut
        self.role = role
        self.tint = tint
        self.isFullWidth = isFullWidth
        self.controlSize = controlSize
        self.action = action
    }

    init(
        verbatim title: String,
        systemImage: String? = nil,
        key: KeyGlyph? = nil,
        bindsShortcut: Bool = true,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        isFullWidth: Bool = false,
        controlSize: ControlSize = .large,
        action: @escaping () -> Void
    ) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.key = key
        self.bindsShortcut = bindsShortcut
        self.role = role
        self.tint = tint
        self.isFullWidth = isFullWidth
        self.controlSize = controlSize
        self.action = action
    }

    @Environment(\.isOnGlassSurface) private var isOnGlassSurface

    var body: some View {
        Button(role: role, action: gatedAction(action, bindsKey: bindsShortcut && key != nil)) {
            ActionButtonLabel(title: title, systemImage: systemImage, key: key, isFullWidth: isFullWidth)
                .fontWeight(.medium)
        }
        .secondaryStyle(onGlass: isOnGlassSurface)
        .tint(tint)
        .controlSize(controlSize)
        .shortcut(bindsShortcut ? key?.keyboardShortcut : nil)
        .shortcutAccessibilityHint(bindsShortcut ? nil : key)
    }
}

/// The action of a button bound to a key: a key press that is an auto-repeat or comes right
/// after Return changed the screen does nothing (`KeyActionGate`); clicks always act.
private func gatedAction(_ action: @escaping () -> Void, bindsKey: Bool) -> () -> Void {
    guard bindsKey else { return action }
    return {
        guard KeyActionGate.allowsCurrentEvent() else { return }
        action()
    }
}

/// Shared label: [symbol] Title [keycap]. Always as tall as a keycap, so buttons side by side
/// have the same height with or without keycap, whatever their symbol.
private struct ActionButtonLabel: View {
    let title: Text
    let systemImage: String?
    let key: KeyGlyph?
    let isFullWidth: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.medium)
            }
            title
                .lineLimit(1)
            if let key {
                Keycap(key)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, Spacing.xxs)
        .frame(maxWidth: isFullWidth ? .infinity : nil, minHeight: Keycap.Size.regular.height)
    }
}

private extension View {
    /// Capsules, the Liquid Glass shape (large glass buttons are rounded rectangles on the Mac).
    @ViewBuilder
    func primaryStyle(onGlass: Bool) -> some View {
        if onGlass {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    func secondaryStyle(onGlass: Bool) -> some View {
        if onGlass {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        }
    }
}

extension View {
    /// Tells VoiceOver which key triggers a control whose shortcut is handled elsewhere
    /// (e.g. by a flow reducer). Bound shortcuts are announced by the system already.
    @ViewBuilder
    func shortcutAccessibilityHint(_ key: KeyGlyph?) -> some View {
        if let key {
            accessibilityHint("Kurzbefehl: \(key.accessibilityName)")
        } else {
            self
        }
    }

    /// `.keyboardShortcut(_:)` when a shortcut is given, otherwise unchanged.
    @ViewBuilder
    func shortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
