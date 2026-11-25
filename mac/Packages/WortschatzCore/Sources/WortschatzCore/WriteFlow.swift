import Foundation

// Write mode ("Schreiben") as a pure reducer (spec §6): a port of the state machine in
// src/screens/write.js together with the keyboard rules of write-keys.js, the card states of
// write-card.js and the round/results logic of write-views.js.
//
// The SwiftUI view renders `State` and forwards events; the app performs the returned effects
// (store writes, speech, haptics, VoiceOver, timers, navigation). Nothing here touches the store,
// the clock or the system random source directly: `Env` supplies time, randomness and the current
// progress, so every rule (including "one Return = one transition") is unit-tested.
//
// Phases: question → feedback (correct | wrong | dontKnow) or the copy step → … → round summary →
// … → results. Every session change is persisted with `.saveSession`, including the open
// "Nicht ganz" screen (`pending`), so leaving and coming back resumes exactly where the learner
// stopped.
//
// Differences to the web screen, all deliberate:
// - Return on the results screen without misses means "Fertig" (back to the set, spec §4.3); the
//   web app restarts the session there. "Nochmal von vorne" is `.restart` (⇧⌘R).
// - New keys of the Mac app: ⌥↩ "Weiss ich nicht" and ⌘↩ "Ich hatte recht" follow the Return rules
//   (ignored while held and right after a transition); Esc leaves Write mode (ignored while held).
// - At most one `.saveSession` and one `.announce` per event: the latest (the web app's last write
//   wins, and its announcer drops all but the last message).
// - Haptic feedback on graded answers (spec §4.2); a "Weiss ich nicht" gets none.
// - Dialogs (card editor, options, restart questions) are part of the state (`overlay`, `prompt`),
//   so pausing and resuming the auto-advance timer around them is testable.

/// Write mode as a pure reducer (spec §6). See the file header of WriteFlow.swift.
public enum WriteFlow {
    // MARK: - Constants

    /// Auto-advance after an exact correct answer (`ADVANCE_MS`).
    public static let advanceMs = 900
    /// Auto-advance after a tolerated answer, time to read "Genau: …" (`ADVANCE_MS_WITH_NOTES`).
    public static let advanceMsWithNotes = 1800
    /// Return-family keys are ignored this long after a transition (`ENTER_LOCK_MS`).
    public static let enterLockMs: Double = 280
    /// After a correct answer, Return within the lock is not lost: it moves on as soon as the
    /// lock ends. Presses closer than this to the answer count as the answering press itself.
    public static let skipMinGapMs: Double = 50
    /// Praise after an exact answer; never the same twice in a row (`PRAISE`).
    public static var praise: [String] { [L("Richtig!"), L("Super!"), L("Genau!"), L("Stark!")] }
    /// How often the app should send `.clockTick` while the window is visible (write-clock.js).
    public static let clockTickMs: Double = 15_000
    /// After this long without input the app stops ticking and sends `.clockResumed` on the next
    /// input, so idle time is not study time (write-clock.js).
    public static let clockIdleMs: Double = 2 * 60 * 1000

    // MARK: - Phase

    /// The kind of feedback after an answer.
    public enum FeedbackKind: String, Codable, Sendable, Equatable, Hashable {
        /// "Richtig!": the answer was accepted.
        case correct
        /// "Nicht ganz.": a wrong answer.
        case wrong
        /// "Kein Problem – merk dir das:": the learner chose "Weiss ich nicht".
        case dontKnow
    }

    public enum Phase: Codable, Sendable, Equatable, Hashable {
        /// Nothing is shown yet: the start question (`prompt`, "Laufende Runde beenden?") is open.
        case starting
        /// A written question; the answer field is editable.
        case question
        /// The feedback after an answer, without a copy step.
        case feedback(FeedbackKind)
        /// A miss with the copy step ("Richtige Antwort abtippen"); `feedback.dontKnow` tells
        /// whether it followed "Weiss ich nicht".
        case copy
        /// The round summary ("Runde 1 geschafft", "Weiter zu Runde 2").
        case summary
        /// The results of the finished session.
        case results
        /// Nothing to practise in the requested subset (see `emptyMessage`).
        case empty
        /// The set does not exist (any more).
        case missing

        /// Question, feedback or copy step: the question card is shown.
        public var isCard: Bool {
            switch self {
            case .question, .feedback, .copy: true
            default: false
            }
        }

        /// A miss is shown (wrong or "Weiss ich nicht", with or without the copy step).
        public var isMiss: Bool {
            switch self {
            case .feedback(.wrong), .feedback(.dontKnow), .copy: true
            default: false
            }
        }
    }

    // MARK: - State parts

    /// The answered question's outcome (`last` in write.js, without the question itself).
    public struct Feedback: Codable, Sendable, Equatable, Hashable {
        /// What was typed, trimmed ("" for "Weiss ich nicht").
        public var given: String
        /// The grading result; nil for "Weiss ich nicht" (and for a restored miss without an answer).
        public var result: GradeResult?
        public var dontKnow: Bool
        /// The copy step is shown.
        public var copy: Bool
        /// The card was edited during the miss and now accepts what was typed.
        public var editedCorrect: Bool
        /// The answer belongs to another card with the same prompt.
        public var synonym: Bool
        /// The title of a correct answer ("Super!", "Auch richtig!", …).
        public var praise: String?

        public init(
            given: String, result: GradeResult?, dontKnow: Bool, copy: Bool = false, editedCorrect: Bool = false,
            synonym: Bool = false, praise: String? = nil
        ) {
            self.given = given
            self.result = result
            self.dontKnow = dontKnow
            self.copy = copy
            self.editedCorrect = editedCorrect
            self.synonym = synonym
            self.praise = praise
        }

        public var isCorrect: Bool { result?.correct == true }

        /// "Super!" after a correct answer, "Nicht ganz." after a miss and
        /// "Kein Problem – merk dir das:" after "Weiss ich nicht".
        public var title: String {
            if isCorrect { return praise ?? L("Richtig!") }
            return dontKnow ? L("Kein Problem – merk dir das:") : L("Nicht ganz.")
        }

        /// Introduces `result.expectedDisplay` after a tolerated answer: "Genau:", or
        /// "Gesucht war:" for a synonym.
        public var exactLabel: String { synonym ? L("Gesucht war:") : L("Genau:") }

        /// A tolerated (not exact) correct answer shows the exact answer under `exactLabel`.
        public var showsExact: Bool {
            guard let result, isCorrect else { return false }
            return !result.exact && !result.expectedDisplay.isEmpty
        }

        /// The note chips of a correct answer; synonyms use the accent tone, the rest a warning tone.
        public var notes: [NoteLabel] {
            guard isCorrect, let result else { return [] }
            return result.notes.compactMap { note in
                Labels.NOTE_LABELS[note].map { NoteLabel(note: note, label: $0) }
            }
        }

        /// The hint chip of a miss ("Falscher Artikel", …).
        public var hintLabel: String? { result?.hint.flatMap { Labels.HINT_LABELS[$0] } }

        /// Whether the hint chip is shown (not once an edit made the answer correct).
        public var showsHint: Bool { hintLabel != nil && !editedCorrect }

        /// The typed answer is shown under "Deine Antwort" (with `WriteFlow.answerDiff`).
        public var showsGiven: Bool { !given.isEmpty && !dontKnow }

        /// "Ich hatte recht" is offered (⌘↩).
        public var canOverride: Bool { !dontKnow && WriteFlow.hasText(given) }

        /// "Als richtig zählen" after an edit made the answer correct, else "Ich hatte recht".
        public var overrideLabel: String { editedCorrect ? L("Als richtig zählen") : L("Ich hatte recht") }

        /// The note under the answers after such an edit.
        public var editedNote: String? { editedCorrect ? L("Mit deiner Korrektur stimmt deine Antwort jetzt.") : nil }
    }

    /// A note chip after a correct answer.
    public struct NoteLabel: Codable, Sendable, Equatable, Hashable {
        public var note: GradeNote
        public var label: String
        /// Synonym notes are shown in the accent tone, others as a warning.
        public var isSynonym: Bool { note == .synonym || note == .extendedSynonym }
    }

    /// The pending auto-advance after a correct answer. A timer whose token does not match the
    /// current one is stale and ignored.
    public struct AutoAdvance: Codable, Sendable, Equatable, Hashable {
        public var token: Int
        public var ms: Int
    }

    /// The results of a finished session.
    public struct Results: Codable, Sendable, Equatable, Hashable {
        public var stats: WriteSession.FinalStats
        /// The missed cards that still exist ("Falsche nochmal üben"; empty hides the button).
        public var retryCardIds: [String]
        /// Distinct cards of the session.
        public var cardCount: Int
        /// The session asked both directions.
        public var bothDirections: Bool

        public var canRetry: Bool { !retryCardIds.isEmpty }
    }

    /// The direction, order and copy settings when the options sheet opened.
    public struct OptionsBaseline: Codable, Sendable, Equatable, Hashable {
        public var answerWith: AnswerWith
        public var shuffle: Bool
        public var copyAnswer: Bool

        init(_ options: StudyOptions) {
            answerWith = options.answerWith
            shuffle = options.shuffle
            copyAnswer = options.copyAnswer
        }
    }

    /// A sheet the view shows on top of the study card. Keys are ignored while one is open.
    public enum Overlay: Codable, Sendable, Equatable, Hashable {
        /// "Karte bearbeiten" for the question's card; `focus` is the side the learner had to type.
        /// Answer with `.editCard` (save, closes it) or `.overlayDismissed` (cancel).
        case editor(question: SessionQuestion, focus: AskSide, resumesTimer: Bool)
        /// The options sheet; changes arrive as `.optionsChanged`, closing with `.overlayDismissed`.
        case options(before: OptionsBaseline, resumesTimer: Bool)
    }

    /// A yes/no question the view shows as an alert. Answer with `.promptAnswered`.
    public enum Prompt: Codable, Sendable, Equatable, Hashable {
        /// "Neu starten?" (sidebar button, menu or the options sheet's "Neu starten").
        case restart(resumesTimer: Bool)
        /// A subset was requested while an answered round of another subset is stored.
        case replaceRound(wanted: StudySubset, saved: SessionState, feedback: PendingFeedback?)
    }

    /// A toast the app shows.
    public enum Toast: String, Codable, Sendable, Equatable, Hashable {
        /// "Willkommen zurück – weiter geht's" after resuming a session with answers.
        case welcomeBack
        /// "Als richtig gezählt" after "Ich hatte recht".
        case countedAsCorrect
        /// "Karte gespeichert" after an edit.
        case cardSaved

        public var message: String {
            switch self {
            case .welcomeBack: L("Willkommen zurück – weiter geht's")
            case .countedAsCorrect: L("Als richtig gezählt")
            case .cardSaved: L("Karte gespeichert")
            }
        }

        /// Success tone (green) instead of the neutral one.
        public var isSuccess: Bool { self != .welcomeBack }

        /// Display time; nil means the app's default.
        public var durationMs: Int? {
            switch self {
            case .welcomeBack: nil
            case .countedAsCorrect: 2000
            case .cardSaved: 2200
            }
        }

        /// SF Symbol.
        public var systemImage: String {
            switch self {
            case .welcomeBack: "sparkles"
            case .countedAsCorrect, .cardSaved: "checkmark.circle.fill"
            }
        }
    }

    /// What `.speak` reads aloud.
    public enum SpeechTarget: String, Codable, Sendable, Equatable, Hashable {
        /// The prompt ("Vorlesen", ⌘R).
        case prompt
        /// The expected answer ("Antwort vorlesen").
        case answer
    }

    // MARK: - State

    /// Everything the Write screen renders. Change it only through `reduce`.
    public struct State: Codable, Sendable, Equatable {
        public internal(set) var phase: Phase
        /// The set being studied; nil when it does not exist.
        public internal(set) var set: VocabSet?
        public internal(set) var options: StudyOptions
        public internal(set) var session: SessionState?
        /// The question on the card: the current one, or the answered one during feedback.
        public internal(set) var question: Question?
        /// The outcome of the answered question (feedback and copy step).
        public internal(set) var feedback: Feedback?
        /// The open miss, persisted with the session so a relaunch shows it again.
        public internal(set) var pending: PendingFeedback?
        /// The answer field (question) or the copy field (copy step); `.inputChanged` updates it.
        public internal(set) var input: String
        /// The copy field holds a rejected attempt (cleared by typing).
        public internal(set) var inputInvalid: Bool
        /// Bumps when an empty answer or a wrong copy is rejected (drives the shake).
        public internal(set) var rejections: Int
        /// Bumps for every new question (drives the prompt transition).
        public internal(set) var questionSerial: Int
        /// The new question replaces another one on the card (animate the swap).
        public internal(set) var animatesQuestion: Bool
        /// Bumps after a sheet or alert closed: move focus back to the primary control.
        public internal(set) var focusSerial: Int
        public internal(set) var summary: WriteSession.RoundSummary?
        public internal(set) var results: Results?
        /// The subset that turned out empty (`.empty`).
        public internal(set) var emptySubset: StudySubset?
        /// The running auto-advance after a correct answer (drives the countdown bar).
        public internal(set) var autoAdvance: AutoAdvance?
        public internal(set) var overlay: Overlay?
        public internal(set) var prompt: Prompt?
        /// Return-family keys are ignored before this time (epoch ms).
        public internal(set) var lockUntil: Double
        var lastPraise: String
        var nextToken: Int

        init(set: VocabSet?, options: StudyOptions) {
            phase = set == nil ? .missing : .starting
            self.set = set
            self.options = options
            session = nil
            question = nil
            feedback = nil
            pending = nil
            input = ""
            inputInvalid = false
            rejections = 0
            questionSerial = 0
            animatesQuestion = false
            focusSerial = 0
            summary = nil
            results = nil
            emptySubset = nil
            autoAdvance = nil
            overlay = nil
            prompt = nil
            lockUntil = 0
            lastPraise = ""
            nextToken = 0
        }

        /// The answer or copy field accepts typing.
        public var isInputEditable: Bool { phase == .question || phase == .copy }

        /// A sheet or alert is open; keys go to it, not to the flow.
        public var isBlocked: Bool { overlay != nil || prompt != nil }

        /// The `startedAt` of the shown session. Pass it back as `resultsMarker` to `start` to show
        /// a finished session's results again when the same screen is restored.
        public var resultsMarker: Double? { session?.startedAt }
    }

    // MARK: - Events and effects

    public enum Event: Equatable, Sendable {
        /// A key press; `isRepeat` for auto-repeat while held (never transitions). The answer field
        /// keeps its own typing, forward Return-family keys, Escape and (in the correct phase)
        /// printable keys.
        case key(KeyInput, isRepeat: Bool = false)
        /// The answer or copy field changed.
        case inputChanged(String)
        /// "Antworten" (question) or "Weiter" of the copy step, with the field's text.
        case submit(String)
        /// "Weiss ich nicht".
        case dontKnow
        /// The primary button of the current step was clicked ("Antworten", "Weiter",
        /// "Weiter zu Runde N", "Falsche nochmal üben"/"Fertig", …).
        case proceed
        /// "Ich hatte recht" / "Als richtig zählen".
        case override
        /// A timer from `.scheduleAutoAdvance` fired.
        case autoAdvanceFired(token: Int)
        /// The star of the question's card.
        case toggleStar
        /// The speaker buttons ("Vorlesen" ⌘R, "Antwort vorlesen").
        case speak(SpeechTarget)
        /// "Bearbeiten" (⌘E): opens `Overlay.editor` for the question's card.
        case requestEdit
        /// The editor saved the card (its `term` and `definition`); closes the editor.
        case editCard(Card)
        /// "Optionen" (⌘K): opens `Overlay.options`.
        case requestOptions
        /// The study options changed (live from the options sheet, or anywhere else).
        case optionsChanged(StudyOptions)
        /// The open sheet closed; `restartRequested` when the options sheet's "Neu starten" was used.
        case overlayDismissed(restartRequested: Bool = false)
        /// The open alert was answered.
        case promptAnswered(confirmed: Bool)
        /// "Neu starten" (asks first) or, on the results screen, "Nochmal von vorne" (⇧⌘R).
        case restart
        /// "Falsche nochmal üben" on the results screen.
        case retryMissed
        /// "Alle Begriffe üben" on the empty screen.
        case practiceAll
        /// "Zurück zum Lernset".
        case leave
        /// The set changed outside the flow (another window, the editor, a deletion of cards).
        case setChanged(VocabSet)
        /// Only the cards changed outside the flow.
        case cardsChanged([Card])
        /// The set was deleted.
        case setDeleted
        /// The periodic study clock (every `clockTickMs` while visible and active, and once when
        /// the screen goes away).
        case clockTick
        /// Study time counts again from now (after the window was hidden or idle).
        case clockResumed

        /// `.key` for a `KeyPress` of the view layer.
        public static func key(_ press: KeyPress) -> Event { .key(press.key, isRepeat: press.isRepeat) }
    }

    public enum Effect: Equatable, Sendable {
        /// `LibraryStore.recordAnswer(setId, cardId, correct:, at:)`.
        case recordAnswer(cardId: String, correct: Bool, at: Double)
        /// `LibraryStore.overrideLastAnswer(setId, cardId)`.
        case overrideLastAnswer(cardId: String)
        /// Persist the session with the open miss: `LibraryStore.saveSessionJSON(setId,
        /// WriteFlow.storedJSON(session:feedback:))`. At most one per event (the latest).
        case saveSession(SessionState, feedback: PendingFeedback?)
        /// Read `text` aloud in `lang` (cancelling anything still speaking).
        case speak(text: String, lang: Lang)
        case haptic(HapticKind)
        /// Send `.autoAdvanceFired(token:)` after `ms` milliseconds.
        case scheduleAutoAdvance(ms: Int, token: Int)
        /// A VoiceOver announcement. At most one per event (the latest).
        case announce(String)
        /// `LibraryStore.updateCard(setId, card.id, CardChanges(term:definition:))`.
        case updateCard(Card)
        /// `LibraryStore.toggleStar(setId, cardId)`.
        case toggleStar(cardId: String)
        case toast(Toast)
        /// Open the set editor ("Begriffe hinzufügen").
        case editSet
        /// Leave Write mode: back to the set, or to the overview when the set is gone.
        case exit
    }

    /// The world the reducer reads: time, randomness and the set's current progress (read when a
    /// session is created for the "Nicht gemeistert" / "Falsch beantwortet" subsets).
    public struct Env {
        public var now: Double
        public var rng: RNG
        public var progress: ProgressMap
        /// Words with the same meaning as a question's answer that are not in the set
        /// (`ExtendedSynonyms`); an answer matching one counts as right.
        public var extraAnswers: (SynonymQuery) -> [String]

        public init(
            now: Double = TimeUtil.nowMs(), rng: @escaping RNG = systemRNG(), progress: ProgressMap = [:],
            extraAnswers: @escaping (SynonymQuery) -> [String] = { _ in [] }
        ) {
            self.now = now
            self.rng = rng
            self.progress = progress
            self.extraAnswers = extraAnswers
        }
    }

    // MARK: - API

    /// Opens Write mode for `set` (nil: the set does not exist).
    ///
    /// A stored session (`saved`, with the open miss `savedFeedback`) is resumed unless
    /// `forceNew`, it is finished, or another named `subset` was requested. A requested subset
    /// that would drop an answered round asks first (`Prompt.replaceRound`). A finished session is
    /// shown again when `resultsMarker` is its `startedAt` (see `State.resultsMarker`).
    public static func start(
        set: VocabSet?, options: StudyOptions, saved: SessionState?, savedFeedback: PendingFeedback? = nil,
        subset: StudySubset? = nil, forceNew: Bool = false, resultsMarker: Double? = nil, env: Env
    ) -> (State, [Effect]) {
        var m = Machine(State(set: set, options: options), env)
        if set != nil {
            m.boot(saved: saved, feedback: savedFeedback, wanted: subset, forceNew: forceNew, marker: resultsMarker)
        }
        return m.finish()
    }

    /// `start` with the stored JSON of `LibraryStore.getSessionJSON` (session plus `feedback`).
    public static func start(
        set: VocabSet?, options: StudyOptions, stored: JSONValue?, subset: StudySubset? = nil, forceNew: Bool = false,
        resultsMarker: Double? = nil, env: Env
    ) -> (State, [Effect]) {
        let decoded = decodeStored(stored)
        return start(
            set: set, options: options, saved: decoded?.session, savedFeedback: decoded?.feedback, subset: subset,
            forceNew: forceNew, resultsMarker: resultsMarker, env: env)
    }

    /// Applies one event.
    public static func reduce(_ state: State, _ event: Event, env: Env) -> (State, [Effect]) {
        // Typing is by far the most frequent event: keep it cheap.
        if case let .inputChanged(text) = event {
            guard state.isInputEditable else { return (state, []) }
            var s = state
            s.input = text
            s.inputInvalid = false
            // The copy typed out continues by itself after a short beat, like Return (`CopyStep`).
            guard s.phase == .copy else { return (s, []) }
            var m = Machine(s, env)
            m.continueTypedOutCopy()
            return m.finish()
        }
        var m = Machine(state, env)
        m.handle(event)
        return m.finish()
    }

    /// The label of what Return does now (for the ↩ hint); nil when Return does nothing here.
    public static func returnAction(_ state: State) -> String? {
        if state.isBlocked { return nil }
        switch state.phase {
        case .starting: return nil
        case .question: return L("Antworten")
        case .feedback, .copy: return L("Weiter")
        case .summary:
            return L("Weiter zu Runde %@", "\((state.summary?.round ?? state.session?.round ?? 1) + 1)")
        case .results: return state.results?.canRetry == true ? L("Falsche nochmal üben") : L("Fertig")
        case .empty: return emptyMessage(for: state.emptySubset ?? .all).primaryLabel
        case .missing: return missingMessage.primaryLabel
        }
    }

    /// The text next to the ↩ key hint on the card ("zum Antworten", …); nil where the button
    /// label says it all.
    public static func returnHint(_ state: State) -> String? {
        if state.isBlocked { return nil }
        switch state.phase {
        case .question: return L("zum Antworten")
        case .feedback(.correct): return state.autoAdvance != nil ? L("Weiter mit beliebiger Taste") : L("zum Weitermachen")
        case .copy: return L("zum Prüfen")
        default: return nil
        }
    }

    /// Whether study time counts now (write.js `studying`): a running session on the card or the
    /// round summary.
    public static func isStudying(_ state: State) -> Bool {
        guard let session = state.session, session.finishedAt == nil else { return false }
        return state.phase.isCard || state.phase == .summary
    }

    /// "Verbleibend / Falsch / Richtig" and the round of the sidebar.
    public static func counters(_ state: State) -> WriteSession.Counters? {
        state.session.map(WriteSession.counters)
    }

    /// The card the editor edits (`Overlay.editor`).
    public static func editorCard(_ state: State) -> Card? {
        guard case let .editor(question, _, _)? = state.overlay else { return nil }
        return state.set?.cards.first { $0.id == question.cardId }
    }
}

extension WriteFlow.State {
    /// Whether `other` differs from this state in the answer field's text (`input`) alone: the
    /// app then updates only the field instead of every view that shows the state.
    public func differsOnlyInInput(from other: Self) -> Bool {
        guard input != other.input else { return false }
        var same = other
        same.input = input
        return same == self
    }
}
