import Foundation

// The Learn screen as a pure reducer (spec §6): a port of the screen logic of the web app's Learn
// mode (src/screens/learn.js, learn-answer.js, learn-dialogs.js, learn-keys.js and the decisions
// in learn-mc.js / learn-views.js) on top of LearnEngine. SwiftUI views render `State` and forward
// user input as `Event`s; every side effect (store writes, speech, haptics, VoiceOver
// announcements, timers, navigation) comes back as an `Effect` for the app to perform.
//
// Keys (spec §4.3):
// - Multiple choice: ↑↓←→ move the highlight (none at first, the first arrow lands on option 1),
//   Return chooses the highlighted option, 1–4 choose directly, 0 or ⌥↩ = "Weiss ich nicht".
//   Typing letters highlights the one option they start ("la vo" → la voiture, see
//   `typeAhead`); ⌫ deletes a letter (held: one after another), ⌥⌫ a word, esc clears them.
// - Written: Return submits the answer field (`draft`), ⌥↩ = "Weiss ich nicht".
// - Feedback: Return = Weiter (a correct answer also advances by itself); after multiple choice
//   any key continues, after a correct written answer any key continues and starts typing the
//   next written answer. ⌘↩ = "Ich hatte recht" after a written miss.
// - Copy step (Abtippen, `learn.retype`): Return checks the copy field and continues when right.
// - Checkpoint: Return = Weiter zu Runde N. Finish: Return = Fertig. Esc leaves (back to the set).
// One key press causes at most one transition: repeats never transition, and presses within
// `INPUT_LOCK_MS` after a transition are swallowed (like the web app's Enter lock).

/// The Learn screen's reducer (spec §6). See the file header for the key map.
public enum LearnFlow {
    // MARK: - State

    public enum FeedbackKind: String, Codable, Sendable, Equatable, Hashable {
        case correct, wrong, dontKnow
    }

    /// What the screen shows.
    public enum Phase: Codable, Sendable, Equatable, Hashable {
        /// A question: multiple choice tiles or the written answer field.
        case question(QuestionType)
        /// The answer's feedback (praise with auto-advance, or "Nicht ganz" / "Kein Problem").
        case feedback(FeedbackKind)
        /// A written miss with the copy step on: the right answer has to be typed once.
        case copy
        /// "Runde N geschafft" after each round.
        case checkpoint
        /// Every card in scope is mastered: celebration and stats.
        case finished
        /// Everything in scope was already mastered at the start.
        case allMastered
        /// Nothing to study (no usable cards, or none in the requested subset).
        case empty
    }

    /// The question on screen (`questionInfo` of write-model.js plus the options).
    public struct QuestionInfo: Codable, Sendable, Equatable, Hashable {
        public var qid: String
        public var cardId: String
        public var type: QuestionType
        public var ask: AskSide
        public var prompt: String
        /// The asked card's answer.
        public var expected: String
        public var promptLang: Lang
        public var answerLang: Lang
        /// "Französisch", or "Definition"/"Begriff" when both sides share a language.
        public var promptLabel: String
        public var placeholder: String
        public var placeholderShort: String
        public var starred: Bool
        /// The options on screen (multiple choice), texts from the current cards; [] for written.
        public var choices: [Choice]
        /// The options as stored in the session.
        public var storedChoices: [Choice]
        /// A repetition question (Wiederholungsfrage) of a card mastered before the session.
        public var isReview: Bool

        public init(
            qid: String, cardId: String, type: QuestionType, ask: AskSide, prompt: String, expected: String,
            promptLang: Lang, answerLang: Lang, promptLabel: String, placeholder: String, placeholderShort: String,
            starred: Bool, choices: [Choice], storedChoices: [Choice], isReview: Bool = false
        ) {
            self.qid = qid
            self.cardId = cardId
            self.type = type
            self.ask = ask
            self.prompt = prompt
            self.expected = expected
            self.promptLang = promptLang
            self.answerLang = answerLang
            self.promptLabel = promptLabel
            self.placeholder = placeholder
            self.placeholderShort = placeholderShort
            self.starred = starred
            self.choices = choices
            self.storedChoices = storedChoices
            self.isReview = isReview
        }

        /// The question for the synonym check (`ExtendedSynonyms`).
        public var synonymQuery: SynonymQuery {
            SynonymQuery(prompt: prompt, expected: expected, promptLang: promptLang, answerLang: answerLang)
        }
    }

    /// The result of the last answer, as the feedback shows it.
    public struct Feedback: Codable, Sendable, Equatable, Hashable {
        public var kind: FeedbackKind
        /// Praise ("Super!"), "Auch richtig!", "Richtig!", `MISS_TITLE` or `DONT_KNOW_TITLE`.
        public var title: String
        /// Multiple choice: the right option and the learner's pick (nil = "Weiss ich nicht").
        public var correctIndex: Int?
        public var chosenIndex: Int?
        /// Written: what was typed (trimmed; "" for "Weiss ich nicht") and its grade (nil for
        /// "Weiss ich nicht"). Show "Deine Antwort" with `Grading.diffAnswer(given, expected)`.
        public var given: String
        public var result: GradeResult?
        /// The answer was right for another card with the same prompt.
        public var synonym: Bool
        /// A correct but not exact answer: "Genau:" / "Gesucht war:" before
        /// `result.expectedDisplay`.
        public var exactLabel: String?
        /// The hint chip after a written miss (`Labels.HINT_LABELS`).
        public var hint: String?
        /// "Ich hatte recht" is offered (a written miss with an answer).
        public var canOverride: Bool
        /// The edited card now accepts what was typed ("Als richtig zählen").
        public var editedCorrect: Bool
        /// The copy step is on for this miss.
        public var copy: Bool
        /// The auto-advance delay of a correct answer (for the countdown).
        public var autoAdvanceMs: Int?
        /// A repetition question was missed: the card is learned again ("Wieder am Lernen").
        public var demoted: Bool

        public init(
            kind: FeedbackKind, title: String = "", correctIndex: Int? = nil, chosenIndex: Int? = nil, given: String = "",
            result: GradeResult? = nil, synonym: Bool = false, exactLabel: String? = nil, hint: String? = nil,
            canOverride: Bool = false, editedCorrect: Bool = false, copy: Bool = false, autoAdvanceMs: Int? = nil,
            demoted: Bool = false
        ) {
            self.kind = kind
            self.title = title
            self.correctIndex = correctIndex
            self.chosenIndex = chosenIndex
            self.given = given
            self.result = result
            self.synonym = synonym
            self.exactLabel = exactLabel
            self.hint = hint
            self.canOverride = canOverride
            self.editedCorrect = editedCorrect
            self.copy = copy
            self.autoAdvanceMs = autoAdvanceMs
            self.demoted = demoted
        }
    }

    /// The open "Nicht ganz" screen, stored next to the Learn state (web: `feedback`) so that a
    /// relaunch shows it again with "Ich hatte recht" and the copy step. JSON as in the web app:
    /// multiple choice `{qid, cardId, type: "mc", ask, choices, chosen}` (chosen = card id or
    /// null for "Weiss ich nicht"), written `{qid, cardId, type: "written", ask, given, dontKnow}`.
    public struct PendingFeedback: Codable, Sendable, Equatable, Hashable {
        public var qid: String
        public var cardId: String
        public var type: QuestionType
        public var ask: AskSide
        public var choices: [Choice]?
        public var chosen: String?
        public var given: String?
        public var dontKnow: Bool?

        public init(mcQid qid: String, cardId: String, ask: AskSide, choices: [Choice], chosen: String?) {
            self.qid = qid
            self.cardId = cardId
            self.type = .mc
            self.ask = ask
            self.choices = choices
            self.chosen = chosen
        }

        public init(writtenQid qid: String, cardId: String, ask: AskSide, given: String, dontKnow: Bool) {
            self.qid = qid
            self.cardId = cardId
            self.type = .written
            self.ask = ask
            self.given = given
            self.dontKnow = dontKnow
        }

        enum CodingKeys: String, CodingKey { case qid, cardId, type, ask, choices, chosen, given, dontKnow }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(qid, forKey: .qid)
            try c.encode(cardId, forKey: .cardId)
            try c.encode(type, forKey: .type)
            try c.encode(ask, forKey: .ask)
            if type == .mc {
                try c.encode(choices ?? [], forKey: .choices)
                try c.encodeNullable(chosen, forKey: .chosen)
            } else {
                try c.encode(given ?? "", forKey: .given)
                try c.encode(dontKnow ?? false, forKey: .dontKnow)
            }
        }
    }

    /// A stored Learn session as the store keeps it (`learn:<setId>`): the state plus the raw
    /// `feedback` record of an open "Nicht ganz" screen (validated on resume).
    public struct SavedLearn: Sendable, Equatable {
        public var state: LearnState
        public var feedback: JSONValue?

        public init(state: LearnState, feedback: PendingFeedback? = nil) {
            self.state = state
            self.feedback = feedback.flatMap { try? JSONValue(encoding: $0) }
        }

        public init(state: LearnState, feedbackJSON: JSONValue?) {
            self.state = state
            self.feedback = feedbackJSON
        }

        /// A stored JSON object (repaired with `LearnEngine.copyState`); nil for anything else.
        public init?(json: JSONValue) {
            guard json.isObject else { return nil }
            state = LearnEngine.copyState(json)
            feedback = json["feedback"]
        }

        /// The JSON to store (`LibraryStore.saveLearnJSON`): the state with `feedback` next to it.
        public func json() throws -> JSONValue {
            var o = try JSONValue(encoding: state).objectValue ?? [:]
            if let feedback, feedback != .null { o["feedback"] = feedback }
            return .object(o)
        }
    }

    /// A confirmation the view shows as an alert (see `promptContent`). Keys are ignored while it
    /// is open; answer it with `.promptAnswered(confirmed:)`.
    public enum Prompt: Codable, Sendable, Equatable, Hashable {
        /// "Neu starten?" (⇧⌘R in a running session).
        case restartSession
        /// Options that only apply to a new session were changed.
        case restartForOptions([SettingsChange])
        /// "Fortschritt zurücksetzen?" before learning these cards again.
        case relearn(cardIds: [String])
        /// "Laufende Lerneinheit beenden?" when another subset was asked for.
        case replaceSession(StudySubset)
    }

    public struct PromptContent: Sendable, Equatable, Hashable {
        public var title: String
        public var message: String
        public var confirmLabel: String
        public var cancelLabel: String
        /// Destructive: the cancel button is the default.
        public var isDestructive: Bool
    }

    /// A sheet or popover over the screen; keys are ignored and the auto-advance pauses while it
    /// is open.
    public enum Overlay: String, Codable, Sendable, Equatable, Hashable {
        /// The Learn options; on dismissal a change that needs a new session asks to restart.
        case options
        /// The card editor (⌘E).
        case editor
        case other
    }

    /// Where the app should go.
    public enum Destination: String, Codable, Sendable, Equatable, Hashable {
        /// Back to the set (Esc, "Fertig", "Zurück zum Lernset").
        case set
        /// Write mode with a new session ("Schreiben üben").
        case write
        /// The set editor ("Begriffe hinzufügen").
        case editSet
    }

    /// How a multiple-choice option is drawn. `filtered`: the letters typed do not start it.
    public enum OptionState: String, Codable, Sendable, Equatable, Hashable {
        case idle, highlighted, filtered, correct, wrong, dimmed
    }

    /// Everything the Learn screen renders.
    public struct State: Codable, Sendable, Equatable {
        public var phase: Phase
        /// The engine state; nil while no session runs (`.empty`, `.allMastered`).
        public var session: LearnState?
        public var setId: String
        public var setTitle: String
        public var termLang: Lang
        public var defLang: Lang
        /// The set's current cards.
        public var cards: [Card]
        /// The study options in effect (tolerance, audio and the copy step apply at once).
        public var options: StudyOptions
        /// New sessions ask repetition questions (Wiederholungsfragen, `LearnReview`); a running
        /// session keeps what it was started with.
        public var review: Bool
        /// The scope (the session's subset, or the requested one on the message screens).
        public var subset: StudySubset
        /// `.allMastered`: the scope's cards (reset by "Fortschritt zurücksetzen und neu lernen").
        public var scopeCardIds: [String]
        public var question: QuestionInfo?
        public var feedback: Feedback?
        /// The highlighted multiple-choice option (0-based), nil = none.
        public var highlighted: Int?
        /// The letters typed on a multiple-choice question (`typeAhead`), "" = none.
        public var typed: String
        /// The answer field (written question) or the copy field (copy step).
        public var draft: String
        /// The open "Nicht ganz" record stored next to the session.
        public var pending: PendingFeedback?
        /// Counts when the round started: the checkpoint bar grows from there (nil: no animation).
        public var roundStartCounts: LearnEngine.Counts?
        public var prompt: Prompt?
        public var overlay: Overlay?
        public var optionsBeforeOverlay: StudyOptions?
        public var reviewBeforeOverlay: Bool?
        /// The running auto-advance timer (`.scheduleAutoAdvance`), nil = none.
        public var autoAdvanceToken: Int?
        public var lastToken: Int
        /// An overlay or prompt interrupted the auto-advance; it restarts when they close.
        public var autoAdvancePaused: Bool
        public var lastPraise: String?
        /// Key presses before this time (epoch ms) are swallowed.
        public var inputLockedUntil: Double
        /// Increases when an empty answer or a wrong copy is rejected (shake trigger).
        public var rejections: Int
        /// Increases with every transition (new question, feedback, checkpoint, finish, message).
        public var transitions: Int

        public init(
            phase: Phase, session: LearnState?, setId: String, setTitle: String, termLang: Lang, defLang: Lang,
            cards: [Card], options: StudyOptions, subset: StudySubset, review: Bool = false
        ) {
            self.phase = phase
            self.session = session
            self.setId = setId
            self.setTitle = setTitle
            self.termLang = termLang
            self.defLang = defLang
            self.cards = cards
            self.options = options
            self.subset = subset
            self.review = review
            scopeCardIds = []
            typed = ""
            draft = ""
            lastToken = 0
            autoAdvancePaused = false
            inputLockedUntil = 0
            rejections = 0
            transitions = 0
        }

        /// Neu · Am Lernen · Gemeistert of the session (zeros without one).
        public var counts: LearnEngine.Counts {
            session.map(LearnEngine.counts) ?? LearnEngine.Counts(fresh: 0, learning: 0, mastered: 0, total: 0, progress: 0)
        }

        /// The round on screen ("Runde N").
        public var round: Int { session?.round ?? 1 }

        /// The checkpoint of the current round.
        public var checkpoint: LearnEngine.Checkpoint? { session.map(LearnEngine.checkpoint) }

        /// The final statistics (finish screen).
        public var finalStats: LearnEngine.FinalStats? { session.map(LearnEngine.finalStats) }

        /// Segments of the progress bar.
        public var segments: Int {
            LearnFlow.segmentCount(total: counts.total, roundSize: session?.learn.roundSize)
        }

        /// Whether study time counts now (send `.tick` periodically and on leaving).
        public var isStudying: Bool {
            guard let session, session.finishedAt == nil else { return false }
            switch phase {
            case .question, .feedback, .copy, .checkpoint: return true
            case .finished, .allMastered, .empty: return false
            }
        }

        /// A question or its feedback is on screen.
        public var isStudyStep: Bool {
            switch phase {
            case .question, .feedback, .copy: true
            default: false
            }
        }

        /// "Multiple Choice first, written next time" (until the view's dismissal or the first
        /// checkpoint): only while both question types are on.
        public var showsIntroHint: Bool {
            guard case .question = phase, let session else { return false }
            // A session of repetition questions without new cards has nothing to introduce.
            if session.review != nil && counts.fresh == 0 { return false }
            return session.learn.mc && session.learn.written && session.rounds.isEmpty
        }
    }

    // MARK: - Events and effects

    public enum Event: Sendable, Equatable {
        /// A key press; repeats never cause a transition.
        case key(KeyInput, isRepeat: Bool = false)
        /// A click on option `i` (0-based).
        case choose(Int)
        /// The pointer highlights an option (nil = none).
        case highlight(Int?)
        /// The answer or copy field changed.
        case draftChanged(String)
        /// Return in the answer or copy field with its text (like `.key(.returnKey)`).
        case submit(String)
        /// "Weiss ich nicht?" was clicked.
        case dontKnow
        /// The screen's primary button was clicked (Weiter, Antworten, Fertig, …).
        case proceed
        /// "Ich hatte recht" (⌘↩ or its button).
        case override
        /// Vorlesen (⌘R): the prompt.
        case speakPrompt
        /// Markieren (⌘D): star the card on screen.
        case toggleStar
        /// The card editor saved this card (⌘E, Bearbeiten).
        case editCard(Card)
        /// The study options changed (options popover or settings).
        case optionsChanged(StudyOptions)
        /// "Wiederholungsfragen" was switched (applies to new sessions; see `State.review`).
        case reviewChanged(Bool)
        /// "Alle wiederholen" on the everything-mastered screen: a session of repetition
        /// questions over the scope.
        case startReview
        /// The set changed elsewhere (title, languages, cards).
        case setChanged(VocabSet)
        /// The set's cards changed elsewhere (edited, added, deleted).
        case cardsChanged([Card])
        /// The stored progress changed elsewhere (`Env.progress`), e.g. in Write mode.
        case progressChanged
        case overlayPresented(Overlay)
        case overlayDismissed
        case promptAnswered(confirmed: Bool)
        /// Neu starten (⇧⌘R): asks first; on the finish screen it is "Nochmal lernen".
        case restart
        /// "Nochmal lernen" / "Fortschritt zurücksetzen und neu lernen" (asks first).
        case relearn
        /// "Alle Begriffe üben" on the empty screen.
        case studyAll
        /// A `.scheduleAutoAdvance` timer fired; stale tokens are ignored.
        case autoAdvanceFired(token: Int)
        /// Periodic clock tick while studying (the web app ticks every 15 s).
        case tick
        /// The window is active again after a pause: the time away is not study time.
        case resume
        /// Leave the screen (Esc, back button): saves the clock and navigates to the set.
        case exit
    }

    public enum Effect: Sendable, Equatable {
        /// `LibraryStore.recordAnswer(setId, cardId, correct:, at:)`.
        case recordAnswer(cardId: String, correct: Bool, at: Double)
        /// `LibraryStore.overrideLastAnswer(setId, cardId)`.
        case overrideLastAnswer(cardId: String)
        /// `resetProgress(setId)` (nil) or `resetCardProgress(setId, cardIds)`.
        case resetProgress(cardIds: [String]?)
        /// Store the session: `saveLearnJSON(setId, SavedLearn(state:feedback:).json())`.
        case saveLearn(LearnState, feedback: PendingFeedback?)
        case clearLearn
        case speak(text: String, lang: Lang)
        case haptic(HapticKind)
        /// Send `.autoAdvanceFired(token:)` after `ms` milliseconds.
        case scheduleAutoAdvance(ms: Int, token: Int)
        /// A VoiceOver announcement.
        case announce(String)
        case toast(String, tone: Tone)
        /// `LibraryStore.updateCard` with the edited card.
        case updateCard(Card)
        /// `LibraryStore.toggleStar(setId, cardId)`.
        case toggleStar(cardId: String)
        case navigate(Destination)
    }

    /// What a reduction may read besides the state: randomness, the time, the stored progress and
    /// the synonyms found outside the set.
    public struct Env {
        public var rng: RNG
        /// Epoch ms.
        public var now: Double
        /// The set's stored progress (after every effect applied so far).
        public var progress: ProgressMap
        /// Words with the same meaning as a question's answer that are not in the set
        /// (`ExtendedSynonyms`); a written answer matching one counts as right.
        public var extraAnswers: (SynonymQuery) -> [String]

        public init(
            rng: @escaping RNG = systemRNG(), now: Double = TimeUtil.nowMs(), progress: ProgressMap = [:],
            extraAnswers: @escaping (SynonymQuery) -> [String] = { _ in [] }
        ) {
            self.rng = rng
            self.now = now
            self.progress = progress
            self.extraAnswers = extraAnswers
        }
    }

    // MARK: - API

    /// Opens the Learn screen for `set`: resumes `saved` (with its open "Nicht ganz" screen and
    /// the answers given elsewhere since) unless `forceNew`, the saved session is finished or a
    /// different `subset` is asked for; otherwise starts a new session over `subset` (nil = the
    /// whole set). A requested subset never silently ends a session with answers: it asks first.
    public static func start(
        set: VocabSet, progress: ProgressMap, options: StudyOptions, saved: SavedLearn? = nil,
        subset: StudySubset? = nil, forceNew: Bool = false, review: Bool = false, rng: @escaping RNG = systemRNG(),
        now: Double = TimeUtil.nowMs()
    ) -> (State, [Effect]) {
        let state = State(
            phase: .empty, session: nil, setId: set.id, setTitle: set.title, termLang: set.termLang,
            defLang: set.defLang, cards: set.cards, options: options, subset: subset ?? .all, review: review)
        var m = Machine(state, env: Env(rng: rng, now: now, progress: progress))
        m.boot(saved: saved, wanted: subset, forceNew: forceNew)
        return m.result()
    }

    /// One event: the new state and the effects to perform, in order.
    public static func reduce(_ state: State, _ event: Event, env: Env) -> (State, [Effect]) {
        var m = Machine(state, env: env)
        m.handle(event)
        return m.result()
    }

    /// The German label of what Return does now (for the ↩ hint and the primary button), nil when
    /// Return does nothing.
    public static func returnAction(_ state: State) -> String? {
        guard state.prompt == nil, state.overlay == nil else { return nil }
        switch state.phase {
        case .question(.mc): return state.highlighted == nil ? nil : "Auswählen"
        case .question(.written): return "Antworten"
        case .feedback, .copy: return "Weiter"
        case .checkpoint: return "Weiter zu Runde \(state.round + 1)"
        case .finished: return "Fertig"
        case .allMastered: return "Fortschritt zurücksetzen und neu lernen"
        case .empty: return state.subset == .all ? "Begriffe hinzufügen" : "Alle Begriffe üben"
        }
    }

    /// The label of the override button: "Ich hatte recht", or "Als richtig zählen" when the
    /// edited card now accepts the answer; nil when not offered.
    public static func overrideLabel(_ state: State) -> String? {
        guard let f = state.feedback, f.canOverride, state.question?.type == .written else { return nil }
        switch state.phase {
        case .feedback(.wrong), .copy: return f.editedCorrect ? "Als richtig zählen" : "Ich hatte recht"
        default: return nil
        }
    }

    /// How option `index` of the multiple-choice question is drawn.
    public static func optionState(_ state: State, at index: Int) -> OptionState {
        switch state.phase {
        case .question(.mc):
            if state.highlighted == index { return .highlighted }
            guard !state.typed.isEmpty else { return .idle }
            let match = typeAhead(state)
            return match.isActive && !match.matching.isEmpty && !match.matching.contains(index) ? .filtered : .idle
        case .feedback:
            guard let f = state.feedback, state.question?.type == .mc else { return .idle }
            if index == f.correctIndex { return .correct }
            return index == f.chosenIndex ? .wrong : .dimmed
        default:
            return .idle
        }
    }

    /// Title, message and buttons of the open prompt.
    public static func promptContent(_ state: State) -> PromptContent? {
        guard let prompt = state.prompt else { return nil }
        switch prompt {
        case .restartSession:
            return PromptContent(
                title: "Neu starten?", message: restartSessionMessage(state.session?.subset ?? state.subset),
                confirmLabel: "Neu starten", cancelLabel: "Abbrechen", isDestructive: false)
        case let .restartForOptions(changes):
            return PromptContent(
                title: "Neu starten?", message: restartMessage(changes), confirmLabel: "Neu starten",
                cancelLabel: "Später", isDestructive: false)
        case let .relearn(ids):
            let n = ids.count
            return PromptContent(
                title: "Fortschritt zurücksetzen?",
                message: "Der Lernfortschritt \(n == 1 ? "dieses Begriffs" : "dieser \(n) Begriffe") wird zurückgesetzt. "
                    + "Danach lernst du \(n == 1 ? "ihn" : "sie") von vorne – zuerst mit Multiple Choice.",
                confirmLabel: "Zurücksetzen", cancelLabel: "Abbrechen", isDestructive: true)
        case let .replaceSession(wanted):
            return PromptContent(
                title: "Laufende Lerneinheit beenden?",
                message: "Deine gespeicherte Lerneinheit endet, wenn du jetzt \(subsetWhat(wanted)) lernst. "
                    + "Dein Lernfortschritt bleibt erhalten.",
                confirmLabel: "Neu beginnen", cancelLabel: "Fortsetzen", isDestructive: false)
        }
    }

    /// The message screens (`.empty`, `.allMastered`).
    public struct MessageContent: Sendable, Equatable, Hashable {
        public var systemImage: String
        public var title: String
        public var text: String
        /// The Return action (same as `returnAction`).
        public var primaryLabel: String
        /// "Schreiben üben" is offered.
        public var offersWrite: Bool
        /// "Alle wiederholen" is offered (`Event.startReview`).
        public var offersReview = false
    }

    public static func message(_ state: State) -> MessageContent? {
        switch state.phase {
        case .allMastered:
            return MessageContent(
                systemImage: "trophy.fill", title: "Alles gemeistert!",
                text: "Du beherrschst bereits \(scopeText(state.subset, count: state.scopeCardIds.count)). "
                    + "Wiederhole sie, um zu prüfen, ob sie noch sitzen, setz den Fortschritt zurück, um nochmal von "
                    + "vorne zu lernen, oder übe sie schriftlich.",
                primaryLabel: "Fortschritt zurücksetzen und neu lernen", offersWrite: true, offersReview: true)
        case .empty:
            let all = "Alle Begriffe üben"
            switch state.subset {
            case .starred:
                return MessageContent(
                    systemImage: "star", title: "Keine markierten Begriffe",
                    text: "Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben.", primaryLabel: all,
                    offersWrite: false)
            case .learning:
                return MessageContent(
                    systemImage: "trophy.fill", title: "Alles gemeistert!",
                    text: "Du beherrschst bereits alle Begriffe in diesem Lernset. "
                        + "Übe trotzdem alle, damit sie frisch bleiben.", primaryLabel: all, offersWrite: false)
            case .missed, .cardIds:
                return MessageContent(
                    systemImage: "checkmark.circle", title: "Keine falschen Begriffe",
                    text: "Hier gibt es gerade nichts nachzuholen.", primaryLabel: all, offersWrite: false)
            case .all:
                return MessageContent(
                    systemImage: "square.stack.3d.up", title: "Noch keine Begriffe zum Üben",
                    text: "Füge diesem Lernset Begriffe mit Übersetzung hinzu, dann kann es losgehen.",
                    primaryLabel: "Begriffe hinzufügen", offersWrite: false)
            }
        default:
            return nil
        }
    }
}
