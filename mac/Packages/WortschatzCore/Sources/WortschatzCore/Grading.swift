import Foundation

// Port of src/core/grading.js: answer grading for Write and Learn mode (spec §4.10).
//
// `grade` decides whether a typed answer matches the stored answer under the learner's tolerance
// options. Both sides run through the same pipeline:
//   normalise → split alternatives (, ; /) → parenthesis variants → abbreviation expansion →
//   strip punctuation → split leading article or reflexive pronoun → compare with progressively
//   more tolerant comparators (exact, case, accents, typo).
// Every tolerance that was needed is reported as a note; for wrong answers the most helpful hint
// is computed.
//
// Strings are processed as code-point arrays (`Grading.JSText`) and compared by identity like JS
// `===`; Swift `String ==` would treat canonically equivalent texts ("é" and "e\u{301}") as equal.
// Every position the JS code cuts at (brackets, separators, slashes, article prefixes) is an ASCII
// character, so code-point indices give exactly the slices of the JS UTF-16 indices. The JS
// regular expressions are ported by hand (see the comment above each helper).

/// A tolerance that was needed to accept an answer (`result.notes`, in `NOTE_ORDER`).
public enum GradeNote: String, Codable, Sendable, CaseIterable, Hashable {
    case article
    case pronoun
    case abbreviation
    case partial
    case parentheses
    /// JSON "case" (a Swift keyword): capitalisation differed (German only).
    case letterCase = "case"
    case accents
    case typo
    case order
    /// Accepted as the answer of a synonym card (only added by `Synonyms.gradeWithSynonyms`).
    case synonym
    /// Accepted as a word with the same meaning that is not in the set (found by the on-device
    /// language model; only added by `Synonyms.gradeWithSynonyms` with `extraAnswers`).
    case extendedSynonym
}

/// The most helpful hint for a wrong answer (`result.hint`, priority in `HINT_ORDER`).
public enum GradeHint: String, Codable, Sendable, CaseIterable, Hashable {
    case wrongArticle, missingArticle, accentsOnly, caseOnly, typo, almost
}

/// Result of `grade`. `hint` is encoded as explicit `null` when absent (like JS).
public struct GradeResult: Codable, Sendable, Equatable, Hashable {
    public var correct: Bool
    /// Correct without any tolerance.
    public var exact: Bool
    /// Tolerances used (empty for wrong or exact answers), in `NOTE_ORDER`.
    public var notes: [GradeNote]
    /// Only for wrong answers.
    public var hint: GradeHint?
    /// The stored answer as given (`String(expected)`), for the feedback.
    public var expectedDisplay: String

    public init(correct: Bool, exact: Bool, notes: [GradeNote] = [], hint: GradeHint? = nil, expectedDisplay: String) {
        self.correct = correct
        self.exact = exact
        self.notes = notes
        self.hint = hint
        self.expectedDisplay = expectedDisplay
    }

    enum CodingKeys: String, CodingKey { case correct, exact, notes, hint, expectedDisplay }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(correct, forKey: .correct)
        try c.encode(exact, forKey: .exact)
        try c.encode(notes, forKey: .notes)
        try c.encodeNullable(hint, forKey: .hint)
        try c.encode(expectedDisplay, forKey: .expectedDisplay)
    }
}

/// Kind of a diff segment: `same`, `del` (typed but wrong), `add` (missing).
public enum DiffType: String, Codable, Sendable, CaseIterable, Hashable {
    case same, del, add
}

/// `{ type, text }` of `diffChars` / `diffAnswer`.
public struct DiffSegment: Codable, Sendable, Equatable, Hashable {
    public var type: DiffType
    public var text: String

    public init(type: DiffType, text: String) {
        self.type = type
        self.text = text
    }
}

/// An `ABBREVIATIONS` entry: `pattern` is the JS RegExp source (flags "giu", case-insensitive,
/// Unicode, global) and `canonical` its expansion. Applied in order.
public struct AbbreviationRule: Sendable, Equatable, Hashable {
    public var pattern: String
    public var canonical: String

    public init(pattern: String, canonical: String) {
        self.pattern = pattern
        self.canonical = canonical
    }

    /// `(?<![\p{L}\p{N}])` in JS.
    public static let wordStart = #"(?<![\p{L}\p{N}])"#
    /// `(?![\p{L}\p{N}])` in JS.
    public static let wordEnd = #"(?![\p{L}\p{N}])"#
    /// The start of the standalone "u." rule: not after a letter, digit or dot ("u.a." stays).
    public static let wordStartNoDot = #"(?<![\p{L}\p{N}.])"#

    /// JS `abbr(body, canonical, start)`.
    public static func abbr(_ body: String, _ canonical: String, start: String = wordStart) -> AbbreviationRule {
        AbbreviationRule(pattern: "\(start)(?:\(body))\(wordEnd)", canonical: canonical)
    }
}

/// Port of src/core/grading.js: answer grading for Write and Learn mode.
public enum Grading {
    /// Articles per answer language.
    public static let ARTICLES: [Lang: [String]] = [
        .fr: ["le", "la", "les", "l'", "un", "une", "des", "du", "de la", "de l'"],
        .de: ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines"],
        .en: ["the", "a", "an", "to"],
        .es: ["el", "la", "los", "las", "un", "una", "unos", "unas"],
        .it: ["il", "lo", "la", "i", "gli", "le", "l'", "un", "uno", "una", "un'"],
    ]

    /// Reflexive pronouns per answer language (note the trailing spaces, as in JS).
    public static let REFLEXIVES: [Lang: [String]] = [
        .fr: ["se ", "s'"],
        .de: ["sich "],
        .en: ["oneself"],
        .es: [],
        .it: [],
    ]

    /// `[pattern, canonical expansion]`, applied in order, case-insensitive.
    public static let ABBREVIATIONS: [AbbreviationRule] = [
        .abbr(#"etw\.?"#, "etwas"),
        .abbr(#"jdn\.?|jmdn\.?"#, "jemanden"),
        .abbr(#"jdm\.?|jmdm\.?"#, "jemandem"),
        .abbr(#"jds\.?|jmds\.?"#, "jemandes"),
        .abbr(#"jd\.?|jmd\.?"#, "jemand"),
        .abbr(#"s\.\s?th\.?|smth\.?|sth\.?"#, "something"),
        .abbr(#"s\.\s?b\.?|s\.\s?o\.?|smb\.?|sb\.?|someone"#, "somebody"),
        .abbr(#"o\.\s?s\.?"#, "oneself"),
        .abbr(#"qqch\.?|qqc\.?|qch\.?|qc\.?"#, "quelque chose"),
        .abbr(#"qqn\.?|qn\.?"#, "quelqu'un"),
        .abbr(#"z\.?\s?b\.?"#, "zum Beispiel"),
        .abbr(#"usw\.?"#, "und so weiter"),
        .abbr(#"bzw\.?"#, "beziehungsweise"),
        .abbr(#"od\.?"#, "oder"),
        .abbr(#"u\."#, "und", start: AbbreviationRule.wordStartNoDot),
    ]

    /// `DEFAULT_TOLERANCE` (= `DEFAULT_STUDY_OPTIONS.tolerance`).
    public static let DEFAULT_TOLERANCE = Tolerance.default

    /// Order of `notes` in a result.
    public static let NOTE_ORDER: [GradeNote] = [
        .article, .pronoun, .abbreviation, .partial, .parentheses, .letterCase, .accents, .typo, .order,
    ]

    /// Priority of hints.
    public static let HINT_ORDER: [GradeHint] = [
        .wrongArticle, .missingArticle, .accentsOnly, .caseOnly, .typo, .almost,
    ]

    /// More alternatives than this → compare as a single string.
    static let maxParts = 24
    /// Longer strings skip edit-distance comparisons.
    static let maxDistLen = 200
    /// LCS table cap for `diffChars`.
    static let maxDiffCells = 1_000_000
    static let maxParenVariants = 64
    static let maxSlashVariants = 16
    static let almostSimilarity = 0.75

    // MARK: - Public API

    /// The alternatives of an answer ("laid, laide" → ["laid", "laide"]), without grammar
    /// annotations. `lang` is the language of the answer (sentences are not split at commas).
    public static func splitAlternatives(_ expected: String, lang: Lang? = nil) -> [String] {
        let s = normalizeBasic(JSText(expected))
        return splitInternal(s, commas: !isSentenceLike(s, lang: resolvedLang(lang))).alts.map(\.string)
    }

    /// Whether `given` matches `expected` under `tolerance`; `lang` is the answer's language.
    /// Never throws (the JS safety net compares normalised strings on internal errors, which the
    /// port cannot hit).
    public static func grade(given: String, expected: String, tolerance: Tolerance = .default, lang: Lang? = nil)
        -> GradeResult
    {
        let tol = tolerance
        let lang = resolvedLang(lang)
        func result(_ correct: Bool, _ exact: Bool, _ notes: [GradeNote] = [], _ hint: GradeHint? = nil)
            -> GradeResult
        {
            GradeResult(correct: correct, exact: exact, notes: notes, hint: hint, expectedDisplay: expected)
        }

        let gPrep = prep(JSText(given))
        let ePrep = prep(JSText(expected))
        if gPrep.isEmpty { return result(false, false) }

        // A sentence is one answer for both sides: its commas are not separators.
        let commas = !isSentenceLike(ePrep, lang: lang)
        let (eSegs, eNotes) = splitInternal(ePrep, commas: commas)
        let gSegs = splitInternal(gPrep, commas: commas, allowed: Set(eNotes.map(noteKey))).alts
        let eKey = JSText.joined(eSegs.map(keyOf), separator: "|")
        if !eKey.isEmpty && JSText.joined(gSegs.map(keyOf), separator: "|") == eKey { return result(true, true) }
        if eSegs.isEmpty && !hasAlnum(ePrep) {
            // Only punctuation or symbols ("?", "…", "-"): compare them as typed.
            let ok = symbolKey(gPrep) == symbolKey(ePrep)
            return result(ok, ok)
        }

        var altTexts = lang.map { mergeLoneArticles(eSegs, lang: $0) } ?? eSegs
        if altTexts.count > maxParts { altTexts = [ePrep] }
        let alts = altTexts.map { prepareAlt($0, tol: tol, lang: lang) }.filter { !$0.variants.isEmpty }
        let givenPart = { (t: JSText) in makeForms(t, tol: tol, lang: lang) }
        let parts = (gSegs.count > maxParts ? [gPrep] : gSegs).map(givenPart).filter { !$0.raw.text.isEmpty }
        if alts.isEmpty || parts.isEmpty { return result(false, false) }

        // Read the answer as separate parts first, then as one string, e.g. for
        // "freuen über, auf" against "freuen (über, auf)".
        var readings = [parts]
        if parts.count > 1 { readings.append([givenPart(gPrep)]) }
        let folds = FoldCache()
        var failure: (parts: [Forms], evaluation: Evaluation)?
        for ps in readings {
            let res = evaluate(ps, alts, tol: tol, lang: lang, folds: folds)
            if res.correct { return result(true, false, NOTE_ORDER.filter(res.notes.contains)) }
            if failure == nil { failure = (ps, res) }
        }
        guard let failure else { return result(false, false) }
        let hint = computeHint(
            parts: failure.parts, evaluation: failure.evaluation, alts: alts, altTexts: altTexts, tol: tol, lang: lang,
            given: gPrep, expected: ePrep, folds: folds)
        return result(false, false, [], hint)
    }

    /// Character diff for highlighting (code points, NFC, trimmed): `del` = typed but wrong,
    /// `add` = missing.
    public static func diffChars(_ given: String, _ expected: String) -> [DiffSegment] {
        let a = JSText(JSCompat.nfc(given)).trimmed().scalars
        let b = JSText(JSCompat.nfc(expected)).trimmed().scalars
        var out: [DiffSegment] = []
        func push(_ type: DiffType, _ chars: ArraySlice<Unicode.Scalar>) {
            guard !chars.isEmpty else { return }
            let text = JSText(chars).string
            if let last = out.last, last.type == type {
                out[out.count - 1].text += text
            } else {
                out.append(DiffSegment(type: type, text: text))
            }
        }
        var pre = 0
        while pre < a.count && pre < b.count && a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre && suf < b.count - pre && a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        push(.same, a[0..<pre])
        let x = Array(a[pre..<(a.count - suf)])
        let y = Array(b[pre..<(b.count - suf)])
        let n = x.count
        let m = y.count
        if n > 0 && m > 0 && (n + 1) * (m + 1) <= maxDiffCells {
            // dp[i * w + j] = LCS length of x[i:] and y[j:]
            let w = m + 1
            var dp = [UInt32](repeating: 0, count: (n + 1) * w)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i * w + j] = x[i] == y[j]
                        ? dp[(i + 1) * w + j + 1] + 1
                        : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < n && j < m {
                if x[i] == y[j] {
                    push(.same, x[i...i])
                    i += 1
                    j += 1
                } else if dp[(i + 1) * w + j] >= dp[i * w + j + 1] {
                    push(.del, x[i...i])
                    i += 1
                } else {
                    push(.add, y[j...j])
                    j += 1
                }
            }
            push(.del, x[i...])
            push(.add, y[j...])
        } else {
            push(.del, x[...])
            push(.add, y[...])
        }
        push(.same, a[(a.count - suf)...])
        return out
    }

    /// `diffChars` for the answer feedback: both sides get the normalisation that grading treats
    /// as equal (apostrophes, spaces, ß ≡ ss, œ ≡ oe), so only real mistakes are highlighted. A
    /// ligature is kept when the learner typed one.
    public static func diffAnswer(_ given: String, _ expected: String) -> [DiffSegment] {
        var g = squeezeApostrophes(normalizeBasic(JSText(given)))
        var e = squeezeApostrophes(normalizeBasic(JSText(expected)))
        if !g.contains(where: isLigature) {
            e = foldLigatures(e)
        } else if !e.contains(where: isLigature) {
            g = foldLigatures(g)
        }
        return diffChars(g.string, e.string)
    }

    /// JS `resolveLang`: the grading language of a language code ("de", "DE", " de-CH" → `.de`),
    /// nil for codes without articles ("other", "xx", "").
    public static func resolveLang(_ code: String?) -> Lang? {
        guard let code else { return nil }
        let short = JSText(code).trimmed().lowercased().slice(0, 2)
        return resolvedLang(Lang(rawValue: short.string))
    }

    /// Only languages with an article table count; `.other` grades without articles.
    static func resolvedLang(_ lang: Lang?) -> Lang? {
        guard let lang, articleTable[lang] != nil else { return nil }
        return lang
    }
}

// MARK: - JS string model

extension Grading {
    /// A string as the JS code sees it: a sequence of code points, compared and hashed by identity
    /// (no canonical equivalence, unlike Swift `String`).
    struct JSText: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        var scalars: [Unicode.Scalar]

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }
        init(_ scalars: ArraySlice<Unicode.Scalar>) { self.scalars = Array(scalars) }
        init(_ string: String) { scalars = Array(string.unicodeScalars) }
        init(stringLiteral value: String) { self.init(value) }

        var string: String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }

        var description: String { string }

        static func == (a: JSText, b: JSText) -> Bool { a.scalars == b.scalars }

        func hash(into hasher: inout Hasher) {
            scalars.withUnsafeBytes { hasher.combine(bytes: $0) }
        }

        var count: Int { scalars.count }
        var isEmpty: Bool { scalars.isEmpty }

        var isASCII: Bool {
            for u in scalars where !u.isASCII { return false }
            return true
        }

        var first: Unicode.Scalar? { scalars.first }
        var last: Unicode.Scalar? { scalars.last }
        subscript(i: Int) -> Unicode.Scalar { scalars[i] }

        /// JS `s[i]`: nil outside the string (`undefined`).
        func at(_ i: Int) -> Unicode.Scalar? { i >= 0 && i < scalars.count ? scalars[i] : nil }

        /// JS `s.slice(start, end)` for non-negative indices (clamped to the string).
        func slice(_ start: Int, _ end: Int? = nil) -> JSText {
            let lo = min(max(start, 0), scalars.count)
            let hi = max(min(end ?? scalars.count, scalars.count), lo)
            return JSText(scalars[lo..<hi])
        }

        static func + (a: JSText, b: JSText) -> JSText { JSText(a.scalars + b.scalars) }

        func hasPrefix(_ p: JSText) -> Bool { scalars.starts(with: p.scalars) }

        func hasSuffix(_ p: JSText) -> Bool {
            p.count <= count && scalars[(count - p.count)...].elementsEqual(p.scalars)
        }

        func contains(_ u: Unicode.Scalar) -> Bool { scalars.contains(u) }
        func contains(where predicate: (Unicode.Scalar) -> Bool) -> Bool { scalars.contains(where: predicate) }

        /// JS `s.trim()`.
        func trimmed() -> JSText {
            var lo = 0
            var hi = scalars.count
            while lo < hi && JSCompat.isWhitespace(scalars[lo]) { lo += 1 }
            while hi > lo && JSCompat.isWhitespace(scalars[hi - 1]) { hi -= 1 }
            return lo == 0 && hi == scalars.count ? self : JSText(scalars[lo..<hi])
        }

        /// JS `s.toLowerCase()`: full lowercase mappings plus the Greek final-sigma rule (Swift's
        /// `lowercased()` maps each scalar on its own).
        func lowercased() -> JSText {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(scalars.count)
            for i in 0..<scalars.count {
                let u = scalars[i]
                if u.isASCII {
                    out.append(u.value >= 0x41 && u.value <= 0x5A ? Unicode.Scalar(UInt8(u.value + 0x20)) : u)
                } else if u.value == 0x3A3 {
                    out.append(isFinalSigma(at: i) ? "\u{3C2}" : "\u{3C3}")
                } else if u.properties.changesWhenLowercased {
                    out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
                } else {
                    out.append(u)
                }
            }
            return JSText(out)
        }

        /// Final_Sigma (as ICU checks it): a cased letter before, none after, skipping
        /// case-ignorable characters on both sides.
        private func isFinalSigma(at i: Int) -> Bool {
            var j = i - 1
            var casedBefore = false
            while j >= 0 {
                let p = scalars[j].properties
                if p.isCaseIgnorable {
                    j -= 1
                    continue
                }
                casedBefore = p.isCased
                break
            }
            guard casedBefore else { return false }
            j = i + 1
            while j < scalars.count {
                let p = scalars[j].properties
                if p.isCaseIgnorable {
                    j += 1
                    continue
                }
                return !p.isCased
            }
            return true
        }

        /// JS `s.split(sep)` with a one-character separator (empty parts are kept).
        func split(_ separator: Unicode.Scalar) -> [JSText] {
            scalars.split(separator: separator, omittingEmptySubsequences: false).map(JSText.init)
        }

        /// JS `s.split(/[set]/)` (empty parts are kept).
        func split(where isSeparator: (Unicode.Scalar) -> Bool) -> [JSText] {
            scalars.split(omittingEmptySubsequences: false, whereSeparator: isSeparator).map(JSText.init)
        }

        /// JS `s.replace(/\s+/g, sep)`.
        func collapsingWhitespace(into separator: JSText) -> JSText {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(scalars.count)
            var inRun = false
            for u in scalars {
                if JSCompat.isWhitespace(u) {
                    if !inRun { out.append(contentsOf: separator.scalars) }
                    inRun = true
                } else {
                    out.append(u)
                    inRun = false
                }
            }
            return JSText(out)
        }

        /// `list.join(sep)`.
        static func joined(_ list: [JSText], separator: JSText) -> JSText {
            var out: [Unicode.Scalar] = []
            for k in 0..<list.count {
                if k > 0 { out.append(contentsOf: separator.scalars) }
                out.append(contentsOf: list[k].scalars)
            }
            return JSText(out)
        }
    }

    /// `normalizeBasic` of text.js.
    static func normalizeBasic(_ s: JSText) -> JSText {
        JSText(TextNormalizer.normalizeBasic(s.string))
    }
}

// MARK: - Character classes

extension Grading {
    /// `\p{L}`
    static func isL(_ u: Unicode.Scalar) -> Bool {
        u.isASCII ? isAsciiUpper(u.value) || isAsciiLower(u.value) : TextNormalizer.isLetterScalar(u)
    }

    /// `\p{N}`
    static func isN(_ u: Unicode.Scalar) -> Bool { u.isASCII ? isDigit(u) : TextNormalizer.isNumberScalar(u) }
    /// `[\p{L}\p{N}]`
    static func isAlnum(_ u: Unicode.Scalar) -> Bool { isL(u) || isN(u) }
    /// `\p{Lu}`
    static func isLu(_ u: Unicode.Scalar) -> Bool {
        u.isASCII ? isAsciiUpper(u.value) : TextNormalizer.isUppercaseLetter(u)
    }

    /// `\p{Ll}`
    static func isLl(_ u: Unicode.Scalar) -> Bool {
        u.isASCII ? isAsciiLower(u.value) : TextNormalizer.isLowercaseLetter(u)
    }

    private static func isAsciiUpper(_ v: UInt32) -> Bool { v >= 0x41 && v <= 0x5A }
    private static func isAsciiLower(_ v: UInt32) -> Bool { v >= 0x61 && v <= 0x7A }
    /// `\d` (ASCII digits, no `u` flag).
    static func isDigit(_ u: Unicode.Scalar) -> Bool { u.value >= 0x30 && u.value <= 0x39 }

    /// `PUNCT = /[.,!?;:"«»‹›¿¡…~*„“”‚]/`
    static func isPunct(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x2E, 0x2C, 0x21, 0x3F, 0x3B, 0x3A, 0x22, 0xAB, 0xBB, 0x2039, 0x203A, 0xBF, 0xA1, 0x2026, 0x7E, 0x2A,
             0x201E, 0x201C, 0x201D, 0x201A:
            return true
        default:
            return false
        }
    }

    /// `BRACKETS = /[()[\]{}]/`
    static func isBracket(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D: return true
        default: return false
        }
    }

    /// `LIGATURES = /[ßẞœŒæÆ]/`
    static func isLigature(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0xDF, 0x1E9E, 0x153, 0x152, 0xE6, 0xC6: return true
        default: return false
        }
    }

    /// `"(" | "["`
    fileprivate static func isOpening(_ u: Unicode.Scalar) -> Bool { u == "(" || u == "[" }
    /// `")" | "]"`
    fileprivate static func isClosing(_ u: Unicode.Scalar) -> Bool { u == ")" || u == "]" }

    /// `[\s"»«”“„)\]]` (stripped from the end of a sentence).
    fileprivate static func isSentenceCloser(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x22, 0xBB, 0xAB, 0x201D, 0x201C, 0x201E, 0x29, 0x5D: return true
        default: return JSCompat.isWhitespace(u)
        }
    }

    /// `[\s"«„“¿¡([]` (allowed before the capital that starts a sentence).
    fileprivate static func isSentenceOpener(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x22, 0xAB, 0x201E, 0x201C, 0xBF, 0xA1, 0x28, 0x5B: return true
        default: return JSCompat.isWhitespace(u)
        }
    }

    /// `[\s"«„“([]` (stripped from the start of a German noun list).
    fileprivate static func isNounListOpener(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x22, 0xAB, 0x201E, 0x201C, 0x28, 0x5B: return true
        default: return JSCompat.isWhitespace(u)
        }
    }

    /// `[^\s/]`
    fileprivate static func isWordChar(_ u: Unicode.Scalar) -> Bool { u != "/" && !JSCompat.isWhitespace(u) }
}

// MARK: - Tables

extension Grading {
    /// An article or reflexive pronoun of a language (lower case, trimmed).
    fileprivate struct ArticleEntry: Sendable {
        let token: JSText
        /// `.article` or `.pronoun`
        let kind: GradeNote
        let elided: Bool
    }

    /// Entries per language, longest token first (stable for equal lengths, like the JS sort).
    fileprivate static let articleTable: [Lang: [ArticleEntry]] = {
        var table: [Lang: [ArticleEntry]] = [:]
        for lang in [Lang.fr, .de, .en, .es, .it] {
            var entries: [ArticleEntry] = []
            func add(_ raw: String, _ kind: GradeNote) {
                let token = JSText(raw).trimmed().lowercased()
                if !token.isEmpty { entries.append(ArticleEntry(token: token, kind: kind, elided: token.last == "'")) }
            }
            ARTICLES[lang, default: []].forEach { add($0, .article) }
            REFLEXIVES[lang, default: []].forEach { add($0, .pronoun) }
            table[lang] = entries.enumerated()
                .sorted { $0.element.token.count != $1.element.token.count
                    ? $0.element.token.count > $1.element.token.count : $0.offset < $1.offset }
                .map(\.element)
        }
        return table
    }()

    /// Articles and reflexive pronouns of every language.
    fileprivate static let bareArticles: Set<JSText> = Set(
        articleTable.values.joined().filter { !$0.elided }.map(\.token))
    fileprivate static let elidedArticles: Set<JSText> = Set(articleTable.values.joined().filter(\.elided).map(\.token))
    /// Real articles only (no "to", no pronouns).
    fileprivate static let nounArticles: Set<JSText> = Set(
        articleTable.values.joined().filter { $0.kind == .article && $0.token != "to" }.map(\.token))
    fileprivate static let elidedNounArticles: Set<JSText> = nounArticles.filter { $0.last == "'" }
    fileprivate static let germanArticles: Set<JSText> = Set(ARTICLES[.de, default: []].map { JSText($0) })

    /// Elided forms and the full articles/pronouns they stand for (l'homme ≡ le homme).
    fileprivate static let elisions: [Lang: [JSText: [JSText]]] = [
        .fr: ["l'": ["le", "la"], "s'": ["se"], "de l'": ["de la", "du"]],
        .it: ["l'": ["lo", "la"], "un'": ["una"]],
    ]

    /// Contractions that open a phrase like an article ("jouer au foot/au tennis").
    fileprivate static let phraseStarters: Set<JSText> = ["au", "aux"]
    /// Contracted article → the preposition it contains ("à la plage/au cinéma").
    fileprivate static let contracted: [JSText: JSText] = ["au": "à", "aux": "à", "du": "de", "des": "de"]

    /// Placeholders for an object or reflexive slot ("an jdn./etw. denken", "sb/sth", "qn/qc",
    /// "etw./sich ändern"); abbreviations are compared by their expansion.
    fileprivate static let slotWords: Set<JSText> = [
        "etwas", "jemand", "jemanden", "jemandem", "jemandes", "sich",
        "something", "somebody", "oneself",
        "quelque chose", "quelqu'un", "se", "s'",
    ]
    fileprivate static let reflexiveSlots: Set<JSText> = ["sich", "oneself", "se", "s'"]
    /// French reflexives stand before the verb, object placeholders after it, so in
    /// "laver qc/se laver" the slash separates two whole verb phrases.
    fileprivate static let preverbalReflexives: Set<JSText> = ["se", "s'"]

    /// Short pronouns and determiners written as slash lists ("il/elle", "er/sie/es").
    fileprivate static let shortForms: Set<JSText> = [
        "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "te", "lui", "leur", "eux", "moi", "toi",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "ce", "cet", "cette", "ces",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mir", "dir", "mich", "dich",
        "he", "she", "it", "we", "they", "him", "her", "us", "them", "his", "its", "my", "your", "our", "their",
    ]

    fileprivate static let grammarMarkers: Set<JSText> = [
        "m", "f", "n", "pl", "sg", "etc", "irr", "ugs", "fam", "adj", "adv",
    ]
    fileprivate static let markerWords: Set<JSText> = ["m", "f", "n", "pl", "Pl", "sg", "Sg"]
    fileprivate static let genderPairs: Set<JSText> = ["m/f", "m./f", "m/f.", "m./f."]

    /// Grammar annotations written as their own comma part: plural or suffix notation
    /// ("der Tisch, -e", "die Mutter, ¨") and gender/number markers ("maison, f",
    /// "die Eltern, Pl."). Markers are lower case: "Mme, M." and "S, M, L" are answers.
    /// `/^(?:[-¨~].*|(?:m|f|n|pl|Pl|sg|Sg)\.?|m\.?\/f\.?)$/`
    fileprivate static func isAnnotation(_ s: JSText) -> Bool {
        guard let first = s.first else { return false }
        if first == "-" || first == "¨" || first == "~" {
            // `.` does not match line terminators.
            return !s.scalars.dropFirst().contains { [0x0A, 0x0D, 0x2028, 0x2029].contains($0.value) }
        }
        let core = s.last == "." ? s.slice(0, s.count - 1) : s
        return markerWords.contains(core) || genderPairs.contains(s)
    }

    /// `noteKey`: lower case without whitespace and dots.
    fileprivate static func noteKey(_ s: JSText) -> JSText {
        JSText(s.lowercased().scalars.filter { $0 != "." && !JSCompat.isWhitespace($0) })
    }
}

// MARK: - Abbreviations

extension Grading {
    fileprivate enum AbbreviationToken: Sendable {
        /// A letter (lower case ASCII), matched case-insensitively.
        case letter(UInt32)
        /// `\.`
        case dot
        /// `\.?`
        case optionalDot
        /// `\s?`
        case optionalSpace
    }

    /// An `AbbreviationRule` compiled for the hand-written matcher. JS semantics of the "giu"
    /// regex: alternatives in order, greedy optional parts with backtracking, the look-behind and
    /// look-ahead on code points, and case-insensitive letters by simple case folding (so "ſ"
    /// matches "s").
    fileprivate struct CompiledAbbreviation: Sendable {
        let alternatives: [[AbbreviationToken]]
        let canonical: JSText
        /// `canonical[0].toUpperCase() + canonical.slice(1)`
        let capitalised: JSText
        /// The look-behind also rejects a dot (`(?<![\p{L}\p{N}.])`).
        let noDotBefore: Bool
        /// The (folded, lower case ASCII) letters an alternative can start with, as a bit mask.
        let firstLetters: UInt32

        init?(_ rule: AbbreviationRule) {
            var p = Substring(rule.pattern)
            if p.hasPrefix(AbbreviationRule.wordStart) {
                p = p.dropFirst(AbbreviationRule.wordStart.count)
                noDotBefore = false
            } else if p.hasPrefix(AbbreviationRule.wordStartNoDot) {
                p = p.dropFirst(AbbreviationRule.wordStartNoDot.count)
                noDotBefore = true
            } else {
                return nil
            }
            let tail = ")" + AbbreviationRule.wordEnd
            guard p.hasPrefix("(?:"), p.hasSuffix(tail) else { return nil }
            let body = Array(p.dropFirst(3).dropLast(tail.count).unicodeScalars)
            var alternatives: [[AbbreviationToken]] = [[]]
            var i = 0
            while i < body.count {
                let c = body[i]
                if c == "|" {
                    alternatives.append([])
                    i += 1
                } else if c == "\\" {
                    guard i + 1 < body.count else { return nil }
                    let optional = i + 2 < body.count && body[i + 2] == "?"
                    switch body[i + 1] {
                    case ".": alternatives[alternatives.count - 1].append(optional ? .optionalDot : .dot)
                    case "s" where optional: alternatives[alternatives.count - 1].append(.optionalSpace)
                    default: return nil
                    }
                    i += optional ? 3 : 2
                } else if c.isASCII && c.properties.isAlphabetic {
                    alternatives[alternatives.count - 1].append(.letter(Grading.caseFold(c)))
                    i += 1
                } else {
                    return nil
                }
            }
            var firstLetters: UInt32 = 0
            for tokens in alternatives {
                guard case let .letter(v) = tokens.first, v >= 0x61 && v <= 0x7A else { return nil }
                firstLetters |= 1 << (v - 0x61)
            }
            self.alternatives = alternatives
            self.firstLetters = firstLetters
            canonical = JSText(rule.canonical)
            if let head = canonical.first {
                capitalised = JSText(Array(head.properties.uppercaseMapping.unicodeScalars)) + canonical.slice(1)
            } else {
                capitalised = canonical
            }
        }

        /// `s.replace(pattern, m => /^\p{Lu}/u.test(m) ? capitalised : canonical)`; nil when nothing
        /// matched. `starts` lists the positions a match can begin at (not after a letter or digit)
        /// with their folded letter.
        func replaceAll(in s: JSText, starts: [AbbreviationStart]) -> JSText? {
            var out: [Unicode.Scalar] = []
            var last = 0
            for start in starts where start.pos >= last {
                let pos = start.pos
                guard firstLetters & (1 << (start.letter - 0x61)) != 0 else { continue }
                if noDotBefore && pos > 0 && s[pos - 1] == "." { continue }
                if let end = match(s, at: pos) {
                    out.append(contentsOf: s.scalars[last..<pos])
                    out.append(contentsOf: (Grading.isLu(s[pos]) ? capitalised : canonical).scalars)
                    last = end
                }
            }
            if last == 0 { return nil }
            out.append(contentsOf: s.scalars[last...])
            return JSText(out)
        }

        /// The alternatives at `p` (the look-behind is checked by the caller).
        private func match(_ s: JSText, at p: Int) -> Int? {
            for tokens in alternatives {
                if let end = match(tokens, 0, s, p) { return end }
            }
            return nil
        }

        private func match(_ tokens: [AbbreviationToken], _ k: Int, _ s: JSText, _ p: Int) -> Int? {
            guard k < tokens.count else {
                // (?![\p{L}\p{N}])
                return p >= s.count || !Grading.isAlnum(s[p]) ? p : nil
            }
            switch tokens[k] {
            case let .letter(v):
                guard p < s.count, Grading.caseFold(s[p]) == v else { return nil }
                return match(tokens, k + 1, s, p + 1)
            case .dot:
                guard p < s.count, s[p] == "." else { return nil }
                return match(tokens, k + 1, s, p + 1)
            case .optionalDot:
                if p < s.count, s[p] == ".", let end = match(tokens, k + 1, s, p + 1) { return end }
                return match(tokens, k + 1, s, p)
            case .optionalSpace:
                if p < s.count, JSCompat.isWhitespace(s[p]), let end = match(tokens, k + 1, s, p + 1) { return end }
                return match(tokens, k + 1, s, p)
            }
        }
    }

    /// A position where a pattern can start (a letter not after a letter or digit), with the
    /// folded letter (a-z).
    fileprivate struct AbbreviationStart {
        let pos: Int
        let letter: UInt32
    }

    /// The simple case folding of the "iu" regex flags, for the letters the patterns use.
    fileprivate static func caseFold(_ u: Unicode.Scalar) -> UInt32 {
        let v = u.value
        if v >= 0x41 && v <= 0x5A { return v + 0x20 }
        if v == 0x17F { return 0x73 } // ſ → s
        if v == 0x212A { return 0x6B } // Kelvin sign → k
        return v
    }

    fileprivate static let compiledAbbreviations: [CompiledAbbreviation] = {
        let compiled = ABBREVIATIONS.compactMap(CompiledAbbreviation.init)
        assert(compiled.count == ABBREVIATIONS.count, "ABBREVIATIONS uses syntax the matcher does not support")
        return compiled
    }()

    /// A capitalised abbreviation ("Etw.") expands capitalised ("Etwas").
    static func expandAbbreviations(_ s: JSText) -> JSText {
        // Positions where a pattern can start: a letter not preceded by a letter or digit.
        func starts(_ t: JSText) -> [AbbreviationStart] {
            var list: [AbbreviationStart] = []
            var prevAlnum = false
            for i in 0..<t.count {
                let u = t[i]
                if !prevAlnum {
                    let letter = caseFold(u)
                    if letter >= 0x61 && letter <= 0x7A { list.append(AbbreviationStart(pos: i, letter: letter)) }
                }
                prevAlnum = isAlnum(u)
            }
            return list
        }
        var text = s
        var positions = starts(text)
        if positions.isEmpty { return text }
        for rule in compiledAbbreviations {
            if let replaced = rule.replaceAll(in: text, starts: positions) {
                text = replaced
                positions = starts(text)
            }
        }
        return text
    }
}

// MARK: - Normalisation helpers

extension Grading {
    /// `\p{L}` count.
    fileprivate static func countLetters(_ s: JSText) -> Int { s.scalars.reduce(0) { $0 + (isL($1) ? 1 : 0) } }

    /// `/[\p{L}\p{N}]/u.test(s)`
    fileprivate static func hasAlnum(_ s: JSText) -> Bool { s.contains(where: isAlnum) }

    /// ß ≡ ss, œ ≡ oe, æ ≡ ae (the JS replacements, one after the other).
    static func foldLigatures(_ s: JSText) -> JSText {
        guard s.contains(where: isLigature) else { return s }
        var t = s.scalars
        func replace(_ target: Unicode.Scalar, _ with: String, beforeLowercase: Bool = false) {
            guard t.contains(target) else { return }
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(t.count + 4)
            for (i, u) in t.enumerated() {
                if u == target && (!beforeLowercase || (i + 1 < t.count && isLl(t[i + 1]))) {
                    out.append(contentsOf: with.unicodeScalars)
                } else {
                    out.append(u)
                }
            }
            t = out
        }
        replace("\u{1E9E}", "SS")
        replace("ß", "ss")
        replace("Œ", "Oe", beforeLowercase: true)
        replace("Œ", "OE")
        replace("œ", "oe")
        replace("Æ", "Ae", beforeLowercase: true)
        replace("Æ", "AE")
        replace("æ", "ae")
        return JSText(t)
    }

    /// `s.replace(/ *' */g, "'")`: no spaces next to apostrophes ("s' appeler").
    static func squeezeApostrophes(_ s: JSText) -> JSText {
        guard s.contains("'") else { return s }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if s[i] == " " {
                var j = i
                while j < s.count && s[j] == " " { j += 1 }
                let touches = (i > 0 && s[i - 1] == "'") || (j < s.count && s[j] == "'")
                if !touches { out.append(contentsOf: s.scalars[i..<j]) }
                i = j
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return JSText(out)
    }

    /// Normalisation that always applies: whitespace, apostrophes, dashes, ligatures, no spaces
    /// around apostrophes ("s' appeler").
    fileprivate static func prep(_ value: JSText) -> JSText {
        squeezeApostrophes(foldLigatures(normalizeBasic(value)))
    }

    /// Whitespace collapsed, no spaces around apostrophes, trimmed.
    fileprivate static func tidy(_ s: JSText) -> JSText {
        squeezeApostrophes(s.collapsingWhitespace(into: " ")).trimmed()
    }

    /// Comparison text: hyphen ≡ space, punctuation and leftover brackets dropped.
    fileprivate static func clean(_ s: JSText) -> JSText {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        for u in s.scalars {
            if u == "-" {
                out.append(" ")
            } else if !isPunct(u) && !isBracket(u) {
                out.append(u)
            }
        }
        return tidy(JSText(out))
    }

    /// Exactness key: like `clean` but brackets still count.
    fileprivate static func keyOf(_ s: JSText) -> JSText {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        for u in s.scalars {
            if u == "-" {
                out.append(" ")
            } else if !isPunct(u) {
                out.append(u)
            }
        }
        return tidy(JSText(out))
    }

    /// `s.replace(/\s+/g, '').replace(/\.\.\./g, '…')`
    fileprivate static func symbolKey(_ s: JSText) -> JSText {
        let t = s.scalars.filter { !JSCompat.isWhitespace($0) }
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < t.count {
            if i + 2 < t.count && t[i] == "." && t[i + 1] == "." && t[i + 2] == "." {
                out.append("…")
                i += 3
            } else {
                out.append(t[i])
                i += 1
            }
        }
        return JSText(out)
    }
}

// MARK: - Alternatives: "lieb, nett", "beau/belle", "der/die Angestellte"

extension Grading {
    fileprivate static func bracketsBalanced(_ s: JSText) -> Bool {
        var depth = 0
        for u in s.scalars {
            if isOpening(u) {
                depth += 1
            } else if isClosing(u) {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    /// Calls `visit(ch, i)` for every character outside brackets (when balanced); stops when it
    /// returns false.
    fileprivate static func scanTopLevel(_ s: JSText, _ visit: (Unicode.Scalar, Int) -> Bool) {
        let track = bracketsBalanced(s)
        var depth = 0
        for i in 0..<s.count {
            let ch = s[i]
            if track && isOpening(ch) {
                depth += 1
            } else if track && isClosing(ch) {
                depth -= 1
            } else if depth == 0 && !visit(ch, i) {
                return
            }
        }
    }

    /// Splits on top-level ',' ';' and spaced '/' (never between digits: "1,5 kg"). With
    /// `commas` false (a sentence) a comma only cuts after '?', '!' or '…'.
    fileprivate static func splitSegments(_ s: JSText, commas: Bool = true) -> [JSText] {
        var out: [JSText] = []
        var start = 0
        scanTopLevel(s) { ch, i in
            let prev = s.at(i - 1) ?? " "
            let next = s.at(i + 1) ?? " "
            let cut: Bool
            switch ch {
            case ";": cut = true
            case ",": cut = commas ? !(isDigit(prev) && isDigit(next)) : (prev == "?" || prev == "!" || prev == "…")
            case "/": cut = prev == " " || next == " "
            default: cut = false
            }
            if cut {
                out.append(s.slice(start, i))
                start = i + 1
            }
            return true
        }
        out.append(s.slice(start))
        return out
    }

    /// A comma inside a sentence ("Ça va bien, merci.", "Danke, gleichfalls!") does not separate
    /// answers. A final dot only ends a sentence that starts with a capital and ends in a real
    /// word, not a list ("ja, nein.") or one ending in an abbreviation, marker or article
    /// ("jdn. fragen, etw. tun.", "maison, f.", "Herr, der."). German capitalises nouns, so
    /// "Mappe, Tasche." is a list of nouns.
    fileprivate static func isSentenceLike(_ s: JSText, lang: Lang?) -> Bool {
        guard s.contains(",") else { return false }
        var end = s.count
        while end > 0 && isSentenceCloser(s[end - 1]) { end -= 1 }
        let t = s.slice(0, end)
        // /(?:[?!…]|\.\.\.)$/
        if let last = t.last, last == "?" || last == "!" || last == "…" { return true }
        if t.hasSuffix("...") { return true }
        // /^[\s"«„“¿¡([]*\p{Lu}/u
        var i = 0
        while i < t.count && isSentenceOpener(t[i]) { i += 1 }
        guard i < t.count, isLu(t[i]) else { return false }
        // /([\p{L}']+)\.$/u
        guard t.last == "." else { return false }
        var start = t.count - 1
        while start > 0 && (isL(t[start - 1]) || t[start - 1] == "'") { start -= 1 }
        guard start < t.count - 1 else { return false }
        let word = t.slice(start, t.count - 1)
        let low = word.lowercased()
        if countLetters(low) < 2 || grammarMarkers.contains(low) || bareArticles.contains(low) { return false }
        let dotted = word + "."
        if expandAbbreviations(dotted) != dotted { return false }
        return !(lang == .de && isGermanNounList(t))
    }

    /// Every comma part is one capitalised word, optionally after an article: "Mappe, Tasche.",
    /// "Die Mappe, die Tasche." (but not "Guten Tag, Frau Müller.").
    fileprivate static func isGermanNounList(_ t: JSText) -> Bool {
        var i = 0
        while i < t.count && isNounListOpener(t[i]) { i += 1 }
        var body = t.slice(i)
        if body.last == "." { body = body.slice(0, body.count - 1) }
        let parts = body.split { $0 == "," || $0 == ";" }.map { $0.trimmed() }.filter { !$0.isEmpty }
        return parts.allSatisfy { part in
            let words = part.scalars.split(whereSeparator: JSCompat.isWhitespace).map(JSText.init)
            guard let lastWord = words.last, let head = lastWord.first else { return false }
            let article = words.count == 2 && germanArticles.contains(words[0].lowercased())
            // /^\p{Lu}[\p{L}'-]*$/u
            return (words.count == 1 || article) && isLu(head)
                && lastWord.scalars.dropFirst().allSatisfy { isL($0) || $0 == "'" || $0 == "-" }
        }
    }

    fileprivate static func isBareArticle(_ w: JSText) -> Bool { bareArticles.contains(w.lowercased()) }

    fileprivate static func startsPhrase(_ w: JSText) -> Bool {
        let low = w.lowercased()
        if bareArticles.contains(low) || phraseStarters.contains(low) { return true }
        return elidedArticles.contains { low.count > $0.count && low.hasPrefix($0) }
    }

    /// The word opens a noun phrase with a real article ("das Haus der Familie").
    fileprivate static func opensNounPhrase(_ w: JSText) -> Bool {
        let low = w.lowercased()
        if nounArticles.contains(low) { return true }
        return elidedNounArticles.contains { low.count > $0.count && low.hasPrefix($0) }
    }

    /// Index of the group in the words left of a slash that the article group right of it
    /// replaces: "faire du vélo/du ski" → 1, "aller à la plage/au cinéma" → 1. -1 when the right
    /// side is not such a group (pronouns and "to" start whole phrases: "aller au lit/se coucher")
    /// or the left side is a noun phrase itself ("das Haus der Familie/die Wohnung").
    fileprivate static func parallelGroupStart(_ lw: [JSText], _ firstRight: JSText) -> Int {
        func opensGroup(_ w: JSText) -> Bool { opensNounPhrase(w) || phraseStarters.contains(w.lowercased()) }
        if !opensGroup(firstRight) || opensNounPhrase(lw[0]) { return -1 }
        for j in stride(from: lw.count - 1, through: 1, by: -1) {
            let low = lw[j].lowercased()
            // A bare starter needs a word after it; an elided one carries it ("l'école").
            let bare = nounArticles.contains(low) || phraseStarters.contains(low)
            if !opensGroup(lw[j]) || (bare && j == lw.count - 1) { continue }
            if let prep = contracted[firstRight.lowercased()], lw[j - 1].lowercased() == prep { return j - 1 }
            return j
        }
        return -1
    }

    fileprivate static func slotWord(_ text: JSText) -> JSText { expandAbbreviations(clean(text)).lowercased() }
    fileprivate static func isSlot(_ text: JSText) -> Bool { slotWords.contains(slotWord(text)) }

    /// Number of words (0-2) that form a placeholder at the end or the start of `words`.
    fileprivate static func slotSpan(_ words: [JSText], atEnd: Bool) -> Int {
        var n = min(2, words.count)
        while n > 0 {
            let span = atEnd ? Array(words.suffix(n)) : Array(words.prefix(n))
            if isSlot(JSText.joined(span, separator: " ")) { return n }
            n -= 1
        }
        return 0
    }

    /// `s.match(/[^\s/]*$/)[0]`
    fileprivate static func trailingWord(_ s: JSText) -> JSText {
        var start = s.count
        while start > 0 && isWordChar(s[start - 1]) { start -= 1 }
        return s.slice(start)
    }

    /// `s.match(/^[^\s/]*/)[0]`
    fileprivate static func leadingWord(_ s: JSText) -> JSText {
        var end = 0
        while end < s.count && isWordChar(s[end]) { end += 1 }
        return s.slice(0, end)
    }

    /// An unspaced slash separates alternatives when both sides look like words (≥ 3 letters),
    /// articles, placeholders ("sb/sth") or short pronouns ("il/elle"), never for suffix notation
    /// like "Lehrer/in".
    fileprivate static func isAlternationSlash(_ seg: JSText, _ i: Int) -> Bool {
        let left = seg.slice(0, i)
        let right = seg.slice(i + 1)
        let lw = trailingWord(left)
        let rw = leadingWord(right)
        guard let lHead = lw.first, let rHead = rw.first, rHead != "-" else { return false }
        if isSlot(lw) && isSlot(rw) { return true } // "jdn./etw.", "sb/sth", "qn/qc"
        if shortForms.contains(lw.lowercased()) && shortForms.contains(rw.lowercased()) { return true } // "il/elle"
        let rightWords = right.trimmed().split(" ").count
        if rightWords == 1 && isLu(lHead) && isLl(rHead) { return false } // "Lehrer/innen"
        if isBareArticle(lw) && isBareArticle(rw) { return true } // "le/la", "der/die"
        if startsPhrase(rw) && rightWords >= 2 && countLetters(lw) >= 2 { return true } // "le chat/la chatte"
        // A short object placeholder is a word too ("habiller qn/s'habiller"); "se" is not, it
        // is also a suffix ("gros/se").
        func wordLike(_ w: JSText) -> Bool {
            countLetters(w) >= 3 || (isSlot(w) && !reflexiveSlots.contains(slotWord(w)))
        }
        return wordLike(lw) && wordLike(rw)
    }

    fileprivate static func expandSlashes(_ seg: JSText, depth: Int = 0) -> [JSText] {
        var at = -1
        if depth < 6 {
            scanTopLevel(seg) { ch, i in
                if ch == "/" && isAlternationSlash(seg, i) {
                    at = i
                    return false
                }
                return true
            }
        }
        if at < 0 { return [seg] }
        let left = seg.slice(0, at).trimmed()
        let right = seg.slice(at + 1).trimmed()
        let lw = left.split(" ")
        let rw = right.split(" ")
        let lastLeft = trailingWord(left)
        let firstRight = leadingWord(right)
        // The slash binds the nl words before it and the nr words after it:
        // "der/die Angestellte", "etw. tun/machen", "an jdn./etw. denken".
        func bind(_ nl: Int, _ nr: Int) -> [JSText] {
            let prefix = Array(lw[0..<(lw.count - nl)])
            let suffix = Array(rw[nr...])
            return [
                JSText.joined(prefix + lw[(lw.count - nl)...] + suffix, separator: " "),
                JSText.joined(prefix + rw[0..<nr] + suffix, separator: " "),
            ]
        }
        let nl = slotSpan(lw, atEnd: true)
        let nr = slotSpan(rw, atEnd: false)
        let group = parallelGroupStart(lw, firstRight)
        let pieces: [JSText]
        if nl > 0 && nr > 0 {
            let leftSlot = slotWord(JSText.joined(Array(lw.suffix(nl)), separator: " "))
            let rightSlot = slotWord(JSText.joined(Array(rw.prefix(nr)), separator: " "))
            let verbPhrases = lw.count > nl && rw.count > nr && preverbalReflexives.contains(rightSlot)
                && !reflexiveSlots.contains(leftSlot)
            // "laver qc/se laver" | "an jdn./etw. denken", "etw./sich ändern", "to wash sth/oneself"
            pieces = verbPhrases ? [left, right] : bind(nl, nr)
        } else if isBareArticle(lastLeft) && isBareArticle(firstRight) {
            pieces = bind(1, 1) // "mit der/dem Lehrer"
        } else if group > 0 {
            pieces = [left, JSText.joined(Array(lw[0..<group]) + rw, separator: " ")] // "faire du vélo/du ski"
        } else if lw.count == rw.count || (startsPhrase(firstRight) && !isBareArticle(lastLeft)) {
            pieces = [left, right] // "beau/belle", "der Lehrer/die Lehrerin"
        } else {
            pieces = bind(1, 1)
        }
        var out: [JSText] = []
        for piece in pieces {
            for x in expandSlashes(piece, depth: depth + 1) where out.count < maxSlashVariants {
                out.append(x)
            }
        }
        return out
    }

    /// Splits an answer into alternatives and sets aside the grammar annotations of the answer
    /// before them ("der Tisch, -e", "maison, f"). The stored answer drops every annotation; the
    /// learner's answer only drops the stored ones (`allowed` note keys), so "der Tisch, -s" for
    /// "der Tisch, -e" is still wrong.
    fileprivate static func splitInternal(_ s: JSText, commas: Bool = true, allowed: Set<JSText>? = nil)
        -> (alts: [JSText], notes: [JSText])
    {
        var alts: [JSText] = []
        var notes: [JSText] = []
        var seen: Set<JSText> = []
        for seg in splitSegments(s, commas: commas) {
            for piece in expandSlashes(seg.trimmed()) {
                let alt = normalizeBasic(piece)
                if clean(alt).isEmpty || seen.contains(alt) { continue }
                let annotation = !alts.isEmpty && isAnnotation(alt) && !isAnnotation(alts[alts.count - 1])
                if annotation && (allowed.map { $0.contains(noteKey(alt)) } ?? true) {
                    notes.append(alt)
                    continue
                }
                seen.insert(alt)
                alts.append(alt)
            }
        }
        return (alts, notes)
    }
}

// MARK: - Parentheses: "(sich) freuen" → "freuen" | "sich freuen"; "marié(e)" → "marié" | "mariée"

extension Grading {
    fileprivate struct BracketGroup {
        let start: Int
        let end: Int
        let content: JSText
    }

    fileprivate struct ParenVariant {
        let text: JSText
        let omitted: Bool
        let lock: Bool
    }

    fileprivate static func bracketGroups(_ s: JSText) -> [BracketGroup] {
        guard bracketsBalanced(s) else { return [] }
        var groups: [BracketGroup] = []
        var depth = 0
        var start = -1
        for i in 0..<s.count {
            let ch = s[i]
            if isOpening(ch) {
                if depth == 0 { start = i }
                depth += 1
            } else if isClosing(ch) {
                depth -= 1
                if depth == 0 { groups.append(BracketGroup(start: start, end: i + 1, content: s.slice(start + 1, i))) }
            }
        }
        return groups
    }

    fileprivate static func parenVariants(_ alt: JSText, optional: Bool) -> [ParenVariant] {
        let groups = bracketGroups(alt)
        if groups.isEmpty { return [ParenVariant(text: alt, omitted: false, lock: false)] }
        // With the toggle off, a bracketed leading article/pronoun is required too.
        let lock = !optional && alt.first.map(isOpening) == true
        let choices: [[(text: JSText, omitted: Bool)]] = groups.map { g in
            var list: [(text: JSText, omitted: Bool)] = [(g.content, false)]
            if optional {
                list.insert(("", hasAlnum(g.content)), at: 0)
                let subs = splitSegments(g.content)
                    .flatMap { expandSlashes($0.trimmed()) }
                    .filter { !clean($0).isEmpty }
                if subs.count > 1 { list.append(contentsOf: subs.map { ($0, false) }) }
            }
            return list
        }
        var total = 1
        for list in choices where total <= maxParenVariants { total *= list.count }
        var picks: [[(text: JSText, omitted: Bool)]]
        if total > maxParenVariants {
            picks = [choices.map { $0[$0.count > 1 ? 1 : 0] }]
            if optional { picks.append(choices.map { $0[0] }) }
        } else {
            picks = [[]]
            for list in choices {
                picks = picks.flatMap { p in list.map { p + [$0] } }
            }
        }
        return picks.map { p in
            var text: [Unicode.Scalar] = []
            var pos = 0
            for (k, g) in groups.enumerated() {
                text.append(contentsOf: alt.scalars[pos..<g.start])
                text.append(contentsOf: p[k].text.scalars)
                pos = g.end
            }
            text.append(contentsOf: alt.scalars[pos...])
            return ParenVariant(text: tidy(JSText(text)), omitted: p.contains { $0.omitted }, lock: lock)
        }
    }
}

// MARK: - Articles and reflexive pronouns

extension Grading {
    fileprivate struct ArticleSplit {
        let text: JSText
        /// The article as typed (nil when there is none).
        let article: JSText?
        /// `.article` or `.pronoun` (nil when there is no article).
        let kind: GradeNote?
        /// The text after the article (= `text` when there is none).
        let core: JSText
    }

    fileprivate static func splitArticle(_ text: JSText, lang: Lang?) -> ArticleSplit {
        if let lang, let table = articleTable[lang] {
            for entry in table {
                let n = entry.token.count
                if !lowercasedPrefix(of: text, equals: entry.token) { continue }
                let rest = text.slice(n)
                if !entry.elided && rest.at(0) != " " { continue }
                let core = rest.trimmed()
                if !core.isEmpty && hasAlnum(core) {
                    return ArticleSplit(text: text, article: text.slice(0, n), kind: entry.kind, core: core)
                }
            }
        }
        return ArticleSplit(text: text, article: nil, kind: nil, core: text)
    }

    /// `text.slice(0, token.length).toLowerCase() === token`. For an ASCII token only ASCII
    /// letters (and the Kelvin sign, which lowercases to "k") can match, one scalar each.
    fileprivate static func lowercasedPrefix(of text: JSText, equals token: JSText) -> Bool {
        guard token.isASCII else { return text.slice(0, token.count).lowercased() == token }
        guard text.count >= token.count else { return false }
        for k in 0..<token.count {
            let v = text[k].value
            let lower: UInt32 = v >= 0x41 && v <= 0x5A ? v + 0x20 : v < 0x80 ? v : v == 0x212A ? 0x6B : 0
            if lower != token[k].value { return false }
        }
        return true
    }

    fileprivate static func sameArticle(_ a: JSText, _ b: JSText, lang: Lang?) -> Bool {
        let x = a.lowercased()
        let y = b.lowercased()
        if x == y { return true }
        guard let lang, let map = elisions[lang] else { return false }
        return map[x]?.contains(y) == true || map[y]?.contains(x) == true
    }

    /// "Herr, der" (dictionary style) → "der Herr"
    fileprivate static func mergeLoneArticles(_ alts: [JSText], lang: Lang) -> [JSText] {
        guard let table = articleTable[lang] else { return alts }
        func loneArticle(_ alt: JSText) -> ArticleEntry? {
            let low = clean(alt).lowercased()
            return table.first { $0.kind == .article && $0.token == low }
        }
        var out: [JSText] = []
        for alt in alts {
            let low = clean(alt).lowercased()
            if let entry = loneArticle(alt), let prev = out.last, loneArticle(prev) == nil,
               splitArticle(clean(prev), lang: lang).article == nil
            {
                out[out.count - 1] = entry.elided ? low + prev : low + " " + prev
            } else {
                out.append(alt)
            }
        }
        return out
    }
}

// MARK: - Comparators

extension Grading {
    fileprivate struct Combo: Equatable, Sendable {
        /// Case ignored.
        let c: Bool
        /// Accents ignored.
        let a: Bool
        /// One or two typos allowed.
        let t: Bool
    }

    /// Least tolerant first.
    fileprivate static let combos: [Combo] = [
        Combo(c: false, a: false, t: false),
        Combo(c: true, a: false, t: false),
        Combo(c: false, a: true, t: false),
        Combo(c: true, a: true, t: false),
        Combo(c: false, a: false, t: true),
        Combo(c: true, a: false, t: true),
        Combo(c: false, a: true, t: true),
        Combo(c: true, a: true, t: true),
    ]

    /// The tolerances a comparison may use.
    fileprivate struct Allow {
        let c: Bool
        let a: Bool
        let t: Bool
        var art = true
        var abbr = true
        /// Hint pass: locked (bracketed) articles may be left out, near misses are recorded.
        var hintPass = false
    }

    fileprivate static let nonTypo = Allow(c: true, a: true, t: false)
    fileprivate static let anyCombo = Allow(c: true, a: true, t: true)

    fileprivate static func foldForms(_ s: JSText, _ c: Bool, _ a: Bool) -> [JSText] {
        let base = c ? s.lowercased() : s
        guard a else { return [base] }
        // ASCII has no diacritics, umlauts or ligatures.
        if base.isASCII { return [base, base] }
        let string = base.string
        return [JSText(TextNormalizer.stripDiacritics(string)), JSText(TextNormalizer.foldUmlauts(string))]
    }

    /// `foldForms` results of one `grade` call: the same given and expected texts are compared
    /// under several comparators, variants and passes.
    fileprivate final class FoldCache {
        private struct Key: Hashable {
            let text: JSText
            let c: Bool
            let a: Bool
        }

        private var forms: [Key: [JSText]] = [:]

        func forms(_ s: JSText, _ c: Bool, _ a: Bool) -> [JSText] {
            let key = Key(text: s, c: c, a: a)
            if let hit = forms[key] { return hit }
            let value = Grading.foldForms(s, c, a)
            forms[key] = value
            return value
        }
    }

    fileprivate static func typoBudget(_ s: JSText) -> Int {
        let n = countLetters(s)
        return n >= 10 ? 2 : n >= 4 ? 1 : 0
    }

    /// Optimal-string-alignment (restricted Damerau-Levenshtein) distance over code points.
    /// Returns `max + 1` as soon as the distance is known to exceed `max`.
    fileprivate static func editDistance(_ a: JSText, _ b: JSText, _ max: Int) -> Int {
        if a == b { return 0 }
        let x = a.scalars
        let y = b.scalars
        let n = x.count
        let m = y.count
        if abs(n - m) > max { return max + 1 }
        if n == 0 || m == 0 { return Swift.max(n, m) }
        if n > maxDistLen || m > maxDistLen { return max + 1 }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            var rowMin = i
            for j in 1...m {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                var v = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1] { v = Swift.min(v, prev2[j - 2] + 1) }
                cur[j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > max { return max + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[m]
    }

    fileprivate static func comboMatches(_ g: JSText, _ e: JSText, _ combo: Combo, _ folds: FoldCache) -> Bool {
        let gs = folds.forms(g, combo.c, combo.a)
        let es = folds.forms(e, combo.c, combo.a)
        for i in es.indices {
            if gs[i] == es[i] { return true }
            if combo.t {
                let max = typoBudget(es[i])
                if max > 0 && editDistance(gs[i], es[i], max) <= max { return true }
            }
        }
        return false
    }

    /// First (least tolerant) permitted comparator under which `g` matches `e`.
    fileprivate static func findCombo(_ g: JSText, _ e: JSText, _ allow: Allow, _ folds: FoldCache) -> Combo? {
        for combo in combos {
            if (combo.c && !allow.c) || (combo.a && !allow.a) || (combo.t && !allow.t) { continue }
            if comboMatches(g, e, combo, folds) { return combo }
        }
        return nil
    }

    fileprivate struct PairBest {
        let combo: Combo
        /// The article note when the article was left out (`.article` / `.pronoun`).
        let art: GradeNote?
        let rank: Int
    }

    fileprivate struct PairResult {
        var best: PairBest?
        var wrongArticle = false
        /// Wrong article and the word is only close (hint pass only), e.g. "der Strase" for
        /// "die Straße": not a wrongArticle, the word is off too.
        var near = false
    }

    /// Compares one given form with one expected form, handling articles.
    fileprivate static func evalPair(
        _ g: ArticleSplit, _ e: ArticleSplit, _ allow: Allow, artOk: Bool, lang: Lang?, folds: FoldCache
    ) -> PairResult {
        var r = PairResult()
        func consider(_ combo: Combo?, _ art: GradeNote?) {
            guard let combo else { return }
            let rank = (combo.c ? 1 : 0) + (combo.a ? 2 : 0) + (combo.t ? 8 : 0) + (art != nil ? 4 : 0)
            if r.best == nil || rank < r.best!.rank { r.best = PairBest(combo: combo, art: art, rank: rank) }
        }
        if let eArticle = e.article {
            if let gArticle = g.article {
                if sameArticle(gArticle, eArticle, lang: lang) {
                    consider(findCombo(g.core, e.core, allow, folds), nil)
                } else if findCombo(g.core, e.core, nonTypo, folds) != nil {
                    r.wrongArticle = true // "la monsieur", "den Herr"
                } else if allow.hintPass && findCombo(g.core, e.core, anyCombo, folds) != nil {
                    r.near = true
                }
            } else {
                if artOk { consider(findCombo(g.text, e.core, allow, folds), e.kind) }
                consider(findCombo(g.text, e.text, allow, folds), nil) // typo across the space: "lemonsieur"
            }
        } else {
            consider(findCombo(g.text, e.text, allow, folds), nil)
            if g.article != nil { consider(findCombo(g.core, e.text, allow, folds), nil) } // extra article is ignored
        }
        return r
    }

    fileprivate struct Forms {
        let raw: ArticleSplit
        /// With abbreviations expanded (nil when that changes nothing or the toggle is off).
        let exp: ArticleSplit?
    }

    fileprivate static func makeForms(_ text: JSText, tol: Tolerance, lang: Lang?) -> Forms {
        let rawText = clean(text)
        let raw = splitArticle(rawText, lang: lang)
        var exp: ArticleSplit?
        if tol.abbreviations {
            let expText = clean(expandAbbreviations(text))
            if expText != rawText { exp = splitArticle(expText, lang: lang) }
        }
        return Forms(raw: raw, exp: exp)
    }

    fileprivate struct Variant {
        let forms: Forms
        let omitted: Bool
        let lock: Bool
    }

    fileprivate struct PreparedAlt {
        let variants: [Variant]
        /// Articles the alternative declares (lower case), including bracketed ones.
        let articles: [JSText]
    }

    /// One expected alternative: its comparison variants and the articles it declares, including
    /// bracketed ones ("(der) Herr", "Herr (der)").
    fileprivate static func prepareAlt(_ text: JSText, tol: Tolerance, lang: Lang?) -> PreparedAlt {
        var variants: [Variant] = []
        var seen: Set<VariantKey> = []
        var articles: [JSText] = []
        func addArticle(_ a: JSText) { if !articles.contains(a) { articles.append(a) } }
        var sources = parenVariants(text, optional: tol.parentheses)
        if let lang, let table = articleTable[lang] {
            for g in bracketGroups(text) {
                let low = clean(g.content).lowercased()
                guard let entry = table.first(where: { $0.token == low }) else { continue }
                addArticle(low)
                // A trailing bracketed article also reads in front, like the dictionary form
                // "Herr, der": "Herr (der)" → "der Herr" (required when the toggle is off).
                let head = tidy(text.slice(0, g.start))
                if !hasAlnum(text.slice(g.end)) && hasAlnum(head) && bracketGroups(head).isEmpty
                    && splitArticle(clean(head), lang: lang).article == nil
                {
                    let front = entry.elided ? low + head : low + " " + head
                    sources.append(ParenVariant(text: front, omitted: false, lock: !tol.parentheses))
                }
            }
        }
        for v in sources {
            let forms = makeForms(v.text, tol: tol, lang: lang)
            let id = VariantKey(text: forms.raw.text, omitted: v.omitted)
            if forms.raw.text.isEmpty || seen.contains(id) { continue }
            seen.insert(id)
            if let article = forms.raw.article { addArticle(article.lowercased()) }
            variants.append(Variant(forms: forms, omitted: v.omitted, lock: v.lock))
        }
        return PreparedAlt(variants: variants, articles: articles)
    }

    fileprivate struct VariantKey: Hashable {
        let text: JSText
        let omitted: Bool
    }

    fileprivate struct MatchBest {
        let combo: Combo
        let art: GradeNote?
        let rank: Int
        /// Matched through abbreviation expansion.
        let abbr: Bool
        /// Matched a variant with bracketed content left out.
        let paren: Bool
        let lock: Bool
    }

    fileprivate struct MatchResult {
        var best: MatchBest?
        var wrongArticle = false
        var near = false
    }

    /// Best match of a given part against one expected alternative.
    fileprivate static func matchPart(
        _ part: Forms, _ alt: PreparedAlt, _ allow: Allow, lang: Lang?, folds: FoldCache
    ) -> MatchResult {
        var r = MatchResult()
        // A given article that the alternative contradicts ("den Herr" for "(der) Herr") must not
        // be excused by the variant without the bracketed article.
        let conflict: Bool
        if let given = part.raw.article, !alt.articles.isEmpty {
            conflict = !alt.articles.contains { sameArticle(given, $0, lang: lang) }
        } else {
            conflict = false
        }
        for v in alt.variants {
            if conflict && v.forms.raw.article == nil {
                if findCombo(part.raw.core, v.forms.raw.core, nonTypo, folds) != nil { r.wrongArticle = true }
                continue
            }
            let artOk = allow.art && (allow.hintPass || !v.lock)
            var tries = [(part.raw, v.forms.raw, false)]
            if allow.abbr && (part.exp != nil || v.forms.exp != nil) {
                tries.append((part.exp ?? part.raw, v.forms.exp ?? v.forms.raw, true))
            }
            for (g, e, usedAbbr) in tries {
                let pair = evalPair(g, e, allow, artOk: artOk, lang: lang, folds: folds)
                if pair.wrongArticle { r.wrongArticle = true }
                if pair.near { r.near = true }
                guard let b = pair.best else { continue }
                let rank = b.rank + (usedAbbr ? 1 : 0) + (v.omitted ? 3 : 0)
                if r.best == nil || rank < r.best!.rank {
                    r.best = MatchBest(
                        combo: b.combo, art: b.art, rank: rank, abbr: usedAbbr, paren: v.omitted, lock: v.lock)
                }
            }
        }
        return r
    }
}

// MARK: - Whole-answer evaluation

extension Grading {
    fileprivate struct Evaluation {
        let correct: Bool
        var notes: Set<GradeNote> = []
        var results: [[MatchResult]] = []
        /// Parts without any matching alternative.
        var failing: [Int] = []
    }

    fileprivate static func evaluate(
        _ parts: [Forms], _ alts: [PreparedAlt], tol: Tolerance, lang: Lang?, folds: FoldCache
    ) -> Evaluation {
        let allow = Allow(
            c: tol.ignoreCase, a: tol.ignoreAccents, t: tol.typos, art: tol.articles, abbr: tol.abbreviations)
        let results = parts.map { p in alts.map { matchPart(p, $0, allow, lang: lang, folds: folds) } }
        let edges: [[(best: MatchBest, j: Int)]] = results.map { row in
            // A wrong article on an otherwise matching word beats a mere typo match elsewhere.
            let blocked = row.contains { $0.wrongArticle }
            var list: [(best: MatchBest, j: Int)] = []
            for (j, r) in row.enumerated() {
                if let b = r.best, !(blocked && b.combo.t) { list.append((b, j)) }
            }
            return list.sorted { $0.best.rank != $1.best.rank ? $0.best.rank < $1.best.rank : $0.j < $1.j }
        }
        let failing = edges.indices.filter { edges[$0].isEmpty }
        if !failing.isEmpty { return Evaluation(correct: false, results: results, failing: failing) }

        // Maximum bipartite matching of given parts to distinct alternatives.
        var partOfAlt = [Int](repeating: -1, count: alts.count)
        var altOfPart = [Int](repeating: -1, count: parts.count)
        func assign(_ i: Int, _ seen: inout Set<Int>) -> Bool {
            for edge in edges[i] {
                if seen.contains(edge.j) { continue }
                seen.insert(edge.j)
                if partOfAlt[edge.j] < 0 || assign(partOfAlt[edge.j], &seen) {
                    partOfAlt[edge.j] = i
                    altOfPart[i] = edge.j
                    return true
                }
            }
            return false
        }
        for i in parts.indices {
            var seen: Set<Int> = []
            _ = assign(i, &seen)
        }
        let covered = partOfAlt.filter { $0 >= 0 }.count
        if !tol.multipleAnswers && covered < alts.count {
            return Evaluation(correct: false, results: results, failing: failing)
        }

        var notes: Set<GradeNote> = []
        var sequence: [Int] = []
        for (i, list) in edges.enumerated() {
            let chosen = list.first { $0.j == altOfPart[i] } ?? list[0]
            sequence.append(chosen.j)
            if let art = chosen.best.art { notes.insert(art) }
            if chosen.best.abbr { notes.insert(.abbreviation) }
            if chosen.best.paren { notes.insert(.parentheses) }
            if chosen.best.combo.c && lang == .de { notes.insert(.letterCase) }
            if chosen.best.combo.a { notes.insert(.accents) }
            if chosen.best.combo.t { notes.insert(.typo) }
        }
        if covered < alts.count {
            notes.insert(.partial)
        } else if sequence.indices.contains(where: { $0 > 0 && sequence[$0] < sequence[$0 - 1] }) {
            notes.insert(.order)
        }
        return Evaluation(correct: true, notes: notes)
    }

    fileprivate static func hintFromMatch(_ best: MatchBest, tol: Tolerance) -> GradeHint? {
        let (c, a, t) = (best.combo.c, best.combo.a, best.combo.t)
        if best.art != nil && (!tol.articles || best.lock) { return .missingArticle }
        let offA = a && !tol.ignoreAccents
        let offC = c && !tol.ignoreCase
        let offT = t && !tol.typos
        if !offA && !offC && !offT { return nil }
        if offA && !t { return offC ? .almost : .accentsOnly }
        if offC && !t { return .caseOnly }
        if offT { return .typo }
        return .almost
    }

    fileprivate static func simFold(_ s: JSText) -> JSText {
        JSText(TextNormalizer.stripDiacritics(clean(s).lowercased().string))
    }

    fileprivate static func isAlmost(_ given: JSText, _ target: JSText) -> Bool {
        let a = simFold(given)
        let b = simFold(target)
        let len = max(a.count, b.count)
        if len == 0 || len > maxDistLen { return false }
        let budget = Int((Double(len) * (1 - almostSimilarity)).rounded(.down))
        return editDistance(a, b, budget) <= budget
    }

    fileprivate static func computeHint(
        parts: [Forms], evaluation res: Evaluation, alts: [PreparedAlt], altTexts: [JSText], tol: Tolerance,
        lang: Lang?, given: JSText, expected: JSText, folds: FoldCache
    ) -> GradeHint? {
        var found: Set<GradeHint> = []
        let hintAllow = Allow(c: true, a: true, t: true, art: true, abbr: tol.abbreviations, hintPass: true)
        for i in res.failing {
            if res.results[i].contains(where: \.wrongArticle) { found.insert(.wrongArticle) }
            for alt in alts {
                let r = matchPart(parts[i], alt, hintAllow, lang: lang, folds: folds)
                if r.wrongArticle { found.insert(.wrongArticle) }
                if r.near { found.insert(.almost) }
                if let best = r.best, let h = hintFromMatch(best, tol: tol) { found.insert(h) }
            }
        }
        if let h = HINT_ORDER.first(where: found.contains) { return h }
        return ([expected] + altTexts).contains { isAlmost(given, $0) } ? .almost : nil
    }
}
