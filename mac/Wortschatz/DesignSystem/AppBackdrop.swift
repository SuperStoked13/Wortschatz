import SwiftUI

/// The calm, accent-tinted mesh gradient behind content (spec §4.2), so Liquid Glass has
/// something to refract. Very low saturation in light mode, deeper in dark mode. It drifts
/// slowly (one cycle takes about half a minute), pauses while the window is inactive, and is
/// static under Reduce Motion. Under Reduce Transparency or increased contrast it becomes a
/// plain window background, since glass turns opaque there anyway.
///
/// ```swift
/// content.background { AppBackdrop() }        // or: .appBackdrop()
/// ```
struct AppBackdrop: View {
    /// How strongly the accent shows through (1 = default; study screens use `studyIntensity`).
    var intensity: Double = 1

    /// The study screens' backdrop, and the covers that stand in for it during their
    /// transitions (they must match exactly).
    static let studyIntensity = 1.1
    /// Off: a still image of the mesh, drawn once (the window's own background under everything,
    /// see `WortschatzApp`).
    var drifts = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isSnapshotRendering) private var isSnapshot

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Theme.solidBackdrop
            } else if reduceMotion || isSnapshot || !drifts {
                mesh(time: 0)
            } else {
                // Colours once per render, not on every tick of the drift.
                let colors = palette
                let background = base
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !appearsActive)) { context in
                    mesh(time: context.date.timeIntervalSinceReferenceDate, colors: colors, background: background)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func mesh(time: TimeInterval) -> some View {
        mesh(time: time, colors: palette, background: base)
    }

    private func mesh(time: TimeInterval, colors: [Color], background: Color) -> some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: Self.points(time: time),
            colors: colors,
            background: background,
            smoothsColors: true,
            colorSpace: .perceptual
        )
    }

    // MARK: Geometry

    /// 3×3 control points. Corners stay fixed, edge midpoints slide along their edge and the
    /// centre wanders, each on its own slow period so the motion never visibly loops.
    static func points(time t: TimeInterval) -> [SIMD2<Float>] {
        func wave(_ period: Double, _ phase: Double = 0) -> Float {
            Float(sin((t / period + phase) * 2 * .pi))
        }
        let a: Float = 0.07
        return [
            [0, 0], [0.5 + a * wave(29), 0], [1, 0],
            [0, 0.5 + a * wave(37, 0.3)], [0.5 + a * wave(31, 0.6), 0.5 + a * wave(41, 0.1)], [1, 0.5 + a * wave(33, 0.8)],
            [0, 1], [0.5 + a * wave(43, 0.45), 1], [1, 1],
        ]
    }

    // MARK: Palette

    private var isDark: Bool { colorScheme == .dark }

    private var base: Color {
        isDark ? Color(hex: 0x0D0E16) : Color(hex: 0xF6F6FB)
    }

    /// Accent, violet and teal tones, mixed towards the base so they stay quiet.
    private var palette: [Color] {
        let accent = Theme.accent
        let violet = Color(hex: 0x9D6BFF)
        let teal = Color(hex: 0x2BB3C0)
        let indigo = Color(hex: 0x3D5BFF)
        let rose = Color(hex: 0xE58BD0)
        // Fraction of the tone that survives (the rest is the base colour).
        let k = intensity
        func tone(_ c: Color, light: Double, dark: Double) -> Color {
            base.mix(with: c, by: min(1, (isDark ? dark : light) * k))
        }
        return [
            tone(accent, light: 0.20, dark: 0.34), tone(violet, light: 0.12, dark: 0.20), tone(teal, light: 0.16, dark: 0.22),
            tone(indigo, light: 0.10, dark: 0.18), tone(accent, light: 0.06, dark: 0.10), tone(teal, light: 0.11, dark: 0.16),
            tone(rose, light: 0.12, dark: 0.14), tone(accent, light: 0.15, dark: 0.26), tone(violet, light: 0.17, dark: 0.24),
        ]
    }
}

extension View {
    /// Places `AppBackdrop` behind the view (full window, under the safe areas).
    func appBackdrop(intensity: Double = 1) -> some View {
        background { AppBackdrop(intensity: intensity) }
    }
}

#Preview("AppBackdrop") {
    AppBackdrop()
        .frame(width: 800, height: 500)
}
