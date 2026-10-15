import SwiftUI
import WortschatzCore

// The flashcard itself (Karteikarten): a large card that turns over in 3D, with two card edges
// peeking out below it as the stack.
//
// - Turning over: the card lifts toward you and turns around a nearly horizontal axis, always
//   the same way round (like a card you keep turning over), once, and stops flat (no swing past
//   flat). A streak of light rises across it while it turns and fades out on the card just as it
//   lands; the crystal then dissolves into the real glass. Meanwhile the cards of the stack
//   behind it come into view at their full size, and are back under it once it has landed.
// - Sorting: the verdict lands on the card (it floods green or amber from the side it is going
//   to, a seal settles in behind the text and sends out a ring), then the card glides off to
//   that side, leaning a little and fading, while the next card rises from the stack.
// - "Zurück": a card still in flight glides back along its own path; a card that is gone slides
//   back in from its side, and the current card sinks back under the stack.
// - Swiping (`FlashcardSwipe`): the card follows two fingers on the trackpad or the mouse
//   sideways, on the same glide as a sorted card (leaning, a little smaller, but not fading), and
//   takes on the colour of the side it is heading for. Past the threshold the verdict's seal
//   settles on it; let go there (or flung) it flies off from where it is, else it springs back.
//
// Glass and crystal: Liquid Glass cannot be turned. Under a rotation or a perspective the system
// draws it as a larger, misplaced slab beside the content (only moving and scaling keep it in
// place; verified with the `flashcard-*` snapshots). So the resting card is real Liquid Glass,
// flat, and while the card turns or leaves, a crystal stand-in drawn by SwiftUI takes over: it
// matches the resting glass, so the switch does not show.
//
// Smoothness: every frame of a turn or a glide only recomputes small modifiers (`FaceTurn`,
// `GlassFade`, `GlideEffect`); the card's content is built once, not on every frame. Curves land
// exactly (no spring tail on the big surface, no overshoot on the turn). A sorted card leaves as
// the same view it was on screen (glass that appears anew flashes while it materializes); only
// the incoming card is new, and it fades in from nothing.
// Reduce Motion: the sides cross-fade, cards fade in and out, nothing turns or glides.

/// SF Symbols of the flashcards screen.
nonisolated enum FlashcardsSymbols {
    /// The mode (buttons, menus, the set page's running line).
    static let mode = "rectangle.on.rectangle.angled"
    static let know = "checkmark"
    static let stillLearning = "arrow.circlepath"
    static let undo = "arrow.uturn.backward"
}

/// Timings and distances of the card.
nonisolated enum FlashcardMotion {
    // MARK: Turning over

    /// Turning over: a firm start, through the edge at speed, then it slows down and stops
    /// exactly flat. Never past flat and back: the curve does not overshoot.
    static let flip = Animation.timingCurve(0.36, 0, 0.2, 1, duration: 0.62)
    /// How much the card grows toward you at the middle of a turn, and how far it rises.
    static let flipLift = 0.045
    static let flipRise: CGFloat = 10
    /// The turning axis leans a little off the horizontal, as if the card were turned by hand.
    static let flipAxisLean: CGFloat = 0.12
    static let flipPerspective: CGFloat = 0.45
    /// Once the card lies flat, its crystal dissolves into the real glass: slowly enough that the
    /// glass never pops in as the card comes to rest.
    static let glassReturn = Animation.easeInOut(duration: 0.32)

    // MARK: Sorting

    /// The verdict's colour coming onto the card.
    static let tint = Animation.easeOut(duration: 0.16)
    /// The seal settling in behind the text, and the ring it sends out.
    static let seal = Motion.arrive(0.32)
    static let ripple = Animation.easeOut(duration: 0.6)
    /// The glide: a beat for the verdict, then the card gathers pace evenly and is gone. No
    /// wind-up, no turn in depth: one calm movement.
    static let glide = Animation.timingCurve(0.42, 0, 0.72, 0.72, duration: 0.5).delay(0.06)
    /// A swiped card let go past the threshold: it is already moving, so it flies off at once
    /// and slows down as it fades.
    static let fling = Animation.timingCurve(0.2, 0.55, 0.35, 1, duration: 0.42)
    /// A swiped card let go before the threshold: back to the middle, landing softly and exactly.
    static let snapBack = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.36)
    /// How far a sorted card glides sideways and drops, how much it leans toward its side and how
    /// much smaller it gets.
    static let glideDistance: CGFloat = 280
    static let glideDrop: CGFloat = 24
    static let glideLean = 6.0
    static let glideShrink = 0.06
    /// The current card going back under the stack ("Zurück").
    static let sink = Motion.depart(0.3)
    /// How far to the side a card that was gone comes back from ("Zurück").
    static let returnDistance: CGFloat = 140

    // MARK: Arriving

    /// The next card rising from the stack, a card coming back: quick out of the gate, a long
    /// soft landing.
    static let arriveDuration = 0.48
    static let arrive = Motion.arrive(arriveDuration)
    /// How far the next card rises from the stack, and how small it starts.
    static let riseDistance: CGFloat = 16
    static let riseScale = 0.965

    // MARK: The turn, frame by frame

    /// Where in its turn the card is at `angle` (180° per half-turn): which side is up, its tilt
    /// (a side going away tilts from 0° to 90°, the next one comes up from -90° to 0°), how far
    /// it is lifted (0 flat … 1 edge-on), and the streak of light (strength, and its position in
    /// units of the card's height). The streak stays on the card: it rises from its lower part to
    /// its upper third and has faded out exactly when the card lies flat, so it is never cut off
    /// by an edge while it is still bright.
    static func turn(angle: Double) -> (showsBack: Bool, tilt: Double, lift: Double, sheen: Double, sheenPosition: Double) {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        let turned = remainder < 0 ? remainder + 360 : remainder
        let showsBack = turned > 90 && turned <= 270
        let tilt = showsBack ? turned - 180 : (turned > 270 ? turned - 360 : turned)
        let lift = sin(min(1, abs(tilt) / 90) * .pi / 2)
        // Through this half-turn: 0 at its start, 0.5 edge-on, 1 at its end.
        let through = tilt >= 0 ? tilt / 180 : 1 + tilt / 180
        return (showsBack, tilt, lift, abs(sin(tilt * .pi / 180)), 0.9 - 0.8 * through)
    }

    /// How much of the card is the crystal stand-in rather than the real glass: all of it on a
    /// card that is leaving or still gliding (`glide`, its progress), on a turning card as soon as
    /// it tilts more than a few tenths of a degree (`tilt`), and as much as `hold` says (1 from
    /// the start of a turn until the card lies flat, then dissolving into the glass).
    static func crystalShare(tilt: Double, glide: Double, isLeaving: Bool, hold: Double = 0) -> Double {
        if isLeaving { return 1 }
        let turning = (abs(tilt) - 0.2) / 2.8
        let gliding = (abs(glide) - 0.002) / 0.013
        let moving = min(1, max(0, max(turning, gliding)))
        return max(moving * moving * (3 - 2 * moving), min(1, max(0, hold)))
    }

    /// How much of the stack behind the card shows while it turns at `angle`: none at rest, all
    /// of it from about 40° on. Nearly nothing by the time the card is back on its glass, which a
    /// whole card behind it would cloud. A swiped card uncovers it too (`swipe`: 0 … 1 at the
    /// threshold). `turning`: 1 while the card that turns is the one on the deck; it falls to 0
    /// when it is sorted mid-turn, so the stack does not stay uncovered behind the next card.
    static func stackReveal(angle: Double, swipe: Double = 0, turning: Double = 1) -> Double {
        let reveal = min(1, max(turn(angle: angle).lift * 1.6 * min(1, max(0, turning)), swipe * 1.2))
        return reveal * reveal * (3 - 2 * reveal)
    }
}

/// Sizes of the card and the stack under it.
nonisolated enum FlashcardMetrics {
    /// How far each card edge of the stack peeks out below the one above it.
    static let peekDrop: CGFloat = 9
    /// How much narrower each card edge is, on either side, than the one above it.
    static let peekInset: CGFloat = 18
    /// Room below the card for the peeking edges.
    static let stackDepth: CGFloat = peekDrop * 2
    /// The card's height for the room the stage has: an index-card shape, between 240 and 440 pt.
    static func cardHeight(width: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let shaped = width * 0.58
        return max(240, min(440, min(shaped, availableHeight)))
    }

    /// The card edge of the stack `level` steps below the card (0 is the next card): how far
    /// below the card it hangs, how much narrower it is on each side, and how strongly it shows.
    static func edge(level: Int) -> (drop: CGFloat, inset: CGFloat, opacity: Double) {
        let depth = CGFloat(level + 1)
        return (peekDrop * depth, peekInset * depth, level == 0 ? 1 : 0.62)
    }
}

extension FlashcardVerdict {
    var color: Theme.StatusPalette {
        self == .know ? Theme.success : Theme.learning
    }

    var symbol: String {
        self == .know ? FlashcardsSymbols.know : FlashcardsSymbols.stillLearning
    }

    var title: String {
        self == .know ? "Weiss ich" : "Lerne ich noch"
    }

    /// Sideways direction of the sorted card: "Weiss ich" to the right, "Lerne ich noch" to the left.
    var direction: CGFloat {
        self == .know ? 1 : -1
    }
}


// MARK: - The card

/// A card of the deck: both sides in one card that turns over when `isFlipped` changes. The
/// current card turns over on a click (or the space bar, Return, ↑↓) and has the tools 🔊 ★ ✎
/// in its corner. A card that is `leaving` is the same view on its way out: sorted, the verdict
/// lands on it and it glides off to its side; going back under the stack ("Zurück"), it sinks
/// and fades.
struct FlashcardView: View {
    let card: Card
    let front: FlashcardSide
    let back: FlashcardSide
    let isFlipped: Bool
    let height: CGFloat
    var leaving: FlashcardDeparture.Kind?
    /// The current card's swipe (nil for a card that is leaving).
    var swipe: FlashcardSwipe?
    /// A leaving card was let go after a swipe: it flies off from where it was (`releaseOffset`).
    var flung = false
    var releaseOffset: CGFloat = 0
    var isSpeaking = false
    var onFlip: () -> Void = {}
    var onSpeak: () -> Void = {}
    var onStar: () -> Void = {}
    var onEdit: () -> Void = {}
    /// The mouse drags the card sideways (translation from where it started, and the time).
    var onDrag: (FlashcardDrag) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Half-turns so far (odd: the back is up). It only grows, so the card always turns the same
    /// way round.
    @State private var turns: Int
    /// The crystal staying on after a turn (1) until the card lies flat, then dissolving (0).
    @State private var crystalHold = 0.0
    /// Counts the turns, so that only the last one hands the card back to its glass.
    @State private var turnID = 0
    /// The side the card was last sorted to: called back mid-flight, it returns along its path.
    @State private var lastDirection: CGFloat = 1

    init(
        card: Card,
        front: FlashcardSide,
        back: FlashcardSide,
        isFlipped: Bool,
        height: CGFloat,
        leaving: FlashcardDeparture.Kind? = nil,
        swipe: FlashcardSwipe? = nil,
        flung: Bool = false,
        releaseOffset: CGFloat = 0,
        isSpeaking: Bool = false,
        onFlip: @escaping () -> Void = {},
        onSpeak: @escaping () -> Void = {},
        onStar: @escaping () -> Void = {},
        onEdit: @escaping () -> Void = {},
        onDrag: @escaping (FlashcardDrag) -> Void = { _ in }
    ) {
        self.card = card
        self.front = front
        self.back = back
        self.isFlipped = isFlipped
        self.height = height
        self.leaving = leaving
        self.swipe = swipe
        self.flung = flung
        self.releaseOffset = releaseOffset
        self.isSpeaking = isSpeaking
        self.onFlip = onFlip
        self.onSpeak = onSpeak
        self.onStar = onStar
        self.onEdit = onEdit
        self.onDrag = onDrag
        _turns = State(initialValue: isFlipped ? 1 : 0)
    }

    private var isCurrent: Bool { leaving == nil }

    private var verdict: FlashcardVerdict? {
        if case let .sorted(verdict) = leaving { verdict } else { nil }
    }

    /// This card is the one being swiped.
    private var isSwiped: Bool {
        isCurrent && swipe?.cardID == card.id
    }

    /// Where the swipe has taken the card (+ to the right).
    private var swipeOffset: CGFloat {
        isSwiped ? swipe?.offset ?? 0 : 0
    }

    /// The verdict on the card: sorted, or about to be if let go now.
    private var shownVerdict: FlashcardVerdict? {
        verdict ?? (isSwiped ? swipe?.armed : nil)
    }

    /// How far the card has glided off: all the way once sorted, else as far as it is swiped.
    private var glide: Double {
        verdict == nil ? Double(abs(swipeOffset) / FlashcardMotion.glideDistance) : 1
    }

    private var glideDirection: CGFloat {
        if let verdict { return verdict.direction }
        if swipeOffset != 0 { return swipeOffset < 0 ? -1 : 1 }
        return lastDirection
    }

    var body: some View {
        surface
            .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .onTapGesture { if isCurrent { onFlip() } }
            // Before the tap: a click still turns the card over, a drag moves it.
            .highPriorityGesture(dragGesture, including: isCurrent && swipe != nil ? .all : .subviews)
            .onChange(of: isFlipped) { _, showsBack in turnOver(showingBack: showsBack) }
            .onChange(of: verdict) { _, verdict in
                if let verdict { lastDirection = verdict.direction }
            }
            .onChange(of: leaving) { old, new in
                if old != nil, new == nil { holdCrystalWhileArriving() }
            }
            .modifier(placement)
            .animation(departure, value: leaving)
            .allowsHitTesting(isCurrent)
            .accessibilityHidden(!isCurrent)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: isFlipped ? "Vorderseite zeigen" : "Umdrehen", onFlip)
            .accessibilityIdentifier(isCurrent ? "flashcard" : "flashcard-leaving")
    }

    /// Both sides on the glass or crystal, turning and gliding.
    @ViewBuilder
    private var surface: some View {
        if reduceMotion {
            // Nothing turns: the glass stays, the side that is up shows.
            ZStack {
                face(front, isUp: !isFlipped)
                    .opacity(isFlipped ? 0 : 1)
                face(back, isUp: isFlipped)
                    .opacity(isFlipped ? 1 : 0)
            }
            .background { FlashcardGlass(isBack: isFlipped) }
            .animation(.easeInOut(duration: 0.2), value: isFlipped)
            // Moving keeps the glass in place: the card only follows the swipe sideways.
            .offset(x: isCurrent ? swipeOffset : releaseOffset)
        } else {
            CardSurface(
                angle: Double(turns) * 180, glide: glide, direction: glideDirection, isLeaving: !isCurrent,
                isBackUp: isFlipped, hold: max(crystalHold, isSwiped && swipe?.isEngaged == true ? 1 : 0),
                fades: isSwiped && swipe?.isEngaged == true ? 0 : 1, wash: isSwiped ? swipe?.lean ?? 0 : 0
            ) {
                face(front, isUp: !isFlipped)
            } back: {
                face(back, isUp: isFlipped)
            }
        }
    }

    /// Fading (Reduce Motion) and sinking back under the stack; the glide is `GlideEffect`.
    private var placement: CardPlacement {
        switch leaving {
        case nil:
            CardPlacement()
        case .sorted:
            CardPlacement(opacity: reduceMotion ? 0 : 1)
        case .backToStack:
            reduceMotion
                ? CardPlacement(opacity: 0)
                : CardPlacement(y: FlashcardMotion.riseDistance, scale: FlashcardMotion.riseScale, opacity: 0)
        }
    }

    /// Sorted: a beat, then gone. Sinking: gathers pace. Called back mid-flight: lands softly.
    private var departure: Animation {
        switch leaving {
        case nil: reduceMotion ? Motion.fade : FlashcardMotion.arrive
        case .sorted: reduceMotion ? Motion.fade : flung ? FlashcardMotion.fling : FlashcardMotion.glide
        case .backToStack: reduceMotion ? Motion.fade : FlashcardMotion.sink
        }
    }

    /// The mouse drags the current card sideways (`onDrag`).
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                onDrag(.changed(value.translation.width, at: ProcessInfo.processInfo.systemUptime))
            }
            .onEnded { _ in
                onDrag(.ended(at: ProcessInfo.processInfo.systemUptime))
            }
    }

    /// One side. Only the side that is up takes clicks, keys (⌘E) and VoiceOver.
    private func face(_ side: FlashcardSide, isUp: Bool) -> some View {
        FlashcardFace(side: side, height: height, verdict: shownVerdict) {
            FlashcardTools(
                starred: card.starred, isSpeaking: isSpeaking, isInteractive: isCurrent && isUp, onSpeak: onSpeak,
                onStar: onStar, onEdit: onEdit)
        }
        .allowsHitTesting(isUp)
        .accessibilityHidden(!isUp)
    }

    /// Called back (from its flight or from under the stack): the crystal stays on until the card
    /// is in place, then dissolves into the glass, as after a turn (the glass would otherwise come
    /// back at once, on a card still moving or half faded).
    private func holdCrystalWhileArriving() {
        guard !reduceMotion else { return }
        // A turn still running must not hand the card back to its glass early.
        turnID += 1
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { crystalHold = 1 }
        withAnimation(FlashcardMotion.glassReturn.delay(FlashcardMotion.arriveDuration)) { crystalHold = 0 }
    }

    /// One more half-turn, so that the side `showingBack` asks for is up. The crystal stays on
    /// until the card lies flat and only then dissolves into the glass.
    private func turnOver(showingBack: Bool) {
        var next = turns + 1
        if next.isMultiple(of: 2) == showingBack { next += 1 }
        turnID += 1
        let id = turnID
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { crystalHold = 1 }
        withAnimation(FlashcardMotion.flip) {
            turns = next
        } completion: {
            guard id == turnID else { return }
            withAnimation(FlashcardMotion.glassReturn) { crystalHold = 0 }
        }
    }
}

/// Both sides of a card on its glass, turned to `angle` and glided `glide` (0 on the deck … 1
/// gone) toward `direction` (1 right). The sides are built once; each frame of a turn or a glide
/// only recomputes the small modifiers. The real glass sits behind everything, outside every
/// transform, and fades while the crystal under each side takes over (a leaving card: at once).
private struct CardSurface<Front: View, Back: View>: View {
    let angle: Double
    let glide: Double
    let direction: CGFloat
    let isLeaving: Bool
    /// The side that is up (the glass's tint; the glass only shows at rest).
    let isBackUp: Bool
    /// The crystal held on after a turn (`FlashcardMotion.crystalShare`).
    var hold: Double = 0
    /// How much the glide fades the card: 1 for a sorted card, 0 while it follows a swipe.
    var fades: Double = 1
    /// The swipe's colour on the card, -1 (Lerne ich noch) … 1 (Weiss ich).
    var wash: Double = 0
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var body: some View {
        ZStack {
            front
                .modifier(FaceTurn(angle: angle, glide: glide, hold: hold, wash: wash, isBack: false, isLeaving: isLeaving))
            back
                .modifier(FaceTurn(angle: angle, glide: glide, hold: hold, wash: wash, isBack: true, isLeaving: isLeaving))
        }
        .modifier(GlideEffect(offset: Double(direction) * glide, fades: fades))
        .background {
            FlashcardGlass(isBack: isBackUp)
                .modifier(GlassFade(angle: angle, glide: glide, hold: hold, isLeaving: isLeaving))
        }
    }
}

/// One side of the card at `angle`: shown while it is the side up, tilted with the turn, lifted
/// toward you halfway, with the streak of light; on its crystal while the card moves.
private struct FaceTurn: ViewModifier, Animatable {
    var angle: Double
    var glide: Double
    var hold: Double
    var wash: Double
    let isBack: Bool
    let isLeaving: Bool

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, AnimatablePair<Double, Double>>> {
        get { AnimatablePair(angle, AnimatablePair(glide, AnimatablePair(hold, wash))) }
        set {
            angle = newValue.first
            glide = newValue.second.first
            hold = newValue.second.second.first
            wash = newValue.second.second.second
        }
    }

    func body(content: Content) -> some View {
        let turn = FlashcardMotion.turn(angle: angle)
        let crystal = FlashcardMotion.crystalShare(tilt: turn.tilt, glide: glide, isLeaving: isLeaving, hold: hold)
        content
            .background {
                ZStack {
                    FlashcardCrystal(isBack: isBack)
                        .opacity(crystal)
                    if abs(wash) > 0.004 {
                        SwipeWash(lean: wash)
                    }
                }
            }
            .overlay {
                if turn.sheen > 0.001 {
                    FlashcardSheen(position: turn.sheenPosition)
                        .opacity(turn.sheen)
                        .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                }
            }
            .rotation3DEffect(
                .degrees(turn.tilt), axis: (x: 1, y: FlashcardMotion.flipAxisLean, z: 0), anchor: .center,
                perspective: FlashcardMotion.flipPerspective)
            .scaleEffect(CGFloat(1 + FlashcardMotion.flipLift * turn.lift))
            .offset(y: -FlashcardMotion.flipRise * CGFloat(turn.lift))
            .opacity(turn.showsBack == isBack ? 1 : 0)
    }
}

/// The real glass at `angle` and `glide`: there while the card rests, gone while it turns or
/// leaves (the crystal stands in).
private struct GlassFade: ViewModifier, Animatable {
    var angle: Double
    var glide: Double
    var hold: Double
    let isLeaving: Bool

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(angle, AnimatablePair(glide, hold)) }
        set {
            angle = newValue.first
            glide = newValue.second.first
            hold = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let tilt = FlashcardMotion.turn(angle: angle).tilt
        content.opacity(1 - FlashcardMotion.crystalShare(tilt: tilt, glide: glide, isLeaving: isLeaving, hold: hold))
    }
}

/// A sorted card on its way to its side (`offset` 0 on the deck … 1 gone to the right, -1 to the
/// left): it glides off, dropping a little, leaning toward its side and getting smaller, and fades
/// from about a third of the way on (`fades`: 0 while a swipe holds it, so it never fades under
/// the fingers; it grows to 1 as the card flies off). The offset is signed so that a card swiped
/// a little to one side and then sorted to the other glides across the middle instead of jumping.
private struct GlideEffect: ViewModifier, Animatable {
    var offset: Double
    var fades: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(offset, fades) }
        set {
            offset = newValue.first
            fades = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let p = abs(offset)
        let fade = min(1, max(0, (p - 0.3) / 0.65))
        content
            .rotationEffect(.degrees(FlashcardMotion.glideLean * offset))
            .scaleEffect(CGFloat(1 - FlashcardMotion.glideShrink * p))
            .offset(
                x: FlashcardMotion.glideDistance * CGFloat(offset),
                y: FlashcardMotion.glideDrop * CGFloat(p * p))
            .opacity(1 - min(1, max(0, fades)) * fade * fade * (3 - 2 * fade))
    }
}

/// The colour of the side a swiped card is heading for, growing with the swipe (`lean`: -1 Lerne
/// ich noch … 1 Weiss ich), strongest on that side; under the text.
private struct SwipeWash: View {
    let lean: Double

    var body: some View {
        let verdict: FlashcardVerdict = lean >= 0 ? .know : .stillLearning
        let strength = min(1, abs(lean))
        let toward: UnitPoint = verdict == .know ? .trailing : .leading
        let away: UnitPoint = verdict == .know ? .leading : .trailing
        RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [verdict.color.fill.opacity(0.34 * strength), verdict.color.fill.opacity(0.08 * strength)],
                    startPoint: toward, endPoint: away)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Where a card is while it rises from the stack, goes back under it or slides back in from its
/// side: moved, a little smaller (from its bottom edge) and faded. Only moving and scaling, so
/// the glass stays in place.
private struct CardPlacement: ViewModifier {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: Double = 1
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(CGFloat(scale), anchor: .bottom)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

// MARK: - Glass and crystal

/// The card's Liquid Glass, empty (the content is drawn over it). It never turns: only fading,
/// moving and scaling keep glass where it belongs. The back has a breath of the accent.
private struct FlashcardGlass: View {
    let isBack: Bool

    var body: some View {
        Color.clear
            .glassSurface(
                tint: isBack ? Theme.accent.opacity(0.10) : nil,
                in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The stand-in for the glass while the card turns or leaves: a translucent pane tinted like the
/// resting glass (measured on the study backdrop), a little brighter in its middle, with a light
/// rim that is strongest along the top and a soft shadow outside the pane. Drawn by SwiftUI, so
/// it turns and glides with the card. Opaque under Reduce Transparency and bordered under
/// increased contrast, like the glass.
private struct FlashcardCrystal: View {
    let isBack: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private static let pane = Color.dynamic(light: 0xF4F6FF, dark: 0xC8CDFF, alpha: 0.72, darkAlpha: 0.145)
    private static let core = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 0.24, darkAlpha: 0.03)
    private static let rimTop = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 1, darkAlpha: 0.3)
    private static let rimBottom = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 0.65, darkAlpha: 0.12)
    private static let shadow = Color.dynamic(light: 0x000000, dark: 0x000000, alpha: 0.14, darkAlpha: 0.2)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
        ZStack {
            // Outside the pane only: inside, a shadow would cloud the translucent crystal.
            shape.fill(Self.shadow)
                .blur(radius: 12)
                .offset(y: 3)
                .mask {
                    Rectangle()
                        .padding(-48)
                        .overlay { shape.blendMode(.destinationOut) }
                        .compositingGroup()
                }
            if reduceTransparency {
                shape.fill(Theme.solidSurface)
            } else {
                shape.fill(Self.pane)
                shape.fill(
                    RadialGradient(
                        colors: [Self.core, Self.core.opacity(0)], center: .center, startRadius: 0, endRadius: 420))
            }
            if isBack {
                shape.fill(Theme.accent.opacity(0.10))
            }
            shape.strokeBorder(
                LinearGradient(colors: [Self.rimTop, Self.rimBottom], startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            if reduceTransparency || contrast == .increased {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The streak of light that sweeps across the card while it turns over: a bright core in a soft
/// band. Gentler in light mode, where white light on the bright card would only wash out the text.
private struct FlashcardSheen: View {
    /// Where the band's middle is, in units of the card's height (0 top, 1 bottom).
    let position: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let core = colorScheme == .dark ? 0.44 : 0.26
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0.24),
                .init(color: .white.opacity(core * 0.27), location: 0.4),
                .init(color: .white.opacity(core), location: 0.5),
                .init(color: .white.opacity(core * 0.27), location: 0.6),
                .init(color: .white.opacity(0), location: 0.76),
            ],
            startPoint: UnitPoint(x: 0.3, y: position - 0.5),
            endPoint: UnitPoint(x: 0.7, y: position + 0.5)
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - A side

/// One side of a card: the language at the top with the tools, the text large in the middle, the
/// flip hint at the bottom; the glass or crystal under it is `CardSurface`'s. `verdict` floods
/// the card green or amber and settles the verdict's seal behind the text (a sorted card on its
/// way out).
struct FlashcardFace<Tools: View>: View {
    let side: FlashcardSide
    let height: CGFloat
    var verdict: FlashcardVerdict?
    @ViewBuilder var tools: Tools

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.s) {
                Text(side.label)
                    .eyebrowStyle()
                    .accessibilityHidden(true)
                Spacer(minLength: Spacing.s)
                tools
            }

            Spacer(minLength: Spacing.s)
            text
            Spacer(minLength: Spacing.s)

            HStack(spacing: 6) {
                Keycap(.space, size: .small)
                Text(side.isBack ? "Vorderseite" : "Umdrehen")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .padding(Spacing.xl + Spacing.xxs)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        // Under the text, so the seal never covers it.
        .background {
            ZStack {
                if let verdict {
                    VerdictFlood(verdict: verdict)
                        .transition(.opacity)
                    VerdictSeal(verdict: verdict)
                        .transition(sealTransition)
                }
            }
        }
        .animation(FlashcardMotion.tint, value: verdict)
    }

    @ViewBuilder
    private var text: some View {
        if LearnText.hasText(side.text) {
            Text(LearnText.spoken(side.text, lang: side.lang))
                .font(Typography.flashcard(for: side.text))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(7)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
                .cardTextDirection(side.lang)
                .padding(.horizontal, Spacing.l)
                .accessibilityLabel(Text(LearnText.labeled(side.label, side.text, lang: side.lang)))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(side.isBack ? "flashcard-back" : "flashcard-front")
        } else {
            Text("Keine Angabe")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }

    /// The seal settles in: from a little larger and clear into place, on a curve that lands
    /// softly (no bounce). Reduce Motion: it fades.
    private var sealTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .modifier(active: SealPlacement(scale: 1.18, opacity: 0), identity: SealPlacement())
            .animation(FlashcardMotion.seal)
    }
}

/// The verdict's colour flooding the card, strongest on the side the card is going to, with a
/// rim in the same colour.
private struct VerdictFlood: View {
    let verdict: FlashcardVerdict

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
        let toward: UnitPoint = verdict == .know ? .trailing : .leading
        let away: UnitPoint = verdict == .know ? .leading : .trailing
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [verdict.color.fill.opacity(0.36), verdict.color.fill.opacity(0.12)],
                    startPoint: toward, endPoint: away))
            shape.strokeBorder(verdict.color.fill.opacity(0.75), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The verdict behind the text, like a seal: its symbol in a ring, large and translucent in the
/// verdict's colour, with a second ring spreading from it as it settles.
private struct VerdictSeal: View {
    let verdict: FlashcardVerdict

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasSettled = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(verdict.color.fill, lineWidth: 2)
                .frame(width: 150, height: 150)
                .scaleEffect(hasSettled ? 1.7 : 1)
                .opacity(hasSettled || reduceMotion ? 0 : 0.45)
            Circle()
                .strokeBorder(verdict.color.fill.opacity(0.42), lineWidth: 5)
                .frame(width: 150, height: 150)
            Image(systemName: verdict.symbol)
                .font(.system(size: 70, weight: .bold))
                .foregroundStyle(verdict.color.fill.opacity(0.42))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(FlashcardMotion.ripple.delay(0.04)) { hasSettled = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The seal while it settles: larger and clear, then in place.
private struct SealPlacement: ViewModifier {
    var scale: Double = 1
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(CGFloat(scale))
            .opacity(opacity)
    }
}

/// 🔊 ★ ✎ in the card's corner. Not interactive on a card that is leaving or on the side that is
/// down (same look, no buttons, so ⌘E belongs to the side on screen).
struct FlashcardTools: View {
    let starred: Bool
    var isSpeaking = false
    var isInteractive = true
    var onSpeak: () -> Void = {}
    var onStar: () -> Void = {}
    var onEdit: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if isInteractive {
                LearnIconButton(label: "Vorlesen", help: "Vorlesen (⌘R)", systemImage: "speaker.wave.2.fill", action: onSpeak)
                    .symbolEffect(.variableColor.iterative, isActive: isSpeaking && !reduceMotion)
                LearnIconButton(
                    label: starred ? "Markierung entfernen" : "Markieren",
                    help: starred ? "Markierung entfernen (⌘D)" : "Markieren (⌘D)",
                    systemImage: starred ? "star.fill" : "star",
                    tint: starred ? Theme.star : nil,
                    action: onStar
                )
                .symbolEffect(.bounce, options: .nonRepeating, value: starred)
                // ⌘E wins over the Lernset menu's ⌘E while a card is on screen: it edits this card.
                LearnIconButton(
                    label: "Karte bearbeiten", help: "Karte bearbeiten (⌘E)", systemImage: "square.and.pencil",
                    shortcut: KeyboardShortcut("e", modifiers: .command), action: onEdit)
            } else {
                icon("speaker.wave.2.fill")
                icon(starred ? "star.fill" : "star", tint: starred ? Theme.star : nil)
                icon("square.and.pencil")
            }
        }
    }

    private func icon(_ systemImage: String, tint: Color? = nil) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .frame(width: 32, height: 32)
    }
}


// MARK: - The deck

/// The current card on the stack, with the cards still leaving over it. Every card is one view
/// for as long as it is on screen (keyed by its id and the deck's round): the current card becomes
/// a leaving one when it is sorted, and turns back into the current one when "Zurück" brings it
/// back in time. In a new round it is a new view, even while its last exit is still finishing.
/// A card that comes on screen anew rises from the stack (the next card) or slides back in from
/// its side ("Zurück" after it was gone).
struct FlashcardDeckView: View {
    let controller: FlashcardsController
    let height: CGFloat
    let onEdit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Grows with every turn of the current card (the stack behind it shows meanwhile).
    @State private var turnSerial = 0
    /// The card that turned last: once another card is on the deck, the stack goes back under it.
    @State private var turnCardID: String?

    private var deck: FlashcardDeck { controller.deck }

    private struct Entry: Identifiable {
        let card: Card
        let showsBack: Bool
        let leaving: FlashcardDeparture.Kind?
        var flung = false
        var releaseOffset: CGFloat = 0
        let generation: Int
        var id: String { "\(generation):\(card.id)" }
    }

    /// The current card and which side is up: a turn changes the side, not the card.
    private struct TurnKey: Equatable {
        let cardID: String?
        let isFlipped: Bool
    }

    /// The current card first, the leaving ones over it (latest on top).
    private var entries: [Entry] {
        var entries: [Entry] = []
        let generation = controller.deckGeneration
        if let card = controller.currentCard {
            entries.append(Entry(card: card, showsBack: deck.isFlipped, leaving: nil, generation: generation))
        }
        for departure in controller.departures
        where departure.generation != generation || departure.card.id != deck.currentCardID {
            entries.append(
                Entry(
                    card: departure.card, showsBack: departure.showsBack, leaving: departure.kind, flung: departure.flung,
                    releaseOffset: departure.releaseOffset, generation: departure.generation))
        }
        return entries
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Turned with the same curve as the card, so the stack shows exactly while it turns;
            // a swiped card uncovers it as it moves aside.
            FlashcardSwipeStack(
                swipe: controller.swipe, count: min(2, deck.upcomingCardIDs.count), height: height,
                angle: reduceMotion ? 0 : Double(turnSerial) * 180,
                turning: deck.currentCardID != nil && deck.currentCardID == turnCardID ? 1 : 0, isReduced: reduceMotion
            )
            .animation(FlashcardMotion.flip, value: turnSerial)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                FlashcardView(
                    card: entry.card,
                    front: controller.side(of: entry.card, showingBack: false),
                    back: controller.side(of: entry.card, showingBack: true),
                    isFlipped: entry.showsBack,
                    height: height,
                    leaving: entry.leaving,
                    swipe: entry.leaving == nil ? controller.swipe : nil,
                    flung: entry.flung,
                    releaseOffset: entry.releaseOffset,
                    isSpeaking: entry.leaving == nil && controller.speech.isSpeaking,
                    onFlip: controller.flip,
                    onSpeak: controller.speakVisibleSide,
                    onStar: controller.toggleStar,
                    onEdit: onEdit,
                    onDrag: controller.drag
                )
                .zIndex(Double(index))
                // Gone when its exit is over (it is invisible by then).
                .transition(.asymmetric(insertion: arrivalTransition, removal: .identity))
            }
        }
        .frame(height: height + FlashcardMetrics.stackDepth, alignment: .top)
        .onChange(of: TurnKey(cardID: deck.currentCardID, isFlipped: deck.isFlipped)) { old, new in
            guard old.cardID == new.cardID, old.isFlipped != new.isFlipped else { return }
            turnCardID = new.cardID
            turnSerial += 1
        }
    }

    /// Only moving, scaling and fading: the arriving card's glass stays in place.
    private var arrivalTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.2)) }
        switch controller.arrival {
        case .fromStack:
            return .modifier(
                active: CardPlacement(y: FlashcardMotion.riseDistance, scale: FlashcardMotion.riseScale, opacity: 0),
                identity: CardPlacement()
            )
            .animation(FlashcardMotion.arrive.delay(0.04))
        case let .fromSide(verdict):
            return .modifier(
                active: CardPlacement(
                    x: verdict.direction * FlashcardMotion.returnDistance, y: FlashcardMotion.riseDistance,
                    scale: 0.94, opacity: 0),
                identity: CardPlacement()
            )
            .animation(FlashcardMotion.arrive)
        }
    }
}

/// The stack under the current card, uncovered as far as the card is swiped aside. Its own view,
/// so a swipe re-renders nothing but it (and the card).
private struct FlashcardSwipeStack: View {
    let swipe: FlashcardSwipe
    let count: Int
    let height: CGFloat
    let angle: Double
    let turning: Double
    let isReduced: Bool

    var body: some View {
        FlashcardStackPeeks(
            count: count, height: height, angle: angle, swipe: isReduced ? 0 : abs(swipe.lean), turning: turning)
    }
}

/// The next cards of the stack under the current one. At rest only their edges peek out below
/// it: under the glass, a whole card would cloud it. While the card turns over, the cards come
/// into view at their full size behind it, fully while it stands on its edge, and are back under
/// it once it has landed (`angle`: the current card's turn, animated like the card); a swiped
/// card uncovers them too (`swipe`).
private struct FlashcardStackPeeks: View {
    let count: Int
    let height: CGFloat
    /// 180° for every time the current card was turned over.
    let angle: Double
    /// How far the current card is swiped aside, 0 … 1 at the threshold.
    var swipe: Double = 0
    /// 1 while the card that turns is still on the deck (`FlashcardMotion.stackReveal`).
    var turning: Double = 1

    var body: some View {
        ZStack(alignment: .top) {
            ForEach((0..<2).reversed(), id: \.self) { level in
                let edge = FlashcardMetrics.edge(level: level)
                if level == 0 {
                    // A card hides the one behind it, so their tints never add up.
                    FlashcardStackEdge.shape
                        .fill(.black)
                        .frame(height: height)
                        .padding(.horizontal, edge.inset)
                        .offset(y: edge.drop)
                        .blendMode(.destinationOut)
                }
                FlashcardStackEdge(height: height)
                    .padding(.horizontal, edge.inset)
                    .offset(y: edge.drop)
                    .opacity(level < count ? edge.opacity : 0)
            }
        }
        .frame(height: height + FlashcardMetrics.stackDepth, alignment: .top)
        .compositingGroup()
        .modifier(StackReveal(angle: angle, swipe: swipe, turning: turning, cardHeight: height))
        .animation(.easeOut(duration: 0.3), value: count)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shows the stack below the current card always, and behind it as much as the card's turn at
/// `angle` (or its swipe) uncovers it (`FlashcardMotion.stackReveal`).
private struct StackReveal: ViewModifier, Animatable {
    var angle: Double
    var swipe: Double
    var turning: Double
    let cardHeight: CGFloat

    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(angle, AnimatablePair(swipe, turning)) }
        set {
            angle = newValue.first
            swipe = newValue.second.first
            turning = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let reveal = FlashcardMotion.stackReveal(angle: angle, swipe: swipe, turning: turning)
        content.mask(alignment: .top) {
            VStack(spacing: 0) {
                Color.black.opacity(reveal)
                    .frame(height: cardHeight)
                Color.black
            }
        }
    }
}

/// A card of the stack: a quiet translucent card with a hairline.
private struct FlashcardStackEdge: View {
    let height: CGFloat

    static let shape = RoundedRectangle(cornerRadius: Radii.card, style: .continuous)

    var body: some View {
        Self.shape
            .fill(Theme.solidSurface.opacity(0.55))
            .overlay(Self.shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .frame(height: height)
    }
}


#if DEBUG
// MARK: - Snapshots

/// The card's motion frozen at moments worth looking at, on the study backdrop
/// (`--render-snapshots <dir> --snapshot-filter flashcard-`). `crystal` is the resting card as
/// the crystal stand-in, to hold against `rest` (the real glass).
final class FlashcardSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        FlashcardSnapshotMoment.allCases.map { moment in
            SnapshotScene("flashcard-\(moment.rawValue)", size: CGSize(width: 980, height: 620)) {
                FlashcardSnapshotStage(moment: moment)
            }
        }
    }
}

private enum FlashcardSnapshotMoment: String, CaseIterable {
    case rest
    case crystal
    case turn40 = "turn-40"
    case turn75 = "turn-75"
    case turn130 = "turn-130"
    case turn160 = "turn-160"
    case knowSealed = "know-sealed"
    case knowGlide = "know-glide"
    case learningGlide = "learning-glide"
    case swipeKnow = "swipe-know"
    case swipeLearning = "swipe-learning"

    /// Where a swipe has taken the card (+ to the right).
    var swipe: CGFloat {
        switch self {
        case .swipeKnow: 150
        case .swipeLearning: -70
        default: 0
        }
    }

    /// The verdict on the card: sorted, or armed by the swipe.
    var shownVerdict: FlashcardVerdict? {
        verdict ?? (abs(swipe) >= FlashcardSwipe.threshold ? FlashcardSwipe.verdict(for: swipe) : nil)
    }

    var angle: Double {
        switch self {
        case .turn40: 40
        case .turn75: 75
        case .turn130: 130
        case .turn160: 160
        default: 0
        }
    }

    var verdict: FlashcardVerdict? {
        switch self {
        case .knowSealed, .knowGlide: .know
        case .learningGlide: .stillLearning
        default: nil
        }
    }

    var glide: Double {
        switch self {
        case .knowGlide: 0.45
        case .learningGlide: 0.3
        default: 0
        }
    }

    var isLeaving: Bool {
        self == .crystal || verdict != nil
    }
}

/// One card on its stack, frozen at `moment`.
private struct FlashcardSnapshotStage: View {
    let moment: FlashcardSnapshotMoment

    private let height: CGFloat = 380
    private let front = FlashcardSide(text: "la mademoiselle", lang: .fr, label: "Französisch", isBack: false)
    private let back = FlashcardSide(text: "das Fräulein, die Frau", lang: .de, label: "Deutsch", isBack: true)

    var body: some View {
        let swipe = moment.swipe
        let isSwiped = swipe != 0
        ZStack(alignment: .top) {
            FlashcardStackPeeks(
                count: 2, height: height, angle: moment.angle, swipe: Double(abs(swipe) / FlashcardSwipe.threshold))
            CardSurface(
                angle: moment.angle, glide: isSwiped ? Double(abs(swipe) / FlashcardMotion.glideDistance) : moment.glide,
                direction: swipe < 0 ? -1 : moment.verdict?.direction ?? 1, isLeaving: moment.isLeaving,
                isBackUp: moment.angle > 90, hold: isSwiped ? 1 : 0, fades: isSwiped ? 0 : 1,
                wash: Double(max(-1, min(1, swipe / FlashcardSwipe.threshold)))
            ) {
                FlashcardFace(side: front, height: height, verdict: moment.shownVerdict) {
                    FlashcardTools(starred: true, isInteractive: false)
                }
            } back: {
                FlashcardFace(side: back, height: height, verdict: moment.shownVerdict) {
                    FlashcardTools(starred: true, isInteractive: false)
                }
            }
        }
        .frame(width: 640, height: height + FlashcardMetrics.stackDepth, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackdrop(intensity: AppBackdrop.studyIntensity) }
    }
}
#endif
