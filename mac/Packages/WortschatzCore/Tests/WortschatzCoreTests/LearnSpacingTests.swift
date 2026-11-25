import Foundation
import Testing
import WortschatzCore

/// The order of Lernen since 1.4 (spacing, rechecks): a card comes back after at least MIN_GAP
/// other questions and at the latest after about MAX_WAIT, mixed with new cards; a card answered
/// wrong in a long session is checked once more 30–50 questions after it was mastered.
/// LearnEngineParityTests replays the JS reference question for question; these tests state the
/// rules themselves.
@Suite("Learn: spacing and rechecks")
struct LearnSpacingTests {
    static let T0: Double = 1_760_000_000_000

    static func makeCards(_ n: Int) -> [Card] {
        (1...n).map { i in Card(id: "c\(i)", term: "terme \(i)", definition: "Begriff \(i)") }
    }

    static func create(_ cards: [Card], mc: Bool = true, recheck: Bool = false, seed: Int = 1, roundSize: Int = 7)
        -> LearnState
    {
        LearnEngine.createLearn(
            cards, answerWith: .term, learn: LearnOptions(roundSize: roundSize, mc: mc), rng: mulberry32(seed: seed),
            now: T0, recheck: recheck)
    }

    /// The questions of a whole session in order; `decide(question, index)` says whether the
    /// answer is right.
    static func run(
        _ state: LearnState, _ cards: [Card], seed: Int = 7, _ decide: (LearnQueueQuestion, Int) -> Bool
    ) -> (asked: [LearnQueueQuestion], final: LearnState) {
        var s = state
        var asked: [LearnQueueQuestion] = []
        let rng = mulberry32(seed: seed)
        var t = T0
        var guardCount = 0
        while !LearnEngine.isFinished(s) {
            guardCount += 1
            precondition(guardCount < 5000, "the session did not end")
            t += 1000
            guard let q = s.queue.first else {
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t)
                continue
            }
            asked.append(q)
            s = LearnEngine.answer(s, correct: decide(q, asked.count - 1), now: t)
        }
        return (asked, s)
    }

    /// For every question of a card asked before: (other questions in between, cards still open
    /// then). Open = the cards asked from there on; with at least 11 of them the gap must be at
    /// least 10.
    static func gaps(_ asked: [LearnQueueQuestion]) -> [(gap: Int, open: Int)] {
        var last: [String: Int] = [:]
        var out: [(gap: Int, open: Int)] = []
        for (i, q) in asked.enumerated() {
            if let before = last[q.cardId] {
                out.append((i - before - 1, Set(asked[i...].map(\.cardId)).count))
            }
            last[q.cardId] = i
        }
        return out
    }

    @Test func everyCardComesBackAfterTenToFifteenOtherQuestions() {
        // Written only (the case that felt monotonous): every card twice, the second time 10–15
        // questions later.
        let cards = Self.makeCards(60)
        let (asked, final) = Self.run(Self.create(cards, mc: false), cards) { _, _ in true }
        #expect(asked.count == 120)
        for c in cards { #expect(asked.count { $0.cardId == c.id } == 2) }
        #expect(asked.allSatisfy { $0.type == .written })
        // Until the last few cards (fewer than 11 open), the gap is at least 10; never more than a
        // little over 15.
        for (gap, open) in Self.gaps(asked) {
            #expect(gap >= (open > LearnEngine.MIN_GAP ? LearnEngine.MIN_GAP : 0))
            #expect(gap <= LearnEngine.MAX_WAIT + 3)
        }
        #expect(LearnEngine.counts(final).mastered == 60)
    }

    @Test func newCardsComeFirstThenRepeatsAreMixedInAtMostThreeInARow() {
        let cards = Self.makeCards(60)
        let (asked, _) = Self.run(Self.create(cards, mc: false, seed: 4), cards) { _, _ in true }
        var seen = Set<String>()
        var run = 0
        var longest = 0
        var firstRepeat = -1
        for (i, q) in asked.enumerated() {
            let repeated = !seen.insert(q.cardId).inserted
            if repeated && firstRepeat < 0 { firstRepeat = i }
            run = repeated ? run + 1 : 0
            if seen.count < cards.count { longest = max(longest, run) }
        }
        // The first 11 questions are new cards (nothing may come back before 10 others), then the
        // mix starts.
        #expect(firstRepeat >= LearnEngine.MIN_GAP + 1)
        #expect(longest <= LearnEngine.MAX_REPEATS, "\(longest) repeats in a row while new cards were left")
    }

    @Test func withManyMistakesTheRepeatsStayLimited() {
        let cards = Self.makeCards(60)
        let rng = mulberry32(seed: 99)
        let (asked, final) = Self.run(Self.create(cards, mc: false, seed: 5), cards) { _, _ in rng() < 0.7 }
        #expect(LearnEngine.isFinished(final))
        var seen = Set<String>()
        var run = 0
        var longest = 0
        for q in asked {
            run = seen.insert(q.cardId).inserted ? 0 : run + 1
            if seen.count < cards.count { longest = max(longest, run) }
        }
        #expect(longest <= 2 * LearnEngine.MAX_REPEATS, "\(longest) repeats in a row while new cards were left")
        for (gap, open) in Self.gaps(asked) where open > LearnEngine.MIN_GAP {
            #expect(gap >= LearnEngine.MIN_GAP, "gap \(gap) with \(open) cards open")
        }
    }

    @Test func smallSetsUseTheLargestGapPossible() {
        let cards = Self.makeCards(5)
        let (asked, _) = Self.run(Self.create(cards, seed: 3), cards) { _, _ in true }
        #expect(asked.count == 10)
        // Every card once, then every card again in the same order: four others in between.
        #expect(asked.prefix(5).map(\.cardId) == asked.dropFirst(5).map(\.cardId))
        #expect(Self.gaps(asked).allSatisfy { $0.gap == 4 })
        #expect(asked.prefix(5).allSatisfy { $0.type == .mc })
        #expect(asked.dropFirst(5).allSatisfy { $0.type == .written })
    }

    @Test func aWrongAnswerIsNoLongerRetriedAtTheEndOfTheRound() {
        let cards = Self.makeCards(30)
        var s = Self.create(cards, mc: false)
        let first = s.queue[0].cardId
        s = LearnEngine.answer(s, correct: false, now: Self.T0 + 1000)
        #expect(s.stage[first] == 0)
        #expect(!s.queue.contains { $0.cardId == first })
        let (asked, _) = Self.run(s, cards) { _, _ in true }
        // Back after the gap (the miss was question 0; it is now learned twice more).
        let again = asked.firstIndex { $0.cardId == first } ?? -1
        #expect(again + 1 >= LearnEngine.MIN_GAP, "asked again after \(again + 1) questions")
        #expect(asked.count { $0.cardId == first } == 2)
    }

    @Test func laterQuestionsOfACardInTheRoundFollowAWrongAnswer() throws {
        // Three cards, 7 questions per round: each card comes more than once in a round.
        let cards = Self.makeCards(3)
        var s = Self.create(cards, roundSize: 7)
        let id = s.queue[0].cardId
        #expect(s.queue[0].qid == "1.1:\(id)")
        let later = try #require(s.queue.indices.dropFirst().first { s.queue[$0].cardId == id })
        #expect(s.queue[later].qid == "1.1.2:\(id)")
        #expect(s.queue[later].type == .written)
        // Wrong: the planned written question becomes multiple choice again (stage 0).
        s = LearnEngine.answer(s, correct: false, now: Self.T0 + 1000)
        #expect(s.queue.first { $0.cardId == id }?.type == .mc)
        // "Ich hatte recht": stage 1 again, so written again.
        s = LearnEngine.override(s, now: Self.T0 + 2000)
        #expect(s.queue.first { $0.cardId == id }?.type == .written)
    }

    @Test func rechecksNeedTheOptionAndMoreThanSixtyCards() throws {
        #expect(Self.create(Self.makeCards(61)).recheck == nil)
        #expect(Self.create(Self.makeCards(60), recheck: true).recheck == nil)
        #expect(Self.create(Self.makeCards(61), recheck: true).recheck == LearnRecheck())
        #expect(try JSONValue(encoding: Self.create(Self.makeCards(61)))["recheck"] == nil)
        #expect(try JSONValue(encoding: Self.create(Self.makeCards(61), recheck: true))["recheck"] != nil)
    }

    @Test func aCardMissedOnceIsCheckedAgainThirtyToFiftyQuestionsAfterItWasMastered() {
        let cards = Self.makeCards(80)
        let s = Self.create(cards, mc: false, recheck: true)
        let missed = s.queue[0].cardId
        let (asked, final) = Self.run(s, cards) { _, i in i != 0 }
        let mine = asked.enumerated().filter { $0.element.cardId == missed }
        // Wrong, then learned (twice right), then the recheck.
        #expect(mine.count == 4)
        guard mine.count == 4 else { return }
        #expect(LearnEngine.isRecheckQuestion(mine[3].element.qid))
        #expect(mine.prefix(3).allSatisfy { !LearnEngine.isRecheckQuestion($0.element.qid) })
        let gap = mine[3].offset - mine[2].offset - 1
        #expect(gap >= LearnEngine.RECHECK_GAP && gap <= LearnEngine.RECHECK_WAIT + 3)
        // No other card was missed: no other recheck.
        #expect(asked.count { LearnEngine.isRecheckQuestion($0.qid) } == 1)
        #expect(LearnEngine.isFinished(final))
        #expect(final.recheck?.due == [])
    }

    /// The study card shows "Nachkontrolle" (and the first one a hint): the question says what it is.
    @Test func theRecheckIsMarkedAsSuchOnScreen() throws {
        let cards = Self.makeCards(80)
        var s = Self.create(cards, mc: false, recheck: true)
        let missed = try #require(s.queue.first).cardId
        let rng = mulberry32(seed: 7)
        var t = Self.T0
        var recheck: LearnEngine.Question?
        var learning: [LearnEngine.Question] = []
        var guardCount = 0
        while recheck == nil, !LearnEngine.isFinished(s) {
            guardCount += 1
            try #require(guardCount < 5000, "no recheck came")
            t += 1000
            guard let q = LearnEngine.current(s) else {
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t)
                continue
            }
            if q.isRecheck { recheck = q } else { learning.append(q) }
            s = LearnEngine.answer(s, correct: s.answered > 0, now: t)
        }
        let found = try #require(recheck)
        #expect(found.cardId == missed)
        #expect(!found.isReview)
        #expect(learning.allSatisfy { !$0.isRecheck })

        let card = try #require(cards.first { $0.id == found.cardId })
        let info = LearnFlow.questionInfo(found, card: card, cards: cards, termLang: .fr, defLang: .de)
        #expect(info.isRecheck)
        #expect(!info.isReview)
        let first = try #require(learning.first)
        let firstCard = try #require(cards.first { $0.id == first.cardId })
        #expect(!LearnFlow.questionInfo(first, card: firstCard, cards: cards, termLang: .fr, defLang: .de).isRecheck)
    }

    @Test func aWrongRecheckLearnsTheCardAgainAndChecksItOnceMore() {
        let cards = Self.makeCards(80)
        let s = Self.create(cards, mc: false, recheck: true, seed: 2)
        let missed = s.queue[0].cardId
        var firstRecheck = true
        let (asked, final) = Self.run(s, cards) { q, i in
            if i == 0 { return false }
            if q.cardId == missed && LearnEngine.isRecheckQuestion(q.qid) && firstRecheck {
                firstRecheck = false
                return false
            }
            return true
        }
        let kinds = asked.filter { $0.cardId == missed }.map { LearnEngine.isRecheckQuestion($0.qid) }
        // wrong, right, right, recheck (wrong), right, right, recheck (right)
        #expect(kinds == [false, false, false, true, false, false, true])
        #expect(LearnEngine.finalStats(final).hardest.first { $0.cardId == missed }?.misses == 2)
        #expect(LearnEngine.isFinished(final))
    }

    @Test func theSessionIsOnlyFinishedAfterItsRechecks() {
        let cards = Self.makeCards(70)
        var s = Self.create(cards, mc: false, recheck: true, seed: 6)
        let missed = s.queue[0].cardId
        let rng = mulberry32(seed: 3)
        var t = Self.T0
        var sawPending = false
        var i = 0
        var guardCount = 0
        while !LearnEngine.isFinished(s) {
            guardCount += 1
            precondition(guardCount < 5000)
            t += 1000
            if s.queue.isEmpty {
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t)
                continue
            }
            s = LearnEngine.answer(s, correct: i != 0, now: t)
            i += 1
            let pending =
                (s.recheck?.due ?? []) + s.queue.filter { LearnEngine.isRecheckQuestion($0.qid) }.map(\.cardId)
            if !pending.isEmpty {
                sawPending = true
                #expect(pending == [missed])
                #expect(!LearnEngine.isFinished(s))
            }
        }
        #expect(sawPending, "the missed card never waited for its recheck")
    }

    @Test func aRecheckOfACardMissedElsewhereBecomesALearningQuestion() {
        let cards = Self.makeCards(70)
        var s = Self.create(cards, mc: false, recheck: true)
        let missed = s.queue[0].cardId
        var progress: ProgressMap = [:]
        let rng = mulberry32(seed: 8)
        var t = Self.T0
        var i = 0
        // Play until the recheck is queued.
        while !s.queue.contains(where: { LearnEngine.isRecheckQuestion($0.qid) }) {
            precondition(i < 5000)
            t += 1000
            guard let q = s.queue.first else {
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t)
                continue
            }
            let ok = i != 0
            i += 1
            progress[q.cardId] = Mastery.applyAnswer(progress[q.cardId], correct: ok, at: t)
            s = LearnEngine.answer(s, correct: ok, now: t)
        }
        // Missed in Schreiben meanwhile.
        progress[missed] = Mastery.applyAnswer(progress[missed], correct: false, at: t)
        s = LearnEngine.syncProgress(s, progress: progress, now: t + 1000)
        #expect(s.stage[missed] == 0)
        #expect(!s.queue.contains { LearnEngine.isRecheckQuestion($0.qid) })
        #expect(s.queue.contains { $0.cardId == missed && $0.qid.contains(".1") })
        #expect(!(s.recheck?.due.contains(missed) ?? true))
    }

    @Test func aSessionStoredBeforeSpacingGoesOn() throws {
        // A 1.3 session: batch (active), retries, no clock.
        let json = try JSONValue.parse(
            #"""
            {"v":1,"subset":"all","answerWith":"term","learn":{"roundSize":3,"mc":false,"written":true},
             "order":["c1","c2","c3","c4","c5"],"stage":{"c1":1,"c2":0,"c3":0,"c4":0,"c5":0},"initiallyMastered":[],
             "seen":{"c1":true,"c2":true},"active":["c1","c2","c3"],"round":1,
             "queue":[{"qid":"1.1:c3","cardId":"c3","type":"written","ask":"term"},
              {"qid":"1.2:c2","cardId":"c2","type":"written","ask":"term"}],
             "retried":{"c2":true},"roundLog":[{"qid":"1.1:c1","cardId":"c1","type":"written","ask":"term","correct":true,"stageAfter":1},
             {"qid":"1.1:c2","cardId":"c2","type":"written","ask":"term","correct":false,"stageAfter":0}],
             "rounds":[],"answered":2,"correct":1,"misses":{"c2":1},"last":null,"startedAt":0,"updatedAt":0,
             "finishedAt":null,"elapsedMs":0}
            """#)
        let s = LearnState(json: json)
        #expect(s.clock == 2)
        #expect(s.lastAt.isEmpty)
        let encoded = try JSONValue(encoding: s)
        #expect(encoded["active"] == nil)
        #expect(encoded["retried"] == nil)
        #expect(s.queue.map(\.qid) == ["1.1:c3", "1.2:c2"])
        let (_, final) = Self.run(s, Self.makeCards(5)) { _, _ in true }
        #expect(LearnEngine.isFinished(final))
        #expect(LearnEngine.counts(final).mastered == 5)
    }
}
