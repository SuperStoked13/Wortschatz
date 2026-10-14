import AppKit
import SwiftUI
import WortschatzCore

/// Colour tokens of the app (spec §4.2). Every colour adapts to light/dark mode and to
/// "Kontrast erhöhen" (increased contrast). The accent is the asset catalogue's
/// `AccentColor` (#5146E5 light, #7B74FF dark), so `.tint` and system controls agree.
///
/// Use the `fill` variants for bars, dots and tinted glass, the `text` variants for
/// coloured text and symbols on light surfaces (they meet 4.5:1 on the window
/// background), and `soft` for chip backgrounds.
nonisolated enum Theme {
    // MARK: Accent

    /// The app accent (indigo violet). Prefer `.tint(Theme.accent)` / `.foregroundStyle(.tint)`.
    static let accent = Color.accentColor

    /// Accent for text on plain backgrounds (slightly deeper than the fill in light mode).
    static let accentText = Color.dynamic(light: 0x463BD4, dark: 0x9B95FF, lightHC: 0x3A30B5, darkHC: 0xB9B5FF)

    /// Soft accent background for chips and selected rows.
    static let accentSoft = Color.dynamic(light: 0x5146E5, dark: 0x7B74FF, alpha: 0.12, darkAlpha: 0.22)

    // MARK: Card status (mastery)

    /// Colours of one status: `fill` for bars/dots/gauges, `text` for labels, `soft` for chip backgrounds.
    struct StatusPalette {
        let fill: Color
        let text: Color
        let soft: Color
    }

    static let mastered = StatusPalette(
        fill: .dynamic(light: 0x1FA855, dark: 0x32D74B, lightHC: 0x0B7A3B, darkHC: 0x5BE57A),
        text: .dynamic(light: 0x0B7A3B, dark: 0x4ADE80, lightHC: 0x075C2C, darkHC: 0x86EFAC),
        soft: .dynamic(light: 0x1FA855, dark: 0x32D74B, alpha: 0.14, darkAlpha: 0.20)
    )

    static let learning = StatusPalette(
        fill: .dynamic(light: 0xE8A317, dark: 0xFFC53D, lightHC: 0xB37A00, darkHC: 0xFFD66B),
        text: .dynamic(light: 0x8F5D00, dark: 0xFFD27A, lightHC: 0x6E4700, darkHC: 0xFFE2A8),
        soft: .dynamic(light: 0xE8A317, dark: 0xFFC53D, alpha: 0.16, darkAlpha: 0.20)
    )

    static let new = StatusPalette(
        fill: .dynamic(light: 0xC4C9D4, dark: 0x5C6272, lightHC: 0x8A91A0, darkHC: 0x8A91A0),
        text: .dynamic(light: 0x5F6679, dark: 0xAEB4C2, lightHC: 0x3E4454, darkHC: 0xD0D4DD),
        soft: .dynamic(light: 0x8A91A0, dark: 0x8A91A0, alpha: 0.14, darkAlpha: 0.22)
    )

    static func palette(for status: CardStatus) -> StatusPalette {
        switch status {
        case .new: new
        case .learning: learning
        case .mastered: mastered
        }
    }

    // MARK: Feedback

    /// Correct answers: green. Tint for glass is `success.fill.opacity(Theme.glassTintOpacity)`.
    static let success = StatusPalette(
        fill: .dynamic(light: 0x1FA855, dark: 0x30D158, lightHC: 0x0B7A3B, darkHC: 0x5BE57A),
        text: .dynamic(light: 0x0B7A3B, dark: 0x4ADE80, lightHC: 0x075C2C, darkHC: 0x86EFAC),
        soft: .dynamic(light: 0x1FA855, dark: 0x30D158, alpha: 0.14, darkAlpha: 0.20)
    )

    /// Wrong answers: red.
    static let failure = StatusPalette(
        fill: .dynamic(light: 0xE5484D, dark: 0xFF5A5F, lightHC: 0xB52A30, darkHC: 0xFF8A8F),
        text: .dynamic(light: 0xC4282E, dark: 0xFF8A8F, lightHC: 0x9A1D22, darkHC: 0xFFB3B6),
        soft: .dynamic(light: 0xE5484D, dark: 0xFF5A5F, alpha: 0.13, darkAlpha: 0.20)
    )

    /// Hints and warnings ("Knapp daneben", parser warnings): amber.
    static let warning = StatusPalette(
        fill: .dynamic(light: 0xE8A317, dark: 0xFFC53D, lightHC: 0xB37A00, darkHC: 0xFFD66B),
        text: .dynamic(light: 0x8F5D00, dark: 0xFFD27A, lightHC: 0x6E4700, darkHC: 0xFFE2A8),
        soft: .dynamic(light: 0xE8A317, dark: 0xFFC53D, alpha: 0.16, darkAlpha: 0.20)
    )

    /// Neutral information (tolerance notes such as "Artikel fehlte"): blue.
    static let info = StatusPalette(
        fill: .dynamic(light: 0x2F7DE1, dark: 0x5EA2FF, lightHC: 0x1A5DB5, darkHC: 0x8FC0FF),
        text: .dynamic(light: 0x1F63BF, dark: 0x8FC0FF, lightHC: 0x154C93, darkHC: 0xB5D5FF),
        soft: .dynamic(light: 0x2F7DE1, dark: 0x5EA2FF, alpha: 0.12, darkAlpha: 0.20)
    )

    /// Star (markiert).
    static let star = Color.dynamic(light: 0xF2AE0C, dark: 0xF5C344, lightHC: 0xB98200, darkHC: 0xFFD66B)

    /// Streak flame (Lernserie).
    static let flame = Color.dynamic(light: 0xF26B1D, dark: 0xFF8A3D, lightHC: 0xC2500E, darkHC: 0xFFA766)

    // MARK: Surfaces

    /// Opaque window background used instead of the mesh backdrop under Reduce Transparency /
    /// increased contrast (a touch darker than `solidSurface`, so surfaces still stand out).
    static let solidBackdrop = Color.dynamic(light: 0xEFEFF4, dark: 0x111217, lightHC: 0xE6E6EB, darkHC: 0x000000)

    /// Opaque surface used instead of glass when "Transparenz reduzieren" is on.
    static let solidSurface = Color.dynamic(light: 0xFFFFFF, dark: 0x23262F, lightHC: 0xFFFFFF, darkHC: 0x1B1D24)

    /// Hairline border for surfaces (stronger with increased contrast).
    static let hairline = Color.dynamic(light: 0x101828, dark: 0xFFFFFF, alpha: 0.10, darkAlpha: 0.12, hcAlpha: 0.45)

    /// Opacity of a status tint layered into glass (`Glass.tint`).
    static let glassTintOpacity = 0.30
}

// MARK: - Status presentation

nonisolated extension CardStatus {
    /// German label ("Neu", "Am Lernen", "Gemeistert"), from `Labels.STATUS`.
    var label: String { Labels.STATUS[self] ?? rawValue }

    var palette: Theme.StatusPalette { Theme.palette(for: self) }

    /// SF Symbol for the status (used next to the label, never alone).
    var systemImage: String {
        switch self {
        case .new: "circle.dashed"
        case .learning: "circle.lefthalf.filled"
        case .mastered: "checkmark.seal.fill"
        }
    }
}

// MARK: - Dynamic colours

extension Color {
    /// A colour that resolves per appearance (light, dark and their increased-contrast
    /// variants). Hex values are sRGB `0xRRGGBB`.
    ///
    /// The provider runs on whatever thread AppKit draws on, so it is built in a
    /// nonisolated context and captures only Sendable values.
    nonisolated static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightHC: UInt32? = nil,
        darkHC: UInt32? = nil,
        alpha: Double = 1,
        darkAlpha: Double? = nil,
        hcAlpha: Double? = nil
    ) -> Color {
        let darkAlpha = darkAlpha ?? alpha
        let ns = NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            switch match {
            case .darkAqua:
                return NSColor(hex: dark, alpha: darkAlpha)
            case .accessibilityHighContrastAqua:
                return NSColor(hex: lightHC ?? light, alpha: hcAlpha ?? alpha)
            case .accessibilityHighContrastDarkAqua:
                return NSColor(hex: darkHC ?? dark, alpha: hcAlpha ?? darkAlpha)
            default:
                return NSColor(hex: light, alpha: alpha)
            }
        }
        return Color(nsColor: ns)
    }

    /// A fixed sRGB colour from `0xRRGGBB`.
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
