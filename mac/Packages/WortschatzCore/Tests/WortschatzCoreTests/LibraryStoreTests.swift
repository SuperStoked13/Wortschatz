import Foundation
import Testing
import WortschatzCore

// Port of tests/db.test.js (browser-only parts, like lazy localStorage resolution or cross-tab
// storage events, are replaced by their Mac equivalents).

/// A store over a MemoryBackend with a controllable clock (starts at 1000 like the JS tests).
final class LibraryStoreTestEnv {
    final class Clock {
        var t: Double = 1000
    }

    let clock = Clock()
    let backend: MemoryBackend
    private(set) var store: LibraryStore!

    var t: Double {
        get { clock.t }
        set { clock.t = newValue }
    }

    init(document: JSONValue? = nil, autosave: Bool = false) {
        backend = MemoryBackend(data: document.flatMap { try? $0.jsonData() })
        store = makeStore(autosave: autosave)
    }

    func makeStore(autosave: Bool = false) -> LibraryStore {
        let clock = clock
        return LibraryStore(backend: backend, autosave: autosave, now: { clock.t }, timeZone: zurich)
    }

    @discardableResult
    func tick(_ ms: Double = 1000) -> Double {
        t += ms
        return t
    }
}

/// Shared data and helpers of the LibraryStore tests.
enum LibraryStoreTestKit {
    static let sample: [CardDraft] = [
        CardDraft(term: "le monsieur, messieurs", definition: "der Herr"),
        CardDraft(term: "l'homme", definition: "der Mann"),
        CardDraft(term: "la femme", definition: "die Frau", starred: true),
    ]

    static let learnState: JSONValue = [
        "v": 1, "round": 2, "order": ["a", "b"], "stage": ["a": 1, "b": 0],
        "queue": [["qid": "2.1:a", "cardId": "a", "type": "written", "ask": "term"]], "finishedAt": nil,
    ]

    /// The error code a throwing call produces ("did-not-throw" when it succeeds).
    static func codeOf(_ body: () throws -> Void) -> String {
        do {
            try body()
        } catch let error as LibraryStoreError {
            return error.code.rawValue
        } catch {
            return "other: \(error)"
        }
        return "did-not-throw"
    }

    static func errorOf(_ body: () throws -> Void) -> LibraryStoreError? {
        do {
            try body()
        } catch let error as LibraryStoreError {
            return error
        } catch {
            return nil
        }
        return nil
    }

    /// The saved document as JSON.
    static func savedDocument(_ backend: MemoryBackend) throws -> JSONValue {
        try JSONValue.parse(try #require(backend.data))
    }

    /// `new Date(y, m - 1, d, h, min).getTime()` in Zurich.
    static func localMs(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Double {
        TimeUtil.localTimestamp(year: y, month: m, day: d, hour: h, minute: min, timeZone: zurich)
    }
}

@Suite("LibraryStore (db.test.js)")
struct LibraryStoreTests {
    private typealias Kit = LibraryStoreTestKit
    private typealias StoreEnv = LibraryStoreTestEnv

    // MARK: Loading

    @Test func theBackendIsReadOnceAtInit() throws {
        final class Spy: StorageBackend, @unchecked Sendable {
            var loads = 0
            func load() throws -> Data? {
                loads += 1
                return nil
            }
            func loadBackups() -> [Data] { [] }
            func save(_ data: Data) throws {}
        }
        let spy = Spy()
        let store = LibraryStore(backend: spy)
        _ = store.listSets()
        _ = store.getSettings()
        try store.createSet(title: "A", cards: Kit.sample)
        _ = store.getSet("x")
        #expect(spy.loads == 1)
    }

    @Test func anUnreadableBackendStillGivesAWorkingStore() throws {
        struct Denied: Error {}
        final class Broken: StorageBackend, @unchecked Sendable {
            func load() throws -> Data? { throw Denied() }
            func loadBackups() -> [Data] { [] }
            func save(_ data: Data) throws {}
        }
        let store = LibraryStore(backend: Broken())
        #expect(store.listSets().isEmpty)
        #expect(store.getSettings().theme == .system)
        #expect(store.recovery == .reset)
        let set = try store.createSet(title: "Offline", termLang: .en, cards: Kit.sample)
        #expect(store.getSet(set.id)?.title == "Offline")
    }

    // MARK: Sets CRUD

    @Test func createSetStoresACleanSet() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(
            title: "  Personen  ", termLang: .fr,
            cards: Kit.sample + [CardDraft(term: "   ", definition: ""), CardDraft(term: " calme ", definition: " ruhig ")])
        #expect(set.title == "Personen")
        #expect(set.description == "")
        #expect(set.termLang == .fr)
        #expect(set.defLang == .de)
        #expect(set.cards.count == 4)
        #expect(set.cards[3] == Card(id: set.cards[3].id, term: "calme", definition: "ruhig", starred: false))
        #expect(set.cards[2].starred)
        #expect(Set(set.cards.map(\.id)).count == 4)
        #expect(set.cards.allSatisfy { $0.id.count >= 12 })
        #expect(set.studyOptions == nil)
        #expect(set.createdAt == env.t)
        #expect(set.updatedAt == env.t)
        #expect(set.lastStudiedAt == nil)
        try env.store.save()
        let doc = try Kit.savedDocument(env.backend)
        #expect(doc["sets"]?[0]?["id"] == .string(set.id))
        #expect(doc["schemaVersion"] == 1)
    }

    @Test func createSetFallsBackToADefaultTitle() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "   ", cards: [])
        #expect(set.title == "Unbenanntes Lernset")
        #expect(set.termLang == .fr)
        #expect(set.defLang == .de)
        #expect(set.cards.isEmpty)
    }

    @Test func createSetAssignsFreshCardIdsEvenIfIdsArePassed() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "X", cards: [CardDraft(id: "fixed", term: "a", definition: "b")])
        #expect(set.cards[0].id != "fixed")
    }

    @Test func getSetReturnsCopiesAndNilForUnknownIds() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        var copy = try #require(env.store.getSet(set.id))
        copy.title = "mutated"
        copy.cards.append(Card(id: "z", term: "z", definition: "z"))
        #expect(env.store.getSet(set.id)?.title == "A")
        #expect(env.store.getSet(set.id)?.cards.count == 3)
        #expect(env.store.getSet("nope") == nil)
    }

    @Test func listSetsOrdersByMostRecentActivity() throws {
        let env = StoreEnv()
        let a = try env.store.createSet(title: "A", cards: Kit.sample)
        env.tick()
        let b = try env.store.createSet(title: "B", cards: Kit.sample)
        env.tick()
        let c = try env.store.createSet(title: "C", cards: Kit.sample)
        #expect(env.store.listSets().map(\.title) == ["C", "B", "A"])
        try env.store.recordAnswer(a.id, a.cards[0].id, correct: true, at: env.tick())
        #expect(env.store.listSets().map(\.title) == ["A", "C", "B"])
        env.tick()
        try env.store.updateSet(b.id, SetPatch(title: "B2"))
        #expect(env.store.listSets().map(\.title) == ["B2", "A", "C"])
        #expect(c.id != a.id)
    }

    @Test func listSetsBreaksRecencyTiesByCreationTime() throws {
        let env = StoreEnv()
        let older = try env.store.createSet(title: "older", cards: Kit.sample)
        let t = env.tick()
        try env.store.createSet(title: "newer", cards: Kit.sample)
        try env.store.recordAnswer(older.id, older.cards[0].id, correct: true, at: t)
        #expect(env.store.listSets().map(\.title) == ["newer", "older"])
    }

    @Test func updateSetChangesMetadataAndBumpsUpdatedAt() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        let t = env.tick()
        let next = try env.store.updateSet(
            set.id, SetPatch(title: " Neu ", description: " Kapitel 1 ", termLang: .en, defLang: .de))
        #expect(next.title == "Neu")
        #expect(next.description == "Kapitel 1")
        #expect(next.termLang == .en)
        #expect(next.updatedAt == t)
        #expect(next.createdAt == 1000)
        #expect(env.store.getSet(set.id)?.title == "Neu")
    }

    @Test func updateSetIgnoresInvalidLanguagesAndThrowsNotFound() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        #expect(try env.store.updateSet(set.id, SetPatch(json: ["termLang": "klingon"])).termLang == .fr)
        #expect(Kit.codeOf { try env.store.updateSet("missing", SetPatch(title: "x")) } == "NOT_FOUND")
    }

    @Test func updateSetPreservesCardIdsAssignsNewIdsAndKeepsStars() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        let (c1, c2, c3) = (set.cards[0], set.cards[1], set.cards[2])
        let next = try env.store.updateSet(
            set.id,
            SetPatch(cards: [
                CardDraft(id: c3.id, term: " la femme ", definition: "die Frau, das Weib"),
                CardDraft(id: c1.id, term: c1.term, definition: c1.definition, starred: true),
                CardDraft(term: "la dame", definition: "die Dame"),
                CardDraft(id: c2.id, term: "", definition: "  "),
            ]))
        #expect(next.cards.count == 3)
        #expect(next.cards[0].id == c3.id)
        #expect(next.cards[0].term == "la femme")
        #expect(next.cards[0].definition == "die Frau, das Weib")
        #expect(next.cards[0].starred)
        #expect(next.cards[1].id == c1.id)
        #expect(next.cards[1].starred)
        #expect(![c1.id, c2.id, c3.id].contains(next.cards[2].id))
        #expect(!next.cards.map(\.id).contains(c2.id))
    }

    @Test func updateSetDeduplicatesRepeatedCardIds() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        let id = set.cards[0].id
        let next = try env.store.updateSet(
            set.id, SetPatch(cards: [CardDraft(id: id, term: "a", definition: "b"), CardDraft(id: id, term: "c", definition: "d")]))
        #expect(next.cards[0].id == id)
        #expect(next.cards[1].id != id)
    }

    @Test func updateSetPrunesProgressOfRemovedCards() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        let (c1, c2) = (set.cards[0], set.cards[1])
        try env.store.recordAnswer(set.id, c1.id, correct: true)
        try env.store.recordAnswer(set.id, c2.id, correct: false)
        try env.store.updateSet(set.id, SetPatch(cards: [CardDraft(c1)]))
        let progress = env.store.getProgress(set.id)
        #expect(Array(progress.keys) == [c1.id])
        #expect(progress[c1.id]?.correct == 1)
    }

    @Test func updateSetClearsTheSessionOnlyOnStructuralCardChanges() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let state: JSONValue = ["v": 1, "round": 1, "queue": ["x"]]

        try store.saveSessionJSON(set.id, state)
        try store.updateSet(set.id, SetPatch(cards: set.cards.map { CardDraft(id: $0.id, term: $0.term, definition: $0.definition + "!") }))
        #expect(store.getSessionJSON(set.id) == state)
        try store.updateSet(set.id, SetPatch(cards: set.cards.reversed().map(CardDraft.init)))
        #expect(store.getSessionJSON(set.id) == state)
        try store.updateSet(set.id, SetPatch(title: "Nur Titel"))
        #expect(store.getSessionJSON(set.id) == state)
        try store.updateSet(set.id, SetPatch(cards: set.cards.map(CardDraft.init) + [CardDraft(term: "neu", definition: "new")]))
        #expect(store.getSessionJSON(set.id) == nil)

        let current = try #require(store.getSet(set.id))
        try store.saveSessionJSON(set.id, state)
        try store.updateSet(set.id, SetPatch(cards: current.cards.dropFirst().map(CardDraft.init)))
        #expect(store.getSessionJSON(set.id) == nil)
    }

    @Test func deleteSetRemovesTheSetItsProgressAndItsSession() throws {
        let env = StoreEnv()
        let store = env.store!
        let keep = try store.createSet(title: "keep", cards: Kit.sample)
        let set = try store.createSet(title: "gone", cards: Kit.sample)
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        try store.saveSessionJSON(set.id, ["v": 1])
        #expect(try store.deleteSet(set.id))
        #expect(store.getSet(set.id) == nil)
        #expect(store.listSets().map(\.id) == [keep.id])
        try store.save()
        let doc = try Kit.savedDocument(env.backend)
        #expect(doc["progress"]?[set.id] == nil)
        #expect(doc["sessions"]?[set.id] == nil)
        #expect(try store.deleteSet("unknown") == false)
    }

    @Test func snapshotAndRestoreUndoADeleteIncludingProgressAndTheRunningSession() throws {
        let env = StoreEnv()
        let store = env.store!
        let keep = try store.createSet(title: "keep", cards: Kit.sample)
        let set = try store.createSet(title: "gone", cards: Kit.sample)
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        let session: JSONValue = [
            "v": 1, "round": 1, "queue": ["b:t", "c:t"], "roundAnswered": [["qid": "a:t", "correct": true]],
            "finishedAt": nil,
        ]
        try store.saveSessionJSON(set.id, session)
        let before = (set: store.getSet(set.id), progress: store.getProgress(set.id))

        let snapshot = try #require(store.snapshotSet(set.id))
        let roundTripped = try JSONValue(encoding: snapshot).decode(as: SetSnapshot.self)
        #expect(roundTripped == snapshot)
        try store.deleteSet(set.id)
        #expect(store.getSessionJSON(set.id) == nil)

        var notified = 0
        let off = store.subscribe { _ in notified += 1 }
        let restored = try store.restoreSet(snapshot)
        off()
        #expect(notified == 1)
        #expect(restored == before.set)
        #expect(store.getSet(set.id) == before.set)
        #expect(store.getProgress(set.id) == before.progress)
        #expect(store.getSessionJSON(set.id) == session)
        #expect(store.listSets().map(\.id).sorted() == [keep.id, set.id].sorted())
    }

    @Test func restoreSetWorksWithoutProgressOrSessionAndRejectsJunk() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let snapshot = try #require(store.snapshotSet(set.id))
        #expect(snapshot.progress.isEmpty)
        #expect(snapshot.session == nil)
        #expect(try JSONValue(encoding: snapshot)["session"] == .null)
        try store.deleteSet(set.id)
        try store.restoreSet(snapshot)
        #expect(store.getSet(set.id)?.title == "A")
        #expect(store.getSessionJSON(set.id) == nil)
        #expect(store.snapshotSet("unknown") == nil)
        #expect(Kit.codeOf { try store.restoreSet(json: .null) } == "INVALID")
        #expect(Kit.codeOf { try store.restoreSet(json: ["set": ["title": "ohne id"]]) } == "INVALID")
    }

    @Test func duplicateSetCopiesContentWithFreshIdsAndNoProgress() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "Original", description: "d", termLang: .en, cards: Kit.sample)
        try store.updateStudyOptions(set.id, StudyOptionsPatch(answerWith: .both))
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        let t = env.tick()
        let copy = try store.duplicateSet(set.id)
        #expect(copy.title == "Original (Kopie)")
        #expect(copy.id != set.id)
        #expect(copy.description == "d")
        #expect(copy.termLang == .en)
        #expect(copy.cards.map(\.term) == set.cards.map(\.term))
        #expect(copy.cards.map(\.starred) == [false, false, true])
        #expect(!copy.cards.contains { c in set.cards.contains { $0.id == c.id } })
        #expect(store.getProgress(copy.id).isEmpty)
        #expect(copy.lastStudiedAt == nil)
        #expect(copy.createdAt == t)
        #expect(store.getStudyOptions(copy.id).answerWith == .both)
        #expect(store.listSets().count == 2)
        #expect(Kit.codeOf { try store.duplicateSet("missing") } == "NOT_FOUND")
    }

    // MARK: Cards

    @Test func updateCardEditsOneCardAndValidatesInput() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let card = set.cards[1]
        let t = env.tick()
        let next = try store.updateCard(set.id, card.id, CardChanges(definition: "  der Mensch "))
        #expect(next == Card(id: card.id, term: "l'homme", definition: "der Mensch", starred: false))
        #expect(store.getSet(set.id)?.cards[1].definition == "der Mensch")
        #expect(store.getSet(set.id)?.updatedAt == t)
        #expect(Kit.codeOf { try store.updateCard(set.id, card.id, CardChanges(term: " ", definition: "")) } == "INVALID")
        #expect(Kit.codeOf { try store.updateCard(set.id, "nope", CardChanges(term: "x")) } == "NOT_FOUND")
        #expect(Kit.codeOf { try store.updateCard("nope", card.id, CardChanges(term: "x")) } == "NOT_FOUND")
        #expect(try store.updateCard(set.id, card.id, CardChanges(starred: true)).starred)
    }

    @Test func toggleStarFlipsAndPersistsTheStarWithoutReordering() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        env.tick()
        #expect(try store.toggleStar(set.id, set.cards[0].id))
        #expect(store.getSet(set.id)?.cards[0].starred == true)
        #expect(try store.toggleStar(set.id, set.cards[0].id) == false)
        #expect(try store.toggleStar(set.id, set.cards[2].id) == false)
        #expect(store.getSet(set.id)?.updatedAt == 1000)
        #expect(Kit.codeOf { try store.toggleStar(set.id, "nope") } == "NOT_FOUND")
    }

    // MARK: Progress

    @Test func recordAnswerUpdatesProgressLastStudiedAtAndActivity() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let id = set.cards[0].id
        let at = Kit.localMs(2026, 10, 11, 10)
        let p1 = try store.recordAnswer(set.id, id, correct: true, at: at)
        #expect(p1 == CardProgress(correct: 1, incorrect: 0, streak: 1, streakBefore: 0, lastResult: .correct, lastAnsweredAt: at))
        let p2 = try store.recordAnswer(set.id, id, correct: false, at: at + 1000)
        #expect(p2.streak == 0)
        #expect(p2.streakBefore == 1)
        #expect(p2.incorrect == 1)
        try store.recordAnswer(set.id, set.cards[1].id, correct: true, at: at + 2000)
        #expect(store.getSet(set.id)?.lastStudiedAt == at + 2000)
        #expect(store.getActivity() == [TimeUtil.dateKey(at, timeZone: zurich): 3])
        let next = Kit.localMs(2026, 10, 12, 9)
        try store.recordAnswer(set.id, id, correct: true, at: next)
        #expect(store.getActivity()[TimeUtil.dateKey(next, timeZone: zurich)] == 1)
        #expect(store.getProgress(set.id).count == 2)
    }

    @Test func recordAnswerDrivesTheStatus() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let id = set.cards[0].id
        #expect(store.getProgress(set.id)[id] == nil)
        #expect(try store.recordAnswer(set.id, id, correct: true).streak == 1)
        #expect(try store.recordAnswer(set.id, id, correct: true).streak == 2)
        #expect(Mastery.cardStatus(store.getProgress(set.id)[id]) == .mastered)
        let miss = try store.recordAnswer(set.id, id, correct: false)
        #expect(miss.streak == 0)
        #expect(miss.streakBefore == 2)
        #expect(miss.correct == 2)
        #expect(miss.incorrect == 1)
        #expect(Mastery.cardStatus(miss) == .learning)
    }

    @Test func recordAnswerRejectsUnknownSetsAndCards() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(Kit.codeOf { try store.recordAnswer("nope", set.cards[0].id, correct: true) } == "NOT_FOUND")
        #expect(Kit.codeOf { try store.recordAnswer(set.id, "nope", correct: true) } == "NOT_FOUND")
        #expect(store.getActivity().isEmpty)
    }

    @Test func recordAnswerWithoutAValidTimeUsesNow() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(try store.recordAnswer(set.id, set.cards[0].id, correct: true, at: .nan).lastAnsweredAt == env.t)
        #expect(try store.recordAnswer(set.id, set.cards[0].id, correct: true, at: .infinity).lastAnsweredAt == env.t)
    }

    @Test func overrideLastAnswerTurnsTheLastMissIntoACorrectAnswer() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let id = set.cards[0].id
        try store.recordAnswer(set.id, id, correct: true, at: 5000)
        try store.recordAnswer(set.id, id, correct: false, at: 6000)
        let o = try store.overrideLastAnswer(set.id, id)
        #expect(o == CardProgress(correct: 2, incorrect: 0, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: 6000))
        #expect(store.getProgress(set.id)[id] == o)
        // A second override does nothing.
        #expect(try store.overrideLastAnswer(set.id, id) == o)
        #expect(store.getActivity()[TimeUtil.dateKey(5000, timeZone: zurich)] == 2)
    }

    @Test func overrideLastAnswerIsANoOpAfterACorrectAnswerOrWithoutProgress() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let id = set.cards[0].id
        var events = 0
        let off = store.subscribe { _ in events += 1 }
        let fresh = try store.overrideLastAnswer(set.id, id)
        off()
        #expect(events == 0)
        #expect(fresh.correct == 0)
        #expect(fresh.lastResult == nil)
        #expect(store.getProgress(set.id).isEmpty)
        let p = try store.recordAnswer(set.id, id, correct: true)
        #expect(try store.overrideLastAnswer(set.id, id) == p)
    }

    @Test func resetProgressClearsProgressAndSessionButKeepsTheSet() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        try store.saveSessionJSON(set.id, ["v": 1])
        try store.resetProgress(set.id)
        #expect(store.getProgress(set.id).isEmpty)
        #expect(store.getSessionJSON(set.id) == nil)
        #expect(store.getSet(set.id)?.cards.count == 3)
    }

    // MARK: Write sessions

    @Test func sessionsRoundTripAsCopies() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(store.getSessionJSON(set.id) == nil)
        let state: JSONValue = ["v": 1, "round": 2, "queue": ["a:t"], "misses": ["a:t": 1], "finishedAt": nil]
        try store.saveSessionJSON(set.id, state)
        #expect(store.getSessionJSON(set.id)?["round"] == 2)
        try store.clearSession(set.id)
        #expect(store.getSessionJSON(set.id) == nil)
    }

    @Test func saveSessionIgnoresUnknownSetsAndNilClears() throws {
        let env = StoreEnv()
        let store = env.store!
        try store.saveSessionJSON("ghost", ["v": 1])
        #expect(store.getSessionJSON("ghost") == nil)
        #expect(store.hasUnsavedChanges == false)
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.saveSessionJSON(set.id, ["v": 1])
        try store.saveSessionJSON(set.id, nil)
        #expect(store.getSessionJSON(set.id) == nil)
        try store.saveSessionJSON(set.id, ["v": 1])
        try store.saveSession(set.id, nil)
        #expect(store.getSessionJSON(set.id) == nil)
    }

    // MARK: Learn sessions

    @Test func learnSessionsRoundTripUnderLearnKeys() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(store.getLearnJSON(set.id) == nil)
        try store.saveLearnJSON(set.id, Kit.learnState)
        #expect(store.getLearnJSON(set.id) == Kit.learnState)
        try store.save()
        #expect(try Kit.savedDocument(env.backend)["learns"]?[set.id] == Kit.learnState)
        try store.clearLearn(set.id)
        #expect(store.getLearnJSON(set.id) == nil)
        try store.save()
        #expect(try Kit.savedDocument(env.backend)["learns"]?[set.id] == nil)
    }

    @Test func saveLearnIgnoresUnknownSetsAndANonObjectClears() throws {
        let env = StoreEnv()
        let store = env.store!
        try store.saveLearnJSON("ghost", Kit.learnState)
        #expect(store.getLearnJSON("ghost") == nil)
        let set = try store.createSet(title: "A", cards: Kit.sample)
        for junk: JSONValue? in [nil, .null, "state", [1, 2]] {
            try store.saveLearnJSON(set.id, Kit.learnState)
            try store.saveLearnJSON(set.id, junk)
            #expect(store.getLearnJSON(set.id) == nil)
        }
    }

    @Test func learnAndWriteSessionsAreStoredIndependently() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let session: JSONValue = ["v": 1, "round": 1, "queue": ["x"]]
        try store.saveSessionJSON(set.id, session)
        try store.saveLearnJSON(set.id, Kit.learnState)
        try store.clearSession(set.id)
        #expect(store.getLearnJSON(set.id) == Kit.learnState)
        try store.saveSessionJSON(set.id, session)
        try store.clearLearn(set.id)
        #expect(store.getSessionJSON(set.id) == session)
    }

    @Test func saveLearnAndClearLearnNotifySubscribersWithTheLearnKey() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        var events: [StoreChange] = []
        let off = store.subscribe { events.append($0) }
        try store.saveLearnJSON(set.id, Kit.learnState)
        try store.clearLearn(set.id)
        off()
        #expect(events == [
            StoreChange(kind: .local, keys: ["learn:" + set.id]), StoreChange(kind: .local, keys: ["learn:" + set.id]),
        ])
    }

    @Test func updateSetClearsTheLearnSessionExactlyWhenItClearsTheWriteSession() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let session: JSONValue = ["v": 1, "round": 1, "queue": ["x"]]
        func both() -> [JSONValue?] { [store.getSessionJSON(set.id), store.getLearnJSON(set.id)] }
        func cards() -> [CardDraft] { (store.getSet(set.id)?.cards ?? []).map(CardDraft.init) }
        try store.saveSessionJSON(set.id, session)
        try store.saveLearnJSON(set.id, Kit.learnState)

        // Text edits, reordering, metadata and options keep both.
        try store.updateSet(set.id, SetPatch(cards: set.cards.map { CardDraft(id: $0.id, term: $0.term + "!", definition: $0.definition) }))
        try store.updateSet(set.id, SetPatch(cards: cards().reversed()))
        try store.updateSet(set.id, SetPatch(title: "Nur Titel", description: "neu"))
        try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 10)))
        try store.updateCard(set.id, set.cards[0].id, CardChanges(definition: "der Herr (Anrede)"))
        try store.toggleStar(set.id, set.cards[1].id)
        #expect(both() == [session, Kit.learnState])

        // A card added: both end.
        try store.updateSet(set.id, SetPatch(cards: cards() + [CardDraft(term: "neu", definition: "new")]))
        #expect(both() == [nil, nil])

        // A card removed: both end.
        try store.saveSessionJSON(set.id, session)
        try store.saveLearnJSON(set.id, Kit.learnState)
        try store.updateSet(set.id, SetPatch(cards: Array(cards().dropFirst())))
        #expect(both() == [nil, nil])

        // Only a Learn session running: it ends on its own too.
        try store.saveLearnJSON(set.id, Kit.learnState)
        try store.updateSet(set.id, SetPatch(cards: Array(cards().dropFirst())))
        #expect(store.getLearnJSON(set.id) == nil)
    }

    @Test func recordingAnswersKeepsTheLearnSession() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.saveLearnJSON(set.id, Kit.learnState)
        try store.recordAnswer(set.id, set.cards[0].id, correct: false)
        try store.overrideLastAnswer(set.id, set.cards[0].id)
        #expect(store.getLearnJSON(set.id) == Kit.learnState)
    }

    @Test func deleteSetAndResetProgressRemoveTheLearnSession() throws {
        let env = StoreEnv()
        let store = env.store!
        let keep = try store.createSet(title: "keep", cards: Kit.sample)
        let gone = try store.createSet(title: "gone", cards: Kit.sample)
        try store.saveLearnJSON(keep.id, Kit.learnState)
        try store.saveLearnJSON(gone.id, Kit.learnState)
        try store.deleteSet(gone.id)
        #expect(store.getLearnJSON(gone.id) == nil)
        #expect(store.getLearnJSON(keep.id) == Kit.learnState)

        try store.recordAnswer(keep.id, keep.cards[0].id, correct: true)
        try store.saveSessionJSON(keep.id, ["v": 1])
        try store.resetProgress(keep.id)
        #expect(store.getProgress(keep.id).isEmpty)
        #expect(store.getSessionJSON(keep.id) == nil)
        #expect(store.getLearnJSON(keep.id) == nil)
        try store.save()
        #expect(try Kit.savedDocument(env.backend)["learns"] == [:])
    }

    @Test func snapshotAndRestoreBringTheLearnSessionBackWithTheSet() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "gone", cards: Kit.sample)
        try store.saveLearnJSON(set.id, Kit.learnState)
        let snapshot = try #require(store.snapshotSet(set.id))
        #expect(snapshot.learn == Kit.learnState)
        #expect(snapshot.session == nil)
        try store.deleteSet(set.id)
        #expect(store.getLearnJSON(set.id) == nil)
        try store.restoreSet(json: try JSONValue(encoding: snapshot))
        #expect(store.getLearnJSON(set.id) == Kit.learnState)
        #expect(store.getSessionJSON(set.id) == nil)

        // A snapshot without a Learn session restores none (and drops a stale one).
        let plain = try #require(store.snapshotSet(set.id))
        try store.clearLearn(set.id)
        let bare = try #require(store.snapshotSet(set.id))
        #expect(bare.learn == nil)
        try store.saveLearnJSON(set.id, ["v": 1, "stale": true])
        try store.restoreSet(bare)
        #expect(store.getLearnJSON(set.id) == nil)
        #expect(plain.learn == Kit.learnState)
    }

    // MARK: Per-card progress reset

    @Test func resetCardProgressForgetsJustThoseCardsAndEndsBothSessions() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let (c1, c2, c3) = (set.cards[0].id, set.cards[1].id, set.cards[2].id)
        try store.recordAnswer(set.id, c1, correct: true)
        try store.recordAnswer(set.id, c1, correct: true)
        try store.recordAnswer(set.id, c2, correct: false)
        try store.recordAnswer(set.id, c3, correct: true)
        let studied = store.getSet(set.id)?.lastStudiedAt
        let activity = store.getActivity()
        try store.saveSessionJSON(set.id, ["v": 1])
        try store.saveLearnJSON(set.id, Kit.learnState)
        env.tick()

        var events: [StoreChange] = []
        let off = store.subscribe { events.append($0) }
        #expect(try store.resetCardProgress(set.id, [c1, c2, c2, "unknown"]) == 2)
        off()
        #expect(events.count == 1)
        #expect(Array(store.getProgress(set.id).keys) == [c3])
        #expect(store.getSessionJSON(set.id) == nil)
        #expect(store.getLearnJSON(set.id) == nil)
        // Set data, study date and activity stay as they were.
        #expect(store.getSet(set.id)?.cards.count == 3)
        #expect(store.getSet(set.id)?.lastStudiedAt == studied)
        #expect(store.getActivity() == activity)

        // The last entry removed: the entry goes away.
        #expect(try store.resetCardProgress(set.id, [c3]) == 1)
        #expect(store.getProgress(set.id).isEmpty)
        try store.save()
        #expect(try Kit.savedDocument(env.backend)["progress"]?[set.id] == nil)
    }

    @Test func resetCardProgressWithoutValidIdsChangesNothing() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        try store.saveSessionJSON(set.id, ["v": 1])
        try store.saveLearnJSON(set.id, Kit.learnState)
        let progress = store.getProgress(set.id)
        var notified = 0
        let off = store.subscribe { _ in notified += 1 }
        for ids in [[], [""], ["", ""]] as [[String]] { #expect(try store.resetCardProgress(set.id, ids) == 0) }
        off()
        #expect(notified == 0)
        #expect(store.getProgress(set.id) == progress)
        #expect(store.getSessionJSON(set.id) == ["v": 1])
        #expect(store.getLearnJSON(set.id) == Kit.learnState)
    }

    @Test func resetCardProgressOfCardsWithoutProgressStillRestartsTheSessions() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.saveSessionJSON(set.id, ["v": 1])
        try store.saveLearnJSON(set.id, Kit.learnState)
        #expect(try store.resetCardProgress(set.id, [set.cards[0].id]) == 0)
        #expect(store.getSessionJSON(set.id) == nil)
        #expect(store.getLearnJSON(set.id) == nil)
        // Unknown sets are fine too.
        #expect(try store.resetCardProgress("ghost", ["x"]) == 0)
    }

    // MARK: Settings and study options

    @Test func defaultsAreComplete() {
        #expect(DEFAULT_STUDY_OPTIONS.answerWith == .term)
        #expect(DEFAULT_STUDY_OPTIONS.tolerance.articles)
        #expect(!DEFAULT_STUDY_OPTIONS.tolerance.ignoreAccents)
        #expect(!DEFAULT_STUDY_OPTIONS.tolerance.typos)
        #expect(DEFAULT_SETTINGS.theme == .system)
        #expect(DEFAULT_SETTINGS.study == DEFAULT_STUDY_OPTIONS)
        #expect(DEFAULT_STUDY_OPTIONS.learn == LearnOptions(roundSize: 7, mc: true, written: true, retype: false))
    }

    @Test func getSettingsReturnsDefaults() {
        let env = StoreEnv()
        #expect(env.store.getSettings() == Settings(theme: .system, study: DEFAULT_STUDY_OPTIONS))
    }

    @Test func updateSettingsDeepMergesAndIgnoresInvalidValues() throws {
        let env = StoreEnv()
        let store = env.store!
        try store.updateSettings(SettingsPatch(json: ["theme": "dark", "study": ["tolerance": ["typos": true]]]))
        let s = try store.updateSettings(
            SettingsPatch(json: [
                "study": ["shuffle": false, "answerWith": "nonsense", "tolerance": ["ignoreCase": "yes"]], "extra": 1,
            ]))
        #expect(s.theme == .dark)
        #expect(!s.study.shuffle)
        #expect(s.study.answerWith == .term)
        #expect(s.study.tolerance.typos)
        #expect(s.study.tolerance.ignoreCase)
        #expect(s.study.tolerance.articles)
        #expect(try store.updateSettings(SettingsPatch(json: ["theme": "neon"])).theme == .dark)
        #expect(store.getSettings() == s)
    }

    @Test func getStudyOptionsMergesDefaultsSettingsAndSetOptions() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(store.getStudyOptions(set.id) == DEFAULT_STUDY_OPTIONS)
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(answerWith: .definition, tolerance: TolerancePatch(ignoreAccents: true))))
        #expect(store.getStudyOptions(set.id).answerWith == .definition)
        let opts = try store.updateStudyOptions(set.id, StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(typos: true)))
        #expect(opts.answerWith == .both)
        #expect(opts.tolerance.typos)
        #expect(opts.tolerance.ignoreAccents)
        #expect(opts.tolerance.articles)
        #expect(store.getSet(set.id)?.studyOptions == StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(typos: true)))
        try store.updateStudyOptions(set.id, StudyOptionsPatch(tolerance: TolerancePatch(articles: false)))
        #expect(
            store.getSet(set.id)?.studyOptions
                == StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(articles: false, typos: true)))
        // Settings changes still flow through for keys the set does not override.
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(copyAnswer: false)))
        #expect(!store.getStudyOptions(set.id).copyAnswer)
        #expect(store.getStudyOptions("unknown").answerWith == .definition)
        #expect(Kit.codeOf { try store.updateStudyOptions("unknown", StudyOptionsPatch(shuffle: false)) } == "NOT_FOUND")
    }

    @Test func updateStudyOptionsDoesNotReorderTheDashboard() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        env.tick()
        try env.store.updateStudyOptions(set.id, StudyOptionsPatch(shuffle: false))
        #expect(env.store.getSet(set.id)?.updatedAt == 1000)
    }

    @Test func learnOptionsDefaultToTheEngineDefaults() throws {
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        #expect(env.store.getStudyOptions(set.id).learn == .default)
        #expect(env.store.getSettings().study.learn == .default)
    }

    @Test func learnOptionsDeepMerge() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        let s = try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 10))))
        #expect(s.study.learn == LearnOptions(roundSize: 10, mc: true, written: true, retype: false))
        let opts = try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(retype: true)))
        #expect(opts.learn == LearnOptions(roundSize: 10, mc: true, written: true, retype: true))
        #expect(store.getSet(set.id)?.studyOptions == StudyOptionsPatch(learn: LearnOptionsPatch(retype: true)))
        try store.updateStudyOptions(set.id, StudyOptionsPatch(answerWith: .both, learn: LearnOptionsPatch(roundSize: 15)))
        #expect(
            store.getSet(set.id)?.studyOptions
                == StudyOptionsPatch(answerWith: .both, learn: LearnOptionsPatch(roundSize: 15, retype: true)))
        // Settings still flow through for keys the set does not override.
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 5, retype: false))))
        #expect(store.getStudyOptions(set.id).learn == LearnOptions(roundSize: 15, mc: true, written: true, retype: true))
        #expect(store.getStudyOptions("unknown").learn == LearnOptions(roundSize: 5, mc: true, written: true, retype: false))
        // Other options are untouched by learn patches.
        #expect(store.getStudyOptions(set.id).tolerance == DEFAULT_STUDY_OPTIONS.tolerance)
    }

    @Test func invalidLearnOptionValuesAreIgnored() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        func patch(_ json: JSONValue) -> StudyOptionsPatch { StudyOptionsPatch(json: json) ?? StudyOptionsPatch() }
        for roundSize: JSONValue in [0, -3, 7.5, "10", 51, nil] {
            #expect(try store.updateStudyOptions(set.id, patch(["learn": ["roundSize": roundSize]])).learn.roundSize == 7)
        }
        #expect(try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 99))).learn.roundSize == 7)
        #expect(
            try store.updateStudyOptions(set.id, patch(["learn": ["mc": "no", "written": 0, "retype": "yes", "bogus": true]])).learn
                == .default)
        #expect(try store.updateStudyOptions(set.id, patch(["learn": "all"])).learn == .default)
        #expect(store.getSet(set.id)?.studyOptions == nil)
        #expect(try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 1))).learn.roundSize == 1)
        #expect(try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 50))).learn.roundSize == 50)
    }

    @Test func learnOptionsNeverSwitchOffBothQuestionTypes() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        func learn() -> LearnOptions { store.getStudyOptions(set.id).learn }

        try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(mc: false)))
        #expect([learn().mc, learn().written] == [false, true])
        // Turning the other one off: the newest choice wins, the first comes back on.
        try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(written: false)))
        #expect([learn().mc, learn().written] == [true, false])
        #expect(store.getSet(set.id)?.studyOptions?.learn == LearnOptionsPatch(mc: true, written: false))
        // Both off in one patch is not a valid choice: that part is ignored.
        try store.updateStudyOptions(set.id, StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 10, mc: false, written: false)))
        #expect(learn() == LearnOptions(roundSize: 10, mc: true, written: false, retype: false))

        // Across layers the set's own choice wins over the defaults in Settings.
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(mc: false))))
        #expect([learn().mc, learn().written] == [true, false])
        try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(written: false))))
        #expect(store.getSettings().study.learn == LearnOptions(roundSize: 7, mc: true, written: false, retype: false))
        #expect(
            try store.updateSettings(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(mc: false, written: false))))
                .study.learn == LearnOptions(roundSize: 7, mc: true, written: false, retype: false))

        let other = try store.createSet(title: "B", cards: Kit.sample)
        try store.updateStudyOptions(other.id, StudyOptionsPatch(learn: LearnOptionsPatch(mc: false)))
        #expect(store.getStudyOptions(other.id).learn == LearnOptions(roundSize: 7, mc: false, written: true, retype: false))
    }

    @Test func resettingTheDefaultsInSettingsResetsTheLearnOptionsToo() throws {
        let env = StoreEnv()
        try env.store.updateSettings(SettingsPatch(study: StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 15, mc: false, retype: true))))
        #expect(try env.store.updateSettings(SettingsPatch(study: StudyOptionsPatch(DEFAULT_STUDY_OPTIONS))).study == DEFAULT_STUDY_OPTIONS)
    }

    // MARK: Subscriptions

    @Test func subscribeNotifiesOncePerWriteOperationAndUnsubscribes() throws {
        let env = StoreEnv()
        let store = env.store!
        var events: [StoreChange] = []
        let off = store.subscribe { events.append($0) }
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(events.count == 1)
        #expect(events[0].kind == .local)
        #expect(events[0].keys?.contains("sets") == true)
        #expect(events[0].keys?.contains("meta") == true)
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        #expect(events.count == 2)
        #expect(events[1].touches("progress:" + set.id))
        #expect(events[1].touches("activity"))
        #expect(!events[1].touches("settings"))
        _ = store.listSets()
        _ = store.getSettings()
        #expect(events.count == 2)
        off()
        try store.updateSettings(SettingsPatch(theme: .light))
        #expect(events.count == 2)
    }

    @Test func aSubscriberMayCallBackIntoTheStore() throws {
        let env = StoreEnv()
        let store = env.store!
        var seen: [Int] = []
        var nested = false
        store.subscribe { _ in
            seen.append(store.listSets().count)
            if !nested {
                nested = true
                _ = try? store.updateSettings(SettingsPatch(theme: .dark))
            }
        }
        try store.createSet(title: "A", cards: Kit.sample)
        #expect(seen == [1, 1])
        #expect(store.getSettings().theme == .dark)
    }

    @Test func reloadRereadsTheBackendAndNotifiesAnExternalChange() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.save()
        // Another writer renames the set in the file.
        var doc = try Kit.savedDocument(env.backend).objectValue ?? [:]
        var sets = doc["sets"]?.arrayValue ?? []
        var first = sets[0].objectValue ?? [:]
        first["title"] = "Von aussen"
        sets[0] = .object(first)
        doc["sets"] = .array(sets)
        env.backend.data = try JSONValue.object(doc).jsonData()
        #expect(store.getSet(set.id)?.title == "A")

        var events: [StoreChange] = []
        store.subscribe { events.append($0) }
        store.reload()
        #expect(store.getSet(set.id)?.title == "Von aussen")
        #expect(events == [StoreChange(kind: .external, keys: nil)])
        #expect(events[0].touches("anything"))
    }

    @Test func changesStreamsTheNotifications() async throws {
        let env = StoreEnv()
        let store = env.store!
        let stream = store.changes()
        try store.createSet(title: "A", cards: Kit.sample)
        try store.updateSettings(SettingsPatch(theme: .dark))
        var received: [StoreChange] = []
        for await change in stream {
            received.append(change)
            if received.count == 2 { break }
        }
        #expect(received[0].touches("sets"))
        #expect(received[1].keys == ["settings"])
    }

    // MARK: Backup export / import

    /// db.test.js `seeded()`.
    private static func seeded() throws -> (env: StoreEnv, a: VocabSet, b: VocabSet) {
        let env = StoreEnv()
        let store = env.store!
        let a = try store.createSet(title: "Personen", cards: Kit.sample)
        env.tick()
        let b = try store.createSet(title: "Farben", termLang: .en, cards: [CardDraft(term: "red", definition: "rot")])
        try store.recordAnswer(a.id, a.cards[0].id, correct: true, at: Kit.localMs(2026, 10, 10, 12))
        try store.recordAnswer(a.id, a.cards[1].id, correct: false, at: Kit.localMs(2026, 10, 11, 12))
        try store.updateSettings(SettingsPatch(theme: .dark, study: StudyOptionsPatch(tolerance: TolerancePatch(typos: true))))
        try store.updateStudyOptions(b.id, StudyOptionsPatch(answerWith: .definition))
        try store.saveSessionJSON(a.id, ["v": 1, "round": 1])
        return (env, a, b)
    }

    @Test func exportAllHasTheDocumentedShape() throws {
        let (env, a, _) = try Self.seeded()
        let data = env.store.exportAll()
        #expect(data.app == "wortschatz")
        #expect(data.version == 1)
        #expect(data.exportedAt == env.t)
        #expect(data.sets.count == 2)
        #expect(Array(data.progress.keys) == [a.id])
        #expect(data.settings.theme == .dark)
        #expect(data.activity == ["2026-10-10": 1, "2026-10-11": 1])
        let json = try JSONValue(encoding: data)
        #expect(Set(json.objectValue?.keys.map { $0 } ?? []) == ["app", "version", "exportedAt", "sets", "progress", "settings", "activity"])
        #expect(try json.decode(as: BackupDocument.self) == data)
    }

    @Test func exportThenImportReplaceRoundTripsIntoAnEmptyStore() throws {
        let (env, a, b) = try Self.seeded()
        let data = try JSONValue(encoding: env.store.exportAll())
        let target = StoreEnv().store!
        #expect(try target.importAll(data, mode: .replace) == ImportSummary(setsAdded: 2, setsUpdated: 0))
        #expect(target.listSets() == env.store.listSets())
        #expect(target.getProgress(a.id) == env.store.getProgress(a.id))
        #expect(target.getSettings() == env.store.getSettings())
        #expect(target.getActivity() == env.store.getActivity())
        #expect(target.getStudyOptions(b.id).answerWith == .definition)
        #expect(target.getSessionJSON(a.id) == nil)
        // The typed overload gives the same result.
        let typed = StoreEnv().store!
        try typed.importAll(env.store.exportAll(), mode: .replace)
        #expect(typed.listSets() == env.store.listSets())
    }

    @Test func importMergeReplacesSameIdSetsAddsNewOnesAndKeepsTheRest() throws {
        let (env, a, b) = try Self.seeded()
        let store = env.store!
        var edited = try JSONValue(encoding: store.exportAll()).objectValue ?? [:]
        var sets = (edited["sets"]?.arrayValue ?? []).filter { $0["id"] == .string(a.id) }
        var first = sets[0].objectValue ?? [:]
        first["title"] = "Personen (Backup)"
        sets[0] = .object(first)
        sets.append([
            "id": "brandnew", "title": "Neu", "termLang": "it", "defLang": "de",
            "cards": [["id": "k1", "term": "ciao", "definition": "hallo"]],
        ])
        edited["sets"] = .array(sets)
        edited["progress"] = [:]
        edited["settings"] = ["theme": "light"]
        edited["activity"] = ["2026-10-11": 7, "2026-01-01": 2]

        #expect(try store.importAll(.object(edited), mode: .merge) == ImportSummary(setsAdded: 1, setsUpdated: 1))
        #expect(store.listSets().count == 3)
        #expect(store.getSet(a.id)?.title == "Personen (Backup)")
        #expect(store.getSet(b.id)?.title == "Farben")
        #expect(store.getSet("brandnew")?.cards[0] == Card(id: "k1", term: "ciao", definition: "hallo", starred: false))
        // The replaced set takes the backup's (empty) progress; its session is dropped.
        #expect(store.getProgress(a.id).isEmpty)
        #expect(store.getSessionJSON(a.id) == nil)
        // Settings stay local in merge mode; activity keeps the max per day.
        #expect(store.getSettings().theme == .dark)
        #expect(store.getActivity() == ["2026-10-10": 1, "2026-10-11": 7, "2026-01-01": 2])
    }

    @Test func importMergeIsIdempotent() throws {
        let (env, _, _) = try Self.seeded()
        let store = env.store!
        let backup = try JSONValue(encoding: store.exportAll())
        #expect(try store.importAll(backup) == ImportSummary(setsAdded: 0, setsUpdated: 2))
        let before = (store.listSets(), store.getActivity())
        try store.importAll(backup)
        #expect(store.listSets() == before.0)
        #expect(store.getActivity() == before.1)
    }

    @Test func importReplaceWipesPreviousSetsProgressAndSessionsIncludingOrphans() throws {
        let (seededEnv, a, _) = try Self.seeded()
        try seededEnv.store.createSet(title: "Lokal", cards: Kit.sample)
        try seededEnv.store.save()
        // An orphaned progress entry (no set with that id), like a stray localStorage key.
        var doc = try Kit.savedDocument(seededEnv.backend).objectValue ?? [:]
        var progress = doc["progress"]?.objectValue ?? [:]
        progress["orphan"] = [:]
        doc["progress"] = .object(progress)
        let env = StoreEnv(document: .object(doc))
        let store = env.store!
        var events: [StoreChange] = []
        store.subscribe { events.append($0) }
        let backup: JSONValue = [
            "app": "wortschatz", "version": 1,
            "sets": [["id": "only", "title": "Einzig", "termLang": "fr", "defLang": "de",
                      "cards": [["id": "c", "term": "la rue", "definition": "die Strasse"]]]],
            "progress": ["only": ["c": ["correct": 2, "incorrect": 0, "streak": 2, "streakBefore": 1,
                                         "lastResult": "correct", "lastAnsweredAt": 1]]],
        ]
        #expect(try store.importAll(backup, mode: .replace) == ImportSummary(setsAdded: 1, setsUpdated: 0))
        #expect(store.listSets().map(\.id) == ["only"])
        #expect(store.getProgress("only")["c"]?.streak == 2)
        #expect(events.first?.touches("progress:orphan") == true)
        try store.save()
        let saved = try Kit.savedDocument(env.backend)
        #expect(saved["progress"]?[a.id] == nil)
        #expect(saved["progress"]?["orphan"] == nil)
        #expect(saved["sessions"] == [:])
        #expect(store.getSettings() == Settings(theme: .system, study: DEFAULT_STUDY_OPTIONS))
        #expect(store.getActivity().isEmpty)
    }

    @Test func importDropsProgressForUnknownCardsAndRenamesDuplicateSetIds() throws {
        let env = StoreEnv()
        let store = env.store!
        let backup: JSONValue = [
            "app": "wortschatz", "version": 1,
            "sets": [
                ["id": "same", "title": "Eins", "cards": [["id": "c1", "term": "a", "definition": "b"]]],
                ["id": "same", "title": "Zwei", "cards": [["id": "c2", "term": "c", "definition": "d"]]],
            ],
            "progress": ["same": ["c1": ["correct": 1, "streak": 1], "ghost": ["correct": 3, "streak": 3]]],
        ]
        #expect(try store.importAll(backup).setsAdded == 2)
        let sets = store.listSets()
        #expect(sets.count == 2)
        #expect(Set(sets.map(\.id)).count == 2)
        #expect(Array(store.getProgress("same").keys) == ["c1"])
    }

    @Test func importAllRejectsInvalidBackupsWithGermanMessagesAndChangesNothing() throws {
        let (env, _, _) = try Self.seeded()
        let store = env.store!
        let before = store.exportAll().sets
        let invalid: [JSONValue] = [
            nil, "text", [], ["app": "quizlet", "sets": []], ["app": "wortschatz", "version": 2, "sets": []],
            ["app": "wortschatz", "version": "eins", "sets": []], ["app": "wortschatz", "version": 1],
            ["app": "wortschatz", "version": 1, "sets": [["title": "ohne Karten"]]],
            ["app": "wortschatz", "version": 1, "sets": ["kaputt"]],
            ["app": "wortschatz", "version": 1, "sets": [], "progress": []],
        ]
        var events = 0
        store.subscribe { _ in events += 1 }
        for data in invalid {
            let error = try #require(Kit.errorOf { try store.importAll(data, mode: .replace) })
            #expect(error.code == .invalidBackup)
            #expect(!error.message.contains("ß"))
        }
        #expect(events == 0)
        #expect(Kit.errorOf { try store.importAll(["app": "wortschatz", "version": 2, "sets": []]) }?.message.contains("neueren Version") == true)
        #expect(Kit.errorOf { try store.importAll(["app": "x", "sets": []]) }?.message.contains("kein Wortschatz-Backup") == true)
        #expect(Kit.errorOf { try store.importAll(["app": "wortschatz", "sets": [["cards": []], 5]]) }?.message == StoreMessages.badSet(2))
        #expect(Kit.errorOf { try store.importAll(["app": "wortschatz", "sets": [], "settings": 1]) }?.message == StoreMessages.badPart("settings"))
        #expect(store.exportAll().sets == before)
    }

    @Test func clearAllRemovesAllUserData() throws {
        let (env, a, _) = try Self.seeded()
        let store = env.store!
        try store.clearAll()
        #expect(store.listSets().isEmpty)
        #expect(store.getProgress(a.id).isEmpty)
        #expect(store.getSessionJSON(a.id) == nil)
        #expect(store.getActivity().isEmpty)
        #expect(store.getSettings().theme == .system)
        try store.save()
        #expect(try Kit.savedDocument(env.backend)["progress"] == [:])
    }

    @Test func previewImportValidatesWithoutTouchingTheLibrary() throws {
        let (env, _, _) = try Self.seeded()
        let backup = try JSONValue(encoding: env.store.exportAll())
        #expect(try LibraryStore.previewImport(backup).map(\.title) == env.store.listSets().map(\.title))
        #expect(throws: LibraryStoreError.self) { try LibraryStore.previewImport(["app": "x"]) }
    }

    // MARK: Robustness

    @Test func corruptPartsReadAsEmpty() throws {
        let env = StoreEnv(document: [
            "sets": "{not json", "settings": 7, "activity": "x", "progress": ["s1": "x"], "sessions": ["s1": "x"],
            "schemaVersion": "x",
        ])
        let store = env.store!
        #expect(store.listSets().isEmpty)
        #expect(store.getSet("s1") == nil)
        #expect(store.getSettings() == Settings(theme: .system, study: DEFAULT_STUDY_OPTIONS))
        #expect(store.getActivity().isEmpty)
        #expect(store.getProgress("s1").isEmpty)
        #expect(store.getSessionJSON("s1") == nil)
        #expect(store.getStudyOptions("s1") == DEFAULT_STUDY_OPTIONS)
        #expect(store.recovery == .none)
        let set = try store.createSet(title: "Neu", cards: Kit.sample)
        #expect(store.listSets().count == 1)
        #expect(store.getSet(set.id)?.cards.count == 3)
    }

    @Test func wronglyTypedButValidJSONIsSanitised() throws {
        let env = StoreEnv(document: [
            "sets": [
                nil,
                ["title": "ohne id", "cards": []],
                [
                    "id": "s1", "title": 42, "termLang": "zz",
                    "cards": [["id": "c1", "term": "le nom", "definition": "der Name", "starred": "yes"], "junk",
                              ["term": "", "definition": ""]],
                    "studyOptions": ["answerWith": "both", "shuffle": "no", "tolerance": ["typos": true, "bogus": true]],
                    "createdAt": "gestern",
                ],
                ["id": "s1", "title": "Duplikat", "cards": []],
            ],
            "settings": ["theme": 7, "study": ["tolerance": "none"]],
            "activity": ["2026-10-11": 3, "2026-10-12": -1, "foo": 2, "2026-10-13": "x"],
            "progress": ["s1": ["c1": ["correct": "2", "streak": 2], "c2": "bad"]],
            "sessions": ["s1": [1, 2, 3]],
            "learns": ["s1": "state", "s2": [1, 2]],
        ])
        let store = env.store!
        let sets = store.listSets()
        #expect(sets.count == 1)
        let s = try #require(sets.first)
        #expect(s.title == "42")
        #expect(s.termLang == .fr)
        #expect(s.cards == [Card(id: "c1", term: "le nom", definition: "der Name", starred: false)])
        #expect(s.studyOptions == StudyOptionsPatch(answerWith: .both, tolerance: TolerancePatch(typos: true)))
        #expect(s.createdAt == env.t)
        #expect(store.getSettings() == Settings(theme: .system, study: DEFAULT_STUDY_OPTIONS))
        #expect(store.getActivity() == ["2026-10-11": 3])
        #expect(store.getProgress("s1") == ["c1": CardProgress(correct: 0, incorrect: 0, streak: 2)])
        #expect(store.getSessionJSON("s1") == nil)
        #expect(store.getLearnJSON("s1") == nil)
        #expect(store.getLearnJSON("s2") == nil)
        try store.saveLearnJSON("s1", Kit.learnState)
        #expect(store.getLearnJSON("s1") == Kit.learnState)
    }

    @Test func learnSessionsAreNotExportedAndImportingASetEndsItsLearnSession() throws {
        let (env, a, b) = try Self.seeded()
        let store = env.store!
        try store.saveLearnJSON(a.id, Kit.learnState)
        try store.saveLearnJSON(b.id, Kit.learnState)
        let data = try JSONValue(encoding: store.exportAll())
        #expect(!data.jsonString.contains("\"stage\""))
        #expect(data["learns"] == nil)

        var onlyA = data.objectValue ?? [:]
        onlyA["sets"] = .array((onlyA["sets"]?.arrayValue ?? []).filter { $0["id"] == .string(a.id) })
        try store.importAll(.object(onlyA), mode: .merge)
        #expect(store.getLearnJSON(a.id) == nil)
        #expect(store.getLearnJSON(b.id) == Kit.learnState)

        let target = StoreEnv().store!
        try target.importAll(data, mode: .replace)
        #expect(target.getLearnJSON(a.id) == nil)
        #expect(target.getLearnJSON(b.id) == nil)
    }

    @Test func importReplaceAndClearAllWipeLearnSessionsIncludingOrphans() throws {
        let wipes: [(LibraryStore) throws -> Void] = [
            { _ = try $0.importAll(["app": "wortschatz", "version": 1, "sets": []], mode: .replace) },
            { try $0.clearAll() },
        ]
        for wipe in wipes {
            let env = StoreEnv(document: ["learns": ["orphan": Kit.learnState]])
            let store = env.store!
            let set = try store.createSet(title: "A", cards: Kit.sample)
            try store.saveLearnJSON(set.id, Kit.learnState)
            #expect(store.getLearnJSON("orphan") == Kit.learnState)
            try wipe(store)
            #expect(store.getLearnJSON(set.id) == nil)
            #expect(store.getLearnJSON("orphan") == nil)
            try store.save()
            #expect(try Kit.savedDocument(env.backend)["learns"] == [:])
        }
    }

    @Test func duplicateSetDoesNotCopyTheLearnSession() throws {
        let env = StoreEnv()
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        try store.saveLearnJSON(set.id, Kit.learnState)
        let copy = try store.duplicateSet(set.id)
        #expect(store.getLearnJSON(copy.id) == nil)
        #expect(store.getLearnJSON(set.id) == Kit.learnState)
    }
}
