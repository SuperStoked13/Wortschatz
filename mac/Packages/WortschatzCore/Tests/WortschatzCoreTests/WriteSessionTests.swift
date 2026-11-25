import Foundation
import Testing
import WortschatzCore

/// Port of tests/session.test.js (Write mode engine), plus Swift-specific checks of the typed API
/// (encoding, repair of typed and JSON states, non-finite times, odd RNGs).
@Suite("WriteSession (session.test.js)")
struct WriteSessionTests {
    static let T0: Double = 1_760_000_000_000
    static let SEC: Double = 1000
    static let MIN: Double = 60 * SEC

    static func makeCards(_ n: Int) -> [Card] {
        (0..<n).map { i in
            Card(id: "c\(i + 1)", term: "terme \(i + 1)", definition: "Begriff \(i + 1)", starred: i % 3 == 0)
        }
    }

    static func progressEntry(_ streak: Int, _ correct: Int, _ incorrect: Int, _ lastResult: AnswerResult)
        -> CardProgress
    {
        CardProgress(
            correct: correct, incorrect: incorrect, streak: streak, streakBefore: 0, lastResult: lastResult,
            lastAnsweredAt: T0 - 1000)
    }

    /// `createSession(cards, ORDERED, { now: T0, ... })`.
    static func ordered(
        _ cards: [Card], _ answerWith: AnswerWith = .term, subset: StudySubset = .all, progress: ProgressMap = [:]
    ) -> SessionState {
        WriteSession.createSession(
            cards, answerWith: answerWith, shuffle: false, subset: subset, rng: mulberry32(seed: 1), now: T0,
            progress: progress)
    }

    static func shuffled(_ cards: [Card], _ answerWith: AnswerWith = .term, seed: Int) -> SessionState {
        WriteSession.createSession(cards, answerWith: answerWith, shuffle: true, rng: mulberry32(seed: seed), now: T0)
    }

    /// Answers the current question with each value in `results`, 10 s apart.
    static func answerSeq(_ state: SessionState, _ results: [Bool], startAt: Double = T0) -> SessionState {
        var s = state
        for (i, r) in results.enumerated() {
            s = WriteSession.answer(s, correct: r, now: startAt + Double(i + 1) * 10 * SEC)
        }
        return s
    }

    static func next(_ s: SessionState, seed: Int = 1, now: Double) -> SessionState {
        WriteSession.nextRound(s, rng: mulberry32(seed: seed), now: now)
    }

    static func cardsOf(_ s: SessionState, _ qids: [String]) -> [String] {
        qids.map { s.questions[$0]?.cardId ?? "?" }
    }

    static func hasAdjacentSiblings(_ s: SessionState, _ qids: [String]) -> Bool {
        zip(qids, qids.dropFirst()).contains { s.questions[$0]?.cardId == s.questions[$1]?.cardId }
    }

    static func counters(
        _ remaining: Int, _ correct: Int, _ incorrect: Int, _ total: Int, _ round: Int, _ progress: Double
    ) -> WriteSession.Counters {
        WriteSession.Counters(
            remaining: remaining, correct: correct, incorrect: incorrect, total: total, round: round, progress: progress)
    }

    static func item(_ qid: String, _ cardId: String, _ ask: AskSide, _ correct: Bool) -> WriteSession.RoundSummaryItem {
        WriteSession.RoundSummaryItem(qid: qid, cardId: cardId, ask: ask, correct: correct)
    }

    typealias Q = SessionQuestion
    typealias R = SessionRound
    typealias A = SessionAnswer
    var T0: Double { Self.T0 }
    var SEC: Double { Self.SEC }
    var MIN: Double { Self.MIN }

    // MARK: - Creation

    @Test("createSession answerWith term: one question per card, user types the term")
    func createTerm() {
        let s = Self.ordered(Self.makeCards(4))
        #expect(s.v == 1)
        #expect(s.setOptions == SessionSetOptions(answerWith: .term, shuffle: false))
        #expect(s.subset == .all)
        #expect(s.order == ["c1:t", "c2:t", "c3:t", "c4:t"])
        #expect(s.queue == s.order)
        #expect(s.questions["c2:t"] == Q(qid: "c2:t", cardId: "c2", ask: .term))
        #expect(s.round == 1)
        #expect(s.roundAnswered.isEmpty)
        #expect(s.rounds.isEmpty)
        #expect(s.done.isEmpty)
        #expect(s.attempts == ["c1:t": 0, "c2:t": 0, "c3:t": 0, "c4:t": 0])
        #expect(s.misses["c3:t"] == 0)
        #expect(s.firstTry.isEmpty)
        #expect(s.startedAt == T0)
        #expect(s.updatedAt == T0)
        #expect(s.finishedAt == nil)
        #expect(s.elapsedMs == 0)
        #expect(!WriteSession.isFinished(s))
        #expect(!WriteSession.isRoundOver(s))
    }

    @Test("createSession answerWith definition: user types the definition")
    func createDefinition() {
        let s = Self.ordered(Self.makeCards(3), .definition)
        #expect(s.order == ["c1:d", "c2:d", "c3:d"])
        #expect(s.questions["c1:d"] == Q(qid: "c1:d", cardId: "c1", ask: .definition))
        #expect(WriteSession.current(s) == Q(qid: "c1:d", cardId: "c1", ask: .definition))
    }

    @Test("createSession answerWith both: two questions per card, unshuffled terms first")
    func createBoth() {
        let s = Self.ordered(Self.makeCards(3), .both)
        #expect(s.order == ["c1:t", "c2:t", "c3:t", "c1:d", "c2:d", "c3:d"])
        #expect(s.questions.count == 6)
        #expect(s.questions["c3:d"]?.ask == .definition)
        #expect(s.questions["c3:t"]?.ask == .term)
        #expect(WriteSession.counters(s).total == 6)
    }

    @Test("createSession shuffle is deterministic per seed and a permutation")
    func createShuffleDeterministic() {
        let cards = Self.makeCards(20)
        let a = Self.shuffled(cards, seed: 42)
        let b = Self.shuffled(cards, seed: 42)
        let c = Self.shuffled(cards, seed: 7)
        let plain = Self.ordered(cards)
        #expect(a.order == b.order)
        #expect(a.order != plain.order)
        #expect(a.order != c.order)
        #expect(a.order.sorted() == plain.order.sorted())
        #expect(a.queue == a.order)
        #expect(a.setOptions.shuffle)
    }

    @Test("createSession shuffle off keeps the card order")
    func createShuffleOff() {
        let cards = Self.makeCards(6)
        let s = Self.ordered(cards)
        #expect(Self.cardsOf(s, s.order) == cards.map(\.id))
    }

    @Test("createSession with both + shuffle never asks a card twice in a row")
    func createBothShuffleSeparatesSiblings() {
        for n in 2...6 {
            for seed in 1...100 {
                let s = Self.shuffled(Self.makeCards(n), .both, seed: seed)
                #expect(s.order.count == 2 * n)
                #expect(!Self.hasAdjacentSiblings(s, s.order), "adjacent siblings for n=\(n) seed=\(seed): \(s.order)")
            }
        }
    }

    @Test("createSession defaults: missing or invalid options")
    func createDefaults() {
        let s = WriteSession.createSession(Self.makeCards(3), options: .default, rng: mulberry32(seed: 3), now: T0)
        #expect(s.setOptions == SessionSetOptions(answerWith: .term, shuffle: true))
        let bogus = StudyOptions(json: ["answerWith": "bogus", "shuffle": false])
        let t = WriteSession.createSession(Self.makeCards(3), options: bogus, now: T0)
        #expect(t.setOptions.answerWith == .term)
        #expect(t.order == ["c1:t", "c2:t", "c3:t"])
        let u = WriteSession.createSession(Self.makeCards(2), answerWith: .term, shuffle: false)
        #expect(u.startedAt.isFinite && u.startedAt > 0)
        #expect(u.order.count == 2)
    }

    @Test("createSession skips cards with an empty side, duplicate ids and junk")
    func createSkipsJunk() {
        let raw: [JSONValue] = [
            ["id": "a", "term": "la rue", "definition": "die Strasse"],
            ["id": "b", "term": "  ", "definition": "leer"],
            ["id": "c", "term": "le nom", "definition": ""],
            ["id": "a", "term": "dup", "definition": "Duplikat"],
            nil,
            ["term": "ohne id", "definition": "x"],
            ["id": "d", "term": "calme", "definition": "ruhig"],
        ]
        let s = Self.ordered(raw.compactMap { Card(json: $0) })
        #expect(s.order == ["a:t", "d:t"])
        #expect(Self.ordered([]).order.isEmpty)
    }

    // MARK: - Subsets

    @Test("subset starred")
    func subsetStarred() {
        let s = Self.ordered(Self.makeCards(7), subset: .starred)  // starred: c1, c4, c7
        #expect(s.subset == .starred)
        #expect(s.order == ["c1:t", "c4:t", "c7:t"])
    }

    @Test("subset learning excludes mastered cards (streak >= 2)")
    func subsetLearning() {
        let progress: ProgressMap = [
            "c1": Self.progressEntry(2, 2, 0, .correct),  // mastered
            "c2": Self.progressEntry(1, 1, 1, .correct),  // learning
            "c3": Self.progressEntry(0, 0, 1, .incorrect),  // learning
            "c5": Self.progressEntry(3, 4, 1, .correct),  // mastered
        ]
        let s = Self.ordered(Self.makeCards(5), subset: .learning, progress: progress)
        #expect(s.order == ["c2:t", "c3:t", "c4:t"])
        let none = Self.ordered(Self.makeCards(2), subset: .learning)
        #expect(none.order == ["c1:t", "c2:t"])
    }

    @Test("subset cardIds keeps the set order and ignores unknown ids")
    func subsetCardIds() {
        let s = Self.ordered(Self.makeCards(6), subset: .cardIds(["c5", "x9", "c2", "c5"]))
        #expect(s.order == ["c2:t", "c5:t"])
        #expect(s.subset == .cardIds(["c5", "x9", "c2", "c5"]))
        let both = Self.ordered(Self.makeCards(6), .both, subset: .cardIds(["c3"]))
        #expect(both.order == ["c3:t", "c3:d"])
    }

    @Test("subset missed uses the last result in progress; unknown subset falls back to all")
    func subsetMissed() {
        let progress: ProgressMap = [
            "c2": Self.progressEntry(0, 1, 1, .incorrect), "c3": Self.progressEntry(1, 1, 1, .correct),
        ]
        let s = Self.ordered(Self.makeCards(4), subset: .missed, progress: progress)
        #expect(s.order == ["c2:t"])
        let all = Self.ordered(Self.makeCards(2), subset: StudySubset(json: "whatever"))
        #expect(all.subset == .all)
        #expect(all.order == ["c1:t", "c2:t"])
    }

    @Test("empty subset: zero questions, finished, every API safe")
    func emptySubset() {
        let cards = Self.makeCards(2).map { Card(id: $0.id, term: $0.term, definition: $0.definition, starred: false) }
        let s = Self.ordered(cards, subset: .starred)
        #expect(s.order.isEmpty)
        #expect(s.questions.isEmpty)
        #expect(WriteSession.isFinished(s))
        #expect(WriteSession.isRoundOver(s))
        #expect(s.finishedAt == T0)
        #expect(WriteSession.current(s) == nil)
        #expect(WriteSession.counters(s) == Self.counters(0, 0, 0, 0, 1, 0))
        #expect(
            WriteSession.roundSummary(s) == WriteSession.RoundSummary(round: 1, total: 0, correct: 0, incorrect: 0, items: []))
        #expect(WriteSession.answer(s, correct: true, now: T0 + SEC) == s)
        #expect(Self.next(s, now: T0 + SEC) == s)
        #expect(
            WriteSession.finalStats(s)
                == WriteSession.FinalStats(
                    total: 0, firstTryCorrect: 0, accuracy: 0, rounds: 0, elapsedMs: 0, hardest: [], missedCardIds: []))
        #expect(Self.ordered(Self.makeCards(3), subset: .cardIds([])).order.isEmpty)
    }

    // MARK: - Answering & counters

    @Test("answering flow: queue advances, misses are not retried in the same round")
    func answeringFlow() {
        var s = Self.ordered(Self.makeCards(4))
        #expect(WriteSession.current(s) == Q(qid: "c1:t", cardId: "c1", ask: .term))

        s = WriteSession.answer(s, correct: true, now: T0 + 10 * SEC)
        #expect(s.done == ["c1:t"])
        #expect(s.queue == ["c2:t", "c3:t", "c4:t"])
        #expect(s.roundAnswered == [A(qid: "c1:t", correct: true)])
        #expect(s.attempts["c1:t"] == 1)
        #expect(s.firstTry["c1:t"] == true)

        s = WriteSession.answer(s, correct: false, now: T0 + 20 * SEC)
        #expect(s.done == ["c1:t"])
        #expect(s.misses["c2:t"] == 1)
        #expect(s.firstTry["c2:t"] == false)
        #expect(WriteSession.current(s)?.qid == "c3:t")

        s = WriteSession.answer(s, correct: true, now: T0 + 30 * SEC)
        s = WriteSession.answer(s, correct: false, now: T0 + 40 * SEC)
        #expect(s.queue.isEmpty)
        #expect(WriteSession.current(s) == nil)
        #expect(WriteSession.isRoundOver(s))
        #expect(!WriteSession.isFinished(s))
        #expect(s.finishedAt == nil)
        #expect(s.roundAnswered.map(\.qid) == ["c1:t", "c2:t", "c3:t", "c4:t"])
        // Answering past the end of the round changes nothing.
        #expect(WriteSession.answer(s, correct: true, now: T0 + 50 * SEC) == s)
    }

    @Test("counters follow Quizlet semantics at every step")
    func countersSemantics() {
        var s = Self.ordered(Self.makeCards(4))
        #expect(WriteSession.counters(s) == Self.counters(4, 0, 0, 4, 1, 0))
        s = WriteSession.answer(s, correct: true, now: T0 + SEC)
        #expect(WriteSession.counters(s) == Self.counters(3, 1, 0, 4, 1, 0.25))
        s = WriteSession.answer(s, correct: false, now: T0 + 2 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(2, 1, 1, 4, 1, 0.25))
        s = WriteSession.answer(s, correct: false, now: T0 + 3 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(1, 1, 2, 4, 1, 0.25))
        s = WriteSession.answer(s, correct: true, now: T0 + 4 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(0, 2, 2, 4, 1, 0.5))
        s = Self.next(s, now: T0 + 5 * SEC)
        // New round: incorrect resets, correct stays overall.
        #expect(WriteSession.counters(s) == Self.counters(2, 2, 0, 4, 2, 0.5))
        s = WriteSession.answer(s, correct: false, now: T0 + 6 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(1, 2, 1, 4, 2, 0.5))
        s = WriteSession.answer(s, correct: true, now: T0 + 7 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(0, 3, 1, 4, 2, 0.75))
        s = Self.next(s, now: T0 + 8 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(1, 3, 0, 4, 3, 0.75))
        s = WriteSession.answer(s, correct: true, now: T0 + 9 * SEC)
        #expect(WriteSession.counters(s) == Self.counters(0, 4, 0, 4, 3, 1))
    }

    @Test("roundSummary lists the round answers in order")
    func roundSummaryOrder() {
        let s = Self.answerSeq(Self.ordered(Self.makeCards(4), .definition), [true, false, true, false])
        #expect(
            WriteSession.roundSummary(s)
                == WriteSession.RoundSummary(
                    round: 1, total: 4, correct: 2, incorrect: 2,
                    items: [
                        Self.item("c1:d", "c1", .definition, true), Self.item("c2:d", "c2", .definition, false),
                        Self.item("c3:d", "c3", .definition, true), Self.item("c4:d", "c4", .definition, false),
                    ]))
        // Mid-round the total still counts the questions not yet answered.
        let mid = Self.answerSeq(Self.ordered(Self.makeCards(4)), [false])
        #expect(
            WriteSession.roundSummary(mid)
                == WriteSession.RoundSummary(
                    round: 1, total: 4, correct: 0, incorrect: 1, items: [Self.item("c1:t", "c1", .term, false)]))
    }

    // MARK: - Rounds

    @Test("nextRound: closes the round, next queue = missed questions only")
    func nextRoundMissedOnly() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(5)), [true, false, true, false, false])
        s = Self.next(s, seed: 9, now: T0 + MIN)
        #expect(s.rounds == [R(round: 1, total: 5, correct: 2, incorrectQids: ["c2:t", "c4:t", "c5:t"])])
        #expect(s.round == 2)
        #expect(s.queue == ["c2:t", "c4:t", "c5:t"])
        #expect(s.roundAnswered.isEmpty)
        #expect(WriteSession.current(s)?.qid == "c2:t")
        #expect(WriteSession.roundSummary(s) == WriteSession.RoundSummary(round: 2, total: 3, correct: 0, incorrect: 0, items: []))
    }

    @Test("nextRound with shuffle: queue is a permutation of the missed questions")
    func nextRoundShufflePermutation() {
        var s = Self.shuffled(Self.makeCards(12), seed: 5)
        s = Self.answerSeq(s, [false, true, true, false, true, false, false, true, true, true, false, true])
        let missed = s.roundAnswered.filter { !$0.correct }.map(\.qid)
        let a = Self.next(s, seed: 77, now: T0 + MIN)
        let b = Self.next(s, seed: 77, now: T0 + MIN)
        #expect(a.queue == b.queue)
        #expect(a.queue.sorted() == missed.sorted())
        #expect(a.queue.count == 5)
    }

    @Test("nextRound in both-mode keeps a card’s two questions apart when possible")
    func nextRoundBothSeparatesSiblings() {
        for seed in 1...60 {
            var s = Self.shuffled(Self.makeCards(4), .both, seed: seed)
            s = Self.answerSeq(s, Array(repeating: false, count: 8))
            s = Self.next(s, seed: seed + 1000, now: T0 + MIN)
            #expect(s.queue.count == 8)
            #expect(!Self.hasAdjacentSiblings(s, s.queue), "adjacent siblings in round 2, seed \(seed): \(s.queue)")
        }
    }

    @Test("nextRound is a no-op while the round is still running")
    func nextRoundMidRound() {
        let s = Self.answerSeq(Self.ordered(Self.makeCards(3)), [false])
        #expect(Self.next(s, now: T0 + MIN) == s)
    }

    @Test("multi-round session runs until every question was answered correctly once")
    func multiRound() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(4)), [true, false, false, true])  // c2, c3 missed
        #expect(!WriteSession.isFinished(s))
        s = Self.next(s, now: T0 + MIN)
        #expect(s.queue == ["c2:t", "c3:t"])
        s = Self.answerSeq(s, [true, false], startAt: T0 + MIN)  // c3 missed again
        s = Self.next(s, now: T0 + 2 * MIN)
        #expect(s.round == 3)
        #expect(s.queue == ["c3:t"])
        s = WriteSession.answer(s, correct: true, now: T0 + 2 * MIN + 5 * SEC)
        #expect(WriteSession.isRoundOver(s))
        #expect(WriteSession.isFinished(s))
        #expect(s.finishedAt == T0 + 2 * MIN + 5 * SEC)
        #expect(s.done.sorted() == ["c1:t", "c2:t", "c3:t", "c4:t"])
        #expect(s.misses == ["c1:t": 0, "c2:t": 1, "c3:t": 2, "c4:t": 0])
        #expect(s.attempts == ["c1:t": 1, "c2:t": 2, "c3:t": 3, "c4:t": 1])

        // Closing the final round records it but does not start another one.
        let closed = Self.next(s, now: T0 + 3 * MIN)
        #expect(closed.round == 3)
        #expect(
            closed.rounds == [
                R(round: 1, total: 4, correct: 2, incorrectQids: ["c2:t", "c3:t"]),
                R(round: 2, total: 2, correct: 1, incorrectQids: ["c3:t"]),
                R(round: 3, total: 1, correct: 1, incorrectQids: []),
            ])
        #expect(closed.finishedAt == T0 + 2 * MIN + 5 * SEC)
        #expect(WriteSession.roundSummary(closed).items == [Self.item("c3:t", "c3", .term, true)])
        #expect(Self.next(closed, now: T0 + 4 * MIN) == closed)
        #expect(WriteSession.finalStats(closed).rounds == 3)
        #expect(WriteSession.finalStats(s).rounds == 3)
    }

    @Test("a perfect first round finishes immediately")
    func perfectRound() {
        let s = Self.answerSeq(Self.ordered(Self.makeCards(3)), [true, true, true])
        #expect(WriteSession.isFinished(s))
        #expect(s.finishedAt == T0 + 30 * SEC)
        let closed = Self.next(s, now: T0 + MIN)
        #expect(closed.round == 1)
        #expect(closed.rounds == [R(round: 1, total: 3, correct: 3, incorrectQids: [])])
        #expect(WriteSession.finalStats(closed).accuracy == 1)
    }

    // MARK: - Override

    @Test("override in-round on a first attempt: counts as correct, fixes firstTry, idempotent")
    func overrideInRound() {
        let s = Self.answerSeq(Self.ordered(Self.makeCards(3)), [false, false])  // c1, c2 missed; c3 pending
        #expect(WriteSession.counters(s) == Self.counters(1, 0, 2, 3, 1, 0))
        let o = WriteSession.override(s, qid: "c2:t", now: T0 + 25 * SEC)
        #expect(o.roundAnswered == [A(qid: "c1:t", correct: false), A(qid: "c2:t", correct: true)])
        #expect(o.done == ["c2:t"])
        #expect(o.misses["c2:t"] == 0)
        #expect(o.attempts["c2:t"] == 1)
        #expect(o.firstTry["c2:t"] == true)
        #expect(WriteSession.counters(o) == Self.counters(1, 1, 1, 3, 1, 1.0 / 3.0))
        #expect(WriteSession.current(o)?.qid == "c3:t")
        // Idempotent.
        let twice = WriteSession.override(o, qid: "c2:t", now: T0 + 26 * SEC)
        #expect(twice.done == ["c2:t"])
        #expect(twice.misses["c2:t"] == 0)
        #expect(WriteSession.counters(twice) == WriteSession.counters(o))
        // The overridden question is not part of the next round.
        var r = WriteSession.answer(o, correct: true, now: T0 + 30 * SEC)
        r = Self.next(r, now: T0 + MIN)
        #expect(r.queue == ["c1:t"])
        #expect(r.rounds.first == R(round: 1, total: 3, correct: 2, incorrectQids: ["c1:t"]))
    }

    @Test("override of a later-round answer keeps firstTry false")
    func overrideLaterRound() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(2)), [false, true])
        s = Self.next(s, now: T0 + MIN)
        s = WriteSession.answer(s, correct: false, now: T0 + MIN + 5 * SEC)  // c1 missed again in round 2
        #expect(s.misses["c1:t"] == 2)
        let o = WriteSession.override(s, qid: "c1:t", now: T0 + MIN + 8 * SEC)
        #expect(o.misses["c1:t"] == 1)
        #expect(o.attempts["c1:t"] == 2)
        #expect(o.firstTry["c1:t"] == false)
        #expect(WriteSession.isFinished(o))
        #expect(o.finishedAt == T0 + MIN + 8 * SEC)
        #expect(WriteSession.counters(o) == Self.counters(0, 2, 0, 2, 2, 1))
        #expect(WriteSession.finalStats(o).firstTryCorrect == 1)
    }

    @Test("override while the round summary is showing removes the miss from the next round")
    func overrideDuringSummary() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(4)), [true, false, true, false])
        #expect(WriteSession.isRoundOver(s))
        s = WriteSession.override(s, qid: "c4:t", now: T0 + MIN)
        #expect(WriteSession.roundSummary(s).correct == 3)
        #expect(WriteSession.roundSummary(s).incorrect == 1)
        #expect(WriteSession.counters(s).incorrect == 1)
        s = Self.next(s, now: T0 + 2 * MIN)
        #expect(s.queue == ["c2:t"])
        #expect(s.rounds.first == R(round: 1, total: 4, correct: 3, incorrectQids: ["c2:t"]))
    }

    @Test("override of the last miss during the summary finishes the session")
    func overrideLastMissFinishes() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(3)), [true, true, false])
        #expect(!WriteSession.isFinished(s))
        s = WriteSession.override(s, qid: "c3:t", now: T0 + MIN)
        #expect(WriteSession.isFinished(s))
        #expect(s.finishedAt == T0 + MIN)
        let closed = Self.next(s, now: T0 + 2 * MIN)
        #expect(closed.round == 1)
        #expect(closed.rounds == [R(round: 1, total: 3, correct: 3, incorrectQids: [])])
    }

    @Test("override right after nextRound applies to the just-closed round")
    func overrideAfterNextRound() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(4)), [false, true, false, true])
        s = Self.next(s, now: T0 + MIN)
        #expect(s.queue == ["c1:t", "c3:t"])
        s = WriteSession.override(s, qid: "c3:t", now: T0 + MIN + SEC)
        #expect(s.round == 2)
        #expect(s.queue == ["c1:t"])
        #expect(s.rounds == [R(round: 1, total: 4, correct: 3, incorrectQids: ["c1:t"])])
        #expect(s.firstTry["c3:t"] == true)
        #expect(s.done.contains("c3:t"))
        #expect(WriteSession.counters(s) == Self.counters(1, 3, 0, 4, 2, 0.75))

        // Overriding the remaining miss leaves the new round empty: the session ends with round 1.
        let f = WriteSession.override(s, qid: "c1:t", now: T0 + MIN + 2 * SEC)
        #expect(WriteSession.isFinished(f))
        #expect(f.round == 1)
        #expect(f.queue.isEmpty)
        #expect(f.rounds == [R(round: 1, total: 4, correct: 4, incorrectQids: [])])
        #expect(f.finishedAt == T0 + MIN + 2 * SEC)
        #expect(WriteSession.finalStats(f).rounds == 1)
        #expect(WriteSession.finalStats(f).accuracy == 1)
        #expect(Self.next(f, now: T0 + 2 * MIN) == f)
    }

    @Test("override is a no-op for correct, unanswered, unknown or older answers")
    func overrideNoOps() {
        let s = Self.answerSeq(Self.ordered(Self.makeCards(4)), [true, false])
        #expect(WriteSession.override(s, qid: "c1:t", now: T0 + MIN) == s)  // answered correctly
        #expect(WriteSession.override(s, qid: "c3:t", now: T0 + MIN) == s)  // not answered yet
        #expect(WriteSession.override(s, qid: "zz:t", now: T0 + MIN) == s)  // unknown
        #expect(WriteSession.override(s, qid: "", now: T0 + MIN) == s)

        // A miss from two rounds ago cannot be overridden once it was asked again.
        var r = Self.answerSeq(s, [true, true], startAt: T0 + 20 * SEC)
        r = Self.next(r, now: T0 + MIN)
        r = WriteSession.answer(r, correct: false, now: T0 + MIN + SEC)  // c2 missed again in round 2
        r = Self.next(r, now: T0 + 2 * MIN)
        let before = r
        let o = WriteSession.override(r, qid: "c2:t", now: T0 + 2 * MIN + SEC)  // miss of the just-closed round 2
        #expect(o.done.contains("c2:t"))
        #expect(r == before)
        let answered = WriteSession.answer(r, correct: false, now: T0 + 2 * MIN + SEC)  // round 3 miss
        let o3 = WriteSession.override(answered, qid: "c2:t", now: T0 + 2 * MIN + 2 * SEC)
        #expect(o3.roundAnswered == [A(qid: "c2:t", correct: true)])
        #expect(o3.rounds.count > 1 && o3.rounds[1] == R(round: 2, total: 1, correct: 0, incorrectQids: ["c2:t"]))
    }

    // MARK: - Final stats

    @Test("finalStats: accuracy, hardest ordering and missed cards")
    func finalStatsOrdering() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(5)), [false, true, false, false, true])  // c1, c3, c4 missed
        s = Self.next(s, now: T0 + MIN)
        s = Self.answerSeq(s, [true, false, false], startAt: T0 + MIN)  // c3, c4 missed
        s = Self.next(s, now: T0 + 2 * MIN)
        s = Self.answerSeq(s, [true, false], startAt: T0 + 2 * MIN)  // c4 missed
        s = Self.next(s, now: T0 + 3 * MIN)
        s = WriteSession.answer(s, correct: true, now: T0 + 3 * MIN + 10 * SEC)
        #expect(WriteSession.isFinished(s))
        let stats = WriteSession.finalStats(s)
        #expect(stats.total == 5)
        #expect(stats.firstTryCorrect == 2)
        #expect(stats.accuracy == 0.4)
        #expect(stats.rounds == 4)
        #expect(
            stats.hardest == [
                MissedCard(cardId: "c4", misses: 3), MissedCard(cardId: "c3", misses: 2),
                MissedCard(cardId: "c1", misses: 1),
            ])
        #expect(stats.missedCardIds == ["c1", "c3", "c4"])
        #expect(stats.elapsedMs == s.elapsedMs)
        #expect(stats.elapsedMs > 0)
    }

    @Test("finalStats: both directions add up per card, ties keep order, every missed card")
    func finalStatsBoth() {
        var s = Self.ordered(Self.makeCards(12), .both)
        // Round 1: every term question missed, every definition question correct except c12:d.
        let results = s.order.map { $0.hasSuffix(":d") && $0 != "c12:d" }
        s = Self.answerSeq(s, results)
        let stats = WriteSession.finalStats(s)
        #expect(stats.total == 24)
        #expect(stats.firstTryCorrect == 11)
        #expect(stats.accuracy == 11.0 / 24.0)
        #expect(stats.hardest.count == 12)
        #expect(stats.hardest.first == MissedCard(cardId: "c12", misses: 2))
        #expect(stats.hardest.dropFirst().map(\.cardId) == ["c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10", "c11"])
        #expect(stats.missedCardIds.count == 12)
        #expect(stats.missedCardIds.first == "c1")
    }

    // MARK: - removeCard

    @Test("removeCard mid-round removes all its questions everywhere")
    func removeCardMidRound() {
        let s = Self.answerSeq(Self.ordered(Self.makeCards(4), .both), [true, false, true])  // current c4:t
        let r = WriteSession.removeCard(s, cardId: "c2", now: T0 + MIN)
        #expect(!r.questions.keys.contains { $0.hasPrefix("c2:") })
        #expect(r.order == ["c1:t", "c3:t", "c4:t", "c1:d", "c3:d", "c4:d"])
        #expect(r.queue == ["c4:t", "c1:d", "c3:d", "c4:d"])
        #expect(r.roundAnswered == [A(qid: "c1:t", correct: true), A(qid: "c3:t", correct: true)])
        #expect(r.attempts["c2:t"] == nil)
        #expect(r.misses["c2:t"] == nil)
        #expect(r.firstTry["c2:t"] == nil)
        #expect(WriteSession.counters(r) == Self.counters(4, 2, 0, 6, 1, 2.0 / 6.0))
        #expect(WriteSession.finalStats(r).missedCardIds.isEmpty)
        // Unknown card: nothing changes.
        #expect(WriteSession.removeCard(s, cardId: "nope", now: T0 + MIN) == s)
    }

    @Test("removeCard of the current question moves on to the next one")
    func removeCardCurrent() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(3)), [false])
        #expect(WriteSession.current(s)?.cardId == "c2")
        s = WriteSession.removeCard(s, cardId: "c2", now: T0 + MIN)
        #expect(WriteSession.current(s)?.cardId == "c3")
        #expect(WriteSession.counters(s) == Self.counters(1, 0, 1, 2, 1, 0))
    }

    @Test("removeCard adjusts closed rounds and can finish the session")
    func removeCardClosedRounds() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(4)), [true, false, false, true])  // c2, c3 missed
        s = Self.next(s, now: T0 + MIN)
        s = Self.answerSeq(s, [true, false], startAt: T0 + MIN)  // c3 missed again
        s = Self.next(s, now: T0 + 2 * MIN)
        #expect(s.round == 3)
        #expect(s.queue == ["c3:t"])

        // Removing a done card changes the tallies of the rounds it took part in.
        let a = WriteSession.removeCard(s, cardId: "c2", now: T0 + 2 * MIN + SEC)
        #expect(
            a.rounds == [
                R(round: 1, total: 3, correct: 2, incorrectQids: ["c3:t"]),
                R(round: 2, total: 1, correct: 0, incorrectQids: ["c3:t"]),
            ])
        #expect(a.round == 3)
        #expect(!WriteSession.isFinished(a))

        // Removing the only open card ends the session; empty rounds are dropped.
        let b = WriteSession.removeCard(a, cardId: "c3", now: T0 + 2 * MIN + 2 * SEC)
        #expect(b.rounds == [R(round: 1, total: 2, correct: 2, incorrectQids: [])])
        #expect(b.round == 1)
        #expect(b.queue.isEmpty)
        #expect(WriteSession.isFinished(b))
        #expect(b.finishedAt == T0 + 2 * MIN + 2 * SEC)
        #expect(
            WriteSession.finalStats(b)
                == WriteSession.FinalStats(
                    total: 2, firstTryCorrect: 2, accuracy: 1, rounds: 1, elapsedMs: b.elapsedMs, hardest: [],
                    missedCardIds: []))
    }

    @Test("removeCard of every card leaves an empty finished session")
    func removeCardEvery() {
        var s = Self.answerSeq(Self.ordered(Self.makeCards(2)), [false])
        s = WriteSession.removeCard(s, cardId: "c1", now: T0 + MIN)
        s = WriteSession.removeCard(s, cardId: "c2", now: T0 + MIN)
        #expect(s.order.isEmpty)
        #expect(WriteSession.isFinished(s))
        #expect(s.finishedAt == T0 + MIN)
        #expect(WriteSession.counters(s).total == 0)
        #expect(WriteSession.finalStats(s).rounds == 0)
    }

    // MARK: - Time

    @Test("tick accumulates active time and ignores gaps longer than 5 minutes")
    func tickGaps() {
        var s = Self.ordered(Self.makeCards(2))
        s = WriteSession.tick(s, now: T0 + 30 * SEC)
        #expect(s.elapsedMs == 30 * SEC)
        s = WriteSession.tick(s, now: T0 + 30 * SEC + 5 * MIN)  // exactly 5 minutes still counts
        #expect(s.elapsedMs == 30 * SEC + 5 * MIN)
        s = WriteSession.tick(s, now: T0 + 30 * SEC + 5 * MIN + 2 * 60 * MIN)  // two hours away
        #expect(s.elapsedMs == 30 * SEC + 5 * MIN)
        #expect(s.updatedAt == T0 + 30 * SEC + 5 * MIN + 2 * 60 * MIN)
        s = WriteSession.tick(s, now: s.updatedAt + 10 * SEC)
        #expect(s.elapsedMs == 40 * SEC + 5 * MIN)
        let back = WriteSession.tick(s, now: s.updatedAt - 10 * SEC)  // clock went backwards
        #expect(back.elapsedMs == s.elapsedMs)
    }

    @Test("answers advance the clock and it stops once finished")
    func clockStopsWhenFinished() {
        var s = Self.ordered(Self.makeCards(2))
        s = WriteSession.answer(s, correct: true, now: T0 + 12 * SEC)
        #expect(s.elapsedMs == 12 * SEC)
        #expect(s.updatedAt == T0 + 12 * SEC)
        s = WriteSession.answer(s, correct: true, now: T0 + 20 * SEC)
        #expect(s.elapsedMs == 20 * SEC)
        #expect(WriteSession.isFinished(s))
        let later = WriteSession.tick(s, now: T0 + 60 * SEC)
        #expect(later.elapsedMs == 20 * SEC)
        #expect(WriteSession.finalStats(later).elapsedMs == 20 * SEC)
    }

    // MARK: - Serialisation & immutability

    @Test("state survives a JSON round-trip and continues identically")
    func jsonRoundTrip() throws {
        var s = Self.shuffled(Self.makeCards(8), .both, seed: 11)
        let decide = mulberry32(seed: 99)
        let outcomes = (0..<200).map { _ in decide() < 0.55 }
        var k = 0
        var t = T0
        func step(_ state: SessionState) -> SessionState {
            t += 7 * SEC
            if WriteSession.isRoundOver(state) {
                return WriteSession.nextRound(state, rng: mulberry32(seed: Int(t)), now: t)
            }
            defer { k += 1 }
            return WriteSession.answer(state, correct: outcomes[k % outcomes.count], now: t)
        }
        for _ in 0..<10 { s = step(s) }
        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(SessionState.self, from: data)
        #expect(restored == s)
        #expect(WriteSession.copyState(try JSONValue.parse(data)) == s)

        let tStart = t
        let kStart = k
        var a = s
        var guardCount = 0
        while !WriteSession.isFinished(a) && guardCount < 500 {
            a = step(a)
            guardCount += 1
        }
        t = tStart
        k = kStart
        var b = restored
        guardCount = 0
        while !WriteSession.isFinished(b) && guardCount < 500 {
            b = step(b)
            guardCount += 1
        }
        #expect(WriteSession.isFinished(a))
        #expect(b == a)
        #expect(WriteSession.finalStats(b) == WriteSession.finalStats(a))
    }

    @Test("functions never mutate their input state")
    func noMutation() throws {
        let s = Self.answerSeq(Self.shuffled(Self.makeCards(5), .both, seed: 3), [true, false, true, false])
        let before = try JSONValue(encoding: s)
        let qid = s.roundAnswered[1].qid
        let cardId = try #require(s.questions[qid]).cardId
        let results = [
            WriteSession.answer(s, correct: true, now: T0 + MIN),
            WriteSession.answer(s, correct: false, now: T0 + MIN),
            WriteSession.override(s, qid: qid, now: T0 + MIN),
            WriteSession.removeCard(s, cardId: cardId, now: T0 + MIN),
            WriteSession.tick(s, now: T0 + MIN),
        ]
        _ = WriteSession.current(s)
        _ = WriteSession.counters(s)
        _ = WriteSession.roundSummary(s)
        _ = WriteSession.finalStats(s)
        _ = WriteSession.isRoundOver(s)
        _ = WriteSession.isFinished(s)
        #expect(try JSONValue(encoding: s) == before)
        for r in results { #expect(r != s) }

        // Finish the round, then check nextRound too.
        var e = s
        while !WriteSession.isRoundOver(e) { e = WriteSession.answer(e, correct: false, now: T0 + 2 * MIN) }
        let endBefore = e
        let n = Self.next(e, seed: 5, now: T0 + 3 * MIN)
        #expect(n.round == 2)
        #expect(e == endBefore)
        // Changing a returned question does not leak into the state.
        var q = try #require(WriteSession.current(n))
        q.cardId = "changed"
        #expect(WriteSession.current(n)?.cardId != "changed")
    }

    @Test("defensive: a corrupt or partial state does not crash the engine")
    func defensive() {
        let partial = WriteSession.copyState([
            "questions": ["a:t": ["cardId": "a", "ask": "term"]], "order": ["a:t", "ghost:t"], "queue": ["a:t"],
        ])
        #expect(WriteSession.current(partial) == Q(qid: "a:t", cardId: "a", ask: .term))
        let s = WriteSession.answer(partial, correct: true, now: T0)
        #expect(WriteSession.isFinished(s))
        #expect(WriteSession.counters(s) == Self.counters(0, 1, 0, 1, 1, 1))
        #expect(WriteSession.counters(WriteSession.copyState(nil)).total == 0)
        #expect(WriteSession.isFinished(SessionState(json: nil)))
        // An open question that fell out of the queue is picked up again by nextRound.
        let stuck = WriteSession.copyState([
            "questions": ["a:t": ["cardId": "a", "ask": "term"]], "order": ["a:t"], "queue": [], "round": 1,
        ])
        #expect(WriteSession.isRoundOver(stuck))
        let refilled = Self.next(stuck, now: T0)
        #expect(refilled.queue == ["a:t"])
        #expect(refilled.round == 1)
        #expect(refilled.rounds.isEmpty)
    }

    // MARK: - Simulation

    @Test("simulation: invariants hold for random play until finished")
    func simulation() {
        for seed in 1...40 {
            let rng = mulberry32(seed: seed)
            let answerWith: AnswerWith = [.term, .definition, .both][seed % 3]
            var s = WriteSession.createSession(
                Self.makeCards(3 + seed % 9), answerWith: answerWith, shuffle: seed % 2 == 0, rng: rng, now: T0)
            let total = s.order.count
            var t = T0
            var expectedQueue: [String]?
            var guardCount = 0
            while !WriteSession.isFinished(s) {
                guardCount += 1
                guard guardCount <= 2000 else {
                    Issue.record("seed \(seed): did not finish")
                    break
                }
                t += 3 * SEC
                if WriteSession.isRoundOver(s) {
                    let missed = s.roundAnswered.filter { !$0.correct }.map(\.qid)
                    s = WriteSession.nextRound(s, rng: rng, now: t)
                    #expect(s.queue.sorted() == missed.sorted())
                    expectedQueue = s.queue
                    continue
                }
                if let expectedQueue, s.roundAnswered.isEmpty { #expect(s.queue == expectedQueue) }
                let before = WriteSession.counters(s)
                s = WriteSession.answer(s, correct: rng() < 0.6, now: t)
                let after = WriteSession.counters(s)
                #expect(after.remaining == before.remaining - 1)
                if rng() < 0.1, let last = s.roundAnswered.last, !last.correct {
                    s = WriteSession.override(s, qid: last.qid, now: t)
                }
            }
            s = WriteSession.nextRound(s, rng: rng, now: t + SEC)
            // Every question done exactly once; attempt bookkeeping is consistent.
            #expect(s.done.count == total)
            #expect(s.done.sorted() == s.order.sorted())
            for qid in s.order {
                // One correct (or overridden) answer per question; every other attempt was a miss.
                #expect(s.attempts[qid] == (s.misses[qid] ?? 0) + 1)
                #expect(s.firstTry[qid] == (s.attempts[qid] == 1))
            }
            // Rounds are numbered 1..k; their correct answers add up to the number of questions.
            #expect(s.rounds.map(\.round) == s.rounds.indices.map { $0 + 1 })
            #expect(s.rounds.reduce(0) { $0 + $1.correct } == total)
            #expect(s.rounds.first?.total == total)
            for i in s.rounds.indices.dropFirst() {
                #expect(s.rounds[i].total == s.rounds[i - 1].incorrectQids.count)
            }
            #expect(WriteSession.finalStats(s).rounds == s.rounds.count)
            #expect(WriteSession.counters(s).progress == 1)
        }
    }

    // MARK: - Swift API

    @Test("JSON encoding uses the web app's keys; finishedAt is an explicit null while running")
    func encodingShape() throws {
        let s = Self.ordered(Self.makeCards(2), subset: .cardIds(["c1", "c2"]))
        let json = try JSONValue(encoding: s)
        #expect(
            Set(json.objectValue?.keys.map { $0 } ?? []) == [
                "v", "setOptions", "subset", "questions", "order", "round", "queue", "roundAnswered", "rounds", "done",
                "attempts", "misses", "firstTry", "startedAt", "updatedAt", "finishedAt", "elapsedMs",
            ])
        #expect(json["finishedAt"] == .null)
        #expect(json["subset"] == ["cardIds": ["c1", "c2"]])
        #expect(json["setOptions"] == ["answerWith": "term", "shuffle": false])
        #expect(json["questions"]?["c1:t"] == ["qid": "c1:t", "cardId": "c1", "ask": "term"])
        let named = try JSONValue(encoding: Self.ordered(Self.makeCards(1), subset: .learning))
        #expect(named["subset"] == "learning")
    }

    @Test("a state stored by the web app is read as is")
    func readsWebAppJSON() throws {
        let stored = """
            {"v":1,"setOptions":{"answerWith":"both","shuffle":true},"subset":"starred",
             "questions":{"k1:t":{"qid":"k1:t","cardId":"k1","ask":"term"},"k1:d":{"qid":"k1:d","cardId":"k1","ask":"definition"}},
             "order":["k1:d","k1:t"],"round":2,"queue":["k1:t"],"roundAnswered":[],
             "rounds":[{"round":1,"total":2,"correct":1,"incorrectQids":["k1:t"]}],"done":["k1:d"],
             "attempts":{"k1:t":1,"k1:d":1},"misses":{"k1:t":1,"k1:d":0},"firstTry":{"k1:t":false,"k1:d":true},
             "startedAt":1760000000000,"updatedAt":1760000060000,"finishedAt":null,"elapsedMs":60000}
            """
        let json = try JSONValue.parse(stored)
        let strict = try JSONDecoder().decode(SessionState.self, from: Data(stored.utf8))
        let repaired = WriteSession.copyState(json)
        #expect(strict == repaired)
        #expect(repaired.setOptions == SessionSetOptions(answerWith: .both, shuffle: true))
        #expect(repaired.subset == .starred)
        #expect(WriteSession.current(repaired) == Q(qid: "k1:t", cardId: "k1", ask: .term))
        #expect(WriteSession.counters(repaired) == Self.counters(1, 1, 0, 2, 2, 0.5))
        #expect(try JSONValue(encoding: repaired) == json)
        let done = WriteSession.answer(repaired, correct: true, now: T0 + 70 * SEC)
        #expect(WriteSession.isFinished(done))
        #expect(done.finishedAt == T0 + 70 * SEC)
        #expect(done.elapsedMs == 70 * SEC)
    }

    @Test("copyState repairs a typed state like the JS copyState")
    func copyStateTyped() {
        let questions: [String: Q] = [
            "a:t": Q(qid: "a:t", cardId: "a", ask: .term),
            "b:t": Q(qid: "wrong", cardId: "b", ask: .definition),
        ]
        let broken = SessionState(
            setOptions: SessionSetOptions(answerWith: .term, shuffle: false), subset: .cardIds(["a", "", "b"]),
            questions: questions, order: ["a:t", "ghost", "a:t", "b:t"], round: 0, queue: ["b:t", "b:t", "x"],
            roundAnswered: [A(qid: "a:t", correct: false), A(qid: "nope", correct: true)],
            rounds: [R(round: 1, total: -2, correct: -1, incorrectQids: ["a:t", "a:t", "zz"])], done: ["zz"],
            attempts: ["a:t": -3, "zz": 4, "b:t": 2], misses: ["a:t": 1, "zz": 2], firstTry: ["a:t": false, "zz": true],
            startedAt: .nan, updatedAt: .infinity, finishedAt: nil, elapsedMs: -5)
        let s = WriteSession.copyState(broken)
        #expect(s.questions["b:t"] == Q(qid: "b:t", cardId: "b", ask: .definition))
        #expect(s.subset == .cardIds(["a", "b"]))
        #expect(s.order == ["a:t", "b:t"])
        #expect(s.round == 1)
        #expect(s.queue == ["b:t"])
        #expect(s.roundAnswered == [A(qid: "a:t", correct: false)])
        #expect(s.rounds == [R(round: 1, total: 0, correct: 0, incorrectQids: ["a:t"])])
        #expect(s.done.isEmpty)
        #expect(s.attempts == ["a:t": 0, "b:t": 2])
        #expect(s.misses == ["a:t": 1])
        #expect(s.firstTry == ["a:t": false])
        #expect(s.startedAt == 0)
        #expect(s.updatedAt == 0)
        #expect(s.elapsedMs == 0)
        #expect(WriteSession.copyState(s) == s)
        // Every engine function works on the repaired copy.
        #expect(WriteSession.current(broken) == Q(qid: "b:t", cardId: "b", ask: .definition))
        #expect(WriteSession.counters(broken) == Self.counters(1, 0, 1, 2, 1, 0))
    }

    @Test("copyState of raw JSON: junk types fall back to defaults")
    func copyStateJunk() {
        let s = WriteSession.copyState([
            "setOptions": ["answerWith": "bogus", "shuffle": 0],
            "subset": ["cardIds": ["c1", 5, nil, ""]],
            "questions": [
                "a:t": ["cardId": 7, "ask": "x"], "b:d": ["cardId": nil], "c:d": "junk", "d:d": ["cardId": "d", "ask": "definition"],
            ],
            "order": ["a:t", "d:d", 5, "a:t", "b:d"], "queue": "x", "round": 2.5,
            "roundAnswered": [["qid": "a:t", "correct": "yes"], "x", ["qid": "d:d", "correct": true]],
            "rounds": [nil, [], ["round": 2.5, "total": "x", "incorrectQids": ["d:d", "d:d"]], ["round": -1, "total": 3, "correct": 1]],
            "attempts": ["a:t": -2, "d:d": 3, "zz": 1], "misses": ["a:t": "x", "d:d": 1.5],
            "firstTry": ["a:t": "yes", "d:d": true],
            "startedAt": "x", "updatedAt": nil, "finishedAt": "x", "elapsedMs": -50,
        ])
        #expect(s.setOptions == SessionSetOptions(answerWith: .term, shuffle: true))
        #expect(s.subset == .cardIds(["c1", "5"]))
        #expect(s.questions == ["a:t": Q(qid: "a:t", cardId: "7", ask: .term), "d:d": Q(qid: "d:d", cardId: "d", ask: .definition)])
        #expect(s.order == ["a:t", "d:d"])
        #expect(s.queue.isEmpty)
        #expect(s.round == 1)
        #expect(s.roundAnswered == [A(qid: "a:t", correct: false), A(qid: "d:d", correct: true)])
        #expect(
            s.rounds == [
                R(round: 1, total: 0, correct: 0, incorrectQids: []), R(round: 2, total: 0, correct: 0, incorrectQids: ["d:d"]),
                R(round: -1, total: 3, correct: 1, incorrectQids: []),
            ])
        #expect(s.attempts == ["a:t": 0, "d:d": 3])
        // Fractional counts (never written by the web app) are rounded up.
        #expect(s.misses == ["a:t": 0, "d:d": 2])
        #expect(s.firstTry == ["d:d": true])
        #expect(s.startedAt == 0)
        #expect(s.updatedAt == 0)
        #expect(s.finishedAt == nil)
        #expect(s.elapsedMs == 0)
    }

    @Test("absurd typed counts are capped at 2^53 instead of overflowing")
    func overflowSafety() {
        var s = Self.ordered(Self.makeCards(2))
        s.attempts["c1:t"] = .max
        s.misses["c1:t"] = .max
        s.round = .max
        s.rounds = [R(round: .max, total: .max, correct: .max, incorrectQids: ["c1:t"])]
        s = WriteSession.answer(s, correct: false, now: T0 + SEC)
        s = WriteSession.answer(s, correct: true, now: T0 + 2 * SEC)
        s = WriteSession.override(s, qid: "c1:t", now: T0 + 3 * SEC)
        s = Self.next(s, now: T0 + 4 * SEC)
        let cap = 9_007_199_254_740_992
        #expect(s.round == cap)
        // Every call caps its input again: the miss pushed both counts to cap + 1, the override took one back.
        #expect(s.attempts["c1:t"] == cap)
        #expect(s.misses["c1:t"] == cap - 1)
        #expect(s.rounds == [R(round: cap, total: cap, correct: cap, incorrectQids: [])])
        #expect(WriteSession.isFinished(s))
    }

    @Test("blank sides use JS whitespace: NEL and zero-width space count as text")
    func jsWhitespace() {
        let cards = [
            Card(id: "nbsp", term: "\u{00A0}", definition: "x"), Card(id: "ideo", term: "a", definition: "\u{3000}\u{FEFF}"),
            Card(id: "ls", term: "\u{2028}", definition: "x"), Card(id: "nel", term: "\u{0085}", definition: "x"),
            Card(id: "zwsp", term: "a", definition: "\u{200B}"),
        ]
        #expect(Self.ordered(cards).order == ["nel:t", "zwsp:t"])
    }

    @Test("non-finite times leave the clock alone")
    func nonFiniteNow() {
        let created = WriteSession.createSession(Self.makeCards(1), answerWith: .term, shuffle: false, now: .nan)
        #expect(created.startedAt == 0)
        #expect(created.updatedAt == 0)
        var s = Self.ordered(Self.makeCards(2))
        s = WriteSession.tick(s, now: .infinity)
        #expect(s.updatedAt == T0)
        s = WriteSession.answer(s, correct: true, now: T0 + 5 * SEC)
        s = WriteSession.answer(s, correct: true, now: .nan)
        #expect(s.elapsedMs == 5 * SEC)
        #expect(s.finishedAt == T0 + 5 * SEC)
    }

    @Test("shuffling tolerates an rng returning values outside [0, 1)")
    func oddRNG() {
        for values in [[1.0], [-0.5], [Double.nan], [5.0], [0.999_999, -3, .infinity, 0.5]] {
            var i = 0
            let rng: RNG = {
                defer { i += 1 }
                return values[i % values.count]
            }
            let s = WriteSession.createSession(Self.makeCards(6), answerWith: .both, shuffle: true, rng: rng, now: T0)
            #expect(s.order.sorted() == Self.ordered(Self.makeCards(6), .both).order.sorted())
            #expect(i == 11)
        }
    }

    @Test("createSession(options:) reads answerWith and shuffle; qid(cardId:ask:)")
    func optionsOverload() {
        let options = StudyOptions(answerWith: .definition, shuffle: false)
        let s = WriteSession.createSession(Self.makeCards(2), options: options, now: T0)
        #expect(s.setOptions == SessionSetOptions(answerWith: .definition, shuffle: false))
        #expect(s.order == [WriteSession.qid(cardId: "c1", ask: .definition), WriteSession.qid(cardId: "c2", ask: .definition)])
        #expect(WriteSession.qid(cardId: "x", ask: .term) == "x:t")
    }
}
