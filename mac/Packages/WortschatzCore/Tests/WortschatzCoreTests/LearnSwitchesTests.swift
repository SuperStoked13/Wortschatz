import Foundation
import Testing
import WortschatzCore

/// «Wiederholungsfragen» and «Nachkontrolle nach Fehlern» apply to a running session at once
/// (since 24.11.2026). Before, a session kept what it was started with: switched off in
/// Einstellungen, a long session went on asking rechecks for days.
@Suite("Learn: switching repetition questions and rechecks")
struct LearnSwitchesTests {
    static let T0: Double = 1_760_000_000_000

    static func makeCards(_ n: Int) -> [Card] {
        (1...n).map { i in Card(id: "c\(i)", term: "terme \(i)", definition: "Begriff \(i)") }
    }

    static func set(_ cards: [Card]) -> VocabSet {
        VocabSet(id: "set1", title: "Wörter", termLang: .fr, defLang: .de, cards: cards, createdAt: T0)
    }

    static func mastered(_ ids: [String]) -> ProgressMap {
        var p: ProgressMap = [:]
        for (i, id) in ids.enumerated() {
            p[id] = CardProgress(
                correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: T0 - 100_000 + Double(i))
        }
        return p
    }

    /// Plays written questions (the first card wrong once) until a recheck is queued.
    static func untilARecheckIsQueued(_ cards: [Card]) -> (LearnState, ProgressMap, Double) {
        var s = LearnEngine.createLearn(
            cards, answerWith: .term, learn: LearnOptions(roundSize: 7, mc: false), rng: mulberry32(seed: 1), now: T0,
            recheck: true)
        let missed = s.queue[0].cardId
        var progress: ProgressMap = [:]
        let rng = mulberry32(seed: 4)
        var t = T0
        var first = true
        while !s.queue.contains(where: { LearnEngine.isRecheckQuestion($0.qid) }) {
            precondition(t < T0 + 5_000_000)
            t += 1000
            guard let q = s.queue.first else {
                s = LearnEngine.nextRound(s, cards: cards, rng: rng, now: t)
                continue
            }
            let ok = !(first && q.cardId == missed)
            first = false
            progress[q.cardId] = Mastery.applyAnswer(progress[q.cardId], correct: ok, at: t)
            s = LearnEngine.answer(s, correct: ok, now: t)
        }
        return (s, progress, t)
    }

    // MARK: - Engine

    @Test func rechecksSwitchedOffGoAtOnce() {
        let cards = Self.makeCards(70)
        let (s, _, t) = Self.untilARecheckIsQueued(cards)
        let off = LearnEngine.setRecheck(s, on: false, now: t + 1)
        #expect(off.recheck == nil)
        #expect(!off.queue.contains { LearnEngine.isRecheckQuestion($0.qid) })
        #expect(off.queue.count == s.queue.count - s.queue.count { LearnEngine.isRecheckQuestion($0.qid) })
        // Stored without the key, like a session that never had them.
        #expect((try? JSONValue(encoding: off))?["recheck"] == nil)
    }

    @Test func rechecksSwitchedOnCountFromNowOn() {
        let large = LearnEngine.createLearn(Self.makeCards(70), answerWith: .term, learn: .default, now: Self.T0)
        #expect(LearnEngine.setRecheck(large, on: true, now: Self.T0).recheck == LearnRecheck())
        // Only sessions with more than 60 cards have rechecks.
        let small = LearnEngine.createLearn(Self.makeCards(60), answerWith: .term, learn: .default, now: Self.T0)
        #expect(LearnEngine.setRecheck(small, on: true, now: Self.T0).recheck == nil)
        // Already on: the cards waiting stay.
        let (s, _, t) = Self.untilARecheckIsQueued(Self.makeCards(70))
        #expect(LearnEngine.setRecheck(s, on: true, now: t) == s)
    }

    @Test func repetitionQuestionsSwitchedOffGoAtOnce() {
        let cards = Self.makeCards(9)
        let progress = Self.mastered(["c1", "c2", "c3", "c4"])
        let s = LearnEngine.createLearn(
            cards, answerWith: .term, learn: LearnOptions(roundSize: 9), progress: progress, rng: mulberry32(seed: 3),
            now: Self.T0, review: true)
        #expect(s.queue.contains { LearnEngine.isReviewQuestion($0.qid) })
        let off = LearnEngine.setReview(s, on: false, progress: progress, now: Self.T0 + 1)
        #expect(off.review == nil)
        #expect(!off.queue.contains { LearnEngine.isReviewQuestion($0.qid) })
        #expect(LearnEngine.reviewStats(off) == nil)
        // They still count as mastered before the session.
        #expect(off.initiallyMastered == s.initiallyMastered)
    }

    @Test func repetitionQuestionsSwitchedOnAskTheMasteredCardsMostOverdueFirst() {
        let cards = Self.makeCards(9)
        // Answered longest ago: c3, then c2, then c1 (whatever the shuffled order).
        var progress = Self.mastered(["c1", "c2", "c3"])
        progress["c3"]?.lastAnsweredAt = Self.T0 - 900_000
        progress["c1"]?.lastAnsweredAt = Self.T0 - 1
        for seed in 1...6 {
            let s = LearnEngine.createLearn(
                cards, answerWith: .term, learn: .default, progress: progress, rng: mulberry32(seed: seed), now: Self.T0)
            #expect(LearnEngine.setReview(s, on: true, progress: progress, now: Self.T0 + 1).review?.due == ["c3", "c2", "c1"])
        }
        let s = LearnEngine.createLearn(
            cards, answerWith: .term, learn: .default, progress: progress, rng: mulberry32(seed: 3), now: Self.T0)
        let on = LearnEngine.setReview(s, on: true, progress: progress, now: Self.T0 + 1)
        #expect(LearnEngine.reviewStats(on) == LearnEngine.ReviewStats(asked: 0, kept: 0, left: 3))
        #expect(!LearnEngine.isFinished(on))
    }

    @Test func aSessionWithNothingLeftButRechecksEndsWhenTheyAreSwitchedOff() {
        let cards = Self.makeCards(62)
        let (queued, progress, t) = Self.untilARecheckIsQueued(cards)
        // Every other card mastered meanwhile (in Schreiben): only the recheck is left.
        var all = progress
        for card in cards where Mastery.cardStatus(all[card.id]) != .mastered {
            all[card.id] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: t)
        }
        let s = LearnEngine.syncProgress(queued, progress: all, now: t + 1)
        #expect(s.queue.allSatisfy { LearnEngine.isRecheckQuestion($0.qid) } && !s.queue.isEmpty)
        #expect(!LearnEngine.isFinished(s))
        let off = LearnEngine.setRecheck(s, on: false, now: t + 2)
        #expect(LearnEngine.isFinished(off))
        #expect(off.finishedAt == t + 2)
    }

    @Test func aFinishedSessionIsLeftAsItIs() {
        let cards = Self.makeCards(3)
        let s = LearnEngine.createLearn(
            cards, answerWith: .term, learn: .default, progress: Self.mastered(["c1", "c2", "c3"]), now: Self.T0)
        #expect(LearnEngine.isFinished(s))
        #expect(LearnEngine.setReview(s, on: true, now: Self.T0 + 1) == s)
    }

    // MARK: - Screen

    @Test func aStoredSessionSwitchedKeepsItsOpenMiss() throws {
        let cards = Self.makeCards(70)
        let (session, _, t) = Self.untilARecheckIsQueued(cards)
        let feedback = LearnFlow.PendingFeedback(
            writtenQid: "1.1:c1", cardId: "c1", ask: .term, given: "faux", dontKnow: false)
        let saved = LearnFlow.SavedLearn(state: session, feedback: feedback)
        let off = try #require(saved.switching(recheck: false, progress: [:], now: t))
        #expect(off.state.recheck == nil)
        #expect(off.feedback == saved.feedback)
        // Nothing to change: nil (nothing is written).
        #expect(off.switching(recheck: false, progress: [:], now: t) == nil)
        #expect(saved.switching(progress: [:], now: t) == nil)
    }

    @Test func switchingInTheOptionsAppliesWithoutARestart() {
        let cards = Self.makeCards(6)
        let progress = Self.mastered(["c1", "c2"])
        let (start, _) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, rng: mulberry32(seed: 2), now: Self.T0)
        let env = LearnFlow.Env(rng: mulberry32(seed: 2), now: Self.T0 + 1000, progress: progress)
        var (s, _) = LearnFlow.reduce(start, .overlayPresented(.options), env: env)
        let effects: [LearnFlow.Effect]
        (s, effects) = LearnFlow.reduce(s, .reviewChanged(true), env: env)
        // At once, also while the options are open (so the stored session is never behind).
        #expect(s.session?.review != nil)
        #expect(effects.contains { if case .saveLearn = $0 { true } else { false } })
        (s, _) = LearnFlow.reduce(s, .overlayDismissed, env: env)
        #expect(s.prompt == nil)
        #expect(s.session?.review != nil)
    }

    @Test func theOtherOptionsApplyAtOnceToo() {
        let cards = Self.makeCards(70)
        let (start, _) = LearnFlow.start(
            set: Self.set(cards), progress: [:], options: .default, recheck: true, rng: mulberry32(seed: 2),
            now: Self.T0)
        #expect(start.session?.recheck != nil)
        let env = LearnFlow.Env(rng: mulberry32(seed: 2), now: Self.T0 + 1000)
        var (s, _) = LearnFlow.reduce(start, .overlayPresented(.options), env: env)
        var options = s.options
        options.learn.roundSize = 12
        (s, _) = LearnFlow.reduce(s, .optionsChanged(options), env: env)
        (s, _) = LearnFlow.reduce(s, .recheckChanged(false), env: env)
        (s, _) = LearnFlow.reduce(s, .overlayDismissed, env: env)
        #expect(s.session?.recheck == nil)
        #expect(s.session?.learn.roundSize == 12)
        #expect(s.prompt == nil)
    }

    @Test func aRecheckOnScreenMakesWayWhenTheyAreSwitchedOff() throws {
        let cards = Self.makeCards(70)
        let (session, progress, t0) = Self.untilARecheckIsQueued(cards)
        // Up to the recheck, every answer recorded as the app does.
        var stored = session
        var p = progress
        var t = t0
        while let q = stored.queue.first, !LearnEngine.isRecheckQuestion(q.qid) {
            t += 1000
            p[q.cardId] = Mastery.applyAnswer(p[q.cardId], correct: true, at: t)
            stored = LearnEngine.answer(stored, correct: true, now: t)
        }
        #expect(LearnEngine.matchesProgress(stored, progress: p))
        let (start, _) = LearnFlow.start(
            set: Self.set(cards), progress: p, options: .default, saved: LearnFlow.SavedLearn(state: stored),
            recheck: true, rng: mulberry32(seed: 2), now: t + 1000)
        let shown = try #require(start.question)
        try #require(shown.isRecheck)
        let env = LearnFlow.Env(rng: mulberry32(seed: 2), now: t + 2000, progress: p)
        let (after, effects) = LearnFlow.reduce(start, .recheckChanged(false), env: env)
        #expect(after.session?.recheck == nil)
        #expect(after.question?.isRecheck != true)
        #expect(after.question?.qid != shown.qid || after.phase != start.phase)
        #expect(effects.contains { if case .saveLearn = $0 { true } else { false } })
    }

    @Test func aResumedSessionFollowsTheRecheckSwitch() {
        let cards = Self.makeCards(70)
        let (session, progress, t) = Self.untilARecheckIsQueued(cards)
        let (resumed, effects) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, saved: LearnFlow.SavedLearn(state: session),
            recheck: false, rng: mulberry32(seed: 2), now: t + 1000)
        #expect(resumed.session?.recheck == nil)
        #expect(!(resumed.session?.queue.contains { LearnEngine.isRecheckQuestion($0.qid) } ?? true))
        #expect(resumed.session?.answered == session.answered)
        #expect(effects.contains { if case .saveLearn = $0 { true } else { false } })
    }

    @Test func aResumedSessionFinishedByTheSwitchIsStoredAsFinished() throws {
        // Only a recheck was left: without the Nachkontrolle the session is done, and stored so,
        // or «Weiterlernen» would keep offering it.
        let cards = Self.makeCards(62)
        let (queued, progress, t) = Self.untilARecheckIsQueued(cards)
        var all = progress
        for card in cards where Mastery.cardStatus(all[card.id]) != .mastered {
            all[card.id] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: t)
        }
        let s = LearnEngine.syncProgress(queued, progress: all, now: t + 1)
        try #require(!LearnEngine.isFinished(s))
        let (screen, effects) = LearnFlow.start(
            set: Self.set(cards), progress: all, options: .default, saved: LearnFlow.SavedLearn(state: s),
            recheck: false, rng: mulberry32(seed: 2), now: t + 1000)
        #expect(screen.phase == .allMastered)
        let saved = effects.compactMap { effect -> LearnState? in
            if case let .saveLearn(state, _) = effect { state } else { nil }
        }
        #expect(saved.count == 1)
        #expect(saved.first?.finishedAt != nil)
        #expect(saved.first?.answered == s.answered)
    }

    @Test func aResumedSessionKeepsItsRepetitionQuestions() {
        // Started for them («Gemeisterte wiederholen»): the switch being off does not end them.
        let cards = Self.makeCards(5)
        let progress = Self.mastered(cards.map(\.id))
        let (first, _) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, review: true, rng: mulberry32(seed: 2),
            now: Self.T0)
        let session = first.session!
        #expect(session.review != nil)
        let (resumed, _) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, saved: LearnFlow.SavedLearn(state: session),
            review: false, rng: mulberry32(seed: 2), now: Self.T0 + 1000)
        #expect(resumed.session?.review != nil)
        #expect(resumed.question?.isReview == true)
    }

    @Test func switchingRechecksDoesNotEndRepetitionQuestionsStartedForThem() {
        let cards = Self.makeCards(5)
        let progress = Self.mastered(cards.map(\.id))
        let (first, _) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, review: true, rng: mulberry32(seed: 2),
            now: Self.T0)
        let (resumed, _) = LearnFlow.start(
            set: Self.set(cards), progress: progress, options: .default, saved: LearnFlow.SavedLearn(state: first.session!),
            review: false, recheck: true, rng: mulberry32(seed: 2), now: Self.T0 + 1000)
        let env = LearnFlow.Env(rng: mulberry32(seed: 2), now: Self.T0 + 2000, progress: progress)
        var (s, _) = LearnFlow.reduce(resumed, .overlayPresented(.options), env: env)
        (s, _) = LearnFlow.reduce(s, .recheckChanged(false), env: env)
        (s, _) = LearnFlow.reduce(s, .overlayDismissed, env: env)
        #expect(s.session?.review != nil)
    }
}
