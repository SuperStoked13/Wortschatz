import Foundation

// Port of src/core/learn.js: the Learn-mode ("Lernen") engine with Quizlet Learn semantics.
//
// Every card in scope has a stage derived from its persistent streak: 0 = new or reset (asked as
// multiple choice), 1 = familiar (asked written), 2 = mastered (not asked any more). A correct
// answer moves the card up one stage, a wrong one sends it back to stage 0.
//
// The session works in rounds over an active batch of up to `roundSize` unmastered cards: one
// question per card in shuffled order, plus one retry at the end of the round for a card answered
// wrong. The next round drops the mastered cards from the batch and refills it (stage-1 cards
// first, then stage-0 cards in order) until every card in scope is mastered.
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
//   comparison with 0 and 1 the engine makes) and caps them at 2^53.
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
/// `.mc`; `retryChoices` (options for a re-queue after a miss) only when multiple choice is
/// possible. Absent keys are omitted, like JS.
public struct LearnQueueQuestion: Codable, Sendable, Equatable, Hashable {
    /// "<round>.1:<cardId>" (main question) or "<round>.2:<cardId>" (retry after a miss).
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
    /// The round's batch.
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

/// `state.review`: repetition questions (Wiederholungsfragen, an option of the Mac app that the
/// web app does not have). The cards that were mastered when the session started are asked once
/// more, a few per round next to the cards being learned (a whole round once nothing is left to
/// learn), the ones answered longest ago first. A wrong answer sends a card back to stage 0, so
/// it is learned again like any other.
public struct LearnReview: Codable, Sendable, Equatable, Hashable {
    /// Mastered cards still to be asked again, the most overdue first.
    public var due: [String]
    /// cardId → whether its repetition question was answered right (the first answer counts).
    public var results: [String: Bool]

    public init(due: [String] = [], results: [String: Bool] = [:]) {
        self.due = due
        self.results = results
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
    /// The current batch (≤ roundSize unmastered cards).
    public var active: [String]
    public var round: Int
    public var queue: [LearnQueueQuestion]
    /// cardId → true when its retry was queued this round.
    public var retried: [String: Bool]
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
    /// The repetition questions; nil without them (always for the web app's states). Encoded
    /// only when present, so states without them stay key for key those of the web app.
    public var review: LearnReview?

    public init(
        v: Int = 1, subset: StudySubset, answerWith: AnswerWith, learn: LearnSessionOptions, order: [String],
        stage: [String: Int], initiallyMastered: [String], seen: [String: Bool], active: [String], round: Int,
        queue: [LearnQueueQuestion], retried: [String: Bool], roundLog: [LearnRoundLogEntry],
        rounds: [LearnRoundRecord], answered: Int, correct: Int, misses: [String: Int], last: LearnLastAnswer?,
        startedAt: Double, updatedAt: Double, finishedAt: Double?, elapsedMs: Double, review: LearnReview? = nil
    ) {
        self.v = v
        self.subset = subset
        self.answerWith = answerWith
        self.learn = learn
        self.order = order
        self.stage = stage
        self.initiallyMastered = initiallyMastered
        self.seen = seen
        self.active = active
        self.round = round
        self.queue = queue
        self.retried = retried
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
    }

    /// A repaired state from any JSON value (`LearnEngine.copyState(json)`): never fails. Extra
    /// keys (like the `feedback` record the web app stores next to the state) are ignored.
    public init(json: JSONValue) {
        self = LearnEngine.copyState(json)
    }

    enum CodingKeys: String, CodingKey {
        case v, subset, answerWith, learn, order, stage, initiallyMastered, seen, active, round, queue, retried,
            roundLog, rounds, answered, correct, misses, last, startedAt, updatedAt, finishedAt, elapsedMs, review
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
        try c.encode(active, forKey: .active)
        try c.encode(round, forKey: .round)
        try c.encode(queue, forKey: .queue)
        try c.encode(retried, forKey: .retried)
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
    /// position plus distinct wrong answers of other (non-synonym) cards. [] when the card has
    /// no id or no answer text; a non-positive `n` means `MAX_CHOICES`.
    public static func buildChoices(
        _ cards: [Card], card: Card, ask: AskSide, rng: RNG = systemRNG(), n: Int = MAX_CHOICES
    ) -> [Choice] {
        guard !card.id.isEmpty else { return [] }
        let correctText = JSCompat.trim(Synonyms.answerSide(card, ask: ask))
        if TextNormalizer.normalizeBasic(correctText).isEmpty { return [] }
        let size = n >= 1 ? n : MAX_CHOICES
        let correct = Choice(cardId: card.id, text: correctText)
        if size == 1 { return [correct] }

        let candidates = distractors(cardList(cards), card, ask)
        var choices = Array(shuffled(candidates, rng).prefix(size - 1))
        // The correct option's position is uniform over all slots.
        choices.insert(correct, at: randomIndex(rng, choices.count + 1))
        return choices
    }

    // MARK: - Creation

    /// min(streak, 2) of the card's progress.
    public static func stageFromProgress(_ progress: CardProgress?) -> Int {
        min(Mastery.normalizeProgress(progress).streak, masteredStage)
    }

    /// `createLearn(cards, { answerWith, learn }, { subset, progress, rng, now })`.
    ///
    /// Cards without an id, repeated ids (the first one wins) and cards with an empty side are
    /// skipped; options come from every askable card of `cards`, not only from the scope. A
    /// non-finite `now` becomes 0. `retype` is a UI option and not part of the state.
    /// `review` (Mac only) adds repetition questions for the cards mastered already
    /// (`LearnReview`); without it the session is the web app's, rng draw for rng draw.
    public static func createLearn(
        _ cards: [Card], answerWith: AnswerWith, learn: LearnOptions, subset: StudySubset = .all,
        progress: ProgressMap = [:], rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs(), review: Bool = false
    ) -> LearnState {
        let sub = normalizeSubset(subset)
        let selected = cardList(cards).filter { askable($0) && cardInSubset($0, sub, progress) }
        let order = shuffled(selected.map(\.id), rng)

        var stage: [String: Int] = [:]
        var seen: [String: Bool] = [:]
        for id in order {
            let p = progress[id]
            stage[id] = stageFromProgress(p)
            if Mastery.cardStatus(p) != .new { seen[id] = true }
        }

        let at = now.isFinite ? now : 0
        let mastered = order.filter { (stage[$0] ?? 0) >= masteredStage }
        var s = LearnState(
            v: 1, subset: sub, answerWith: answerWith, learn: normalizeLearn(learn), order: order, stage: stage,
            initiallyMastered: mastered, seen: seen, active: [], round: 1,
            queue: [], retried: [:], roundLog: [], rounds: [], answered: 0, correct: 0, misses: [:], last: nil,
            startedAt: at, updatedAt: at, finishedAt: nil, elapsedMs: 0,
            review: review ? LearnReview(due: mostOverdueFirst(mastered, progress: progress)) : nil)
        fillBatch(&s)
        let reviews = takeReviews(&s)
        s.queue = buildQueue(s, cards, rng, reviews: reviews)
        markFinished(&s, at)
        return s
    }

    /// `createLearn` with full study options (reads `answerWith` and `learn`).
    public static func createLearn(
        _ cards: [Card], options: StudyOptions, subset: StudySubset = .all, progress: ProgressMap = [:],
        rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs(), review: Bool = false
    ) -> LearnState {
        createLearn(
            cards, answerWith: options.answerWith, learn: options.learn, subset: subset, progress: progress, rng: rng,
            now: now, review: review)
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
            let id = jsString(v)
            if known.insert(id).inserted { order.append(id) }
        }
        func ids(_ v: JSONValue?) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for x in v?.arrayValue ?? [] where x != .null {
                let id = jsString(x)
                if known.contains(id) && seen.insert(id).inserted { out.append(id) }
            }
            return out
        }
        func knownId(_ v: JSONValue?) -> String? {
            guard let v, v != .null else { return nil }
            let id = jsString(v)
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

        let learnSrc = src["learn"]?.objectValue ?? [:]
        let roundSize = learnSrc["roundSize"]?.finiteNumber.map { Int(max(-1, min($0.rounded(.down), 1e15))) } ?? 0
        let answered = countValue(src["answered"])
        let startedAt = src["startedAt"]?.finiteNumber ?? 0
        return LearnState(
            v: 1, subset: StudySubset(json: src["subset"] ?? .null),
            answerWith: src["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:)) ?? .term,
            learn: normalizeLearn(
                roundSize: roundSize, mc: learnSrc["mc"] != .bool(false), written: learnSrc["written"] != .bool(false)),
            order: order, stage: stage, initiallyMastered: ids(src["initiallyMastered"]), seen: trueMap(src["seen"]),
            active: ids(src["active"]), round: round, queue: queue, retried: trueMap(src["retried"]),
            roundLog: roundLog, rounds: rounds, answered: answered, correct: min(answered, countValue(src["correct"])),
            misses: misses, last: last, startedAt: startedAt, updatedAt: src["updatedAt"]?.finiteNumber ?? startedAt,
            finishedAt: src["finishedAt"]?.numberValue, elapsedMs: max(0, src["elapsedMs"]?.finiteNumber ?? 0),
            review: review)
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
            seen: state.seen.filter { known.contains($0.key) && $0.value }, active: ids(state.active), round: round,
            queue: queue, retried: state.retried.filter { known.contains($0.key) && $0.value },
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
            })
    }

    // MARK: - Asking and answering

    /// The question to ask now, nil when the round is over.
    public static func current(_ state: LearnState) -> Question? {
        guard let q = copyState(state).queue.first else { return nil }
        return publicQuestion(q)
    }

    /// Answers the current question (no-op when the round is over). A miss is asked once more
    /// at the end of the round, as multiple choice when possible.
    public static func answer(_ state: LearnState, correct: Bool, now: Double = TimeUtil.nowMs()) -> LearnState {
        var s = copyState(state)
        guard let q = s.queue.first else { return s }
        advanceClock(&s, now)
        let id = q.cardId
        let stageBefore = s.stage[id] ?? 0
        let stageAfter = correct ? min(stageBefore + 1, masteredStage) : 0
        s.stage[id] = stageAfter
        s.seen[id] = true
        s.answered += 1
        if correct {
            s.correct += 1
        } else {
            s.misses[id, default: 0] += 1
        }
        s.queue.removeFirst()
        s.roundLog.append(
            LearnRoundLogEntry(qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: correct, stageAfter: stageAfter))
        s.last = LearnLastAnswer(qid: q.qid, cardId: id, type: q.type, ask: q.ask, correct: correct, stageBefore: stageBefore)

        if !correct && s.retried[id] != true {
            s.retried[id] = true
            var retry = LearnQueueQuestion(qid: retryQid(s.round, id), cardId: id, type: .written, ask: q.ask)
            if s.learn.mc, let options = q.retryChoices {
                retry.type = .mc
                retry.choices = options
            }
            s.queue.append(retry)
        }
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
    /// stageBefore + 1 and its retry in this round is dropped. Idempotent; a no-op after
    /// `nextRound`.
    public static func override(_ state: LearnState, now: Double = TimeUtil.nowMs()) -> LearnState {
        var s = copyState(state)
        guard let l = s.last, !l.correct else { return s }
        advanceClock(&s, now)
        let id = l.cardId
        let stageAfter = min(l.stageBefore + 1, masteredStage)
        s.stage[id] = stageAfter
        s.correct = min(s.answered, s.correct + 1)
        s.misses[id] = max(0, (s.misses[id] ?? 0) - 1)
        if let i = s.roundLog.lastIndex(where: { $0.cardId == id && ($0.qid == nil || $0.qid == l.qid) }) {
            s.roundLog[i].correct = true
            s.roundLog[i].stageAfter = stageAfter
        }
        let before = s.queue.count
        s.queue.removeAll { $0.cardId == id }
        if s.queue.count < before { s.retried[id] = nil }
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

    /// Closes the finished round into `rounds`, drops mastered cards from the batch, refills it
    /// and builds the next round's questions. When every card is mastered the final round is
    /// closed and the session stays finished (its roundLog is kept for the checkpoint). No-op
    /// mid-round. Scope cards missing from `cards` (deleted) are removed; nil keeps every card
    /// (JS: a non-array `cards`) and builds written questions only.
    public static func nextRound(
        _ state: LearnState, cards: [Card]?, rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs()
    ) -> LearnState {
        var s = copyState(state)
        if !s.queue.isEmpty { return s }
        if let cards {
            let present = Set(cardList(cards).map(\.id))
            for id in s.order where !present.contains(id) { dropCard(&s, id, refill: nil, rng: rng) }
        }
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
        s.retried = [:]
        s.last = nil
        fillBatch(&s)
        let reviews = takeReviews(&s)
        s.queue = buildQueue(s, cards ?? [], rng, reviews: reviews)
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
            .prefix(10)
            .map(\.card)
        return FinalStats(
            total: total, mastered: mastered, alreadyMastered: s.initiallyMastered.count, rounds: rounds,
            answered: s.answered, accuracy: s.answered == 0 ? 0 : Double(s.correct) / Double(s.answered),
            elapsedMs: s.elapsedMs, hardest: Array(hardest))
    }

    // MARK: - Repetition questions

    /// Whether question `qid` is a repetition question ("<round>.3:<cardId>").
    public static func isReviewQuestion(_ qid: String) -> Bool {
        guard let colon = qid.firstIndex(of: ":") else { return false }
        let head = qid[..<colon]
        guard head.hasSuffix(".3") else { return false }
        let round = head.dropLast(2).unicodeScalars
        return !round.isEmpty && round.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    /// How many repetition questions a round asks next to the cards being learned.
    public static func reviewsPerRound(_ roundSize: Int) -> Int {
        max(1, roundSize / 3)
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

    /// Removes a card from the session (deleted mid-session): its stage, batch slot, questions,
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
            refill = Refill(pool: all.filter { $0.id != cardId && askable($0) }, byId: byId)
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

    // MARK: - Shared progress
    //
    // Learn and Write record every answer in the same CardProgress, which is the source of truth:
    // a card's stage is min(streak, 2) and it counts as seen once it was ever answered. Every Learn
    // transition keeps that true by itself; answers given elsewhere (Write mode, another window)
    // are brought in with syncProgress().

    /// Whether every card's stage and seen flag match `progress` (always true when finished: a
    /// finished session keeps its result).
    public static func matchesProgress(_ state: LearnState, progress: ProgressMap) -> Bool {
        let s = copyState(state)
        if s.finishedAt != nil { return true }
        return s.order.allSatisfy { id in
            let p = progress[id]
            return s.stage[id] == stageFromProgress(p) && (s.seen[id] == true) == (Mastery.cardStatus(p) != .new)
        }
    }

    /// Brings the session in line with `progress` (answers given in Write mode or elsewhere):
    /// every stage becomes min(streak, 2) and `seen` follows whether the card was ever answered.
    /// A card that is mastered now leaves the batch and this round's queue; a card whose stage
    /// changed otherwise keeps its queued questions, switched to the type of its new stage; a card
    /// no longer mastered is studied again from the next round on. A finished session is left as
    /// it is.
    public static func syncProgress(_ state: LearnState, progress: ProgressMap, now: Double = TimeUtil.nowMs())
        -> LearnState
    {
        var s = copyState(state)
        if s.finishedAt != nil { return s }
        var changed: [String] = []
        for id in s.order {
            let p = progress[id]
            let stage = stageFromProgress(p)
            if stage != s.stage[id] {
                s.stage[id] = stage
                changed.append(id)
            }
            s.seen[id] = Mastery.cardStatus(p) == .new ? nil : true
        }
        for id in changed {
            if (s.stage[id] ?? 0) >= masteredStage {
                s.active.removeAll { $0 == id }
                s.queue.removeAll { $0.cardId == id }
            } else {
                s.initiallyMastered.removeAll { $0 == id }
                s.queue = s.queue.map { $0.cardId == id ? retype(s, $0) : $0 }
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

    /// JS `String(v)` for ids read from JSON.
    private static func jsString(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case let .bool(b): b ? "true" : "false"
        case let .number(n): JSCompat.numberToString(n)
        case let .string(s): s
        case let .array(a): a.map { $0 == .null ? "" : jsString($0) }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }

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

    /// Integer in [0, n) from the rng, clamped so a misbehaving rng never breaks an index.
    private static func randomIndex(_ rng: RNG, _ n: Int) -> Int {
        let r = (rng() * Double(n)).rounded(.down)
        if !(r >= 0) { return 0 }
        if r > Double(n - 1) { return n - 1 }
        return Int(r)
    }

    /// Fisher–Yates on a copy, consuming `rng` like the JS.
    private static func shuffled<T>(_ list: [T], _ rng: RNG) -> [T] {
        var a = list
        var i = a.count - 1
        while i > 0 {
            a.swapAt(i, randomIndex(rng, i + 1))
            i -= 1
        }
        return a
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

    /// Possible wrong options for `card` asked on `side`, in `list` order (list: `cardList`
    /// output): other cards' answer texts that are non-empty, distinct, differ from the correct
    /// answer and share none of its alternatives, from cards that are no synonyms of `card`.
    /// Texts whose key is in `takenKeys` are skipped too.
    private static func distractors(_ list: [Card], _ card: Card, _ side: AskSide, takenKeys: [JSText] = [])
        -> [Choice]
    {
        let correctText = JSCompat.trim(Synonyms.answerSide(card, ask: side))
        // Synonym cards (same prompt) would make their answer correct too.
        let synonyms = Set(Synonyms.findSynonymCards(list, card: card, ask: side).map(\.id))
        let correctKeys = answerKeys(correctText)
        var usedKeys = Set(takenKeys)
        usedKeys.insert(textKey(correctText))
        var out: [Choice] = []
        for other in list where other.id != card.id && !synonyms.contains(other.id) {
            let text = JSCompat.trim(Synonyms.answerSide(other, ask: side))
            let key = textKey(text)
            if key.isEmpty || usedKeys.contains(key) { continue }
            // An option sharing an alternative with the correct answer would be correct as well.
            if !answerKeys(text).isDisjoint(with: correctKeys) { continue }
            usedKeys.insert(key)
            out.append(Choice(cardId: other.id, text: text))
        }
        return out
    }

    /// A stored option list: each non-empty card id once; kept only with at least two options
    /// including the asked card's.
    private static func normChoices(_ v: JSONValue?, _ cardId: String) -> [Choice]? {
        guard let list = v?.arrayValue else { return nil }
        var ids = Set<String>()
        var out: [Choice] = []
        for c in list {
            guard let o = c.objectValue, let raw = o["cardId"], raw != .null, raw != .string("") else { continue }
            let id = jsString(raw)
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

    private static func mainQid(_ round: Int, _ cardId: String) -> String { "\(round).1:\(cardId)" }
    private static func retryQid(_ round: Int, _ cardId: String) -> String { "\(round).2:\(cardId)" }
    private static func reviewQid(_ round: Int, _ cardId: String) -> String { "\(round).3:\(cardId)" }

    private static func publicQuestion(_ q: LearnQueueQuestion) -> Question {
        Question(qid: q.qid, cardId: q.cardId, type: q.type, ask: q.ask, choices: q.type == .mc ? q.choices : nil)
    }

    private static func pickAsk(_ answerWith: AnswerWith, _ rng: RNG) -> AskSide {
        switch answerWith {
        case .term: .term
        case .definition: .definition
        case .both: randomIndex(rng, 2) == 0 ? .term : .definition
        }
    }

    /// Stage 0 → multiple choice, stage 1 → written; a disabled type falls back to the other one,
    /// and multiple choice needs at least two options. `retryChoices` holds the options for a
    /// re-queue after a wrong answer, which is always asked at stage 0.
    private static func makeQuestion(_ s: LearnState, _ card: Card, _ pool: [Card], _ qid: String, _ rng: RNG)
        -> LearnQueueQuestion
    {
        let ask = pickAsk(s.answerWith, rng)
        let choices = s.learn.mc ? buildChoices(pool, card: card, ask: ask, rng: rng) : []
        let canMc = choices.count >= 2
        let type: QuestionType =
            (s.stage[card.id] ?? 0) == 0 ? (canMc ? .mc : .written) : (s.learn.written || !canMc ? .written : .mc)
        var q = LearnQueueQuestion(qid: qid, cardId: card.id, type: type, ask: ask)
        if type == .mc { q.choices = choices }
        if canMc { q.retryChoices = buildChoices(pool, card: card, ask: ask, rng: rng) }
        return q
    }

    /// Keeps the batch's unmastered cards and refills it up to roundSize: stage-1 cards first,
    /// then stage-0 cards, each in `order`.
    private static func fillBatch(_ s: inout LearnState) {
        let inOrder = Set(s.order)
        s.active = s.active.filter { inOrder.contains($0) && (s.stage[$0] ?? 0) < masteredStage }
        var inBatch = Set(s.active)
        for want in [1, 0] {
            for id in s.order {
                if s.active.count >= s.learn.roundSize { return }
                if !inBatch.contains(id) && s.stage[id] == want {
                    s.active.append(id)
                    inBatch.insert(id)
                }
            }
        }
    }

    /// The round's questions: one per card of the batch in shuffled order, with the repetition
    /// questions `reviews` mixed in among them.
    private static func buildQueue(_ s: LearnState, _ cards: [Card], _ rng: RNG, reviews: [String] = [])
        -> [LearnQueueQuestion]
    {
        let all = cardList(cards)
        var byId: [String: Card] = [:]
        for card in all { byId[card.id] = card }
        let pool = all.filter(askable)
        func question(_ id: String, _ qid: String) -> LearnQueueQuestion {
            makeQuestion(s, byId[id] ?? Card(id: id, term: "", definition: ""), pool, qid, rng)
        }
        if reviews.isEmpty {
            return shuffled(s.active, rng).map { question($0, mainQid(s.round, $0)) }
        }
        let entries = s.active.map { (id: $0, isReview: false) } + reviews.map { (id: $0, isReview: true) }
        return shuffled(entries, rng).map { e in
            question(e.id, e.isReview ? reviewQid(s.round, e.id) : mainQid(s.round, e.id))
        }
    }

    /// Takes the next round's repetition questions off `review.due`: a few next to the cards
    /// being learned (`reviewsPerRound`), a whole round once nothing is left to learn. Cards that
    /// are no longer mastered (answered wrong elsewhere) are learned instead and leave the list.
    private static func takeReviews(_ s: inout LearnState) -> [String] {
        guard var review = s.review else { return [] }
        let inOrder = Set(s.order)
        review.due.removeAll { !inOrder.contains($0) || (s.stage[$0] ?? 0) < masteredStage }
        let count = s.active.isEmpty ? s.learn.roundSize : reviewsPerRound(s.learn.roundSize)
        let picks = Array(review.due.prefix(count))
        review.due.removeFirst(picks.count)
        s.review = review
        return picks
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
    /// stage 0, written at stage 1), using the options it already holds. Keeps qid and ask.
    private static func retype(_ s: LearnState, _ q: LearnQueueQuestion) -> LearnQueueQuestion {
        let options = q.type == .mc ? q.choices : q.retryChoices
        let canMc = s.learn.mc && (options?.count ?? 0) >= 2
        let type: QuestionType =
            (s.stage[q.cardId] ?? 0) == 0 ? (canMc ? .mc : .written) : (s.learn.written || !canMc ? .written : .mc)
        if type == q.type { return q }
        return LearnQueueQuestion(
            qid: q.qid, cardId: q.cardId, type: type, ask: q.ask, choices: type == .mc ? options : nil,
            retryChoices: q.retryChoices ?? (q.type == .mc ? q.choices : nil))
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

    /// The session's goal is reached: everything mastered, every repetition question asked.
    private static func isComplete(_ s: LearnState) -> Bool {
        allMastered(s) && !reviewPending(s)
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

    private static func markFinished(_ s: inout LearnState, _ now: Double) {
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

    private static func archiveRound(_ s: inout LearnState) {
        s.rounds.append(
            LearnRoundRecord(
                round: s.round, answered: s.roundLog.count, correct: s.roundLog.count { $0.correct },
                cardIds: s.active))
    }

    /// The set's askable cards without the removed one, and every card by id: the source of
    /// replacement options when a card is removed.
    private struct Refill {
        let pool: [Card]
        let byId: [String: Card]
    }

    /// The options of question `q` without card `id`. With `refill` its slot gets another valid
    /// wrong option when there is one, so a question keeps its number of options and the other
    /// options keep their places.
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
        let candidates = distractors(refill.pool, card, q.ask, takenKeys: taken).filter { !present.contains($0.cardId) }
        if candidates.isEmpty { return rest }
        rest.insert(candidates[randomIndex(rng, candidates.count)], at: at)
        return rest
    }

    private static func dropCard(_ s: inout LearnState, _ id: String, refill: Refill?, rng: RNG) {
        s.order.removeAll { $0 == id }
        s.stage[id] = nil
        s.seen[id] = nil
        s.retried[id] = nil
        s.misses[id] = nil
        s.initiallyMastered.removeAll { $0 == id }
        s.active.removeAll { $0 == id }
        if var review = s.review {
            review.due.removeAll { $0 == id }
            review.results[id] = nil
            s.review = review
        }
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
