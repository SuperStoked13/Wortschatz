import Foundation
import Testing
import WortschatzCore

/// Direction, question types and round size (Lernen) and direction and «Mischen» (Schreiben) apply
/// to a running session at once (since 25.11.2026; Anthony: keep learning with the new options
/// instead of having to restart). Before, Lernen's and Schreiben's options asked «Neu starten?» and
/// options changed elsewhere never reached a session already started (GitHub issue #7).
@Suite("Options apply at once to running sessions")
struct OptionsAtOnceTests {
    static let T0: Double = 1_760_000_000_000

    static func makeCards(_ n: Int) -> [Card] {
        (1...n).map { i in Card(id: "c\(i)", term: "terme \(i)", definition: "Begriff \(i)") }
    }

    static func learn(_ cards: [Card], roundSize: Int = 7, mc: Bool = true, written: Bool = true, review: Bool = false,
                      progress: ProgressMap = [:]) -> LearnState {
        LearnEngine.createLearn(
            cards, answerWith: .term, learn: LearnOptions(roundSize: roundSize, mc: mc, written: written),
            progress: progress, rng: mulberry32(seed: 1), now: T0, review: review)
    }

    /// Every multiple-choice question offers its card's answer on the side it asks.
    static func choicesFit(_ s: LearnState, _ cards: [Card]) -> Bool {
        s.queue.allSatisfy { q in
            guard q.type == .mc else { return q.choices == nil }
            guard let card = cards.first(where: { $0.id == q.cardId }), let choices = q.choices else { return false }
            return choices.count >= 2
                && choices.contains { $0.cardId == q.cardId && $0.text == Synonyms.answerSide(card, ask: q.ask) }
        }
    }

    // MARK: - Lernen

    @Test func unchangedOptionsOrAFinishedSessionStayAsTheyAre() {
        let cards = Self.makeCards(8)
        let s = Self.learn(cards)
        let same = LearnEngine.setOptions(
            s, answerWith: .term, learn: LearnOptions(roundSize: 7), cards: cards, rng: mulberry32(seed: 9))
        #expect(same == s)
        var finished = s
        finished.finishedAt = Self.T0 + 1
        let after = LearnEngine.setOptions(
            finished, answerWith: .definition, learn: LearnOptions(roundSize: 3), cards: cards, rng: mulberry32(seed: 9))
        #expect(after == finished)
    }

    @Test func anotherDirectionAsksTheQuestionsStillToComeOnTheOtherSide() {
        let cards = Self.makeCards(8)
        var s = Self.learn(cards)
        s = LearnEngine.answer(s, correct: true, now: Self.T0 + 1000)
        let stages = s.stage
        let qids = s.queue.map(\.qid)
        let types = s.queue.map(\.type)
        let next = LearnEngine.setOptions(
            s, answerWith: .definition, learn: LearnOptions(), cards: cards, rng: mulberry32(seed: 9))
        #expect(next.answerWith == .definition)
        #expect(next.stage == stages)
        #expect(next.answered == s.answered)
        #expect(next.queue.map(\.qid) == qids)
        #expect(next.queue.map(\.type) == types)
        #expect(next.queue.allSatisfy { $0.ask == .definition })
        #expect(Self.choicesFit(next, cards))
        // Both directions: every question keeps its side.
        let both = LearnEngine.setOptions(
            s, answerWith: .both, learn: LearnOptions(), cards: cards, rng: mulberry32(seed: 9))
        #expect(both.queue == s.queue)
        #expect(both.answerWith == .both)
    }

    @Test func questionTypesFollowEachQuestionsPlannedStage() {
        let cards = Self.makeCards(4)
        let s = Self.learn(cards)
        // A new card is planned as multiple choice first, written the second time.
        #expect(s.queue.contains { $0.type == .written })
        let writtenOnly = LearnEngine.setOptions(
            s, answerWith: .term, learn: LearnOptions(mc: false), cards: cards, rng: mulberry32(seed: 9))
        #expect(writtenOnly.queue.allSatisfy { $0.type == .written && $0.choices == nil })
        let mcOnly = LearnEngine.setOptions(
            writtenOnly, answerWith: .term, learn: LearnOptions(written: false), cards: cards, rng: mulberry32(seed: 9))
        #expect(mcOnly.queue.allSatisfy { $0.type == .mc })
        #expect(Self.choicesFit(mcOnly, cards))
        // Both again: as planned at the start.
        let back = LearnEngine.setOptions(
            mcOnly, answerWith: .term, learn: LearnOptions(), cards: cards, rng: mulberry32(seed: 9))
        #expect(back.queue.map(\.type) == s.queue.map(\.type))
        #expect(Self.choicesFit(back, cards))
    }

    @Test func aSmallerRoundEndsThisRoundSoonerALargerOneCountsFromTheNext() {
        let cards = Self.makeCards(12)
        var s = Self.learn(cards, roundSize: 8)
        s = LearnEngine.answer(s, correct: true, now: Self.T0 + 1000)
        s = LearnEngine.answer(s, correct: true, now: Self.T0 + 2000)
        #expect(s.queue.count == 6)
        let smaller = LearnEngine.setOptions(
            s, answerWith: .term, learn: LearnOptions(roundSize: 5), cards: cards, rng: mulberry32(seed: 9))
        #expect(smaller.learn.roundSize == 5)
        #expect(smaller.queue == Array(s.queue.prefix(3)))
        // Already past it: the question asked now stays, then the round ends.
        let tiny = LearnEngine.setOptions(
            s, answerWith: .term, learn: LearnOptions(roundSize: 1), cards: cards, rng: mulberry32(seed: 9))
        #expect(tiny.queue == [s.queue[0]])
        let larger = LearnEngine.setOptions(
            s, answerWith: .term, learn: LearnOptions(roundSize: 20), cards: cards, rng: mulberry32(seed: 9))
        #expect(larger.queue == s.queue)
        #expect(LearnEngine.isRoundOver(LearnEngine.answer(tiny, correct: true, now: Self.T0 + 3000)))
    }

    @Test func repetitionQuestionsTakenOutOfTheRoundWaitForTheNext() {
        let cards = Self.makeCards(12)
        var progress: ProgressMap = [:]
        for card in cards.prefix(6) {
            progress[card.id] = CardProgress(
                correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: Self.T0 - 100_000)
        }
        let s = Self.learn(cards, roundSize: 20, review: true, progress: progress)
        let queuedReviews = s.queue.filter { LearnEngine.isReviewQuestion($0.qid) }.map(\.cardId)
        #expect(!queuedReviews.isEmpty)
        let next = LearnEngine.setOptions(
            s, answerWith: .term, learn: LearnOptions(roundSize: 1), cards: cards, rng: mulberry32(seed: 9))
        let kept = next.queue.filter { LearnEngine.isReviewQuestion($0.qid) }.map(\.cardId)
        let waiting = Set(next.review?.due ?? [])
        for id in queuedReviews where !kept.contains(id) { #expect(waiting.contains(id)) }
        #expect(LearnEngine.reviewStats(next)?.left == LearnEngine.reviewStats(s)?.left)
    }

    // MARK: - Schreiben

    static let three = [
        Card(id: "a", term: "le chat", definition: "die Katze"),
        Card(id: "b", term: "le chien", definition: "der Hund"),
        Card(id: "c", term: "la maison", definition: "das Haus"),
    ]

    static func write(_ answerWith: AnswerWith = .term, shuffle: Bool = false) -> SessionState {
        WriteSession.createSession(
            three, answerWith: answerWith, shuffle: shuffle, rng: mulberry32(seed: 1), now: T0)
    }

    static func set(_ s: SessionState, _ answerWith: AnswerWith, shuffle: Bool = false) -> SessionState {
        WriteSession.setOptions(
            s, answerWith: answerWith, shuffle: shuffle, cards: three, rng: mulberry32(seed: 5), now: T0 + 9000)
    }

    @Test func theOtherDirectionTurnsEveryQuestionAroundWithItsAnswers() {
        var s = Self.write()
        s = WriteSession.answer(s, correct: true, now: Self.T0 + 1000)  // a:t
        s = WriteSession.answer(s, correct: false, now: Self.T0 + 2000)  // b:t
        let next = Self.set(s, .definition)
        #expect(next.setOptions.answerWith == .definition)
        #expect(next.order == ["a:d", "b:d", "c:d"])
        #expect(next.queue == ["c:d"])
        #expect(next.done == ["a:d"])
        #expect(next.misses["b:d"] == 1)
        #expect(next.attempts["a:d"] == 1)
        #expect(next.firstTry == ["a:d": true, "b:d": false])
        #expect(next.roundAnswered.map(\.qid) == ["a:d", "b:d"])
        #expect(WriteSession.counters(next) == WriteSession.counters(s))
        #expect(next.questions["b:d"] == SessionQuestion(qid: "b:d", cardId: "b", ask: .definition))
        // The missed one comes back in the next round, the other way round.
        let last = WriteSession.answer(next, correct: true, now: Self.T0 + 10_000)
        let round2 = WriteSession.nextRound(last, now: Self.T0 + 11_000)
        #expect(round2.queue == ["b:d"])
    }

    @Test func aDirectionAddedAsksEveryCardThatWayInThisRound() {
        var s = Self.write()
        s = WriteSession.answer(s, correct: true, now: Self.T0 + 1000)
        let next = Self.set(s, .both)
        #expect(next.order == ["a:t", "b:t", "c:t", "a:d", "b:d", "c:d"])
        #expect(next.queue == ["b:t", "c:t", "a:d", "b:d", "c:d"])
        #expect(next.done == ["a:t"])
        #expect(WriteSession.counters(next).total == 6)
        // Shuffled: the question asked now stays first, the rest is mixed, never a card twice in a row.
        let mixed = Self.set(s, .both, shuffle: true)
        #expect(mixed.queue.first == "b:t")
        #expect(Set(mixed.queue) == Set(next.queue))
        for (x, y) in zip(mixed.queue, mixed.queue.dropFirst()) {
            #expect(mixed.questions[x]?.cardId != mixed.questions[y]?.cardId)
        }
    }

    @Test func aDirectionDroppedTakesItsOpenQuestionsOutAndKeepsTheRightOnes() {
        var s = Self.write(.both)
        #expect(s.queue == ["a:t", "b:t", "c:t", "a:d", "b:d", "c:d"])
        for _ in 0..<4 { s = WriteSession.answer(s, correct: true, now: Self.T0 + 1000) }  // up to a:d
        let next = Self.set(s, .term)
        #expect(next.queue.isEmpty)
        #expect(next.done == ["a:t", "b:t", "c:t", "a:d"])
        #expect(next.order == ["a:t", "b:t", "c:t", "a:d"])
        #expect(next.finishedAt != nil)
        // The open ones come back when the direction is added again.
        let again = Self.set(Self.set(Self.write(.both), .term), .both)
        #expect(Set(again.order) == Set(Self.write(.both).order))
    }

    @Test func mischenOffPutsTheQuestionsStillToComeInTheSetsOrder() {
        let s = WriteSession.answer(Self.write(.both, shuffle: true), correct: true, now: Self.T0 + 1000)
        let ordered = Self.set(s, .both, shuffle: false)
        #expect(ordered.setOptions.shuffle == false)
        let rank = ["a:t": 0, "b:t": 1, "c:t": 2, "a:d": 3, "b:d": 4, "c:d": 5]
        let rest = ordered.queue.dropFirst().map { rank[$0]! }
        #expect(rest == rest.sorted())
        #expect(ordered.queue.first == s.queue.first)
        #expect(ordered.order == ["a:t", "b:t", "c:t", "a:d", "b:d", "c:d"])
    }

    @Test func aFinishedWriteSessionStaysAsItIs() {
        var s = Self.write()
        for _ in 0..<3 { s = WriteSession.answer(s, correct: true, now: Self.T0 + 1000) }
        #expect(s.finishedAt != nil)
        #expect(Self.set(s, .both) == s)
    }
}
