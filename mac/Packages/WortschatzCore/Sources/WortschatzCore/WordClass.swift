import Foundation

/// Port of src/core/wordclass.js: word classes ("Wortart") for multiple-choice options (since 23.11.2026).
///
/// Wrong options should look like the right one: they come from cards of the same word class (noun,
/// verb, adjective/adverb, expression, number) and among those from the most similar ones
/// (`LearnEngine` ranks them).
///
/// The class of a card comes from cues on both of its sides. A side gives one class and a strength:
/// 2 (strong) for articles ("le", "der", "the"), "to", "se", "sich", gender marks (", f.", "(in)"),
/// French feminine forms ("amusant, amusante", "marié(e)"), sentence punctuation and numbers;
/// 1 (weak) for German capitalisation and lowercase, endings ("-ung", "-lich", "-tion", "-ous",
/// French "-er") and long texts. Both sides agreeing or only one having a cue gives the class; with
/// different classes the stronger cue wins, equal strengths leave the class open ("").
/// Many cues hold in one language only ("-er" is a French verb but an English noun), so each side's
/// language is detected over the whole list (`sideProfile`, `LangDetect.detectColumn`).
///
/// Works on Unicode scalars and JS lowercase (`Grading.JSText`) like the JS works on code points.
public enum WordClass {
    typealias JSText = Grading.JSText

    public static let noun = "noun"
    public static let verb = "verb"
    public static let adj = "adj"
    public static let phrase = "phrase"
    public static let number = "number"

    /// What a side of a list says about its texts (`sideProfile`).
    public struct SideProfile: Codable, Sendable, Equatable, Hashable {
        public var lang: DetectedLanguage
        /// German: nouns are capitalised, so a word in lowercase is no noun.
        public var wordCaps: Bool
        /// German: texts start with capitals and with lowercase letters alike, so a capital means a noun.
        public var capsNoun: Bool
        /// Other languages: few texts start with a capital, so one that does is a name.
        public var capsRare: Bool

        public init(lang: DetectedLanguage, wordCaps: Bool = false, capsNoun: Bool = false, capsRare: Bool = false) {
            self.lang = lang
            self.wordCaps = wordCaps
            self.capsNoun = capsNoun
            self.capsRare = capsRare
        }

        public static let unknown = SideProfile(lang: .unknown)

        /// The memo key part of the profile (`sideKey`).
        var key: String { "\(lang.rawValue)|\(wordCaps ? 1 : 0)\(capsNoun ? 1 : 0)\(capsRare ? 1 : 0)|" }
    }

    /// The class one side points to (`cls` "" = no cue) and how sure: 2 strong, 1 weak.
    public struct TextClass: Codable, Sendable, Equatable, Hashable {
        public var cls: String
        public var strength: Int

        public init(cls: String, strength: Int) {
            self.cls = cls
            self.strength = strength
        }

        static let none = TextClass(cls: "", strength: 0)
    }

    /// What the options of a side are compared by: the article, the rest without it, its words and
    /// length in code points.
    public struct OptionShape: Codable, Sendable, Equatable, Hashable {
        public var article: String
        public var head: String
        public var words: Int
        public var length: Int

        public init(article: String, head: String, words: Int, length: Int) {
            self.article = article
            self.head = head
            self.words = words
            self.length = length
        }
    }

    /// The profiles of both sides of a list.
    public struct ListProfiles: Codable, Sendable, Equatable, Hashable {
        public var term: SideProfile
        public var definition: SideProfile

        public func side(_ ask: AskSide) -> SideProfile { ask == .term ? term : definition }
    }

    // MARK: - Word lists

    private static let articles: [DetectedLanguage: [JSText]] = [
        .fr: ["le", "la", "les", "un", "une", "des", "du"],
        .de: ["der", "die", "das", "ein", "eine"],
        .en: ["the", "a", "an"],
        .es: ["el", "la", "los", "las", "un", "una", "unos", "unas"],
        .it: ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una"],
    ]
    /// A side of another language: the articles that are no other common word.
    private static let safeArticles: [JSText] = [
        "le", "la", "les", "une", "der", "das", "the", "el", "los", "las", "lo", "gli", "una", "uno",
    ]
    /// First words that make a verb: "to go", "se lever", "sich freuen".
    private static let verbLeads: [JSText] = ["to", "se", "sich"]
    /// Placeholders for objects: "etw. vorschlagen", "to propose sth", "donner qc à qn".
    private static let objects: Set<JSText> = [
        "etw", "etw.", "jmdn", "jmdn.", "jmdm", "jmdm.", "jmds", "jmds.", "jdn", "jdn.", "jdm", "jdm.", "jds", "jds.",
        "jemanden", "jemandem", "sth", "sth.", "sb", "sb.", "sb's", "qc", "qc.", "qn", "qn.", "qch", "qch.", "qqch",
        "qqch.", "qqn", "qqn.",
    ]
    /// Gender marks after a comma: "l'oreille, f.", "l'œil, m. les yeux".
    private static let genderMarks: [JSText] = ["m", "m.", "f", "f.", "n", "n.", "pl", "pl.", "m.pl.", "f.pl.", "m/f", "m./f."]
    private static let genderParens: [JSText] = ["(m)", "(m.)", "(f)", "(f.)", "(n)", "(n.)", "(pl)", "(pl.)", "(in)"]
    /// French feminine endings in brackets or after a comma: "marié(e)", "grand, e", "heureux, -euse".
    private static let feminineEndings: [JSText] = [
        "e", "ne", "le", "se", "te", "ve", "ère", "euse", "ive", "elle", "enne", "ienne", "trice",
    ]
    /// German: words after the verb ("Lust haben auf"), first words of adverbial phrases ("im
    /// Inland"), words with a verb ending that are no verbs, noun and adjective endings.
    private static let deParticles: [JSText] = [
        "an", "auf", "aus", "bei", "für", "gegen", "in", "mit", "nach", "um", "von", "vor", "zu", "über",
    ]
    private static let dePrepositions: [JSText] = [
        "als", "am", "an", "ans", "auf", "aus", "bei", "beim", "durch", "für", "gegen", "im", "in", "ins", "mit", "nach",
        "ohne", "pro", "um", "unter", "vom", "von", "vor", "zu", "zum", "zur", "über",
    ]
    private static let deNotVerbs: [JSText] = [
        "modern", "intern", "extern", "gestern", "morgen", "golden", "offen", "eigen", "trocken", "verschieden", "zufrieden",
        "oben", "unten", "innen", "aussen", "hinten", "vorne", "neben", "gegen", "eben", "selten", "wegen",
    ]
    private static let deNounEndings: [JSText] = ["ung", "heit", "keit", "schaft", "tion", "tät", "ismus", "nis", "ment", "ling"]
    private static let deAdjEndings: [JSText] = ["ig", "lich", "isch", "bar", "sam", "haft", "los", "voll"]
    private static let enNounEndings: [JSText] = ["tion", "sion", "ment", "ness", "ity", "ism", "ship", "ance", "ence", "hood", "dom"]
    private static let enAdjEndings: [JSText] = ["ous", "ful", "less", "ive", "able", "ible", "al", "ic", "ish", "ly"]
    private static let frNounEndings: [JSText] = ["tion", "sion", "isme"]
    private static let frAdjEndings: [JSText] = ["eux", "euse", "if", "ive", "able", "ible", "ique", "ment"]
    /// French words with an infinitive ending that are no verbs.
    private static let frNotVerbs: [JSText] = [
        "hier", "cher", "fier", "amer", "super", "premier", "dernier", "entier", "léger", "étranger", "autre", "libre",
        "propre", "pauvre", "rare", "sombre", "célèbre", "contre", "entre", "notre", "votre", "quatre", "noir", "soir",
        "mer", "hiver", "plaisir", "désir", "avenir", "loisir",
    ]
    /// Spanish and Italian adjectives and adverbs.
    private static let romanceAdjEndings: [JSText] = ["oso", "osa", "mente"]

    // MARK: - Small helpers

    private static func words(_ s: JSText) -> [JSText] { s.split(" ").filter { !$0.isEmpty } }

    private static func joined(_ list: [JSText]) -> JSText { JSText.joined(list, separator: " ") }

    private static func isDigit(_ u: Unicode.Scalar) -> Bool { u.value >= 0x30 && u.value <= 0x39 }

    private static func endsWithAny(_ word: JSText, _ endings: [JSText], _ minLength: Int) -> Bool {
        word.count >= minLength && endings.contains { word.hasSuffix($0) && word.count > $0.count }
    }

    /// JS `ch.toLowerCase() !== ch` for one code point (false for none).
    private static func isUpper(_ u: Unicode.Scalar?) -> Bool {
        guard let u else { return false }
        let one = JSText([u])
        return one.lowercased() != one
    }

    private static func isLower(_ u: Unicode.Scalar?) -> Bool {
        guard let u else { return false }
        let one = JSText([u])
        return TextNormalizer.isLetterScalar(u) && one.lowercased() == one
    }

    /// JS `s.includes(part)`.
    private static func includes(_ s: JSText, _ part: JSText) -> Bool {
        let a = s.scalars
        let b = part.scalars
        if b.isEmpty { return true }
        if b.count > a.count { return false }
        for i in 0...(a.count - b.count) where a[i] == b[0] && Array(a[i..<(i + b.count)]) == b { return true }
        return false
    }

    /// The text without bracketed parts ("(verabschiedetes) Gesetz" → "Gesetz") or, with `keep`,
    /// without only the brackets ("(sich) freuen" → "sich freuen"); single spaces.
    private static func brackets(_ s: JSText, keep: Bool) -> JSText {
        var out: [Unicode.Scalar] = []
        var depth = 0
        for u in s.scalars {
            if u == "(" || u == "[" {
                depth += 1
            } else if (u == ")" || u == "]") && depth > 0 {
                depth -= 1
            } else if keep || depth == 0 {
                out.append(u)
            }
        }
        return joined(words(JSText(out)))
    }

    /// The pieces between commas and semicolons, trimmed.
    private static func segments(_ s: JSText) -> [JSText] {
        s.split { $0 == "," || $0 == ";" }.map { joined(words($0)) }
    }

    /// The article a text starts with ("le", "l'", "der/die") or "". `list`: lowercase words.
    private static func articleOf(_ list: [JSText], _ lang: DetectedLanguage) -> JSText {
        guard let first = list.first else { return "" }
        if lang == .fr || lang == .it || articles[lang] == nil, first.hasPrefix("l'"), first.count > 2 { return "l'" }
        if list.count < 2 { return "" }
        let known = articles[lang] ?? safeArticles
        return first.split("/").allSatisfy { known.contains($0) } ? first : ""
    }

    // MARK: - Sides

    /// What a side of the list says about its texts: the language (`detectColumn`) and how it uses
    /// capitals. German: `wordCaps` – a fifth of the texts or more have a capitalised word;
    /// `capsNoun` – texts start with capitals and with lowercase letters alike. Other languages:
    /// `capsRare` – few texts start with a capital.
    public static func sideProfile(_ texts: [String]) -> SideProfile {
        let list = texts.map { TextNormalizer.normalizeBasic($0) }.filter { !$0.isEmpty }
        let lang = LangDetect.detectColumn(list).lang
        var upper = 0
        var lower = 0
        var capitalised = 0
        for t in list {
            let text = JSText(t)
            if isUpper(text.first) {
                upper += 1
            } else if isLower(text.first) {
                lower += 1
            }
            if words(text).contains(where: { isUpper($0.first) }) { capitalised += 1 }
        }
        let letters = upper + lower
        let german = lang == .de && letters > 0
        return SideProfile(
            lang: lang,
            wordCaps: german && capitalised * 5 >= list.count,
            capsNoun: german && upper * 10 >= letters && lower * 10 >= letters,
            capsRare: lang != .de && letters > 0 && upper * 4 <= letters)
    }

    // MARK: - Texts

    /// The parts of a text the cues look at (`parse`).
    private struct Parsed {
        /// The whole text in lowercase.
        var low: JSText
        /// Its comma pieces in lowercase.
        var segs: [JSText]
        /// The first piece's words without brackets, lowercase, and which start with a capital.
        var cut: [JSText]
        var caps: [Bool]
        /// The first piece's words with the bracketed words, lowercase.
        var keep: [JSText]
    }

    private static func parse(_ text: String) -> Parsed {
        let base = Grading.foldScripts(Grading.normalizeBasic(JSText(text)))
        let segs = segments(base)
        let main = segs[0]
        let without = brackets(main, keep: false)
        let cut = words(without.isEmpty ? brackets(main, keep: true) : without)
        return Parsed(
            low: base.lowercased(),
            segs: segs.map { $0.lowercased() },
            cut: cut.map { $0.lowercased() },
            caps: cut.map { isUpper($0.first) },
            keep: words(brackets(main, keep: true).lowercased()))
    }

    /// Only digits and separators: "1474", "1914-1918", "3,5".
    private static func isNumber(_ low: JSText) -> Bool {
        guard let first = low.first, isDigit(first) else { return false }
        let separators: [Unicode.Scalar] = [" ", ".", ",", ":", "/", "'", "-", "+", "%"]
        return low.scalars.allSatisfy { isDigit($0) || separators.contains($0) }
    }

    /// A sentence or exclamation: "Achtung!", "Wie geht's?", "C'est mon tour." (not "etw. tun bei etw.").
    private static func isSentence(_ p: Parsed) -> Bool {
        guard let first = p.low.first, let last = p.low.last else { return false }
        if first == "¿" || first == "¡" || last == "!" || last == "?" { return true }
        if (last != "." && last != "…") || !p.low.contains(" ") { return false }
        return !objects.contains(words(p.low).last ?? "")
    }

    /// "amusant, amusante", "grand, e", "heureux, -euse", "marié(e)": French, Spanish or Italian adjective.
    private static func isFeminineForm(_ p: Parsed) -> Bool {
        for w in words(p.segs[0]) {
            for e in feminineEndings where w.hasSuffix(JSText("(") + e + JSText(")")) && w.count > e.count + 2 {
                return true
            }
        }
        if p.segs.count < 2 || p.cut.count != 1 { return false }
        let a = p.segs[0]
        var b = p.segs[1]
        if b.hasPrefix("-") { b = b.slice(1) }
        if feminineEndings.contains(b) { return true }
        if words(b).count != 1 || a == b { return false }
        let x = a.scalars
        let y = b.scalars
        var common = 0
        while common < x.count && common < y.count && x[common] == y[common] { common += 1 }
        return common >= 3 && common >= x.count - 2 && y.count >= x.count
    }

    /// The words of the first piece without placeholders ("etw.", "sth"): lowercase, which start with
    /// a capital, and whether there were placeholders.
    private static func content(_ p: Parsed) -> (list: [JSText], caps: [Bool], objects: Bool) {
        var list: [JSText] = []
        var caps: [Bool] = []
        for i in p.cut.indices where !objects.contains(p.cut[i]) {
            list.append(p.cut[i])
            caps.append(p.caps[i])
        }
        return (list, caps, list.count != p.cut.count)
    }

    /// German verb or verb phrase on a side with capitalised nouns: the last word (before
    /// particles) in lowercase with a verb ending. Strength 2 with placeholders or an article in
    /// front, otherwise 1; 0 = no verb.
    private static func germanVerb(_ p: Parsed, _ side: SideProfile) -> Int {
        let c = content(p)
        if !side.wordCaps || c.list.isEmpty { return 0 }
        var v = c.list.count - 1
        if v >= 1 && deParticles.contains(c.list[v]) { v -= 1 }
        let verb = c.list[v]
        if c.caps[v] || deNotVerbs.contains(verb) { return 0 }
        if !endsWithAny(verb, ["en", "ern", "eln"], 4) && !verb.hasSuffix("tun") && verb != "sein" { return 0 }
        return c.objects || (v >= 1 && articles[.de]!.contains(c.list[0])) ? 2 : 1
    }

    /// Cues of one language (weak ones and the language's own strong ones), then a name ("Noël") or
    /// a long text without other cues.
    private static func languageCues(_ p: Parsed, _ side: SideProfile) -> TextClass {
        let (list, caps, _) = content(p)
        guard let last = list.last else { return .none }
        let single = list.count == 1
        let capital = caps[0]
        switch side.lang {
        case .de:
            let verb = germanVerb(p, side)
            if verb > 0 { return TextClass(cls: Self.verb, strength: verb) }
            // The noun comes last, before particles: "gemeinsame Reaktion auf etw.".
            var h = list.count - 1
            if h >= 1 && deParticles.contains(list[h]) { h -= 1 }
            if endsWithAny(list[h], deNounEndings, 5) { return TextClass(cls: noun, strength: 2) }
            if capital {
                if side.capsNoun { return TextClass(cls: noun, strength: 2) }
                break
            }
            if !side.wordCaps { break }
            // Lowercase: an adverbial phrase ("im Inland"), an adjective with a noun ("gemeinsame
            // Politik") or an adjective, adverb ("unbedingt erforderlich").
            if !single && dePrepositions.contains(list[0]) { return TextClass(cls: adj, strength: 1) }
            if caps[h] { return TextClass(cls: noun, strength: 1) }
            return TextClass(cls: adj, strength: endsWithAny(list[h], deAdjEndings, 4) ? 2 : 1)
        case .en:
            if endsWithAny(last, enNounEndings, 5) { return TextClass(cls: noun, strength: 1) }
            if single && endsWithAny(last, enAdjEndings, 5) { return TextClass(cls: adj, strength: 1) }
        case .fr:
            let first = list[0]
            let n = first.count
            let infinitive = !frNotVerbs.contains(first)
                && ((n >= 5 && (first.hasSuffix("er") || first.hasSuffix("ir")))
                    || (n >= 4 && (first.hasSuffix("oir") || first.hasSuffix("re"))))
            if infinitive { return TextClass(cls: Self.verb, strength: 1) }
            if single && endsWithAny(last, frNounEndings, 5) { return TextClass(cls: noun, strength: 1) }
            if single && endsWithAny(last, frAdjEndings, 4) { return TextClass(cls: adj, strength: 1) }
        case .es:
            if single && (last.hasSuffix("arse") || last.hasSuffix("erse") || last.hasSuffix("irse")) {
                return TextClass(cls: Self.verb, strength: 2)
            }
            if single && endsWithAny(last, ["ar", "er", "ir"], 4) { return TextClass(cls: Self.verb, strength: 1) }
            if single && endsWithAny(last, romanceAdjEndings, 4) { return TextClass(cls: adj, strength: 1) }
        case .it:
            if single && (last.hasSuffix("arsi") || last.hasSuffix("ersi") || last.hasSuffix("irsi")) {
                return TextClass(cls: Self.verb, strength: 2)
            }
            if single && endsWithAny(last, ["are", "ere", "ire"], 5) { return TextClass(cls: Self.verb, strength: 1) }
            if single && endsWithAny(last, romanceAdjEndings, 4) { return TextClass(cls: adj, strength: 1) }
        default:
            break
        }
        if side.capsRare && capital { return TextClass(cls: noun, strength: 1) }
        if list.count >= 5 { return TextClass(cls: phrase, strength: 1) }
        return .none
    }

    /// The class one side of a card points to, with its strength (cls "" = no cue).
    public static func textClass(_ text: String, side: SideProfile = .unknown) -> TextClass {
        let p = parse(text)
        if p.cut.isEmpty { return .none }
        if isNumber(p.low) { return TextClass(cls: number, strength: 2) }
        if p.segs.dropFirst().contains(where: { genderMarks.contains($0) || $0.hasPrefix("m. ") || $0.hasPrefix("f. ") }) {
            return TextClass(cls: noun, strength: 2)
        }
        if genderParens.contains(where: { includes(p.low, $0) }) { return TextClass(cls: noun, strength: 2) }
        if isSentence(p) { return TextClass(cls: phrase, strength: 2) }
        let first = p.keep.first ?? ""
        if p.keep.count >= 2 && verbLeads.contains(first) { return TextClass(cls: verb, strength: 2) }
        if (side.lang == .fr || side.lang == .unknown) && first.hasPrefix("s'") && first.count > 2 {
            return TextClass(cls: verb, strength: 2)
        }
        if side.lang == .de && p.cut.count >= 2 {
            let v = germanVerb(p, side)
            if v > 0 { return TextClass(cls: verb, strength: v) }
        }
        if !articleOf(p.cut, side.lang).isEmpty { return TextClass(cls: noun, strength: 2) }
        let romance = side.lang == .fr || side.lang == .es || side.lang == .it || side.lang == .unknown
        if romance && isFeminineForm(p) { return TextClass(cls: adj, strength: 2) }
        return languageCues(p, side)
    }

    /// The class of a card from both sides ("" when open). Different strong classes make a class of
    /// their own ("number/phrase": a year and an event).
    public static func combineClasses(_ term: TextClass, _ definition: TextClass) -> String {
        if term.cls.isEmpty { return definition.cls }
        if definition.cls.isEmpty || term.cls == definition.cls { return term.cls }
        if term.strength != definition.strength { return term.strength > definition.strength ? term.cls : definition.cls }
        return term.strength == 2 ? "\(term.cls)/\(definition.cls)" : ""
    }

    /// The article, the rest without it ("head"), its words and length in code points.
    public static func optionShape(_ text: String, side: SideProfile = .unknown) -> OptionShape {
        let p = parse(text)
        let article = articleOf(p.cut, side.lang)
        var rest = p.cut
        if article == "l'" {
            rest = [p.cut[0].slice(2)] + p.cut.dropFirst()
        } else if !article.isEmpty {
            rest = Array(p.cut.dropFirst())
        }
        let head = joined(rest)
        return OptionShape(article: article.string, head: head.string, words: rest.count, length: head.count)
    }

    /// Similarity points of two option shapes: the same article, as many words, a similar length,
    /// the same first two and last three letters (0–5).
    public static func shapePoints(_ a: OptionShape, _ b: OptionShape) -> Int {
        var points = 0
        if !a.article.isEmpty && a.article == b.article { points += 1 }
        if a.words == b.words { points += 1 }
        if abs(a.length - b.length) <= max(2, a.length / 5) { points += 1 }
        let x = Array(a.head.unicodeScalars)
        let y = Array(b.head.unicodeScalars)
        if x.count >= 2 && y.count >= 2 && x[0] == y[0] && x[1] == y[1] { points += 1 }
        if x.count >= 3 && y.count >= 3 && x.suffix(3).elementsEqual(y.suffix(3)) { points += 1 }
        return points
    }

    /// Points for cards close together in the set (sets are mostly ordered by topic): 3 up to 3
    /// apart, 2 up to 10, 1 up to 25.
    public static func nearPoints(_ distance: Int) -> Int {
        if distance <= 3 { return 3 }
        if distance <= 10 { return 2 }
        if distance <= 25 { return 1 }
        return 0
    }

    // MARK: - Cards of a list

    // Results per text and side, computed once (a round compares every card with every card of the set).
    private static let profiles = TextMemo<SideProfile>()
    private static let classes = TextMemo<TextClass>()
    private static let shapes = TextMemo<OptionShape>()

    /// A memo key for a list of texts (each with its length, so no two lists share one).
    private static func listKey(_ texts: [String]) -> String {
        texts.map { "\($0.unicodeScalars.count):\($0)" }.joined()
    }

    /// The profiles of both sides of `cards`.
    public static func listProfiles(_ cards: [Card]) -> ListProfiles {
        let term = cards.map(\.term)
        let definition = cards.map(\.definition)
        return ListProfiles(
            term: profiles.value(for: listKey(term)) { _ in sideProfile(term) },
            definition: profiles.value(for: listKey(definition)) { _ in sideProfile(definition) })
    }

    /// The word class of a card ("" when open). `sides`: `listProfiles` of its list.
    public static func cardClass(_ card: Card, sides: ListProfiles) -> String {
        let term = classes.value(for: sides.term.key + card.term) { _ in textClass(card.term, side: sides.term) }
        let definition = classes.value(for: sides.definition.key + card.definition) { _ in
            textClass(card.definition, side: sides.definition)
        }
        return combineClasses(term, definition)
    }

    /// `optionShape`, computed once per text and side.
    static func shapeOf(_ text: String, side: SideProfile) -> OptionShape {
        shapes.value(for: side.key + text) { _ in optionShape(text, side: side) }
    }
}
