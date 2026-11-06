import AppKit
import Observation
import SwiftUI
import WortschatzCore

/// Runs one Write screen (spec §4.4 "Write", §6): holds the `WriteFlow` state, reduces every
/// event with the freshly stored progress and performs the reducer's effects in order (store
/// writes, speech, haptics, VoiceOver announcements, toasts, the auto-advance timer and
/// navigation).
///
/// The view only renders `state` and calls `send(_:)`; it never changes the state itself.
@MainActor
@Observable
final class WriteController {
    let setID: String
    private(set) var state: WriteFlow.State
    private(set) var countdown: StudyCountdown?
    /// Correct answers in a row while this screen is open (the flame in the action bar).
    private(set) var streak = AnswerStreak()
    /// An otherwise wrong answer is being looked up as a synonym outside the set
    /// (`SynonymAssistant`); it is submitted once that is known.
    private(set) var isCheckingSynonym = false
    /// Read-aloud for the prompt, the answer and the audio option (the app's shared service).
    let speech: SpeechService

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let requestID: UUID
    @ObservationIgnored private let rng: RNG
    @ObservationIgnored private let clock: () -> Double
    /// Off for the snapshot harness: no timers, speech, haptics, announcements or navigation.
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var pendingStartEffects: [WriteFlow.Effect]
    @ObservationIgnored private var timers: [Int: Task<Void, Never>] = [:]
    /// Toasts held back while the screen is still invisible ("Willkommen zurück" must not pop
    /// up over an empty backdrop); nil when toasts show at once.
    @ObservationIgnored private var heldToasts: [WriteFlow.Toast]?
    /// An auto-advance that came due while a sheet of the app (the set editor) covered the
    /// screen. WriteFlow has no event for outside sheets, so the controller holds it back and
    /// runs it again in full once the sheet is gone.
    @ObservationIgnored private var heldAutoAdvance: (token: Int, ms: Int)?
    /// The running synonym check (a stale one is ignored).
    @ObservationIgnored private var synonymCheck: UUID?
    /// The question whose prompt translations were requested.
    @ObservationIgnored private var prefetchedQid: String?
    /// Study clock (write-clock.js): the window is active, the last input, idle since then.
    @ObservationIgnored private var isWindowActive = true
    @ObservationIgnored private var lastActivity: Double
    @ObservationIgnored private var isIdle = false

    /// The finished session each study request showed, so the results come back when the same
    /// screen is rebuilt (the window was closed and reopened) instead of a new session starting
    /// (web: the history entry's `wrSession` marker).
    private static var resultsMarkers: [UUID: Double] = [:]

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
        let now = clock()
        lastActivity = now
        let env = WriteFlow.Env(now: now, rng: rng, progress: store.getProgress(request.setID))
        let (state, effects) = WriteFlow.start(
            set: store.getSet(request.setID), options: store.getStudyOptions(request.setID),
            stored: store.getSessionJSON(request.setID), subset: request.subset, forceNew: request.forceNew,
            resultsMarker: Self.resultsMarkers[request.id], env: env)
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
        rememberResults()
        model.studySessionStarted(requestID: requestID)
        if isLive { SoundEffects.shared.prepare() }
        prefetchSynonyms()
    }

    /// The screen went away (back button, another route): keeps the study time and stops
    /// timers and speech.
    func deactivate() {
        heldToasts = nil
        synonymCheck = nil
        isCheckingSynonym = false
        // The last tick, also when the screen is no longer the current one.
        if WriteFlow.isStudying(state) { reduce(.clockTick) }
        for timer in timers.values { timer.cancel() }
        timers = [:]
        heldAutoAdvance = nil
        countdown = nil
        speech.stop()
    }

    /// Saves the study clock every `WriteFlow.clockTickMs` while studying in the active window;
    /// after `WriteFlow.clockIdleMs` without input the clock pauses until the next input.
    func runClock() async {
        guard isLive else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int(WriteFlow.clockTickMs)))
            guard !Task.isCancelled else { return }
            guard isWindowActive, !isIdle else { continue }
            if WriteFlow.isStudying(state) { send(.clockTick) }
            if clock() - lastActivity > WriteFlow.clockIdleMs { isIdle = true }
        }
    }

    /// The window became active or inactive: time away is not study time.
    func windowActivityChanged(_ active: Bool) {
        isWindowActive = active
        if active {
            lastActivity = clock()
            isIdle = false
            send(.clockResumed)
        } else if WriteFlow.isStudying(state) {
            send(.clockTick)
        }
    }

    // MARK: Events

    /// Reduces one event with the current store progress and performs its effects. An otherwise
    /// wrong answer is first looked up as a synonym outside the set. A screen dissolving after
    /// Schreiben was left (`isCurrent`) takes no more events: no keys, clicks, auto-advances.
    func send(_ event: WriteFlow.Event) {
        guard isCurrent else { return }
        if event.isUserActivity { markActive() }
        if holdsForSynonymCheck(event) { return }
        reduce(event)
    }

    private func reduce(_ event: WriteFlow.Event) {
        let query = state.question?.synonymQuery
        let extras = isLive && Self.mayGrade(event) ? query.map(synonyms.extraAnswers(for:)) ?? [] : []
        let env = WriteFlow.Env(
            now: clock(), rng: rng, progress: store.getProgress(setID), extraAnswers: { $0 == query ? extras : [] })
        let previousPhase = state.phase
        let (next, effects) = WriteFlow.reduce(state, event, env: env)
        if next != state { state = next }
        perform(effects)
        rememberResults()
        if isLive { playSound(for: effects, after: previousPhase) }
        prefetchSynonyms()
    }

    // MARK: Synonyms outside the set

    private var synonyms: SynonymAssistant { .shared }

    /// Events that may grade an answer (the others need no synonyms).
    private static func mayGrade(_ event: WriteFlow.Event) -> Bool {
        switch event {
        case .key(.returnKey, _), .proceed, .submit: true
        default: false
        }
    }

    /// Return (or "Antworten") on an answer that would be wrong: the answer waits while
    /// `SynonymAssistant` looks it up, then it is submitted (and counts if it means the same).
    /// Further answers wait for that too; everything else goes on.
    private func holdsForSynonymCheck(_ event: WriteFlow.Event) -> Bool {
        let given: String
        let fromField: Bool
        switch event {
        case .key(.returnKey, isRepeat: false), .proceed: (given, fromField) = (state.input, true)
        case let .submit(text): (given, fromField) = (text, false)
        default: return false
        }
        guard state.phase == .question else { return false }
        if isCheckingSynonym { return true }
        guard isLive, isCurrent, synonyms.isActive, !state.isBlocked, clock() >= state.lockUntil,
            let question = state.question
        else { return false }
        let query = question.synonymQuery
        let cards = state.set?.cards ?? []
        let graded = WriteFlow.gradeQuestion(
            set: state.set, question: question, given: given, tolerance: state.options.tolerance,
            extraAnswers: synonyms.extraAnswers(for: query))
        guard synonyms.supports(query),
            ExtendedSynonyms.worthChecking(
                given: given, result: graded.result, query: query, card: cards.first { $0.id == question.cardId },
                cards: cards, ask: question.ask)
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
            guard isCurrent, state.phase == .question, state.question?.qid == question.qid,
                !fromField || state.input == given
            else { return }
            reduce(.submit(given))
        }
        return true
    }

    /// A question is on screen: its prompt's translations are looked up in the background, so an
    /// answer among them counts at once.
    private func prefetchSynonyms() {
        guard isLive, state.phase == .question, let question = state.question, question.qid != prefetchedQid
        else { return }
        prefetchedQid = question.qid
        synonyms.prefetch(question.synonymQuery)
    }

    /// The sound of a step (`SoundEffects.playStudyStep`).
    private func playSound(for effects: [WriteFlow.Effect], after previousPhase: WriteFlow.Phase) {
        let answer = effects.lazy.compactMap { effect -> SoundEffects.StudyAnswer? in
            switch effect {
            case let .recordAnswer(_, correct, _):
                correct ? .correct : self.state.feedback?.dontKnow == true ? .dontKnow : .wrong
            case .overrideLastAnswer: .correct
            default: nil
            }
        }.first
        SoundEffects.shared.playStudyStep(
            finished: state.phase == .results && previousPhase != .results,
            roundDone: state.phase == .summary && previousPhase != .summary,
            answer: answer, reachedMilestone: streak.reachedMilestone)
    }

    /// The screen is on screen now: the toasts held back by `activate(holdingToasts:)` show.
    func releaseToasts() {
        let toasts = heldToasts ?? []
        heldToasts = nil
        for toast in toasts { showToast(toast) }
    }

    /// Whether the screen is the one being studied (not one dissolving after Schreiben was left).
    private var isCurrent: Bool {
        !isLive || model.route.study?.id == requestID
    }

    /// A key press from the screen's key handler. After a correct answer, a letter typed with an
    /// input method continues without typing it (`LearnKeyRouter.continuing`).
    func press(_ key: KeyInput, isRepeat: Bool) {
        let key = LearnKeyRouter.continuing(
            key, afterAnswer: state.phase == .feedback(.correct), inputMethod: InputSource.isInputMethodActive)
        send(.key(key, isRepeat: isRepeat))
    }

    /// Return in the answer or copy field. `onSubmit` runs while AppKit handles the key, so the
    /// current event tells whether it is an auto-repeat.
    func submitFromField() {
        press(.returnKey, isRepeat: Self.currentKeyIsRepeat)
    }

    /// A Lernen menu command (⌘↩, ⌥↩, ⌘K, ⌘R, ⌘D, ⇧⌘R, esc). Key equivalents keep their
    /// repeat flag, so a held key never causes two transitions.
    func handle(_ command: StudyCommand) {
        guard isCurrent else { return }
        let event = NSApp.currentEvent
        let fromKey = event?.type == .keyDown
        let isRepeat = fromKey && (event?.isARepeat ?? false)
        switch command {
        case .override: send(fromKey ? .key(.commandReturn, isRepeat: isRepeat) : .override)
        case .dontKnow: send(fromKey ? .key(.optionReturn, isRepeat: isRepeat) : .dontKnow)
        case .exit: send(fromKey ? .key(.escape, isRepeat: isRepeat) : .leave)
        case .options: if !isRepeat { send(.requestOptions) }
        case .speak: if !isRepeat { send(.speak(.prompt)) }
        case .toggleStar: if !isRepeat { send(.toggleStar) }
        case .restart: if !isRepeat { send(.restart) }
        }
    }

    /// What the Lernen menu offers now. Nothing while a sheet, popover or alert of the screen is
    /// open (esc closes that first).
    var enabledCommands: Set<StudyCommand> {
        guard !state.isBlocked else { return [] }
        var commands: Set<StudyCommand> = [.exit]
        if canShowOptions { commands.insert(.options) }
        if state.phase == .question { commands.insert(.dontKnow) }
        if state.phase.isMiss, state.feedback?.canOverride == true { commands.insert(.override) }
        if state.phase.isCard {
            commands.insert(.toggleStar)
            if canSpeakPrompt { commands.insert(.speak) }
        }
        switch state.phase {
        case .question, .feedback, .copy, .summary, .results: commands.insert(.restart)
        case .starting, .empty, .missing: break
        }
        return commands
    }

    /// The options apply to sessions: offered on the card, the round summary and the results.
    var canShowOptions: Bool {
        guard !state.isBlocked else { return false }
        return state.phase.isCard || state.phase == .summary || state.phase == .results
    }

    /// The prompt has a voice (not for "Andere").
    private var canSpeakPrompt: Bool {
        guard let question = state.question else { return false }
        return question.promptLang != .other
    }

    /// The card of the question on screen.
    var currentCard: Card? {
        guard let id = state.question?.cardId else { return nil }
        return state.set?.cards.first { $0.id == id }
    }

    /// The set's mastery now ("Dein Lernset" on the results screen).
    var setCounts: StatusCounts {
        StatusCounts(Mastery.setProgress(state.set, store.getProgress(setID)))
    }

    // MARK: Store

    /// The library changed (after any store write, also from elsewhere: the set editor, the
    /// settings): forwards what differs from the screen's state. Echoes of the screen's own
    /// writes match already and send nothing.
    func storeDidChange() {
        guard let set = store.getSet(setID) else {
            if state.set != nil { send(.setDeleted) }
            return
        }
        if let shown = state.set {
            if set.title != shown.title || set.termLang != shown.termLang || set.defLang != shown.defLang
                || set.cards != shown.cards
            {
                send(.setChanged(set))
            }
        }
        let options = store.getStudyOptions(setID)
        if options != state.options { send(.optionsChanged(options)) }
    }

    /// The set editor closed: its changes apply, an auto-advance held back while it was open
    /// starts again, and "Begriffe hinzufügen" on the empty screen starts writing once the set
    /// has cards to ask.
    func setEditorClosed() {
        storeDidChange()
        if let held = heldAutoAdvance {
            heldAutoAdvance = nil
            if state.autoAdvance?.token == held.token { scheduleAutoAdvance(ms: held.ms, token: held.token) }
        }
        if state.phase == .empty, state.emptySubset == .all,
            state.set?.cards.contains(where: WriteFlow.isUsableCard) == true
        {
            send(.practiceAll)
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

    /// The standard of every set (Einstellungen), for the note at the top of the options.
    var standardOptions: StudyOptions { model.settings.study }

    /// "Auf Standard zurücksetzen" (Optionen): this set follows the standard again; a new
    /// direction or order asks to restart when the popover closes, like after any other change.
    func resetOptionsToStandard() {
        if let options = model.resetStudyOptions(setID: setID) { send(.optionsChanged(options)) }
    }

    // MARK: Effects

    private func perform(_ effects: [WriteFlow.Effect]) {
        for effect in effects {
            switch effect {
            case let .recordAnswer(cardId, correct, at):
                streak.record(correct: correct)
                write { _ = try $0.recordAnswer(setID, cardId, correct: correct, at: at) }
            case let .overrideLastAnswer(cardId):
                streak.overrideMiss()
                write { _ = try $0.overrideLastAnswer(setID, cardId) }
            case let .saveSession(session, feedback):
                write { try $0.saveSessionJSON(setID, WriteFlow.storedJSON(session: session, feedback: feedback)) }
            case let .speak(text, lang):
                if isLive { speech.speak(text, lang: lang) }
            case let .haptic(kind):
                if isLive { kind == .success ? Haptics.success() : Haptics.failure() }
            case let .scheduleAutoAdvance(ms, token):
                scheduleAutoAdvance(ms: ms, token: token)
            case let .announce(text):
                if isLive { Announcer.announce(text, important: state.phase.isMiss) }
            case let .updateCard(card):
                write { _ = try $0.updateCard(setID, card.id, CardChanges(term: card.term, definition: card.definition)) }
            case let .toggleStar(cardId):
                write { store in
                    let starred = try store.toggleStar(setID, cardId)
                    if isLive { Announcer.announce(starred ? "Markiert" : "Markierung entfernt") }
                }
            case let .toast(toast):
                if heldToasts != nil {
                    heldToasts?.append(toast)
                } else {
                    showToast(toast)
                }
            case .editSet:
                if isLive { model.openEditor(.edit(setID: setID)) }
            case .exit:
                if isLive {
                    speech.stop()
                    model.finishStudy()
                }
            }
        }
    }

    private func showToast(_ toast: WriteFlow.Toast) {
        model.toasts.show(
            toast.message, tone: toast.isSuccess ? .success : .neutral, systemImage: toast.systemImage,
            duration: toast.durationMs.map { .milliseconds($0) } ?? ToastCenter.defaultDuration)
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
            // Not behind the set editor: the learner would come back to a different question.
            if model.isPresentingSheet {
                heldAutoAdvance = (token, ms)
                countdown = nil
                return
            }
            // A stale token (continued by key in the meantime, a sheet opened) is ignored.
            send(.autoAdvanceFired(token: token))
        }
    }

    private func markActive() {
        lastActivity = clock()
        guard isIdle else { return }
        isIdle = false
        send(.clockResumed)
    }

    private func rememberResults() {
        if state.phase == .results, let marker = state.resultsMarker {
            Self.resultsMarkers[requestID] = marker
        } else {
            Self.resultsMarkers[requestID] = nil
        }
    }

    private static var currentKeyIsRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }
}

private extension WriteFlow.Event {
    /// Events that come from the learner (they keep the study clock running).
    var isUserActivity: Bool {
        switch self {
        case .autoAdvanceFired, .setChanged, .cardsChanged, .setDeleted, .clockTick, .clockResumed, .optionsChanged:
            false
        default:
            true
        }
    }
}
