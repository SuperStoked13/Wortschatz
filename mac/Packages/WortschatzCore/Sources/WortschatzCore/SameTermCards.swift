import Foundation

/// Cards that ask for the same word (Joan, 10.11.2026): «etw. entführen» → «to hijack sth» and
/// «jmdn. entführen» → «to kidnap sb». Writing «to kidnap sb» for the first is wrong by the card,
/// but it is the right answer to the other card with the same word – the app then asks what it
/// should count as (`SameTermSheet`). Cards whose prompts are exactly the same are synonym cards
/// already and count as right on their own (`Synonyms.gradeWithSynonyms`); this is for prompts
/// that differ only in placeholders, articles or notes in brackets.
/// Same as SameTermCards.cs of the Windows app.
public enum SameTermCards {
    /// The other card whose prompt is the same word as `card`'s and whose answer `given` is
    /// (graded with the session's tolerance), or nil.
    public static func answerOfOtherCard(
        _ given: String, card: Card, cards: [Card], ask: AskSide, tolerance: Tolerance, promptLang: Lang,
        answerLang: Lang
    ) -> Card? {
        guard !JSCompat.trim(given).isEmpty else { return nil }
        let keys = termKeys(Synonyms.promptSide(card, ask: ask), lang: promptLang)
        guard !keys.isEmpty else { return nil }
        for other in cards where other.id != card.id {
            let answer = Synonyms.answerSide(other, ask: ask)
            guard !JSCompat.trim(answer).isEmpty,
                !termKeys(Synonyms.promptSide(other, ask: ask), lang: promptLang).isDisjoint(with: keys)
            else { continue }
            if Grading.grade(given: given, expected: answer, tolerance: tolerance, lang: answerLang).correct {
                return other
            }
        }
        return nil
    }

    /// The word a prompt asks for, without placeholders, articles, reflexive pronouns and notes in
    /// brackets, for the prompt and each of its alternatives: «etw. entführen» and
    /// «jmdn. entführen» → «entfuhren».
    public static func termKeys(_ prompt: String, lang: Lang) -> Set<String> {
        // Once per prompt: a wrong answer compares the asked card with every card of the set
        // (15 ms per answer for 540 cards, measured 26.11.2026).
        termKeySets.value(for: "\(lang.rawValue)\u{1}\(prompt)") { _ in
            var keys = Set<String>()
            for text in [prompt] + Grading.splitAlternatives(prompt, lang: lang) {
                let key = termKey(text, lang: lang)
                if !key.isEmpty { keys.insert(key) }
            }
            return keys
        }
    }

    private static let termKeySets = TextMemo<Set<String>>()

    /// Placeholders of vocabulary lists that are not part of the word («etw.», «jmdn.», «sth», «sb»).
    static let placeholders: Set<String> = [
        "etw", "etwas", "jmdn", "jmdm", "jmds", "jmd", "jdn", "jdm", "jds", "jd", "jemanden", "jemandem", "jemandes",
        "sth", "sb", "smth", "smb", "someone", "something", "somebody", "qc", "qch", "qqch", "qqc", "qn", "qqn",
        "algo", "alguien", "alg", "qlco", "qlcu", "qualcosa", "qualcuno",
    ]

    /// `ExtendedSynonyms.looseKey` without notes in brackets and placeholders (Windows:
    /// SynonymLexicon.KeyOf).
    static func termKey(_ text: String, lang: Lang) -> String {
        let key = ExtendedSynonyms.looseKey(
            ExtendedSynonyms.stripBracketed(text).replacingOccurrences(of: "/", with: " "), lang: lang)
        guard !key.isEmpty else { return key }
        let words = key.split(separator: " ").map(String.init)
        let kept = words.filter { !placeholders.contains($0) }
        return kept.isEmpty ? key : kept.joined(separator: " ")
    }
}
