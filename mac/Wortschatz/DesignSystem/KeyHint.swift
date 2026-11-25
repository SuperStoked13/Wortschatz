import SwiftUI

/// A key or key combination of the Enter-only key map (spec §4.3), shown as a keycap.
enum KeyGlyph: Hashable, Sendable {
    /// ↩ Return (the primary action of every screen).
    case returnKey
    /// ⌥↩ "Weiss ich nicht".
    case optionReturn
    /// ⌘↩ "Ich hatte recht" / save.
    case commandReturn
    /// esc: leave / cancel.
    case escape
    /// 0-9: choose a multiple-choice answer (1-4) or "Weiss ich nicht" (0).
    case digit(Int)
    /// ⇥ Tab.
    case tab
    /// ↑↓←→: move the multiple-choice highlight.
    case arrows
    /// ← and →: sort a flashcard ("Lerne ich noch", "Weiss ich").
    case leftArrow
    case rightArrow
    /// The space bar: turn a flashcard over.
    case space
    /// ⌫: take the last flashcard back.
    case delete
    /// ⌘ + key, e.g. `.command("E")` → ⌘E.
    case command(Character)
    /// ⇧⌘ + key, e.g. `.shiftCommand("L")` → ⇧⌘L.
    case shiftCommand(Character)

    /// What the keycap shows.
    var symbol: String {
        switch self {
        case .returnKey: "↩"
        case .optionReturn: "⌥↩"
        case .commandReturn: "⌘↩"
        case .escape: "esc"
        case let .digit(n): String(n)
        case .tab: "⇥"
        case .arrows: "↑↓←→"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .space: "␣"
        case .delete: "⌫"
        case let .command(c): "⌘\(c.uppercased())"
        case let .shiftCommand(c): "⇧⌘\(c.uppercased())"
        }
    }

    /// German name for VoiceOver ("Eingabetaste", "Wahltaste-Eingabetaste", …).
    var accessibilityName: String {
        switch self {
        case .returnKey: String(localized: "Eingabetaste")
        case .optionReturn: String(localized: "Wahltaste-Eingabetaste")
        case .commandReturn: String(localized: "Befehlstaste-Eingabetaste")
        case .escape: String(localized: "Escape-Taste")
        case let .digit(n): String(localized: "Taste \(n)")
        case .tab: String(localized: "Tabulatortaste")
        case .arrows: String(localized: "Pfeiltasten")
        case .leftArrow: String(localized: "Pfeil nach links")
        case .rightArrow: String(localized: "Pfeil nach rechts")
        case .space: String(localized: "Leertaste")
        case .delete: String(localized: "Rückschritttaste")
        case let .command(c): String(localized: "Befehlstaste-\(c.uppercased())")
        case let .shiftCommand(c): String(localized: "Umschalt-Befehlstaste-\(c.uppercased())")
        }
    }

    /// The matching SwiftUI shortcut. Return is `.defaultAction` (the window's default
    /// button), esc is `.cancelAction`; arrows have none.
    var keyboardShortcut: KeyboardShortcut? {
        switch self {
        case .returnKey: .defaultAction
        case .optionReturn: KeyboardShortcut(.return, modifiers: .option)
        case .commandReturn: KeyboardShortcut(.return, modifiers: .command)
        case .escape: .cancelAction
        case let .digit(n):
            (0...9).contains(n) ? KeyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: []) : nil
        case .tab: KeyboardShortcut(.tab, modifiers: [])
        case .arrows: nil
        case .leftArrow: KeyboardShortcut(.leftArrow, modifiers: [])
        case .rightArrow: KeyboardShortcut(.rightArrow, modifiers: [])
        case .space: KeyboardShortcut(.space, modifiers: [])
        case .delete: KeyboardShortcut(.delete, modifiers: [])
        case let .command(c): KeyboardShortcut(KeyEquivalent(Character(c.lowercased())), modifiers: .command)
        case let .shiftCommand(c): KeyboardShortcut(KeyEquivalent(Character(c.lowercased())), modifiers: [.command, .shift])
        }
    }
}

/// One keycap ("↩", "⌥↩", "1", "esc"). It draws with the *current* foreground style, so it
/// reads correctly both on plain backgrounds and inside a `.glassProminent` button (white
/// on accent). Decorative: hidden from VoiceOver; the button it sits in carries the label.
struct Keycap: View {
    let glyph: KeyGlyph
    var size: Size = .regular

    enum Size: Sendable {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: 16
            case .regular: 20
            case .large: 26
            }
        }

        var font: Font {
            switch self {
            case .small: .system(size: 10, weight: .semibold, design: .rounded)
            case .regular: Typography.keycap
            case .large: .system(size: 14, weight: .semibold, design: .rounded)
            }
        }
    }

    init(_ glyph: KeyGlyph, size: Size = .regular) {
        self.glyph = glyph
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.height * 0.3, style: .continuous)
        Text(glyph.symbol)
            .font(size.font)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, size.height * 0.3)
            .frame(minWidth: size.height, minHeight: size.height)
            .background {
                shape.fill(.quaternary)
                    .overlay(alignment: .bottom) {
                        // Subtle bottom edge, like a physical key.
                        shape.strokeBorder(.tertiary, lineWidth: 0.5)
                    }
            }
            .accessibilityHidden(true)
    }
}

/// A keycap followed by what it does, for hint lines below controls:
/// `KeyHint(.optionReturn, "Weiss ich nicht")` → [⌥↩] Weiss ich nicht.
struct KeyHint: View {
    let glyph: KeyGlyph
    let label: String?

    init(_ glyph: KeyGlyph, _ label: String? = nil) {
        self.glyph = glyph
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            Keycap(glyph)
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "\($0): \(glyph.accessibilityName)" } ?? glyph.accessibilityName)
    }
}

/// A row of hints separated by generous spacing: `KeyHintRow([(.returnKey, "Weiter"), (.escape, "Beenden")])`.
struct KeyHintRow: View {
    let hints: [(KeyGlyph, String)]

    init(_ hints: [(KeyGlyph, String)]) {
        self.hints = hints
    }

    var body: some View {
        HStack(spacing: Spacing.l) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                KeyHint(hint.0, hint.1)
            }
        }
    }
}
