import SwiftUI

/// A gentle horizontal shake (wrong answers). Plays each time `trigger` changes; does nothing
/// under Reduce Motion.
private struct ShakeEffect: ViewModifier {
    let trigger: Int
    var amplitude: Double = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let amplitude = amplitude
        content.keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : trigger) { view, offset in
            view.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-amplitude, duration: 0.07)
                CubicKeyframe(amplitude * 0.85, duration: 0.09)
                CubicKeyframe(-amplitude * 0.55, duration: 0.09)
                CubicKeyframe(amplitude * 0.3, duration: 0.08)
                CubicKeyframe(0, duration: 0.08)
            }
        }
    }
}

/// A short scale "pop" (a number that just went up, a finished badge). Plays each time `trigger`
/// changes; does nothing under Reduce Motion. Not for glass inside a GlassEffectContainer
/// (scale applied outside the glass is not rendered there).
private struct PopEffect: ViewModifier {
    let trigger: Int
    var scale: Double = 1.035

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let scale = scale
        content.keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : trigger) { view, value in
            view.scaleEffect(value)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(scale, duration: 0.14)
                SpringKeyframe(1, duration: 0.3)
            }
        }
    }
}

extension View {
    /// Shakes the view horizontally whenever `trigger` changes (Reduce Motion: no movement).
    func shake(trigger: Int, amplitude: Double = 8) -> some View {
        modifier(ShakeEffect(trigger: trigger, amplitude: amplitude))
    }

    /// Briefly scales the view up whenever `trigger` changes (Reduce Motion: no movement).
    func pop(trigger: Int, scale: Double = 1.035) -> some View {
        modifier(PopEffect(trigger: trigger, scale: scale))
    }
}

extension AnyTransition {
    /// Content that takes the place of other content in the same spot (the text in the answer
    /// box, the bar under it): the old content is gone quickly before the new one fades in, so
    /// two texts never sit on top of each other at half strength.
    static var answerSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    /// The prompt of the next question: the old one is gone quickly (sliding a little to the
    /// left), the new one glides in from the right a moment later, on the spring the card moves
    /// with. Overlapping, the two words blurred into each other.
    static func promptSwap(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .answerSwap
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: StudyEntrance.promptShift))
                    .animation(Motion.gentle.delay(0.06)),
                removal: .opacity.combined(with: .offset(x: -10)).animation(.easeOut(duration: 0.12)))
    }
}
