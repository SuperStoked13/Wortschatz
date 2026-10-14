import Foundation

/// A detected language: one of `LangDetect.SUPPORTED` or "unknown" (the only place where JS
/// returns "unknown").
public enum DetectedLanguage: String, Codable, Sendable, CaseIterable, Hashable {
    case fr, de, en, es, it, unknown

    /// The set-side language, nil for `.unknown`.
    public var lang: Lang? { Lang(rawValue: rawValue) }

    public init(_ lang: Lang) {
        self = DetectedLanguage(rawValue: lang.rawValue) ?? .unknown
    }
}

/// `{ lang, confidence }` of `detectLanguage` / `detectColumn`.
public struct LanguageDetection: Codable, Sendable, Equatable, Hashable {
    public var lang: DetectedLanguage
    /// 0…1, rounded to 3 decimals by the JS code.
    public var confidence: Double

    public init(lang: DetectedLanguage, confidence: Double) {
        self.lang = lang
        self.confidence = confidence
    }

    public static let unknown = LanguageDetection(lang: .unknown, confidence: 0)
}

/// Port of src/core/langdetect.js: language identification for short vocabulary lines
/// (fr / de / en / es / it).
///
/// Vocabulary lines are tiny ("calme", "der Mut", "sage"), so classic n-gram detectors fail on
/// them. Several weak signals are combined into additive evidence scores (roughly log-odds units):
/// - a compact frequent-word lexicon (function words + common school vocabulary),
/// - leading articles / reflexive pronouns (le, die, the, el, gli, sich, s' …),
/// - diacritics (é ç œ → fr, ä ö ü → de, ñ ¿ → es, ì ò → it),
/// - German noun capitalisation ("die Frau", mid-line capitals),
/// - typical suffixes (-tion, -euse, -ung, -keit, -ing, -ción, -zione …),
/// - characteristic letter groups (sch, eau, th, w, k, z, gli …),
/// - a character-trigram model trained lazily on the lexicon itself, which generalises to words
///   that are not in the lexicon.
///
/// Column-level detection aggregates soft votes over many lines, so a single ambiguous line never
/// decides the language of a whole column.
///
/// The port works on Unicode scalars and UTF-16 code units exactly like the JS code (lengths,
/// suffixes and trigrams are UTF-16 based) and adds the evidence in the same order, so the
/// rounded scores are bit-identical.
public enum LangDetect {
    /// Detectable languages, in the JS order (`['fr', 'de', 'en', 'es', 'it']`).
    public static let SUPPORTED: [Lang] = [.fr, .de, .en, .es, .it]

    /// Additive, non-negative evidence per language (higher = more likely); every supported
    /// language is present (0 when there is no evidence). Values are rounded to 3 decimals.
    /// Encodes as `{"fr": …, "de": …, "en": …, "es": …, "it": …}`.
    public static func scoreLanguages(_ text: String?) -> [Lang: Double] {
        let scores = score(text)
        var out: [Lang: Double] = [:]
        for (i, lang) in SUPPORTED.enumerated() { out[lang] = scores[i] }
        return out
    }

    /// Most likely language of a single text with a 0…1 confidence (`.unknown` / 0 without evidence).
    public static func detectLanguage(_ text: String?) -> LanguageDetection {
        let scores = score(text)
        guard hasEvidence(scores) else { return .unknown }
        let p = softmax(scores)
        let top = rank(p)[0]
        return LanguageDetection(lang: DetectedLanguage(SUPPORTED[top]), confidence: round3(p[top]))
    }

    /// Language of a whole column (many short lines). Every line casts a soft vote (its probability
    /// distribution); summed evidence breaks near-ties.
    public static func detectColumn(_ lines: [String]) -> LanguageDetection {
        var votes = [Double](repeating: 0, count: languageCount)
        var evidence = [Double](repeating: 0, count: languageCount)
        var n = 0
        for line in lines {
            let scores = score(line)
            guard hasEvidence(scores) else { continue }
            let p = softmax(scores)
            var best = 0.0
            for l in 0..<languageCount { best = max(best, scores[l]) }
            for l in 0..<languageCount {
                votes[l] += p[l]
                // Cap the influence of a single long line on the evidence sum.
                evidence[l] += max(-8, scores[l] - best)
            }
            n += 1
        }
        guard n > 0 else { return .unknown }
        let count = Double(n)
        var order = rank(votes)
        let (a, b) = (order[0], order[1])
        if abs(votes[a] - votes[b]) / count < 0.04 && evidence[b] > evidence[a] { order = [b, a] }
        let top = order[0]
        let second = order[1]
        let share = votes[top] / count
        let secondShare = votes[second] / count
        let separation = share / (share + secondShare)
        let sizeFactor = min(1, 0.7 + 0.1 * count)
        let confidence = max(0, min(1, separation * sizeFactor))
        return LanguageDetection(lang: DetectedLanguage(SUPPORTED[top]), confidence: round3(confidence))
    }
}

// MARK: - Weights and tables

extension LangDetect {
    /// Number of supported languages; scores are `[Double]` indexed like `SUPPORTED`.
    static let languageCount = 5
    private static let fr = 0, de = 1, en = 2, es = 3, it = 4

    /// Small tie-breaking prior: the app is used by German speakers learning French (sometimes
    /// English). Only applied when turning scores into probabilities (`PRIOR`).
    static let prior: [Double] = [0.2, 0.25, 0.1, 0.05, 0]

    /// One `{ lang: weight }` entry of the JS weight tables.
    private struct LangWeight: Sendable {
        let lang: Int
        let value: Double
    }

    private static func weights(
        fr: Double? = nil, de: Double? = nil, en: Double? = nil, es: Double? = nil, it: Double? = nil
    ) -> [LangWeight] {
        [fr, de, en, es, it].enumerated().compactMap { i, w in w.map { LangWeight(lang: i, value: $0) } }
    }

    private static let wFunction = 1.4
    private static let wVocab = 2.0
    private static let wLexiconOnly = 4.0 // makes up for the missing trigram evidence
    private static let wUniqueBonus = 0.8

    private static let trigramK = 0.3
    private static let trigramWeight = 0.3
    private static let trigramCap = 3.0

    /// `LEADING`: article / pronoun at the start of a line or of a comma-separated segment.
    ///
    /// "constructor" maps to no weights: in JS `LEADING[key]` reads `Object.prototype.constructor`
    /// for that key, which is truthy but adds nothing, and it suppresses the capitalisation bonus
    /// of a leading "Constructor" like a real article would. The port keeps that behaviour.
    private static let leading: [String: [LangWeight]] = [
        "le": weights(fr: 2.2, it: 0.5),
        "la": weights(fr: 1.4, es: 1.1, it: 1.1),
        "les": weights(fr: 2.8),
        "l'": weights(fr: 2.2, it: 1.2),
        "un": weights(fr: 1.3, es: 1.0, it: 1.0),
        "une": weights(fr: 2.8),
        "des": weights(fr: 2.2, de: 0.3),
        "du": weights(fr: 2.6),
        "se": weights(fr: 2.0, es: 0.9, it: 0.7),
        "s'": weights(fr: 2.4, it: 0.5),
        "der": weights(de: 3),
        "die": weights(de: 2.6, en: 0.2),
        "das": weights(de: 3),
        "den": weights(de: 2.4),
        "dem": weights(de: 3),
        "ein": weights(de: 2.8),
        "eine": weights(de: 3),
        "einen": weights(de: 3),
        "einem": weights(de: 3),
        "einer": weights(de: 3),
        "eines": weights(de: 3),
        "sich": weights(de: 3.2),
        "the": weights(en: 3.2),
        "a": weights(en: 1.5, es: 0.3, it: 0.3),
        "an": weights(de: 0.6, en: 2.0),
        "to": weights(en: 2.6),
        "el": weights(es: 3),
        "los": weights(es: 2.8),
        "las": weights(es: 2.8),
        "una": weights(es: 1.4, it: 1.4),
        "unos": weights(es: 3),
        "unas": weights(es: 3),
        "lo": weights(es: 1.0, it: 1.4),
        "il": weights(fr: 0.6, it: 2.8),
        "gli": weights(it: 3.2),
        "i": weights(en: 0.4, it: 1.6),
        "uno": weights(es: 0.8, it: 2.2),
        "un'": weights(it: 3),
        "constructor": [],
    ]

    /// `DE_DETERMINERS`: German determiners after which a capitalised word is almost surely a noun.
    private static let deDeterminers: Set<String> = Set(
        splitWords("""
            der die das den dem des ein eine einen einem einer eines kein keine keinen keinem keiner mein meine
            dein deine sein seine ihr ihre unser unsere euer eure dieser diese dieses jeder jede jedes zum zur im
            am vom beim
            """))

    /// `CHAR_WEIGHTS`: diacritics and Spanish punctuation, by (lowercase) scalar value.
    private static let charWeights: [UInt32: [LangWeight]] = [
        0xE9: weights(fr: 1.6, es: 0.5, it: 0.4), // é
        0xE8: weights(fr: 1.6, it: 0.9), // è
        0xEA: weights(fr: 2.4), // ê
        0xE2: weights(fr: 2.4), // â
        0xEE: weights(fr: 2.4), // î
        0xF4: weights(fr: 2.4), // ô
        0xFB: weights(fr: 2.4), // û
        0xEB: weights(fr: 1.8), // ë
        0xEF: weights(fr: 2.0), // ï
        0xE7: weights(fr: 2.6), // ç
        0x153: weights(fr: 3), // œ
        0xE0: weights(fr: 1.2, it: 1.0), // à
        0xF9: weights(fr: 1.4, it: 0.9), // ù
        0xE4: weights(de: 2.6), // ä
        0xF6: weights(de: 2.6), // ö
        0xFC: weights(de: 2.6, es: 0.3), // ü
        0xDF: weights(de: 3.2), // sharp s
        0xF1: weights(es: 3.4), // ñ
        0xE1: weights(es: 2.2), // á
        0xED: weights(es: 2.0, it: 0.4), // í
        0xF3: weights(es: 2.0, it: 0.4), // ó
        0xFA: weights(es: 2.0, it: 0.2), // ú
        0xEC: weights(it: 2.6), // ì
        0xF2: weights(it: 2.6), // ò
        0xBF: weights(es: 3.4), // ¿
        0xA1: weights(es: 3.4), // ¡
    ]

    /// `SUFFIXES`, per language in `SUPPORTED` order. Per word only the strongest matching suffix
    /// of each language counts.
    private static let suffixes: [[(suffix: [UInt16], weight: Double)]] = [
        // fr
        suffixList([
            ("euses", 2.6), ("euse", 2.6), ("eux", 2.2), ("eaux", 2.4), ("eau", 2.4), ("tion", 0.8), ("ment", 0.9),
            ("ée", 1.0), ("ées", 1.2), ("ier", 0.9), ("oyer", 2.0), ("ayer", 1.0), ("uyer", 2.0), ("ière", 2.0),
            ("oir", 2.0), ("oire", 2.0), ("ette", 2.0), ("elle", 1.0), ("ique", 2.0), ("isme", 1.2), ("ance", 0.9),
            ("ence", 0.7), ("esse", 1.4), ("eur", 1.8), ("eure", 2.0), ("aire", 1.4), ("oise", 2.0), ("ois", 1.2),
            ("ille", 1.8), ("eille", 2.4), ("ail", 1.4), ("aille", 2.2), ("ouille", 2.6), ("ais", 1.2), ("ait", 1.4),
            ("ez", 1.2), ("ons", 0.8), ("ant", 0.8), ("ante", 0.9), ("ent", 0.5), ("er", 1.0), ("ir", 0.5),
            ("re", 0.5), ("age", 0.9), ("té", 1.2), ("eil", 2.0), ("otte", 2.0), ("ain", 1.4), ("aine", 1.6),
            ("ienne", 2.4), ("oux", 2.4), ("ude", 0.8), ("eindre", 3.0), ("aindre", 3.0), ("oindre", 3.0),
            ("einture", 2.6),
        ]),
        // de
        suffixList([
            ("ung", 3), ("ungen", 3), ("heit", 3), ("keit", 3), ("lich", 2.6), ("isch", 2.6), ("chen", 2.2),
            ("schaft", 3), ("ieren", 2.6), ("iert", 2.4), ("ig", 1.4), ("nis", 2.0), ("tum", 2.0), ("haft", 2.6),
            ("sam", 1.0), ("bar", 1.0), ("los", 0.9), ("lein", 2.6), ("eln", 2.0), ("ern", 1.5), ("en", 1.0),
            ("er", 0.5), ("tz", 2.4), ("ck", 1.6), ("cht", 2.2), ("ft", 1.0), ("st", 0.6), ("ss", 0.8), ("ei", 1.2),
            ("tet", 1.4), ("det", 1.2), ("rn", 1.2), ("hn", 1.4), ("hl", 1.4),
        ]),
        // en
        suffixList([
            ("ing", 2.6), ("ly", 2.0), ("ness", 3), ("ful", 2.6), ("less", 2.2), ("ous", 2.0), ("ity", 1.6),
            ("ship", 2.4), ("ish", 1.6), ("ed", 1.2), ("tion", 0.8), ("able", 0.8), ("ible", 0.6), ("ward", 2.0),
            ("y", 0.7), ("ght", 2.4), ("ay", 1.0), ("ey", 1.0), ("ow", 1.0), ("th", 1.6),
        ]),
        // es
        suffixList([
            ("ción", 3.4), ("ciones", 3.4), ("dad", 3), ("ado", 1.6), ("ada", 1.2), ("ido", 1.6), ("ida", 1.2),
            ("mente", 1.4), ("os", 1.0), ("as", 0.6), ("ar", 1.4), ("er", 0.5), ("ir", 0.6), ("ería", 2.6),
            ("illa", 2.0), ("illo", 2.0), ("aza", 1.0), ("azo", 1.2), ("udo", 1.0), ("ez", 0.8), ("oso", 1.2),
            ("osa", 1.2), ("ito", 1.0), ("ita", 0.8), ("dor", 1.4), ("ón", 1.6), ("ía", 1.6), ("eza", 1.6),
            ("ero", 0.9), ("iento", 2.2), ("o", 0.5),
        ]),
        // it
        suffixList([
            ("zione", 3.4), ("zioni", 3.4), ("ità", 3), ("tà", 2.6), ("ino", 1.0), ("etto", 2.0), ("etta", 1.6),
            ("ezza", 3), ("are", 1.0), ("ere", 1.0), ("ire", 0.6), ("mente", 1.4), ("oni", 1.4), ("ati", 1.4),
            ("iti", 1.4), ("ato", 1.2), ("uto", 1.6), ("ello", 1.4), ("i", 0.7), ("o", 0.5), ("cci", 2.4),
            ("zzo", 2.4), ("zza", 2.4), ("gno", 1.6), ("glio", 2.6), ("ggio", 2.6),
        ]),
    ]

    private static func suffixList(_ items: [(String, Double)]) -> [(suffix: [UInt16], weight: Double)] {
        items.map { (Array($0.0.utf16), $0.1) }
    }

    /// `CONSONANT_END`: Italian words almost always end in a vowel.
    private static let consonantEnd = weights(fr: 0.3, de: 0.3, en: 0.3, es: 0.3)

    /// `/[aeiouàèéìòùy]$/` (UTF-16 code units).
    private static let vowelEndings: Set<UInt16> = Set("aeiouàèéìòùy".utf16)

    /// `NGRAMS`: characteristic letter groups, counted once per word.
    private static let ngrams: [(gram: [UInt16], weights: [LangWeight])] = ngramList([
        ("sch", weights(de: 1.8)),
        ("tsch", weights(de: 1.0)),
        ("eau", weights(fr: 2.2)),
        ("ou", weights(fr: 0.9, en: 0.4)),
        ("qu", weights(fr: 0.7, en: 0.2, es: 0.5, it: 0.5)),
        ("th", weights(de: 0.2, en: 1.4)),
        ("w", weights(de: 0.9, en: 0.9)),
        ("k", weights(de: 1.0, en: 0.4)),
        ("z", weights(de: 0.8, es: 0.3, it: 0.8)),
        ("ch", weights(fr: 0.5, de: 0.5)),
        ("ei", weights(de: 1.0)),
        ("ie", weights(fr: 0.2, de: 0.5)),
        ("eu", weights(fr: 0.6, de: 0.6)),
        ("oi", weights(fr: 1.0)),
        ("ai", weights(fr: 0.6)),
        ("gn", weights(fr: 0.5, it: 0.7)),
        ("gli", weights(it: 1.6)),
        ("zz", weights(it: 1.8)),
        ("cc", weights(it: 1.0)),
        ("ck", weights(de: 1.0, en: 0.6)),
        ("tz", weights(de: 1.4)),
        ("pf", weights(de: 1.4)),
        ("wh", weights(en: 1.8)),
        ("sh", weights(en: 1.4)),
        ("ght", weights(en: 2.0)),
        ("ee", weights(de: 0.4, en: 0.8)),
        ("oo", weights(en: 1.2)),
        ("ea", weights(en: 0.6)),
        ("y", weights(en: 0.7, es: 0.2)),
        ("ae", weights(de: 0.4)),
        ("ue", weights(de: 0.3, es: 0.4)),
        ("uo", weights(it: 1.0)),
        ("rr", weights(es: 0.5, it: 0.3)),
    ])

    private static func ngramList(_ items: [(String, [LangWeight])]) -> [(gram: [UInt16], weights: [LangWeight])] {
        items.map { (Array($0.0.utf16), $0.1) }
    }

    /// A lexicon word with its per-language weights.
    private struct LexiconEntry: Sendable {
        let word: String
        let weights: [LangWeight]
    }

    /// The lazily built tables (`buildTables()` in JS).
    private struct Tables: Sendable {
        /// word → `{ lang: weight }`
        let lexicon: [String: LexiconEntry]
        /// `Math.log(count + TRIGRAM_K) - denom` per language for every trigram of the training words.
        let trigramTerms: [UInt64: [Double]]
        /// The same for a trigram that never occurs in training (count 0).
        let unknownTrigramTerms: [Double]
    }

    /// Built on first use (Swift initialises static stored properties lazily and thread-safely).
    private static let tables = buildTables()

    private static func buildTables() -> Tables {
        // Lexicon: word -> { lang: weight }
        var raw: [String: [Double?]] = [:]
        func add(_ word: String, _ lang: Int, _ w: Double) {
            var entry = raw[word] ?? [Double?](repeating: nil, count: languageCount)
            entry[lang] = max(entry[lang] ?? 0, w)
            raw[word] = entry
        }
        for (i, lang) in SUPPORTED.enumerated() {
            for w in splitWords(functionWords[lang] ?? "") { add(w, i, wFunction) }
            for w in splitWords(vocabWords[lang] ?? "") { add(w, i, wVocab) }
            for w in splitWords(lexiconOnly[lang] ?? "") { add(w, i, wLexiconOnly) }
        }
        var lexicon: [String: LexiconEntry] = [:]
        lexicon.reserveCapacity(raw.count)
        for (word, entry) in raw {
            var values = entry
            // Words known in a single language are stronger evidence than shared ones.
            let langs = values.indices.filter { values[$0] != nil }
            if langs.count == 1 { values[langs[0]]! += wUniqueBonus }
            let list = values.enumerated().compactMap { i, w in w.map { LangWeight(lang: i, value: $0) } }
            lexicon[word] = LexiconEntry(word: word, weights: list)
        }

        // Character-trigram model per language, trained on the lexicon words (not LEXICON_ONLY).
        var counts = [[UInt64: Int]](repeating: [:], count: languageCount)
        var totals = [Int](repeating: 0, count: languageCount)
        var vocab = Set<UInt64>()
        for (i, lang) in SUPPORTED.enumerated() {
            let all = splitWords(functionWords[lang] ?? "") + splitWords(vocabWords[lang] ?? "")
            for word in all {
                let w = word.utf16.filter { $0 != apostrophe }
                if w.count < 2 { continue }
                for g in trigramKeys(w) {
                    counts[i][g, default: 0] += 1
                    vocab.insert(g)
                    totals[i] += 1
                }
            }
        }
        let v = Double(vocab.count + 2000)
        let denom = (0..<languageCount).map { log(Double(totals[$0]) + trigramK * v) }
        let unknown = (0..<languageCount).map { log(0 + trigramK) - denom[$0] }
        var terms: [UInt64: [Double]] = [:]
        terms.reserveCapacity(vocab.count)
        for g in vocab {
            terms[g] = (0..<languageCount).map { log(Double(counts[$0][g] ?? 0) + trigramK) - denom[$0] }
        }
        return Tables(lexicon: lexicon, trigramTerms: terms, unknownTrigramTerms: unknown)
    }

    /// `str.split(/\s+/).filter(Boolean)`
    private static func splitWords(_ s: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if JSCompat.isWhitespace(u) {
                if !cur.isEmpty { out.append(String(cur)) }
                cur = String.UnicodeScalarView()
            } else {
                cur.append(u)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    private static let apostrophe: UInt16 = 0x27

    /// The trigrams of `" word "` over UTF-16 code units (JS `s.slice(i, i + 3)`), each packed into
    /// one integer.
    private static func trigramKeys(_ word: [UInt16]) -> [UInt64] {
        let s = [0x20] + word + [0x20]
        var out: [UInt64] = []
        out.reserveCapacity(s.count - 2)
        var i = 0
        while i + 3 <= s.count {
            out.append(UInt64(s[i]) << 32 | UInt64(s[i + 1]) << 16 | UInt64(s[i + 2]))
            i += 1
        }
        return out
    }
}

// MARK: - Scoring

extension LangDetect {
    /// `scoreLanguages` as an array in `SUPPORTED` order (rounded to 3 decimals), without the
    /// dictionary (for callers that score many lines).
    static func score(_ text: String?) -> [Double] {
        var out = [Double](repeating: 0, count: languageCount)
        // normalizeBasic(text).slice(0, 4000)
        let s = prefixUTF16(TextNormalizer.normalizeBasic(text), 4000)
        guard s.contains(where: TextNormalizer.isLetterScalar) else { return out }
        let t = tables

        // Diacritics: first occurrence of each character counts fully, repeats half.
        var seen: [UInt32: Int] = [:]
        var lowered: [Unicode.Scalar] = []
        for u in s {
            lowered.removeAll(keepingCapacity: true)
            appendLowercased(u, to: &lowered)
            for ch in lowered {
                guard let w = charWeights[ch.value] else { continue }
                let n = seen[ch.value] ?? 0
                seen[ch.value] = n + 1
                add(w, n == 0 ? 1 : n < 4 ? 0.5 : 0, to: &out)
            }
        }

        // Tokens: /\p{L}+'?/gu
        let n = s.count
        var prevEnd = 0
        var prevLower: String?
        var index = 0
        var i = 0
        while i < n {
            guard TextNormalizer.isLetterScalar(s[i]) else {
                i += 1
                continue
            }
            let start = i
            repeat { i += 1 } while i < n && TextNormalizer.isLetterScalar(s[i])
            if i < n && s[i] == "'" { i += 1 }
            let token = s[start..<i]

            var lowerScalars: [Unicode.Scalar] = []
            for u in token { appendLowercased(u, to: &lowerScalars) }
            var keyScalars: [Unicode.Scalar] = []
            for u in lowerScalars {
                if u.value == 0xDF {
                    keyScalars.append("s")
                    keyScalars.append("s")
                } else {
                    keyScalars.append(u)
                }
            }
            let lower = string(lowerScalars)
            let key = string(keyScalars)
            let gapBreaks = isSegmentBreak(s[prevEnd..<start])
            let isLeading = index == 0 || gapBreaks

            // Lexicon
            if let lex = t.lexicon[key], identical(lex.word, key) { add(lex.weights, 1, to: &out) }

            // Leading article / reflexive pronoun
            let lead = exactLookup(leading, key)
            if isLeading, let lead { add(lead, index == 0 ? 1 : 0.7, to: &out) }

            // German noun capitalisation
            if isCapitalised(token) {
                if let prevLower, exactContains(deDeterminers, prevLower), !gapBreaks {
                    out[de] += 2.4
                } else if !isLeading {
                    out[de] += 1.0
                } else if lead == nil {
                    out[de] += 0.5
                }
            }

            var bare: [UInt16] = []
            for u in keyScalars where u != "'" { appendUTF16(u, to: &bare) }
            if bare.count >= 2 {
                // Suffixes
                if bare.count >= 4 {
                    for l in 0..<languageCount {
                        var best = 0.0
                        for (suffix, w) in suffixes[l]
                        where w > best && bare.count >= suffix.count + 2 && hasSuffix(bare, suffix) {
                            best = w
                        }
                        out[l] += best
                    }
                }
                // Letter groups
                for (gram, w) in ngrams where contains(bare, gram) { add(w, 1, to: &out) }
                // Italian words almost always end in a vowel.
                if bare.count >= 4 && !vowelEndings.contains(bare[bare.count - 1]) { add(consonantEnd, 1, to: &out) }
                // Trigram model
                trigramEvidence(bare, t, &out)
            }

            prevEnd = i
            prevLower = lower
            index += 1
        }
        for l in 0..<languageCount { out[l] = round3(out[l]) }
        return out
    }

    private static func trigramEvidence(_ word: [UInt16], _ t: Tables, _ out: inout [Double]) {
        let terms = trigramKeys(word).map { t.trigramTerms[$0] ?? t.unknownTrigramTerms }
        var ll = [Double](repeating: 0, count: languageCount)
        var minimum = Double.infinity
        for l in 0..<languageCount {
            var sum = 0.0
            for term in terms { sum += term[l] }
            ll[l] = sum
            if sum < minimum { minimum = sum }
        }
        for l in 0..<languageCount { out[l] += min(trigramCap, (ll[l] - minimum) * trigramWeight) }
    }

    /// `addWeights(out, weights, factor)`
    private static func add(_ weights: [LangWeight], _ factor: Double, to out: inout [Double]) {
        for w in weights { out[w.lang] += w.value * factor }
    }

    /// Scores (plus the tie-breaking prior) → probability distribution.
    static func softmax(_ scores: [Double]) -> [Double] {
        var maximum = -Double.infinity
        for l in 0..<languageCount { maximum = max(maximum, scores[l] + prior[l]) }
        var p = [Double](repeating: 0, count: languageCount)
        var sum = 0.0
        for l in 0..<languageCount {
            p[l] = exp(scores[l] + prior[l] - maximum)
            sum += p[l]
        }
        for l in 0..<languageCount { p[l] /= sum }
        return p
    }

    static func hasEvidence(_ scores: [Double]) -> Bool {
        scores.contains { $0 >= 0.3 }
    }

    /// Language indices sorted by `map` (descending), ties broken by the prior.
    static func rank(_ map: [Double]) -> [Int] {
        // JS: (a, b) => map[b] - map[a] || PRIOR[b] - PRIOR[a]. The priors are distinct, so this is
        // a strict total order and every sort algorithm gives the same result.
        (0..<languageCount).sorted { a, b in
            let d = map[b] - map[a]
            return (d != 0 && !d.isNaN ? d : prior[b] - prior[a]) < 0
        }
    }

    private static func round3(_ x: Double) -> Double { JSCompat.round(x * 1000) / 1000 }

    // MARK: Text helpers

    /// The scalars of `s.slice(0, limit)` (UTF-16 based). An astral character cut in half by the
    /// limit is dropped: the lone high surrogate JS keeps at the very end never matters for scoring.
    private static func prefixUTF16(_ s: String, _ limit: Int) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var units = 0
        for u in s.unicodeScalars {
            units += UTF16.width(u)
            if units > limit { break }
            out.append(u)
        }
        return out
    }

    /// Appends JS `toLowerCase()` of one scalar (full case mapping; the Greek final-sigma rule only
    /// changes σ/ς, which no table here distinguishes).
    private static func appendLowercased(_ u: Unicode.Scalar, to out: inout [Unicode.Scalar]) {
        switch u.value {
        case 0x41...0x5A: out.append(Unicode.Scalar(u.value + 0x20)!)
        case 0..<0x80: out.append(u)
        default: out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
        }
    }

    /// Appends JS `toUpperCase()` of one scalar (full case mapping).
    private static func appendUppercased(_ u: Unicode.Scalar, to out: inout [Unicode.Scalar]) {
        switch u.value {
        case 0x61...0x7A: out.append(Unicode.Scalar(u.value - 0x20)!)
        case 0..<0x80: out.append(u)
        default: out.append(contentsOf: u.properties.uppercaseMapping.unicodeScalars)
        }
    }

    /// "Frau" yes; "frau", "FRAU", "l'" no.
    private static func isCapitalised(_ token: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let first = token.first else { return false }
        // JS `token[0]` is a UTF-16 code unit: for an astral letter it is a lone high surrogate,
        // which `toLowerCase()` leaves unchanged.
        if first.value > 0xFFFF { return false }
        var lower: [Unicode.Scalar] = []
        appendLowercased(first, to: &lower)
        if lower.count == 1 && lower[0] == first { return false }
        let rest = token.dropFirst().filter { $0 != "'" }
        guard !rest.isEmpty else { return false }
        var upper: [Unicode.Scalar] = []
        for u in rest { appendUppercased(u, to: &upper) }
        return upper != rest
    }

    /// `SEGMENT_BREAK = /[,;/(|:]|\s-\s|^\s*-\s/` tested on the text between two tokens.
    private static func isSegmentBreak(_ gap: ArraySlice<Unicode.Scalar>) -> Bool {
        let a = Array(gap)
        var j = 0
        while j < a.count && JSCompat.isWhitespace(a[j]) { j += 1 }
        if j + 1 < a.count && a[j] == "-" && JSCompat.isWhitespace(a[j + 1]) { return true }
        for k in a.indices {
            switch a[k] {
            case ",", ";", "/", "(", "|", ":":
                return true
            case "-" where k > 0 && k + 1 < a.count && JSCompat.isWhitespace(a[k - 1]) && JSCompat.isWhitespace(a[k + 1]):
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// JS `===` (Swift `==` uses canonical equivalence).
    private static func identical(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// `table[key]` with exact (code point) key comparison, like a JS object / Map lookup.
    private static func exactLookup<V>(_ table: [String: V], _ key: String) -> V? {
        guard let index = table.index(forKey: key), identical(table[index].key, key) else { return nil }
        return table[index].value
    }

    private static func exactContains(_ set: Set<String>, _ key: String) -> Bool {
        guard let index = set.firstIndex(of: key) else { return false }
        return identical(set[index], key)
    }

    /// Appends the UTF-16 code units of `u`.
    private static func appendUTF16(_ u: Unicode.Scalar, to out: inout [UInt16]) {
        if u.value <= 0xFFFF {
            out.append(UInt16(u.value))
        } else {
            out.append(UTF16.leadSurrogate(u))
            out.append(UTF16.trailSurrogate(u))
        }
    }

    private static func hasSuffix(_ s: [UInt16], _ suffix: [UInt16]) -> Bool {
        s.count >= suffix.count && s[(s.count - suffix.count)...].elementsEqual(suffix)
    }

    private static func contains(_ s: [UInt16], _ needle: [UInt16]) -> Bool {
        guard needle.count <= s.count else { return false }
        if needle.count == 1 { return s.contains(needle[0]) }
        var i = 0
        while i + needle.count <= s.count {
            if s[i] == needle[0] && s[i..<(i + needle.count)].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }
}
