import AppKit
import Observation
import SwiftUI
import WortschatzCore

/// A card on its way out, still drawn over the deck until its exit is over (`FlashcardDeckView`):
/// sorted cards glide off to their side, a card that goes back under the stack ("Zurück") sinks
/// into it.
struct FlashcardDeparture: Identifiable, Equatable {
    enum Kind: Equatable {
        case sorted(FlashcardVerdict)
        /// "Zurück" brought the previous card back; the current one goes under the stack again.
        case backToStack
    }

    let id: Int
    let card: Card
    let showsBack: Bool
    let kind: Kind
    /// Sorted by letting go of a swipe: the card flies off from where it was let go.
    var flung = false
    var releaseOffset: CGFloat = 0
    /// The deck's round or restart it left (`FlashcardsController.deckGeneration`).
    var generation = 0
}

/// How the current card came on screen (its entrance, `FlashcardDeckView`).
enum FlashcardArrival: Equatable {
    /// Up from the stack: the next card.
    case fromStack
    /// Back from the side it was sorted to ("Zurück").
    case fromSide(FlashcardVerdict)
}

/// One side of a card as it is shown: the text, its language and the language's name.
struct FlashcardSide: Equatable {
    let text: String
    let lang: Lang
    let label: String
    let isBack: Bool
}

/// Runs one flashcards screen (Karteikarten): holds the deck and performs every action on it,
/// keeps it stored per set (`AppModel.storeFlashcardDeck`), reads cards aloud, stars and edits
/// them, and plays the round's sound. Sorting is self-assessment: nothing here records answers
/// or changes the mastery progress.
///
/// The view only renders the published state and calls the actions.
@MainActor
@Observable
final class FlashcardsController {
    let setID: String
    private(set) var set: VocabSet
    private(set) var deck: FlashcardDeck
    /// Cards still leaving the screen, oldest first.
    private(set) var departures: [FlashcardDeparture] = []
    /// How the current card came in.
    private(set) var arrival: FlashcardArrival = .fromStack
    /// Which side is up first (Optionen, the same for every set).
    private(set) var front: FlashcardFront
    /// Read-aloud (the app's shared service).
    let speech: SpeechService
    /// The current card following two fingers on the trackpad or the mouse.
    let swipe = FlashcardSwipe()

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let requestID: UUID
    @ObservationIgnored private let rng: RNG
    @ObservationIgnored private let clock: () -> Double
    /// Off for the snapshot harness: no storing, speech, sounds or announcements.
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var departureSerial = 0
    /// Grows with every new round and restart: a card that comes up again in the new round is a
    /// new view rising from the stack, while its last exit can still finish (`FlashcardDeckView`).
    private(set) var deckGeneration = 0

    /// `UserDefaults` keys of the options that apply to every set.
    static let frontKey = "flashcards.front"
    static let shuffleKey = "flashcards.shuffle"

    /// How long a departing card is kept (its exit, at most 0.56 s, is a little shorter).
    static let departureLifetime: Duration = .milliseconds(700)

    private var store: LibraryStore { model.store }

    init(
        model: AppModel,
        request: StudyRequest,
        rng: @escaping RNG = systemRNG(),
        clock: @escaping () -> Double = { TimeUtil.nowMs() },
        isLive: Bool = true
    ) {
        self.model = model
        self.rng = rng
        self.clock = clock
        self.isLive = isLive
        requestID = request.id
        setID = request.setID
        speech = model.speech
        let set = model.store.getSet(request.setID) ?? VocabSet(id: request.setID, title: "", createdAt: 0)
        self.set = set
        let defaults = UserDefaults.standard
        front = FlashcardFront(rawValue: defaults.string(forKey: Self.frontKey) ?? "") ?? .term
        deck = Self.startingDeck(
            set: set, saved: model.flashcardDeck(for: request.setID), request: request,
            shuffled: defaults.bool(forKey: Self.shuffleKey), rng: rng, now: clock())
    }

    /// The stored deck, brought up to date with the set, unless a new one is asked for (or the
    /// stored one is finished, empty or of another subset). A starred-only deck without starred
    /// cards becomes one of all cards.
    static func startingDeck(
        set: VocabSet, saved: FlashcardDeck?, request: StudyRequest, shuffled: Bool, rng: RNG, now: Double
    ) -> FlashcardDeck {
        let starredOnly = request.subset == .starred
        if !request.forceNew, var saved, request.subset == nil || saved.starredOnly == starredOnly {
            saved.sync(with: set.cards, now: now)
            saved.isFlipped = false
            // "Mischen" applies to every set, also to a deck started before it was changed.
            saved.setShuffled(shuffled, cardOrder: set.cards.map(\.id), rng: rng, now: now)
            if saved.isResumable { return saved }
        }
        let deck = FlashcardDeck(cards: set.cards, starredOnly: starredOnly, shuffled: shuffled, rng: rng, now: now)
        guard deck.phase == .empty, starredOnly else { return deck }
        return FlashcardDeck(cards: set.cards, shuffled: shuffled, rng: rng, now: now)
    }

    // MARK: Reading

    var phase: FlashcardDeck.Phase { deck.phase }

    /// The card on screen.
    var currentCard: Card? {
        deck.currentCardID.flatMap(card(id:))
    }

    func card(id: String) -> Card? {
        self.set.cards.first { $0.id == id }
    }

    /// The starred cards of the set (the "Nur markierte" option).
    var starredCount: Int {
        self.set.cards.reduce(0) { $0 + ($1.starred ? 1 : 0) }
    }

    /// What `card` shows face up (`showingBack == false`) or face down.
    func side(of card: Card, showingBack: Bool) -> FlashcardSide {
        let showsTerm = (front == .term) != showingBack
        let names = LearnOptionsCopy.sideNames(termLang: set.termLang, defLang: set.defLang)
        return FlashcardSide(
            text: showsTerm ? card.term : card.definition,
            lang: showsTerm ? set.termLang : set.defLang,
            label: showsTerm ? names.term.label : names.definition.label,
            isBack: showingBack)
    }

    /// Whether the screen is the one being studied (not one dissolving after it was left).
    private var isCurrent: Bool {
        !isLive || model.route.study?.id == requestID
    }

    // MARK: Lifecycle

    /// The screen appeared: from now on the route resumes this deck.
    func activate() {
        model.studySessionStarted(requestID: requestID)
        persist()
        if isLive { SoundEffects.shared.prepare() }
    }

    /// The screen went away: the deck stays stored, speech stops.
    func deactivate() {
        speech.stop()
        departures = []
        swipe.reset()
        persist()
    }

    // MARK: Keys and commands

    /// A key press on the screen; returns whether the screen used it (held keys are used but do
    /// nothing, so they never beep or reach other controls).
    func press(_ key: KeyInput, isRepeat: Bool) -> Bool {
        guard let action = FlashcardDeck.action(for: key, isRepeat: false, phase: phase) else { return false }
        if !isRepeat { perform(action) }
        return true
    }

    func perform(_ action: FlashcardAction) {
        switch action {
        case .flip: flip()
        case let .sort(verdict): sort(verdict)
        case .undo: undo()
        case .nextRound: nextRound()
        case .restart: restart()
        case .exit: exit()
        }
    }

    /// A Lernen menu command (⌘K, ⌘R, ⌘D, ⇧⌘R, esc).
    func handle(_ command: StudyCommand, showOptions: () -> Void) {
        guard isCurrent else { return }
        let event = NSApp.currentEvent
        if event?.type == .keyDown, event?.isARepeat == true { return }
        switch command {
        case .options: showOptions()
        case .speak: speakVisibleSide()
        case .toggleStar: toggleStar()
        case .restart: requestRestart()
        case .exit: exit()
        case .override, .dontKnow: break
        }
    }

    /// What the Lernen menu offers now (`isCovered`: a popover, sheet or alert is open).
    func enabledCommands(isCovered: Bool) -> Set<StudyCommand> {
        guard !isCovered else { return [] }
        var commands: Set<StudyCommand> = [.exit]
        if phase != .empty { commands.formUnion([.options, .restart]) }
        if phase == .card { commands.formUnion([.speak, .toggleStar]) }
        return commands
    }

    // MARK: Actions

    /// Turns the current card over.
    func flip() {
        guard isCurrent, phase == .card, let card = currentCard else { return }
        deck.flip(now: clock())
        if isLive {
            let side = side(of: card, showingBack: deck.isFlipped)
            Announcer.announce("\(side.label): \(side.text)")
        }
    }

    /// Sorts the current card: it glides off to its side (`flung`: a swipe let it go, it flies on
    /// from there), the next one comes up from the stack.
    func sort(_ verdict: FlashcardVerdict, flung: Bool = false) {
        guard isCurrent, phase == .card, let card = currentCard else { return }
        depart(
            card, showsBack: deck.isFlipped, kind: .sorted(verdict), flung: flung,
            releaseOffset: swipe.offset(for: card.id))
        animated {
            arrival = .fromStack
            // The stack the swipe uncovered goes back under the next card as it rises.
            swipe.reset()
            deck.sort(verdict, now: clock())
        }
        persist()
        guard isLive else { return }
        Haptics.selection()
        Announcer.announce(verdict == .know ? String(localized: "Weiss ich") : String(localized: "Lerne ich noch"))
        // The round's fanfare replaces the card's own sound, as in Lernen.
        switch phase {
        case .roundDone: SoundEffects.shared.play(.roundDone)
        case .finished: SoundEffects.shared.play(.finished)
        case .card, .empty: SoundEffects.shared.play(verdict == .know ? .know : .stillLearning)
        }
    }

    /// "Zurück" (⌫): the last sorted card comes back from its side; the current one goes back
    /// under the stack.
    func undo() {
        guard isCurrent, deck.canUndo else { return }
        if let card = currentCard {
            depart(card, showsBack: deck.isFlipped, kind: .backToStack)
        }
        let previous = deck.sorts.last
        animated {
            arrival = .fromSide(previous?.verdict ?? .know)
            swipe.reset()
            deck.undo(now: clock())
        }
        // The card coming back is no longer leaving.
        departures.removeAll { $0.card.id == previous?.cardID }
        persist()
        if isLive { SoundEffects.shared.play(.undo) }
    }

    /// "Weiter mit N Karten" after a round.
    func nextRound() {
        guard isCurrent, phase == .roundDone else { return }
        deckGeneration += 1
        animated {
            arrival = .fromStack
            swipe.reset()
            deck.startNextRound(cardOrder: set.cards.map(\.id), rng: rng, now: clock())
        }
        persist()
    }

    /// "Neu starten" (⇧⌘R): asks first when cards were sorted.
    func requestRestart() {
        guard isCurrent, phase != .empty else { return }
        guard deck.hasProgress, deck.isResumable else {
            restart()
            return
        }
        model.confirm(ConfirmationRequest(
            title: String(localized: "Karteikarten neu starten?"), message: FlashcardCopy.restartMessage(deck),
            confirmLabel: String(localized: "Neu starten")
        ) { [weak self] in
            self?.restart()
        })
    }

    /// A new deck over the same cards (or, with `starredOnly`, over all or the starred ones).
    func restart(starredOnly: Bool? = nil) {
        guard isCurrent else { return }
        let starredOnly = starredOnly ?? deck.starredOnly
        var fresh = FlashcardDeck(cards: set.cards, starredOnly: starredOnly, shuffled: deck.isShuffled, rng: rng, now: clock())
        if fresh.phase == .empty, starredOnly {
            fresh = FlashcardDeck(cards: set.cards, shuffled: deck.isShuffled, rng: rng, now: clock())
        }
        // Cards still leaving finish their exit; the new deck's cards are new views.
        deckGeneration += 1
        animated {
            arrival = .fromStack
            swipe.reset()
            deck = fresh
        }
        persist()
    }

    // MARK: Swiping

    /// Two fingers (or the mouse) start moving the current card; false when there is none.
    func swipeBegan(at time: TimeInterval) -> Bool {
        guard isCurrent, phase == .card, let id = deck.currentCardID else { return false }
        swipe.begin(cardID: id, at: time)
        return true
    }

    /// Two fingers moved the card by `delta` points.
    func swipeMoved(by delta: CGFloat, at time: TimeInterval) {
        guard swipe.cardID != nil, swipe.cardID == deck.currentCardID else { return }
        swipe.move(by: delta, at: time)
    }

    /// Let go: past the threshold (or flung) the card is sorted to that side, else it springs back.
    func swipeEnded(at time: TimeInterval) {
        guard swipe.cardID != nil else { return }
        guard swipe.cardID == deck.currentCardID, phase == .card, let verdict = swipe.end(at: time) else {
            swipe.settle(reduceMotion: StudyEntrance.reducesMotion)
            return
        }
        sort(verdict, flung: true)
    }

    /// The swipe was interrupted (a sheet opened, the system took the gesture): back to the middle.
    func swipeCancelled() {
        swipe.settle(reduceMotion: StudyEntrance.reducesMotion)
    }

    /// The mouse drags the current card (`FlashcardView.onDrag`).
    func drag(_ drag: FlashcardDrag) {
        switch drag {
        case let .changed(translation, time):
            if !swipe.isTracking || swipe.cardID != deck.currentCardID {
                guard swipeBegan(at: time) else { return }
            }
            swipe.move(to: translation, at: time)
        case let .ended(time):
            swipeEnded(at: time)
        }
    }

    /// Back to the set (esc, "Zurück zum Lernset").
    func exit() {
        guard isCurrent else { return }
        speech.stop()
        model.finishStudy()
    }

    /// "Lernen" after the last round: the cards are tested for real there.
    func openLearn() {
        guard isCurrent else { return }
        speech.stop()
        model.continueLearn(setID: setID)
    }

    /// "Begriffe hinzufügen" on an empty set.
    func addCards() {
        model.openEditor(.edit(setID: setID))
    }

    // MARK: Card tools

    /// 🔊 (⌘R): reads the side that is up.
    func speakVisibleSide() {
        guard isLive, phase == .card, let card = currentCard else { return }
        let side = side(of: card, showingBack: deck.isFlipped)
        guard LearnText.hasText(side.text) else { return }
        speech.speak(side.text, lang: side.lang)
    }

    /// ★ (⌘D) of the current card.
    func toggleStar() {
        guard isCurrent, phase == .card, let card = currentCard else { return }
        model.toggleStar(setID: setID, cardID: card.id)
    }

    /// ✎ (⌘E): the card editor saved.
    func saveEdit(_ card: Card) {
        do {
            _ = try store.updateCard(setID, card.id, CardChanges(term: card.term, definition: card.definition))
        } catch {
            model.report(error, fallback: String(localized: "Die Karte konnte nicht gespeichert werden."))
        }
    }

    // MARK: Options

    func setFront(_ newFront: FlashcardFront) {
        guard newFront != front else { return }
        front = newFront
        UserDefaults.standard.set(newFront.rawValue, forKey: Self.frontKey)
    }

    func setShuffled(_ shuffled: Bool) {
        UserDefaults.standard.set(shuffled, forKey: Self.shuffleKey)
        deck.setShuffled(shuffled, cardOrder: set.cards.map(\.id), rng: rng, now: clock())
        persist()
    }

    /// "Nur markierte": starts over with the starred cards (or all again).
    func setStarredOnly(_ starredOnly: Bool) {
        guard starredOnly != deck.starredOnly else { return }
        restart(starredOnly: starredOnly)
    }

    // MARK: Store

    /// The library changed (star, card editor, set editor, another window): the deck follows.
    func storeDidChange() {
        guard let newSet = store.getSet(setID), newSet != set else { return }
        set = newSet
        let currentID = deck.currentCardID
        guard deck.sync(with: newSet.cards, now: clock()) else { return }
        // The current card was deleted: the next one rises from the stack, and a swipe of the
        // deleted card is over.
        if deck.currentCardID != currentID {
            swipe.reset()
            arrival = .fromStack
        }
        persist()
    }

    // MARK: Helpers

    /// A change that brings another card: its entrance, the counts and the stack move together.
    private func animated(_ change: () -> Void) {
        withAnimation(Motion.animation(FlashcardMotion.arrive, reduceMotion: StudyEntrance.reducesMotion), change)
    }

    private func depart(
        _ card: Card, showsBack: Bool, kind: FlashcardDeparture.Kind, flung: Bool = false, releaseOffset: CGFloat = 0
    ) {
        departureSerial += 1
        let departure = FlashcardDeparture(
            id: departureSerial, card: card, showsBack: showsBack, kind: kind, flung: flung, releaseOffset: releaseOffset,
            generation: deckGeneration)
        // One view per card and round: a card leaving again replaces its earlier exit.
        departures.removeAll { $0.card.id == card.id && $0.generation == deckGeneration }
        departures.append(departure)
        // Fast sorting: only the last few are still worth drawing.
        if departures.count > 3 { departures.removeFirst(departures.count - 3) }
        guard isLive else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.departureLifetime)
            self?.departures.removeAll { $0.id == departure.id }
        }
    }

    private func persist() {
        guard isLive else { return }
        model.storeFlashcardDeck(deck, for: setID)
    }
}
