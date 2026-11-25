import Foundation

/// Display data of a language (`LANGS` entry of src/lib/labels.js).
public struct LangInfo: Codable, Sendable, Equatable, Hashable {
    /// German name, e.g. "Französisch" (raw data; for display use `Labels.langName`, which
    /// translates it).
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
        // Written right to left (`Lang.isRTL`).
        .ar: LangInfo(name: "Arabisch", short: "AR", bcp47: "ar"),
        .zh: LangInfo(name: "Chinesisch", short: "ZH", bcp47: "zh-CN"),
        .de: LangInfo(name: "Deutsch", short: "DE", bcp47: "de-CH"),
        .other: LangInfo(name: "Andere", short: "—", bcp47: ""),
    ]

    /// Display order for language pickers.
    public static let LANG_ORDER: [Lang] = [.fr, .en, .es, .it, .ar, .zh, .de, .other]

    /// Display labels in the app's language (computed: `CoreText.translate` is set at launch).
    public static var STATUS: [CardStatus: String] {
        [
            .new: L("Neu"),
            .learning: L("Am Lernen"),
            .mastered: L("Gemeistert"),
        ]
    }

    public static var NOTE_LABELS: [GradeNote: String] {
        [
            .article: L("Artikel fehlte"),
            .pronoun: L("Pronomen fehlte"),
            .abbreviation: L("Abkürzung"),
            .partial: L("Teilantwort"),
            .parentheses: L("Klammerinhalt weggelassen"),
            .pinyin: L("Nur Pinyin"),
            .letterCase: L("Gross-/Kleinschreibung"),
            .accents: L("Akzente"),
            .tones: L("Töne"),
            .variant: L("Schreibvariante"),
            .typo: L("Tippfehler"),
            .order: L("Reihenfolge"),
            // The answer of another card with the same prompt (Synonyms).
            .synonym: L("Anderes Wort mit gleicher Bedeutung"),
            // A word with the same meaning that is not in the set (ExtendedSynonyms).
            .extendedSynonym: L("Synonym – nicht im Set"),
        ]
    }

    public static var HINT_LABELS: [GradeHint: String] {
        [
            .wrongArticle: L("Falscher Artikel"),
            .missingArticle: L("Artikel fehlt"),
            .accentsOnly: L("Nur die Akzente stimmen nicht"),
            .tonesOnly: L("Nur die Töne fehlen"),
            .caseOnly: L("Nur Gross-/Kleinschreibung falsch"),
            .typo: L("Fast – ein kleiner Tippfehler"),
            .almost: L("Knapp daneben"),
        ]
    }

    /// `plural(3, "Begriff", "Begriffe")` → "3 Begriffe". Translated as "%@ Begriff" / "%@ Begriffe"
    /// (so a counter's word can differ from the same word as a heading); callers pass literals.
    public static func plural(_ n: Int, _ one: String, _ other: String) -> String {
        L("%@ " + (n == 1 ? one : other), "\(n)")
    }

    public static func info(_ code: Lang?) -> LangInfo {
        LANGS[code ?? .other] ?? LANGS[.other]!
    }

    /// Lenient lookup for raw codes (unknown → `.other`, like `LANGS[code] || LANGS.other`).
    public static func info(_ code: String?) -> LangInfo {
        info(code.flatMap(Lang.init(rawValue:)))
    }

    /// The language's name in the app's language (`LANGS[code].name` translated). Display only:
    /// nothing parses it back.
    public static func langName(_ code: Lang?) -> String {
        switch code ?? .other {
        case .fr: L("Französisch")
        case .en: L("Englisch")
        case .es: L("Spanisch")
        case .it: L("Italienisch")
        case .ar: L("Arabisch")
        case .zh: L("Chinesisch")
        case .de: L("Deutsch")
        case .other: L("Andere")
        }
    }

    public static func langName(_ code: String?) -> String { langName(code.flatMap(Lang.init(rawValue:))) }

    public static func langShort(_ code: Lang?) -> String { info(code).short }
    public static func langShort(_ code: String?) -> String { info(code).short }

    /// "FR → DE"
    public static func langPair(_ termLang: Lang?, _ defLang: Lang?) -> String {
        "\(langShort(termLang)) → \(langShort(defLang))"
    }
}
