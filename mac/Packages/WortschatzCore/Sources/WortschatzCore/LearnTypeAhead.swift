import Foundation

// Typing on a multiple-choice question: instead of a digit or a click, the learner starts typing
// the answer ("la vo…") and the one option those letters start is highlighted, so Return chooses
// it. The letters must leave no doubt: an article alone never picks anything ("la" starts many
// words), at least `TYPE_AHEAD_MIN_LETTERS` letters after it are needed, and exactly one option
// may match. Case, accents and the kind of apostrophe do not matter; an option can also be
// started without its article ("voi" → la voiture) or at one of its alternatives ("laide" in
// "laid, laide"). Arabic: vowel marks, tatweel, hamza forms, ة/ه and ى/ي do not matter and «ال»
// is a glued article («كت» → الكتاب). Chinese: spaces do not matter and the pinyin of
// «你好 (nǐ hǎo)» or «你好 nǐ hǎo» starts it too («ni»). Hand-mirrored by src/core/typeahead.js.

extension LearnFlow {
    /// The most characters kept while typing on a multiple-choice question.
    public static let TYPE_AHEAD_MAX = 80
    /// Letters needed after the article before the typed letters pick an option.
    public static let TYPE_AHEAD_MIN_LETTERS = 2

    /// What the letters typed on a multiple-choice question match.
    public struct TypeAhead: Sendable, Equatable {
        /// The option the letters pick (Return chooses it), nil = none yet.
        public var selected: Int?
        /// The options the letters start, in order (empty while nothing is typed).
        public var matching: [Int]
        /// The typed part of each matching option's text (`Character` offsets), for highlighting.
        public var ranges: [Int: Range<Int>]
        /// Letters are typed.
        public var isActive: Bool
        /// Enough letters for a pick, should a single option match.
        public var hasEnoughLetters: Bool

        public init(
            selected: Int? = nil, matching: [Int] = [], ranges: [Int: Range<Int>] = [:], isActive: Bool = false,
            hasEnoughLetters: Bool = false
        ) {
            self.selected = selected
            self.matching = matching
            self.ranges = ranges
            self.isActive = isActive
            self.hasEnoughLetters = hasEnoughLetters
        }
    }

    /// The type-ahead of the question on screen.
    public static func typeAhead(_ state: State) -> TypeAhead {
        guard case .question(.mc) = state.phase, let q = state.question else { return TypeAhead() }
        return typeAhead(state.typed, choices: q.choices.map(\.text), lang: q.answerLang)
    }

    /// Which of `choices` the letters `typed` start, and the one they pick. `lang` is the
    /// language of the options (its articles); nil allows the articles of every language.
    public static func typeAhead(_ typed: String, choices: [String], lang: Lang?) -> TypeAhead {
        // Chinese: spaces do not count, in the letters typed and in the options.
        let noSpaces = lang == .zh
        let input = TypeAheadText(typed, noSpaces: noSpaces)
        guard input.chars.contains(where: { $0 != " " }) else { return TypeAhead() }
        let prefixes = TypeAheadText.articlePrefixes(lang)

        // The letters after a leading article ("la vo" → "vo"); none for an article alone.
        let contentStart = TypeAheadText.articleEnd(input.chars, at: 0, prefixes: prefixes)
        let articleOnly = contentStart == nil && TypeAheadText.isArticle(input.chars, prefixes: prefixes)
        let content = articleOnly ? [] : Array(input.chars[(contentStart ?? 0)...])
        let letters = content.filter { $0.isLetter || $0.isNumber }.count

        var strong: [(index: Int, range: Range<Int>, complete: Bool)] = []
        var weak: [(index: Int, range: Range<Int>, complete: Bool)] = []
        for (index, choice) in choices.enumerated() {
            let option = TypeAheadText(choice, noSpaces: noSpaces)
            let starts = option.starts(prefixes: prefixes)
            // The whole input from the start of the option, an alternative or a word after an article.
            if let start = starts.first(where: { option.chars[$0...].starts(with: input.chars) }) {
                strong.append((index, option.range(start, input.chars.count), option.isComplete(start + input.chars.count)))
                continue
            }
            // Another article than the option's ("le voi" for "la voiture"): the content alone.
            if contentStart != nil, !content.isEmpty,
                let start = starts.first(where: { option.chars[$0...].starts(with: content) })
            {
                weak.append((index, option.range(start, content.count), option.isComplete(start + content.count)))
            }
        }
        // Options that match with the typed article win over those matching only after it.
        let matches = strong.isEmpty ? weak : strong
        let complete = matches.filter(\.complete)
        let enough = letters >= TYPE_AHEAD_MIN_LETTERS || (letters >= 1 && matches.count == 1 && matches[0].complete)

        var selected: Int?
        if enough {
            if matches.count == 1 {
                selected = matches[0].index
            } else if complete.count == 1 {
                // "le pain" picks "le pain", not "le pain de mie".
                selected = complete[0].index
            }
        }
        return TypeAhead(
            selected: selected, matching: matches.map(\.index),
            ranges: Dictionary(uniqueKeysWithValues: matches.map { ($0.index, $0.range) }), isActive: true,
            hasEnoughLetters: enough)
    }

    /// The digit 0–9 a key types, ASCII or Arabic-Indic (٠–٩, ۰–۹: an Arabic keyboard chooses like
    /// 1–4 and 0); nil for anything else (typeahead.js `digitValue`).
    public static func digitValue(_ text: String) -> Int? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 1 else { return nil }
        let v = scalars[0].value
        switch v {
        case 0x30...0x39: return Int(v - 0x30)
        case 0x660...0x669: return Int(v - 0x660)
        case 0x6F0...0x6F9: return Int(v - 0x6F0)
        default: return nil
        }
    }
}

/// A text folded for type-ahead comparison: lower case, no accents, one kind of apostrophe, single
/// spaces, no leading space, a trailing space kept ("la " means the article is done); no spaces
/// between two Han characters, none at all with `noSpaces` (Chinese). `origin` maps every folded
/// character to its `Character` offset in the original text.
struct TypeAheadText {
    var chars: [Character] = []
    var origin: [Int] = []

    init(_ text: String, noSpaces: Bool = false) {
        // The offset of the whitespace before the next character, once something came before it.
        var pendingSpace: Int?
        for (offset, ch) in text.enumerated() {
            if ch.isWhitespace {
                if !chars.isEmpty && !noSpaces { pendingSpace = offset }
                continue
            }
            let folded = Self.fold(ch)
            // Nothing to compare (tatweel, a lone mark): a space before it waits for the next
            // character.
            if folded.isEmpty { continue }
            if let space = pendingSpace {
                if !(chars.last.map(Self.isHan) == true && TextNormalizer.hasHan(folded)) {
                    chars.append(" ")
                    origin.append(space)
                }
                pendingSpace = nil
            }
            for f in folded.unicodeScalars {
                chars.append(Character(f))
                origin.append(offset)
            }
        }
        if let space = pendingSpace {
            chars.append(" ")
            origin.append(space)
        }
    }

    /// One character folded for comparison (typeahead.js `foldChar`): lower case, no accents
    /// (NFD, marks dropped), one kind of apostrophe, ß → ss. Arabic: the script folds (vowel marks
    /// and tatweel go, presentation forms, ، ؛ and full-width punctuation become plain), hamza
    /// goes with the accents (أ → ا), ٱ → ا, ة → ه, ى → ي.
    static func fold(_ ch: Character) -> String {
        switch ch {
        case "’", "‘", "`", "´", "ʼ", "′": return "'"
        default: break
        }
        let lower = TextNormalizer.foldScripts(String(ch)).lowercased()
        var out = String.UnicodeScalarView()
        for u in lower.decomposedStringWithCanonicalMapping.unicodeScalars where !TextNormalizer.isMark(u) {
            switch u.value {
            case 0xDF: out.append(contentsOf: "ss".unicodeScalars) // ß
            case 0x671: out.append("\u{627}") // ٱ → ا
            case 0x629: out.append("\u{647}") // ة → ه
            case 0x649: out.append("\u{64A}") // ى → ي
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// A Han character (Chinese).
    static func isHan(_ ch: Character) -> Bool { ch.unicodeScalars.contains(where: TextNormalizer.isHanScalar) }

    /// The original `Character` offsets of `length` folded characters from `start`.
    func range(_ start: Int, _ length: Int) -> Range<Int> {
        guard length > 0, start < origin.count else { return 0..<0 }
        let end = min(start + length, origin.count) - 1
        return origin[start]..<(origin[end] + 1)
    }

    /// Whether the option ends at folded position `end` (or an alternative or a note in
    /// brackets starts there).
    func isComplete(_ end: Int) -> Bool {
        var i = end
        while i < chars.count, chars[i] == " " { i += 1 }
        return i >= chars.count || [",", ";", "/", "("].contains(chars[i])
    }

    /// Where typing may start: the option itself and each alternative ("laid, laide"), and the
    /// word after their leading article or pronoun ("la voiture" → "voiture"). An option with
    /// Chinese characters also starts after a bracket and where pinyin follows the characters
    /// ("你好 (nǐ hǎo)", "你好 nǐ hǎo" → "ni").
    func starts(prefixes: [[Character]]) -> [Int] {
        var alternatives = [0]
        let chinese = chars.contains(where: Self.isHan)
        var lastHan = false // the last letter before i is a Han character
        for (i, ch) in chars.enumerated() {
            let pinyin = chinese && lastHan && ch.isASCII && ch.isLowercase
            if ch != " " { lastHan = Self.isHan(ch) }
            if pinyin && alternatives.last != i { alternatives.append(i) }
            guard [",", ";", "/"].contains(ch) || (chinese && (ch == "(" || ch == "[")) else { continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            if j < chars.count { alternatives.append(j) }
        }
        var all: [Int] = []
        for start in alternatives {
            all.append(start)
            if let end = Self.articleEnd(chars, at: start, prefixes: prefixes) { all.append(end) }
        }
        return all
    }

    /// The position after a leading article or pronoun at `start` ("la " or "l'"), nil if none
    /// starts there or nothing follows it.
    static func articleEnd(_ chars: [Character], at start: Int, prefixes: [[Character]]) -> Int? {
        for prefix in prefixes where chars[start...].starts(with: prefix) && chars.count > start + prefix.count {
            return start + prefix.count
        }
        return nil
    }

    /// Whether the letters are only an article or pronoun, possibly unfinished by its space
    /// ("la", "la ", "l'").
    static func isArticle(_ chars: [Character], prefixes: [[Character]]) -> Bool {
        let trimmed = Array(chars.reversed().drop { $0 == " " }.reversed())
        return prefixes.contains { prefix in
            prefix == trimmed || (prefix.last == " " && Array(prefix.dropLast()) == trimmed)
        }
    }

    /// `ExtendedSynonyms.articlePrefixes`, folded.
    static func articlePrefixes(_ lang: Lang?) -> [[Character]] {
        ExtendedSynonyms.articlePrefixes(lang).map { Array(TypeAheadText($0).chars) }
    }
}
