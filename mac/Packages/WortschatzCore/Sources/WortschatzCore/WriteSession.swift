import Foundation

// Port of src/core/session.js: the Write-mode session engine with Quizlet "Write" semantics.
//
// Round 1 asks every question once. A missed question is not retried within the same round; the
// next round contains only the questions missed in the previous round. This repeats until every
// question has been answered correctly once.
//
// Every function takes a `SessionState` and returns a NEW state (value semantics, inputs are never
// changed). Like the JS, each function first repairs its input (`copyState`), so states restored
// from storage or built by hand never crash the engine. Randomness comes from an injected `RNG`
// that is consumed in exactly the order of the JS (one Fisher–Yates pass when the session is
// created and one per new round), so seeded runs replay the web app's sessions bit for bit
// (checked against Parity/gen-session.js).
//
// Known differences to the JS, all limited to states the web app never writes:
// - Ids are compared with Swift `String` equality (Unicode canonical equivalence); JS compares
//   UTF-16 code units. Card ids are ASCII `uid()`s, so this never matters in practice.
// - Counts are `Int`. `copyState(_: JSONValue)` rounds fractional counts up (which keeps every
//   comparison with 0 and 1 the engine makes) and caps them at 2^53.
// - Without shuffling, a new round is sorted by `order`; a qid missing from `order` (only possible
//   in a hand-edited state) goes last instead of following JS's engine-specific NaN ordering.

/// A Write question (`state.questions[qid]` and the result of `current`). `qid` is
/// "<cardId>:t" (ask term) or "<cardId>:d" (ask definition).
public struct SessionQuestion: Codable, Sendable, Equatable, Hashable {
    public var qid: String
    public var cardId: String
    public var ask: AskSide

    public init(qid: String, cardId: String, ask: AskSide) {
        self.qid = qid
        self.cardId = cardId
        self.ask = ask
    }
}

/// `state.setOptions`.
public struct SessionSetOptions: Codable, Sendable, Equatable, Hashable {
    public var answerWith: AnswerWith
    public var shuffle: Bool

    public init(answerWith: AnswerWith = .term, shuffle: Bool = true) {
        self.answerWith = answerWith
        self.shuffle = shuffle
    }
}

/// An answer of the current round (`state.roundAnswered[]`).
public struct SessionAnswer: Codable, Sendable, Equatable, Hashable {
    public var qid: String
    public var correct: Bool

    public init(qid: String, correct: Bool) {
        self.qid = qid
        self.correct = correct
    }
}

/// A closed round (`state.rounds[]`).
public struct SessionRound: Codable, Sendable, Equatable, Hashable {
    public var round: Int
    public var total: Int
    public var correct: Int
    public var incorrectQids: [String]

    public init(round: Int, total: Int, correct: Int, incorrectQids: [String]) {
        self.round = round
        self.total = total
        self.correct = correct
        self.incorrectQids = incorrectQids
    }
}

/// The JSON-serialisable Write session (`session:<setId>` in the web app), key for key.
/// `finishedAt` is encoded as explicit `null` while running.
///
/// Decoding uses the synthesized (strict) decoder; for stored or imported JSON use
/// `WriteSession.copyState(_:)` (or `init(json:)`), which repairs states like `copyState` in
/// session.js.
public struct SessionState: Codable, Sendable, Equatable, Hashable {
    /// Schema version (always 1).
    public var v: Int
    public var setOptions: SessionSetOptions
    public var subset: StudySubset
    /// qid → question.
    public var questions: [String: SessionQuestion]
    /// Every qid in asking order of round 1.
    public var order: [String]
    public var round: Int
    /// Remaining qids of the current round.
    public var queue: [String]
    public var roundAnswered: [SessionAnswer]
    public var rounds: [SessionRound]
    /// qids answered correctly once.
    public var done: [String]
    public var attempts: [String: Int]
    public var misses: [String: Int]
    public var firstTry: [String: Bool]
    /// Epoch ms.
    public var startedAt: Double
    public var updatedAt: Double
    public var finishedAt: Double?
    /// Active study time (gaps > 5 min are not counted).
    public var elapsedMs: Double

    public init(
        v: Int = 1, setOptions: SessionSetOptions, subset: StudySubset, questions: [String: SessionQuestion],
        order: [String], round: Int, queue: [String], roundAnswered: [SessionAnswer], rounds: [SessionRound],
        done: [String], attempts: [String: Int], misses: [String: Int], firstTry: [String: Bool], startedAt: Double,
        updatedAt: Double, finishedAt: Double?, elapsedMs: Double
    ) {
        self.v = v
        self.setOptions = setOptions
        self.subset = subset
        self.questions = questions
        self.order = order
        self.round = round
        self.queue = queue
        self.roundAnswered = roundAnswered
        self.rounds = rounds
        self.done = done
        self.attempts = attempts
        self.misses = misses
        self.firstTry = firstTry
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.elapsedMs = elapsedMs
    }

    /// A repaired state from any JSON value (`WriteSession.copyState(json)`): never fails.
    public init(json: JSONValue) {
        self = WriteSession.copyState(json)
    }

    enum CodingKeys: String, CodingKey {
        case v, setOptions, subset, questions, order, round, queue, roundAnswered, rounds, done, attempts, misses,
            firstTry, startedAt, updatedAt, finishedAt, elapsedMs
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(setOptions, forKey: .setOptions)
        try c.encode(subset, forKey: .subset)
        try c.encode(questions, forKey: .questions)
        try c.encode(order, forKey: .order)
        try c.encode(round, forKey: .round)
        try c.encode(queue, forKey: .queue)
        try c.encode(roundAnswered, forKey: .roundAnswered)
        try c.encode(rounds, forKey: .rounds)
        try c.encode(done, forKey: .done)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(misses, forKey: .misses)
        try c.encode(firstTry, forKey: .firstTry)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeNullable(finishedAt, forKey: .finishedAt)
        try c.encode(elapsedMs, forKey: .elapsedMs)
    }
}

/// Port of src/core/session.js: the Write-mode session engine with Quizlet "Write" semantics.
/// Every function takes a state and returns a NEW state; inputs are never mutated.
public enum WriteSession {
    public typealias Question = SessionQuestion

    /// Pauses between two actions longer than this are not counted as study time (`IDLE_GAP_MS`).
    public static let idleGapMs: Double = 5 * 60 * 1000

    /// `roundSummary(state).items[]`.
    public struct RoundSummaryItem: Codable, Sendable, Equatable, Hashable {
        public var qid: String
        public var cardId: String
        public var ask: AskSide
        public var correct: Bool

        public init(qid: String, cardId: String, ask: AskSide, correct: Bool) {
            self.qid = qid
            self.cardId = cardId
            self.ask = ask
            self.correct = correct
        }
    }

    /// `roundSummary(state)`.
    public struct RoundSummary: Codable, Sendable, Equatable, Hashable {
        public var round: Int
        public var total: Int
        public var correct: Int
        public var incorrect: Int
        public var items: [RoundSummaryItem]

        public init(round: Int, total: Int, correct: Int, incorrect: Int, items: [RoundSummaryItem]) {
            self.round = round
            self.total = total
            self.correct = correct
            self.incorrect = incorrect
            self.items = items
        }
    }

    /// `counters(state)` ("Verbleibend / Falsch / Richtig").
    public struct Counters: Codable, Sendable, Equatable, Hashable {
        public var remaining: Int
        public var correct: Int
        public var incorrect: Int
        public var total: Int
        public var round: Int
        /// done / total (0…1).
        public var progress: Double

        public init(remaining: Int, correct: Int, incorrect: Int, total: Int, round: Int, progress: Double) {
            self.remaining = remaining
            self.correct = correct
            self.incorrect = incorrect
            self.total = total
            self.round = round
            self.progress = progress
        }
    }

    /// `finalStats(state)`.
    public struct FinalStats: Codable, Sendable, Equatable, Hashable {
        public var total: Int
        public var firstTryCorrect: Int
        /// firstTryCorrect / total (0…1).
        public var accuracy: Double
        public var rounds: Int
        public var elapsedMs: Double
        /// Up to 10 cards with the most misses (both directions together).
        public var hardest: [MissedCard]
        /// Every card with a miss, in order of first appearance.
        public var missedCardIds: [String]

        public init(
            total: Int, firstTryCorrect: Int, accuracy: Double, rounds: Int, elapsedMs: Double, hardest: [MissedCard],
            missedCardIds: [String]
        ) {
            self.total = total
            self.firstTryCorrect = firstTryCorrect
            self.accuracy = accuracy
            self.rounds = rounds
            self.elapsedMs = elapsedMs
            self.hardest = hardest
            self.missedCardIds = missedCardIds
        }
    }

    // MARK: - Creation

    /// The question id of a card and side (`qidFor`): "<cardId>:t" or "<cardId>:d".
    public static func qid(cardId: String, ask: AskSide) -> String {
        "\(cardId):\(ask == .term ? "t" : "d")"
    }

    /// `createSession(cards, { answerWith, shuffle }, { subset, rng, now, progress })`.
    ///
    /// Cards without an id, repeated ids (the first one wins) and cards with an empty side are
    /// skipped; `progress` is only read by the `.learning` and `.missed` subsets. A non-finite
    /// `now` becomes 0. Shuffling consumes `rng` exactly like the JS.
    public static func createSession(
        _ cards: [Card], answerWith: AnswerWith, shuffle: Bool, subset: StudySubset = .all, rng: RNG = systemRNG(),
        now: Double = TimeUtil.nowMs(), progress: ProgressMap = [:]
    ) -> SessionState {
        let sub = normalizeSubset(subset)

        var seen = Set<String>()
        var selected: [Card] = []
        for card in cards {
            guard !card.id.isEmpty, seen.insert(card.id).inserted else { continue }
            // A card with an empty side cannot be asked meaningfully in either direction.
            guard hasText(card.term), hasText(card.definition) else { continue }
            if cardInSubset(card, sub, progress) { selected.append(card) }
        }

        // Unshuffled `.both`: every term question first, then every definition question, so a
        // card's two directions are never asked back to back.
        let sides: [AskSide] =
            switch answerWith {
            case .both: [.term, .definition]
            case .definition: [.definition]
            case .term: [.term]
            }
        var questions: [String: SessionQuestion] = [:]
        var order: [String] = []
        for ask in sides {
            for card in selected {
                let id = qid(cardId: card.id, ask: ask)
                questions[id] = SessionQuestion(qid: id, cardId: card.id, ask: ask)
                order.append(id)
            }
        }

        let at = now.isFinite ? now : 0
        let finalOrder = shuffle ? separateSiblings(shuffled(order, rng), questions) : order
        var zeros: [String: Int] = [:]
        for id in finalOrder { zeros[id] = 0 }
        return SessionState(
            v: 1, setOptions: SessionSetOptions(answerWith: answerWith, shuffle: shuffle), subset: sub,
            questions: questions, order: finalOrder, round: 1, queue: finalOrder, roundAnswered: [], rounds: [],
            done: [], attempts: zeros, misses: zeros, firstTry: [:], startedAt: at, updatedAt: at,
            finishedAt: finalOrder.isEmpty ? at : nil, elapsedMs: 0)
    }

    /// `createSession` with full study options (reads `answerWith` and `shuffle`).
    public static func createSession(
        _ cards: [Card], options: StudyOptions, subset: StudySubset = .all, rng: RNG = systemRNG(),
        now: Double = TimeUtil.nowMs(), progress: ProgressMap = [:]
    ) -> SessionState {
        createSession(
            cards, answerWith: options.answerWith, shuffle: options.shuffle, subset: subset, rng: rng, now: now,
            progress: progress)
    }

    // MARK: - Repair

    /// `copyState` of session.js on raw JSON: a defensive copy that repairs missing fields and
    /// drops references to unknown qids, so states restored from storage never crash the engine.
    /// Accepts any JSON; a non-object gives an empty state without questions (`isFinished`).
    public static func copyState(_ json: JSONValue) -> SessionState {
        let src = json.objectValue ?? [:]

        var questions: [String: SessionQuestion] = [:]
        for (key, value) in jsEntries(src["questions"]) {
            guard let q = value.objectValue, let cardId = q["cardId"], cardId != .null else { continue }
            let ask: AskSide = q["ask"]?.stringValue == "definition" ? .definition : .term
            questions[key] = SessionQuestion(qid: key, cardId: jsString(cardId), ask: ask)
        }

        func known(_ v: JSONValue?) -> String? {
            guard let qid = v?.stringValue, questions[qid] != nil else { return nil }
            return qid
        }
        func uniqueQids(_ v: JSONValue?) -> [String] {
            uniqued((v?.arrayValue ?? []).compactMap { known($0) })
        }
        func countMap(_ v: JSONValue?) -> [String: Int] {
            var out: [String: Int] = [:]
            for (key, value) in jsEntries(v) where questions[key] != nil { out[key] = countValue(value) }
            return out
        }
        func boolMap(_ v: JSONValue?) -> [String: Bool] {
            var out: [String: Bool] = [:]
            for (key, value) in jsEntries(v) where questions[key] != nil {
                if let b = value.boolValue { out[key] = b }
            }
            return out
        }

        let opts = src["setOptions"]?.objectValue ?? [:]
        let answerWith = opts["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:)) ?? .term
        let shuffle = opts["shuffle"] != .bool(false)

        let roundAnswered = (src["roundAnswered"]?.arrayValue ?? []).compactMap { entry -> SessionAnswer? in
            guard let a = entry.objectValue, let qid = known(a["qid"]) else { return nil }
            return SessionAnswer(qid: qid, correct: a["correct"] == .bool(true))
        }

        var rounds: [SessionRound] = []
        for entry in src["rounds"]?.arrayValue ?? [] {
            // Arrays pass JS's `typeof r === 'object'` filter and read like an empty object.
            let r: [String: JSONValue]
            switch entry {
            case let .object(o): r = o
            case .array: r = [:]
            default: continue
            }
            rounds.append(
                SessionRound(
                    round: r["round"]?.integerValue ?? rounds.count + 1, total: countValue(r["total"]),
                    correct: countValue(r["correct"]), incorrectQids: uniqueQids(r["incorrectQids"])))
        }

        let round = src["round"]?.integerValue.flatMap { $0 > 0 ? $0 : nil } ?? 1
        let startedAt = src["startedAt"]?.finiteNumber ?? 0
        return SessionState(
            v: 1, setOptions: SessionSetOptions(answerWith: answerWith, shuffle: shuffle),
            subset: StudySubset(json: src["subset"] ?? .null), questions: questions, order: uniqueQids(src["order"]),
            round: round, queue: uniqueQids(src["queue"]), roundAnswered: roundAnswered, rounds: rounds,
            done: uniqueQids(src["done"]), attempts: countMap(src["attempts"]), misses: countMap(src["misses"]),
            firstTry: boolMap(src["firstTry"]), startedAt: startedAt,
            updatedAt: src["updatedAt"]?.finiteNumber ?? startedAt, finishedAt: src["finishedAt"]?.numberValue,
            elapsedMs: max(0, src["elapsedMs"]?.finiteNumber ?? 0))
    }

    /// `copyState` of session.js on a typed state: questions are keyed by their own qid, every
    /// qid list keeps only known qids (each once), counts are at least 0, `round` at least 1 and
    /// timestamps finite. Every engine function applies it to its input first; it is idempotent.
    /// Counts and round numbers are also capped at ±2^53 (the JS safe-integer range), so that a
    /// hand-edited state cannot overflow `Int`.
    public static func copyState(_ state: SessionState) -> SessionState {
        var questions: [String: SessionQuestion] = [:]
        questions.reserveCapacity(state.questions.count)
        for (key, q) in state.questions { questions[key] = SessionQuestion(qid: key, cardId: q.cardId, ask: q.ask) }
        func uniqueQids(_ list: [String]) -> [String] {
            uniqued(list.filter { questions[$0] != nil })
        }
        func countMap(_ map: [String: Int]) -> [String: Int] {
            var out: [String: Int] = [:]
            for (key, n) in map where questions[key] != nil { out[key] = clampCount(n) }
            return out
        }

        let startedAt = state.startedAt.isFinite ? state.startedAt : 0
        return SessionState(
            v: 1, setOptions: state.setOptions, subset: normalizeSubset(state.subset), questions: questions,
            order: uniqueQids(state.order), round: state.round > 0 ? min(state.round, maxSafeInteger) : 1,
            queue: uniqueQids(state.queue), roundAnswered: state.roundAnswered.filter { questions[$0.qid] != nil },
            rounds: state.rounds.map {
                SessionRound(
                    round: min(max($0.round, -maxSafeInteger), maxSafeInteger), total: clampCount($0.total),
                    correct: clampCount($0.correct), incorrectQids: uniqueQids($0.incorrectQids))
            },
            done: uniqueQids(state.done), attempts: countMap(state.attempts), misses: countMap(state.misses),
            firstTry: state.firstTry.filter { questions[$0.key] != nil }, startedAt: startedAt,
            updatedAt: state.updatedAt.isFinite ? state.updatedAt : startedAt, finishedAt: state.finishedAt,
            elapsedMs: state.elapsedMs.isFinite ? max(0, state.elapsedMs) : 0)
    }

    // MARK: - Asking and answering

    /// The question to ask now, nil when the round is over.
    public static func current(_ state: SessionState) -> SessionQuestion? {
        let s = copyState(state)
        return s.queue.first.flatMap { s.questions[$0] }
    }

    /// Answers the current question (no-op when the round is over).
    public static func answer(_ state: SessionState, correct: Bool, now: Double = TimeUtil.nowMs()) -> SessionState {
        var s = copyState(state)
        guard let qid = s.queue.first else { return s }
        advanceClock(&s, now)
        let previous = s.attempts[qid] ?? 0
        s.attempts[qid] = previous + 1
        if previous == 0 { s.firstTry[qid] = correct }
        if correct {
            if !s.done.contains(qid) { s.done.append(qid) }
        } else {
            s.misses[qid, default: 0] += 1
        }
        s.queue.removeFirst()
        s.roundAnswered.append(SessionAnswer(qid: qid, correct: correct))
        markFinished(&s, now)
        return s
    }

    /// "Ich hatte recht": the incorrect answer of `qid` in the current round becomes correct.
    /// Also works right after `nextRound` for a miss of the just-closed round, as long as the qid
    /// has not been answered in the new round yet. Idempotent: anything else is a no-op.
    public static func override(_ state: SessionState, qid: String, now: Double = TimeUtil.nowMs()) -> SessionState {
        var s = copyState(state)
        guard s.questions[qid] != nil, !s.done.contains(qid) else { return s }

        if let idx = s.roundAnswered.lastIndex(where: { $0.qid == qid }) {
            if s.roundAnswered[idx].correct { return s }
            advanceClock(&s, now)
            s.roundAnswered[idx] = SessionAnswer(qid: qid, correct: true)
            markCorrect(&s, qid)
            if roundIsClosed(s) {
                let last = s.rounds.count - 1
                s.rounds[last].incorrectQids.removeAll { $0 == qid }
                s.rounds[last].correct = min(s.rounds[last].total, s.rounds[last].correct + 1)
            }
            markFinished(&s, now)
            return s
        }

        guard let lastRound = s.rounds.last, lastRound.round == s.round - 1, lastRound.incorrectQids.contains(qid)
        else { return s }
        advanceClock(&s, now)
        let last = s.rounds.count - 1
        s.rounds[last].incorrectQids.removeAll { $0 == qid }
        s.rounds[last].correct = min(lastRound.total, lastRound.correct + 1)
        s.queue.removeAll { $0 == qid }
        markCorrect(&s, qid)
        if s.queue.isEmpty && s.roundAnswered.isEmpty {
            // The new round lost its only questions: the session ended with the closed round.
            s.round = lastRound.round
        }
        markFinished(&s, now)
        return s
    }

    // MARK: - Rounds

    public static func isRoundOver(_ state: SessionState) -> Bool {
        copyState(state).queue.isEmpty
    }

    /// The current round's answers in order; `total` also counts the questions still queued.
    public static func roundSummary(_ state: SessionState) -> RoundSummary {
        let s = copyState(state)
        let items = s.roundAnswered.compactMap { a -> RoundSummaryItem? in
            guard let q = s.questions[a.qid] else { return nil }
            return RoundSummaryItem(qid: a.qid, cardId: q.cardId, ask: q.ask, correct: a.correct)
        }
        let correct = items.count { $0.correct }
        return RoundSummary(
            round: s.round, total: items.count + s.queue.count, correct: correct, incorrect: items.count - correct,
            items: items)
    }

    /// Closes the finished round into `rounds` and starts the next one with the questions missed
    /// in it. When nothing is left the session is finished instead; the closed round's answers
    /// stay in `roundAnswered` so its summary can still be shown. No-op while the round is still
    /// running (and once the round is closed).
    public static func nextRound(_ state: SessionState, rng: RNG = systemRNG(), now: Double = TimeUtil.nowMs())
        -> SessionState
    {
        var s = copyState(state)
        if !s.queue.isEmpty || roundIsClosed(s) { return s }
        advanceClock(&s, now)

        var incorrectQids: [String] = []
        for a in s.roundAnswered where !a.correct && !incorrectQids.contains(a.qid) { incorrectQids.append(a.qid) }
        let finished = allDone(s)
        if !s.roundAnswered.isEmpty {
            let answered = s.roundAnswered.count
            s.rounds.append(
                SessionRound(
                    round: s.round, total: answered, correct: answered - s.roundAnswered.count { !$0.correct },
                    incorrectQids: incorrectQids))
        }
        if finished {
            markFinished(&s, now)
            return s
        }

        let done = Set(s.done)
        var missed = incorrectQids.filter { !done.contains($0) }
        // Safety net for inconsistent restored states: any other open question joins the next round.
        for qid in s.order where !done.contains(qid) && !missed.contains(qid) { missed.append(qid) }
        s.queue = arrangeQueue(missed, s, rng)
        // A round without answers (only possible in a repaired state) is refilled, not counted.
        if !s.roundAnswered.isEmpty { s.round += 1 }
        s.roundAnswered = []
        return s
    }

    /// Every question has been answered correctly once (also true for a session without questions).
    public static func isFinished(_ state: SessionState) -> Bool {
        allDone(copyState(state))
    }

    // MARK: - Statistics

    /// "Verbleibend / Falsch / Richtig": `incorrect` counts the current round only, `correct`
    /// the whole session.
    public static func counters(_ state: SessionState) -> Counters {
        let s = copyState(state)
        let total = s.order.count
        return Counters(
            remaining: s.queue.count, correct: s.done.count, incorrect: s.roundAnswered.count { !$0.correct },
            total: total, round: s.round, progress: total == 0 ? 0 : Double(s.done.count) / Double(total))
    }

    public static func finalStats(_ state: SessionState) -> FinalStats {
        let s = copyState(state)
        let total = s.order.count
        let firstTryCorrect = s.order.count { s.firstTry[$0] == true }

        // Misses per card (both directions together), in order of first appearance.
        var cardOrder: [String] = []
        var byCard: [String: Int] = [:]
        for qid in s.order {
            guard let cardId = s.questions[qid]?.cardId else { continue }
            if byCard[cardId] == nil { cardOrder.append(cardId) }
            byCard[cardId, default: 0] += s.misses[qid] ?? 0
        }
        let missedCards = cardOrder.compactMap { cardId -> MissedCard? in
            let misses = byCard[cardId] ?? 0
            return misses > 0 ? MissedCard(cardId: cardId, misses: misses) : nil
        }
        let hardest = missedCards.enumerated()
            .sorted { x, y in
                x.element.misses != y.element.misses ? x.element.misses > y.element.misses : x.offset < y.offset
            }
            .prefix(10)
            .map(\.element)

        return FinalStats(
            total: total, firstTryCorrect: firstTryCorrect,
            accuracy: total == 0 ? 0 : Double(firstTryCorrect) / Double(total), rounds: total == 0 ? 0 : s.round,
            elapsedMs: s.elapsedMs, hardest: Array(hardest), missedCardIds: missedCards.map(\.cardId))
    }

    // MARK: - Changes

    /// Removes every question of a card (deleted mid-session), including its share of the
    /// closed rounds' tallies. Rounds left without any question are dropped. Unknown ids are a
    /// no-op.
    public static func removeCard(_ state: SessionState, cardId: String, now: Double = TimeUtil.nowMs()) -> SessionState {
        var s = copyState(state)
        let gone = Set(s.questions.compactMap { $0.value.cardId == cardId ? $0.key : nil })
        if gone.isEmpty { return s }
        advanceClock(&s, now)

        // Round 1 asked every question; round n asked exactly the misses of round n - 1.
        let previous = s.rounds
        var rounds = previous.enumerated().map { i, r -> SessionRound in
            var total = r.total
            var correct = r.correct
            for qid in gone where i == 0 || previous[i - 1].incorrectQids.contains(qid) {
                total -= 1
                if !r.incorrectQids.contains(qid) { correct -= 1 }
            }
            total = max(0, total)
            return SessionRound(
                round: r.round, total: total, correct: min(total, max(0, correct)),
                incorrectQids: r.incorrectQids.filter { !gone.contains($0) })
        }
        if let firstEmpty = rounds.firstIndex(where: { $0.total == 0 }) { rounds.removeSubrange(firstEmpty...) }
        s.rounds = rounds

        for qid in gone {
            s.questions[qid] = nil
            s.attempts[qid] = nil
            s.misses[qid] = nil
            s.firstTry[qid] = nil
        }
        s.order.removeAll { gone.contains($0) }
        s.queue.removeAll { gone.contains($0) }
        s.done.removeAll { gone.contains($0) }
        s.roundAnswered.removeAll { gone.contains($0.qid) }

        if s.queue.isEmpty && s.roundAnswered.isEmpty {
            // The current round has nothing left: fall back to the last round that still has content.
            s.round = s.rounds.last?.round ?? 1
        }
        markFinished(&s, now)
        return s
    }

    /// Advances the active-time clock.
    public static func tick(_ state: SessionState, now: Double = TimeUtil.nowMs()) -> SessionState {
        var s = copyState(state)
        advanceClock(&s, now)
        return s
    }

    // MARK: - Internals

    private static func hasText(_ s: String) -> Bool {
        s.unicodeScalars.contains { !JSCompat.isWhitespace($0) }
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

    /// Fisher–Yates on a copy (`shuffled`), consuming `rng` like the JS. Tolerates an rng
    /// returning values outside [0, 1) (or NaN).
    private static func shuffled(_ list: [String], _ rng: RNG) -> [String] {
        var a = list
        var i = a.count - 1
        while i > 0 {
            let r = (rng() * Double(i + 1)).rounded(.down)
            let j = !(r >= 0) ? 0 : r > Double(i) ? i : Int(r)
            a.swapAt(i, j)
            i -= 1
        }
        return a
    }

    /// With `.both` a card has two questions; avoid asking them back to back, which would give
    /// the answer away. Deterministic: only swaps/moves items, no randomness.
    private static func separateSiblings(_ qids: [String], _ questions: [String: SessionQuestion]) -> [String] {
        var a = qids
        func card(_ i: Int) -> String? { questions[a[i]]?.cardId }
        var i = 1
        while i < a.count {
            defer { i += 1 }
            let c = card(i)
            if c != card(i - 1) { continue }
            if let j = (i + 1..<a.count).first(where: { card($0) != c }) {
                a.swapAt(i, j)
                continue
            }
            // Last position: move the item to an earlier slot whose neighbours belong to other cards.
            if let p = (0..<i - 1).first(where: { ($0 == 0 || card($0 - 1) != c) && card($0) != c }) {
                let item = a.remove(at: i)
                a.insert(item, at: p)
            }
        }
        return a
    }

    private static func arrangeQueue(_ qids: [String], _ s: SessionState, _ rng: RNG) -> [String] {
        guard s.setOptions.shuffle else {
            var rank: [String: Int] = [:]
            for (i, qid) in s.order.enumerated() { rank[qid] = i }
            return qids.enumerated()
                .sorted { x, y in
                    let rx = rank[x.element] ?? .max
                    let ry = rank[y.element] ?? .max
                    return rx != ry ? rx < ry : x.offset < y.offset
                }
                .map(\.element)
        }
        return separateSiblings(shuffled(qids, rng), s.questions)
    }

    private static func allDone(_ s: SessionState) -> Bool {
        let done = Set(s.done)
        return s.order.allSatisfy { done.contains($0) }
    }

    /// Adds active time since the last update; gaps longer than `idleGapMs` (pause, sleeping
    /// laptop, resuming another day) are not counted. The clock stops once the session is
    /// finished, and a non-finite `now` leaves it untouched.
    private static func advanceClock(_ s: inout SessionState, _ now: Double) {
        guard s.finishedAt == nil, now.isFinite else { return }
        let gap = now - s.updatedAt
        if gap > 0 && gap <= idleGapMs { s.elapsedMs += gap }
        s.updatedAt = now
    }

    private static func markFinished(_ s: inout SessionState, _ now: Double) {
        if s.finishedAt == nil && allDone(s) { s.finishedAt = now.isFinite ? now : s.updatedAt }
    }

    private static func roundIsClosed(_ s: SessionState) -> Bool {
        guard let last = s.rounds.last else { return false }
        return last.round == s.round
    }

    private static func markCorrect(_ s: inout SessionState, _ qid: String) {
        if !s.done.contains(qid) { s.done.append(qid) }
        s.misses[qid] = max(0, (s.misses[qid] ?? 0) - 1)
        if (s.attempts[qid] ?? 0) <= 1 { s.firstTry[qid] = true }
    }

    /// Each element once, first occurrence wins (`[...new Set(list)]`).
    private static func uniqued(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// `Object.keys(v)` with values for anything JS treats as an object: an object's entries,
    /// an array's elements keyed "0", "1", …; nothing for other values.
    private static func jsEntries(_ v: JSONValue?) -> [(key: String, value: JSONValue)] {
        switch v {
        case let .object(o)?: o.map { (key: $0.key, value: $0.value) }
        case let .array(a)?: a.enumerated().map { (key: String($0.offset), value: $0.element) }
        default: []
        }
    }

    /// JS `String(v)`.
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

    /// `Math.max(0, finite(v, 0))` as a count: fractional values (never written by the web app)
    /// are rounded up, which keeps the engine's comparisons with 0 and 1 intact.
    private static func countValue(_ v: JSONValue?) -> Int {
        guard let n = v?.finiteNumber, n > 0 else { return 0 }
        return Int(min(n, Double(maxSafeInteger)).rounded(.up))
    }

    /// 2^53, the end of the JS safe-integer range.
    private static let maxSafeInteger = 9_007_199_254_740_992

    private static func clampCount(_ n: Int) -> Int { min(max(0, n), maxSafeInteger) }
}
