import AppKit
import Observation
import SwiftUI
import WortschatzCore

/// Runs one Learn screen (spec §4.4, §6): holds the `LearnFlow` state, reduces every event with
/// the freshly stored progress and performs the reducer's effects in order (store writes, speech,
/// haptics, VoiceOver announcements, toasts, the auto-advance timer and navigation).
///
/// The view only renders `state` and calls `send(_:)`; it never changes the state itself.
@MainActor
@Observable
final class LearnController {
    let setID: String
    private(set) var state: LearnFlow.State
    private(set) var countdown: StudyCountdown?
    /// Correct answers in a row while this screen is open (the flame in the action bar).
    private(set) var streak = AnswerStreak()
    /// An otherwise wrong written answer is being looked up as a synonym outside the set
    /// (`SynonymAssistant`); it is submitted once that is known.
    private(set) var isCheckingSynonym = false
    /// Read-aloud for the prompt, the answer and the audio option (the app's shared service).
    let speech: SpeechService

    /// Whether the window is active (the study clock only runs then).
    @ObservationIgnored private var isWindowActive = true

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let requestID: UUID
    @ObservationIgnored private let rng: RNG
    @ObservationIgnored private let clock: () -> Double
    /// Off for the snapshot harness: no timers, speech, haptics or announcements.
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var pendingStartEffects: [LearnFlow.Effect]
    @ObservationIgnored private var timers: [Int: Task<Void, Never>] = [:]
    /// Toasts held back while the screen is still invisible ("Willkommen zurück" must not pop
    /// up over an empty backdrop); nil when toasts show at once.
    @ObservationIgnored private var heldToasts: [(text: String, tone: LearnFlow.Tone)]?
    /// The running synonym check (a stale one is ignored).
    @ObservationIgnored private var synonymCheck: UUID?
    /// The written question whose prompt translations were requested.
    @ObservationIgnored private var prefetchedQid: String?

    /// How often the study clock is saved while studying (the web app's 15 s tick).
    static let clockInterval: Duration = .seconds(15)
    /// `UserDefaults` key of "Wiederholungsfragen" (Optionen, the same for every set).
    static let reviewKey = "learn.review"
    /// `UserDefaults` key of "Nachkontrolle nach Fehlern" (Optionen, the same for every set; on
    /// until switched off).
    static let recheckKey = "learn.recheck"

    /// Whether "Nachkontrolle nach Fehlern" is on (the default when it was never switched).
    static var recheckIsOn: Bool {
        UserDefaults.standard.object(forKey: recheckKey) as? Bool ?? true
    }

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
        let store = model.store
        let set = store.getSet(request.setID) ?? VocabSet(id: request.setID, title: "", createdAt: 0)
        let saved = store.getLearnJSON(request.setID).flatMap(LearnFlow.SavedLearn.init(json:))
        let (state, effects) = LearnFlow.start(
            set: set, progress: store.getProgress(request.setID), options: store.getStudyOptions(request.setID),
            saved: saved, subset: request.subset, forceNew: request.forceNew,
            review: request.reviewMastered || UserDefaults.standard.bool(forKey: Self.reviewKey),
            recheck: Self.recheckIsOn, rng: rng, now: clock())
        self.state = state
        pendingStartEffects = effects
    }

    // MARK: Lifecycle

    /// Performs the effects of opening the screen (saving a new session, "Willkommen zurück", …).
    /// Called once when the screen appears. From then on the route resumes this session, should
    /// the screen be built again (window closed and reopened).
    /// `holdingToasts`: its toasts wait for `releaseToasts()` (the screen is not visible yet).
    func activate(holdingToasts: Bool = false) {
        let effects = pendingStartEffects
        pendingStartEffects = []
        if holdingToasts { heldToasts = [] }
        perform(effects)
        model.studySessionStarted(requestID: requestID)
        if isLive { SoundEffects.shared.prepare() }
        prefetchSynonyms()
    }

    /// The screen is on screen now: the toasts held back by `activate(holdingToasts:)` show.
    func releaseToasts() {
        let toasts = heldToasts ?? []
        heldToasts = nil
        for toast in toasts { showToast(toast.text, tone: toast.tone) }
    }

    /// The screen went away (back button, another route): keeps the study time and stops
    /// timers and speech.
    func deactivate() {
        heldToasts = nil
        synonymCheck = nil
        isCheckingSynonym = false
        // The last tick, also when the screen is no longer the current one.
        if state.isStudying { reduce(.tick) }
        for timer in timers.values { timer.cancel() }
        timers = [:]
        countdown = nil
        speech.stop()
    }

    /// Saves the study clock every `clockInterval` while studying in the active window.
    func runClock() async {
        guard isLive else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.clockInterval)
            guard !Task.isCancelled else { return }
            if isWindowActive && state.isStudying { send(.tick) }
        }
    }

    /// The window became active or inactive: time away is not study time.
    func windowActivityChanged(_ active: Bool) {
        isWindowActive = active
        guard state.isStudying else { return }
        send(active ? .resume : .tick)
    }

    // MARK: Events

    /// Reduces one event with the current store progress and performs its effects. An otherwise
    /// wrong written answer is first looked up as a synonym outside the set. A screen dissolving
    /// after Lernen was left (`isCurrent`) takes no more events: no keys, clicks, auto-advances.
    func send(_ event: LearnFlow.Event) {
        guard isCurrent else { return }
        if holdsForSynonymCheck(event) { return }
        reduce(event)
    }

    private func reduce(_ event: LearnFlow.Event) {
        let query = state.question?.synonymQuery
        let extras = isLive && Self.mayGrade(event) ? query.map(synonyms.extraAnswers(for:)) ?? [] : []
        let env = LearnFlow.Env(
            rng: rng, now: clock(), progress: store.getProgress(setID), extraAnswers: { $0 == query ? extras : [] })
        let previousPhase = state.phase
        let (next, effects) = LearnFlow.reduce(state, event, env: env)
        if next != state { state = next }
        perform(effects)
        if isLive { playSound(for: effects, after: previousPhase) }
        prefetchSynonyms()
    }

    /// The sound of a step (`SoundEffects.playStudyStep`).
    private func playSound(for effects: [LearnFlow.Effect], after previousPhase: LearnFlow.Phase) {
        let answer = effects.lazy.compactMap { effect -> SoundEffects.StudyAnswer? in
            switch effect {
            case let .recordAnswer(_, correct, _):
                correct ? .correct : self.state.feedback?.kind == .dontKnow ? .dontKnow : .wrong
            case .overrideLastAnswer: .correct
            default: nil
            }
        }.first
        SoundEffects.shared.playStudyStep(
            finished: state.phase == .finished && previousPhase != .finished,
            roundDone: state.phase == .checkpoint && previousPhase != .checkpoint,
            answer: answer, reachedMilestone: streak.reachedMilestone)
    }

    /// Whether the screen is the one being studied (not one dissolving after Lernen was left).
    private var isCurrent: Bool {
        !isLive || model.route.study?.id == requestID
    }

    /// A key press from the screen's key handler or the answer field. After an answer, a letter
    /// typed with an input method continues without typing it (`LearnKeyRouter.continuing`).
    func press(_ key: KeyInput, isRepeat: Bool) {
        let afterAnswer = if case .feedback = state.phase { true } else { false }
        let key = LearnKeyRouter.continuing(key, afterAnswer: afterAnswer, inputMethod: InputSource.isInputMethodActive)
        send(.key(key, isRepeat: isRepeat))
    }

    /// Return in the answer or copy field. `onSubmit` runs while AppKit handles the key, so the
    /// current event tells whether it is an auto-repeat.
    func submitFromField() {
        press(.returnKey, isRepeat: Self.currentKeyIsRepeat)
    }

    /// A Lernen menu command (⌘↩, ⌥↩, ⌘K, ⌘R, ⌘D, ⇧⌘R, esc). Key equivalents keep their
    /// repeat flag, so a held key never causes two transitions.
    func handle(_ command: StudyCommand, showOptions: () -> Void) {
        guard isCurrent else { return }
        let event = NSApp.currentEvent
        let fromKey = event?.type == .keyDown
        let isRepeat = fromKey && (event?.isARepeat ?? false)
        switch command {
        case .override: send(fromKey ? .key(.commandReturn, isRepeat: isRepeat) : .override)
        case .dontKnow: send(fromKey ? .key(.optionReturn, isRepeat: isRepeat) : .dontKnow)
        case .exit: send(fromKey ? .key(.escape, isRepeat: isRepeat) : .exit)
        case .options: if !isRepeat { showOptions() }
        case .speak: if !isRepeat { send(.speakPrompt) }
        case .toggleStar: if !isRepeat { send(.toggleStar) }
        case .restart: if !isRepeat { send(.restart) }
        }
    }

    /// What the Lernen menu offers now.
    var enabledCommands: Set<StudyCommand> {
        let free = state.prompt == nil && state.overlay == nil
        guard free else { return [] }
        var commands: Set<StudyCommand> = [.exit]
        if canShowOptions { commands.insert(.options) }
        if case .question = state.phase { commands.insert(.dontKnow) }
        if LearnFlow.overrideLabel(state) != nil { commands.insert(.override) }
        if state.isStudyStep {
            commands.formUnion([.speak, .toggleStar])
        }
        switch state.phase {
        case .question, .feedback, .copy, .checkpoint, .finished, .allMastered: commands.insert(.restart)
        case .empty: break
        }
        return commands
    }

    /// The options apply to sessions: not offered on the message screens or under a prompt.
    var canShowOptions: Bool {
        guard state.prompt == nil else { return false }
        switch state.phase {
        case .allMastered, .empty: return false
        default: return true
        }
    }

    // MARK: Synonyms outside the set

    private var synonyms: SynonymAssistant { .shared }

    /// Events that may grade a written answer (the others need no synonyms).
    private static func mayGrade(_ event: LearnFlow.Event) -> Bool {
        switch event {
        case .key(.returnKey, _), .proceed, .submit: true
        default: false
        }
    }

    /// Return (or "Antworten") on a written answer that would be wrong: the answer waits while
    /// `SynonymAssistant` looks it up, then it is submitted (and counts if it means the same).
    /// Further answers wait for that too; everything else goes on.
    private func holdsForSynonymCheck(_ event: LearnFlow.Event) -> Bool {
        let given: String
        let fromField: Bool
        switch event {
        case .key(.returnKey, isRepeat: false), .proceed: (given, fromField) = (state.draft, true)
        case let .submit(text): (given, fromField) = (text, false)
        default: return false
        }
        guard case .question(.written) = state.phase else { return false }
        if isCheckingSynonym { return true }
        guard isLive, isCurrent, synonyms.isActive, state.prompt == nil, state.overlay == nil,
            clock() >= state.inputLockedUntil, let question = state.question
        else { return false }
        let query = question.synonymQuery
        let graded = LearnFlow.gradeQuestion(
            question, given: given, cards: state.cards, tolerance: state.options.tolerance,
            extraAnswers: synonyms.extraAnswers(for: query))
        guard synonyms.supports(query),
            ExtendedSynonyms.worthChecking(
                given: given, result: graded.result, query: query, card: state.cards.first { $0.id == question.cardId },
                cards: state.cards, ask: question.ask)
        else { return false }

        let id = UUID()
        synonymCheck = id
        isCheckingSynonym = true
        let tolerance = state.options.tolerance
        Task { [weak self] in
            await SynonymAssistant.shared.check(given, for: query, tolerance: tolerance)
            guard let self, synonymCheck == id else { return }
            synonymCheck = nil
            isCheckingSynonym = false
            // Typed on, answered otherwise or left in the meantime: nothing to submit.
            guard isCurrent, state.phase == .question(.written), state.question?.qid == question.qid,
                !fromField || state.draft == given
            else { return }
            reduce(.submit(given))
        }
        return true
    }

    /// A written question is on screen: its prompt's translations are looked up in the
    /// background, so an answer among them counts at once.
    private func prefetchSynonyms() {
        guard isLive, case .question(.written) = state.phase, let question = state.question,
            question.qid != prefetchedQid
        else { return }
        prefetchedQid = question.qid
        synonyms.prefetch(question.synonymQuery)
    }

    // MARK: Store

    /// The library changed (after any store write, also from elsewhere: the set editor, the
    /// settings): forwards what differs from the screen's state. Echoes of the screen's own
    /// writes match already and send nothing.
    func storeDidChange() {
        guard let set = store.getSet(setID) else { return }
        if set.title != state.setTitle || set.termLang != state.termLang || set.defLang != state.defLang
            || set.cards != state.cards
        {
            send(.setChanged(set))
        }
        let options = store.getStudyOptions(setID)
        if options != state.options { send(.optionsChanged(options)) }
        if let session = state.session, !LearnEngine.matchesProgress(session, progress: store.getProgress(setID)) {
            send(.progressChanged)
        }
    }

    /// The set editor sheet opened over the screen: keys and the auto-advance pause.
    func setEditorOpened() {
        guard state.overlay == nil else { return }
        send(.overlayPresented(.other))
    }

    /// The set editor closed: its changes apply, and "Begriffe hinzufügen" on the empty screen
    /// starts learning once the set has cards to ask.
    func setEditorClosed() {
        storeDidChange()
        if state.overlay == .other { send(.overlayDismissed) }
        if state.phase == .empty, state.subset == .all,
            state.cards.contains(where: { LearnText.hasText($0.term) && LearnText.hasText($0.definition) })
        {
            send(.studyAll)
        }
    }

    /// Writes an options change (popover) and applies it to the running session.
    func updateOptions(_ patch: StudyOptionsPatch) {
        do {
            let options = try store.updateStudyOptions(setID, patch)
            send(.optionsChanged(options))
        } catch {
            model.report(error, fallback: "Die Option konnte nicht gespeichert werden.")
        }
    }

    /// "Wiederholungsfragen" (Optionen): kept for every set. A running session asks to restart
    /// when the popover closes, like the other options that shape a session.
    func setReview(_ review: Bool) {
        UserDefaults.standard.set(review, forKey: Self.reviewKey)
        send(.reviewChanged(review))
    }

    /// "Nachkontrolle nach Fehlern" (Optionen): kept for every set, like `setReview`.
    func setRecheck(_ recheck: Bool) {
        UserDefaults.standard.set(recheck, forKey: Self.recheckKey)
        send(.recheckChanged(recheck))
    }

    /// The standard of every set (Einstellungen), for the note at the top of the options.
    var standardOptions: StudyOptions { model.settings.study }

    /// "Auf Standard zurücksetzen" (Optionen): this set follows the standard again; a running
    /// session asks to restart when the popover closes, like after any other change.
    func resetOptionsToStandard() {
        if let options = model.resetStudyOptions(setID: setID) { send(.optionsChanged(options)) }
    }

    /// The card of the question on screen (for the card editor).
    var currentCard: Card? {
        guard let id = state.question?.cardId else { return nil }
        return state.cards.first { $0.id == id }
    }

    /// Reads a text aloud (🔊 next to the right answer).
    func speak(_ text: String, lang: Lang) {
        guard isLive else { return }
        speech.speak(text, lang: lang)
    }

    // MARK: Navigation

    /// "Schreiben üben": a new Write session over the whole set.
    func practiceWriting() {
        speech.stop()
        model.study(.write, setID: setID, forceNew: true)
    }

    // MARK: Effects

    private func perform(_ effects: [LearnFlow.Effect]) {
        for effect in effects {
            switch effect {
            case let .recordAnswer(cardId, correct, at):
                streak.record(correct: correct)
                write { _ = try $0.recordAnswer(setID, cardId, correct: correct, at: at) }
            case let .overrideLastAnswer(cardId):
                streak.overrideMiss()
                write { _ = try $0.overrideLastAnswer(setID, cardId) }
            case let .resetProgress(cardIds):
                write { store in
                    if let cardIds {
                        _ = try store.resetCardProgress(setID, cardIds)
                    } else {
                        try store.resetProgress(setID)
                    }
                }
            case let .saveLearn(session, feedback):
                write { try $0.saveLearnJSON(setID, LearnFlow.SavedLearn(state: session, feedback: feedback).json()) }
            case .clearLearn:
                write { try $0.clearLearn(setID) }
            case let .speak(text, lang):
                if isLive { speech.speak(text, lang: lang) }
            case let .haptic(kind):
                if isLive { kind == .success ? Haptics.success() : Haptics.failure() }
            case let .scheduleAutoAdvance(ms, token):
                scheduleAutoAdvance(ms: ms, token: token)
            case let .announce(text):
                if isLive { Announcer.announce(text) }
            case let .toast(text, tone):
                if heldToasts != nil {
                    heldToasts?.append((text, tone))
                } else if isLive {
                    showToast(text, tone: tone)
                }
            case let .updateCard(card):
                write { _ = try $0.updateCard(setID, card.id, CardChanges(term: card.term, definition: card.definition)) }
            case let .toggleStar(cardId):
                write { store in
                    let starred = try store.toggleStar(setID, cardId)
                    if isLive { Announcer.announce(starred ? "Markiert" : "Markierung entfernt") }
                }
            case let .navigate(destination):
                navigate(destination)
            }
        }
    }

    private func write(_ change: (LibraryStore) throws -> Void) {
        do {
            try change(store)
        } catch {
            model.report(error)
        }
    }

    private func scheduleAutoAdvance(ms: Int, token: Int) {
        countdown = StudyCountdown(token: token, milliseconds: ms, start: .now)
        guard isLive else { return }
        timers[token]?.cancel()
        timers[token] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self else { return }
            timers[token] = nil
            // A stale token (answered by key in the meantime, overlay opened) is ignored.
            send(.autoAdvanceFired(token: token))
        }
    }

    private func showToast(_ text: String, tone: LearnFlow.Tone) {
        let symbol = text == LearnFlow.WELCOME_BACK ? "hand.wave.fill" : nil
        let mapped: ToastCenter.Toast.Tone =
            switch tone {
            case .neutral: .neutral
            case .success: .success
            case .warning: .warning
            }
        model.toasts.show(text, tone: mapped, systemImage: symbol, duration: .seconds(text == LearnFlow.WELCOME_BACK ? 3.5 : 2))
    }

    private func navigate(_ destination: LearnFlow.Destination) {
        guard isLive else { return }
        switch destination {
        case .set:
            speech.stop()
            model.finishStudy()
        case .write:
            practiceWriting()
        case .editSet:
            model.openEditor(.edit(setID: setID))
        }
    }

    private static var currentKeyIsRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }
}
