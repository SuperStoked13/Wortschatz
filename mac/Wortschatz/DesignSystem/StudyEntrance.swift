import AppKit
import SwiftUI

/// How a study screen (Lernen, Schreiben) comes in, in steps that never overlap expensive work
/// with motion (measured: building the screen while the sidebar slides cost 30–70 ms per frame
/// and a 130–220 ms freeze):
/// 1. The page and the sidebar's content dissolve into the backdrop.
/// 2. The sidebar slides away while the detail column shows only the backdrop (cheap to lay
///    out on every frame).
/// 3. The screen is built once, invisibly.
/// 4. It fades in as one piece; inside the card the prompt glides in from the right and the
///    answer tiles from below, exactly as every later question does (`entranceShift`).
///
/// Leaving is the mirror image: the study screen dissolves, the sidebar slides back over the
/// bare backdrop, and the page (Übersicht, set page) is built invisibly and fades in
/// (`AppModel.leaveStudyLayout`); the first page after launch fades in the same way
/// (`AppModel.revealFirstPage`).
///
/// What keeps it crisp and smooth:
/// - Whole screens only fade. Scaled, their text and glass re-rendered on every frame and
///   snapped into place at the end (a visible tremble); moved, they drag AppKit views along
///   (scroll views, buttons, tables), and AppKit then re-checks what lies under the pointer on
///   every frame, which costs frames with a custom pointer.
/// - Only content SwiftUI draws itself glides, by a few points: the prompt and the answer
///   tiles, the way they move between questions.
/// - Screens fade on soft curves that land exactly (`Motion.soft`), long enough to read as
///   motion: quick, front-loaded fades looked like a stutter. No spring tail on whole screens,
///   no bounce on large surfaces. What glides uses the spring of the transitions between
///   questions, a touch calmer (`Motion.glide`).
/// - Pointer and keys work from the first frame of a reveal, so nothing changes when it ends.
///
/// Reduce Motion keeps short fades without movement.
enum StudyEntrance {
    static var sidebar: Animation {
        reducesMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.42)
    }

    /// The outgoing screen dissolves into the backdrop (into Lernen and out of it).
    static var dissolveDuration: Duration {
        reducesMotion ? .milliseconds(120) : .milliseconds(280)
    }
    static var dissolve: Animation {
        reducesMotion ? .easeOut(duration: 0.12) : Motion.soft(0.28)
    }

    /// Waits until the screen that was just inserted has been built and SwiftUI's follow-up
    /// passes are done. The first sleep usually ends while the (long) build frame still blocks
    /// the main thread; the second one starts only after it, so the reveal's first frames are
    /// free.
    static func waitUntilBuilt() async {
        try? await Task.sleep(for: .milliseconds(24))
        try? await Task.sleep(for: .milliseconds(110))
    }

    /// Waits until the change just made has been drawn, so the next step starts in a frame of
    /// its own (a long frame ends before the sleep does).
    static func waitForFrame() async {
        try? await Task.sleep(for: .milliseconds(24))
    }

    /// Opacity of content that is built but not shown yet. Not exactly zero: AppKit and SwiftUI
    /// skip drawing fully transparent content, which would move all the drawing into the
    /// first frame of the fade.
    static let hiddenOpacity = 0.001

    /// The fade-in of a study screen or a page.
    static var reveal: Animation {
        reducesMotion ? .easeOut(duration: 0.2) : Motion.soft(0.6)
    }

    /// Until a page's fade-in is over (the backdrop under it goes then).
    static let revealDuration: Duration = .milliseconds(650)

    /// How far the prompt glides in from the right, and the answer tiles from below, both when
    /// a screen comes in (`entranceShift`) and from one question to the next (`promptSwap`,
    /// `LearnStage`): the first question arrives like every later one.
    static let promptShift: CGFloat = 18
    static let tileShift: CGFloat = 12

    /// "Willkommen zurück" waits this long after the reveal starts, so it does not pop up over
    /// the empty backdrop.
    static let toastDelay: Duration = .milliseconds(450)

    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension EnvironmentValues {
    /// False while a screen is built invisibly before its entrance (`entranceReveal`); parts
    /// that glide in read it (`entranceShift`).
    @Entry var isEntranceRevealed: Bool = true
}

extension View {
    /// A screen before (`isRevealed == false`) and during its entrance: it fades in where it
    /// stands, as one piece. Pointer and keys work from the first frame of the fade.
    func entranceReveal(_ isRevealed: Bool) -> some View {
        modifier(EntranceRevealModifier(isRevealed: isRevealed))
    }

    /// Content drawn by SwiftUI itself (text, the answer tiles) that glides into place from
    /// (`x`, `y`) points away while its screen fades in. Outside an entrance it does nothing;
    /// Reduce Motion: no movement.
    func entranceShift(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(EntranceShiftModifier(x: x, y: y))
    }
}

private struct EntranceRevealModifier: ViewModifier {
    let isRevealed: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.isEntranceRevealed, isRevealed)
            .opacity(isRevealed ? 1 : StudyEntrance.hiddenOpacity)
            .allowsHitTesting(isRevealed)
    }
}

private struct EntranceShiftModifier: ViewModifier {
    let x: CGFloat
    let y: CGFloat

    @Environment(\.isEntranceRevealed) private var isRevealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isAway = !isRevealed && !reduceMotion
        content
            .offset(x: isAway ? x : 0, y: isAway ? y : 0)
            .animation(reduceMotion ? nil : Motion.glide, value: isRevealed)
    }
}
