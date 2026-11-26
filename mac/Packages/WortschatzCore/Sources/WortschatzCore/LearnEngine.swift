import Foundation

// Port of src/core/learn.js: the Learn-mode ("Lernen") engine with Quizlet Learn semantics.
//
// Every card in scope has a stage derived from its persistent streak: 0 = new or reset (asked as
// multiple choice), 1 = familiar (asked written), 2 = mastered (not asked any more). A correct
// answer moves the card up one stage, a wrong one sends it back to stage 0.
//
// Multiple choice only once (since 24.11.2026): a card is asked as multiple choice only until it
// was answered right once (`state.solved`, from the progress: any right answer ever). From then
// on it is asked written, at stage 0 too: a wrong written answer resets the stage but stays
// written; only a wrong multiple-choice answer brings multiple choice again.
//
// Spacing (Abstand, since 1.4): a card comes back only after at least MIN_GAP (10) other
// questions – fewer only when fewer cards are left – and at the latest after about MAX_WAIT (15);
// in between, the longer it waits the likelier it is picked, mixed with new cards (at most
// MAX_REPEATS questions in a row of cards asked before while there are new ones, no new card while
// MAX_LEARNING cards are being learned unless twice as many repeats came in a row). So a new card
// is asked, ~10–15 questions later asked again, and gone once both answers were right. A wrong
// answer sends it back to stage 0; it too comes back only after the gap (no retry at the end of
// the round any more). New cards are taken stage-1 cards first, then stage-0 cards, in `order`.
//
// A round is the next `roundSize` questions (after it the checkpoint shows the interim result).
// They are planned when the round starts, as if every answer were right (`planRound`); an actual
// answer adjusts the card's later questions in the round to its new stage (`followStage`).
//
// Rechecks (Nachkontrolle, opt-in via `createLearn(…, recheck: true)` or during a session via
// `setRecheck`, only for sessions with more than RECHECK_MIN_CARDS (60) cards): a card answered
// wrong in this session is asked once
// more RECHECK_GAP to RECHECK_WAIT (30–50) questions after it was mastered; wrong again, it is
// learned again. They live in `state.recheck` (`LearnRecheck`). A recheck never comes sooner than
// MIN_GAP questions after the card was mastered (since 23.11.2026); at the end of a session, when
// nothing else is left to ask, a recheck that could not come that late is dropped (`dropLateRechecks`).
//
// Every function takes a `LearnState` and returns a NEW state (value semantics, inputs are never
// changed). Like the JS, each function first repairs its input (`copyState`), so states restored
// from storage or built by hand never crash the engine. Randomness comes from an injected `RNG`
// that is consumed in exactly the order of the JS, so seeded runs replay the web app's sessions
// bit for bit (checked against Parity/gen-learn.js). Multiple-choice options are generated when a
// question is created and stored in the state, so a resumed session shows identical options.
//
// Known differences to the JS, all limited to inputs the web app never produces:
// - Ids are compared with Swift `String` equality (Unicode canonical equivalence); JS compares
//   UTF-16 code units. Card ids are ASCII `uid()`s, so this never matters in practice. Option
//   texts are compared exactly (as JS does), via `Grading.JSText`.
// - Counts are `Int`. `copyState(_: JSONValue)` rounds fractional counts up (which keeps every
//   comparison with 0 and 1 the engine makes) and caps them at 2^53. `clock`, `lastAt` and
//   `repeats` beyond 2^53 count as missing (JS keeps any integer).
// - Cards are typed: a side that is not a string in JS (a number, `null`) is a `String` here, so
//   callers convert raw JSON cards first (`Card(json:)` turns numbers into text).

/// Question type: multiple choice (stage 0) or written (stage 1).
public enum QuestionType: String, Codable, Sendable, CaseIterable, Hashable {
    case mc, written
}

/// A multiple-choice option: the answer text of card `cardId`.
public struct Choice: Codable, Sendable, Equatable, Hashable {
    public var cardId: String
    public var text: String

    public init(cardId: String, text: String) {
        self.cardId = cardId
        self.text = text
    }
}

/// A queued question as stored in the state (`state.queue[]`). `choices` is present only for
/// `.mc`; `retryChoices` (options for when the question has to be asked at stage 0 after all) only
/// when multiple choice is possible. Absent keys are omitted, like JS.
public struct LearnQueueQuestion: Codable, Sendable, Equatable, Hashable {
    /// "<round>.<kind>:<cardId>", kind 1 = learning, 3 = repetition question, 4 = recheck; a
    /// card's n-th question of the same round (n ≥ 2) is "<round>.<kind>.<n>:<cardId>". (".2:" was
    /// the retry after a miss before 1.4.)
    public var qid: String
    public var cardId: String
    public var type: QuestionType
    public var ask: AskSide
    public var choices: [Choice]?
    public var retryChoices: [Choice]?

    public init(
        qid: String, cardId: String, type: QuestionType, ask: AskSide, choices: [Choice]? = nil,
        retryChoices: [Choice]? = nil
    ) {
        self.qid = qid
        self.cardId = cardId
        self.type = type
        self.ask = ask
        self.choices = choices
        self.retryChoices = retryChoices
    }
}

/// An answer of the current round (`state.roundLog[]`). `qid` may be absent in old states.
public struct LearnRoundLogEntry: Codable, Sendable, Equatable, Hashable {
    public var qid: String?
    public var cardId: String
    public var type: QuestionType
    public var ask: AskSide
    public var correct: Bool
    public var stageAfter: Int

    public init(qid: String?, cardId: String, type: QuestionType, ask: AskSide, correct: Bool, stageAfter: Int) {
        self.qid = qid
        self.cardId = cardId
        self.type = type
        self.ask = ask
        self.correct = correct
        self.stageAfter = stageAfter
    }
}

/// A closed round (`state.rounds[]`).
public struct LearnRoundRecord: Codable, Sendable, Equatable, Hashable {
    public var round: Int
    public var answered: Int
    public var correct: Int
    /// The cards answered in the round, in the order of their first answer.
    public var cardIds: [String]

    public init(round: Int, answered: Int, correct: Int, cardIds: [String]) {
        self.round = round
        self.answered = answered
        self.correct = correct
        self.cardIds = cardIds
    }
}

/// The last answer (`state.last`), for "Ich hatte recht".
public struct LearnLastAnswer: Codable, Sendable, Equatable, Hashable {
    public var qid: String
    public var cardId: String
    public var type: QuestionType
    public var ask: AskSide
    public var correct: Bool
    public var stageBefore: Int

    public init(qid: String, cardId: String, type: QuestionType, ask: AskSide, correct: Bool, stageBefore: Int) {
        self.qid = qid
        self.cardId = cardId
        self.type = type
        self.ask = ask
        self.correct = correct
        self.stageBefore = stageBefore
    }
}

/// `state.learn`: the normalised Learn options the session runs with (`normalizeLearn`: no
/// `retype`, which is a UI option).
public struct LearnSessionOptions: Codable, Sendable, Equatable, Hashable {
    public var roundSize: Int
    public var mc: Bool
    public var written: Bool

    public init(roundSize: Int = 7, mc: Bool = true, written: Bool = true) {
        self.roundSize = roundSize
        self.mc = mc
        self.written = written
    }
}

/// `state.review`: repetition questions (Wiederholungsfragen). The cards that were mastered when
/// the session started are asked once more, mixed in among the new cards (about every third), the
/// ones answered longest ago first. A wrong answer sends a card back to stage 0, so it is learned
/// again like any other.
public struct LearnReview: Codable, Sendable, Equatable, Hashable {
    /// Mastered cards still to be asked again (not queued yet), the most overdue first.
    public var due: [String]
    /// cardId → whether its repetition question was answered right (the first answer counts).
    public var results: [String: Bool]

    public init(due: [String] = [], results: [String: Bool] = [:]) {
        self.due = due
        self.results = results
    }
}

/// `state.recheck`: rechecks (Nachkontrolle). A card answered wrong in the session waits here once
/// it is mastered, until its recheck is planned 30–50 questions later; a wrong recheck sends it
/// back to stage 0.
public struct LearnRecheck: Codable, Sendable, Equatable, Hashable {
    /// Mastered cards waiting for their recheck (not queued yet), in the order they were mastered.
    public var due: [String]

    public init(due: [String] = []) {
        self.due = due
    }
}

/// The JSON-serialisable Learn session (`learn:<setId>` in the web app), key for key. `last`
/// and `finishedAt` are encoded as explicit `null` when absent.
///
/// Stages: 0 = new/reset (multiple choice), 1 = familiar (written), 2 = mastered.
/// Decoding uses the synthesized (strict) decoder; for stored or imported JSON use
/// `LearnEngine.copyState(_:)` (or `init(json:)`), which repairs states like `copyState` in
/// learn.js.
public struct LearnState: Codable, Sendable, Equatable, Hashable {
    /// Schema version (always 1).
    public var v: Int
    public var subset: StudySubset
    public var answerWith: AnswerWith
    public var learn: LearnSessionOptions
    /// Card ids in scope, shuffled once at creation.
    public var order: [String]
    /// cardId → stage 0…2.
    public var stage: [String: Int]
    /// Cards mastered before the session started.
    public var initiallyMastered: [String]
    /// cardId → true once answered (ever).
    public var seen: [String: Bool]
    /// cardId → true once answered right (ever): no multiple choice any more. Every card past
    /// stage 0 is in it.
    public var solved: [String: Bool]
    public var round: Int
    public var queue: [LearnQueueQuestion]
    /// Answers given in the session (the number of the next question); never goes back.
    public var clock: Int
    /// cardId → `clock` value of its last answer in the session.
    public var lastAt: [String: Int]
    /// How many of the last answers in a row were to cards asked before in the session.
    public var repeats: Int
    public var roundLog: [LearnRoundLogEntry]
    public var rounds: [LearnRoundRecord]
    public var answered: Int
    public var correct: Int
    public var misses: [String: Int]
    public var last: LearnLastAnswer?
    /// Epoch ms.
    public var startedAt: Double
    public var updatedAt: Double
    public var finishedAt: Double?
    /// Active study time (gaps > 5 min are not counted).
    public var elapsedMs: Double
    /// The repetition questions; nil without them. Encoded only when present, so states without
    /// them stay key for key those of the web app.
    public var review: LearnReview?
    /// The rechecks; nil without them (encoded only when present).
    public var recheck: LearnRecheck?

    public init(
        v: Int = 1, subset: StudySubset, answerWith: AnswerWith, learn: LearnSessionOptions, order: [String],
        stage: [String: Int], initiallyMastered: [String], seen: [String: Bool], solved: [String: Bool] = [:],
        round: Int, queue: [LearnQueueQuestion], clock: Int = 0, lastAt: [String: Int] = [:], repeats: Int = 0,
        roundLog: [LearnRoundLogEntry], rounds: [LearnRoundRecord], answered: Int, correct: Int,
        misses: [String: Int], last: LearnLastAnswer?, startedAt: Double, updatedAt: Double, finishedAt: Double?,
        elapsedMs: Double, review: LearnReview? = nil, recheck: LearnRecheck? = nil
    ) {
        self.v = v
        self.subset = subset
        self.answerWith = answerWith
        self.learn = learn
        self.order = order
        self.stage = stage
        self.initiallyMastered = initiallyMastered
        self.seen = seen
        self.solved = solved
        self.round = round
        self.queue = queue
        self.clock = clock
        self.lastAt = lastAt
        self.repeats = repeats
        self.roundLog = roundLog
        self.rounds = rounds
        self.answered = answered
        self.correct = correct
        self.misses = misses
        self.last = last
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.elapsedMs = elapsedMs
        self.review = review
        self.recheck = recheck
    }

    /// A repaired state from any JSON value (`LearnEngine.copyState(json)`): never fails. Extra
    /// keys (like the `feedback` record the web app stores next to the state) are ignored.
    public init(json: JSONValue) {
        self = LearnEngine.copyState(json)
    }

    enum CodingKeys: String, CodingKey {
        case v, subset, answerWith, learn, order, stage, initiallyMastered, seen, solved, round, queue, clock, lastAt,
            repeats, roundLog, rounds, answered, correct, misses, last, startedAt, updatedAt, finishedAt, elapsedMs,
            review, recheck
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(subset, forKey: .subset)
        try c.encode(answerWith, forKey: .answerWith)
        try c.encode(learn, forKey: .learn)
        try c.encode(order, forKey: .order)
        try c.encode(stage, forKey: .stage)
        try c.encode(initiallyMastered, forKey: .initiallyMastered)
        try c.encode(seen, forKey: .seen)
        try c.encode(solved, forKey: .solved)
        try c.encode(round, forKey: .round)
        try c.encode(queue, forKey: .queue)
        try c.encode(clock, forKey: .clock)
        try c.encode(lastAt, forKey: .lastAt)
        try c.encode(repeats, forKey: .repeats)
        try c.encode(roundLog, forKey: .roundLog)
        try c.encode(rounds, forKey: .rounds)
        try c.encode(answered, forKey: .answered)
        try c.encode(correct, forKey: .correct)
        try c.encode(misses, forKey: .misses)
        try c.encodeNullable(last, forKey: .last)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeNullable(finishedAt, forKey: .finishedAt)
        try c.encode(elapsedMs, forKey: .elapsedMs)
        try c.encodeIfPresent(review, forKey: .review)
        try c.encodeIfPresent(recheck, forKey: .recheck)
    }
}

/// Port of src/core/learn.js: the Learn-mode ("Lernen") engine with Quizlet Learn semantics.
/// Every function takes a state and returns a NEW state; inputs are never mutated.
/// Multiple-choice options are generated when a question is created and stored in the state.
public enum LearnEngine {
    /// `DEFAULT_LEARN` (= `DEFAULT_STUDY_OPTIONS.learn`).
    public static let DEFAULT_LEARN = LearnOptions.default
    /// Number of options of a multiple-choice question.
    public static let MAX_CHOICES = 4
    /// Pauses between two actions longer than this are not counted as study time (`IDLE_GAP_MS`).
    public static let idleGapMs: Double = 5 * 60 * 1000
    /// The stage of a mastered card (`MASTERY_STREAK`).
    public static let masteredStage = Mastery.MASTERY_STREAK
    /// Spacing: other questions at least between two questions of a card (fewer only when fewer
    /// cards are left) …
    public static let MIN_GAP = 10
    /// … and after how many a waiting card is asked for sure.
    public static let MAX_WAIT = 15
    /// The same for rechecks, counted from the answer that mastered the card.
    public static let RECHECK_GAP = 30
    public static let RECHECK_WAIT = 50
    /// At most this many questions in a row of cards asked before while there are new cards.
    public static let MAX_REPEATS = 3
    /// No new card while this many cards are being learned (unless 2 × MAX_REPEATS repeats came
    /// in a row).
    public static let MAX_LEARNING = 10
    /// Rechecks only in sessions with more cards than this.
    public static let RECHECK_MIN_CARDS = 60

    /// The public view of a question (`current(state)`): `choices` only for `.mc`.
    public struct Question: Codable, Sendable, Equatable, Hashable {
        public var qid: String
        public var cardId: String
        public var type: QuestionType
        public var ask: AskSide
        public var choices: [Choice]?

        public init(qid: String, cardId: String, type: QuestionType, ask: AskSide, choices: [Choice]? = nil) {
            self.qid = qid
            self.cardId = cardId
            self.type = type
            self.ask = ask
            self.choices = choices
        }

        /// A repetition question (Wiederholungsfrage) of a card mastered before the session.
        public var isReview: Bool { LearnEngine.isReviewQuestion(qid) }
        /// A recheck (Nachkontrolle) of a card missed and then mastered in the session.
        public var isRecheck: Bool { LearnEngine.isRecheckQuestion(qid) }
    }

    /// `counts(state)` (progress capsule: Neu · Am Lernen · Gemeistert).
    public struct Counts: Codable, Sendable, Equatable, Hashable {
        public var fresh: Int
        public var learning: Int
        public var mastered: Int
        public var total: Int
        /// mastered / total (0…1).
        public var progress: Double

        public init(fresh: Int, learning: Int, mastered: Int, total: Int, progress: Double) {
            self.fresh = fresh
            self.learning = learning
            self.mastered = mastered
            self.total = total
            self.progress = progress
        }
    }

    /// `checkpoint(state).counts` (no `progress` key).
    public struct CheckpointCounts: Codable, Sendable, Equatable, Hashable {
        public var fresh: Int
        public var learning: Int
        public var mastered: Int
        public var total: Int

        public init(fresh: Int, learning: Int, mastered: Int, total: Int) {
            self.fresh = fresh
            self.learning = learning
            self.mastered = mastered
            self.total = total
        }
    }

    /// A card of the round in `checkpoint(state).items`.
    public struct CheckpointItem: Codable, Sendable, Equatable, Hashable {
        public var cardId: String
        /// Current stage 0…2.
        public var stage: Int
        /// The round's answers to this card, in order.
        public var results: [Bool]

        public init(cardId: String, stage: Int, results: [Bool]) {
            self.cardId = cardId
            self.stage = stage
            self.results = results
        }
    }

    /// `checkpoint(state)`: summary of the current (just finished) round.
    public struct Checkpoint: Codable, Sendable, Equatable, Hashable {
        public var round: Int
        public var answered: Int
        public var correct: Int
        public var items: [CheckpointItem]
        public var counts: CheckpointCounts

        public init(round: Int, answered: Int, correct: Int, items: [CheckpointItem], counts: CheckpointCounts) {
            self.round = round
            self.answered = answered
            self.correct = correct
            self.items = items
            self.counts = counts
        }
    }

    /// `finalStats(state)`.
    public struct FinalStats: Codable, Sendable, Equatable, Hashable {
        public var total: Int
        public var mastered: Int
        /// Cards that were mastered before the session started (and stayed so).
        public var alreadyMastered: Int
        public var rounds: Int
        public var answered: Int
        /// correct / answered (0…1).
        public var accuracy: Double
        public var elapsedMs: Double
        /// Up to 10 cards with the most misses ("Am häufigsten falsch").
        public var hardest: [MissedCard]

        public init(
            total: Int, mastered: Int, alreadyMastered: Int, rounds: Int, answered: Int, accuracy: Double,
            elapsedMs: Double, hardest: [MissedCard]
        ) {
            self.total = total
            self.mastered = mastered
            self.alreadyMastered = alreadyMastered
            self.rounds = rounds
            self.answered = answered
            self.accuracy = accuracy
            self.elapsedMs = elapsedMs
            self.hardest = hardest
        }
    }

    /// `reviewStats(state)`: the repetition questions of a session that has them.
    public struct ReviewStats: Codable, Sendable, Equatable, Hashable {
        /// Mastered cards asked again so far.
        public var asked: Int
        /// How many of them were still known.
        public var kept: Int
        /// Mastered cards still to be asked again in this session.
        public var left: Int

        public init(asked: Int, kept: Int, left: Int) {
            self.asked = asked
            self.kept = kept
            self.left = left
        }
    }

    // MARK: - Multiple-choice options

    /// Up to `n` options for `card` asked on `ask`: the correct answer at a uniformly random
    /// position plus distinct wrong answers of other (non-synonym) cards, the most alike ones
    /// (`rankedDistractors`) in random order. [] when the card has no id or no answer text; a
    /// non-positive `n` means `MAX_CHOICES`.
    public static func buildChoices(
        _ cards: [Card], card: Card, ask: AskSide, rng: RNG = systemRNG(), n: Int = MAX_CHOICES
    ) -> [Choice] {
        buildChoices(ChoicePool(cardList(cards)), card: card, ask: ask, rng: rng, n: n)
    }

    /// `buildChoices` from a pool shared by the questions of one round (`ChoicePool`).
    private static func buildChoices(
        _ pool: ChoicePool, card: Card, ask: AskSide, rng: RNG, n: Int = MAX_CHOICES
    ) -> [Choice] {
        guard !card.id.isEmpty else { return [] }
        let correctText = JSCompat.trim(Synonyms.answerSide(card, ask: ask))
        if TextNormalizer.normalizeBasic(correctText).isEmpty { return [] }
        let size = n >= 1 ? n : MAX_CHOICES
        let correct = Choice(cardId: card.id, text: correctText)
        if size == 1 { return [correct] }

        let ranked = rankedDistractors(pool, card, ask, rng)
        // The most alike, in random order; the correct option's position is uniform over all slots.
        var choices = JSRandom.shuffled(Array(ranked.prefix(size - 1)), rng)
        choices.insert(correct, at: JSRandom.index(rng, choices.count + 1))
        return choices
    }

    // MARK: - Creation

    /// min(streak, 2) of the card's progress.
    public static func stageFromProgress(_ progress: CardProgress?) -> Int {
        min(Mastery.normalizeProgress(progress).streak, masteredStage)
    }

    /// Whether the card was ever answered right (then it is no longer asked as multiple choice).
    /// A streak counts too, so every card past stage 0 is solved.
    public static func solvedFromProgress(_ progress: CardProgress?) -> Bool {
        let p = Mastery.normalizeProgress(progress)
        return p.correct > 0 || p.streak > 0
    }

    /// `createLearn(cards, { answerWith, learn }, { subset, progress, rng, now, review, recheck })`.
    ///
    /// Cards without an id, repeated ids (the first one wins) and cards with an empty side are
    /// skipped; options come from every askable card of `cards`, not only from the scope. A
    /// non-finite `now` becomes 0. `retype` is a UI option and not part of the state.
    /// `review` adds repetition questions for the cards mastered already (`LearnReview`),
    /// `recheck` rechecks (`LearnRecheck`; only in sessions with more than RECHECK_MIN_CARDS cards).
    public static func createLearn(
        _ cards: [Card], answerWith: AnswerWith, learn: LearnOptions, subset: StudySubset = .all,
        progress: ProgressMap = [:], rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs(), review: Bool = false,
        recheck: Bool = false
    ) -> LearnState {
        let sub = normalizeSubset(subset)
        let selected = cardList(cards).filter { askable($0) && cardInSubset($0, sub, progress) }
        let order = JSRandom.shuffled(selected.map(\.id), rng)

        var stage: [String: Int] = [:]
        var seen: [String: Bool] = [:]
        var solved: [String: Bool] = [:]
        for id in order {
            let p = progress[id]
            stage[id] = stageFromProgress(p)
            if Mastery.cardStatus(p) != .new { seen[id] = true }
            if solvedFromProgress(p) { solved[id] = true }
        }

        let at = now.isFinite ? now : 0
        let mastered = order.filter { (stage[$0] ?? 0) >= masteredStage }
        var s = LearnState(
            v: 1, subset: sub, answerWith: answerWith, learn: normalizeLearn(learn), order: order, stage: stage,
            initiallyMastered: mastered, seen: seen, solved: solved, round: 1, queue: [], roundLog: [], rounds: [],
            answered: 0,
            correct: 0, misses: [:], last: nil, startedAt: at, updatedAt: at, finishedAt: nil, elapsedMs: 0,
            // The most overdue mastered cards are asked again first.
            review: review ? LearnReview(due: mostOverdueFirst(mastered, progress: progress)) : nil,
            recheck: recheck && order.count > RECHECK_MIN_CARDS ? LearnRecheck() : nil)
        let queue = planRound(&s, cards, rng)
        s.queue = queue
        markFinished(&s, at)
        return s
    }

    /// `createLearn` with full study options (reads `answerWith` and `learn`).
    public static func createLearn(
        _ cards: [Card], options: StudyOptions, subset: StudySubset = .all, progress: ProgressMap = [:],
        rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs(), review: Bool = false, recheck: Bool = false
    ) -> LearnState {
        createLearn(
            cards, answerWith: options.answerWith, learn: options.learn, subset: subset, progress: progress, rng: rng,
            now: now, review: review, recheck: recheck)
    }

    // MARK: - Repair

    /// `copyState` of learn.js on raw JSON: a defensive copy that repairs missing fields and
    /// drops references to cards outside `order`, so stored states never crash the engine.
    /// Accepts any JSON; a non-object gives an empty (finished) state. Extra keys are ignored.
    public static func copyState(_ json: JSONValue) -> LearnState {
        let src = json.objectValue ?? [:]

        var order: [String] = []
        var known = Set<String>()
        for v in src["order"]?.arrayValue ?? [] where v != .null && v != .string("") {
            let id = JSCompat.jsString(v)
            if known.insert(id).inserted { order.append(id) }
        }
        func ids(_ v: JSONValue?) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for x in v?.arrayValue ?? [] where x != .null {
                let id = JSCompat.jsString(x)
                if known.contains(id) && seen.insert(id).inserted { out.append(id) }
            }
            return out
        }
        func knownId(_ v: JSONValue?) -> String? {
            guard let v, v != .null else { return nil }
            let id = JSCompat.jsString(v)
            return known.contains(id) ? id : nil
        }
        func trueMap(_ v: JSONValue?) -> [String: Bool] {
            var out: [String: Bool] = [:]
            for (k, x) in v?.objectValue ?? [:] where known.contains(k) && x == .bool(true) { out[k] = true }
            return out
        }

        let srcStage = src["stage"]?.objectValue ?? [:]
        var stage: [String: Int] = [:]
        for id in order { stage[id] = clampStage(srcStage[id]) }
        // A card past stage 0 was answered right (sessions stored before 24.11.2026 have no `solved`).
        var solved = trueMap(src["solved"])
        for id in order where (stage[id] ?? 0) > 0 { solved[id] = true }
        var misses: [String: Int] = [:]
        for (k, x) in src["misses"]?.objectValue ?? [:] where known.contains(k) { misses[k] = countValue(x) }

        let round = src["round"]?.integerValue.flatMap { $0 > 0 ? $0 : nil } ?? 1
        var queue: [LearnQueueQuestion] = []
        for (i, q) in (src["queue"]?.arrayValue ?? []).enumerated() {
            guard let o = q.objectValue, let cardId = knownId(o["cardId"]) else { continue }
            let choices = normChoices(o["choices"], cardId)
            let qid = o["qid"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "\(round).q\(i):\(cardId)"
            let type: QuestionType = o["type"] == .string("mc") && choices != nil ? .mc : .written
            queue.append(
                LearnQueueQuestion(
                    qid: qid, cardId: cardId, type: type, ask: askSide(o["ask"]), choices: type == .mc ? choices : nil,
                    retryChoices: normChoices(o["retryChoices"], cardId)))
        }

        let roundLog = (src["roundLog"]?.arrayValue ?? []).compactMap { e -> LearnRoundLogEntry? in
            guard let o = e.objectValue, let cardId = knownId(o["cardId"]) else { return nil }
            return LearnRoundLogEntry(
                qid: o["qid"]?.stringValue, cardId: cardId, type: questionType(o["type"]), ask: askSide(o["ask"]),
                correct: o["correct"] == .bool(true), stageAfter: clampStage(o["stageAfter"]))
        }

        var rounds: [LearnRoundRecord] = []
        for r in (src["rounds"]?.arrayValue ?? []).compactMap(\.objectValue) {
            let answered = countValue(r["answered"])
            rounds.append(
                LearnRoundRecord(
                    round: r["round"]?.integerValue ?? rounds.count + 1, answered: answered,
                    correct: min(answered, countValue(r["correct"])), cardIds: ids(r["cardIds"])))
        }

        var last: LearnLastAnswer?
        if let l = src["last"]?.objectValue, let cardId = knownId(l["cardId"]) {
            last = LearnLastAnswer(
                qid: l["qid"]?.stringValue ?? "", cardId: cardId, type: questionType(l["type"]), ask: askSide(l["ask"]),
                correct: l["correct"] == .bool(true), stageBefore: clampStage(l["stageBefore"]))
        }

        var review: LearnReview?
        if let r = src["review"]?.objectValue {
            var results: [String: Bool] = [:]
            for (k, x) in r["results"]?.objectValue ?? [:] where known.contains(k) {
                if let ok = x.boolValue { results[k] = ok }
            }
            review = LearnReview(due: ids(r["due"]), results: results)
        }
        // Only sessions with rechecks carry the key.
        let recheck = src["recheck"]?.objectValue.map { LearnRecheck(due: ids($0["due"])) }

        let learnSrc = src["learn"]?.objectValue ?? [:]
        let roundSize = learnSrc["roundSize"]?.finiteNumber.map { Int(max(-1, min($0.rounded(.down), 1e15))) } ?? 0
        let answered = countValue(src["answered"])
        let startedAt = src["startedAt"]?.finiteNumber ?? 0
        // Sessions stored before spacing (1.4) have no clock: their answer count stands in for it
        // (`Math.floor(answered)`, not the rounded-up count).
        let clock =
            src["clock"]?.integerValue.flatMap { $0 >= 0 ? $0 : nil }
            ?? src["answered"]?.finiteNumber.map { Int(max(0, min($0, Double(maxSafeInteger))).rounded(.down)) } ?? 0
        var lastAt: [String: Int] = [:]
        for (k, x) in src["lastAt"]?.objectValue ?? [:] where known.contains(k) {
            if let at = x.integerValue, at >= 0 { lastAt[k] = at }
        }
        return LearnState(
            v: 1, subset: StudySubset(json: src["subset"] ?? .null),
            answerWith: src["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:)) ?? .term,
            learn: normalizeLearn(
                roundSize: roundSize, mc: learnSrc["mc"] != .bool(false), written: learnSrc["written"] != .bool(false)),
            order: order, stage: stage, initiallyMastered: ids(src["initiallyMastered"]), seen: trueMap(src["seen"]),
            solved: solved, round: round, queue: queue, clock: clock, lastAt: lastAt,
            repeats: src["repeats"]?.integerValue.flatMap { $0 >= 0 ? $0 : nil } ?? 0,
            roundLog: roundLog, rounds: rounds, answered: answered, correct: min(answered, countValue(src["correct"])),
            misses: misses, last: last, startedAt: startedAt, updatedAt: src["updatedAt"]?.finiteNumber ?? startedAt,
            finishedAt: src["finishedAt"]?.numberValue, elapsedMs: max(0, src["elapsedMs"]?.finiteNumber ?? 0),
            review: review, recheck: recheck)
    }

    /// `copyState` of learn.js on a typed state: `order` keeps each non-empty id once, every
    /// other reference to a card outside `order` is dropped, stages are clamped to 0…2, counts
    /// are at least 0, `round` at least 1, options normalised and timestamps finite. Every
    /// engine function applies it to its input first; it is idempotent.
    public static func copyState(_ state: LearnState) -> LearnState {
        var order: [String] = []
        var known = Set<String>()
        for id in state.order where !id.isEmpty && known.insert(id).inserted { order.append(id) }
        func ids(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { known.contains($0) && seen.insert($0).inserted }
        }

        var stage: [String: Int] = [:]
        for id in order { stage[id] = clampStage(state.stage[id] ?? 0) }
        var solved = state.solved.filter { known.contains($0.key) && $0.value }
        for id in order where (stage[id] ?? 0) > 0 { solved[id] = true }
        let round = state.round > 0 ? min(state.round, maxSafeInteger) : 1
        var queue: [LearnQueueQuestion] = []
        for (i, q) in state.queue.enumerated() where known.contains(q.cardId) {
            let choices = normChoices(q.choices, q.cardId)
            let type: QuestionType = q.type == .mc && choices != nil ? .mc : .written
            queue.append(
                LearnQueueQuestion(
                    qid: q.qid.isEmpty ? "\(round).q\(i):\(q.cardId)" : q.qid, cardId: q.cardId, type: type, ask: q.ask,
                    choices: type == .mc ? choices : nil, retryChoices: normChoices(q.retryChoices, q.cardId)))
        }
        let answered = clampCount(state.answered)
        let startedAt = state.startedAt.isFinite ? state.startedAt : 0
        return LearnState(
            v: 1, subset: normalizeSubset(state.subset), answerWith: state.answerWith,
            learn: normalizeLearn(roundSize: state.learn.roundSize, mc: state.learn.mc, written: state.learn.written),
            order: order, stage: stage, initiallyMastered: ids(state.initiallyMastered),
            seen: state.seen.filter { known.contains($0.key) && $0.value }, solved: solved, round: round, queue: queue,
            clock: state.clock >= 0 ? min(state.clock, maxSafeInteger) : answered,
            lastAt: state.lastAt.filter { known.contains($0.key) && $0.value >= 0 },
            repeats: clampCount(state.repeats),
            roundLog: state.roundLog.compactMap { e in
                guard known.contains(e.cardId) else { return nil }
                var entry = e
                entry.stageAfter = clampStage(e.stageAfter)
                return entry
            },
            rounds: state.rounds.map { r in
                let answered = clampCount(r.answered)
                return LearnRoundRecord(
                    round: min(max(r.round, -maxSafeInteger), maxSafeInteger), answered: answered,
                    correct: min(answered, clampCount(r.correct)), cardIds: ids(r.cardIds))
            },
            answered: answered, correct: min(answered, clampCount(state.correct)),
            misses: state.misses.filter { known.contains($0.key) }.mapValues(clampCount),
            last: state.last.flatMap { l in
                guard known.contains(l.cardId) else { return nil }
                var last = l
                last.stageBefore = clampStage(l.stageBefore)
                return last
            },
            startedAt: startedAt, updatedAt: state.updatedAt.isFinite ? state.updatedAt : startedAt,
            finishedAt: state.finishedAt, elapsedMs: state.elapsedMs.isFinite ? max(0, state.elapsedMs) : 0,
            review: state.review.map { r in
                LearnReview(due: ids(r.due), results: r.results.filter { known.contains($0.key) })
            },
            recheck: state.recheck.map { LearnRecheck(due: ids($0.due)) })
    }

    // MARK: - Asking and answering

    /// The question to ask now, nil when the round is over.
    public static func current(_ state: LearnState) -> Question? {
        guard let q = copyState(state).queue.first else { return nil }
        return publicQuestion(q)
    }

    /// Answers the current question (no-op when the round is over). A miss comes back like any
    /// card, after the gap (planned in a later round); the card's later questions in this round
    /// follow its new stage.
    public static func answer(_ state: LearnState, correct: Bool, now: Double = TimeUtil.nowMs()) -> LearnState {
        var s = copyState(state)
        guard let q = s.queue.first else { return s }
        advanceClock(&s, now)
        let id = q.cardId
        let stageBefore = s.stage[id] ?? 0
        let stageAfter = correct ? min(stageBefore + 1, masteredStage) : 0
        s.stage[id] = stageAfter
        s.seen[id] = true
        if correct { s.solved[id] = true }
        s.answered += 1
        if correct {
            s.correct += 1
        } else {
            s.misses[id, default: 0] += 1
        }
        s.queue.removeFirst()
        s.repeats = s.lastAt[id] != nil ? s.repeats + 1 : 0
        s.lastAt[id] = s.clock
        s.clock += 1
        s.roundLog.append(
            LearnRoundLogEntry(qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: correct, stageAfter: stageAfter))
        s.last = LearnLastAnswer(qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: correct, stageBefore: stageBefore)

        followStage(&s, id)
        if stageBefore < masteredStage { noteRecheck(&s, id) }
        if isReviewQuestion(q.qid), var review = s.review {
            // The first answer to a mastered card's repetition question counts; a miss means it
            // is learned again (stage 0), so it no longer counts as mastered before the session.
            if review.results[id] == nil { review.results[id] = correct }
            s.review = review
            if !correct { s.initiallyMastered.removeAll { $0 == id } }
        }
        markFinished(&s, now)
        return s
    }

    /// "Ich hatte recht": the last answer (if it was wrong) becomes correct: the card's stage is
    /// stageBefore + 1 and its later questions in this round follow that stage. Idempotent; a no-op
    /// after `nextRound`.
    public static func override(_ state: LearnState, now: Double = TimeUtil.nowMs()) -> LearnState {
        var s = copyState(state)
        guard let l = s.last, !l.correct else { return s }
        advanceClock(&s, now)
        let id = l.cardId
        let stageAfter = min(l.stageBefore + 1, masteredStage)
        s.stage[id] = stageAfter
        s.solved[id] = true
        s.correct = min(s.answered, s.correct + 1)
        s.misses[id] = max(0, (s.misses[id] ?? 0) - 1)
        if let i = s.roundLog.lastIndex(where: { $0.cardId == id && ($0.qid == nil || $0.qid == l.qid) }) {
            s.roundLog[i].correct = true
            s.roundLog[i].stageAfter = stageAfter
        }
        followStage(&s, id)
        if l.stageBefore < masteredStage { noteRecheck(&s, id) }
        s.last?.correct = true
        if isReviewQuestion(l.qid), var review = s.review {
            // The repetition question was right after all: the card is still mastered.
            review.results[id] = true
            s.review = review
            if stageAfter >= masteredStage && !s.initiallyMastered.contains(id) {
                let before = Set(s.initiallyMastered).union([id])
                s.initiallyMastered = s.order.filter(before.contains)
            }
        }
        markFinished(&s, now)
        return s
    }

    // MARK: - Rounds and statistics

    public static func isRoundOver(_ state: LearnState) -> Bool {
        copyState(state).queue.isEmpty
    }

    /// Neu (never answered, stage 0) · Am Lernen · Gemeistert (stage 2) over the scope.
    public static func counts(_ state: LearnState) -> Counts {
        counts(of: copyState(state))
    }

    /// The current round's answers per card (in asked order) and the counts.
    public static func checkpoint(_ state: LearnState) -> Checkpoint {
        let s = copyState(state)
        var items: [CheckpointItem] = []
        var index: [String: Int] = [:]
        for e in s.roundLog {
            if index[e.cardId] == nil {
                index[e.cardId] = items.count
                items.append(CheckpointItem(cardId: e.cardId, stage: s.stage[e.cardId] ?? 0, results: []))
            }
            items[index[e.cardId]!].results.append(e.correct)
        }
        let c = counts(of: s)
        return Checkpoint(
            round: s.round, answered: s.roundLog.count, correct: s.roundLog.count { $0.correct }, items: items,
            counts: CheckpointCounts(fresh: c.fresh, learning: c.learning, mastered: c.mastered, total: c.total))
    }

    /// Closes the finished round into `rounds` and plans the next round's questions
    /// (`planRound`). When every card is mastered (and every repetition question and recheck
    /// asked) the final round is closed and the session stays finished (its roundLog is kept for
    /// the checkpoint). No-op mid-round. Scope cards missing from `cards` (deleted) are removed;
    /// nil keeps every card (JS: a non-array `cards`) and builds written questions only.
    public static func nextRound(
        _ state: LearnState, cards: [Card]?, rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs()
    ) -> LearnState {
        var s = copyState(state)
        if !s.queue.isEmpty { return s }
        if let cards {
            let present = Set(cardList(cards).map(\.id))
            for id in s.order where !present.contains(id) { dropCard(&s, id, refill: nil, rng: rng) }
        }
        dropLateRechecks(&s)
        if isComplete(s) {
            if !s.roundLog.isEmpty && !roundIsClosed(s) { archiveRound(&s) }
            markFinished(&s, now)
            return s
        }
        advanceClock(&s, now)
        // A round without answers (only possible after removals or in a repaired state) is
        // refilled, not counted.
        if !s.roundLog.isEmpty {
            if !roundIsClosed(s) { archiveRound(&s) }
            s.round += 1
        }
        s.roundLog = []
        s.last = nil
        let queue = planRound(&s, cards ?? [], rng)
        s.queue = queue
        return s
    }

    /// Every card in scope is mastered (also true for a session without cards) and, with
    /// repetition questions, every card mastered before the session was asked again.
    public static func isFinished(_ state: LearnState) -> Bool {
        isComplete(copyState(state))
    }

    public static func finalStats(_ state: LearnState) -> FinalStats {
        let s = copyState(state)
        let total = s.order.count
        let mastered = s.order.count { (s.stage[$0] ?? 0) >= masteredStage }
        let rounds = s.rounds.count + (!s.roundLog.isEmpty && !roundIsClosed(s) ? 1 : 0)
        let hardest = s.order.enumerated()
            .compactMap { i, cardId -> (i: Int, card: MissedCard)? in
                let misses = s.misses[cardId] ?? 0
                return misses > 0 ? (i, MissedCard(cardId: cardId, misses: misses)) : nil
            }
            .sorted { x, y in x.card.misses != y.card.misses ? x.card.misses > y.card.misses : x.i < y.i }
            .map(\.card)
        return FinalStats(
            total: total, mastered: mastered, alreadyMastered: s.initiallyMastered.count, rounds: rounds,
            answered: s.answered, accuracy: s.answered == 0 ? 0 : Double(s.correct) / Double(s.answered),
            elapsedMs: s.elapsedMs, hardest: Array(hardest))
    }

    // MARK: - Repetition questions

    /// Whether question `qid` is a repetition question ("<round>.3:<cardId>" or
    /// "<round>.3.<n>:<cardId>", JS `/^\d+\.3(\.\d+)?:/`).
    public static func isReviewQuestion(_ qid: String) -> Bool {
        questionKind(qid) == .review
    }

    /// Whether question `qid` is a recheck ("<round>.4:<cardId>" or "<round>.4.<n>:<cardId>", JS
    /// `/^\d+\.4(\.\d+)?:/`).
    public static func isRecheckQuestion(_ qid: String) -> Bool {
        questionKind(qid) == .recheck
    }

    /// The repetition questions so far; nil for a session without them.
    public static func reviewStats(_ state: LearnState) -> ReviewStats? {
        let s = copyState(state)
        guard let review = s.review else { return nil }
        let queued = Set(s.queue.filter { isReviewQuestion($0.qid) }.map(\.cardId))
        let due = review.due.filter { (s.stage[$0] ?? 0) >= masteredStage && !queued.contains($0) }
        return ReviewStats(
            asked: review.results.count, kept: review.results.values.count { $0 }, left: queued.count + due.count)
    }

    // MARK: - Changes

    /// Removes a card from the session (deleted mid-session): its stage, spacing, questions,
    /// current-round answers and misses, and its options in other questions. With `cards` (the
    /// set's current cards) each lost option is replaced by another wrong option from the set
    /// where one is left, in the same place. Unknown ids are a no-op.
    public static func removeCard(
        _ state: LearnState, cardId: String, now: Double = TimeUtil.nowMs(), cards: [Card]? = nil,
        rng: RNG = systemRNG()
    ) -> LearnState {
        var s = copyState(state)
        guard s.order.contains(cardId) else { return s }
        advanceClock(&s, now)
        var refill: Refill?
        if let cards {
            let all = cardList(cards)
            var byId: [String: Card] = [:]
            for card in all { byId[card.id] = card }
            refill = Refill(pool: ChoicePool(all.filter { $0.id != cardId && askable($0) }), byId: byId)
        }
        dropCard(&s, cardId, refill: refill, rng: rng)
        finishEarly(&s, now)
        return s
    }

    /// Advances the active-time clock.
    public static func tick(_ state: LearnState, now: Double = TimeUtil.nowMs()) -> LearnState {
        var s = copyState(state)
        advanceClock(&s, now)
        return s
    }

    // MARK: - Switching the options during a session
    //
    // «Wiederholungsfragen» and «Nachkontrolle nach Fehlern» apply to a running session at once
    // (since 24.11.2026; before, only to the next one, so a session started with them kept them for
    // days after they were switched off). A finished session is left as it is.

    /// Repetition questions on or off. Off drops the queued ones and those still to come; on asks
    /// the cards mastered before the session that are mastered still once more, the most overdue
    /// first (`progress`: when each was answered last).
    public static func setReview(
        _ state: LearnState, on: Bool, progress: ProgressMap = [:], now: Double = TimeUtil.nowMs()
    ) -> LearnState {
        var s = copyState(state)
        guard s.finishedAt == nil, on != (s.review != nil) else { return s }
        if on {
            let mastered = s.initiallyMastered.filter { (s.stage[$0] ?? 0) >= masteredStage }
            s.review = LearnReview(due: mostOverdueFirst(mastered, progress: progress))
        } else {
            s.queue.removeAll { isReviewQuestion($0.qid) }
            s.review = nil
        }
        finishEarly(&s, now)
        return s
    }

    /// Rechecks on or off. Off drops the queued ones and the cards waiting for one; on (only in
    /// sessions with more than RECHECK_MIN_CARDS cards) checks the cards missed from now on.
    public static func setRecheck(_ state: LearnState, on: Bool, now: Double = TimeUtil.nowMs()) -> LearnState {
        var s = copyState(state)
        guard s.finishedAt == nil, on != (s.recheck != nil) else { return s }
        if on {
            guard s.order.count > RECHECK_MIN_CARDS else { return s }
            s.recheck = LearnRecheck()
        } else {
            s.queue.removeAll { isRecheckQuestion($0.qid) }
            s.recheck = nil
        }
        finishEarly(&s, now)
        return s
    }

    /// Direction (`answerWith`), question types and round size as they are set now (since
    /// 25.11.2026; before, a session kept them from its start and asked «Neu starten?»). The cards'
    /// stages stay; the questions still to come in this round, the one asked now included, are
    /// asked in the new direction and with the new types (new options where the side changes or
    /// multiple choice is switched on). A smaller round ends this round sooner (the question asked
    /// now stays; repetition questions and rechecks taken out wait for a later round), a larger
    /// one applies from the next round. `cards`: the set's cards (the multiple-choice options).
    public static func setOptions(
        _ state: LearnState, answerWith: AnswerWith, learn: LearnOptions, cards: [Card], rng: RNG = systemRNG()
    ) -> LearnState {
        var s = copyState(state)
        let options = normalizeLearn(learn)
        guard s.finishedAt == nil, answerWith != s.answerWith || options != s.learn else { return s }
        let typesChanged = options.mc != s.learn.mc || options.written != s.learn.written
        let shrinks = options.roundSize < s.learn.roundSize
        s.answerWith = answerWith
        s.learn = options
        if shrinks { shortenRound(&s) }
        requestion(&s, cards, rng, typesChanged: typesChanged)
        return s
    }

    // MARK: - Shared progress
    //
    // Learn and Write record every answer in the same CardProgress, which is the source of truth:
    // a card's stage is min(streak, 2) and it counts as seen once it was ever answered. Every Learn
    // transition keeps that true by itself; answers given elsewhere (Write mode, another window)
    // are brought in with syncProgress().

    /// Whether every card's stage, seen and solved flags match `progress` (always true when
    /// finished: a finished session keeps its result).
    public static func matchesProgress(_ state: LearnState, progress: ProgressMap) -> Bool {
        let s = copyState(state)
        if s.finishedAt != nil { return true }
        return s.order.allSatisfy { id in
            let p = progress[id]
            return s.stage[id] == stageFromProgress(p) && (s.seen[id] == true) == (Mastery.cardStatus(p) != .new)
                && (s.solved[id] == true) == solvedFromProgress(p)
        }
    }

    /// Brings the session in line with `progress` (answers given in Write mode or elsewhere):
    /// every stage becomes min(streak, 2), `seen` follows whether the card was ever answered and
    /// `solved` whether it was ever answered right. A card that is mastered now leaves this round's
    /// queue; a card whose stage (or, not mastered, whose solved flag) changed otherwise keeps its
    /// queued questions, switched to the type of its new stage; a card no longer mastered is
    /// studied again. A queued repetition question or recheck of a card that is no longer
    /// mastered (missed elsewhere) becomes an ordinary question: the card is learned instead, so it
    /// neither shows as a repetition nor counts in `reviewStats`, and it leaves the cards waiting
    /// for a recheck. A finished session is left as it is.
    public static func syncProgress(_ state: LearnState, progress: ProgressMap, now: Double = TimeUtil.nowMs())
        -> LearnState
    {
        var s = copyState(state)
        if s.finishedAt != nil { return s }
        var changed: [String] = []
        for id in s.order {
            let p = progress[id]
            let stage = stageFromProgress(p)
            let solved = solvedFromProgress(p)
            if stage != s.stage[id] || (solved != (s.solved[id] == true) && stage < masteredStage) {
                changed.append(id)
            }
            s.stage[id] = stage
            s.seen[id] = Mastery.cardStatus(p) == .new ? nil : true
            s.solved[id] = solved ? true : nil
        }
        for id in changed {
            if (s.stage[id] ?? 0) >= masteredStage {
                s.queue.removeAll { $0.cardId == id }
            } else {
                s.initiallyMastered.removeAll { $0 == id }
                s.recheck?.due.removeAll { $0 == id }
                s.queue = s.queue.map { q in
                    guard q.cardId == id else { return q }
                    var learn = q
                    learn.qid = asLearnQid(q.qid)
                    return retype(s, learn)
                }
            }
        }
        finishEarly(&s, now)
        return s
    }

    // MARK: - Internals: helpers

    private typealias JSText = Grading.JSText

    /// 2^53, the end of the JS safe-integer range.
    private static let maxSafeInteger = 9_007_199_254_740_992

    private static func clampCount(_ n: Int) -> Int { min(max(0, n), maxSafeInteger) }

    /// `Math.max(0, finite(v, 0))` as a count: fractional values (never written by the web app)
    /// are rounded up, which keeps the engine's comparisons with 0 and 1 intact.
    private static func countValue(_ v: JSONValue?) -> Int {
        guard let n = v?.finiteNumber, n > 0 else { return 0 }
        return Int(min(n, Double(maxSafeInteger)).rounded(.up))
    }

    /// `clampStage`: a finite number floored into 0…2, anything else 0.
    private static func clampStage(_ v: JSONValue?) -> Int {
        guard let n = v?.finiteNumber else { return 0 }
        return Int(max(0, min(Double(masteredStage), n.rounded(.down))))
    }

    private static func clampStage(_ n: Int) -> Int { max(0, min(masteredStage, n)) }

    private static func askSide(_ v: JSONValue?) -> AskSide { v == .string("definition") ? .definition : .term }

    private static func questionType(_ v: JSONValue?) -> QuestionType { v == .string("mc") ? .mc : .written }

    private static func hasText(_ s: String) -> Bool {
        s.unicodeScalars.contains { !JSCompat.isWhitespace($0) }
    }

    /// A card with an empty side cannot be asked (and is no useful distractor either).
    private static func askable(_ card: Card) -> Bool { hasText(card.term) && hasText(card.definition) }

    /// Unique cards by id (the first one wins), without empty ids, in the given order (`cardList`).
    private static func cardList(_ cards: [Card]) -> [Card] {
        var seen = Set<String>()
        return cards.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// `normalizeSubset` for a typed subset: empty card ids are dropped.
    private static func normalizeSubset(_ subset: StudySubset) -> StudySubset {
        if case let .cardIds(ids) = subset, ids.contains(where: \.isEmpty) {
            return .cardIds(ids.filter { !$0.isEmpty })
        }
        return subset
    }

    private static func cardInSubset(_ card: Card, _ subset: StudySubset, _ progress: ProgressMap) -> Bool {
        switch subset {
        case .all: true
        case .starred: card.starred
        case .learning: Mastery.cardStatus(progress[card.id]) != .mastered
        case .missed: progress[card.id]?.lastResult == .incorrect
        case let .cardIds(ids): ids.contains(card.id)
        }
    }

    /// `normalizeLearn`: a round size below 1 means the default; at least one question type
    /// stays enabled (both off → the defaults).
    private static func normalizeLearn(roundSize: Int, mc: Bool, written: Bool) -> LearnSessionOptions {
        let both = mc || written
        return LearnSessionOptions(
            roundSize: roundSize >= 1 ? roundSize : DEFAULT_LEARN.roundSize, mc: both ? mc : DEFAULT_LEARN.mc,
            written: both ? written : DEFAULT_LEARN.written)
    }

    private static func normalizeLearn(_ learn: LearnOptions) -> LearnSessionOptions {
        normalizeLearn(roundSize: learn.roundSize, mc: learn.mc, written: learn.written)
    }

    // MARK: - Internals: options

    // Every question of a round compares its card with every card of the set (`distractors`),
    // so the keys of each text are computed once (`TextMemo`).
    private static let textKeys = TextMemo<JSText>()
    private static let answerKeySets = TextMemo<Set<JSText>>()

    /// Comparison key for answer texts: basic normalisation, script folds (Arabic vowel marks,
    /// full-width punctuation) + JS lowercase.
    private static func textKey(_ text: String) -> JSText {
        textKeys.value(for: text) { Grading.foldScripts(Grading.normalizeBasic(JSText($0))).lowercased() }
    }

    /// The whole answer and each of its alternatives ("laid, laide" → laid, laide | laid | laide).
    private static func answerKeys(_ text: String) -> Set<JSText> {
        answerKeySets.value(for: text) { text in
            var keys: Set<JSText> = [textKey(text)]
            for alt in Grading.splitAlternatives(text) { keys.insert(textKey(alt)) }
            keys.remove("")
            return keys
        }
    }

    /// The cards wrong options come from, with what `distractors` and `rankedDistractors` need of
    /// each card worked out once per list (lazily, per side) instead of once per question: a
    /// round plans `roundSize` questions with two option lists each, and every list compares the
    /// asked card with every card of the set (64 ms per round of a 540-card set, 26.11.2026).
    /// Lives for one engine call; the values are those of the memoised text functions.
    private final class ChoicePool {
        /// What every card says on one side (index = position in `list`).
        struct Side {
            /// The trimmed answer text and its shape.
            let texts: [String]
            let shapes: [WordClass.OptionShape]
            /// The number of each distinct answer key (`textKey`; -1 for an empty one): a question
            /// keeps its options distinct by number instead of hashing every text again.
            let keyNumbers: [JSText: Int]
            let keyNumber: [Int]
            /// The cards having each key among their answer's alternatives (`answerKeys`), and among
            /// their prompt's (`Synonyms.promptKeys`, for `findSynonymCards`).
            let answerKeyCards: [JSText: [Int]]
            let promptKeyCards: [JSText: [Int]]
            /// Whether the answer is blank (no synonym card then).
            let blankAnswers: [Bool]
        }

        let list: [Card]
        private var term: Side?
        private var definition: Side?

        init(_ list: [Card]) {
            self.list = list
        }

        /// Each card id's position (the last one wins).
        lazy var at: [String: Int] = {
            var at: [String: Int] = [:]
            for (i, c) in list.enumerated() { at[c.id] = i }
            return at
        }()
        lazy var sides = WordClass.listProfiles(list)
        /// `WordClass.cardClass` of each card.
        lazy var classes: [String] = list.map { WordClass.cardClass($0, sides: sides) }

        func side(_ ask: AskSide) -> Side {
            if let known = ask == .term ? term : definition { return known }
            let answers = sides.side(ask)
            let texts = list.map { JSCompat.trim(Synonyms.answerSide($0, ask: ask)) }
            var keyNumbers: [JSText: Int] = [:]
            var keyNumber: [Int] = []
            var answerKeyCards: [JSText: [Int]] = [:]
            var promptKeyCards: [JSText: [Int]] = [:]
            keyNumber.reserveCapacity(list.count)
            for (i, text) in texts.enumerated() {
                let key = LearnEngine.textKey(text)
                if key.isEmpty {
                    keyNumber.append(-1)
                } else {
                    let number = keyNumbers[key] ?? keyNumbers.count
                    keyNumbers[key] = number
                    keyNumber.append(number)
                }
                for alt in LearnEngine.answerKeys(text) { answerKeyCards[alt, default: []].append(i) }
                for alt in Synonyms.promptKeys(Synonyms.promptSide(list[i], ask: ask)) {
                    promptKeyCards[alt, default: []].append(i)
                }
            }
            let side = Side(
                texts: texts, shapes: texts.map { WordClass.shapeOf($0, side: answers) }, keyNumbers: keyNumbers,
                keyNumber: keyNumber, answerKeyCards: answerKeyCards, promptKeyCards: promptKeyCards,
                blankAnswers: list.map { Synonyms.isBlank(Synonyms.answerSide($0, ask: ask)) })
            if ask == .term { term = side } else { definition = side }
            return side
        }
    }

    /// Possible wrong options for `card` asked on `side`, in `pool.list` order (with their
    /// positions): other cards' answer texts that are non-empty, distinct, differ from the correct
    /// answer and share none of its alternatives, from cards that are no synonyms of `card`.
    /// Texts whose key is in `takenKeys` are skipped too.
    private static func distractors(_ pool: ChoicePool, _ card: Card, _ side: AskSide, takenKeys: [JSText] = [])
        -> [(choice: Choice, index: Int)]
    {
        let list = pool.list
        let data = pool.side(side)
        let correctText = JSCompat.trim(Synonyms.answerSide(card, ask: side))
        // Synonym cards (same prompt) would make their answer correct too (`findSynonymCards`).
        var synonyms = Set<String>()
        for key in Synonyms.promptKeys(Synonyms.promptSide(card, ask: side)) {
            for i in data.promptKeyCards[key] ?? [] where !Synonyms.isSameCard(list[i], card) && !data.blankAnswers[i] {
                synonyms.insert(list[i].id)
            }
        }
        // An option sharing an alternative with the correct answer would be correct as well.
        var sharesAlternative = [Bool](repeating: false, count: list.count)
        for key in answerKeys(correctText) {
            for i in data.answerKeyCards[key] ?? [] { sharesAlternative[i] = true }
        }
        // Keys not among the list's cannot match an option.
        var usedKeys = [Bool](repeating: false, count: data.keyNumbers.count)
        for key in takenKeys + [textKey(correctText)] {
            if let number = data.keyNumbers[key] { usedKeys[number] = true }
        }
        var out: [(choice: Choice, index: Int)] = []
        for (i, other) in list.enumerated()
        where other.id != card.id && (synonyms.isEmpty || !synonyms.contains(other.id)) {
            let number = data.keyNumber[i]
            if number < 0 || usedKeys[number] { continue }
            if sharesAlternative[i] { continue }
            usedKeys[number] = true
            out.append((Choice(cardId: other.id, text: data.texts[i]), i))
        }
        return out
    }

    /// Wrong options for `card` asked on `side`, most alike first (since 23.11.2026, `WordClass`):
    /// cards of the same word class before cards of an open class before others, then by
    /// similarity points (close in the set, same article, as many words, similar length, same
    /// beginning and ending) plus a random 0–2, so options almost as similar take turns; equal
    /// ones in random order.
    private static func rankedDistractors(
        _ pool: ChoicePool, _ card: Card, _ side: AskSide, _ rng: RNG, takenKeys: [JSText] = []
    ) -> [Choice] {
        let candidates = distractors(pool, card, side, takenKeys: takenKeys)
        let at = pool.at
        let sides = pool.sides
        let shapes = pool.side(side).shapes
        let cls = WordClass.cardClass(card, sides: sides)
        let shape = WordClass.shapeOf(JSCompat.trim(Synonyms.answerSide(card, ask: side)), side: sides.side(side))
        let here = at[card.id] ?? -1
        var ranked: [(choice: Choice, order: Int, key: Int)] = []
        for (order, c) in JSRandom.shuffled(candidates, rng).enumerated() {
            let i = at[c.choice.cardId] ?? 0
            let otherCls = pool.classes[i]
            let tier = cls.isEmpty || otherCls.isEmpty ? 1 : otherCls == cls ? 2 : 0
            var points = WordClass.shapePoints(shape, shapes[c.index])
            if here >= 0 { points += WordClass.nearPoints(abs(i - here)) }
            ranked.append((c.choice, order, tier * 100 + points + JSRandom.index(rng, 3)))
        }
        ranked.sort { $0.key != $1.key ? $0.key > $1.key : $0.order < $1.order }
        return ranked.map(\.choice)
    }

    /// A stored option list: each non-empty card id once; kept only with at least two options
    /// including the asked card's.
    private static func normChoices(_ v: JSONValue?, _ cardId: String) -> [Choice]? {
        guard let list = v?.arrayValue else { return nil }
        var ids = Set<String>()
        var out: [Choice] = []
        for c in list {
            guard let o = c.objectValue, let raw = o["cardId"], raw != .null, raw != .string("") else { continue }
            let id = JSCompat.jsString(raw)
            guard ids.insert(id).inserted else { continue }
            out.append(Choice(cardId: id, text: o["text"]?.stringValue ?? ""))
        }
        return out.count >= 2 && ids.contains(cardId) ? out : nil
    }

    private static func normChoices(_ list: [Choice]?, _ cardId: String) -> [Choice]? {
        guard let list else { return nil }
        var ids = Set<String>()
        let out = list.filter { !$0.cardId.isEmpty && ids.insert($0.cardId).inserted }
        return out.count >= 2 && ids.contains(cardId) ? out : nil
    }

    // MARK: - Internals: questions

    /// The kind of a question, the digit after the round in its qid.
    private enum QuestionKind: Int {
        case learn = 1, review = 3, recheck = 4
    }

    /// "<round>.<kind>:<cardId>"; a card's n-th question in the round (n ≥ 2)
    /// "<round>.<kind>.<n>:<cardId>".
    private static func questionId(_ round: Int, _ kind: QuestionKind, _ cardId: String, _ n: Int) -> String {
        n > 1 ? "\(round).\(kind.rawValue).\(n):\(cardId)" : "\(round).\(kind.rawValue):\(cardId)"
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    /// The kind of a qid matching JS `/^\d+\.K(\.\d+)?:/` for a one-digit K (`REVIEW_QID`,
    /// `RECHECK_QID`); nil otherwise (also for kinds that are no `QuestionKind`).
    private static func questionKind(_ qid: String) -> QuestionKind? {
        var rest = qid.unicodeScalars[...]
        func digits() -> Bool {
            let n = rest.prefix(while: isDigit).count
            rest = rest.dropFirst(n)
            return n > 0
        }
        guard digits(), rest.first == ".", let k = rest.dropFirst().first, isDigit(k) else { return nil }
        rest = rest.dropFirst(2)
        if rest.first == "." {
            rest = rest.dropFirst()
            guard digits() else { return nil }
        }
        guard rest.first == ":" else { return nil }
        return QuestionKind(rawValue: Int(k.value) - 0x30)
    }

    /// A repetition question or recheck asked as an ordinary learning question (its card is
    /// learned): JS `qid.replace(/^(\d+)\.[34]/, '$1.1')`.
    private static func asLearnQid(_ qid: String) -> String {
        let scalars = Array(qid.unicodeScalars)
        var i = 0
        while i < scalars.count && isDigit(scalars[i]) { i += 1 }
        guard i > 0, i + 1 < scalars.count, scalars[i] == ".", scalars[i + 1] == "3" || scalars[i + 1] == "4" else {
            return qid
        }
        var out = String.UnicodeScalarView(scalars[...i])
        out.append("1")
        out.append(contentsOf: scalars[(i + 2)...])
        return String(out)
    }

    private static func publicQuestion(_ q: LearnQueueQuestion) -> Question {
        Question(qid: q.qid, cardId: q.cardId, type: q.type, ask: q.ask, choices: q.type == .mc ? q.choices : nil)
    }

    private static func pickAsk(_ answerWith: AnswerWith, _ rng: RNG) -> AskSide {
        switch answerWith {
        case .term: .term
        case .definition: .definition
        case .both: JSRandom.index(rng, 2) == 0 ? .term : .definition
        }
    }

    /// Whether a card at `stage` is asked as multiple choice: at stage 0 until it was answered right
    /// once (`mcStage`).
    private static func mcStage(_ s: LearnState, _ id: String, _ stage: Int) -> Bool {
        stage == 0 && s.solved[id] != true
    }

    /// Stage 0 → multiple choice (until solved), else written; a disabled type falls back to the
    /// other one, and multiple choice needs at least two options. `retryChoices` holds the options
    /// for when the question has to be asked as multiple choice after all (a wrong multiple-choice
    /// answer earlier in the round).
    private static func makeQuestion(
        _ s: LearnState, _ card: Card, _ stage: Int, _ pool: ChoicePool, _ qid: String, _ rng: RNG
    ) -> LearnQueueQuestion {
        let ask = pickAsk(s.answerWith, rng)
        let choices = s.learn.mc ? buildChoices(pool, card: card, ask: ask, rng: rng) : []
        let canMc = choices.count >= 2
        let type: QuestionType =
            mcStage(s, card.id, stage) ? (canMc ? .mc : .written) : (s.learn.written || !canMc ? .written : .mc)
        var q = LearnQueueQuestion(qid: qid, cardId: card.id, type: type, ask: ask)
        if type == .mc { q.choices = choices }
        if canMc { q.retryChoices = buildChoices(pool, card: card, ask: ask, rng: rng) }
        return q
    }

    /// The planning state of a round (`p` in planRound of learn.js): stages and last answers as
    /// if every answer were right, and the repetition questions and rechecks not planned yet.
    private struct Plan {
        var stage: [String: Int]
        var lastAt: [String: Int]
        var repeats: Int
        var reviewDue: [String]
        var recheckDue: [String]
    }

    /// A card that was asked before (or waits for its recheck): it may come once it has waited
    /// `min` other questions and comes for sure once it has waited `max`.
    private struct Waiting {
        let id: String
        let kind: QuestionKind
        let wait: Int
        let min: Int
        let max: Int
    }

    /// Of `list`, the entry with the highest score; ties go to the one earlier in `order`
    /// (`index`). nil for an empty list.
    private static func best(_ list: [Waiting], _ index: [String: Int], score: (Waiting) -> Int) -> Waiting? {
        var top: Waiting?
        for e in list {
            guard let t = top else {
                top = e
                continue
            }
            if score(e) > score(t) || (score(e) == score(t) && (index[e.id] ?? .max) < (index[t.id] ?? .max)) {
                top = e
            }
        }
        return top
    }

    /// The card asked at question number `t` (the session's answer count when it is asked) in
    /// the plan `p`: (id, kind), or nil when no card needs a question any more (`nextPick`).
    ///
    /// Waiting cards (learning cards asked before, and rechecks) may come once they have waited
    /// `min` other questions; once they have waited `max` they come for sure (the longest overdue
    /// first). In between, the card that is furthest past its `min` comes with a chance that grows
    /// with every question it waits – (wait - min + 1) in (max - min + 1) – otherwise a new card
    /// comes. New cards: learning cards not asked yet in this session (stage-1 cards first) and
    /// repetition questions (about every third one while there are both).
    ///
    /// Two limits keep the mix: after MAX_REPEATS questions in a row of cards asked before, a new
    /// card comes (even before an overdue one); while MAX_LEARNING cards are being learned (asked,
    /// not mastered yet) new cards come only by that rule, after twice as many. Only when no card
    /// may come yet, the card that has waited longest comes early (a recheck only after MIN_GAP;
    /// nil when only rechecks are waiting that have not waited that long: the round ends there).
    private static func nextPick(_ s: LearnState, _ p: Plan, _ t: Int, _ rng: RNG, _ index: [String: Int])
        -> (id: String, kind: QuestionKind)?
    {
        let learning = s.order.filter { (p.stage[$0] ?? 0) < masteredStage }
        // Cards that can fill a learning card's gap: the learning cards and the repetition
        // questions (rechecks wait 30 questions and more, so they do not count here).
        let toLearn = learning.count + p.reviewDue.count
        let open = toLearn + p.recheckDue.count
        if open == 0 { return nil }
        var waiting: [Waiting] = []
        var fresh: [String] = []
        for want in [1, 0] {
            for id in learning {
                if let last = p.lastAt[id] {
                    if want == 1 {
                        waiting.append(
                            Waiting(id: id, kind: .learn, wait: t - last - 1, min: min(MIN_GAP, toLearn - 1), max: MAX_WAIT))
                    }
                } else if p.stage[id] == want {
                    fresh.append(id)
                }
            }
        }
        let inFlight = waiting.count
        for id in p.recheckDue {
            // A recheck without a known last answer is overdue.
            let wait = p.lastAt[id].map { t - $0 - 1 } ?? RECHECK_WAIT
            // Fewer open cards bring it closer, but never closer than a learning card's gap.
            let least = max(MIN_GAP, min(RECHECK_GAP, open - 1))
            waiting.append(Waiting(id: id, kind: .recheck, wait: wait, min: least, max: RECHECK_WAIT))
        }
        let ready = waiting.filter { $0.wait >= $0.min }
        let hasNew = !fresh.isEmpty || !p.reviewDue.isEmpty
        func takeNew() -> (id: String, kind: QuestionKind) {
            if let first = fresh.first, let review = p.reviewDue.first {
                return JSRandom.index(rng, 3) == 0 ? (review, .review) : (first, .learn)
            }
            if let first = fresh.first { return (first, .learn) }
            return (p.reviewDue[0], .review)
        }
        func pick(_ w: Waiting?) -> (id: String, kind: QuestionKind)? { w.map { ($0.id, $0.kind) } }
        if ready.isEmpty {
            if hasNew { return takeNew() }
            // Nothing may come yet: the learning card that has waited longest comes early. A
            // recheck only when nothing is left to learn and never before MIN_GAP other questions
            // (sooner it would check nothing): with only such rechecks left the round ends here;
            // they come once they have waited, or are dropped when nothing else is left.
            let learn = waiting.filter { $0.kind == .learn }
            if !learn.isEmpty { return pick(best(learn, index) { $0.wait }) }
            return pick(best(waiting.filter { $0.wait >= MIN_GAP }, index) { $0.wait })
        }
        if !hasNew { return pick(best(ready, index) { $0.wait - $0.max }) }
        let full = inFlight >= MAX_LEARNING
        if p.repeats >= (full ? 2 * MAX_REPEATS : MAX_REPEATS) { return takeNew() }
        let forced = ready.filter { $0.wait >= $0.max }
        if !forced.isEmpty { return pick(best(forced, index) { $0.wait - $0.max }) }
        guard let c = best(ready, index, score: { $0.wait - $0.min }) else { return takeNew() }
        if full || JSRandom.index(rng, c.max - c.min + 1) < c.wait - c.min + 1 { return (c.id, c.kind) }
        return takeNew()
    }

    /// Plans the round's `roundSize` questions (fewer when the session ends sooner), as if every
    /// answer were right (`planRound`). Planned repetition questions and rechecks leave
    /// `review.due` / `recheck.due`; cards there that are no longer mastered (answered wrong
    /// elsewhere) are learned instead and leave too.
    private static func planRound(_ s: inout LearnState, _ cards: [Card], _ rng: RNG) -> [LearnQueueQuestion] {
        let all = cardList(cards)
        var byId: [String: Card] = [:]
        for card in all where byId[card.id] == nil { byId[card.id] = card }
        let pool = ChoicePool(cardList(all.filter(askable)))
        var index: [String: Int] = [:]
        for (i, id) in s.order.enumerated() { index[id] = i }
        let stage = s.stage
        func mastered(_ id: String) -> Bool { index[id] != nil && (stage[id] ?? 0) >= masteredStage }
        var p = Plan(
            stage: s.stage, lastAt: s.lastAt, repeats: s.repeats, reviewDue: s.review?.due.filter(mastered) ?? [],
            recheckDue: s.recheck?.due.filter(mastered) ?? [])
        var asked: [String: Int] = [:]
        var queue: [LearnQueueQuestion] = []
        var k = 0
        while k < s.learn.roundSize {
            let t = s.clock + k
            k += 1
            guard let pick = nextPick(s, p, t, rng, index) else { break }
            let (id, kind) = pick
            asked[id, default: 0] += 1
            let card = byId[id] ?? Card(id: id, term: "", definition: "")
            queue.append(
                makeQuestion(s, card, p.stage[id] ?? 0, pool, questionId(s.round, kind, id, asked[id] ?? 1), rng))
            p.repeats = p.lastAt[id] != nil ? p.repeats + 1 : 0
            p.lastAt[id] = t
            switch kind {
            case .review: p.reviewDue.removeAll { $0 == id }
            case .recheck: p.recheckDue.removeAll { $0 == id }
            case .learn: p.stage[id] = min((p.stage[id] ?? 0) + 1, masteredStage)
            }
        }
        if s.review != nil { s.review?.due = p.reviewDue }
        if s.recheck != nil { s.recheck?.due = p.recheckDue }
        return queue
    }

    /// After an answer (or a correction) the card's later questions in this round follow its
    /// stage: learning questions of a mastered card go, the others are asked at the new stage
    /// (`followStage`).
    private static func followStage(_ s: inout LearnState, _ id: String) {
        let mastered = (s.stage[id] ?? 0) >= masteredStage
        let state = s
        s.queue = s.queue
            .filter { $0.cardId != id || !mastered || isReviewQuestion($0.qid) || isRecheckQuestion($0.qid) }
            .map { $0.cardId == id ? retype(state, $0) : $0 }
    }

    /// A card mastered by a right answer after it was answered wrong in this session waits for
    /// its recheck (unless one is queued already) (`noteRecheck`).
    private static func noteRecheck(_ s: inout LearnState, _ id: String) {
        guard var recheck = s.recheck, (s.stage[id] ?? 0) >= masteredStage, (s.misses[id] ?? 0) > 0 else { return }
        if recheck.due.contains(id) || s.queue.contains(where: { $0.cardId == id && isRecheckQuestion($0.qid) }) {
            return
        }
        recheck.due.append(id)
        s.recheck = recheck
    }

    /// Cards by when they were last answered, the longest ago (or never) first; ties keep their
    /// order.
    private static func mostOverdueFirst(_ ids: [String], progress: ProgressMap) -> [String] {
        ids.enumerated()
            .sorted { a, b in
                let ta = progress[a.element]?.lastAnsweredAt ?? -Double.infinity
                let tb = progress[b.element]?.lastAnsweredAt ?? -Double.infinity
                return ta != tb ? ta < tb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The question `q` asked at its card's current stage (like makeQuestion: multiple choice at
    /// stage 0 until solved, else written), using the options it already holds. Keeps qid and ask.
    private static func retype(_ s: LearnState, _ q: LearnQueueQuestion) -> LearnQueueQuestion {
        let options = q.type == .mc ? q.choices : q.retryChoices
        let canMc = s.learn.mc && (options?.count ?? 0) >= 2
        let type: QuestionType =
            mcStage(s, q.cardId, s.stage[q.cardId] ?? 0)
            ? (canMc ? .mc : .written) : (s.learn.written || !canMc ? .written : .mc)
        if type == q.type { return q }
        return LearnQueueQuestion(
            qid: q.qid, cardId: q.cardId, type: type, ask: q.ask, choices: type == .mc ? options : nil,
            retryChoices: q.retryChoices ?? (q.type == .mc ? q.choices : nil))
    }

    /// Whether `ask` is a side the direction `answerWith` asks.
    private static func asks(_ answerWith: AnswerWith, _ ask: AskSide) -> Bool {
        switch answerWith {
        case .both: true
        case .term: ask == .term
        case .definition: ask == .definition
        }
    }

    /// The queued questions asked with the session's direction and question types (`setOptions`),
    /// each at the stage it was planned for: the card's stage now, one higher after each learning
    /// question of the card before it (like `planRound`). A question keeps its side when the
    /// direction still asks it, and its options where it has them; `typesChanged`: the question
    /// types were switched (else only questions with another side change).
    private static func requestion(_ s: inout LearnState, _ cards: [Card], _ rng: RNG, typesChanged: Bool) {
        let all = cardList(cards)
        var byId: [String: Card] = [:]
        for card in all where byId[card.id] == nil { byId[card.id] = card }
        let pool = ChoicePool(cardList(all.filter(askable)))
        var planned = s.stage
        let state = s
        s.queue = s.queue.map { q in
            let stage = planned[q.cardId] ?? 0
            if !isReviewQuestion(q.qid) && !isRecheckQuestion(q.qid) {
                planned[q.cardId] = min(stage + 1, masteredStage)
            }
            let keepsSide = asks(state.answerWith, q.ask)
            guard !keepsSide || typesChanged else { return q }
            guard let card = byId[q.cardId] else { return q }
            let ask = keepsSide ? q.ask : pickAsk(state.answerWith, rng)
            var choices = ask == q.ask ? (q.choices ?? q.retryChoices) : nil
            var retry = ask == q.ask ? q.retryChoices : nil
            if state.learn.mc && (choices?.count ?? 0) < 2 {
                choices = buildChoices(pool, card: card, ask: ask, rng: rng)
                retry = nil
            }
            let canMc = state.learn.mc && (choices?.count ?? 0) >= 2
            if canMc && retry == nil { retry = buildChoices(pool, card: card, ask: ask, rng: rng) }
            let type: QuestionType =
                mcStage(state, q.cardId, stage)
                ? (canMc ? .mc : .written) : (state.learn.written || !canMc ? .written : .mc)
            return LearnQueueQuestion(
                qid: q.qid, cardId: q.cardId, type: type, ask: ask, choices: type == .mc ? choices : nil,
                retryChoices: canMc ? retry : nil)
        }
    }

    /// A smaller round size ends this round sooner (`setOptions`): the questions past it go, the
    /// first queued one (asked now) stays. Repetition questions and rechecks taken out wait again,
    /// first in line; learning questions come back by themselves in the next rounds.
    private static func shortenRound(_ s: inout LearnState) {
        let room = max(1, s.learn.roundSize - s.roundLog.count)
        guard s.queue.count > room else { return }
        let dropped = s.queue[room...]
        s.queue.removeSubrange(room...)
        let reviews = dropped.filter { isReviewQuestion($0.qid) }.map(\.cardId)
        let rechecks = dropped.filter { isRecheckQuestion($0.qid) }.map(\.cardId)
        if var review = s.review, !reviews.isEmpty {
            review.due = uniqueIds(reviews + review.due)
            s.review = review
        }
        if var recheck = s.recheck, !rechecks.isEmpty {
            recheck.due = uniqueIds(rechecks + recheck.due)
            s.recheck = recheck
        }
    }

    /// Each id once, the first occurrence wins.
    private static func uniqueIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Internals: transitions (on the private copy)

    private static func counts(of s: LearnState) -> Counts {
        var fresh = 0
        var mastered = 0
        for id in s.order {
            let stage = s.stage[id] ?? 0
            if stage >= masteredStage {
                mastered += 1
            } else if stage == 0 && s.seen[id] != true {
                fresh += 1
            }
        }
        let total = s.order.count
        return Counts(
            fresh: fresh, learning: total - fresh - mastered, mastered: mastered, total: total,
            progress: total == 0 ? 0 : Double(mastered) / Double(total))
    }

    private static func allMastered(_ s: LearnState) -> Bool {
        s.order.allSatisfy { (s.stage[$0] ?? 0) >= masteredStage }
    }

    /// Repetition questions are queued or still to come for cards that are still mastered.
    private static func reviewPending(_ s: LearnState) -> Bool {
        guard let review = s.review else { return false }
        return s.queue.contains { isReviewQuestion($0.qid) }
            || review.due.contains { (s.stage[$0] ?? 0) >= masteredStage }
    }

    /// Rechecks are queued or still to come for cards that are still mastered.
    private static func recheckPending(_ s: LearnState) -> Bool {
        guard let recheck = s.recheck else { return false }
        return s.queue.contains { isRecheckQuestion($0.qid) }
            || recheck.due.contains { (s.stage[$0] ?? 0) >= masteredStage }
    }

    /// The session's goal is reached: everything mastered, every repetition question and recheck
    /// asked.
    private static func isComplete(_ s: LearnState) -> Bool {
        allMastered(s) && !reviewPending(s) && !recheckPending(s)
    }

    /// Adds active time since the last update; gaps longer than `idleGapMs` (pause, sleeping
    /// laptop, resuming another day) are not counted. The clock stops once the session is
    /// finished, and a non-finite `now` leaves it untouched.
    private static func advanceClock(_ s: inout LearnState, _ now: Double) {
        guard s.finishedAt == nil, now.isFinite else { return }
        let gap = now - s.updatedAt
        if gap > 0 && gap <= idleGapMs { s.elapsedMs += gap }
        s.updatedAt = now
    }

    /// Once nothing but rechecks is left to ask (every card mastered, no repetition question
    /// pending, only rechecks queued), a waiting recheck that would come fewer than MIN_GAP
    /// questions after the answer that mastered its card is dropped: asked right away it would
    /// check nothing.
    private static func dropLateRechecks(_ s: inout LearnState) {
        guard let recheck = s.recheck, !recheck.due.isEmpty, allMastered(s), !reviewPending(s) else { return }
        if s.queue.contains(where: { !isRecheckQuestion($0.qid) }) { return }
        let ahead = s.queue.count
        let due = recheck.due.filter { id in
            guard let last = s.lastAt[id] else { return true }
            return s.clock + ahead - last - 1 >= MIN_GAP
        }
        if due.count != recheck.due.count { s.recheck = LearnRecheck(due: due) }
    }

    private static func markFinished(_ s: inout LearnState, _ now: Double) {
        dropLateRechecks(&s)
        if s.finishedAt == nil && isComplete(s) { s.finishedAt = now.isFinite ? now : s.updatedAt }
    }

    /// markFinished for a change outside of answering (a removed card, progress from elsewhere):
    /// when the current round ends without a single answer, the session ended with the last
    /// closed round.
    private static func finishEarly(_ s: inout LearnState, _ now: Double) {
        markFinished(&s, now)
        if s.finishedAt != nil && s.queue.isEmpty && s.roundLog.isEmpty {
            s.round = s.rounds.last?.round ?? 1
        }
    }

    private static func roundIsClosed(_ s: LearnState) -> Bool {
        guard let last = s.rounds.last else { return false }
        return last.round == s.round
    }

    /// The round's tally; `cardIds` = the cards answered in it, in the order of their first answer.
    private static func archiveRound(_ s: inout LearnState) {
        var seen = Set<String>()
        s.rounds.append(
            LearnRoundRecord(
                round: s.round, answered: s.roundLog.count, correct: s.roundLog.count { $0.correct },
                cardIds: s.roundLog.map(\.cardId).filter { seen.insert($0).inserted }))
    }

    /// The set's askable cards without the removed one, and every card by id: the source of
    /// replacement options when a card is removed.
    private struct Refill {
        let pool: ChoicePool
        let byId: [String: Card]
    }

    /// The options of question `q` without card `id`. With `refill` its slot gets the most alike
    /// other valid wrong option when there is one, so a question keeps its number of options and
    /// the other options keep their places.
    private static func withoutOption(
        _ list: [Choice]?, _ id: String, _ q: LearnQueueQuestion, _ refill: Refill?, _ rng: RNG
    ) -> [Choice] {
        guard let list else { return [] }
        guard let at = list.firstIndex(where: { $0.cardId == id }) else { return list }
        var rest = list.filter { $0.cardId != id }
        guard let refill, let card = refill.byId[q.cardId] else { return rest }
        let present = Set(rest.map(\.cardId))
        // Keys of the remaining options, from the cards' current texts where they still exist.
        let taken = rest.map { c in
            textKey(refill.byId[c.cardId].map { Synonyms.answerSide($0, ask: q.ask) } ?? c.text)
        }
        let candidates = rankedDistractors(refill.pool, card, q.ask, rng, takenKeys: taken)
            .filter { !present.contains($0.cardId) }
        guard let best = candidates.first else { return rest }
        rest.insert(best, at: at)
        return rest
    }

    private static func dropCard(_ s: inout LearnState, _ id: String, refill: Refill?, rng: RNG) {
        s.order.removeAll { $0 == id }
        s.stage[id] = nil
        s.seen[id] = nil
        s.solved[id] = nil
        s.lastAt[id] = nil
        s.misses[id] = nil
        s.initiallyMastered.removeAll { $0 == id }
        if var review = s.review {
            review.due.removeAll { $0 == id }
            review.results[id] = nil
            s.review = review
        }
        s.recheck?.due.removeAll { $0 == id }
        // Its questions go; other questions lose it as an option (refilled when possible; mc
        // needs two options to stay mc).
        s.queue = s.queue.filter { $0.cardId != id }.map { q in
            let choices = withoutOption(q.choices, id, q, refill, rng)
            let retryChoices = withoutOption(q.retryChoices, id, q, refill, rng)
            let type: QuestionType = q.type == .mc && choices.count >= 2 ? .mc : .written
            return LearnQueueQuestion(
                qid: q.qid, cardId: q.cardId, type: type, ask: q.ask, choices: type == .mc ? choices : nil,
                retryChoices: retryChoices.count >= 2 ? retryChoices : nil)
        }
        // The current round forgets its answers (so the checkpoint never shows a deleted card);
        // closed rounds keep their tallies as history.
        let removed = s.roundLog.filter { $0.cardId == id }
        s.roundLog.removeAll { $0.cardId == id }
        s.answered = max(0, s.answered - removed.count)
        s.correct = min(s.answered, max(0, s.correct - removed.count { $0.correct }))
        for i in s.rounds.indices { s.rounds[i].cardIds.removeAll { $0 == id } }
        if s.last?.cardId == id { s.last = nil }
    }
}
