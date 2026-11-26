import Foundation

// Port of src/core/synonyms.js: synonym-aware grading for Write and Learn mode.
//
// Cards whose prompts share a meaning ("hässlich" → "laid, laide" and "hässlich" → "moche", or
// "lieb" → "brave" and "lieb, nett" → "gentil, gentille") look the same to the learner, who cannot
// know which card is meant. An answer that is correct for such a sibling card is therefore
// accepted with the note `.synonym`; `expectedDisplay` stays the asked card's answer so the
// feedback shows what was meant.

/// `{ result, matchedCard }` of `gradeWithSynonyms`. `matchedCard` (the synonym card whose
/// answer was accepted) is encoded as explicit `null` when absent.
public struct SynonymGradeResult: Codable, Sendable, Equatable, Hashable {
    public var result: GradeResult
    public var matchedCard: Card?

    public init(result: GradeResult, matchedCard: Card? = nil) {
        self.result = result
        self.matchedCard = matchedCard
    }

    /// Accepted as another word with the same meaning: a synonym card's answer, or a synonym that
    /// is not in the set (`.extendedSynonym`).
    public var isSynonym: Bool { matchedCard != nil || result.notes.contains(.extendedSynonym) }

    enum CodingKeys: String, CodingKey { case result, matchedCard }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(result, forKey: .result)
        try c.encodeNullable(matchedCard, forKey: .matchedCard)
    }
}

/// Port of src/core/synonyms.js: synonym-aware grading. Cards whose prompts share a meaning look
/// the same to the learner, so an answer that is correct for such a sibling card is accepted with
/// the note `.synonym`; `expectedDisplay` stays the asked card's answer.
public enum Synonyms {
    private typealias JSText = Grading.JSText

    /// The side shown as the prompt: `ask == .term` → the definition.
    public static func promptSide(_ card: Card, ask: AskSide) -> String {
        ask == .term ? card.definition : card.term
    }

    /// The side the learner types: `ask == .term` → the term.
    public static func answerSide(_ card: Card, ask: AskSide) -> String {
        ask == .term ? card.term : card.definition
    }

    /// Other cards (not `card` itself, matched by id) with a non-empty answer whose prompt side
    /// shares at least one alternative with this card's, in `cards` order.
    public static func findSynonymCards(_ cards: [Card], card: Card, ask: AskSide) -> [Card] {
        let keys = promptKeys(promptSide(card, ask: ask))
        if keys.isEmpty { return [] }
        return cards.filter { other in
            if isSameCard(other, card) { return false }
            if isBlank(answerSide(other, ask: ask)) { return false }
            return !promptKeys(promptSide(other, ask: ask)).isDisjoint(with: keys)
        }
    }

    /// Grades against the asked card first, then against its synonym cards (best = exact, then
    /// fewest notes), then against `extraAnswers`: words with the same meaning that are not in the
    /// set (`ExtendedSynonyms`), accepted with the note `.extendedSynonym` unless the answer
    /// belongs to another card of the set (two cards mixed up).
    public static func gradeWithSynonyms(
        given: String, card: Card, cards: [Card], ask: AskSide, tolerance: Tolerance, answerLang: Lang?,
        extraAnswers: [String] = []
    ) -> SynonymGradeResult {
        let result = Grading.grade(
            given: given, expected: answerSide(card, ask: ask), tolerance: tolerance, lang: answerLang)
        if result.correct { return SynonymGradeResult(result: result) }
        var best: (result: GradeResult, card: Card)?
        for other in findSynonymCards(cards, card: card, ask: ask) {
            let r = Grading.grade(
                given: given, expected: answerSide(other, ask: ask), tolerance: tolerance, lang: answerLang)
            if r.correct && (best.map { quality(r) < quality($0.result) } ?? true) { best = (r, other) }
        }
        guard let best else {
            return gradeWithExtraAnswers(
                given: given, result: result, card: card, cards: cards, ask: ask, tolerance: tolerance,
                answerLang: answerLang, extraAnswers: extraAnswers)
        }
        return SynonymGradeResult(
            result: GradeResult(
                correct: true,
                exact: false,
                notes: [.synonym] + best.result.notes.filter { !siblingOnlyNotes.contains($0) },
                hint: nil,
                expectedDisplay: result.expectedDisplay),
            matchedCard: best.card)
    }

    /// The asked card's wrong `result`, or the best match among `extraAnswers`. Never the prompt
    /// typed again (a model list may repeat it) or another card's answer.
    private static func gradeWithExtraAnswers(
        given: String, result: GradeResult, card: Card, cards: [Card], ask: AskSide, tolerance: Tolerance,
        answerLang: Lang?, extraAnswers: [String]
    ) -> SynonymGradeResult {
        guard !extraAnswers.isEmpty,
            !looseAnswerKeys(promptSide(card, ask: ask), lang: nil).contains(ExtendedSynonyms.looseKey(given, lang: nil)),
            !isAnswerOfOtherCard(given, card: card, cards: cards, ask: ask, lang: answerLang)
        else { return SynonymGradeResult(result: result) }
        var best: GradeResult?
        for extra in extraAnswers {
            let r = Grading.grade(given: given, expected: extra, tolerance: tolerance, lang: answerLang)
            if r.correct && (best.map { quality(r) < quality($0) } ?? true) { best = r }
        }
        guard let best else { return SynonymGradeResult(result: result) }
        return SynonymGradeResult(
            result: GradeResult(
                correct: true,
                exact: false,
                notes: [.extendedSynonym] + best.notes.filter { !siblingOnlyNotes.contains($0) },
                hint: nil,
                expectedDisplay: result.expectedDisplay))
    }

    /// Whether `given` is the answer of a card other than `card` and its synonym cards, compared
    /// loosely (case, accents, articles and punctuation do not matter): the learner mixed up two
    /// cards of the set, so a word from outside the set must not make it right.
    public static func isAnswerOfOtherCard(_ given: String, card: Card, cards: [Card], ask: AskSide, lang: Lang?)
        -> Bool
    {
        let key = ExtendedSynonyms.looseKey(given, lang: lang)
        guard !key.isEmpty else { return false }
        let keys = promptKeys(promptSide(card, ask: ask))
        return cards.contains { other in
            if isSameCard(other, card) { return false }
            // Synonym cards (same prompt) are no mix-up.
            if !keys.isEmpty && !promptKeys(promptSide(other, ask: ask)).isDisjoint(with: keys) { return false }
            return looseAnswerKeys(answerSide(other, ask: ask), lang: lang).contains(key)
        }
    }

    // MARK: - Helpers

    /// Completeness notes describe the other card's answer, not the asked one.
    private static let siblingOnlyNotes: Set<GradeNote> = [.partial, .order]

    private static func quality(_ r: GradeResult) -> Int { r.exact ? 0 : 1 + r.notes.count }

    /// The JS code compares cards by identity or by id; Swift cards are values, so the id decides.
    static func isSameCard(_ a: Card, _ b: Card) -> Bool { JSCompat.identical(a.id, b.id) }

    /// Comparison key: case, ß/ss, ligatures, hyphens and punctuation do not matter, nor Arabic
    /// vowel marks or full-width punctuation (`foldScripts`).
    private static func keyOf(_ text: String) -> JSText {
        var out: [Unicode.Scalar] = []
        for u in Grading.foldScripts(Grading.normalizeBasic(JSText(text))).lowercased().scalars {
            switch u {
            case "ß": out.append(contentsOf: ["s", "s"])
            case "œ": out.append(contentsOf: ["o", "e"])
            case "æ": out.append(contentsOf: ["a", "e"])
            case "-": out.append(" ")
            default:
                if !Grading.isPunct(u) && !Grading.isBracket(u) { out.append(u) }
            }
        }
        return JSText(out).collapsingWhitespace(into: " ").trimmed()
    }

    // `findSynonymCards` looks at every card of the set for each question and answer, so each
    // text is normalised once (`TextMemo`).
    private static let promptKeySets = TextMemo<Set<JSText>>()
    private static let blankTexts = TextMemo<Bool>()
    private static let looseKeySets = TextMemo<Set<String>>()

    /// `ExtendedSynonyms.looseKey` of an answer and of each of its alternatives.
    private static func looseAnswerKeys(_ text: String, lang: Lang?) -> Set<String> {
        looseKeySets.value(for: "\(lang?.rawValue ?? "")\u{1}\(text)") { _ in
            ExtendedSynonyms.alternativeKeys(text, lang: lang)
        }
    }

    /// The whole prompt and each of its alternatives ("lieb, nett" → lieb nett | lieb | nett).
    static func promptKeys(_ text: String) -> Set<Grading.JSText> {
        promptKeySets.value(for: text) { text in
            var keys: Set<JSText> = [keyOf(text)]
            for alt in Grading.splitAlternatives(text) { keys.insert(keyOf(alt)) }
            keys.remove("")
            return keys
        }
    }

    /// Whether `text` is empty after basic normalisation.
    static func isBlank(_ text: String) -> Bool {
        blankTexts.value(for: text) { TextNormalizer.normalizeBasic($0).isEmpty }
    }
}
