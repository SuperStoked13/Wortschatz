import Foundation
import Testing
import WortschatzCore

/// Whole Learn sessions played through the screen logic (`LearnFlow`), as the app does: every
/// answer is recorded in the progress the next step reads, with random right and wrong answers,
/// "Weiss ich nicht?", "Ich hatte recht" and checkpoints. They check the promise behind the
/// options: a card answered right twice in a row is mastered and not asked again, unless a
/// repetition question (Wiederholungsfragen) or a recheck (Nachkontrolle) asks it once more, and
/// only while that option is on (Anthony 24.11.2026: «words I did correctly a second time come
/// again»).
@Suite("Learn: whole sessions")
struct LearnSessionSimulationTests {
    static let T0: Double = 1_760_000_000_000

    static func makeCards(_ n: Int) -> [Card] {
        (1...n).map { i in Card(id: "c\(i)", term: "terme \(i)", definition: "Begriff \(i)") }
    }

    static func set(_ cards: [Card]) -> VocabSet {
        VocabSet(id: "set1", title: "Wörter", termLang: .fr, defLang: .de, cards: cards, createdAt: T0)
    }

    /// One question as it was shown, with the progress of its card at that moment.
    struct Asked {
        var question: LearnFlow.QuestionInfo
        var streak: Int
        /// The card was answered wrong earlier in the session (and not corrected).
        var missedBefore: Bool
    }

    struct Outcome {
        var asked: [Asked]
        var progress: ProgressMap
        var state: LearnFlow.State
    }

    /// Plays a session from `LearnFlow.start` to its end. `rightChance` in percent; a wrong
    /// written answer is now and then corrected with "Ich hatte recht".
    static func play(
        cards: [Card], progress start: ProgressMap = [:], options: StudyOptions = .default, review: Bool = false,
        recheck: Bool = false, seed: Int, rightChance: Int = 70
    ) -> Outcome {
        var progress = start
        let pick = mulberry32(seed: seed &+ 1000)
        func roll(_ n: Int) -> Int { Int(pick() * Double(n)) }
        var now = T0
        var (state, effects) = LearnFlow.start(
            set: set(cards), progress: progress, options: options, review: review, recheck: recheck,
            rng: mulberry32(seed: seed), now: now)
        var asked: [Asked] = []
        var misses: [String: Int] = [:]

        func apply(_ effects: [LearnFlow.Effect]) {
            for effect in effects {
                switch effect {
                case let .recordAnswer(cardId, correct, at):
                    progress[cardId] = Mastery.applyAnswer(progress[cardId], correct: correct, at: at)
                    if !correct { misses[cardId, default: 0] += 1 }
                case let .overrideLastAnswer(cardId):
                    progress[cardId] = Mastery.applyOverride(progress[cardId])
                    misses[cardId, default: 1] -= 1
                case let .resetProgress(ids):
                    if let ids { for id in ids { progress[id] = nil } } else { progress = [:] }
                default:
                    break
                }
            }
        }
        func send(_ event: LearnFlow.Event) {
            // Past every input lock and auto-advance delay.
            now += 5000
            let env = LearnFlow.Env(rng: mulberry32(seed: seed &+ Int(now.truncatingRemainder(dividingBy: 997))), now: now, progress: progress)
            (state, effects) = LearnFlow.reduce(state, event, env: env)
            apply(effects)
        }
        apply(effects)

        var steps = 0
        loop: while true {
            steps += 1
            precondition(steps < 20_000, "the session did not end")
            switch state.phase {
            case let .question(type):
                let q = state.question!
                asked.append(
                    Asked(question: q, streak: progress[q.cardId]?.streak ?? 0, missedBefore: (misses[q.cardId] ?? 0) > 0))
                let right = roll(100) < rightChance
                if type == .mc {
                    let correct = q.choices.firstIndex { $0.cardId == q.cardId }!
                    if right {
                        send(.choose(correct))
                    } else if roll(4) == 0 {
                        send(.dontKnow)
                    } else {
                        send(.choose((correct + 1) % q.choices.count))
                    }
                } else if right {
                    send(.submit(q.expected))
                } else if roll(5) == 0 {
                    send(.dontKnow)
                } else {
                    send(.submit("xyz"))
                    // "Ich hatte recht" now and then.
                    if roll(6) == 0 { send(.override) }
                }
                // The store echoes the answer back to the screen.
                send(.progressChanged)
            case .feedback, .checkpoint:
                send(.proceed)
            case .copy:
                send(.submit(state.question!.expected))
            case .finished, .allMastered, .empty:
                break loop
            }
        }
        return Outcome(asked: asked, progress: progress, state: state)
    }

    /// Without repetition questions and rechecks no card is asked once it was answered right
    /// twice in a row (in this session or before it).
    @Test(arguments: [5, 12, 40, 75])
    func aCardRightTwiceInARowIsNotAskedAgain(cardCount: Int) {
        let cards = Self.makeCards(cardCount)
        for seed in 1...6 {
            for (mc, written) in [(true, true), (false, true), (true, false)] {
                var options = StudyOptions.default
                options.learn.mc = mc
                options.learn.written = written
                options.learn.roundSize = [7, 15, 30][seed % 3]
                let run = Self.play(cards: cards, options: options, seed: seed, rightChance: [50, 70, 90][seed % 3])
                let again = run.asked.filter { $0.streak >= Mastery.MASTERY_STREAK }
                #expect(
                    again.isEmpty,
                    "seed \(seed), \(cardCount) cards, mc \(mc), written \(written): asked again after two right answers: \(again.map(\.question.qid))"
                )
                #expect(run.state.phase == .finished)
                #expect(cards.allSatisfy { Mastery.cardStatus(run.progress[$0.id]) == .mastered })
                #expect(!run.asked.contains { $0.question.isReview || $0.question.isRecheck })
            }
        }
    }

    /// Cards mastered before the session (and those answered right once before) need what is
    /// left: none / one more right answer.
    @Test func progressFromBeforeTheSessionCounts() {
        let cards = Self.makeCards(20)
        var start: ProgressMap = [:]
        for card in cards.prefix(6) {
            start[card.id] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: Self.T0 - 9000)
        }
        for card in cards[6..<12] {
            start[card.id] = CardProgress(correct: 1, streak: 1, lastResult: .correct, lastAnsweredAt: Self.T0 - 9000)
        }
        for seed in 1...10 {
            let run = Self.play(cards: cards, progress: start, seed: seed, rightChance: 100)
            let asked = Dictionary(grouping: run.asked, by: \.question.cardId).mapValues(\.count)
            for card in cards.prefix(6) { #expect(asked[card.id] == nil, "mastered \(card.id) asked") }
            for card in cards[6..<12] { #expect(asked[card.id] == 1, "\(card.id) asked \(asked[card.id] ?? 0)×") }
            for card in cards[12...] { #expect(asked[card.id] == 2, "\(card.id) asked \(asked[card.id] ?? 0)×") }
        }
    }

    /// With the options on, a mastered card comes back only as what they promise: a recheck of
    /// a card missed in this session, a repetition question of a card mastered before it.
    @Test func withTheOptionsOnACardComesBackOnlyAsTheyPromise() {
        let cards = Self.makeCards(75)
        var start: ProgressMap = [:]
        for card in cards.prefix(10) {
            start[card.id] = CardProgress(correct: 2, streak: 2, streakBefore: 1, lastResult: .correct, lastAnsweredAt: Self.T0 - 9000)
        }
        let before = Set(cards.prefix(10).map(\.id))
        for seed in 1...6 {
            let run = Self.play(cards: cards, progress: start, review: true, recheck: true, seed: seed)
            for a in run.asked {
                let q = a.question
                if a.streak >= Mastery.MASTERY_STREAK {
                    if q.isReview {
                        #expect(before.contains(q.cardId), "seed \(seed): repetition question of \(q.cardId)")
                    } else {
                        #expect(q.isRecheck, "seed \(seed): \(q.qid) asked again after two right answers")
                        #expect(a.missedBefore, "seed \(seed): recheck of \(q.cardId), never missed")
                    }
                }
            }
            #expect(run.asked.contains { $0.question.isRecheck }, "seed \(seed): no recheck at all")
            #expect(run.state.phase == .finished)
        }
    }
}
