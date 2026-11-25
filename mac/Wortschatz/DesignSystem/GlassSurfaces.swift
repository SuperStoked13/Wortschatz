import SwiftUI

// Liquid Glass rules (spec §4.2, HIG):
// - Glass lives on the control layer only: the study card, multiple-choice tiles, the floating
//   action bar, the progress capsule, stat tiles, banners/toasts and the "Weiterlernen" hero.
//   Lists, tables, text, backgrounds and content cards are never glass: set cards in a grid and
//   panels inside scrolling content or a sheet use `ContentPanel` / `contentSurface` instead.
// - No glass on glass: content inside a GlassCard/GlassPanel uses plain fills (chips, keycaps,
//   the special-character bar are designed for that). Put glass buttons next to a card, not in it.
// - Several glass shapes that sit close together go into one `GlassEffectContainer` so they
//   sample the backdrop once and can morph (`ChoiceGrid` does this). A container that lasts
//   keeps every glass shape it ever held: give buttons that change per step their own (see
//   `StudyActionBar`).
// - Inside a GlassEffectContainer, modifiers applied *outside* `.glassEffect`/`.glassSurface`
//   (opacity, overlay, scaleEffect, clipShape) are not rendered: put state visuals (rings,
//   dimming) on the content before the glass modifier. Offsets and transitions work.
// - Reduce Transparency: glass falls back to an opaque surface with a hairline border.
//   Increased contrast: glass gets a visible border.

private struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // Controls inside the surface switch to non-glass styles (no glass on glass).
        let content = content.environment(\.isOnGlassSurface, true)
        if reduceTransparency {
            content.background {
                ZStack {
                    shape.fill(Theme.solidSurface)
                    if let tint { shape.fill(tint) }
                    shape.strokeBorder(Theme.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
        } else {
            // The border goes *under* the glass modifier: inside a GlassEffectContainer anything
            // applied outside `.glassEffect` is not drawn.
            content
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Theme.hairline, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

extension EnvironmentValues {
    /// True inside a glass surface (`glassSurface`, `GlassCard`, `GlassPanel`, stat tiles,
    /// banners, choice tiles). `PrimaryActionButton` and `SecondaryButton` read it and use solid
    /// `.borderedProminent` / `.bordered` styles there instead of glass (no glass on glass).
    @Entry var isOnGlassSurface: Bool = false
}

extension View {
    /// Liquid Glass behind the view in `shape`, with the app's accessibility fallbacks
    /// (opaque under Reduce Transparency, bordered under increased contrast).
    ///
    /// - Parameters:
    ///   - tint: A colour that tints the glass; pass it with its opacity, e.g.
    ///     `Theme.success.fill.opacity(Theme.glassTintOpacity)`.
    ///   - interactive: Glass that reacts to pointer and press (for custom controls).
    func glassSurface<S: InsettableShape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        modifier(GlassSurfaceModifier(shape: shape, tint: tint, isInteractive: interactive))
    }

    /// Liquid Glass in a continuous rounded rectangle.
    func glassSurface(
        tint: Color? = nil,
        interactive: Bool = false,
        cornerRadius: CGFloat
    ) -> some View {
        glassSurface(tint: tint, interactive: interactive, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The primary glass surface for content on the control layer: the study card, the
/// "Weiterlernen" hero. Large continuous corners, generous padding.
///
/// ```swift
/// GlassCard {
///     Text("la maison").font(Typography.prompt)
/// }
/// ```
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Spacing.xxl
    var cornerRadius: CGFloat = Radii.card
    var tint: Color?
    var isInteractive = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassSurface(tint: tint, interactive: isInteractive, cornerRadius: cornerRadius)
    }
}

/// A compact glass surface for grouped information on the control layer, e.g. a floating
/// summary strip over the backdrop. Smaller radius and padding than `GlassCard`. Panels that
/// scroll with the content use `ContentPanel`.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = Spacing.m
    var cornerRadius: CGFloat = Radii.panel
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassSurface(tint: tint, cornerRadius: cornerRadius)
    }
}

// MARK: - Content layer

/// The grouped surface of the content layer: a quiet, slightly translucent fill with a hairline,
/// so cards and panels read as groups on the backdrop without competing with the glass controls
/// above them. Opaque under Reduce Transparency; the hairline gets stronger with increased
/// contrast (`Theme.hairline`). `isHighlighted` lifts it a little (hover over a clickable card).
private struct ContentSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isHighlighted: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                shape.fill(Theme.solidSurface.opacity(fillOpacity))
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(isHighlighted ? 0.10 : 0.04), radius: isHighlighted ? 10 : 3, y: isHighlighted ? 4 : 1)
        }
    }

    private var fillOpacity: Double {
        if reduceTransparency { return 1 }
        return isHighlighted ? 0.86 : 0.66
    }
}

extension View {
    /// The content layer's grouped surface behind the view (`ContentPanel`, set cards).
    func contentSurface(cornerRadius: CGFloat, isHighlighted: Bool = false) -> some View {
        modifier(
            ContentSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), isHighlighted: isHighlighted))
    }
}

/// A panel on the content layer: grouped information inside scrolling content or a sheet (the
/// set's mastery panel, the import detection panel). Never glass; glass buttons may sit on it.
///
/// ```swift
/// ContentPanel {
///     Text("52 Paare erkannt")
/// }
/// ```
struct ContentPanel<Content: View>: View {
    var padding: CGFloat = Spacing.m
    var cornerRadius: CGFloat = Radii.panel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .contentSurface(cornerRadius: cornerRadius)
    }
}
