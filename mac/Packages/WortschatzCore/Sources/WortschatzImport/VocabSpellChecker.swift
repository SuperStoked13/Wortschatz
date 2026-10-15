import AppKit
import WortschatzCore

/// A word the spell checker does not know, with replacement suggestions (best first).
public struct SpellingIssue: Hashable, Sendable, Identifiable {
    /// The word as written in the field.
    public let word: String
    /// Where it sits in the field's text (UTF-16, as NSString ranges).
    public let range: NSRange
    /// Up to four replacements; German ones use Swiss spelling ("ss", never "ß").
    public let suggestions: [String]

    public var id: String { "\(range.location):\(word)" }

    public init(word: String, range: NSRange, suggestions: [String]) {
        self.word = word
        self.range = range
        self.suggestions = suggestions
    }
}

/// Finds probable typos in vocabulary entries with the macOS spell checker (offline, per
/// language). Tuned for vocab lists:
/// - Vocab abbreviations (etw., jdn., qc, sth, z. B. …), short words followed by a period,
///   acronyms and tokens with digits are never reported.
/// - German follows Swiss spelling: a word with "ss" counts as correct when its "ß" form is,
///   and suggestions are given with "ss".
/// - Words the learner chose to ignore are remembered (UserDefaults) for every set.
@MainActor
public final class VocabSpellChecker {
    public static let shared = VocabSpellChecker()
    /// UserDefaults key of the ignored words ("lang:word", lowercased).
    public static let ignoredKey = "spellcheck.ignoredWords"
    /// At most this many issues are reported per field.
    public static let maxIssuesPerText = 6

    private let checker: NSSpellChecker
    private let defaults: UserDefaults
    private let tag: Int
    private var ignored: Set<String>
    private var cache: [String: [SpellingIssue]] = [:]

    public init(defaults: UserDefaults = .standard, checker: NSSpellChecker = .shared) {
        self.checker = checker
        self.defaults = defaults
        tag = NSSpellChecker.uniqueSpellDocumentTag()
        ignored = Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    // MARK: Languages

    /// The spell checker's language for a set language, nil when it has no dictionary.
    public func language(for lang: Lang) -> String? {
        let available = checker.availableLanguages
        let candidates: [String] = switch lang {
        case .fr: ["fr"]
        case .de: ["de"]
        case .en: ["en_GB", "en"]
        case .es: ["es"]
        case .it: ["it"]
        case .ar: ["ar"]
        // No Chinese dictionary on macOS.
        case .zh, .other: []
        }
        return candidates.first(where: available.contains)
    }

    public func supports(_ lang: Lang) -> Bool { language(for: lang) != nil }

    // MARK: Checking

    /// The probable typos in `text`, in order of appearance.
    public func issues(in text: String, lang: Lang) -> [SpellingIssue] {
        guard let language = language(for: lang), !JSCompat.trim(text).isEmpty else { return [] }
        let key = "\(lang.rawValue)\u{1}\(text)"
        if let cached = cache[key] { return cached }

        let ns = text as NSString
        var found: [SpellingIssue] = []
        var start = 0
        while start < ns.length, found.count < Self.maxIssuesPerText {
            let range = checker.checkSpelling(
                of: text, startingAt: start, language: language, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0, range.location >= start else { break }
            start = range.location + range.length
            let word = ns.substring(with: range)
            if shouldSkip(word, range: range, in: ns, lang: lang) { continue }
            if lang == .de, swissFormIsCorrect(word, language: language) { continue }
            found.append(
                SpellingIssue(word: word, range: range, suggestions: suggestions(for: word, range: range, in: text, language: language, lang: lang)))
        }

        if cache.count > 4000 { cache.removeAll() }
        cache[key] = found
        return found
    }

    // MARK: Ignoring

    /// "Ignorieren": the word is not reported again (in any set).
    public func ignore(_ word: String, lang: Lang) {
        ignored.insert(Self.ignoreKey(word, lang: lang))
        defaults.set(ignored.sorted(), forKey: Self.ignoredKey)
        cache.removeAll()
    }

    public func isIgnored(_ word: String, lang: Lang) -> Bool {
        ignored.contains(Self.ignoreKey(word, lang: lang))
    }

    /// Forgets every ignored word.
    public func resetIgnored() {
        ignored.removeAll()
        defaults.removeObject(forKey: Self.ignoredKey)
        cache.removeAll()
    }

    private static func ignoreKey(_ word: String, lang: Lang) -> String {
        "\(lang.rawValue):\(word.lowercased())"
    }

    // MARK: Filters

    /// Short forms that vocab lists use on purpose (compared lowercased, without dots).
    static let abbreviations: Set<String> = [
        "etw", "jd", "jdn", "jdm", "jds", "jmd", "jmdn", "jmdm", "jmds", "sth", "sb", "smb", "smth", "so", "sthg",
        "qc", "qch", "qqch", "qn", "qqn", "qqc", "zb", "usw", "bzw", "etc", "ca", "vgl", "ugs", "fam", "pl", "sg",
        "adj", "adv", "inf", "vb", "subst", "mask", "fem", "neutr", "od", "ua", "evtl", "bsp", "akk", "dat",
        "gen", "pers", "präs", "perf", "imp", "fut", "pp", "ppa", "ppp", "lat", "engl", "franz", "frz", "dt",
    ]

    private func shouldSkip(_ word: String, range: NSRange, in text: NSString, lang: Lang) -> Bool {
        if isIgnored(word, lang: lang) { return true }
        let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.count < 2 { return true }
        if word.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        // Acronyms and abbreviations written in capitals (TGV, USA, CH).
        if word == word.uppercased(), word != word.lowercased() { return true }
        let compact = word.lowercased().replacingOccurrences(of: ".", with: "")
        if Self.abbreviations.contains(compact) { return true }
        // A short token directly followed by a period is an abbreviation (vgl., Bsp., qqch.).
        let end = range.location + range.length
        if end < text.length, text.character(at: end) == 0x2E, letters.count <= 5 { return true }
        return false
    }

    /// Swiss spelling: "Strasse" is right when "Straße" is.
    private func swissFormIsCorrect(_ word: String, language: String) -> Bool {
        guard word.contains("ss") || word.contains("SS") else { return false }
        let pieces = word.components(separatedBy: "ss")
        var variants: Set<String> = [word.replacingOccurrences(of: "ss", with: "ß")]
        if pieces.count > 2 {
            // Each "ss" on its own (Schlussstrich, Fussballschuss …).
            for index in 1..<pieces.count {
                let left = pieces[..<index].joined(separator: "ss")
                let right = pieces[index...].joined(separator: "ss")
                variants.insert("\(left)ß\(right)")
            }
        }
        return variants.contains { isCorrect($0, language: language) }
    }

    private func isCorrect(_ word: String, language: String) -> Bool {
        checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil
        ).location == NSNotFound
    }

    // MARK: Suggestions

    private func suggestions(for word: String, range: NSRange, in text: String, language: String, lang: Lang) -> [String] {
        var raw: [String] = []
        if let correction = checker.correction(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: tag) {
            raw.append(correction)
        }
        raw += checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: tag) ?? []
        if lang == .de {
            raw = raw.map { $0.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS") }
        }
        var seen: Set<String> = []
        let unique = raw.filter { !$0.isEmpty && $0 != word && seen.insert($0).inserted }
        return Self.ranked(unique, for: word).prefix(4).map { $0 }
    }

    /// Closest spelling first. Changing the capitalisation of the first letter counts as one
    /// more edit (and loses ties), so "mason" suggests "maçon"/"maison" before "Mason"; a
    /// different first letter loses ties too; remaining ties keep the spell checker's order.
    static func ranked(_ suggestions: [String], for word: String) -> [String] {
        let folded = fold(word)
        let firstIsUpper = word.first?.isUppercase ?? false
        return suggestions.enumerated()
            .map { index, suggestion -> (String, Int, Int, Int, Int) in
                let caseChange = (suggestion.first?.isUppercase ?? false) != firstIsUpper ? 1 : 0
                let cost = editDistance(folded, fold(suggestion)) + caseChange
                let firstLetter = fold(String(suggestion.prefix(1))) == fold(String(word.prefix(1))) ? 0 : 1
                return (suggestion, cost, caseChange, firstLetter, index)
            }
            .sorted { ($0.1, $0.2, $0.3, $0.4) < ($1.1, $1.2, $1.3, $1.4) }
            .map(\.0)
    }

    static func fold(_ s: String) -> [Character] {
        Array(TextNormalizer.stripDiacritics(s.lowercased()))
    }

    /// Optimal string alignment distance (adjacent swaps count as one edit).
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}
