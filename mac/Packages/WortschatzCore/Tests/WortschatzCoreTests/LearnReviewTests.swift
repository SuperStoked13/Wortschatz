import Foundation
import Testing
import WortschatzCore

/// Repetition questions (Wiederholungsfragen, `LearnReview`): an option of the Mac app. Cards
/// mastered before the session are asked once more, mixed into the rounds; a miss sends them back
/// to "Am Lernen". Without the option every session stays the web app's (see the parity tests).
@Suite("Learn: repetition questions")
struct LearnReviewTests {
    static let T0: Double = 1_760_000_000_000

    static func makeCards(_ n: Int) -> [Card] {
        (0..<n).map { i in Card(id: "c\(i + 1)", term: "terme \(i + 1)", definition: "Begriff \(i + 1)") }
    }

    /// Mastered cards, `c1` answered longest ago.
    static func mastered(_ cards: [Card]) -> ProgressMap {
        var p: ProgressMap = [:]
        for (i, c) in cards.enumerated() {
            p[c.id] = CardProgress(
                correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: T0 - 100_000 + Double(i))
        }
        return p
    }

    static func create(
        _ cards: [Card], progress: ProgressMap = [:], roundSize: Int = 7, review: Bool = true, seed: Int = 3
    ) -> LearnState {
        LearnEngine.createLearn(
            cards, answerWith: .term, learn: LearnOptions(roundSize: roundSize), progress: progress,
            rng: mulberry32(seed: seed), now: T0, review: review)
    }

    /// Answers the round's questions; `decide` says whether an answer is right.
    static func play(_ state: LearnState, at start: Double = T0, _ decide: (LearnEngine.Question) -> Bool) -> LearnState {
        var s = state
        var t = start
        var guardCount = 0
        while let q = LearnEngine.current(s) {
            guardCount += 1
            precondition(guardCount <= 200, "round did not end")
            t += 1000
            s = LearnEngine.answer(s, correct: decide(q), now: t)
        }
        return s
    }

    // MARK: - The question ids

    @Test func repetitionQuestionsAreRecognisedByTheirId() {
        #expect(LearnEngine.isReviewQuestion("1.3:c1"))
        #expect(LearnEngine.isReviewQuestion("12.3:a:b"))
        #expect(!LearnEngine.isReviewQuestion("1.1:c1"))
        #expect(!LearnEngine.isReviewQuestion("1.2:c1"))
        #expect(!LearnEngine.isReviewQuestion(".3:c1"))
        #expect(!LearnEngine.isReviewQuestion("x.3:c1"))
        #expect(!LearnEngine.isReviewQuestion("1.q3:c1"))
        #expect(!LearnEngine.isReviewQuestion("13"))
        #expect(LearnEngine.reviewsPerRound(7) == 2)
        #expect(LearnEngine.reviewsPerRound(5) == 1)
        #expect(LearnEngine.reviewsPerRound(1) == 1)
        #expect(LearnEngine.reviewsPerRound(15) == 5)
    }

    // MARK: - Without the option

    @Test func withoutTheOptionNothingChanges() throws {
        let cards = Self.makeCards(9)
        var progress = Self.mastered(Array(cards.prefix(4)))
        progress["c5"] = CardProgress(correct: 1, streak: 1, lastResult: .correct, lastAnsweredAt: Self.T0 - 5)
        let plain = LearnEngine.createLearn(
            cards, answerWith: .term, learn: LearnOptions(roundSize: 7), progress: progress, rng: mulberry32(seed: 3),
            now: Self.T0)
        let off = Self.create(cards, progress: progress, review: false)
        #expect(plain == off)
        #expect(off.review == nil)
        #expect(!off.queue.contains { LearnEngine.isReviewQuestion($0.qid) })
        #expect(LearnEngine.reviewStats(off) == nil)
        let json = try JSONValue(encoding: off)
        #expect(json["review"] == nil)
    }

    @Test func everythingMasteredWithoutTheOptionIsFinishedAtOnce() {
        let cards = Self.makeCards(5)
        let s = Self.create(cards, progress: Self.mastered(cards), review: false)
        #expect(LearnEngine.isFinished(s))
        #expect(s.queue.isEmpty)
    }

    // MARK: - Rounds

    @Test func aFewRepetitionQuestionsJoinEachRoundMostOverdueFirst() {
        let cards = Self.makeCards(10)
        // c1…c6 mastered (c1 answered longest ago), c7…c10 new.
        let s = Self.create(cards, progress: Self.mastered(Array(cards.prefix(6))))
        #expect(s.review?.due == ["c3", "c4", "c5", "c6"])
        let reviews = s.queue.filter { LearnEngine.isReviewQuestion($0.qid) }
        #expect(Set(reviews.map(\.cardId)) == ["c1", "c2"])
        #expect(s.queue.count == 4 + 2)
        // Mastered cards are asked written, with options ready for a retry.
        for q in reviews {
            #expect(q.type == .written)
            #expect(q.retryChoices != nil)
            #expect(q.qid == "1.3:\(q.cardId)")
        }
        #expect(!LearnEngine.isFinished(s))
        #expect(LearnEngine.reviewStats(s) == LearnEngine.ReviewStats(asked: 0, kept: 0, left: 6))
    }

    @Test func aWholeRoundOfRepetitionWhenEverythingIsMastered() {
        let cards = Self.makeCards(10)
        let s = Self.create(cards, progress: Self.mastered(cards), roundSize: 7)
        #expect(!LearnEngine.isFinished(s))
        #expect(s.finishedAt == nil)
        #expect(s.queue.count == 7)
        #expect(s.queue.allSatisfy { LearnEngine.isReviewQuestion($0.qid) })
        #expect(LearnEngine.current(s)?.isReview == true)
        #expect(s.review?.due.count == 3)
    }

    @Test func theSessionEndsOnceEveryMasteredCardWasAskedAgain() {
        let cards = Self.makeCards(10)
        var s = Self.create(cards, progress: Self.mastered(cards), roundSize: 7)
        s = Self.play(s) { _ in true }
        #expect(LearnEngine.isRoundOver(s))
        #expect(!LearnEngine.isFinished(s))
        s = LearnEngine.nextRound(s, cards: cards, rng: mulberry32(seed: 4), now: Self.T0 + 60_000)
        #expect(s.round == 2)
        #expect(s.queue.count == 3)
        s = Self.play(s, at: Self.T0 + 60_000) { _ in true }
        #expect(LearnEngine.isFinished(s))
        #expect(s.finishedAt != nil)
        #expect(LearnEngine.reviewStats(s) == LearnEngine.ReviewStats(asked: 10, kept: 10, left: 0))
        let stats = LearnEngine.finalStats(s)
        #expect(stats.mastered == 10)
        #expect(stats.alreadyMastered == 10)
    }

    // MARK: - Answers

    @Test func aMissedRepetitionQuestionSendsTheCardBackToLearning() {
        let cards = Self.makeCards(6)
        let progress = Self.mastered(cards)
        var s = Self.create(cards, progress: progress, roundSize: 5)
        let first = LearnEngine.current(s)!
        #expect(first.isReview)
        s = LearnEngine.answer(s, correct: false, now: Self.T0 + 1000)
        #expect(s.stage[first.cardId] == 0)
        #expect(!s.initiallyMastered.contains(first.cardId))
        #expect(s.review?.results[first.cardId] == false)
        // Asked once more at the end of the round, as multiple choice.
        let retry = s.queue.last!
        #expect(retry.cardId == first.cardId)
        #expect(retry.qid == "1.2:\(first.cardId)")
        #expect(!LearnEngine.isReviewQuestion(retry.qid))
        #expect(retry.type == .mc)
        #expect(LearnEngine.counts(s).mastered == 5)
        // What the store records for it: no longer mastered.
        let recorded = Mastery.applyAnswer(progress[first.cardId], correct: false, at: Self.T0 + 1000)
        #expect(Mastery.cardStatus(recorded) == .learning)
        #expect(LearnEngine.reviewStats(s) == LearnEngine.ReviewStats(asked: 1, kept: 0, left: 5))
    }

    @Test func aMissedCardIsLearnedAgainUntilItIsMastered() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, progress: Self.mastered(cards), roundSize: 7)
        let missed = LearnEngine.current(s)!.cardId
        var first = true
        s = Self.play(s) { _ in
            defer { first = false }
            return !first
        }
        // The retry was right: stage 1, so the card comes back in the next round, written.
        #expect(s.stage[missed] == 1)
        #expect(!LearnEngine.isFinished(s))
        s = LearnEngine.nextRound(s, cards: cards, rng: mulberry32(seed: 9), now: Self.T0 + 60_000)
        #expect(s.active == [missed])
        #expect(s.queue.map(\.cardId) == [missed])
        #expect(!LearnEngine.isReviewQuestion(s.queue[0].qid))
        s = Self.play(s, at: Self.T0 + 60_000) { _ in true }
        #expect(LearnEngine.isFinished(s))
        let stats = LearnEngine.finalStats(s)
        #expect(stats.alreadyMastered == 3)
        #expect(LearnFlow.reviewLine(LearnEngine.reviewStats(s)!) == "4 gemeisterte Begriffe wiederholt, 1 davon ist wieder am Lernen.")
    }

    @Test func iWasRightKeepsTheCardMastered() {
        let cards = Self.makeCards(4)
        var s = Self.create(cards, progress: Self.mastered(cards), roundSize: 7)
        let q = LearnEngine.current(s)!
        s = LearnEngine.answer(s, correct: false, now: Self.T0 + 1000)
        s = LearnEngine.override(s, now: Self.T0 + 2000)
        #expect(s.stage[q.cardId] == 2)
        #expect(s.initiallyMastered.contains(q.cardId))
        #expect(s.initiallyMastered == s.order.filter { s.initiallyMastered.contains($0) })
        #expect(s.review?.results[q.cardId] == true)
        #expect(!s.queue.contains { $0.cardId == q.cardId })
    }

    @Test func onlyTheFirstAnswerOfARepetitionCounts() {
        let cards = Self.makeCards(3)
        var s = Self.create(cards, progress: Self.mastered(cards), roundSize: 7)
        let q = LearnEngine.current(s)!
        s = LearnEngine.answer(s, correct: false, now: Self.T0 + 1000)
        s = Self.play(s, at: Self.T0 + 1000) { _ in true }
        #expect(s.review?.results[q.cardId] == false)
        #expect(LearnEngine.reviewStats(s)?.kept == 2)
    }

    // MARK: - Changes and storage

    @Test func aDeletedCardLeavesTheRepetition() {
        let cards = Self.makeCards(10)
        var s = Self.create(cards, progress: Self.mastered(Array(cards.prefix(6))))
        s = LearnEngine.removeCard(s, cardId: "c3", now: Self.T0 + 1000, cards: cards.filter { $0.id != "c3" })
        #expect(s.review?.due == ["c4", "c5", "c6"])
        s = LearnEngine.removeCard(s, cardId: "c1", now: Self.T0 + 2000)
        #expect(!s.queue.contains { $0.cardId == "c1" })
        #expect(LearnEngine.reviewStats(s)?.left == 4)
    }

    @Test func aCardMissedElsewhereIsLearnedInsteadOfRepeated() {
        let cards = Self.makeCards(8)
        var progress = Self.mastered(Array(cards.prefix(6)))
        var s = Self.create(cards, progress: progress)
        // c5 is answered wrong in Schreiben: no longer mastered.
        progress["c5"] = Mastery.applyAnswer(progress["c5"], correct: false, at: Self.T0 + 500)
        s = LearnEngine.syncProgress(s, progress: progress, now: Self.T0 + 600)
        s = Self.play(s, at: Self.T0 + 600) { _ in true }
        s = LearnEngine.nextRound(s, cards: cards, rng: mulberry32(seed: 5), now: Self.T0 + 60_000)
        #expect(s.active.contains("c5"))
        #expect(!(s.review?.due.contains("c5") ?? true))
        #expect(!s.queue.contains { $0.cardId == "c5" && LearnEngine.isReviewQuestion($0.qid) })
    }

    @Test func theRepetitionSurvivesStorage() throws {
        let cards = Self.makeCards(8)
        var s = Self.create(cards, progress: Self.mastered(Array(cards.prefix(5))))
        s = LearnEngine.answer(s, correct: true, now: Self.T0 + 1000)
        let json = try JSONValue(encoding: s)
        #expect(json["review"]?["due"] != nil)
        #expect(LearnState(json: json) == s)
        let decoded = try JSONDecoder().decode(LearnState.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        // Unknown cards and junk are dropped on repair.
        var o = json.objectValue!
        o["review"] = ["due": ["c4", "zz", 7, "c4"], "results": ["c1": true, "zz": false, "c2": "x"]]
        let repaired = LearnState(json: .object(o))
        #expect(repaired.review == LearnReview(due: ["c4"], results: ["c1": true]))
    }

    // MARK: - The Learn screen

    static func set(_ cards: [Card]) -> VocabSet {
        VocabSet(id: "set1", title: "Wörter", termLang: .fr, defLang: .de, cards: cards, createdAt: T0)
    }

    @Test func theScreenStartsWithRepetitionWhenEverythingIsMastered() {
        let cards = Self.makeCards(5)
        let progress = Self.mastered(cards)
        let (off, _) = LearnFlow.start(set: Self.set(cards), progress: progress, options: .default, now: Self.T0)
        #expect(off.phase == .allMastered)
        #expect(LearnFlow.message(off)?.offersReview == true)

        let (on, effects) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, review: true, rng: mulberry32(seed: 2),
            now: Self.T0)
        #expect(on.phase == .question(.written))
        #expect(on.question?.isReview == true)
        #expect(effects.contains { if case .saveLearn = $0 { true } else { false } })
    }

    @Test func repeatAllStartsARepetitionSession() {
        let cards = Self.makeCards(5)
        let progress = Self.mastered(cards)
        let (state, _) = LearnFlow.start(set: Self.set(cards), progress: progress, options: .default, now: Self.T0)
        let env = LearnFlow.Env(rng: mulberry32(seed: 2), now: Self.T0 + 5000, progress: progress)
        let (next, _) = LearnFlow.reduce(state, .startReview, env: env)
        #expect(next.phase == .question(.written))
        #expect(next.session?.review != nil)
        #expect(next.question?.isReview == true)
        // The option itself stays as it was.
        #expect(next.review == false)
    }

    @Test func aMissedRepetitionSaysTheCardIsLearnedAgain() {
        let cards = Self.makeCards(5)
        var progress = Self.mastered(cards)
        var (state, _) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, review: true, rng: mulberry32(seed: 2),
            now: Self.T0)
        let cardId = state.question!.cardId
        var env = LearnFlow.Env(rng: mulberry32(seed: 2), now: Self.T0 + 3000, progress: progress)
        (state, _) = LearnFlow.reduce(state, .draftChanged("faux"), env: env)
        env.now += 2000
        let (after, effects) = LearnFlow.reduce(state, .submit("faux"), env: env)
        #expect(after.phase == .feedback(.wrong))
        #expect(after.feedback?.demoted == true)
        #expect(effects.contains(.recordAnswer(cardId: cardId, correct: false, at: env.now)))
        #expect(effects.contains { if case let .announce(text) = $0 { text.contains(LearnFlow.DEMOTED_TEXT) } else { false } })
        progress[cardId] = Mastery.applyAnswer(progress[cardId], correct: false, at: env.now)
        #expect(Mastery.cardStatus(progress[cardId]) == .learning)
    }

    @Test func switchingTheOptionAsksToRestart() {
        let cards = Self.makeCards(6)
        let (start, _) = LearnFlow.start(
            set: Self.set(cards), progress: [:], options: .default, rng: mulberry32(seed: 2), now: Self.T0)
        let env = LearnFlow.Env(rng: mulberry32(seed: 2), now: Self.T0 + 1000)
        var (s, _) = LearnFlow.reduce(start, .overlayPresented(.options), env: env)
        (s, _) = LearnFlow.reduce(s, .reviewChanged(true), env: env)
        (s, _) = LearnFlow.reduce(s, .overlayDismissed, env: env)
        #expect(s.prompt == .restartForOptions([.review]))
        #expect(LearnFlow.restartMessage([.review]).hasPrefix("Die Einstellung für Wiederholungsfragen gilt ab einem Neustart."))
        let (restarted, _) = LearnFlow.reduce(s, .promptAnswered(confirmed: true), env: env)
        #expect(restarted.session?.review != nil)
        #expect(LearnFlow.sessionSettings(restarted.session!).review)
    }
}
