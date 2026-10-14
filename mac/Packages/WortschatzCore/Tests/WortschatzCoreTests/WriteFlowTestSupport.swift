import Foundation
import Testing
@testable import WortschatzCore

/// A mutable clock shared by a test driver and its store.
final class WriteFlowTestClock {
    var now: Double
    init(_ now: Double) { self.now = now }
}

/// Drives `WriteFlow` like the app does: every event goes through `reduce` with the current time,
/// a seeded RNG and the store's progress, and the effects are performed on a real `LibraryStore`
/// (memory backend). Timers are collected and fired on request.
final class WriteFlowDriver {
    static let T0: Double = 1_760_000_000_000

    let store: LibraryStore
    let setId: String
    let clock: WriteFlowTestClock
    let rng: RNG
    var state: WriteFlow.State
    /// The effects of the last event.
    private(set) var effects: [WriteFlow.Effect] = []
    /// Every effect so far.
    private(set) var log: [WriteFlow.Effect] = []
    /// Scheduled auto-advance timers (token, due time).
    private(set) var timers: [(token: Int, due: Double)] = []
    private(set) var exits = 0
    private(set) var editorRequests = 0

    var now: Double { clock.now }
    var phase: WriteFlow.Phase { state.phase }
    var question: WriteFlow.Question? { state.question }
    var session: SessionState? { state.session }
    var env: WriteFlow.Env { WriteFlow.Env(now: clock.now, rng: rng, progress: store.getProgress(setId)) }

    /// A set with `cards` in a fresh store; Write mode opens on it right away (unless `open` is false).
    convenience init(
        cards: [Card], termLang: Lang = .fr, defLang: Lang = .de, options: StudyOptionsPatch = StudyOptionsPatch(shuffle: false),
        seed: Int = 1, subset: StudySubset? = nil, open: Bool = true
    ) {
        let clock = WriteFlowTestClock(Self.T0)
        let store = LibraryStore(backend: MemoryBackend(), now: { clock.now })
        let set = try! store.createSet(title: "Personen", termLang: termLang, defLang: defLang)
        // `updateSet` keeps the card ids (createSet makes new ones).
        _ = try! store.updateSet(set.id, SetPatch(cards: cards.map(CardDraft.init)))
        _ = try! store.updateStudyOptions(set.id, options)
        self.init(store: store, setId: set.id, clock: clock, seed: seed)
        if open { self.open(subset: subset) }
    }

    /// Another Write screen on the same store (leaving and coming back, or a relaunch).
    init(store: LibraryStore, setId: String, clock: WriteFlowTestClock, seed: Int) {
        self.store = store
        self.setId = setId
        self.clock = clock
        rng = mulberry32(seed: seed)
        state = WriteFlow.State(set: nil, options: .default)
    }

    /// Opens Write mode from what the store holds (`WriteFlow.start`).
    @discardableResult
    func open(subset: StudySubset? = nil, forceNew: Bool = false, marker: Double? = nil, after ms: Double = 1000)
        -> [WriteFlow.Effect]
    {
        clock.now += ms
        let (s, fx) = WriteFlow.start(
            set: store.getSet(setId), options: store.getStudyOptions(setId), stored: store.getSessionJSON(setId),
            subset: subset, forceNew: forceNew, resultsMarker: marker, env: env)
        state = s
        record(fx)
        return fx
    }

    /// A new driver on the same store, opened after `ms` (the old screen is gone).
    func reopen(seed: Int = 2, subset: StudySubset? = nil, forceNew: Bool = false, marker: Double? = nil, after ms: Double = 60_000)
        -> WriteFlowDriver
    {
        let d = WriteFlowDriver(store: store, setId: setId, clock: clock, seed: seed)
        d.open(subset: subset, forceNew: forceNew, marker: marker, after: ms)
        return d
    }

    @discardableResult
    func send(_ event: WriteFlow.Event, after ms: Double = 400) -> [WriteFlow.Effect] {
        clock.now += ms
        let (s, fx) = WriteFlow.reduce(state, event, env: env)
        state = s
        record(fx)
        return fx
    }

    @discardableResult
    func press(_ key: KeyInput, repeat isRepeat: Bool = false, after ms: Double = 400) -> [WriteFlow.Effect] {
        send(.key(key, isRepeat: isRepeat), after: ms)
    }

    func type(_ text: String) { send(.inputChanged(text), after: 50) }

    /// Types `text` and presses Return.
    @discardableResult
    func answer(_ text: String) -> [WriteFlow.Effect] {
        type(text)
        return press(.returnKey)
    }

    /// Types the expected answer and presses Return.
    @discardableResult
    func answerCorrectly() -> [WriteFlow.Effect] { answer(state.question?.expected ?? "") }

    /// Fires the latest scheduled auto-advance when it is due.
    @discardableResult
    func fireTimer() -> [WriteFlow.Effect] {
        guard let timer = timers.last else { return [] }
        return send(.autoAdvanceFired(token: timer.token), after: max(0, timer.due - clock.now))
    }

    /// The stored session and its open miss, as the next screen would read them.
    var stored: (session: SessionState, feedback: WriteFlow.PendingFeedback?)? {
        WriteFlow.decodeStored(store.getSessionJSON(setId))
    }

    var progress: ProgressMap { store.getProgress(setId) }

    func saves(_ fx: [WriteFlow.Effect]? = nil) -> [(SessionState, WriteFlow.PendingFeedback?)] {
        (fx ?? effects).compactMap { if case let .saveSession(s, f) = $0 { (s, f) } else { nil } }
    }

    func announcements(_ fx: [WriteFlow.Effect]? = nil) -> [String] {
        (fx ?? effects).compactMap { if case let .announce(t) = $0 { t } else { nil } }
    }

    private func record(_ fx: [WriteFlow.Effect]) {
        effects = fx
        log += fx
        for effect in fx {
            do {
                switch effect {
                case let .recordAnswer(cardId, correct, at):
                    _ = try store.recordAnswer(setId, cardId, correct: correct, at: at)
                case let .overrideLastAnswer(cardId):
                    _ = try store.overrideLastAnswer(setId, cardId)
                case let .saveSession(session, feedback):
                    try store.saveSessionJSON(setId, WriteFlow.storedJSON(session: session, feedback: feedback))
                case let .updateCard(card):
                    _ = try store.updateCard(setId, card.id, CardChanges(term: card.term, definition: card.definition))
                case let .toggleStar(cardId):
                    _ = try store.toggleStar(setId, cardId)
                case let .scheduleAutoAdvance(ms, token):
                    timers.append((token, clock.now + Double(ms)))
                case .exit:
                    exits += 1
                case .editSet:
                    editorRequests += 1
                case .speak, .haptic, .announce, .toast:
                    break
                }
            } catch {
                Issue.record("store rejected \(effect): \(error)")
            }
        }
    }
}

/// Cards for flow tests.
enum WriteFlowSamples {
    /// The user's 52 pairs (tests/fixtures/user-example.txt: alternating term and definition lines).
    static let userCards: [Card] = {
        let lines = LangDetectWebFixtures.read("user-example.txt")
            .split(whereSeparator: \.isNewline).map { JSCompat.trim(String($0)) }.filter { !$0.isEmpty }
        return stride(from: 0, to: lines.count - 1, by: 2).map { i in
            Card(id: "u\(i / 2 + 1)", term: lines[i], definition: lines[i + 1])
        }
    }()

    /// Small set with synonyms (write-model.test.js).
    static let personen: [Card] = [
        Card(id: "laid", term: "laid, laide", definition: "hässlich"),
        Card(id: "moche", term: "moche", definition: "hässlich"),
        Card(id: "brave", term: "brave", definition: "lieb"),
        Card(id: "gentil", term: "gentil, gentille", definition: "lieb, nett"),
        Card(id: "chat", term: "le chat", definition: "die Katze"),
        Card(id: "dash", term: "le pluriel", definition: "-"),
    ]

    static func three() -> [Card] {
        [
            Card(id: "a", term: "le chat", definition: "die Katze"),
            Card(id: "b", term: "le chien", definition: "der Hund", starred: true),
            Card(id: "c", term: "la maison", definition: "das Haus"),
        ]
    }
}

extension WriteFlow.Effect {
    var isSave: Bool { if case .saveSession = self { true } else { false } }
    var isAnnounce: Bool { if case .announce = self { true } else { false } }
}
