import AppKit
import Observation
import SwiftUI
import WortschatzCore

// Swiping a flashcard (Karteikarten): the current card follows two fingers on the trackpad
// (horizontal scroll events) or a drag with the mouse, leaning a little and taking on the colour
// of the side it is heading for. Past `FlashcardSwipe.threshold` the verdict settles on it (a
// seal, a haptic tick on a Force Touch trackpad) and letting go sorts it to that side, where it
// flies off from where it is; a quick flick sorts it too. Anything else springs it back.

/// A mouse drag on the current card: where it has moved the card (points from where it started),
/// and when the button was let go.
enum FlashcardDrag: Equatable {
    case changed(CGFloat, at: TimeInterval)
    case ended(at: TimeInterval)
}

/// The current card following a swipe. `FlashcardsController` owns it; `FlashcardView` reads it
/// for the current card only.
@MainActor
@Observable
final class FlashcardSwipe {
    /// The card the swipe belongs to (nil: none since the last card change).
    private(set) var cardID: String?
    /// How far the fingers (or the mouse) have moved the card, + to the right, before the
    /// rubber band (`offset`).
    private(set) var travel: CGFloat = 0
    /// From the first movement until the card lies still again: the crystal stands in for the
    /// glass, which cannot lean.
    private(set) var isEngaged = false
    /// The fingers (or the mouse button) are down.
    private(set) var isTracking = false

    /// Past this distance letting go sorts the card.
    static let threshold: CGFloat = 110
    /// Beyond this the card follows more and more reluctantly.
    static let freeTravel: CGFloat = 170
    /// A flick: where the card would be this many seconds after letting go decides.
    static let projection: Double = 0.14

    @ObservationIgnored private var samples: [(time: TimeInterval, travel: CGFloat)] = []

    // MARK: Reading

    /// Where the card is drawn (+ to the right), with the rubber band past `freeTravel`.
    var offset: CGFloat {
        let distance = abs(travel)
        guard distance > Self.freeTravel else { return travel }
        let extra = distance - Self.freeTravel
        return (travel < 0 ? -1 : 1) * (Self.freeTravel + extra * 0.4)
    }

    /// The side the card would be sorted to if let go now (nil: it would spring back).
    var armed: FlashcardVerdict? {
        abs(offset) >= Self.threshold ? Self.verdict(for: offset) : nil
    }

    /// How far toward the threshold, -1 (Lerne ich noch) … 1 (Weiss ich).
    var lean: Double {
        Double(max(-1, min(1, offset / Self.threshold)))
    }

    /// The swipe of `card` (0 for any other card).
    func offset(for card: String) -> CGFloat { cardID == card ? offset : 0 }

    static func verdict(for offset: CGFloat) -> FlashcardVerdict {
        offset >= 0 ? .know : .stillLearning
    }

    // MARK: Moving

    /// The fingers (or the mouse) start moving the card `cardID`.
    func begin(cardID: String, at time: TimeInterval) {
        if self.cardID != cardID {
            travel = 0
        }
        self.cardID = cardID
        isTracking = true
        isEngaged = true
        samples = [(time, travel)]
    }

    /// Moves the card by `delta` (trackpad scroll events).
    func move(by delta: CGFloat, at time: TimeInterval) {
        guard isTracking else { return }
        update(travel + delta, at: time)
    }

    /// Moves the card to `translation` (a mouse drag from where it started).
    func move(to translation: CGFloat, at time: TimeInterval) {
        guard isTracking else { return }
        update(translation, at: time)
    }

    /// The fingers lifted: the side to sort the card to, or nil, and then the card springs back
    /// (`settle`).
    func end(at time: TimeInterval) -> FlashcardVerdict? {
        guard isTracking else { return nil }
        isTracking = false
        let projected = travel + velocity(at: time) * CGFloat(Self.projection)
        if abs(offset) >= Self.threshold { return Self.verdict(for: offset) }
        if abs(projected) >= Self.threshold * 1.2, abs(travel) >= 16, (projected < 0) == (travel < 0) {
            return Self.verdict(for: projected)
        }
        return nil
    }

    /// The card springs back to the middle and its glass returns once it lies still.
    func settle(reduceMotion: Bool) {
        isTracking = false
        guard cardID != nil else { return }
        let id = cardID
        withAnimation(reduceMotion ? Motion.fade : FlashcardMotion.snapBack) {
            travel = 0
        } completion: { [weak self] in
            // The card keeps its (now empty) swipe until the next card: the crystal dissolves
            // into the glass on it.
            guard let self, cardID == id, !isTracking else { return }
            withAnimation(FlashcardMotion.glassReturn) { isEngaged = false }
        }
    }

    /// Forgets the swipe (the card was sorted, or another card came); animated with the change
    /// that brings the next card, if any.
    func reset() {
        guard cardID != nil || travel != 0 || isEngaged || isTracking else { return }
        cardID = nil
        travel = 0
        isTracking = false
        isEngaged = false
        samples = []
    }

    // MARK: Internals

    private func update(_ newTravel: CGFloat, at time: TimeInterval) {
        let before = armed
        travel = newTravel
        samples.append((time, newTravel))
        samples.removeAll { time - $0.time > 0.12 }
        if armed != before, armed != nil { Haptics.selection() }
    }

    /// Points per second over the last moments.
    private func velocity(at time: TimeInterval) -> CGFloat {
        guard let first = samples.first, let last = samples.last, time - last.time < 0.08 else { return 0 }
        let span = last.time - first.time
        guard span > 0.004 else { return 0 }
        return (last.travel - first.travel) / CGFloat(span)
    }
}

// MARK: - Trackpad

extension View {
    /// Two-finger swipes left and right on the trackpad move the current flashcard
    /// (`FlashcardsController.swipe…`). Vertical scrolling keeps scrolling the page; while
    /// `isEnabled` is false (a popover, sheet or alert is open, no card is up) nothing is taken.
    func flashcardTrackpadSwipe(_ controller: FlashcardsController, isEnabled: Bool) -> some View {
        modifier(FlashcardTrackpadSwipe(controller: controller, isEnabled: isEnabled))
    }
}

private struct FlashcardTrackpadSwipe: ViewModifier {
    let controller: FlashcardsController
    let isEnabled: Bool

    @State private var monitor = FlashcardScrollMonitor()

    func body(content: Content) -> some View {
        content
            .background { SwipeWindowReader { monitor.window = $0 } }
            .onAppear {
                monitor.controller = controller
                monitor.isEnabled = isEnabled
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: isEnabled) { _, enabled in
                monitor.isEnabled = enabled
                if !enabled { monitor.cancel() }
            }
    }
}

/// Watches the window's scroll events: a gesture that starts mostly sideways belongs to the card
/// until the fingers lift (its momentum too); any other one scrolls as usual.
@MainActor
private final class FlashcardScrollMonitor {
    weak var window: NSWindow?
    weak var controller: FlashcardsController?
    var isEnabled = false

    private enum Axis { case undecided, horizontal, vertical }

    private var token: Any?
    private var axis: Axis = .undecided
    private var pending = CGSize.zero
    /// The last gesture was the card's: its momentum events are swallowed too.
    private var ownsMomentum = false

    func start() {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        cancel()
    }

    /// Gives the card back (a sheet opened mid-swipe, the screen went away).
    func cancel() {
        if axis == .horizontal { controller?.swipeCancelled() }
        axis = .undecided
        pending = .zero
    }

    /// Whether the event moved the card (and must not scroll anything).
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] {
            let owned = ownsMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                ownsMomentum = false
            }
            return owned
        }
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.mayBegin) {
            if axis == .horizontal { controller?.swipeCancelled() }
            axis = .undecided
            pending = .zero
            ownsMomentum = false
            if phase.contains(.mayBegin) { return false }
        }
        if phase.contains(.changed) || phase.contains(.began) {
            return moved(event)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            defer {
                axis = .undecided
                pending = .zero
            }
            guard axis == .horizontal else { return false }
            ownsMomentum = true
            if phase.contains(.cancelled) {
                controller?.swipeCancelled()
            } else {
                controller?.swipeEnded(at: event.timestamp)
            }
            return true
        }
        return false
    }

    private func moved(_ event: NSEvent) -> Bool {
        // Positive deltas move the content to the right (with natural scrolling: the fingers'
        // way), so the card goes where scrolled content would go.
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        switch axis {
        case .vertical:
            return false
        case .horizontal:
            controller?.swipeMoved(by: dx, at: event.timestamp)
            return true
        case .undecided:
            pending.width += dx
            pending.height += dy
            guard abs(pending.width) + abs(pending.height) >= 6 else { return false }
            guard isEnabled, abs(pending.width) > abs(pending.height) * 1.2,
                controller?.swipeBegan(at: event.timestamp) == true
            else {
                axis = .vertical
                return false
            }
            axis = .horizontal
            controller?.swipeMoved(by: pending.width, at: event.timestamp)
            return true
        }
    }
}

/// Reports the window the view is in.
private struct SwipeWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> SwipeWindowView {
        SwipeWindowView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: SwipeWindowView, context: Context) {
        nsView.onWindow = onWindow
    }
}

private final class SwipeWindowView: NSView {
    var onWindow: (NSWindow?) -> Void

    init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
    }
}
