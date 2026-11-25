import Foundation
import Testing
import WortschatzCore

/// Port of tests/learn.test.js (Learn mode engine), plus Swift-specific checks of the typed API
/// (repair of typed and JSON states, encoding, non-finite times, odd RNGs, the store round trip).
/// JS-only inputs (`null` cards, junk options, frozen objects) map to their typed equivalents.
@Suite("LearnEngine (learn.test.js)")
struct LearnEngineTests {
    static let T0: Double = 1_760_000_000_000
    static let SEC: Double = 1000
    static let MIN: Double = 60 * SEC
    var T0: Double { Self.T0 }
    var SEC: Double { Self.SEC }
    var MIN: Double { Self.MIN }

    typealias Q = LearnEngine.Question
    typealias Counts = LearnEngine.Counts
    typealias Item = LearnEngine.CheckpointItem

    static func makeCards(_ n: Int) -> [Card] {
        (0..<n).map { i in
            Card(id: "c\(i + 1)", term: "terme \(i + 1)", definition: "Begriff \(i + 1)", starred: i % 3 == 0)
        }
    }

    static func progressEntry(
        _ streak: Int, _ correct: Int? = nil, _ incorrect: Int = 0, _ lastResult: AnswerResult? = nil
    ) -> CardProgress {
        CardProgress(
            correct: correct ?? streak, incorrect: incorrect, streak: streak, streakBefore: 0,
            lastResult: lastResult ?? (streak > 0 ? .correct : .incorrect), lastAnsweredAt: T0 - 1000)
    }

    /// `createLearn(cards, { answerWith, learn }, { subset, progress, rng: mulberry32(seed), now })`.
    static func create(
        _ cards: [Card], _ answerWith: AnswerWith = .term, learn: LearnOptions = .default,
        subset: StudySubset = .all, progress: ProgressMap = [:], seed: Int, now: Double = T0
    ) -> LearnState {
        LearnEngine.createLearn(
            cards, answerWith: answerWith, learn: learn, subset: subset, progress: progress,
            rng: mulberry32(seed: seed), now: now)
    }

    static func next(_ s: LearnState, _ cards: [Card]?, seed: Int, now: Double) -> LearnState {
        LearnEngine.nextRound(s, cards: cards, rng: mulberry32(seed: seed), now: now)
    }

    /// Answers every remaining question of the round; decide(question, state) → correct.
    static func playRound(
        _ state: LearnState, startAt: Double = T0, _ decide: (Q, LearnState) -> Bool
    ) -> LearnState {
        var s = state
        var t = startAt
        var guardCount = 0
        while !LearnEngine.isRoundOver(s) {
            guardCount += 1
            precondition(guardCount <= 100, "round did not end")
            t += 5 * SEC
            s = LearnEngine.answer(s, correct: decide(LearnEngine.current(s)!, s), now: t)
        }
        return s
    }

    /// decide() from a per-card plan of results, consumed in order.
    final class Plan {
        var left: [String: [Bool]]
        init(_ plan: [String: [Bool]]) { left = plan }
        func decide(_ q: Q, _: LearnState) -> Bool {
            guard var list = left[q.cardId], !list.isEmpty else {
                Issue.record("no planned answer for \(q.cardId)")
                return false
            }
            let r = list.removeFirst()
            left[q.cardId] = list
            return r
        }
    }

    /// What db.recordAnswer stores for a sequence of answers.
    static func recorded(_ results: Bool...) -> CardProgress {
        var p: CardProgress?
        for ok in results { p = Mastery.applyAnswer(p, correct: ok, at: T0) }
        return p ?? .fresh
    }

    static func textKey(_ t: String) -> String { TextNormalizer.normalizeBasic(t).lowercased() }

    /// Exactly one correct option with the card's answer, distinct cards and texts, every text
    /// the owner's answer.
    static func checkChoices(
        _ choices: [Choice]?, cardId: String, ask: AskSide, cards: [Card], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let choices else {
            Issue.record("no choices", sourceLocation: sourceLocation)
            return
        }
        let card = cards.first { $0.id == cardId }!
        let correct = choices.filter { $0.cardId == cardId }
        #expect(correct.count == 1, sourceLocation: sourceLocation)
        #expect(correct.first?.text == Synonyms.answerSide(card, ask: ask), sourceLocation: sourceLocation)
        #expect(Set(choices.map(\.cardId)).count == choices.count, sourceLocation: sourceLocation)
        #expect(Set(choices.map { textKey($0.text) }).count == choices.count, sourceLocation: sourceLocation)
        for c in choices {
            let owner = cards.first { $0.id == c.cardId }!
            #expect(c.text == Synonyms.answerSide(owner, ask: ask), sourceLocation: sourceLocation)
        }
    }

    static func checkChoices(_ q: Q, _ cards: [Card], sourceLocation: SourceLocation = #_sourceLocation) {
        checkChoices(q.choices, cardId: q.cardId, ask: q.ask, cards: cards, sourceLocation: sourceLocation)
    }

    static func checkChoices(_ q: LearnQueueQuestion, _ cards: [Card], sourceLocation: SourceLocation = #_sourceLocation) {
        checkChoices(q.choices, cardId: q.cardId, ask: q.ask, cards: cards, sourceLocation: sourceLocation)
    }

    static func counts(_ fresh: Int, _ learning: Int, _ mastered: Int, _ total: Int) -> Counts {
        Counts(
            fresh: fresh, learning: learning, mastered: mastered, total: total,
            progress: total == 0 ? 0 : Double(mastered) / Double(total))
    }

    /// One answer of `playSession`: the question, its round, the other questions since the
    /// card's last answer (nil for its first) and the cards still open before it.
    struct LogEntry {
        let q: Q
        let round: Int
        let wait: Int?
        let open: Int
        let correct: Bool
    }

    /// Open cards as nextPick counts them for the front question: cards still to learn plus
    /// repetition questions and rechecks still to ask (`situation(s).open` in learn.test.js).
    static func openCount(_ s: LearnState) -> Int {
        let learning = s.order.count { (s.stage[$0] ?? 0) < 2 }
        let reviews =
            s.review.map { r in
                r.due.count { (s.stage[$0] ?? 0) >= 2 } + s.queue.count { LearnEngine.isReviewQuestion($0.qid) }
            } ?? 0
        let rechecks =
            s.recheck.map { r in
                r.due.count { (s.stage[$0] ?? 0) >= 2 } + s.queue.count { LearnEngine.isRecheckQuestion($0.qid) }
            } ?? 0
        return learning + reviews + rechecks
    }

    /// Plays a session to its end (nextRound between rounds) and closes it; decide(question,
    /// state) → correct.
    static func playSession(
        _ state: LearnState, _ cards: [Card], seed: Int = 1, start: Double = T0, _ decide: (Q, LearnState) -> Bool
    ) -> (s: LearnState, log: [LogEntry]) {
        let rng = mulberry32(seed: seed)
        var s = state
        var t = start
        var log: [LogEntry] = []
        var steps = 0
        while !LearnEngine.isFinished(s) {
            steps += 1
            precondition(steps <= 10_000, "session did not end")
            t += 3 * SEC
            guard let q = LearnEngine.current(s) else {
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t)
                continue
            }
            let wait = s.lastAt[q.cardId].map { s.clock - $0 - 1 }
            let ok = decide(q, s)
            log.append(LogEntry(q: q, round: s.round, wait: wait, open: openCount(s), correct: ok))
            s = LearnEngine.answer(s, correct: ok, now: t)
        }
        return (LearnEngine.nextRound(s, cards: cards, rng: rng, now: t + MIN), log)
    }

    /// A stored state with a hand-made spacing situation; nextRound plans its next round. Cards
    /// not in `stage` are new (stage 0), cards not in `lastAt` were not asked in this session.
    static func planFrom(
        _ cards: [Card], stage: [String: Int] = [:], lastAt: [String: Int] = [:], clock: Int = 0, repeats: Int = 0,
        seed: Int = 1, roundSize: Int = 7
    ) -> LearnState {
        let order = cards.map(\.id)
        var stages: [String: JSONValue] = [:]
        for id in order { stages[id] = .number(Double(stage[id] ?? 0)) }
        let raw: JSONValue = .object([
            "v": 1, "order": .array(order.map { .string($0) }), "stage": .object(stages),
            "learn": ["roundSize": .number(Double(roundSize))], "clock": .number(Double(clock)),
            "lastAt": .object(lastAt.mapValues { .number(Double($0)) }), "repeats": .number(Double(repeats)),
            "queue": [], "roundLog": [], "answered": .number(Double(clock)), "correct": .number(Double(clock)),
        ])
        return LearnEngine.nextRound(LearnEngine.copyState(raw), cards: cards, rng: mulberry32(seed: seed), now: T0)
    }

    /// lastAt so that card i has waited waits[i] other questions at `clock`.
    static func lastAtFor(_ ids: [String], _ waits: [Int], _ clock: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, id) in ids.enumerated() { out[id] = clock - 1 - waits[i] }
        return out
    }

    // MARK: - Constants & stages

    @Test func defaultLearnMatchesTheSpec() {
        #expect(LearnEngine.DEFAULT_LEARN == LearnOptions(roundSize: 7, mc: true, written: true, retype: false))
        #expect(LearnEngine.MAX_CHOICES == 4)
    }

    @Test func stageFromProgressIsMinOfStreakAndTwo() {
        #expect(LearnEngine.stageFromProgress(nil) == 0)
        #expect(LearnEngine.stageFromProgress(CardProgress()) == 0)
        #expect(LearnEngine.stageFromProgress(Self.progressEntry(0, 0, 1)) == 0)
        #expect(LearnEngine.stageFromProgress(Self.progressEntry(1)) == 1)
        #expect(LearnEngine.stageFromProgress(Self.progressEntry(2)) == 2)
        #expect(LearnEngine.stageFromProgress(Self.progressEntry(7, 9, 2)) == 2)
        #expect(LearnEngine.stageFromProgress(CardProgress(streak: -3)) == 0)
        #expect(LearnEngine.stageFromProgress(CardProgress(json: ["streak": "x"])) == 0)
        #expect(LearnEngine.stageFromProgress(CardProgress(json: ["streak": 1.9])) == 1)
        #expect(LearnEngine.stageFromProgress(CardProgress(json: "junk")) == 0)
    }

    // MARK: - createLearn

    @Test func stateShapeForASetOfNewCards() {
        let cards = Self.makeCards(10)
        let s = Self.create(cards, seed: 1)
        #expect(s.v == 1)
        #expect(s.subset == .all)
        #expect(s.answerWith == .term)
        #expect(s.learn == LearnSessionOptions(roundSize: 7, mc: true, written: true))
        #expect(s.order.sorted() == cards.map(\.id).sorted())
        #expect(s.stage.values.allSatisfy { $0 == 0 } && s.stage.count == 10)
        #expect(s.initiallyMastered.isEmpty)
        #expect(s.round == 1)
        // The round's questions are planned at once: seven new cards, in session order.
        #expect(s.queue.count == 7)
        #expect(s.queue.map(\.cardId) == Array(s.order.prefix(7)))
        for q in s.queue {
            #expect(q.qid == "1.1:\(q.cardId)")
            #expect(q.type == .mc)
            #expect(q.ask == .term)
            #expect(q.choices?.count == 4)
            #expect(q.retryChoices?.count == 4)
            Self.checkChoices(q, cards)
        }
        // Spacing: nothing answered yet.
        #expect(s.clock == 0 && s.lastAt.isEmpty && s.repeats == 0)
        // The options are opt-in.
        #expect(s.review == nil && s.recheck == nil)
        #expect(s.roundLog.isEmpty && s.rounds.isEmpty)
        #expect(s.answered == 0 && s.correct == 0 && s.misses.isEmpty && s.last == nil)
        #expect(s.startedAt == T0 && s.updatedAt == T0 && s.finishedAt == nil && s.elapsedMs == 0)
        #expect(LearnEngine.counts(s) == Self.counts(10, 0, 0, 10))
        #expect(!LearnEngine.isFinished(s))
        #expect(!LearnEngine.isRoundOver(s))
        // current() is the front of the queue, without internal fields.
        #expect(
            LearnEngine.current(s)
                == Q(qid: s.queue[0].qid, cardId: s.queue[0].cardId, type: .mc, ask: .term, choices: s.queue[0].choices))
    }

    @Test func deterministicPerSeedOrderShuffledOnce() {
        let cards = Self.makeCards(12)
        let a = Self.create(cards, seed: 42)
        let b = Self.create(cards, seed: 42)
        let c = Self.create(cards, seed: 7)
        #expect(a == b)
        #expect(a.order != c.order)
        #expect(a.order != cards.map(\.id))
        #expect(a.order.sorted() == cards.map(\.id).sorted())
    }

    @Test func learnOptionsAreNormalisedAndRetypeIsAUIOptionOnly() {
        let cards = Self.makeCards(10)
        let s = Self.create(cards, learn: LearnOptions(roundSize: 3, mc: false, written: true, retype: true), seed: 1)
        #expect(s.learn == LearnSessionOptions(roundSize: 3, mc: false, written: true))
        #expect(s.queue.count == 3)
        #expect(s.queue.allSatisfy { $0.type == .written && $0.choices == nil && $0.retryChoices == nil })
        for bad in [0, -2] {
            #expect(Self.create(cards, learn: LearnOptions(roundSize: bad), seed: 1).learn.roundSize == 7)
        }
        for bad: JSONValue in ["x", nil, true] {
            #expect(Self.create(cards, learn: LearnOptions(json: ["roundSize": bad]), seed: 1).learn.roundSize == 7)
        }
        #expect(Self.create(cards, learn: LearnOptions(json: ["roundSize": 4.8]), seed: 1).learn.roundSize == 4)
        #expect(
            Self.create(cards, learn: LearnOptions(mc: false, written: false), seed: 1).learn
                == LearnSessionOptions(roundSize: 7, mc: true, written: true))
        let d = LearnEngine.createLearn(cards, options: .default, rng: mulberry32(seed: 1), now: T0)
        #expect(d.answerWith == .term)
        #expect(d.learn == LearnSessionOptions(roundSize: 7, mc: true, written: true))
        #expect(Self.create(cards, .definition, seed: 1).answerWith == .definition)
        let u = LearnEngine.createLearn(Self.makeCards(2), options: .default)
        #expect(u.startedAt > 0)
    }

    @Test func skipsCardsWithAnEmptySideDuplicateIdsAndJunk() {
        let cards = [
            Card(id: "a", term: "la rue", definition: "die Strasse"),
            Card(id: "b", term: "  ", definition: "leer"),
            Card(id: "c", term: "le nom", definition: ""),
            Card(id: "a", term: "dup", definition: "Duplikat"),
            Card(id: "", term: "ohne id", definition: "x"),
            Card(id: "d", term: "calme", definition: "ruhig"),
        ]
        let s = Self.create(cards, seed: 1)
        #expect(s.order.sorted() == ["a", "d"])
        // Two open cards: each comes back after one other question (a d a d).
        #expect(s.queue.map(\.cardId) == s.order + s.order)
        // Only askable cards serve as options: "la rue" vs "calme".
        for q in s.queue {
            if q.type == .mc { #expect(q.choices?.map(\.cardId).sorted() == ["a", "d"]) }
            #expect(q.retryChoices?.map(\.cardId).sorted() == ["a", "d"])
        }
        let empty = LearnEngine.createLearn([], options: .default, now: T0)
        #expect(empty.order.isEmpty)
        #expect(LearnEngine.isFinished(empty))
    }

    @Test func stageInitialisationFromProgress() {
        let cards = Self.makeCards(6)
        let progress = [
            "c1": Self.progressEntry(2),  // mastered
            "c2": Self.progressEntry(1),  // familiar → written
            "c3": Self.progressEntry(0, 1, 1, .incorrect),  // reset after a right answer → written, not fresh
            "c4": Self.progressEntry(5, 6, 1),  // mastered
            "c6": Self.progressEntry(0, 0, 2, .incorrect),  // never right → mc, not fresh
        ]
        let s = Self.create(cards, progress: progress, seed: 3)
        var stages: [String: Int] = [:]
        for id in s.order { stages[id] = 0 }
        stages["c1"] = 2
        stages["c2"] = 1
        stages["c4"] = 2
        #expect(s.stage == stages)
        #expect(s.solved == ["c1": true, "c2": true, "c3": true, "c4": true])
        #expect(s.initiallyMastered.sorted() == ["c1", "c4"])
        #expect(s.initiallyMastered == s.order.filter { $0 == "c1" || $0 == "c4" })
        #expect(Set(s.queue.map(\.cardId)) == ["c2", "c3", "c5", "c6"])
        #expect(s.queue[0].cardId == "c2")  // stage-1 cards first
        #expect(!s.queue.contains { $0.cardId == "c1" || $0.cardId == "c4" })
        // Every card's first question follows its stage.
        var byCard: [String: LearnQueueQuestion] = [:]
        for q in s.queue where byCard[q.cardId] == nil { byCard[q.cardId] = q }
        #expect(byCard["c2"]?.type == .written)
        #expect(byCard["c2"]?.choices == nil)
        #expect(byCard["c3"]?.type == .written)
        #expect(byCard["c3"]?.retryChoices?.count == 4)
        #expect(byCard["c5"]?.type == .mc)
        #expect(byCard["c6"]?.type == .mc)
        // Planned as if every answer were right: c2 is mastered with one question, the others
        // need two.
        #expect(s.queue.count { $0.cardId == "c2" } == 1)
        #expect(LearnEngine.counts(s) == Self.counts(1, 3, 2, 6))
        #expect(!LearnEngine.isFinished(s))
    }

    @Test func newCardsComeStageOneCardsFirstThenStageZeroInOrder() {
        let cards = Self.makeCards(10)
        let progress = ["c8": Self.progressEntry(1), "c9": Self.progressEntry(1)]
        let s = Self.create(cards, learn: LearnOptions(roundSize: 4), progress: progress, seed: 11)
        let ones = s.order.filter { $0 == "c8" || $0 == "c9" }
        let zeros = s.order.filter { $0 != "c8" && $0 != "c9" }
        #expect(s.queue.map(\.cardId) == ones + zeros.prefix(2))
        #expect(s.queue.map(\.type) == [.written, .written, .mc, .mc])
    }

    @Test func everythingAlreadyMasteredAtStart() {
        let cards = Self.makeCards(3)
        let progress = ["c1": Self.progressEntry(2), "c2": Self.progressEntry(3), "c3": Self.progressEntry(2)]
        let s = Self.create(cards, progress: progress, seed: 1)
        #expect(s.queue.isEmpty)
        #expect(LearnEngine.current(s) == nil)
        #expect(LearnEngine.isRoundOver(s))
        #expect(LearnEngine.isFinished(s))
        #expect(s.finishedAt == T0)
        #expect(s.initiallyMastered.count == 3)
        #expect(LearnEngine.counts(s) == Self.counts(0, 0, 3, 3))
        #expect(
            LearnEngine.finalStats(s)
                == LearnEngine.FinalStats(
                    total: 3, mastered: 3, alreadyMastered: 3, rounds: 0, answered: 0, accuracy: 0, elapsedMs: 0,
                    hardest: []))
        #expect(LearnEngine.answer(s, correct: true, now: T0 + SEC) == s)
        #expect(Self.next(s, cards, seed: 1, now: T0 + SEC) == s)
    }

    @Test func emptyScopeZeroCardsFinishedEveryAPISafe() {
        let cards = Self.makeCards(2).map { Card(id: $0.id, term: $0.term, definition: $0.definition, starred: false) }
        let s = Self.create(cards, subset: .starred, seed: 1)
        #expect(s.order.isEmpty)
        #expect(LearnEngine.isFinished(s))
        #expect(s.finishedAt == T0)
        #expect(LearnEngine.current(s) == nil)
        #expect(LearnEngine.counts(s) == Self.counts(0, 0, 0, 0))
        #expect(
            LearnEngine.checkpoint(s)
                == LearnEngine.Checkpoint(
                    round: 1, answered: 0, correct: 0, items: [],
                    counts: LearnEngine.CheckpointCounts(fresh: 0, learning: 0, mastered: 0, total: 0)))
        #expect(LearnEngine.override(s, now: T0 + SEC) == s)
        #expect(LearnEngine.removeCard(s, cardId: "c1", now: T0 + SEC) == s)
        #expect(Self.next(s, cards, seed: 1, now: T0 + SEC) == s)
        #expect(LearnEngine.finalStats(s).rounds == 0)
    }

    @Test func subsetsStarredCardIdsLearningMissedAndUnknown() {
        let cards = Self.makeCards(7)  // starred: c1, c4, c7
        #expect(Self.create(cards, subset: .starred, seed: 5).order.sorted() == ["c1", "c4", "c7"])
        let ids = Self.create(cards, subset: .cardIds(["c5", "x9", "c2"]), seed: 5)
        #expect(ids.order.sorted() == ["c2", "c5"])
        #expect(ids.subset == .cardIds(["c5", "x9", "c2"]))
        let progress = [
            "c1": Self.progressEntry(2), "c2": Self.progressEntry(0, 1, 1, .incorrect), "c3": Self.progressEntry(1),
        ]
        let learning = Self.create(cards, subset: .learning, progress: progress, seed: 5)
        #expect(!learning.order.contains("c1"))
        #expect(learning.order.count == 6)
        #expect(learning.initiallyMastered.isEmpty)
        #expect(Self.create(cards, subset: .missed, progress: progress, seed: 5).order == ["c2"])
        let all = Self.create(cards, subset: StudySubset(json: "whatever"), seed: 5)
        #expect(all.subset == .all)
        #expect(all.order.count == 7)
    }

    // MARK: - Answering

    @Test func aNewCardIsAskedMcThenWrittenAndMasteredAfterBoth() {
        let cards = Self.makeCards(6)
        var s = Self.create(cards, seed: 2)
        let id = LearnEngine.current(s)!.cardId
        #expect(LearnEngine.current(s)?.type == .mc)
        s = LearnEngine.answer(s, correct: true, now: T0 + 10 * SEC)
        #expect(s.stage[id] == 1)
        #expect(
            s.roundLog == [
                LearnRoundLogEntry(qid: "1.1:\(id)", cardId: id, type: .mc, ask: .term, correct: true, stageAfter: 1)
            ])
        #expect(s.last == LearnLastAnswer(qid: "1.1:\(id)", cardId: id, type: .mc, ask: .term, correct: true, stageBefore: 0))
        #expect(s.clock == 1)
        #expect(s.lastAt == [id: 0])
        // Six open cards: it comes back after the five others (min(10, open - 1)), written.
        #expect(s.queue.map(\.cardId) == Array(s.order.dropFirst()) + [id])
        let again = s.queue[5]
        #expect(again.qid == "1.1.2:\(id)")
        #expect(again.type == .written)
        #expect(again.choices == nil)
        s = Self.playRound(s, startAt: T0 + 10 * SEC) { _, _ in true }
        #expect(s.stage[id] == 2)
        #expect(
            s.roundLog[6]
                == LearnRoundLogEntry(qid: "1.1.2:\(id)", cardId: id, type: .written, ask: .term, correct: true, stageAfter: 2))
        #expect(LearnEngine.counts(s) == Self.counts(0, 5, 1, 6))
        s = Self.next(s, cards, seed: 3, now: T0 + MIN)
        #expect(s.round == 2)
        // The other five come back written, the one asked longest ago first.
        #expect(s.queue.map(\.cardId) == Array(s.order.dropFirst()))
        for q in s.queue {
            #expect(q.type == .written)
            #expect(q.choices == nil)
            #expect(q.qid == "2.1:\(q.cardId)")
        }
        s = Self.playRound(s, startAt: T0 + MIN) { _, _ in true }
        #expect(LearnEngine.isFinished(s))
        #expect(s.answered == 12)
        #expect(LearnEngine.counts(s) == Self.counts(0, 0, 6, 6))
    }

    @Test func multipleChoiceOnlyUntilACardWasAnsweredRightOnce() {
        let cards = Self.makeCards(2)
        let learn = LearnOptions(roundSize: 4)
        func types(_ st: LearnState, _ id: String) -> [QuestionType] { st.queue.filter { $0.cardId == id }.map(\.type) }
        var s = Self.create(cards, learn: learn, seed: 12)
        let a = s.order[0]
        let b = s.order[1]
        #expect(s.queue.map(\.cardId) == [a, b, a, b])
        #expect(s.queue.map(\.type) == [.mc, .mc, .written, .written])
        // A multiple-choice miss: the card's later question is multiple choice again.
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        #expect(s.solved.isEmpty)
        #expect(types(s, a) == [.mc])
        Self.checkChoices(s.queue.first { $0.cardId == a }!, cards)
        // Right once: written from then on.
        s = LearnEngine.answer(s, correct: true, now: T0 + 2 * SEC)
        #expect(s.solved == [b: true])
        #expect(types(s, b) == [.written])
        s = LearnEngine.answer(s, correct: true, now: T0 + 3 * SEC)
        #expect(s.solved == [a: true, b: true])
        // A written miss resets the stage, but the card stays written.
        #expect(LearnEngine.current(s) == Q(qid: "1.1.2:\(b)", cardId: b, type: .written, ask: .term))
        s = LearnEngine.answer(s, correct: false, now: T0 + 4 * SEC)
        #expect(s.stage[b] == 0)
        #expect(s.solved == [a: true, b: true])
        #expect(LearnEngine.isRoundOver(s))
        s = Self.next(s, cards, seed: 13, now: T0 + MIN)
        #expect(types(s, b) == [.written, .written])
        #expect(s.queue.allSatisfy { $0.type == .written })
        let (_, log) = Self.playSession(s, cards, seed: 14) { _, _ in true }
        #expect(log.allSatisfy { $0.q.type == .written })

        // "Ich hatte recht" after a multiple-choice miss counts as right.
        var o = Self.create(cards, learn: learn, seed: 12)
        o = LearnEngine.answer(o, correct: false, now: T0 + SEC)
        o = LearnEngine.override(o, now: T0 + 2 * SEC)
        #expect(o.solved == [a: true])
        #expect(types(o, a) == [.written])

        // Answered right elsewhere (Write mode) and then wrong: still stage 0, but written.
        var w = Self.create(cards, learn: learn, seed: 12)
        let elsewhere: ProgressMap = [a: Self.progressEntry(0, 1, 1, .incorrect)]
        #expect(LearnEngine.solvedFromProgress(elsewhere[a]))
        #expect(!LearnEngine.solvedFromProgress(Self.progressEntry(0, 0, 3, .incorrect)))
        #expect(!LearnEngine.solvedFromProgress(nil))
        #expect(!LearnEngine.matchesProgress(w, progress: elsewhere))
        w = LearnEngine.syncProgress(w, progress: elsewhere, now: T0 + SEC)
        #expect(w.stage[a] == 0)
        #expect(w.solved == [a: true])
        #expect(types(w, a) == [.written, .written])
        #expect(types(w, b) == [.mc, .written])
        #expect(LearnEngine.matchesProgress(w, progress: elsewhere))
        // Progress reset: multiple choice again, with the options the questions kept.
        let before = w
        w = LearnEngine.syncProgress(w, progress: [:], now: T0 + 2 * SEC)
        #expect(w.solved.isEmpty)
        #expect(types(w, a) == [.mc, .mc])
        for (i, q) in w.queue.enumerated() where q.cardId == a { #expect(q.choices == before.queue[i].retryChoices) }

        // A session stored before 24.11.2026 has no `solved`: cards past stage 0 count as solved.
        guard case var .object(raw) = try? JSONValue(encoding: s) else {
            Issue.record("not an object")
            return
        }
        raw["solved"] = nil
        let restored = LearnEngine.copyState(.object(raw))
        #expect(restored.solved == s.order.reduce(into: [:]) { out, id in if (s.stage[id] ?? 0) > 0 { out[id] = true } })
    }

    @Test func aWrongWrittenAnswerResetsTheStageButStaysWritten() {
        let cards = Self.makeCards(5)
        var progress: ProgressMap = [:]
        for c in cards { progress[c.id] = Self.progressEntry(1) }
        var s = Self.create(cards, progress: progress, seed: 4)
        // Planned as if every answer were right: one written question per card masters it.
        #expect(s.queue.map(\.cardId) == s.order)
        #expect(s.queue.allSatisfy { $0.type == .written })
        let id = LearnEngine.current(s)!.cardId
        s = LearnEngine.answer(s, correct: false, now: T0 + 10 * SEC)
        #expect(s.stage[id] == 0)
        #expect(
            s.last == LearnLastAnswer(qid: "1.1:\(id)", cardId: id, type: .written, ask: .term, correct: false, stageBefore: 1))
        // No retry at the end of the round.
        #expect(!s.queue.contains { $0.cardId == id })
        s = Self.playRound(s, startAt: T0 + 10 * SEC) { _, _ in true }
        #expect(LearnEngine.checkpoint(s).items.first { $0.cardId == id } == Item(cardId: id, stage: 0, results: [false]))
        s = Self.next(s, cards, seed: 5, now: T0 + MIN)
        // The only open card, answered right before: written twice (nothing else to wait for).
        #expect(s.solved[id] == true)
        #expect(s.queue.map(\.qid) == ["2.1:\(id)", "2.1.2:\(id)"])
        #expect(s.queue.map(\.type) == [.written, .written])
        s = LearnEngine.answer(s, correct: true, now: T0 + MIN + 5 * SEC)
        #expect(s.stage[id] == 1)
        #expect(!LearnEngine.isFinished(s))
        s = LearnEngine.answer(s, correct: true, now: T0 + MIN + 10 * SEC)
        #expect(LearnEngine.isFinished(s))
    }

    @Test func aWrongAnswerIsNotRetriedAtTheEndOfTheRoundTheCardComesBackAfterTheGap() {
        let cards = Self.makeCards(20)
        var s = Self.create(cards, seed: 6)
        let id = LearnEngine.current(s)!.cardId
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        #expect(s.misses == [id: 1])
        #expect(s.queue.map(\.cardId) == Array(s.order[1..<7]))
        let r = Self.playRound(s, startAt: T0 + SEC) { _, _ in true }
        #expect(r.roundLog.count { $0.cardId == id } == 1)
        // Answering past the end of the round changes nothing.
        #expect(LearnEngine.answer(r, correct: true, now: T0 + MIN) == r)
        let (_, log) = Self.playSession(s, cards, seed: 7) { _, _ in true }
        let back = log.first { $0.q.cardId == id }!
        #expect((back.wait ?? -1) >= LearnEngine.MIN_GAP)
        #expect((back.wait ?? .max) <= LearnEngine.MAX_WAIT)
        #expect(back.round > 1)
        #expect(back.q.qid == "\(back.round).1:\(id)")
        #expect(back.q.type == .mc)
    }

    @Test func nextRoundIsANoOpWhileTheRoundIsStillRunning() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 1)
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        #expect(Self.next(s, cards, seed: 1, now: T0 + MIN) == s)
    }

    // MARK: - Rounds

    @Test func nextRoundMasteredCardsLeaveThenNewCardsComeStageOneBeforeStageZero() {
        let cards = Self.makeCards(8)
        let progress = [
            "c2": Self.progressEntry(1), "c4": Self.progressEntry(1), "c6": Self.progressEntry(1),
            "c8": Self.progressEntry(1),
        ]
        var s = Self.create(cards, learn: LearnOptions(roundSize: 3), progress: progress, seed: 4)
        let ones = s.order.filter { progress[$0] != nil }
        let zeros = s.order.filter { progress[$0] == nil }
        #expect(s.queue.map(\.cardId) == Array(ones.prefix(3)))
        #expect(s.queue.allSatisfy { $0.type == .written })
        s = Self.playRound(s) { _, _ in true }
        #expect(ones.prefix(3).allSatisfy { s.stage[$0] == 2 })
        s = Self.next(s, cards, seed: 5, now: T0 + MIN)
        #expect(s.round == 2)
        #expect(s.rounds == [LearnRoundRecord(round: 1, answered: 3, correct: 3, cardIds: Array(ones.prefix(3)))])
        #expect(s.queue.map(\.cardId) == [ones[3], zeros[0], zeros[1]])
        let types = Dictionary(uniqueKeysWithValues: s.queue.map { ($0.cardId, $0.type) })
        #expect(types == [ones[3]: .written, zeros[0]: .mc, zeros[1]: .mc])
    }

    @Test func nextRoundAMissedCardStaysOpenAndComesBackOnceItWaitedItsGap() {
        let cards = Self.makeCards(8)
        let progress = [
            "c2": Self.progressEntry(1), "c4": Self.progressEntry(1), "c6": Self.progressEntry(1),
            "c8": Self.progressEntry(1),
        ]
        var s = Self.create(cards, learn: LearnOptions(roundSize: 3), progress: progress, seed: 4)
        let ones = s.order.filter { progress[$0] != nil }
        let zeros = s.order.filter { progress[$0] == nil }
        let keep = ones[1]
        s = Self.playRound(s) { q, _ in q.cardId != keep }
        #expect(s.stage[keep] == 0)
        #expect(s.lastAt[keep] == 1)
        s = Self.next(s, cards, seed: 5, now: T0 + MIN)
        #expect(s.rounds[0] == LearnRoundRecord(round: 1, answered: 3, correct: 2, cardIds: Array(ones.prefix(3))))
        // Six cards open: keep waits for five other questions, new cards come meanwhile.
        #expect(s.queue.map(\.cardId) == [ones[3], zeros[0], zeros[1]])
        let (_, log) = Self.playSession(s, cards, seed: 6) { _, _ in true }
        let mine = log.filter { $0.q.cardId == keep }
        #expect((mine.first?.wait ?? -1) >= min(LearnEngine.MIN_GAP, (mine.first?.open ?? 0) - 1))
        // Answered right before (progress): written, also after the miss.
        #expect(mine.map(\.q.type) == [.written, .written])
    }

    @Test func theSessionOrderIsShuffledOnceNewCardsFollowIt() {
        let cards = Self.makeCards(10)
        var differs = 0
        for seed in 1...30 {
            let s = Self.create(cards, seed: seed)
            #expect(s.queue.map(\.cardId) == Array(s.order.prefix(7)))
            if s.order != cards.map(\.id) { differs += 1 }
        }
        #expect(differs > 25)
    }

    @Test func twentyCardsAllCorrectEveryCardTwiceMultipleChoiceThenWritten() {
        let cards = Self.makeCards(20)
        let s0 = Self.create(cards, seed: 8)
        let (s, log) = Self.playSession(s0, cards, seed: 100) { _, _ in true }
        #expect(log.count == 40)
        // New cards in session order.
        #expect(log.filter { $0.wait == nil }.map(\.q.cardId) == s0.order)
        for id in s0.order {
            let mine = log.filter { $0.q.cardId == id }
            #expect(mine.map(\.q.type) == [.mc, .written])
            let wait = mine.last?.wait ?? -1
            #expect(wait >= min(LearnEngine.MIN_GAP, (mine.last?.open ?? 0) - 1))
            #expect(wait <= LearnEngine.MAX_WAIT + 1)
        }
        #expect(s.rounds.map(\.round) == [1, 2, 3, 4, 5, 6])
        #expect(s.rounds.map(\.answered) == [7, 7, 7, 7, 7, 5])
        #expect(s.rounds.map(\.correct) == [7, 7, 7, 7, 7, 5])
        // A round's cards in the order of their first answer in it.
        for r in s.rounds {
            var seen = Set<String>()
            #expect(r.cardIds == log.filter { $0.round == r.round }.map(\.q.cardId).filter { seen.insert($0).inserted })
        }
        let stats = LearnEngine.finalStats(s)
        #expect(stats.total == 20 && stats.mastered == 20 && stats.rounds == 6 && stats.answered == 40)
        #expect(stats.accuracy == 1)
        #expect(stats.hardest.isEmpty)
    }

    @Test func twentyCardsWithRandomMistakesInvariantsHoldUntilFinished() {
        for seed in 1...25 {
            let rng = mulberry32(seed: seed)
            let cards = Self.makeCards(20)
            var s = LearnEngine.createLearn(
                cards, answerWith: seed % 3 == 0 ? .both : .term, learn: .default, rng: rng, now: T0)
            var t = T0
            var rounds = 0
            while !LearnEngine.isFinished(s) {
                rounds += 1
                guard rounds <= 200 else {
                    Issue.record("seed \(seed): did not finish")
                    return
                }
                #expect(!s.queue.isEmpty && s.queue.count <= 7)
                // Question ids: this round, learning, a card's n-th question in the round gets ".n".
                var nth: [String: Int] = [:]
                for q in s.queue {
                    nth[q.cardId, default: 0] += 1
                    let n = nth[q.cardId] ?? 1
                    #expect(q.qid == (n > 1 ? "\(s.round).1.\(n):\(q.cardId)" : "\(s.round).1:\(q.cardId)"))
                }
                while !LearnEngine.isRoundOver(s) {
                    t += 4 * SEC
                    let q = LearnEngine.current(s)!
                    #expect((s.stage[q.cardId] ?? 0) < 2)
                    // Multiple choice only until the card was answered right once.
                    #expect(q.type == (s.stage[q.cardId] == 0 && s.solved[q.cardId] != true ? .mc : .written))
                    if q.type == .mc { Self.checkChoices(q, cards) }
                    let before = s
                    s = LearnEngine.answer(s, correct: rng() < 0.7, now: t)
                    #expect(s.clock == before.clock + 1)
                    #expect(s.lastAt[q.cardId] == before.clock)
                    #expect(s.repeats == (before.lastAt[q.cardId] != nil ? before.repeats + 1 : 0))
                    if s.last?.correct == false && rng() < 0.15 { s = LearnEngine.override(s, now: t + SEC) }
                    #expect((s.solved[q.cardId] == true) == (before.solved[q.cardId] == true || s.last?.correct == true))
                    // Queued questions of the card follow its stage at once.
                    for x in s.queue where x.cardId == q.cardId {
                        #expect(x.type == (s.stage[q.cardId] == 0 && s.solved[q.cardId] != true ? .mc : .written))
                    }
                }
                #expect(s.clock == s.answered)
                #expect(s.misses.values.reduce(0, +) == s.answered - s.correct)
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t + SEC)
            }
            s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t + 2 * SEC)
            #expect(LearnEngine.counts(s) == Self.counts(0, 0, 20, 20))
            #expect(s.rounds.map(\.round) == Array(1...s.rounds.count))
            #expect(s.rounds.reduce(0) { $0 + $1.answered } == s.answered)
            #expect(s.rounds.reduce(0) { $0 + $1.correct } == s.correct)
            #expect(LearnEngine.finalStats(s).rounds == s.rounds.count)
            #expect(s.finishedAt != nil)
        }
    }

    @Test func finishingStampsFinishedAtAndNextRoundClosesTheFinalRoundOnce() {
        let cards = Self.makeCards(2)
        var s = Self.create(cards, learn: LearnOptions(roundSize: 3), seed: 9)
        let (a, b) = (s.order[0], s.order[1])
        // Two open cards: each comes back after one other question.
        #expect(s.queue.map(\.qid) == ["1.1:\(a)", "1.1:\(b)", "1.1.2:\(a)"])
        s = Self.playRound(s) { _, _ in true }
        #expect(!LearnEngine.isFinished(s))
        s = Self.next(s, cards, seed: 1, now: T0 + MIN)
        #expect(s.queue.map(\.qid) == ["2.1:\(b)"])
        s = LearnEngine.answer(s, correct: true, now: T0 + MIN + 10 * SEC)
        #expect(LearnEngine.isFinished(s))
        #expect(LearnEngine.isRoundOver(s))
        #expect(s.finishedAt == T0 + MIN + 10 * SEC)
        #expect(LearnEngine.finalStats(s).rounds == 2)
        let closed = Self.next(s, cards, seed: 1, now: T0 + 2 * MIN)
        #expect(closed.round == 2)
        #expect(closed.rounds.map { [$0.round, $0.answered, $0.correct] } == [[1, 3, 3], [2, 1, 1]])
        #expect(closed.finishedAt == T0 + MIN + 10 * SEC)
        // The final round's checkpoint is still available.
        #expect(LearnEngine.checkpoint(closed).round == 2)
        #expect(LearnEngine.checkpoint(closed).answered == 1)
        #expect(Self.next(closed, cards, seed: 1, now: T0 + 3 * MIN) == closed)
        #expect(LearnEngine.finalStats(closed).rounds == 2)
    }

    // MARK: - Spacing (Abstand) and the mix

    @Test func spacingConstants() {
        let constants: [Int] = [
            LearnEngine.MIN_GAP, LearnEngine.MAX_WAIT, LearnEngine.MAX_REPEATS, LearnEngine.MAX_LEARNING,
            LearnEngine.RECHECK_GAP, LearnEngine.RECHECK_WAIT, LearnEngine.RECHECK_MIN_CARDS,
        ]
        #expect(constants == [10, 15, 3, 10, 30, 50, 60])
    }

    @Test func spacingWithFewerOpenCardsTheGapShrinksToOpenMinusOne() {
        // Three new cards: a b c a b c (two others in between), two cards alternate, one comes
        // again at once.
        for n in [1, 2, 3] {
            let s = Self.create(Self.makeCards(n), seed: n)
            #expect(s.queue.map(\.cardId) == s.order + s.order)
        }
        // Four cards asked before, nothing new: each comes as soon as it waited (open - 1).
        let four = Self.makeCards(4)
        let ones = ["c1": 1, "c2": 1, "c3": 1, "c4": 1]
        let s4 = Self.planFrom(four, stage: ones, lastAt: ["c1": 6, "c2": 7, "c3": 8, "c4": 9], clock: 10)
        #expect(s4.queue.map(\.qid) == ["1.1:c1", "1.1:c2", "1.1:c3", "1.1:c4"])
        // c1 waited only 2 of the 3 needed: the others come first.
        let s5 = Self.planFrom(four, stage: ones, lastAt: ["c4": 6, "c1": 7, "c2": 8, "c3": 9], clock: 10)
        #expect(s5.queue.map(\.cardId) == ["c4", "c1", "c2", "c3"])
        // Five new cards, all answers right: every card again after exactly four others.
        let five = Self.makeCards(5)
        let (_, log) = Self.playSession(Self.create(five, seed: 4), five) { _, _ in true }
        #expect(log.compactMap(\.wait) == [4, 4, 4, 4, 4])
    }

    @Test func spacingNoCardMayComeYetAndNothingIsNewTheOneWaitingLongestComesEarly() {
        // Only possible with a repaired state (two cards answered at the same place).
        let cards = Self.makeCards(3)
        let ones = ["c1": 1, "c2": 1, "c3": 1]
        let s = Self.planFrom(cards, stage: ones, lastAt: ["c1": 9, "c2": 9, "c3": 8], clock: 10, roundSize: 1)
        // c3 waited 1, c1 and c2 0 of the 2 needed.
        #expect(s.queue.map(\.cardId) == ["c3"])
        let t = Self.planFrom(cards, stage: ones, lastAt: ["c1": 9, "c2": 9, "c3": 9], clock: 10, roundSize: 1)
        // A tie goes to the card earlier in the session order.
        #expect(t.queue.map(\.cardId) == ["c1"])
    }

    @Test func spacingAWaitingCardComesForSureOnceItWaitedFifteenTheLongestOverdueFirst() {
        let cards = Self.makeCards(20)
        // c1 and c2 asked before (c2 waited longer), all others new: no new card comes first.
        for seed in 1...20 {
            let s = Self.planFrom(
                cards, stage: ["c1": 1, "c2": 1],
                lastAt: Self.lastAtFor(["c1", "c2"], [LearnEngine.MAX_WAIT, LearnEngine.MAX_WAIT + 1], 40), clock: 40,
                seed: seed)
            #expect(s.queue.prefix(2).map(\.cardId) == ["c2", "c1"])
            #expect(
                s.queue.dropFirst(2).allSatisfy { $0.qid == "1.1:\($0.cardId)" && $0.cardId != "c1" && $0.cardId != "c2" })
        }
        // In between, the chance grows with every question it waits: (wait - 9) in 6.
        for wait in LearnEngine.MIN_GAP..<LearnEngine.MAX_WAIT {
            var hits = 0
            for seed in 1...300 {
                let s = Self.planFrom(
                    cards, stage: ["c1": 1], lastAt: Self.lastAtFor(["c1"], [wait], 40), clock: 40, seed: seed,
                    roundSize: 1)
                if s.queue.first?.cardId == "c1" { hits += 1 }
            }
            let want =
                Double(300 * (wait - LearnEngine.MIN_GAP + 1)) / Double(LearnEngine.MAX_WAIT - LearnEngine.MIN_GAP + 1)
            #expect(abs(Double(hits) - want) < 35)
        }
    }

    @Test func mixAtMostThreeRepeatsInARowWhileThereAreNewCards() {
        let cards = Self.makeCards(20)
        let four = ["c1", "c2", "c3", "c4"]
        let stage = Dictionary(uniqueKeysWithValues: four.map { ($0, 1) })
        let lastAt = Self.lastAtFor(four, [18, 17, 16, 15], 40)
        // Four overdue cards: after three of them a new card comes first (c5: the first new one).
        #expect(
            Self.planFrom(cards, stage: stage, lastAt: lastAt, clock: 40).queue.prefix(5).map(\.cardId)
                == ["c1", "c2", "c3", "c5", "c4"])
        // Three repeats before this round: a new card right away.
        #expect(
            Self.planFrom(cards, stage: stage, lastAt: lastAt, clock: 40, repeats: LearnEngine.MAX_REPEATS).queue
                .prefix(5).map(\.cardId) == ["c5", "c1", "c2", "c3", "c6"])
        // Without new cards repeats go on.
        #expect(
            Self.planFrom(
                Array(cards.prefix(4)), stage: stage, lastAt: lastAt, clock: 40, repeats: LearnEngine.MAX_REPEATS
            ).queue.map(\.cardId) == four)
    }

    @Test func mixWhileTenCardsAreBeingLearnedANewCardComesOnlyAfterSixRepeats() {
        let cards = Self.makeCards(20)
        let ten = cards.prefix(10).map(\.id)
        let stage = Dictionary(uniqueKeysWithValues: ten.map { ($0, 1) })
        let lastAt = Self.lastAtFor(ten, [19, 18, 17, 16, 15, 14, 13, 12, 11, 10], 40)
        func first(_ repeats: Int) -> String? {
            Self.planFrom(cards, stage: stage, lastAt: lastAt, clock: 40, repeats: repeats).queue.first?.cardId
        }
        // Full: after three repeats still a card being learned (the most overdue) …
        #expect(first(LearnEngine.MAX_REPEATS) == "c1")
        #expect(first(2 * LearnEngine.MAX_REPEATS - 1) == "c1")
        // … after six a new one.
        #expect(first(2 * LearnEngine.MAX_REPEATS) == "c11")
        // A card that may come comes for sure (no chance for a new card); the one furthest past
        // the gap.
        let ready = Self.lastAtFor(ten, [11, 14, 12, 10, 13, 11, 14, 12, 10, 13], 40)
        for seed in 1...20 {
            let s = Self.planFrom(cards, stage: stage, lastAt: ready, clock: 40, seed: seed, roundSize: 1)
            #expect(s.queue.first?.cardId == "c2")
        }
        // With nine being learned the usual limit holds: after three repeats a new card.
        let nine = Array(ten.prefix(9))
        let s = Self.planFrom(
            cards, stage: Dictionary(uniqueKeysWithValues: nine.map { ($0, 1) }),
            lastAt: Self.lastAtFor(nine, [19, 18, 17, 16, 15, 14, 13, 12, 11], 40), clock: 40,
            repeats: LearnEngine.MAX_REPEATS)
        #expect(s.queue.first?.cardId == "c10")
    }

    @Test func aWrongAnswerTheLaterQuestionOfTheCardInTheRoundIsAskedAsMultipleChoiceAtItsPlace() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 5)
        let (a, b, c) = (s.order[0], s.order[1], s.order[2])
        let plan = s.queue
        #expect(plan.map(\.qid) == ["1.1:\(a)", "1.1:\(b)", "1.1:\(c)", "1.1.2:\(a)", "1.1.2:\(b)", "1.1.2:\(c)"])
        #expect(plan.map(\.type) == [.mc, .mc, .mc, .written, .written, .written])
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        #expect(s.queue.map(\.qid) == plan.dropFirst().map(\.qid))
        #expect(
            s.queue[2]
                == LearnQueueQuestion(
                    qid: "1.1.2:\(a)", cardId: a, type: .mc, ask: .term, choices: plan[3].retryChoices,
                    retryChoices: plan[3].retryChoices))
        Self.checkChoices(s.queue[2], cards)
        // "Ich hatte recht": back to written.
        #expect(LearnEngine.override(s, now: T0 + 2 * SEC).queue[2] == plan[3])
        // Right the second time: stage 1, so the card comes once more in a later round.
        s = LearnEngine.answer(s, correct: true, now: T0 + 3 * SEC)
        s = LearnEngine.answer(s, correct: true, now: T0 + 4 * SEC)
        s = LearnEngine.answer(s, correct: true, now: T0 + 5 * SEC)
        #expect(s.stage[a] == 1)
        s = Self.playRound(s, startAt: T0 + 5 * SEC) { _, _ in true }
        #expect(s.stage[b] == 2 && s.stage[c] == 2)
        #expect(!LearnEngine.isFinished(s))
        s = Self.next(s, cards, seed: 6, now: T0 + MIN)
        #expect(s.queue.map(\.qid) == ["2.1:\(a)"])
        #expect(s.queue.map(\.type) == [.written])
    }

    @Test func questionIdsRoundKindAndTheNumberOfTheCardInTheRound() {
        let s = Self.create([Card(id: "solo", term: "le soleil", definition: "die Sonne")], seed: 1)
        #expect(s.queue.map(\.qid) == ["1.1:solo", "1.1.2:solo"])
        // Card ids may contain anything, also colons and dots.
        let odd = [Card(id: "a:b", term: "un", definition: "eins"), Card(id: "1.2", term: "deux", definition: "zwei")]
        let t = Self.create(odd, seed: 1)
        #expect(t.queue.map(\.qid).sorted() == ["1.1:a:b", "1.1:1.2", "1.1.2:a:b", "1.1.2:1.2"].sorted())
        // In whole sessions: the round, the kind and the number of the card in the round. The plan
        // masters a card with two right answers, so a card has at most two questions in a round.
        var most = 0
        for n in [2, 9] {
            let cards = Self.makeCards(n)
            let d = mulberry32(seed: 3)
            let (_, log) = Self.playSession(Self.create(cards, seed: 2), cards, seed: 2) { _, _ in d() < 0.5 }
            var nth: [String: Int] = [:]
            for e in log {
                let key = "\(e.round)/\(e.q.cardId)"
                nth[key, default: 0] += 1
                let k = nth[key] ?? 1
                #expect(e.q.qid == (k > 1 ? "\(e.round).1.\(k):\(e.q.cardId)" : "\(e.round).1:\(e.q.cardId)"))
                most = max(most, k)
            }
        }
        #expect(most == 2)
    }

    // MARK: - Checkpoint, counts, finalStats

    @Test func checkpointPerCardResultsInAskedOrderAndCounts() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 6)
        let (x, y, z) = (s.order[0], s.order[1], s.order[2])
        #expect(s.queue.map(\.cardId) == [x, y, z, x, y, z])
        s = LearnEngine.answer(s, correct: true, now: T0 + SEC)
        s = LearnEngine.answer(s, correct: false, now: T0 + 2 * SEC)
        #expect(
            LearnEngine.checkpoint(s)
                == LearnEngine.Checkpoint(
                    round: 1, answered: 2, correct: 1,
                    items: [Item(cardId: x, stage: 1, results: [true]), Item(cardId: y, stage: 0, results: [false])],
                    counts: LearnEngine.CheckpointCounts(fresh: 1, learning: 2, mastered: 0, total: 3)))
        s = LearnEngine.answer(s, correct: true, now: T0 + 3 * SEC)  // z
        s = LearnEngine.answer(s, correct: true, now: T0 + 4 * SEC)  // x again: mastered
        // y again, multiple choice now.
        #expect(LearnEngine.current(s)?.qid == "1.1.2:\(y)")
        #expect(LearnEngine.current(s)?.type == .mc)
        s = LearnEngine.answer(s, correct: true, now: T0 + 5 * SEC)
        #expect(
            LearnEngine.checkpoint(s)
                == LearnEngine.Checkpoint(
                    round: 1, answered: 5, correct: 4,
                    items: [
                        Item(cardId: x, stage: 2, results: [true, true]),
                        Item(cardId: y, stage: 1, results: [false, true]), Item(cardId: z, stage: 1, results: [true]),
                    ],
                    counts: LearnEngine.CheckpointCounts(fresh: 0, learning: 2, mastered: 1, total: 3)))
    }

    @Test func countsFreshMeansNeverAnswered() {
        let cards = Self.makeCards(5)
        let progress = ["c1": Self.progressEntry(0, 0, 2, .incorrect), "c2": Self.progressEntry(2)]
        var s = Self.create(cards, progress: progress, seed: 12)
        #expect(LearnEngine.counts(s) == Self.counts(3, 1, 1, 5))
        // A fresh card answered wrong is no longer fresh, although its stage stays 0.
        let id = s.queue.first { $0.cardId != "c1" }!.cardId
        while LearnEngine.current(s)?.cardId != id { s = LearnEngine.answer(s, correct: true, now: T0 + SEC) }
        let before = LearnEngine.counts(s)
        s = LearnEngine.answer(s, correct: false, now: T0 + 2 * SEC)
        #expect(s.stage[id] == 0)
        #expect(LearnEngine.counts(s).fresh == before.fresh - 1)
        #expect(LearnEngine.counts(s).learning == before.learning + 1)
        #expect(LearnEngine.counts(LearnEngine.copyState(.null)) == Self.counts(0, 0, 0, 0))
    }

    @Test func finalStatsAccuracyRoundsAnsweredAndHardestCards() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 13)
        let (a, b, c) = (s.order[0], s.order[1], s.order[2])
        #expect(s.queue.map(\.cardId) == [a, b, c, a, b, c])
        let plan = Plan([a: [false, false], b: [false, true], c: [true, true]])
        s = Self.playRound(s, plan.decide)
        #expect(s.stage[a] == 0 && s.stage[b] == 1 && s.stage[c] == 2)
        s = Self.next(s, cards, seed: 1, now: T0 + MIN)
        // a waited longest, b is mastered by one more answer, then a again.
        #expect(s.queue.map(\.cardId) == [a, b, a])
        s = Self.playRound(s, startAt: T0 + MIN) { _, _ in true }
        #expect(LearnEngine.isFinished(s))
        let stats = LearnEngine.finalStats(s)
        #expect(stats.total == 3 && stats.mastered == 3 && stats.rounds == 2 && stats.answered == 9)
        #expect(stats.accuracy == 6.0 / 9.0)
        #expect(stats.hardest == [MissedCard(cardId: a, misses: 2), MissedCard(cardId: b, misses: 1)])
        #expect(stats.elapsedMs == s.elapsedMs)
        #expect(stats.elapsedMs > 0)
    }

    @Test func finalStatsHardestTiesKeepTheSessionOrderEveryMissedCard() {
        let cards = Self.makeCards(12)
        // 11 questions: 11 new cards (the first one may come back only after 10 others).
        var s = Self.create(cards, learn: LearnOptions(roundSize: 11), seed: 14)
        #expect(s.queue.map(\.cardId) == Array(s.order.prefix(11)))
        s = Self.playRound(s) { _, _ in false }
        let stats = LearnEngine.finalStats(s)
        #expect(stats.hardest.count == 11)
        #expect(stats.hardest == s.order.prefix(11).map { MissedCard(cardId: $0, misses: 1) })
        #expect(stats.answered == 11)
        #expect(stats.accuracy == 0)
        #expect(stats.rounds == 1)
        #expect(stats.mastered == 0)
    }

    // MARK: - buildChoices

    @Test func buildChoicesExactlyOneCorrectNoDuplicatesFourOptions() {
        let cards = Self.makeCards(10)
        for seed in 1...50 {
            let card = cards[seed % 10]
            let choices = LearnEngine.buildChoices(cards, card: card, ask: .term, rng: mulberry32(seed: seed))
            #expect(choices.count == 4)
            Self.checkChoices(choices, cardId: card.id, ask: .term, cards: cards)
        }
    }

    @Test func buildChoicesAskDefinitionUsesTheDefinitions() {
        let cards = Self.makeCards(6)
        let choices = LearnEngine.buildChoices(cards, card: cards[2], ask: .definition, rng: mulberry32(seed: 3))
        #expect(choices.count == 4)
        #expect(choices.allSatisfy { $0.text.hasPrefix("Begriff ") })
        #expect(choices.filter { $0.cardId == "c3" } == [Choice(cardId: "c3", text: "Begriff 3")])
    }

    @Test func buildChoicesSynonymCardsAreNeverOffered() {
        let cards = [
            Card(id: "laid", term: "laid, laide", definition: "hässlich"),
            Card(id: "moche", term: "moche", definition: "hässlich"),
            Card(id: "brave", term: "brave", definition: "lieb"),
            Card(id: "gentil", term: "gentil, gentille", definition: "lieb, nett"),
            Card(id: "calme", term: "calme", definition: "ruhig"),
            Card(id: "sage", term: "sage", definition: "brav, artig"),
            Card(id: "bete", term: "bête", definition: "dumm"),
        ]
        let byId = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let forbidden = ["laid": "moche", "moche": "laid", "brave": "gentil", "gentil": "brave"]
        for seed in 1...200 {
            for (id, other) in forbidden {
                let ids = LearnEngine.buildChoices(cards, card: byId[id]!, ask: .term, rng: mulberry32(seed: seed)).map(\.cardId)
                #expect(ids.count == 4)
                #expect(!ids.contains(other))
            }
        }
        // Asking the definition: "hässlich" is the correct text of both, so it is offered once.
        for seed in 1...50 {
            let choices = LearnEngine.buildChoices(cards, card: byId["moche"]!, ask: .definition, rng: mulberry32(seed: seed))
            #expect(choices.filter { Self.textKey($0.text) == "hässlich" } == [Choice(cardId: "moche", text: "hässlich")])
        }
    }

    @Test func buildChoicesTextsEqualToTheCorrectOneAfterNormalisationAreExcluded() {
        let cards = [
            Card(id: "a", term: "l'homme", definition: "der Mann"),
            Card(id: "b", term: "L\u{2019}Homme", definition: "Mensch"),
            Card(id: "c", term: "  l'homme ", definition: "Typ"),
            Card(id: "d", term: "L'HOMME", definition: "Kerl"),
            Card(id: "e", term: "la femme", definition: "die Frau"),
            Card(id: "f", term: "le  garçon", definition: "der Junge"),
        ]
        for seed in 1...40 {
            let choices = LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: seed))
            #expect(choices.map(\.cardId).sorted() == ["a", "e", "f"])
        }
    }

    @Test func buildChoicesEmptyTextsAndDuplicateDistractorsAreExcluded() {
        let cards = [
            Card(id: "a", term: "le chien", definition: "der Hund"),
            Card(id: "b", term: "le chat", definition: "die Katze"),
            Card(id: "c", term: "Le Chat", definition: "der Kater"),
            Card(id: "d", term: "", definition: "leer"),
            Card(id: "e", term: "   ", definition: "Leerzeichen"),
        ]
        for seed in 1...30 {
            let choices = LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: seed))
            #expect(choices.count == 2)
            #expect(choices.filter { $0.cardId == "a" }.count == 1)
            #expect(choices.first { $0.cardId != "a" }.map { Self.textKey($0.text) } == "le chat")
        }
    }

    @Test func buildChoicesOptionsThatShareAnAlternativeWithTheAnswerAreExcluded() {
        let cards = [
            Card(id: "a", term: "laid, laide", definition: "hässlich"),
            Card(id: "b", term: "laid", definition: "unschön"),
            Card(id: "c", term: "laide, moche", definition: "unansehnlich"),
            Card(id: "d", term: "joli, jolie", definition: "hübsch"),
            Card(id: "e", term: "beau, belle", definition: "schön"),
        ]
        for seed in 1...30 {
            let ids = LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: seed)).map(\.cardId)
            #expect(ids.sorted() == ["a", "d", "e"])
        }
    }

    @Test func buildChoicesSmallSetsGiveOneToFourOptionsAndNLimitsTheCount() {
        for (n, want) in [(1, 1), (2, 2), (3, 3), (4, 4), (5, 4), (30, 4)] {
            let cards = Self.makeCards(n)
            #expect(LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: n)).count == want)
        }
        let cards = Self.makeCards(10)
        func build(_ n: Int) -> [Choice] { LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: 1), n: n) }
        #expect(build(2).count == 2)
        #expect(build(3).count == 3)
        #expect(build(1) == [Choice(cardId: "c1", text: "terme 1")])
        #expect(build(0).count == 4)
        #expect(build(-5).count == 4)
    }

    @Test func buildChoicesTheCorrectOptionPositionIsUniform() {
        let cards = Self.makeCards(10)
        let n = 4000
        var hits = [0, 0, 0, 0]
        for seed in 1...n {
            let card = cards[seed % 10]
            let choices = LearnEngine.buildChoices(cards, card: card, ask: .term, rng: mulberry32(seed: seed))
            hits[choices.firstIndex { $0.cardId == card.id }!] += 1
        }
        for h in hits {
            #expect(Double(h) > Double(n) * 0.22)
            #expect(Double(h) < Double(n) * 0.28)
        }
        // Three options (3-card set): uniform over three slots.
        let three = Self.makeCards(3)
        var h3 = [0, 0, 0]
        for seed in 1...3000 {
            h3[LearnEngine.buildChoices(three, card: three[0], ask: .term, rng: mulberry32(seed: seed)).firstIndex { $0.cardId == "c1" }!] += 1
        }
        for h in h3 {
            #expect(h > 850)
            #expect(h < 1150)
        }
    }

    @Test func questionsTheCorrectOptionPositionIsUniformOverManySessions() {
        let cards = Self.makeCards(12)
        var hits = [0, 0, 0, 0]
        var total = 0
        for seed in 1...400 {
            for q in Self.create(cards, seed: seed).queue {
                hits[q.choices!.firstIndex { $0.cardId == q.cardId }!] += 1
                total += 1
            }
        }
        for h in hits {
            #expect(Double(h) / Double(total) > 0.22)
            #expect(Double(h) / Double(total) < 0.28)
        }
    }

    @Test func buildChoicesDistractorsVaryWithTheRngAndCoverThePool() {
        let cards = Self.makeCards(8)
        var seen = Set<String>()
        for seed in 1...100 {
            for c in LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: seed)) {
                seen.insert(c.cardId)
            }
        }
        #expect(seen.sorted() == cards.map(\.id).sorted())
        #expect(
            LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: 5))
                == LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: mulberry32(seed: 5)))
    }

    /// French–German cards of four word classes (WordClass) and their classes.
    static let mixed: [(id: String, term: String, definition: String, cls: String)] = [
        ("corps", "le corps", "der Körper", "noun"), ("tete", "la tête", "der Kopf", "noun"),
        ("nez", "le nez", "die Nase", "noun"), ("bouche", "la bouche", "der Mund", "noun"),
        ("dent", "la dent", "der Zahn", "noun"), ("manger", "manger", "essen", "verb"),
        ("boire", "boire", "trinken", "verb"), ("dormir", "dormir", "schlafen", "verb"),
        ("lever", "se lever", "aufstehen", "verb"), ("lent", "lent, lente", "langsam", "adj"),
        ("rapide", "rapide", "schnell", "adj"), ("beau", "beau, belle", "schön", "adj"),
        ("gentil", "gentil, gentille", "nett", "adj"), ("noel", "Joyeux Noël!", "Frohe Weihnachten!", "phrase"),
        ("merci", "Merci beaucoup!", "Vielen Dank!", "phrase"),
    ]

    @Test func buildChoicesWrongOptionsAreOfTheSameWordClassWhileThereAreEnough() {
        let cards = Self.mixed.map { Card(id: $0.id, term: $0.term, definition: $0.definition) }
        let cls = Dictionary(uniqueKeysWithValues: Self.mixed.map { ($0.id, $0.cls) })
        for seed in 1...60 {
            for card in cards {
                let ask: AskSide = seed % 2 == 1 ? .term : .definition
                let choices = LearnEngine.buildChoices(cards, card: card, ask: ask, rng: mulberry32(seed: seed))
                #expect(choices.count == 4)
                let others = choices.filter { $0.cardId != card.id }.map { cls[$0.cardId]! }
                let want = cls[card.id]!
                // Only two expressions: the other one, then cards of other classes.
                if want == "phrase" {
                    #expect(others.filter { $0 == "phrase" }.count == 1)
                } else {
                    #expect(others == [want, want, want])
                }
            }
        }
    }

    @Test func buildChoicesTheMostAlikeOptionsComeMostOftenButTakeTurns() {
        let cards = Self.makeCards(40)
        let card = cards[19]
        var seen: [String: Int] = [:]
        var near = 0
        var total = 0
        for seed in 1...300 {
            for c in LearnEngine.buildChoices(cards, card: card, ask: .term, rng: mulberry32(seed: seed)) where c.cardId != card.id {
                seen[c.cardId, default: 0] += 1
                let at = cards.firstIndex { $0.id == c.cardId }!
                if abs(at - 19) <= 3 { near += 1 }
                total += 1
            }
        }
        // Mostly the neighbours in the set (6 of 39 cards), yet more than three different options.
        #expect(Double(near) / Double(total) > 0.6)
        #expect(seen.count > 6)
        // The options of one question stay in random order: the closest is not always first.
        var firsts = Set<String>()
        for seed in 1...40 {
            firsts.insert(LearnEngine.buildChoices(cards, card: card, ask: .term, rng: mulberry32(seed: seed)).first { $0.cardId != card.id }!.cardId)
        }
        #expect(firsts.count > 3)
    }

    @Test func buildChoicesOddInputNeverTraps() {
        let cards = Self.makeCards(4)
        #expect(
            LearnEngine.buildChoices([], card: cards[0], ask: .term, rng: mulberry32(seed: 1))
                == [Choice(cardId: "c1", text: "terme 1")])
        #expect(LearnEngine.buildChoices(cards, card: Card(id: "", term: "x", definition: "y"), ask: .term).isEmpty)
        #expect(LearnEngine.buildChoices(cards, card: Card(id: "x", term: "", definition: "y"), ask: .term).isEmpty)
        #expect(LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: { 1 }).count == 4)
        #expect(LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: { .nan }).count == 4)
        #expect(LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: { -7 }).count == 4)
        #expect(LearnEngine.buildChoices(cards, card: cards[0], ask: .term, rng: { .infinity }).count == 4)
        let junk = cards + [Card(id: "", term: "no id", definition: "x"), cards[1]]
        #expect(LearnEngine.buildChoices(junk, card: cards[0], ask: .term, rng: mulberry32(seed: 1)).count == 4)
    }

    // MARK: - Question types & flags

    @Test func aOneCardSetIsWrittenOnlyAndAskedAgainRightAway() {
        let cards = [Card(id: "solo", term: "le soleil", definition: "die Sonne")]
        var s = Self.create(cards, seed: 1)
        #expect(LearnEngine.current(s) == Q(qid: "1.1:solo", cardId: "solo", type: .written, ask: .term))
        #expect(s.queue.map(\.qid) == ["1.1:solo", "1.1.2:solo"])
        #expect(s.queue.allSatisfy { $0.retryChoices == nil })
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        #expect(LearnEngine.current(s) == Q(qid: "1.1.2:solo", cardId: "solo", type: .written, ask: .term))
        s = LearnEngine.answer(s, correct: true, now: T0 + 2 * SEC)
        #expect(s.stage["solo"] == 1)
        s = Self.next(s, cards, seed: 2, now: T0 + 3 * SEC)
        #expect(LearnEngine.current(s) == Q(qid: "2.1:solo", cardId: "solo", type: .written, ask: .term))
        #expect(s.queue.count == 1)
    }

    @Test func multipleChoiceFallsBackToWrittenWithoutAValidDistractor() {
        // Synonyms: both cards show "hässlich", so neither answer can be a distractor for the other.
        let syn = [Card(id: "a", term: "laid", definition: "hässlich"), Card(id: "b", term: "moche", definition: "hässlich")]
        #expect(Self.create(syn, seed: 1).queue.map(\.type) == [.written, .written, .written, .written])
        // Same answer text on both cards (distinct prompts): fewer than 2 distinct answers.
        let same = [
            Card(id: "a", term: "le visage", definition: "das Gesicht"),
            Card(id: "b", term: "la figure", definition: "das Gesicht"),
        ]
        #expect(Self.create(same, .definition, seed: 1).queue.map(\.type) == [.written, .written, .written, .written])
        // A third card with its own answer makes multiple choice possible again (2 options each).
        let three = same + [Card(id: "c", term: "le nez", definition: "die Nase")]
        let s3 = Self.create(three, .definition, seed: 1)
        #expect(s3.queue.map(\.type) == [.mc, .mc, .mc, .written, .written, .written])
        for q in s3.queue {
            #expect(q.retryChoices?.count == 2)
            Self.checkChoices(q.retryChoices, cardId: q.cardId, ask: q.ask, cards: three)
            if q.type == .mc {
                #expect(q.choices?.count == 2)
                Self.checkChoices(q, three)
            }
        }
    }

    @Test func optionsComeFromTheWholeSetNotOnlyFromTheScope() {
        let cards = Self.makeCards(6).map { Card(id: $0.id, term: $0.term, definition: $0.definition, starred: $0.id == "c5") }
        let s = Self.create(cards, subset: .starred, seed: 2)
        #expect(s.order == ["c5"])
        #expect(LearnEngine.current(s)?.type == .mc)
        #expect(LearnEngine.current(s)?.choices?.count == 4)
        Self.checkChoices(LearnEngine.current(s)!, cards)
    }

    @Test func noQuestionEverOffersASynonymCard() {
        let pairs = [
            ("laid, laide", "hässlich"), ("moche", "hässlich"), ("le visage", "das Gesicht"),
            ("la figure", "das Gesicht"), ("brave", "lieb"), ("gentil, gentille", "lieb, nett"),
            ("la femme", "die Frau"), ("la mademoiselle, mesdemoiselles", "das Fräulein, die Frau"),
            ("calme", "ruhig"), ("bête", "dumm"),
        ]
        let cards = pairs.enumerated().map { Card(id: "w\($0.offset + 1)", term: $0.element.0, definition: $0.element.1) }
        for seed in 1...60 {
            let s = Self.create(cards, .both, learn: LearnOptions(roundSize: 10), seed: seed)
            for q in s.queue {
                let card = cards.first { $0.id == q.cardId }!
                let syn = Synonyms.findSynonymCards(cards, card: card, ask: q.ask).map(\.id)
                for c in (q.choices ?? []) + (q.retryChoices ?? []) { #expect(!syn.contains(c.cardId)) }
                if q.choices != nil { Self.checkChoices(q, cards) }
            }
        }
    }

    @Test func flagMcOnlyStageOneIsAskedAsMultipleChoice() {
        let cards = Self.makeCards(5)
        let mcOnly = LearnOptions(mc: true, written: false)
        var s = Self.create(cards, learn: mcOnly, progress: ["c1": Self.progressEntry(1)], seed: 3)
        #expect(s.queue.allSatisfy { $0.type == .mc })
        let id = LearnEngine.current(s)!.cardId
        s = Self.playRound(s) { _, _ in true }
        s = Self.next(s, cards, seed: 4, now: T0 + MIN)
        #expect(s.queue.allSatisfy { $0.type == .mc && $0.choices?.count == 4 })
        s = Self.playRound(s, startAt: T0 + MIN) { _, _ in true }
        #expect(s.stage[id] == 2)
        #expect(LearnEngine.isFinished(s))
        // A stage-1 card without valid distractors is still asked (written).
        let solo = Self.create([cards[0]], learn: mcOnly, progress: ["c1": Self.progressEntry(1)], seed: 1)
        #expect(LearnEngine.current(solo)?.type == .written)
    }

    @Test func flagWrittenOnlyEveryQuestionIsWrittenRetriesToo() {
        let cards = Self.makeCards(5)
        var s = Self.create(cards, learn: LearnOptions(mc: false, written: true), seed: 5)
        for q in s.queue {
            #expect(q.type == .written)
            #expect(q.choices == nil)
            #expect(q.retryChoices == nil)
        }
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        #expect(s.queue.allSatisfy { $0.type == .written })
        s = Self.playRound(s, startAt: T0 + SEC) { _, _ in true }
        s = Self.next(s, cards, seed: 6, now: T0 + MIN)
        #expect(s.queue.allSatisfy { $0.type == .written })
    }

    @Test func bothFlagsStageZeroMcStageOneWritten() {
        let cards = Self.makeCards(6)
        let progress = ["c1": Self.progressEntry(1), "c2": Self.progressEntry(1), "c3": Self.progressEntry(0, 0, 1)]
        let s = Self.create(cards, learn: LearnOptions(mc: true, written: true), progress: progress, seed: 7)
        // The n-th question of a card in the round is planned at stage + n - 1.
        var nth: [String: Int] = [:]
        for q in s.queue {
            nth[q.cardId, default: 0] += 1
            #expect(q.type == ((s.stage[q.cardId] ?? 0) + (nth[q.cardId] ?? 1) - 1 == 1 ? .written : .mc))
        }
    }

    @Test func answerWithDefinitionAsksTheDefinitionOptionsAreDefinitions() {
        let cards = Self.makeCards(6)
        let s = Self.create(cards, .definition, seed: 8)
        #expect(s.queue.count { $0.type == .mc } == 6)
        for q in s.queue {
            #expect(q.ask == .definition)
            #expect(q.retryChoices?.allSatisfy { $0.text.hasPrefix("Begriff ") } == true)
            guard q.type == .mc else { continue }
            #expect(q.choices?.allSatisfy { $0.text.hasPrefix("Begriff ") } == true)
            Self.checkChoices(q, cards)
        }
    }

    @Test func answerWithBothAskIsPickedPerQuestionOptionsAndRetryFollowIt() {
        let cards = Self.makeCards(8)
        var asks: [AskSide: Int] = [:]
        var mixed = 0
        for seed in 1...40 {
            let s = Self.create(cards, .both, seed: seed)
            #expect(s.answerWith == .both)
            var local = Set<AskSide>()
            for q in s.queue {
                asks[q.ask, default: 0] += 1
                local.insert(q.ask)
                Self.checkChoices(q, cards)
                for c in q.retryChoices ?? [] {
                    #expect(c.text == Synonyms.answerSide(cards.first { $0.id == c.cardId }!, ask: q.ask))
                }
            }
            if local.count == 2 { mixed += 1 }
        }
        #expect((asks[.term] ?? 0) > 100)
        #expect((asks[.definition] ?? 0) > 100)
        #expect(mixed > 30)
        // A later question of the card in the round has its own ask; after a wrong answer it is
        // multiple choice with options for that ask.
        let three = Self.makeCards(3)
        var otherAsk = 0
        for seed in 1...20 {
            var s = Self.create(three, .both, seed: seed)
            let first = LearnEngine.current(s)!
            s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
            let later = s.queue.first { $0.cardId == first.cardId }!
            #expect(later.qid == "1.1.2:\(first.cardId)")
            #expect(later.type == .mc)
            Self.checkChoices(later, three)
            if later.ask != first.ask { otherAsk += 1 }
        }
        #expect(otherAsk > 3)
    }

    // MARK: - Override

    @Test func overrideAWrongMcAnswerBecomesCorrectTheLaterQuestionOfTheCardFollows() {
        let cards = Self.makeCards(5)
        var s = Self.create(cards, seed: 3)
        let id = LearnEngine.current(s)!.cardId
        let planned = s.queue.first { $0.qid == "1.1.2:\(id)" }!
        #expect(planned.type == .written)
        s = LearnEngine.answer(s, correct: false, now: T0 + 10 * SEC)
        #expect(s.queue.count == 6)
        // Wrong: its later question in this round turns multiple choice, with the options kept for it.
        var asMc = planned
        asMc.type = .mc
        asMc.choices = planned.retryChoices
        #expect(s.queue.first { $0.cardId == id } == asMc)
        let o = LearnEngine.override(s, now: T0 + 15 * SEC)
        #expect(o.stage[id] == 1)
        #expect(o.queue.count == 6)
        #expect(o.queue.first { $0.cardId == id } == planned)
        #expect(o.answered == 1 && o.correct == 1)
        #expect(o.misses[id] == 0)
        #expect(
            o.roundLog == [
                LearnRoundLogEntry(qid: "1.1:\(id)", cardId: id, type: .mc, ask: .term, correct: true, stageAfter: 1)
            ])
        #expect(o.last == LearnLastAnswer(qid: "1.1:\(id)", cardId: id, type: .mc, ask: .term, correct: true, stageBefore: 0))
        #expect(o.updatedAt == T0 + 15 * SEC)
        // The spacing stays: the answer was given at the same place.
        #expect(o.lastAt == s.lastAt)
        #expect(o.clock == 1)
        #expect(LearnEngine.counts(o) == Self.counts(4, 1, 0, 5))
        #expect(LearnEngine.checkpoint(o).correct == 1)
    }

    @Test func overrideIsIdempotent() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, seed: 4)
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        let once = LearnEngine.override(s, now: T0 + 2 * SEC)
        let twice = LearnEngine.override(once, now: T0 + 3 * SEC)
        #expect(twice == once)
        #expect(LearnEngine.override(twice, now: T0 + 4 * SEC) == once)
    }

    @Test func overrideOfAWrongWrittenAnswerMastersTheCardAndCanFinish() {
        let cards = Self.makeCards(3)
        let progress = ["c1": Self.progressEntry(2), "c2": Self.progressEntry(2), "c3": Self.progressEntry(1)]
        var s = Self.create(cards, progress: progress, seed: 5)
        #expect(LearnEngine.current(s) == Q(qid: "1.1:c3", cardId: "c3", type: .written, ask: .term))
        #expect(s.queue.count == 1)
        s = LearnEngine.answer(s, correct: false, now: T0 + 10 * SEC)
        #expect(s.stage["c3"] == 0)
        #expect(LearnEngine.isRoundOver(s))
        #expect(!LearnEngine.isFinished(s))
        let o = LearnEngine.override(s, now: T0 + 20 * SEC)
        #expect(o.stage["c3"] == 2)
        #expect(o.queue.isEmpty)
        #expect(LearnEngine.isFinished(o))
        #expect(o.finishedAt == T0 + 20 * SEC)
        #expect(
            LearnEngine.finalStats(o)
                == LearnEngine.FinalStats(
                    total: 3, mastered: 3, alreadyMastered: 2, rounds: 1, answered: 1, accuracy: 1, elapsedMs: 20 * SEC,
                    hardest: []))
    }

    @Test func overrideIsANoOpWithoutAWrongLastAnswerAndAfterNextRound() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 6)
        #expect(LearnEngine.override(s, now: T0 + SEC) == s)  // nothing answered
        s = LearnEngine.answer(s, correct: true, now: T0 + SEC)
        #expect(LearnEngine.override(s, now: T0 + 2 * SEC) == s)  // last was correct
        s = Self.playRound(s, startAt: T0 + 2 * SEC) { _, _ in false }
        #expect(s.last?.correct == false)
        let n = Self.next(s, cards, seed: 7, now: T0 + MIN)
        #expect(n.last == nil)
        #expect(LearnEngine.override(n, now: T0 + MIN + SEC) == n)
    }

    @Test func overrideOfALaterAnswerOfTheCardCorrectsOnlyThatAnswer() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 8)
        let id = LearnEngine.current(s)!.cardId
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)  // wrong
        s = LearnEngine.answer(s, correct: true, now: T0 + 2 * SEC)
        s = LearnEngine.answer(s, correct: true, now: T0 + 3 * SEC)
        #expect(LearnEngine.current(s)?.qid == "1.1.2:\(id)")
        #expect(LearnEngine.current(s)?.type == .mc)
        s = LearnEngine.answer(s, correct: false, now: T0 + 4 * SEC)  // its second question, wrong again
        #expect(s.misses[id] == 2)
        let o = LearnEngine.override(s, now: T0 + MIN)
        #expect(o.stage[id] == 1)
        #expect(o.misses[id] == 1)
        #expect(o.roundLog.filter { $0.cardId == id }.map { [$0.correct ? 1 : 0, $0.stageAfter] } == [[0, 0], [1, 1]])
        #expect(LearnEngine.checkpoint(o).items.first { $0.cardId == id } == Item(cardId: id, stage: 1, results: [false, true]))
    }

    // MARK: - removeCard

    @Test func removeCardMidRoundRemovesTheCardEverywhere() {
        let cards = Self.makeCards(6)
        var s = Self.create(cards, seed: 2)
        let a = s.queue[0].cardId
        let b = s.queue[1].cardId
        #expect(s.queue.map(\.cardId) == s.order + [a])
        s = LearnEngine.answer(s, correct: false, now: T0 + 10 * SEC)  // a wrong
        s = LearnEngine.answer(s, correct: true, now: T0 + 20 * SEC)  // b correct
        let r = LearnEngine.removeCard(s, cardId: a, now: T0 + 30 * SEC)
        #expect(!r.order.contains(a))
        #expect(r.order.count == 5)
        #expect(r.stage[a] == nil)
        #expect(r.lastAt == [b: 1])
        #expect(r.clock == 2)
        #expect(!r.queue.contains { $0.cardId == a })
        #expect(r.queue.count == 4)
        for q in r.queue {
            #expect(!(q.choices ?? []).map(\.cardId).contains(a))
            #expect(!(q.retryChoices ?? []).map(\.cardId).contains(a))
        }
        #expect(r.misses[a] == nil)
        #expect(r.roundLog.map(\.cardId) == [b])
        #expect(r.answered == 1 && r.correct == 1)
        #expect(r.last?.cardId == b)
        #expect(LearnEngine.counts(r).total == 5)
        #expect(LearnEngine.checkpoint(r).items.map(\.cardId) == [b])
        // Removing the last answered card clears `last`.
        #expect(LearnEngine.removeCard(r, cardId: b, now: T0 + 40 * SEC).last == nil)
        // Unknown card: nothing changes.
        #expect(LearnEngine.removeCard(s, cardId: "nope", now: T0 + MIN) == s)
    }

    @Test func removeCardOfTheCurrentQuestionMovesOnToTheNextOne() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, seed: 3)
        let second = s.queue[1].cardId
        let third = s.queue[2].cardId
        s = LearnEngine.answer(s, correct: true, now: T0 + SEC)
        #expect(LearnEngine.current(s)?.cardId == second)
        let rest = s.queue.filter { $0.cardId != second }.map(\.qid)
        s = LearnEngine.removeCard(s, cardId: second, now: T0 + 2 * SEC)
        #expect(LearnEngine.current(s)?.cardId == third)
        #expect(s.queue.map(\.qid) == rest)
    }

    @Test func removeCardDropsItsOptionFromOtherQuestions() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 4)
        let (x, y, z) = (s.order[0], s.order[1], s.order[2])
        #expect(s.queue.map(\.cardId) == [x, y, z, x, y, z])
        for q in s.queue {
            #expect(q.retryChoices?.count == 3)
            if q.type == .mc { #expect(q.choices?.count == 3) }
        }
        s = LearnEngine.removeCard(s, cardId: x, now: T0 + SEC)
        #expect(s.queue.map(\.cardId) == [y, z, y, z])
        #expect(s.queue.map(\.type) == [.mc, .mc, .written, .written])
        for q in s.queue {
            #expect(q.retryChoices?.count == 2)
            if q.type == .mc { #expect(q.choices?.count == 2) }
        }
        s = LearnEngine.removeCard(s, cardId: y, now: T0 + 2 * SEC)
        #expect(s.queue.map(\.qid) == ["1.1:\(z)", "1.1.2:\(z)"])
        #expect(LearnEngine.current(s) == Q(qid: "1.1:\(z)", cardId: z, type: .written, ask: .term))
        #expect(s.queue.allSatisfy { $0.retryChoices == nil })
        s = LearnEngine.answer(s, correct: false, now: T0 + 3 * SEC)
        #expect(LearnEngine.current(s)?.type == .written)
    }

    @Test func removeCardOfTheLastOpenCardFinishesTheSession() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, progress: ["c1": Self.progressEntry(2), "c2": Self.progressEntry(2)], seed: 5)
        #expect(s.queue.map(\.qid) == ["1.1:c3", "1.1.2:c3"])
        s = LearnEngine.removeCard(s, cardId: "c3", now: T0 + 5 * SEC)
        #expect(LearnEngine.isFinished(s))
        #expect(s.finishedAt == T0 + 5 * SEC)
        #expect(s.round == 1)
        #expect(LearnEngine.counts(s) == Self.counts(0, 0, 2, 2))

        // A round that lost every card before any answer: the session ends with the last closed round.
        let two = Self.makeCards(2)
        var t = Self.create(two, learn: LearnOptions(roundSize: 1), progress: ["c1": Self.progressEntry(1)], seed: 6)
        #expect(t.queue.map(\.cardId) == ["c1"])
        t = LearnEngine.answer(t, correct: true, now: T0 + SEC)
        t = Self.next(t, two, seed: 7, now: T0 + 2 * SEC)
        #expect(t.round == 2)
        #expect(t.queue.map(\.cardId) == ["c2"])
        t = LearnEngine.removeCard(t, cardId: "c2", now: T0 + 3 * SEC)
        #expect(LearnEngine.isFinished(t))
        #expect(t.round == 1)
        #expect(LearnEngine.finalStats(t).rounds == 1)
        #expect(LearnEngine.checkpoint(t).round == 1)
    }

    @Test func nextRoundDropsScopeCardsThatAreMissingFromCards() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, learn: LearnOptions(roundSize: 4), seed: 9)
        s = Self.playRound(s) { _, _ in true }
        let gone = s.order[0]
        s = Self.next(s, cards.filter { $0.id != gone }, seed: 10, now: T0 + MIN)
        #expect(!s.order.contains(gone))
        #expect(s.lastAt[gone] == nil)
        #expect(s.queue.map(\.cardId) == s.order)
        for q in s.queue { #expect(q.type == .written) }
        #expect(!s.rounds[0].cardIds.contains(gone))
        #expect(LearnEngine.counts(s).total == 3)
    }

    // MARK: - Time

    @Test func tickAccumulatesActiveTimeAndIgnoresGapsLongerThanFiveMinutes() {
        var s = Self.create(Self.makeCards(2), seed: 1)
        s = LearnEngine.tick(s, now: T0 + 30 * SEC)
        #expect(s.elapsedMs == 30 * SEC)
        s = LearnEngine.tick(s, now: T0 + 30 * SEC + 5 * MIN)  // exactly 5 minutes still counts
        #expect(s.elapsedMs == 30 * SEC + 5 * MIN)
        s = LearnEngine.tick(s, now: T0 + 30 * SEC + 5 * MIN + 2 * 60 * MIN)  // two hours away
        #expect(s.elapsedMs == 30 * SEC + 5 * MIN)
        #expect(s.updatedAt == T0 + 30 * SEC + 5 * MIN + 2 * 60 * MIN)
        s = LearnEngine.tick(s, now: s.updatedAt + 10 * SEC)
        #expect(s.elapsedMs == 40 * SEC + 5 * MIN)
        let back = LearnEngine.tick(s, now: s.updatedAt - 10 * SEC)  // clock went backwards
        #expect(back.elapsedMs == s.elapsedMs)
        #expect(LearnEngine.tick(s, now: .nan).elapsedMs == s.elapsedMs)
        #expect(LearnEngine.tick(s, now: .nan).updatedAt == s.updatedAt)
    }

    @Test func answersAdvanceTheClockAndItStopsOnceFinished() {
        let cards = [Card(id: "solo", term: "le soleil", definition: "die Sonne")]
        var s = Self.create(cards, learn: LearnOptions(roundSize: 1), seed: 1)
        s = LearnEngine.answer(s, correct: true, now: T0 + 12 * SEC)
        #expect(s.elapsedMs == 12 * SEC)
        #expect(s.updatedAt == T0 + 12 * SEC)
        s = Self.next(s, cards, seed: 2, now: T0 + 20 * SEC)
        #expect(s.elapsedMs == 20 * SEC)
        s = LearnEngine.answer(s, correct: true, now: T0 + 30 * SEC)
        #expect(LearnEngine.isFinished(s))
        #expect(s.elapsedMs == 30 * SEC)
        let later = LearnEngine.tick(s, now: T0 + 60 * SEC)
        #expect(later.elapsedMs == 30 * SEC)
        #expect(LearnEngine.finalStats(later).elapsedMs == 30 * SEC)
    }

    // MARK: - Serialisation & value semantics

    @Test func stateSurvivesAJSONRoundTripAndContinuesIdentically() throws {
        let cards = Self.makeCards(12)
        var s = Self.create(cards, .both, learn: LearnOptions(roundSize: 5), seed: 11)
        let decide = mulberry32(seed: 99)
        let outcomes = (0..<300).map { _ in decide() < 0.6 }
        var k = 0
        var t = T0
        func step(_ state: LearnState) -> LearnState {
            t += 7 * SEC
            if LearnEngine.isRoundOver(state) {
                return LearnEngine.nextRound(state, cards: cards, rng: mulberry32(seed: Int(t)), now: t)
            }
            let next = LearnEngine.answer(state, correct: outcomes[k % outcomes.count], now: t)
            k += 1
            return k % 9 == 0 ? LearnEngine.override(next, now: t) : next
        }
        for _ in 0..<17 { s = step(s) }
        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(LearnState.self, from: data)
        #expect(restored == s)
        #expect(LearnEngine.copyState(try JSONValue.parse(data)) == s)

        let (tStart, kStart) = (t, k)
        var a = s
        var guardCount = 0
        while !LearnEngine.isFinished(a) && guardCount < 1000 {
            a = step(a)
            guardCount += 1
        }
        (t, k) = (tStart, kStart)
        var b = restored
        guardCount = 0
        while !LearnEngine.isFinished(b) && guardCount < 1000 {
            b = step(b)
            guardCount += 1
        }
        #expect(LearnEngine.isFinished(a))
        #expect(b == a)
        #expect(LearnEngine.finalStats(b) == LearnEngine.finalStats(a))
    }

    @Test func aResumedSessionShowsTheSameQuestionAndOptions() throws {
        let cards = Self.makeCards(9)
        var s = Self.create(cards, seed: 21)
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        s = LearnEngine.answer(s, correct: true, now: T0 + 2 * SEC)
        let resumed = LearnEngine.copyState(try JSONValue(encoding: s))
        #expect(LearnEngine.current(resumed) == LearnEngine.current(s))
        #expect(resumed.queue == s.queue)
        // Including the multiple-choice retry built from a stored option list.
        var x = s
        var y = resumed
        while !LearnEngine.isRoundOver(x) {
            #expect(LearnEngine.current(y) == LearnEngine.current(x))
            x = LearnEngine.answer(x, correct: true, now: T0 + MIN)
            y = LearnEngine.answer(y, correct: true, now: T0 + MIN)
        }
        #expect(y == x)
    }

    @Test func functionsNeverChangeTheirInputState() {
        let cards = Self.makeCards(6)
        var s = Self.create(cards, .both, learn: LearnOptions(roundSize: 4), progress: ["c1": Self.progressEntry(1)], seed: 3)
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        s = LearnEngine.answer(s, correct: true, now: T0 + 2 * SEC)
        let frozen = s
        let results = [
            LearnEngine.answer(frozen, correct: true, now: T0 + MIN),
            LearnEngine.answer(frozen, correct: false, now: T0 + MIN),
            LearnEngine.override(frozen, now: T0 + MIN),
            LearnEngine.removeCard(frozen, cardId: frozen.queue[0].cardId, now: T0 + MIN, cards: cards),
            LearnEngine.tick(frozen, now: T0 + MIN),
            LearnEngine.syncProgress(frozen, progress: ["c2": Self.recorded(true, true)], now: T0 + MIN),
        ]
        _ = LearnEngine.counts(frozen)
        _ = LearnEngine.checkpoint(frozen)
        _ = LearnEngine.finalStats(frozen)
        // Value semantics: the input is untouched (the JS test checks frozen objects).
        #expect(frozen == s)
        #expect(results.count == 6)
        var e = frozen
        while !LearnEngine.isRoundOver(e) { e = LearnEngine.answer(e, correct: false, now: T0 + 2 * MIN) }
        let n = Self.next(e, cards, seed: 5, now: T0 + 3 * MIN)
        #expect(n.round == 2)
        // A returned question is a copy.
        var q = LearnEngine.current(n)!
        q.cardId = "changed"
        #expect(LearnEngine.current(n)?.cardId != "changed")
    }

    @Test func defensiveACorruptOrPartialStateDoesNotTrapTheEngine() throws {
        #expect(LearnEngine.current(LearnEngine.copyState(.null)) == nil)
        #expect(LearnEngine.isFinished(LearnEngine.copyState(.null)))
        #expect(LearnEngine.isRoundOver(LearnEngine.copyState("junk")))
        #expect(LearnEngine.checkpoint(LearnEngine.copyState(42)).items.isEmpty)
        #expect(LearnEngine.finalStats(LearnEngine.copyState([:])).total == 0)
        let partial: JSONValue = [
            "order": ["a", "b", "a"],
            "stage": ["a": 1, "b": 7],
            "active": ["a", "ghost"],
            "queue": [["cardId": "a", "type": "mc", "choices": [["cardId": "a", "text": "x"]]], ["cardId": "ghost", "type": "mc"], "junk"],
            "misses": ["a": -3, "ghost": 2],
        ]
        let p = LearnEngine.copyState(partial)
        #expect(LearnEngine.current(p) == Q(qid: "1.q0:a", cardId: "a", type: .written, ask: .term))
        let s = LearnEngine.answer(p, correct: true, now: T0)
        #expect(s.order == ["a", "b"])
        #expect(s.stage == ["a": 2, "b": 2])
        #expect(s.misses == ["a": 0])
        #expect(LearnEngine.isFinished(s))
        #expect(s.finishedAt == T0)
        #expect(try JSONValue(encoding: s)["active"] == nil)
        #expect(s.clock == 1 && s.lastAt == ["a": 0] && s.repeats == 0)
        // An open card that fell out of the queue is planned again by nextRound.
        let stuck = LearnEngine.copyState(["order": ["a"], "stage": ["a": 0], "active": [], "queue": [], "round": 1])
        #expect(LearnEngine.isRoundOver(stuck))
        let refilled = Self.next(stuck, [Card(id: "a", term: "oui", definition: "ja")], seed: 1, now: T0)
        #expect(refilled.round == 1)
        #expect(refilled.rounds.isEmpty)
        #expect(refilled.queue.map(\.qid) == ["1.1:a", "1.1.2:a"])
        #expect(LearnEngine.current(refilled) == Q(qid: "1.1:a", cardId: "a", type: .written, ask: .term))
        // Junk spacing fields are repaired: the answer count stands in for the clock, bad entries go.
        for clock: JSONValue in [-3, "x", 2.5, nil] {
            #expect(LearnEngine.copyState(["order": ["a"], "answered": 4, "clock": clock]).clock == 4)
        }
        #expect(LearnEngine.copyState(["order": ["a"], "answered": 4.7]).clock == 4)
        #expect(LearnEngine.copyState(["order": ["a"], "answered": 4, "clock": 9]).clock == 9)
        let junk = LearnEngine.copyState([
            "order": ["a", "b", "c", "d"], "lastAt": ["a": 3, "b": -1, "c": "x", "d": 1.5, "ghost": 2], "repeats": -2,
        ])
        #expect(junk.lastAt == ["a": 3])
        #expect(junk.repeats == 0)
        for lastAt: JSONValue in [nil, "x", [3], 5] {
            #expect(LearnEngine.copyState(["order": ["a"], "lastAt": lastAt]).lastAt.isEmpty)
        }
        for repeats: JSONValue in [1.5, "x", nil] {
            #expect(LearnEngine.copyState(["order": ["a"], "repeats": repeats]).repeats == 0)
        }
        #expect(LearnEngine.copyState(["order": ["a"], "repeats": 4]).repeats == 4)
    }

    // MARK: - Removed options are refilled

    @Test func removeCardWithTheSetCardsRefillsALostOptionInPlace() {
        let cards = Self.makeCards(10)
        let s = Self.create(cards, seed: 21)
        #expect(s.queue.allSatisfy { $0.type == .mc && $0.choices?.count == 4 && $0.retryChoices?.count == 4 })
        let head = s.queue[0]
        let slot = head.choices!.firstIndex { $0.cardId != head.cardId }!
        let gone = head.choices![slot].cardId
        let left = cards.filter { $0.id != gone }
        let r = LearnEngine.removeCard(s, cardId: gone, now: T0 + SEC, cards: left, rng: mulberry32(seed: 22))
        let q = r.queue.first { $0.qid == head.qid }!
        #expect(q.choices?.count == 4)
        // The other options keep their places; the lost slot holds another valid option.
        for (i, c) in q.choices!.enumerated() where i != slot { #expect(c == head.choices![i]) }
        #expect(q.choices![slot].cardId != gone)
        Self.checkChoices(q, left)
        // Seven new cards in the first round: all multiple choice.
        for x in r.queue {
            #expect(x.choices?.count == 4)
            #expect(x.retryChoices?.count == 4)
            #expect(!x.choices!.map(\.cardId).contains(gone))
            #expect(!x.retryChoices!.map(\.cardId).contains(gone))
            Self.checkChoices(x, left)
            Self.checkChoices(x.retryChoices, cardId: x.cardId, ask: x.ask, cards: left)
        }
        // Without the cards the option is only dropped (as before).
        #expect(LearnEngine.removeCard(s, cardId: gone, now: T0 + SEC).queue.first { $0.qid == head.qid }?.choices?.count == 3)
    }

    @Test func removeCardRefillNeverTheRemovedOrAnEmptiedCardNeverADuplicate() {
        let cards = Self.makeCards(5)
        let s = Self.create(cards, seed: 23)
        // The card is still in the set but its definition was emptied: it cannot be an option either.
        let q0 = s.queue[0]
        let gone = q0.choices!.first { $0.cardId != q0.cardId }!.cardId
        let emptied = cards.map { $0.id == gone ? Card(id: $0.id, term: $0.term, definition: " ") : $0 }
        for seed in 1...20 {
            let r = LearnEngine.removeCard(s, cardId: gone, now: T0 + SEC, cards: emptied, rng: mulberry32(seed: seed))
            #expect(!r.queue.isEmpty)
            for q in r.queue {
                for list in [q.choices, q.retryChoices].compactMap({ $0 }) {
                    let ids = list.map(\.cardId)
                    #expect(!ids.contains(gone))
                    #expect(Set(ids).count == ids.count)
                    // Five cards minus the removed one leave exactly four possible options.
                    #expect(ids.count == 4)
                    #expect(ids.sorted() == cards.filter { $0.id != gone }.map(\.id).sorted())
                }
            }
        }
        // Four cards: every option is in use, so removing one leaves three.
        let four = Self.makeCards(4)
        let t = Self.create(four, seed: 24)
        let out = t.queue[0].choices!.first { $0.cardId != t.queue[0].cardId }!.cardId
        let r = LearnEngine.removeCard(
            t, cardId: out, now: T0 + SEC, cards: four.filter { $0.id != out }, rng: mulberry32(seed: 25))
        #expect(r.queue.allSatisfy { $0.retryChoices?.count == 3 && ($0.type != .mc || $0.choices?.count == 3) })
    }

    @Test func removeCardRefillSkipsSynonymsAndTextsEqualToARemainingOption() {
        let cards = [
            Card(id: "a", term: "le nom", definition: "der Name"),
            Card(id: "b", term: "le prénom", definition: "der Vorname"),
            Card(id: "c", term: "le nom de famille", definition: "der Nachname"),
            Card(id: "d", term: "la rue", definition: "die Strasse"),
            Card(id: "e", term: "le nom", definition: "der Name"),  // duplicate text of a
            Card(id: "f", term: "le patronyme", definition: "der Nachname"),  // synonym of c (same prompt)
            Card(id: "g", term: "la ville", definition: "die Stadt"),
        ]
        for seed in 1...30 {
            var s = Self.create(cards, subset: .cardIds(["c"]), seed: seed)
            let q = s.queue[0]
            let slot = q.choices!.firstIndex { $0.cardId != "c" }!
            let gone = q.choices![slot].cardId
            let left = cards.filter { $0.id != gone }
            s.order.append(gone)
            s.stage[gone] = 0
            let r = LearnEngine.removeCard(s, cardId: gone, now: T0 + SEC, cards: left, rng: mulberry32(seed: seed + 100))
            let ids = r.queue[0].choices!.map(\.cardId)
            #expect(!ids.contains("f"))
            let texts = r.queue[0].choices!.map { Self.textKey($0.text) }
            #expect(Set(texts).count == texts.count)
        }
    }

    // MARK: - Shared progress (Write mode, other windows)

    @Test func matchesAndSyncProgressLearnFollowsAnswersGivenInWriteMode() {
        let cards = Self.makeCards(6)
        var progress: ProgressMap = ["c5": Self.recorded(true), "c6": Self.recorded(true)]  // familiar → written
        var s = Self.create(cards, progress: progress, seed: 31)
        #expect(LearnEngine.matchesProgress(s, progress: progress))
        let ones = s.order.filter { $0 == "c5" || $0 == "c6" }
        let zeros = s.order.filter { !ones.contains($0) }
        #expect(s.queue.map(\.cardId) == ones + zeros + [zeros[0]])
        let first = LearnEngine.current(s)!
        s = LearnEngine.answer(s, correct: true, now: T0 + SEC)
        progress[first.cardId] = Mastery.applyAnswer(progress[first.cardId], correct: true, at: T0)  // what Learn records itself
        #expect(LearnEngine.matchesProgress(s, progress: progress))
        #expect(s.stage[first.cardId] == 2)

        // Write: the card Learn just mastered is answered wrong → learned again (in a later round).
        progress[first.cardId] = Mastery.applyAnswer(progress[first.cardId], correct: false, at: T0)
        #expect(!LearnEngine.matchesProgress(s, progress: progress))
        var r = LearnEngine.syncProgress(s, progress: progress, now: T0 + 2 * SEC)
        #expect(r.stage[first.cardId] == 0)
        #expect(LearnEngine.counts(r).mastered == 0)
        #expect(r.queue == s.queue)

        // Write: a queued multiple choice card is answered right → its questions become written.
        let mcQ = r.queue.first { $0.type == .mc }!
        #expect(mcQ.cardId == zeros[0])
        progress[mcQ.cardId] = Self.recorded(true)
        // Write: a queued written card (stage 1) is answered wrong → stage 0, but it stays written
        // (it was answered right before).
        let wQ = r.queue.first { $0.cardId == ones[1] }!
        #expect(wQ.type == .written)
        progress[ones[1]] = Mastery.applyAnswer(progress[ones[1]], correct: false, at: T0)
        // Write: another queued card is mastered → it leaves the round.
        let done = r.queue.first { $0.type == .mc && $0.cardId != mcQ.cardId }!
        progress[done.cardId] = Self.recorded(true, true)
        r = LearnEngine.syncProgress(r, progress: progress, now: T0 + 3 * SEC)
        #expect(LearnEngine.matchesProgress(r, progress: progress))
        #expect(
            r.queue.first { $0.qid == mcQ.qid }
                == LearnQueueQuestion(
                    qid: mcQ.qid, cardId: mcQ.cardId, type: .written, ask: mcQ.ask, retryChoices: mcQ.retryChoices))
        #expect(r.queue.filter { $0.cardId == mcQ.cardId }.map(\.type) == [.written, .written])
        #expect(r.stage[ones[1]] == 0)
        #expect(r.queue.first { $0.qid == wQ.qid } == wQ)
        #expect(!r.queue.contains { $0.cardId == done.cardId })
        #expect(r.stage[done.cardId] == 2)
        #expect(LearnEngine.counts(r).mastered == 1)
        // Nothing else changed, and a second sync is a no-op.
        #expect(r.answered == 1)
        #expect(r.roundLog == s.roundLog)
        #expect(r.clock == s.clock && r.lastAt == s.lastAt && r.repeats == s.repeats)
        #expect(LearnEngine.syncProgress(r, progress: progress, now: T0 + 4 * SEC) == r)

        // From here on Learn's own answers keep both in step.
        while !LearnEngine.isRoundOver(r) {
            let q = LearnEngine.current(r)!
            r = LearnEngine.answer(r, correct: true, now: T0 + 5 * SEC)
            progress[q.cardId] = Mastery.applyAnswer(progress[q.cardId], correct: true, at: T0)
            #expect(LearnEngine.matchesProgress(r, progress: progress))
        }
    }

    @Test func syncProgressACardMasteredBeforeButMissedElsewhereIsStudiedAgain() {
        let cards = Self.makeCards(4)
        var progress: ProgressMap = ["c1": Self.recorded(true, true)]
        var s = Self.create(cards, progress: progress, seed: 32)
        #expect(s.initiallyMastered == ["c1"])
        #expect(!s.queue.contains { $0.cardId == "c1" })
        progress["c1"] = Mastery.applyAnswer(progress["c1"], correct: false, at: T0)
        s = LearnEngine.syncProgress(s, progress: progress, now: T0 + SEC)
        #expect(s.stage["c1"] == 0)
        #expect(s.initiallyMastered.isEmpty)
        #expect(!s.queue.contains { $0.cardId == "c1" })  // not in this round
        #expect(LearnEngine.counts(s) == Self.counts(3, 1, 0, 4))
        s = Self.playRound(s, startAt: T0 + SEC) { _, _ in true }
        s = Self.next(s, cards, seed: 33, now: T0 + MIN)
        #expect(s.queue.first { $0.cardId == "c1" }?.type == .written)  // answered right before: no multiple choice
        #expect(LearnEngine.finalStats(s).alreadyMastered == 0)
    }

    @Test func syncProgressEverythingMasteredElsewhereFinishesTheSession() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, seed: 34)
        s = LearnEngine.answer(s, correct: true, now: T0 + SEC)
        var all: ProgressMap = [:]
        for c in cards { all[c.id] = Self.recorded(true, true) }
        let r = LearnEngine.syncProgress(s, progress: all, now: T0 + 2 * SEC)
        #expect(LearnEngine.isFinished(r))
        #expect(r.finishedAt == T0 + 2 * SEC)
        #expect(r.queue.isEmpty)
        #expect(r.round == 1)
        let closed = Self.next(r, cards, seed: 35, now: T0 + 3 * SEC)
        #expect(closed.rounds.count == 1)
        #expect(LearnEngine.finalStats(closed).rounds == 1)

        // At the start of a round (no answers in it yet) the session ends with the last closed round.
        var t = Self.create(cards, learn: LearnOptions(roundSize: 2), seed: 36)
        t = Self.playRound(t) { _, _ in true }
        t = Self.next(t, cards, seed: 37, now: T0 + MIN)
        #expect(t.round == 2)
        t = LearnEngine.syncProgress(t, progress: all, now: T0 + 2 * MIN)
        #expect(LearnEngine.isFinished(t))
        #expect(t.round == 1)
        #expect(LearnEngine.finalStats(t).rounds == 1)

        // A finished session keeps its result, whatever the progress says later.
        #expect(LearnEngine.matchesProgress(closed, progress: [:]))
        #expect(LearnEngine.syncProgress(closed, progress: [:], now: T0 + 4 * SEC) == closed)
    }

    @Test func syncProgressAResetElsewhereMakesTheCardsNewAgainOverridesStayInStep() {
        let cards = Self.makeCards(4)
        var progress: ProgressMap = [:]
        var s = Self.create(cards, seed: 38)
        let q = LearnEngine.current(s)!
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        progress[q.cardId] = Self.recorded(false)
        #expect(LearnEngine.matchesProgress(s, progress: progress))
        // "Ich hatte recht" in Learn = override in both.
        s = LearnEngine.override(s, now: T0 + 2 * SEC)
        progress[q.cardId] = Mastery.applyOverride(progress[q.cardId])
        #expect(LearnEngine.matchesProgress(s, progress: progress))
        #expect(s.queue.filter { $0.cardId == q.cardId }.map(\.type) == [.written])
        // The progress is reset in another window: its questions are multiple choice again.
        let r = LearnEngine.syncProgress(s, progress: [:], now: T0 + 3 * SEC)
        #expect(LearnEngine.counts(r) == Self.counts(4, 0, 0, 4))
        #expect(r.queue.filter { $0.cardId == q.cardId }.map(\.type) == [.mc])
        // Every first question of a card in the round is multiple choice.
        #expect(r.queue.filter { $0.qid.split(separator: ":")[0].split(separator: ".").count == 2 }.allSatisfy { $0.type == .mc })
        #expect(LearnEngine.matchesProgress(r, progress: [:]))
    }

    @Test func syncProgressFollowsTheQuestionTypeFlags() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, learn: LearnOptions(mc: false, written: true), seed: 39)
        let id = LearnEngine.current(s)!.cardId
        s = LearnEngine.syncProgress(s, progress: [id: Self.recorded(true)], now: T0 + SEC)
        #expect(s.queue.allSatisfy { $0.type == .written && $0.choices == nil })
        var m = Self.create(cards, learn: LearnOptions(mc: true, written: false), seed: 40)
        m = LearnEngine.syncProgress(m, progress: [LearnEngine.current(m)!.cardId: Self.recorded(true)], now: T0 + SEC)
        #expect(m.queue.allSatisfy { $0.type == .mc })
        // Junk input never traps.
        #expect(LearnEngine.matchesProgress(LearnEngine.copyState(.null), progress: [:]))
        #expect(LearnEngine.syncProgress(LearnEngine.copyState("junk"), progress: [:], now: T0).order.isEmpty)
    }

    // MARK: - Swift: typed API

    @Test func copyStateRepairsATypedState() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, seed: 2)
        #expect(LearnEngine.copyState(s) == s)
        s.order = ["c1", "", "c2", "c1", "c3", "c4"]
        s.stage["c1"] = 9
        s.stage["c2"] = -4
        s.stage["ghost"] = 1
        s.lastAt = ["c1": 0, "c2": -1, "ghost": 3]
        s.clock = -2
        s.repeats = -1
        s.recheck = LearnRecheck(due: ["ghost", "c3", "c3"])
        s.seen = ["c1": true, "c2": false, "ghost": true]
        s.misses = ["c3": -2, "ghost": 3]
        s.round = 0
        s.answered = -5
        s.correct = 3
        s.queue[0].qid = ""
        s.queue[1].choices = [Choice(cardId: s.queue[1].cardId, text: "only")]
        s.queue.append(LearnQueueQuestion(qid: "x", cardId: "ghost", type: .written, ask: .term))
        s.startedAt = .nan
        s.updatedAt = .infinity
        s.elapsedMs = -3
        s.learn = LearnSessionOptions(roundSize: 0, mc: false, written: false)
        s.subset = .cardIds(["c1", ""])
        let r = LearnEngine.copyState(s)
        #expect(r.order == ["c1", "c2", "c3", "c4"])
        #expect(r.stage == ["c1": 2, "c2": 0, "c3": 0, "c4": 0])
        #expect(r.lastAt == ["c1": 0])
        #expect(r.repeats == 0)
        #expect(r.recheck == LearnRecheck(due: ["c3"]))
        #expect(r.seen == ["c1": true])
        #expect(r.misses == ["c3": 0])
        #expect(r.round == 1)
        #expect(r.answered == 0 && r.correct == 0)
        #expect(r.clock == 0)  // the answer count stands in for a negative clock
        #expect(r.queue[0].qid == "1.q0:\(r.queue[0].cardId)")
        #expect(r.queue[1].type == .written && r.queue[1].choices == nil)
        #expect(!r.queue.contains { $0.cardId == "ghost" })
        #expect(r.startedAt == 0 && r.updatedAt == 0 && r.elapsedMs == 0)
        #expect(r.learn == LearnSessionOptions(roundSize: 7, mc: true, written: true))
        #expect(r.subset == .cardIds(["c1"]))
        #expect(LearnEngine.copyState(r) == r)
    }

    @Test func copyStateOfJSONIgnoresTheStoredFeedbackRecord() throws {
        let s = LearnEngine.answer(Self.create(Self.makeCards(5), seed: 3), correct: false, now: T0 + SEC)
        guard case var .object(o) = try JSONValue(encoding: s) else {
            Issue.record("not an object")
            return
        }
        o["feedback"] = ["qid": .string(s.last!.qid), "cardId": .string(s.last!.cardId), "type": "mc", "chosen": nil]
        #expect(LearnEngine.copyState(.object(o)) == s)
        #expect(LearnState(json: .object(o)) == s)
        #expect(try JSONValue.object(o).decode(as: LearnState.self) == s)
    }

    @Test func encodingWritesNullsLikeJSAndOmitsAbsentOptions() throws {
        let s = Self.create([Card(id: "solo", term: "le soleil", definition: "die Sonne")], seed: 1)
        let json = try JSONValue(encoding: s)
        #expect(json["last"] == .null)
        #expect(json["finishedAt"] == .null)
        #expect(json["queue"]?[0]?["choices"] == nil)
        #expect(json["queue"]?[0]?["retryChoices"] == nil)
        #expect(json["subset"] == "all")
        let q = try JSONValue(encoding: LearnEngine.current(s)!)
        #expect(q.objectValue?.keys.sorted() == ["ask", "cardId", "qid", "type"])
    }

    @Test func nonFiniteNowAndOddRngsAreHandled() {
        let cards = Self.makeCards(6)
        let s = LearnEngine.createLearn(cards, options: .default, rng: { .nan }, now: .nan)
        #expect(s.startedAt == 0 && s.updatedAt == 0)
        // Six new cards, then the first one again after the five others.
        #expect(s.queue.count == 7)
        for rng: RNG in [{ 1 }, { -1 }, { 2 }, { .infinity }, { -.infinity }] {
            let t = LearnEngine.createLearn(cards, options: .default, rng: rng, now: T0)
            #expect(t.queue.count == 7)
            #expect(t.queue.prefix(6).allSatisfy { $0.choices?.count == 4 })
        }
        let a = LearnEngine.answer(s, correct: false, now: .nan)
        #expect(a.updatedAt == 0 && a.elapsedMs == 0)
        #expect(a.answered == 1)
    }

    @Test func nextRoundWithoutCardsKeepsEveryCardAndAsksWritten() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, seed: 5)
        s = Self.playRound(s) { _, _ in false }
        let n = LearnEngine.nextRound(s, cards: nil, rng: mulberry32(seed: 1), now: T0 + MIN)
        #expect(n.order == s.order)
        #expect(n.round == 2)
        #expect(n.queue.allSatisfy { $0.type == .written && $0.choices == nil && $0.retryChoices == nil })
    }

    @Test func theStoreReadsLearnStatesBackThroughCopyState() throws {
        let store = LibraryStore(backend: MemoryBackend())
        let set = try store.createSet(title: "Wörter", cards: Self.makeCards(5).map(CardDraft.init))
        var s = LearnEngine.createLearn(set.cards, options: .default, rng: mulberry32(seed: 4), now: T0)
        s = LearnEngine.answer(s, correct: false, now: T0 + SEC)
        try store.saveLearn(set.id, s)
        #expect(store.getLearn(set.id) == s)
        let partial: JSONValue = ["v": 1, "round": 2, "order": [.string(set.cards[0].id)], "queue": ["x"], "finishedAt": nil]
        try store.saveLearnJSON(set.id, partial)
        #expect(store.getLearn(set.id) == LearnEngine.copyState(partial))
        try store.saveLearnJSON(set.id, "kaputt")
        #expect(store.getLearn(set.id) == nil)
    }
}
