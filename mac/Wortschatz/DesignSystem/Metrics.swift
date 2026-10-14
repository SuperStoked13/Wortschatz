import SwiftUI

/// Spacing scale (4-pt grid, HIG margins: 20 pt window content inset, 8/12/16 between controls).
nonisolated enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
    static let huge: CGFloat = 56
}

/// Corner radii. Glass surfaces use continuous corners (`.rect(cornerRadius:)` is continuous
/// by default); nested shapes use `radius - padding` so curves stay concentric.
nonisolated enum Radii {
    /// Keycaps, special-character keys.
    static let keycap: CGFloat = 6
    /// Small controls, swatches.
    static let small: CGFloat = 10
    /// Multiple-choice tiles, stat tiles, banners.
    static let tile: CGFloat = 20
    /// Panels (detection bar, grouped info).
    static let panel: CGFloat = 22
    /// The study card and hero surfaces.
    static let card: CGFloat = 30
}

/// Layout widths and sizes.
nonisolated enum LayoutMetrics {
    /// Readable width of the study column (card, tiles, action bar).
    static let studyColumnWidth: CGFloat = 760
    /// Max width of regular content (overview, set detail).
    static let contentWidth: CGFloat = 1080
    /// Minimum height of a multiple-choice tile.
    static let choiceTileMinHeight: CGFloat = 84
    /// Minimum height of the study card.
    static let studyCardMinHeight: CGFloat = 260

    /// Space above the study card (Lernen, Schreiben): a little below the toolbar in tall
    /// windows, close to it in short ones.
    static func studyCardTopInset(height: CGFloat) -> CGFloat {
        max(Spacing.l, min(Spacing.huge * 2, (height - 560) / 2))
    }
}

/// Animation presets. Use `Motion.animation(_:reduceMotion:)` (or `.motionAnimation`) so
/// movement is dropped when "Bewegung reduzieren" is on.
nonisolated enum Motion {
    /// Default UI spring (state changes, selection).
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Snappy spring for small elements (badges, chips).
    static let snappy = Animation.snappy(duration: 0.25)
    /// Gentle spring for large surfaces (cards, banners).
    static let gentle = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// Cross-fade used instead of movement under Reduce Motion.
    static let fade = Animation.easeInOut(duration: 0.2)

    // Curves that end exactly on their target. A spring's tail creeps on by fractions of a
    // pixel, so whole screens (text and glass) would re-render until it settles and snap into
    // place at the end; these land.

    /// Whole screens fading in or out: a gentle start and a long, soft landing, so a fade
    /// reads as motion rather than a cut. Front-loaded curves made a screen half-appear within
    /// a few frames, which looked like a stutter.
    static func soft(_ duration: Double) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }

    /// Small things arriving (toasts): quick out of the gate, a long soft landing.
    static func arrive(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Leaving: gathers pace and is gone (ease-in cubic). Departures are shorter than arrivals.
    static func depart(_ duration: Double) -> Animation {
        .timingCurve(0.32, 0, 0.67, 0, duration: duration)
    }

    /// Content gliding into place while its screen fades in: the spring of the transitions
    /// between questions (`gentle`), a touch slower and calmer for a screen's first appearance.
    static let glide = Animation.spring(response: 0.72, dampingFraction: 0.9)

    /// `base`, or a plain cross-fade when Reduce Motion is on.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : base
    }
}

extension EnvironmentValues {
    /// True while the debug snapshot harness renders a view: time-based decorative animation
    /// (backdrop drift, confetti) draws one representative still frame instead of running.
    @Entry var isSnapshotRendering: Bool = false
}

private struct MotionAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that turns into a short cross-fade under Reduce Motion.
    func motionAnimation<V: Equatable>(_ animation: Animation = Motion.spring, value: V) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }
}
