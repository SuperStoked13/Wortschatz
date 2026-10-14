import Foundation

// Port of src/screens/write-model.js: the pure helpers of Write mode. They build the question
// texts per direction, grade the main answer (synonym aware) and the copy step, decide whether a
// stored session is resumed (including a pending "Nicht ganz" screen) or its results are shown
// again, and format the results tile. The reducer in WriteFlow.swift is built on top of them.

extension WriteFlow {
    // MARK: - Question

    /// Everything the question card shows for one question (`questionInfo` in write-model.js).
    /// `ask == .term`: the definition is shown and the term typed (and vice versa).
    public struct Question: Codable, Sendable, Equatable, Hashable {
        public var qid: String
        public var cardId: String
        public var ask: AskSide
        /// The text shown to the learner.
        public var prompt: String
        /// The text the learner has to type.
        public var expected: String
        public var promptLang: Lang
        public var answerLang: Lang
        /// The label above the prompt: the prompt's language ("Französisch"), or "Definition" /
        /// "Begriff" when both sides share a language or the language is unknown.
        public var promptLabel: String
        /// "Antwort auf Französisch eingeben" (or "Antwort eingeben").
        public var placeholder: String
        /// The short form for narrow layouts: "Auf Französisch …".
        public var placeholderShort: String
        public var starred: Bool

        public init(
            qid: String, cardId: String, ask: AskSide, prompt: String, expected: String, promptLang: Lang,
            answerLang: Lang, promptLabel: String, placeholder: String, placeholderShort: String, starred: Bool
        ) {
            self.qid = qid
            self.cardId = cardId
            self.ask = ask
            self.prompt = prompt
            self.expected = expected
            self.promptLang = promptLang
            self.answerLang = answerLang
            self.promptLabel = promptLabel
            self.placeholder = placeholder
            self.placeholderShort = placeholderShort
            self.starred = starred
        }

        /// The question for the synonym check (`ExtendedSynonyms`).
        public var synonymQuery: SynonymQuery {
            SynonymQuery(prompt: prompt, expected: expected, promptLang: promptLang, answerLang: answerLang)
        }

        /// The engine question this info was built from.
        public var sessionQuestion: SessionQuestion { SessionQuestion(qid: qid, cardId: cardId, ask: ask) }
    }

    /// The named subsets a link or menu can ask for (`NAMED_SUBSETS`).
    public static let namedSubsets: [StudySubset] = [.all, .starred, .learning, .missed]

    /// `hasText`: a string with at least one non-whitespace character (JS `trim`).
    public static func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.unicodeScalars.contains { !JSCompat.isWhitespace($0) }
    }

    /// `isUsableCard`: a card can be asked only when both sides have text.
    public static func isUsableCard(_ card: Card?) -> Bool {
        guard let card else { return false }
        return hasText(card.term) && hasText(card.definition)
    }

    /// `questionInfo(set, card, q)`.
    public static func questionInfo(set: VocabSet, card: Card, question q: SessionQuestion) -> Question {
        questionInfo(termLang: set.termLang, defLang: set.defLang, card: card, question: q)
    }

    /// `questionInfo` for a set given by its languages.
    public static func questionInfo(termLang: Lang, defLang: Lang, card: Card, question q: SessionQuestion)
        -> Question
    {
        let askTerm = q.ask == .term
        let promptLang = askTerm ? defLang : termLang
        let answerLang = askTerm ? termLang : defLang
        let sameLang = termLang == defLang
        let plainAnswer = sameLang || answerLang == .other
        return Question(
            qid: q.qid,
            cardId: card.id,
            ask: askTerm ? .term : .definition,
            prompt: askTerm ? card.definition : card.term,
            expected: askTerm ? card.term : card.definition,
            promptLang: promptLang,
            answerLang: answerLang,
            promptLabel: sameLang || promptLang == .other
                ? (askTerm ? "Definition" : "Begriff") : Labels.langName(promptLang),
            placeholder: plainAnswer ? "Antwort eingeben" : "Antwort auf \(Labels.langName(answerLang)) eingeben",
            placeholderShort: plainAnswer ? "Antwort eingeben" : "Auf \(Labels.langName(answerLang)) …",
            starred: card.starred)
    }

    // MARK: - Grading

    /// `gradeQuestion(set, info, given, tolerance)`: grades the main answer. An answer that is
    /// right for another card with the same prompt counts too (the learner cannot tell such cards
    /// apart). Falls back to plain grading against `question.expected` when the card is not in
    /// the set (or there is no set).
    /// `extraAnswers`: synonyms that are not in the set (`ExtendedSynonyms`), accepted too.
    public static func gradeQuestion(
        set: VocabSet?, question: Question, given: String, tolerance: Tolerance, extraAnswers: [String] = []
    ) -> SynonymGradeResult {
        let cards = set?.cards ?? []
        guard let card = cards.first(where: { $0.id == question.cardId }) else {
            return SynonymGradeResult(
                result: Grading.grade(
                    given: given, expected: question.expected, tolerance: tolerance, lang: question.answerLang))
        }
        return Synonyms.gradeWithSynonyms(
            given: given, card: card, cards: cards, ask: question.ask, tolerance: tolerance,
            answerLang: question.answerLang, extraAnswers: extraAnswers)
    }

    /// `copyAccepted(value, info, tolerance)`: the copy step after a miss needs the asked card's
    /// own answer (no synonyms) and a non-empty field.
    public static func copyAccepted(_ value: String?, question: Question?, tolerance: Tolerance) -> Bool {
        guard let question, let value, hasText(value) else { return false }
        return Grading.grade(given: value, expected: question.expected, tolerance: tolerance, lang: question.answerLang)
            .correct
    }

    // MARK: - Pending "Nicht ganz" screen

    /// The "Nicht ganz" screen that was open when Write mode was left (`feedback`, stored next to
    /// the session): `{ qid, given, dontKnow }`.
    public struct PendingFeedback: Codable, Sendable, Equatable, Hashable {
        public var qid: String
        public var given: String
        public var dontKnow: Bool

        public init(qid: String, given: String = "", dontKnow: Bool = false) {
            self.qid = qid
            self.given = given
            self.dontKnow = dontKnow
        }

        /// Lenient like write-model.js: nil unless `json` is an object with a string `qid`;
        /// a non-string `given` becomes "", `dontKnow` must be `true`.
        public init?(json: JSONValue?) {
            guard let o = json?.objectValue, let qid = o["qid"]?.stringValue else { return nil }
            self.qid = qid
            given = o["given"]?.stringValue ?? ""
            dontKnow = o["dontKnow"]?.boolValue == true
        }

        public init(from decoder: any Decoder) throws {
            guard let value = PendingFeedback(json: try JSONValue(from: decoder)) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a pending feedback"))
            }
            self = value
        }

        /// The JSON record (`{ qid, given, dontKnow }`).
        public var json: JSONValue {
            .object(["qid": .string(qid), "given": .string(given), "dontKnow": .bool(dontKnow)])
        }
    }

    /// `MAX_GIVEN`: longer stored answers are cut (UTF-16 code units).
    public static let maxGivenLength = 1000

    /// `pendingFeedback(session, feedback)`: the stored record is valid while its question was
    /// missed in the running round and not counted as correct since. Returns the cleaned record
    /// (answer capped at `maxGivenLength`) or nil.
    public static func pendingFeedback(_ session: SessionState?, _ feedback: PendingFeedback?) -> PendingFeedback? {
        guard let session, let feedback else { return nil }
        let qid = feedback.qid
        guard session.questions.keys.contains(where: { JSCompat.identical($0, qid) }) else { return nil }
        if session.done.contains(where: { JSCompat.identical($0, qid) }) { return nil }
        if session.queue.contains(where: { JSCompat.identical($0, qid) }) { return nil }
        guard let last = session.roundAnswered.last(where: { JSCompat.identical($0.qid, qid) }), !last.correct else {
            return nil
        }
        let given = utf16Prefix(feedback.given, maxGivenLength)
        return PendingFeedback(qid: qid, given: given, dontKnow: feedback.dontKnow)
    }

    /// `pendingFeedback` for a raw stored record.
    public static func pendingFeedback(_ session: SessionState?, json feedback: JSONValue?) -> PendingFeedback? {
        pendingFeedback(session, PendingFeedback(json: feedback))
    }

    // MARK: - Resuming

    /// Whether a requested subset matches the stored session's: no request matches anything,
    /// named subsets match by value. A card-id list never matches (JS compares it by identity).
    static func subsetMatches(_ stored: StudySubset, _ wanted: StudySubset?) -> Bool {
        guard let wanted else { return true }
        if case .cardIds = wanted { return false }
        return stored == wanted
    }

    /// `canResume(saved, { forceNew, subset })`: a stored session is resumed unless a fresh one
    /// was requested, it is finished or empty, or a different named subset was asked for.
    public static func canResume(_ saved: SessionState?, forceNew: Bool = false, subset: StudySubset? = nil) -> Bool {
        guard !forceNew, let saved else { return false }
        return saved.finishedAt == nil && !saved.order.isEmpty && !WriteSession.isFinished(saved)
            && subsetMatches(saved.subset, subset)
    }

    /// `canShowResults(saved, { forceNew, subset, marker })`: a finished session is shown again
    /// (results instead of a fresh start) when the screen that ran it comes back; `marker` is the
    /// `startedAt` of the session that screen showed (see `State.resultsMarker`).
    public static func canShowResults(
        _ saved: SessionState?, forceNew: Bool = false, subset: StudySubset? = nil, marker: Double? = nil
    ) -> Bool {
        guard !forceNew, let saved, let marker else { return false }
        return saved.finishedAt != nil && !saved.order.isEmpty && marker == saved.startedAt
            && subsetMatches(saved.subset, subset)
    }

    /// `hasAnswers(session)`: something was answered already (a closed round or the current one).
    public static func hasAnswers(_ session: SessionState) -> Bool {
        !session.rounds.isEmpty || !session.roundAnswered.isEmpty
    }

    // MARK: - Stored form

    /// The stored form of write.js: the session's JSON plus the open "Nicht ganz" screen under
    /// `feedback` (`{ ...session, feedback }`). Save it with `LibraryStore.saveSessionJSON`.
    public static func storedJSON(session: SessionState, feedback: PendingFeedback?) -> JSONValue {
        guard var object = (try? JSONValue(encoding: session))?.objectValue else { return .null }
        if let feedback { object["feedback"] = feedback.json }
        return .object(object)
    }

    /// Splits a stored Write session (`LibraryStore.getSessionJSON`) into the repaired session and
    /// its raw `feedback` record (validated later by `pendingFeedback`).
    public static func decodeStored(_ json: JSONValue?) -> (session: SessionState, feedback: PendingFeedback?)? {
        guard let json, json.isObject else { return nil }
        return (WriteSession.copyState(json), PendingFeedback(json: json["feedback"]))
    }

    // MARK: - Results tile, special-character rows

    /// A study time short enough for one line: "42 Sek.", "2:47" (minutes) or "1:02:47" (hours);
    /// `label` names the unit.
    public struct CompactDuration: Codable, Sendable, Equatable, Hashable {
        public var value: String
        public var label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// `compactDuration(ms)`. NaN, negative and infinite values give "0 Sek.".
    public static func compactDuration(_ ms: Double) -> CompactDuration {
        let seconds = ms.isFinite ? max(0, JSCompat.round(ms / 1000)) : 0
        let total = Int(min(seconds, 9_007_199_254_740_992))
        let h = total / 3600
        let m = (total % 3600) / 60
        let ss = twoDigits(total % 60)
        if h > 0 { return CompactDuration(value: "\(h):\(twoDigits(m)):\(ss)", label: "Zeit (Std.)") }
        if m > 0 { return CompactDuration(value: "\(m):\(ss)", label: "Zeit (Min.)") }
        return CompactDuration(value: "\(total) Sek.", label: "Zeit")
    }

    /// `charColumns(count, perRow)`: the column count for special-character keys laid out in the
    /// fewest balanced rows of at most `perRow` keys. Non-finite input counts as 0.
    public static func charColumns(_ count: Double, _ perRow: Double) -> Int {
        let n = count.isFinite ? max(0, count.rounded(.down)) : 0
        let most = max(1, perRow.isFinite ? perRow.rounded(.down) : 0)
        if n == 0 { return 1 }
        return Int((n / (n / most).rounded(.up)).rounded(.up))
    }

    // MARK: - Term rows (summary, results)

    /// A row of the round summary or the "Am häufigsten falsch" list (`termRows`).
    public struct TermRow: Codable, Sendable, Equatable, Hashable, Identifiable {
        /// The question id (summary) or the card id (results).
        public var id: String
        public var cardId: String
        public var term: String
        public var definition: String
        public var termLang: Lang
        public var defLang: Lang
        /// Summary rows: whether the answer was right.
        public var correct: Bool?
        /// Results rows: how often the card was missed.
        public var misses: Int?

        public init(
            id: String, cardId: String, term: String, definition: String, termLang: Lang, defLang: Lang,
            correct: Bool? = nil, misses: Int? = nil
        ) {
            self.id = id
            self.cardId = cardId
            self.term = term
            self.definition = definition
            self.termLang = termLang
            self.defLang = defLang
            self.correct = correct
            self.misses = misses
        }

        /// "2× falsch" (results rows).
        public var missesLabel: String? { misses.map { "\($0)× falsch" } }
    }

    /// The card of each id like the JS `Map` of write.js (the last card with an id wins).
    static func cardIndex(_ cards: [Card]) -> [String: Card] {
        var index: [String: Card] = [:]
        for card in cards { index[card.id] = card }
        return index
    }

    static func termRows(set: VocabSet, items: [(id: String, cardId: String, correct: Bool?, misses: Int?)])
        -> [TermRow]
    {
        let cards = cardIndex(set.cards)
        return items.compactMap { item in
            guard let card = cards[item.cardId] else { return nil }
            return TermRow(
                id: item.id, cardId: item.cardId, term: card.term, definition: card.definition,
                termLang: set.termLang, defLang: set.defLang, correct: item.correct, misses: item.misses)
        }
    }

    // MARK: - Internals

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// JS `s.slice(0, n)` on UTF-16 code units. A surrogate pair cut in half is dropped (Swift
    /// strings cannot hold the lone surrogate JS would keep).
    static func utf16Prefix(_ s: String, _ n: Int) -> String {
        guard s.utf16.count > n else { return s }
        var units = 0
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let width = u.utf16.count
            if units + width > n { break }
            units += width
            out.append(u)
        }
        return String(out)
    }

    /// The number of UTF-16 code units outside JS whitespace (`s.replace(/\s/g, '').length`).
    static func nonWhitespaceLength(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (JSCompat.isWhitespace($1) ? 0 : $1.utf16.count) }
    }
}
