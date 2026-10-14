import Foundation

/// Display data of a language (`LANGS` entry of src/lib/labels.js).
public struct LangInfo: Codable, Sendable, Equatable, Hashable {
    /// German name, e.g. "Französisch".
    public var name: String
    /// Short code, e.g. "FR" ("—" for other).
    public var short: String
    /// BCP 47 tag for speech, e.g. "fr-FR" ("" for other).
    public var bcp47: String

    public init(name: String, short: String, bcp47: String) {
        self.name = name
        self.short = short
        self.bcp47 = bcp47
    }
}

/// Port of src/lib/labels.js: shared German UI labels (Swiss spelling: "ss", never the sharp s).
public enum Labels {
    public static let LANGS: [Lang: LangInfo] = [
        .fr: LangInfo(name: "Französisch", short: "FR", bcp47: "fr-FR"),
        .en: LangInfo(name: "Englisch", short: "EN", bcp47: "en-GB"),
        .es: LangInfo(name: "Spanisch", short: "ES", bcp47: "es-ES"),
        .it: LangInfo(name: "Italienisch", short: "IT", bcp47: "it-IT"),
        .de: LangInfo(name: "Deutsch", short: "DE", bcp47: "de-CH"),
        .other: LangInfo(name: "Andere", short: "—", bcp47: ""),
    ]

    /// Display order for language pickers.
    public static let LANG_ORDER: [Lang] = [.fr, .en, .es, .it, .de, .other]

    public static let STATUS: [CardStatus: String] = [
        .new: "Neu",
        .learning: "Am Lernen",
        .mastered: "Gemeistert",
    ]

    public static let NOTE_LABELS: [GradeNote: String] = [
        .article: "Artikel fehlte",
        .pronoun: "Pronomen fehlte",
        .abbreviation: "Abkürzung",
        .partial: "Teilantwort",
        .parentheses: "Klammerinhalt weggelassen",
        .letterCase: "Gross-/Kleinschreibung",
        .accents: "Akzente",
        .typo: "Tippfehler",
        .order: "Reihenfolge",
        // The answer of another card with the same prompt (Synonyms).
        .synonym: "Anderes Wort mit gleicher Bedeutung",
        // A word with the same meaning that is not in the set (ExtendedSynonyms).
        .extendedSynonym: "Synonym – nicht im Set",
    ]

    public static let HINT_LABELS: [GradeHint: String] = [
        .wrongArticle: "Falscher Artikel",
        .missingArticle: "Artikel fehlt",
        .accentsOnly: "Nur die Akzente stimmen nicht",
        .caseOnly: "Nur Gross-/Kleinschreibung falsch",
        .typo: "Fast – ein kleiner Tippfehler",
        .almost: "Knapp daneben",
    ]

    /// `plural(3, "Begriff", "Begriffe")` → "3 Begriffe".
    public static func plural(_ n: Int, _ one: String, _ other: String) -> String {
        "\(n) \(n == 1 ? one : other)"
    }

    public static func info(_ code: Lang?) -> LangInfo {
        LANGS[code ?? .other] ?? LANGS[.other]!
    }

    /// Lenient lookup for raw codes (unknown → `.other`, like `LANGS[code] || LANGS.other`).
    public static func info(_ code: String?) -> LangInfo {
        info(code.flatMap(Lang.init(rawValue:)))
    }

    public static func langName(_ code: Lang?) -> String { info(code).name }
    public static func langName(_ code: String?) -> String { info(code).name }

    public static func langShort(_ code: Lang?) -> String { info(code).short }
    public static func langShort(_ code: String?) -> String { info(code).short }

    /// "FR → DE"
    public static func langPair(_ termLang: Lang?, _ defLang: Lang?) -> String {
        "\(langShort(termLang)) → \(langShort(defLang))"
    }
}
