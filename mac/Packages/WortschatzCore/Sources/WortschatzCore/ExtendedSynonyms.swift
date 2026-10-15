import Foundation

// Synonyms that are not in the set: for "gemeinsam" → "en commun", "ensemble" is right too. The
// app asks Apple's on-device language model for dictionary translations (the prompt's
// translations, and the learner's answer translated back); this file holds the pure part: which
// wrong answers are worth asking about, how the model's lists are cleaned and compared, and the
// question they are about (`SynonymQuery`). Grading accepts such answers through the
// `extraAnswers` of `Synonyms.gradeWithSynonyms`, with the note `.extendedSynonym`.
//
// The model only ever lists translations of one text; it never sees the learner's answer next to
// the prompt (asked "is X a translation of Y?" it says yes to almost anything, even "le chat" for
// "der Hund"). The comparison is done here.

/// A written question as the synonym check sees it: the prompt and the card's answer with their
/// languages.
public struct SynonymQuery: Codable, Sendable, Equatable, Hashable {
    public var prompt: String
    public var expected: String
    public var promptLang: Lang
    public var answerLang: Lang

    public init(prompt: String, expected: String, promptLang: Lang, answerLang: Lang) {
        self.prompt = prompt
        self.expected = expected
        self.promptLang = promptLang
        self.answerLang = answerLang
    }
}

/// The pure part of the synonym check for answers that are not in the set (see the file header).
public enum ExtendedSynonyms {
    /// English language names for the model's prompts. Not Arabic: the on-device model does not
    /// support it (measured 2026-10-15); the app also checks `supportsLocale` for Chinese.
    public static let modelLanguageNames: [Lang: String] = [
        .de: "German", .fr: "French", .en: "English", .es: "Spanish", .it: "Italian", .zh: "Chinese",
    ]

    /// Longer answers are not looked up: the model is asked for word translations.
    static let maxAnswerLength = 60
    static let maxAnswerWords = 5
    /// Most translations kept from one list.
    static let maxTranslations = 8

    /// Whether the question can be checked: two different languages the model knows, and words
    /// on both sides.
    public static func supports(_ query: SynonymQuery) -> Bool {
        query.promptLang != query.answerLang && modelLanguageNames[query.promptLang] != nil
            && modelLanguageNames[query.answerLang] != nil && hasLetters(query.prompt) && hasLetters(query.expected)
    }

    /// The request for a translation list: `Translate the German word or phrase "gemeinsam" into
    /// French.` nil for a language the model is not asked about.
    public static func translationRequest(_ text: String, from: Lang, to: Lang) -> String? {
        guard let source = modelLanguageNames[from], let target = modelLanguageNames[to] else { return nil }
        let quoted = TextNormalizer.normalizeBasic(text).replacingOccurrences(of: "\"", with: "'")
        return "Translate the \(source) word or phrase \"\(quoted)\" into \(target)."
    }

    /// Whether a wrong answer is worth asking the model about. Not for a near miss of the card's
    /// answer (a hint like "Tippfehler" or "Falscher Artikel"), the prompt typed again, the answer
    /// of another card of the set (two cards mixed up), sentences, or answers without letters.
    public static func worthChecking(
        given: String, result: GradeResult, query: SynonymQuery, card: Card?, cards: [Card], ask: AskSide
    ) -> Bool {
        guard !result.correct, result.hint == nil, supports(query) else { return false }
        let text = JSCompat.trim(given)
        guard hasLetters(text), text.count <= maxAnswerLength,
            text.split(whereSeparator: \.isWhitespace).count <= maxAnswerWords
        else { return false }
        if alternativeKeys(query.prompt, lang: query.promptLang).contains(looseKey(text, lang: query.promptLang)) {
            return false
        }
        if let card, Synonyms.isAnswerOfOtherCard(text, card: card, cards: cards, ask: ask, lang: query.answerLang) {
            return false
        }
        return true
    }

    /// A list from the model, cleaned: alternatives split ("das Auto, der Wagen"), notes in
    /// brackets and quotes removed, duplicates (by `looseKey`) and overlong entries dropped, at most
    /// `maxTranslations`.
    public static func cleanTranslations(_ raw: [String], lang: Lang) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for item in raw {
            for alt in Grading.splitAlternatives(item, lang: lang) {
                let text = JSCompat.trim(stripBracketed(alt))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”„.").union(.whitespaces))
                guard hasLetters(text), text.count <= maxAnswerLength else { continue }
                let key = looseKey(text, lang: lang)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                out.append(text)
                if out.count == maxTranslations { return out }
            }
        }
        return out
    }

    /// The first of the prompt's translations that `given` matches under the learner's
    /// `tolerance`, nil for none.
    public static func matchingTranslation(_ given: String, in translations: [String], tolerance: Tolerance, lang: Lang)
        -> String?
    {
        translations.first { Grading.grade(given: given, expected: $0, tolerance: tolerance, lang: lang).correct }
    }

    /// Whether translating the learner's answer back gives the prompt (or one of its
    /// alternatives) as its most common translation: "vite" → schnell, rasch fits the prompt
    /// "schnell". Only the first entry counts: further down, the model's lists drift into
    /// related words ("le loup" → der Wolf, der Löwe, der Hund, der Fuchs …).
    public static func confirmsPrompt(_ backTranslations: [String], prompt: String, lang: Lang) -> Bool {
        guard let first = backTranslations.first else { return false }
        return alternativeKeys(prompt, lang: lang).contains(looseKey(first, lang: lang))
    }

    /// Comparison key: lower case, no accents, "ss" for "ß", no punctuation or notes in brackets,
    /// no leading article or reflexive pronoun of `lang` ("la Voiture" → "voiture", "الكتاب" →
    /// "كتاب"). The script folds come first: Arabic vowel marks and tatweel (which `.folding`
    /// keeps), presentation forms, full-width brackets and punctuation, spaces between Han
    /// characters.
    public static func looseKey(_ text: String, lang: Lang?) -> String {
        var t = stripBracketed(TextNormalizer.foldScripts(TextNormalizer.normalizeBasic(text)))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
        if let prefix = articlePrefixes(lang).first(where: { t.hasPrefix($0) && t.count > $0.count }) {
            t.removeFirst(prefix.count)
        }
        var out = ""
        var space = false
        for ch in t {
            if ch.isLetter || ch.isNumber {
                if space && !out.isEmpty { out.append(" ") }
                space = false
                out.append(ch)
            } else if ch.isWhitespace || ch == "-" {
                space = true
            }
        }
        return out
    }

    /// Leading articles and reflexive pronouns of `lang` (all languages for nil) as they start a
    /// lower-case text: "la ", "l'", "se ", "to ", "ال" (glued) …, longest first.
    static func articlePrefixes(_ lang: Lang?) -> [String] {
        let langs = lang.map { [$0] } ?? Array(Grading.ARTICLES.keys)
        var prefixes = Set<String>()
        for l in langs {
            for article in Grading.ARTICLES[l] ?? [] {
                let glued = article.hasSuffix("'") || Grading.GLUED_ARTICLES.contains(article)
                prefixes.insert(glued ? article : article + " ")
            }
            for pronoun in Grading.REFLEXIVES[l] ?? [] where pronoun.hasSuffix(" ") || pronoun.hasSuffix("'") {
                prefixes.insert(pronoun)
            }
        }
        return prefixes.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// The keys of a text and of each of its alternatives.
    static func alternativeKeys(_ text: String, lang: Lang?) -> Set<String> {
        var keys: Set<String> = [looseKey(text, lang: lang)]
        for alt in Grading.splitAlternatives(text, lang: lang) { keys.insert(looseKey(alt, lang: lang)) }
        keys.remove("")
        return keys
    }

    static func hasLetters(_ text: String) -> Bool { text.contains { $0.isLetter } }

    /// `text` without "(…)" and "[…]" notes.
    static func stripBracketed(_ text: String) -> String {
        var out = ""
        var depth = 0
        for ch in text {
            switch ch {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(ch) }
            }
        }
        return out
    }
}
