import Foundation

// Text primitives of the parser port: a code-point string with JS identity semantics and a tiny
// backtracking matcher that reproduces the JS regexes of parser.js exactly.
//
// Every regex of parser.js works on characters that are all in the BMP (or has the `u` flag), so
// matching on Unicode scalars gives the same result as JS on UTF-16 code units. The one place where
// code units leak through (`segments`, which tests single code units with `\p{L}`) is handled there.

extension VocabParser {
    /// A string as an array of Unicode scalars. Equality and hashing are exact (JS `===`), unlike
    /// Swift `String`, which compares canonically equivalent strings as equal.
    struct PText: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        var u: [Unicode.Scalar]

        init(_ u: [Unicode.Scalar]) { self.u = u }
        init(_ u: ArraySlice<Unicode.Scalar>) { self.u = Array(u) }
        init(_ s: String) { u = Array(s.unicodeScalars) }
        init(stringLiteral value: String) { self.init(value) }

        static let empty = PText([Unicode.Scalar]())

        var string: String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: u)
            return String(view)
        }

        var description: String { string }
        var count: Int { u.count }
        var isEmpty: Bool { u.isEmpty }
        var first: Unicode.Scalar? { u.first }
        var last: Unicode.Scalar? { u.last }
        subscript(i: Int) -> Unicode.Scalar { u[i] }

        /// JS `s.slice(start, end)` for non-negative indices (clamped).
        func slice(_ start: Int, _ end: Int? = nil) -> PText {
            let lo = min(max(start, 0), u.count)
            let hi = max(min(end ?? u.count, u.count), lo)
            return PText(u[lo..<hi])
        }

        static func + (a: PText, b: PText) -> PText { PText(a.u + b.u) }

        func contains(_ c: Unicode.Scalar) -> Bool { u.contains(c) }
        func contains(where predicate: (Unicode.Scalar) -> Bool) -> Bool { u.contains(where: predicate) }

        /// JS `s.includes(needle)`.
        func includes(_ needle: PText) -> Bool { indexOf(needle) != nil }

        /// JS `s.indexOf(needle, from)` (nil for -1).
        func indexOf(_ needle: PText, from: Int = 0) -> Int? {
            let n = needle.u.count
            let start = max(0, from)
            if n == 0 { return min(start, u.count) }
            guard u.count >= n, start <= u.count - n else { return nil }
            let first = needle.u[0]
            var i = start
            while i <= u.count - n {
                if u[i] == first {
                    var j = 1
                    while j < n && u[i + j] == needle.u[j] { j += 1 }
                    if j == n { return i }
                }
                i += 1
            }
            return nil
        }

        func hasPrefix(_ p: PText) -> Bool { u.starts(with: p.u) }

        func hasSuffix(_ p: PText) -> Bool {
            p.u.count <= u.count && u[(u.count - p.u.count)...].elementsEqual(p.u)
        }

        /// JS `s.trim()`.
        func trimmed() -> PText {
            var lo = 0
            var hi = u.count
            while lo < hi && JSCompat.isWhitespace(u[lo]) { lo += 1 }
            while hi > lo && JSCompat.isWhitespace(u[hi - 1]) { hi -= 1 }
            return lo == 0 && hi == u.count ? self : PText(u[lo..<hi])
        }

        /// JS `s.split(separator)` with a string separator (empty parts are kept).
        func split(_ separator: PText) -> [PText] {
            if separator.isEmpty { return u.map { PText([$0]) } }
            var out: [PText] = []
            var p = 0
            while let idx = indexOf(separator, from: p) {
                out.append(slice(p, idx))
                p = idx + separator.count
            }
            out.append(slice(p))
            return out
        }

        /// JS `s.split(' ').length`.
        var spaceSeparatedCount: Int { u.reduce(1) { $0 + ($1 == " " ? 1 : 0) } }

        /// `s.replace(/\t/g, ' ')`
        func tabsToSpaces() -> PText {
            u.contains("\t") ? PText(u.map { $0 == "\t" ? " " : $0 }) : self
        }

        /// JS `s.toLowerCase()` (with the Greek final-sigma rule).
        func lowercased() -> PText {
            if u.allSatisfy({ $0.isASCII }) {
                return PText(u.map { $0.value >= 0x41 && $0.value <= 0x5A ? Unicode.Scalar($0.value + 0x20)! : $0 })
            }
            return PText(Grading.JSText(u).lowercased().scalars)
        }

        /// `/\p{L}/u.test(s)`
        var hasLetter: Bool { u.contains(where: VocabParser.isL) }
    }
}

// MARK: - Character classes

extension VocabParser {
    /// JS `\s`
    @inline(__always) static func isWS(_ c: Unicode.Scalar) -> Bool { JSCompat.isWhitespace(c) }
    /// `\p{L}`
    @inline(__always) static func isL(_ c: Unicode.Scalar) -> Bool { TextNormalizer.isLetterScalar(c) }
    /// `\p{Lu}`
    @inline(__always) static func isLu(_ c: Unicode.Scalar) -> Bool { TextNormalizer.isUppercaseLetter(c) }
    /// `\p{Ll}`
    @inline(__always) static func isLl(_ c: Unicode.Scalar) -> Bool { TextNormalizer.isLowercaseLetter(c) }
    /// `\p{N}`
    @inline(__always) static func isN(_ c: Unicode.Scalar) -> Bool { TextNormalizer.isNumberScalar(c) }
    /// `\d` (ASCII digits, also with the `u` flag)
    @inline(__always) static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    /// Simple case folding as used by `/iu` regexes, for the letters the parser's patterns contain
    /// (ASCII, Latin-1 lowercase letters): A-Z and the Latin-1 capitals fold to lowercase, "ſ" to
    /// "s", the Kelvin sign to "k" and the Angstrom sign to "å".
    static func fold(_ c: Unicode.Scalar) -> UInt32 {
        let v = c.value
        switch v {
        case 0x41...0x5A: return v + 0x20
        case 0xC0...0xDE where v != 0xD7: return v + 0x20
        case 0x17F: return 0x73
        case 0x212A: return 0x6B
        case 0x212B: return 0xE5
        default: return v
        }
    }

    /// `[...]` as a scalar predicate.
    static func oneOf(_ chars: String) -> @Sendable (Unicode.Scalar) -> Bool {
        let set = Set(chars.unicodeScalars.map(\.value))
        return { set.contains($0.value) }
    }
}

// MARK: - Regex engine

extension VocabParser {
    /// A regex node. Matching backtracks like JS: ordered alternation, greedy quantifiers.
    indirect enum RX: Sendable {
        /// One scalar matching the predicate.
        case cls(@Sendable (Unicode.Scalar) -> Bool)
        /// A literal matched case-insensitively (`/iu`); stored as folded scalar values.
        case ci([UInt32])
        /// An exact literal.
        case lit([Unicode.Scalar])
        case seq([RX])
        /// Ordered alternation.
        case alt([RX])
        /// Greedy repetition `{min,max}`.
        case rep(RX, Int, Int)
        /// `^` (no `m` flag: position 0 only).
        case bol
        /// `$` (no `m` flag: end of input only).
        case eol
        /// `(?!…)`
        case notAhead(RX)
        /// `(?=…)`
        case ahead(RX)

        /// A case-insensitive word list: `(?:w1|w2|…)` with `/iu`. A word may use `[xy]` classes
        /// and a trailing `?` after a character or class (as in `unit[eé]?`, `pag\.?`).
        static func words(_ list: String) -> RX {
            .alt(list.split(separator: " ").map { ciWord(String($0)) })
        }

        /// One case-insensitive word in the mini syntax of `words(_:)`.
        static func ciWord(_ w: String) -> RX {
            var items: [RX] = []
            let chars = Array(w.unicodeScalars)
            var i = 0
            while i < chars.count {
                var node: RX
                if chars[i] == "[" {
                    var set: [UInt32] = []
                    i += 1
                    while chars[i] != "]" {
                        set.append(VocabParser.fold(chars[i]))
                        i += 1
                    }
                    let folded = set
                    node = .cls { folded.contains(VocabParser.fold($0)) }
                } else {
                    if chars[i] == "\\" { i += 1 }
                    node = .ci([VocabParser.fold(chars[i])])
                }
                i += 1
                if i < chars.count && chars[i] == "?" {
                    node = .rep(node, 0, 1)
                    i += 1
                }
                items.append(node)
            }
            return .seq(items)
        }

        static func text(_ s: String) -> RX { .lit(Array(s.unicodeScalars)) }
        static func star(_ r: RX) -> RX { .rep(r, 0, .max) }
        static func plus(_ r: RX) -> RX { .rep(r, 1, .max) }
        static func opt(_ r: RX) -> RX { .rep(r, 0, 1) }
        static let ws = RX.cls { VocabParser.isWS($0) }
        static let digit = RX.cls { VocabParser.isDigit($0) }
        static let letter = RX.cls { VocabParser.isL($0) }
    }

    /// Matches `rx` at `i` and calls `k` with each possible end (in backtracking order) until it
    /// returns true.
    static func run(_ rx: RX, _ s: [Unicode.Scalar], _ i: Int, _ k: (Int) -> Bool) -> Bool {
        switch rx {
        case let .cls(p):
            return i < s.count && p(s[i]) && k(i + 1)
        case let .ci(w):
            guard i + w.count <= s.count else { return false }
            for j in 0..<w.count where fold(s[i + j]) != w[j] { return false }
            return k(i + w.count)
        case let .lit(w):
            guard i + w.count <= s.count else { return false }
            for j in 0..<w.count where s[i + j] != w[j] { return false }
            return k(i + w.count)
        case let .seq(items):
            return runSeq(items[...], s, i, k)
        case let .alt(options):
            for o in options where run(o, s, i, k) { return true }
            return false
        case let .rep(r, lo, hi):
            return runRep(r, lo, hi, 0, s, i, k)
        case .bol:
            return i == 0 && k(i)
        case .eol:
            return i == s.count && k(i)
        case let .notAhead(r):
            return !run(r, s, i, { _ in true }) && k(i)
        case let .ahead(r):
            return run(r, s, i, { _ in true }) && k(i)
        }
    }

    private static func runSeq(_ items: ArraySlice<RX>, _ s: [Unicode.Scalar], _ i: Int, _ k: (Int) -> Bool) -> Bool {
        guard let first = items.first else { return k(i) }
        return run(first, s, i) { j in runSeq(items.dropFirst(), s, j, k) }
    }

    private static func runRep(
        _ r: RX, _ lo: Int, _ hi: Int, _ n: Int, _ s: [Unicode.Scalar], _ i: Int, _ k: (Int) -> Bool
    ) -> Bool {
        if n == 0, let single = singleScalar(r) {
            // A repeated single character: iterative (long runs must not recurse), same order.
            var m = 0
            while m < hi && i + m < s.count && single(s[i + m]) { m += 1 }
            var c = m
            while c >= lo {
                if k(i + c) { return true }
                c -= 1
            }
            return false
        }
        if n < hi && run(r, s, i, { j in j != i && runRep(r, lo, hi, n + 1, s, j, k) }) { return true }
        return n >= lo && k(i)
    }

    /// The predicate of a node that matches exactly one scalar, if it is one.
    private static func singleScalar(_ r: RX) -> ((Unicode.Scalar) -> Bool)? {
        switch r {
        case let .cls(p): return p
        case let .lit(w) where w.count == 1: return { $0 == w[0] }
        case let .ci(w) where w.count == 1: return { fold($0) == w[0] }
        default: return nil
        }
    }

    /// The first match of `rx` in `s` (leftmost start, first end in backtracking order).
    static func search(_ rx: RX, _ s: PText) -> (start: Int, end: Int)? {
        var end = -1
        for i in 0...s.count where run(rx, s.u, i, { end = $0; return true }) {
            return (i, end)
        }
        return nil
    }

    /// `rx.test(s)` for a pattern that starts with `^`: only position 0 can match.
    static func matchesAtStart(_ rx: RX, _ s: PText) -> Bool {
        run(rx, s.u, 0) { _ in true }
    }

    /// End of the match of an anchored pattern at position 0, if any.
    static func matchEnd(_ rx: RX, _ s: PText) -> Int? {
        var end: Int?
        _ = run(rx, s.u, 0) { end = $0; return true }
        return end
    }

    /// JS `s.split(regex)` for a regex without capture groups that never matches the empty string.
    static func split(_ s: PText, _ rx: RX) -> [PText] {
        let size = s.count
        if size == 0 { return run(rx, s.u, 0, { _ in true }) ? [] : [s] }
        var parts: [PText] = []
        var p = 0
        var q = 0
        while q < size {
            var e = -1
            if !run(rx, s.u, q, { e = $0; return true }) {
                q += 1
                continue
            }
            e = min(e, size)
            if e == p {
                q += 1
                continue
            }
            parts.append(s.slice(p, q))
            p = e
            q = p
        }
        parts.append(s.slice(p))
        return parts
    }
}

// MARK: - The regexes of parser.js

extension VocabParser {
    /// `PAGE_RE = /^(?:-\s*)?(?:(?:seite|page|pagina|página|pag\.?|s\.|p\.)\s*)?\d{1,4}(?:\s*(?:\/|von|of|sur|de|di)\s*\d{1,4})?(?:\s*-)?$/iu`
    static let pageRE: RX = .seq([
        .bol,
        .opt(.seq([.text("-"), .star(.ws)])),
        .opt(.seq([.words(#"seite page pagina página pag\.? s\. p\."#), .star(.ws)])),
        .rep(.digit, 1, 4),
        .opt(.seq([.star(.ws), .alt([.text("/"), .words("von of sur de di")]), .star(.ws), .rep(.digit, 1, 4)])),
        .opt(.seq([.star(.ws), .text("-")])),
        .eol,
    ])

    /// `URL_RE = /(?:https?:\/\/|www\.)\S|^©|^\(c\)\s/i` (no `u` flag: ASCII case folding only).
    static let urlRE: RX = {
        func ascii(_ w: String) -> RX {
            .seq(w.unicodeScalars.map { c in
                let lower = c.value >= 0x41 && c.value <= 0x5A ? c.value + 0x20 : c.value
                return RX.cls { u in
                    let v = u.value >= 0x41 && u.value <= 0x5A ? u.value + 0x20 : u.value
                    return v == lower
                }
            })
        }
        return .alt([
            .seq([.alt([.seq([ascii("http"), .opt(ascii("s")), .text("://")]), ascii("www.")]), .cls { !VocabParser.isWS($0) }]),
            .seq([.bol, .text("©")]),
            .seq([.bol, ascii("(c)"), .ws]),
        ])
    }()

    private static let keywordList =
        "seite page unit[eé]? unit[aà] lektion le[cç]on lesson chapitre chapter kapitel capitolo cap[ií]tulo unidad "
        + "lezione lecci[oó]n module? th[eè]me thema tema vocabulaire vocabulary vocabulario vocabolario wortschatz "
        + "vokabeln vokabular glossar glossaire dossier [eé]tape abschnitt section"

    /// `KEYWORD_RE = /^(?:seite|page|…|section)(?!\p{L})/iu`
    static let keywordRE: RX = .seq([.bol, .words(keywordList), .notAhead(.letter)])

    /// `ALWAYS_HEADING_RE = /^(?:vocabulaire|…|glossaire)(?!\p{L})/iu`
    static let alwaysHeadingRE: RX = .seq([
        .bol,
        .words("vocabulaire vocabulary vocabulario vocabolario wortschatz vokabeln vokabular glossar glossaire"),
        .notAhead(.letter),
    ])

    /// `ROMAN_RE = /(?:^|\s)[IVXLC]{1,6}(?=[.:)]|\s|$)/`
    static let romanRE: RX = .seq([
        .alt([.bol, .ws]),
        .rep(.cls(oneOf("IVXLC")), 1, 6),
        .ahead(.alt([.cls(oneOf(".:)")), .ws, .eol])),
    ])

    /// `MARKER_RE = /^(?:\(?\d{1,3}[.)]|\d{1,3} ?[-:]|\(?[a-z]\)|[•·▪▫◦‣○●■□➢►▶✓✔✗☐*+>-])[ \t]+/u`
    static let markerRE: RX = .seq([
        .bol,
        .alt([
            .seq([.opt(.text("(")), .rep(.digit, 1, 3), .cls(oneOf(".)"))]),
            .seq([.rep(.digit, 1, 3), .opt(.text(" ")), .cls(oneOf("-:"))]),
            .seq([.opt(.text("(")), .cls { $0.value >= 0x61 && $0.value <= 0x7A }, .text(")")]),
            .cls(oneOf("•·▪▫◦‣○●■□➢►▶✓✔✗☐*+>-")),
        ]),
        .plus(.cls(oneOf(" \t"))),
    ])

    /// `NUMBER_CELL_RE = /^\d{1,4}[.)]?\t/`
    static let numberCellRE: RX = .seq([.bol, .rep(.digit, 1, 4), .opt(.cls(oneOf(".)"))), .text("\t")])

    /// `NUMBERED_RE = /^\d{1,3} ?[-:][ \t]+/`
    static let numberedRE: RX = .seq([
        .bol, .rep(.digit, 1, 3), .opt(.text(" ")), .cls(oneOf("-:")), .plus(.cls(oneOf(" \t"))),
    ])

    /// `ARROW_RE = /\s*(?:<->|<=>|-->|->|=>|→|⇒|⟶|↔|⟹|➔|➜)\s*/`
    static let arrowRE: RX = .seq([
        .star(.ws),
        .alt(["<->", "<=>", "-->", "->", "=>", "→", "⇒", "⟶", "↔", "⟹", "➔", "➜"].map { RX.text($0) }),
        .star(.ws),
    ])

    /// `/,(?![\s,])/` (Quizlet's comma export)
    static let tightCommaRE: RX = .seq([.text(","), .notAhead(.alt([.ws, .text(",")]))])

    /// `/\s*：\s*/` (the full-width colon, "你好：Hallo")
    static let fullColonRE: RX = .seq([.star(.ws), .text("："), .star(.ws)])

    /// `GLUED_DASH_RE = /(\p{L}[.!?)）]?)[–—](?=[\p{L}(（«"„“])/u`
    static let gluedDashRE: RX = .seq([
        .letter,
        .opt(.cls(oneOf(".!?)）"))),
        .cls(oneOf("–—")),
        .ahead(.cls { VocabParser.isL($0) || "(（«\"„“".unicodeScalars.contains($0) }),
    ])

    /// `DE_ARTICLE_RE = /(?:^|\s)(?:sich|der|die|das|den|dem|des|ein|eine|einen|einem|einer)\s/`
    static let deArticleRE: RX = .seq([
        .alt([.bol, .ws]),
        .alt("sich der die das den dem des ein eine einen einem einer".split(separator: " ").map { RX.text(String($0)) }),
        .ws,
    ])

    /// `FR_OBJECT_END_RE = /\s(?:le|la|les|un|une|du|des)\s\p{Ll}+$/u`
    static let frObjectEndRE: RX = .seq([
        .ws,
        .alt("le la les un une du des".split(separator: " ").map { RX.text(String($0)) }),
        .ws,
        .plus(.cls { VocabParser.isLl($0) }),
        .eol,
    ])

    /// `ENTRY_START_RE = /^(?:(?:le|la|…|sich)\s|(?:l|d)'|s'(?!ils?\s))/iu`
    static let entryStartRE: RX = .seq([
        .bol,
        .alt([
            .seq([.words("le la les un une des du der die das den dem ein eine the a an to el los las il lo gli uno una se sich"), .ws]),
            .seq([.words("l d"), .text("'")]),
            .seq([.ciWord("s"), .text("'"), .notAhead(.seq([.ciWord("il"), .opt(.ciWord("s")), .ws]))]),
        ]),
    ])

    /// `/^(?:(?:et|ou|que|qui|dont|and|or|of|than)\s|qu')/iu`
    static let sentenceContinuationRE: RX = .seq([
        .bol,
        .alt([.seq([.words("et ou que qui dont and or of than"), .ws]), .seq([.ciWord("qu"), .text("'")])]),
    ])

    /// `/^(?:[A-Z]|\d{1,2}|[IVX]{1,4})[.)]\s/`
    static let headingNumberRE: RX = .seq([
        .bol,
        .alt([.cls { $0.value >= 0x41 && $0.value <= 0x5A }, .rep(.digit, 1, 2), .rep(.cls(oneOf("IVX")), 1, 4)]),
        .cls(oneOf(".)")),
        .ws,
    ])
}

// MARK: - Regex entry points
//
// Each one first checks a cheap necessary condition (a character every match needs), which keeps
// the backtracking matcher off the hot path for the vast majority of lines.

extension VocabParser {
    /// The first three (folded) letters of every `KEYWORD_RE` word.
    private static let keywordPrefixes: Set<[UInt32]> = Set(
        "sei pag uni lek lec leç les cha kap cap lez mod the thè tem voc wor vok glo dos eta éta abs sec"
            .split(separator: " ").map { $0.unicodeScalars.map(\.value) })
    private static let alwaysHeadingInitials: Set<UInt32> = Set("vwg".unicodeScalars.map(\.value))
    private static let entryInitials: Set<UInt32> = Set("ludtaeigs".unicodeScalars.map(\.value))
    private static let continuationInitials: Set<UInt32> = Set("eoqdat".unicodeScalars.map(\.value))
    private static let bullets: Set<UInt32> = Set("•·▪▫◦‣○●■□➢►▶✓✔✗☐*+>-".unicodeScalars.map(\.value))
    private static let arrowMarks: Set<UInt32> = Set(">→⇒⟶↔⟹➔➜".unicodeScalars.map(\.value))

    /// `PAGE_RE.test(t)`
    static func isPageNumber(_ t: PText) -> Bool {
        t.contains(where: isDigit) && matchesAtStart(pageRE, t)
    }

    /// `URL_RE.test(t)`
    static func hasURL(_ t: PText) -> Bool {
        guard t.first == "©" || t.first == "(" || t.contains("/") || t.contains(".") else { return false }
        return search(urlRE, t) != nil
    }

    /// Length of the `KEYWORD_RE` match (`kw[0].length`), nil without a match.
    static func keywordEnd(_ t: PText) -> Int? {
        guard t.count >= 4, keywordPrefixes.contains([fold(t[0]), fold(t[1]), fold(t[2])]) else { return nil }
        return matchEnd(keywordRE, t)
    }

    /// `ALWAYS_HEADING_RE.test(t)`
    static func isAlwaysHeading(_ t: PText) -> Bool {
        guard let c = t.first, alwaysHeadingInitials.contains(fold(c)) else { return false }
        return matchesAtStart(alwaysHeadingRE, t)
    }

    /// Length of the `MARKER_RE` match, nil without a match.
    static func markerEnd(_ t: PText) -> Int? {
        guard t.count >= 2, let c = t.first else { return nil }
        let next = t[1]
        let plausible = isDigit(c) || c == "("
            || (c.value >= 0x61 && c.value <= 0x7A && next == ")")
            || (bullets.contains(c.value) && (next == " " || next == "\t"))
        return plausible ? matchEnd(markerRE, t) : nil
    }

    /// Length of the `NUMBER_CELL_RE` match, nil without a match.
    static func numberCellEnd(_ t: PText) -> Int? {
        guard let c = t.first, isDigit(c) else { return nil }
        return matchEnd(numberCellRE, t)
    }

    /// Length of the `NUMBERED_RE` match, nil without a match.
    static func numberedEnd(_ t: PText) -> Int? {
        guard let c = t.first, isDigit(c) else { return nil }
        return matchEnd(numberedRE, t)
    }

    /// `ENTRY_START_RE.test(t)`
    static func startsEntry(_ t: PText) -> Bool {
        guard let c = t.first, entryInitials.contains(fold(c)) else { return false }
        return matchesAtStart(entryStartRE, t)
    }

    /// `/^(?:(?:et|ou|que|qui|dont|and|or|of|than)\s|qu')/iu.test(t)`
    static func startsContinuation(_ t: PText) -> Bool {
        guard let c = t.first, continuationInitials.contains(fold(c)) else { return false }
        return matchesAtStart(sentenceContinuationRE, t)
    }

    /// `/^(?:[A-Z]|\d{1,2}|[IVX]{1,4})[.)]\s/.test(t)`
    static func startsWithHeadingNumber(_ t: PText) -> Bool {
        guard let c = t.first, isDigit(c) || (c.value >= 0x41 && c.value <= 0x5A) else { return false }
        return matchesAtStart(headingNumberRE, t)
    }

    /// `ROMAN_RE.test(t)`
    static func hasRomanNumber(_ t: PText) -> Bool {
        t.contains { "IVXLC".unicodeScalars.contains($0) } && search(romanRE, t) != nil
    }

    /// `t.split(ARROW_RE)`
    static func splitArrows(_ t: PText) -> [PText] {
        t.contains(where: { arrowMarks.contains($0.value) }) ? split(t, arrowRE) : [t]
    }

    /// `t.split(/,(?![\s,])/)`
    static func splitTightComma(_ t: PText) -> [PText] {
        t.contains(",") ? split(t, tightCommaRE) : [t]
    }

    /// `t.split(/\s*：\s*/)`
    static func splitFullColon(_ t: PText) -> [PText] {
        t.contains("：") ? split(t, fullColonRE) : [t]
    }
}
