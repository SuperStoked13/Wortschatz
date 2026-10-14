import Foundation

// Preprocessing and line classification (headings, page numbers, noise, list markers, header rows,
// number vocabulary) of parser.js.

extension VocabParser {
    /// One source line (JS `makeLine`). A class: classification and the parsers update it in place.
    final class Line {
        let no: Int
        var span: [Int]
        let blank: Bool
        var kind: SkipReason?
        var weak = false
        let indent: Int
        /// Normalised text with tabs as column separators.
        var text: PText {
            didSet {
                cachedDisplay = nil
                splits = nil
            }
        }
        /// Like `text`, but runs of 2+ spaces count as column separators too.
        var gap: PText { didSet { splits = nil } }
        private var cachedDisplay: PText?
        /// `splitWith` results by candidate tag.
        private var splits: [SplitResult?]?

        init(no: Int, blank: Bool, text: PText, gap: PText, indent: Int) {
            self.no = no
            span = [no]
            self.blank = blank
            self.text = text
            self.gap = gap
            self.indent = indent
        }

        func cachedSplit(_ slot: Int) -> SplitResult? { splits?[slot] ?? nil }

        func cacheSplit(_ result: SplitResult, _ slot: Int) {
            if splits == nil { splits = Array(repeating: nil, count: Candidate.Tag.allCases.count) }
            splits?[slot] = result
        }

        /// JS `displayText(line)`: tabs shown as spaces, trimmed.
        var display: PText {
            if let d = cachedDisplay { return d }
            let d = text.tabsToSpaces().trimmed()
            cachedDisplay = d
            return d
        }
    }

    // MARK: Preprocessing

    /// "le week-end–das Wochenende": an en/em dash glued between words, the only one on a line
    /// without another delimiter.
    static func gluedDash(_ raw: PText) -> Bool {
        var dashes = 0
        for c in raw.u where c == "–" || c == "—" { dashes += 1 }
        guard dashes == 1 else { return false }
        // !/\t|\s[-–—]\s/.test(raw)
        if raw.contains("\t") || hasSpacedDash(raw) { return false }
        return search(gluedDashRE, raw) != nil
    }

    /// `/\s[-–—]\s/.test(s)`
    static func hasSpacedDash(_ s: PText) -> Bool {
        let u = s.u
        guard u.count >= 3 else { return false }
        for i in 1..<(u.count - 1) where (u[i] == "-" || u[i] == "–" || u[i] == "—") && isWS(u[i - 1]) && isWS(u[i + 1]) {
            return true
        }
        return false
    }

    /// Glued dashes are the delimiter of a dash list ("le chat–die Katze" on most lines, or mixed
    /// with spaced dashes). They are then spaced so that normalisation does not turn them into
    /// word-internal hyphens; in other lists they join compounds and become hyphens.
    /// `dashList`: true/false when the delimiter is known, nil to decide here.
    static func spaceGluedDashes(_ raws: [PText], dashList: Bool? = nil) -> [PText] {
        let rewrite: Bool
        if let dashList {
            rewrite = dashList
        } else {
            let content = raws.filter { !$0.trimmed().isEmpty }
            let glued = content.filter(gluedDash).count
            let spaced = content.filter(hasSpacedDash).count
            rewrite = glued > 0 && Double(glued + spaced) >= 0.6 * Double(content.count)
        }
        guard rewrite else { return raws }
        return raws.map { r in
            guard gluedDash(r), let m = search(gluedDashRE, r) else { return r }
            // r.replace(GLUED_DASH_RE, '$1 - '): the dash is the last character of the match.
            return r.slice(0, m.end - 1) + " - " + r.slice(m.end)
        }
    }

    /// `[ \u{A0}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}]`
    private static func isGapSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x20, 0xA0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// `normalizeBasic(s, { keepTabs: true })` (text.js) on scalars. The same steps as
    /// `TextNormalizer.normalizeBasic(_:keepTabs:)`, which it is tested against; NFC is skipped for
    /// text below U+0300, which is always in NFC (no combining marks, no singletons).
    static func normalizeKeepTabs(_ s: PText) -> PText {
        let source: [Unicode.Scalar]
        if s.u.contains(where: { $0.value >= 0x300 }) {
            source = Array(s.string.precomposedStringWithCanonicalMapping.unicodeScalars)
        } else {
            source = s.u
        }
        // Unify apostrophes, dashes and odd spaces; drop zero-width characters; collapse
        // /[ \f\v\r\n]+/ to one space.
        var collapsed: [Unicode.Scalar] = []
        collapsed.reserveCapacity(source.count)
        var inRun = false
        for u in source {
            let v = u.value
            if TextNormalizer.isZeroWidth(v) { continue }
            let c: Unicode.Scalar = TextNormalizer.isApostrophe(v) ? "'"
                : TextNormalizer.isDash(v) ? "-" : TextNormalizer.isOddSpace(v) ? " " : u
            switch c.value {
            case 0x20, 0x0C, 0x0B, 0x0D, 0x0A:
                if !inRun { collapsed.append(" ") }
                inRun = true
            default:
                collapsed.append(c)
                inRun = false
            }
        }
        // / *\t */g → '\t'
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(collapsed.count)
        var afterTab = false
        for c in collapsed {
            if c == "\t" {
                while out.last == " " { out.removeLast() }
                out.append(c)
                afterTab = true
            } else if c == " " && afterTab {
                continue
            } else {
                out.append(c)
                afterTab = false
            }
        }
        return PText(out).trimmed()
    }

    static func makeLine(_ raw: PText, _ no: Int) -> Line {
        let base = normalizeKeepTabs(raw)
        if base.isEmpty { return Line(no: no, blank: true, text: .empty, gap: .empty, indent: 0) }
        // `^[^\S\t\n]*\t` and `\t[^\S\t\n]*$` on the raw line: an explicit empty first/last cell.
        let isEdgeSpace = { (c: Unicode.Scalar) in isWS(c) && c != "\t" && c != "\n" }
        var i = 0
        while i < raw.count && isEdgeSpace(raw[i]) { i += 1 }
        let leadingTab = i < raw.count && raw[i] == "\t"
        var j = raw.count - 1
        while j >= 0 && isEdgeSpace(raw[j]) { j -= 1 }
        let trailingTab = j >= 0 && raw[j] == "\t"
        func keepEdges(_ s: PText) -> PText {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(s.count + 2)
            for c in s.u where !(c == "\t" && out.last == "\t") { out.append(c) }
            if leadingTab && out.first != "\t" { out.insert("\t", at: 0) }
            if trailingTab && out.last != "\t" { out.append("\t") }
            return PText(out)
        }
        let text = keepEdges(base)
        // raw.replace(/[ \u{A0}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}]{2,}/g, '\t')
        var gapped: [Unicode.Scalar] = []
        gapped.reserveCapacity(raw.count)
        var wide = false
        var k = 0
        while k < raw.count {
            if isGapSpace(raw[k]) {
                var e = k
                while e < raw.count && isGapSpace(raw[e]) { e += 1 }
                if e - k >= 2 {
                    gapped.append("\t")
                    wide = true
                } else {
                    gapped.append(raw[k])
                }
                k = e
            } else {
                gapped.append(raw[k])
                k += 1
            }
        }
        // Without a wide gap the gap text is the normalised text itself.
        let gap = wide ? keepEdges(normalizeKeepTabs(PText(gapped))) : text
        // lead = raw.match(/^[ \t\u{A0}]*/)[0]; indent = lead.length + 3 * tabs
        var lead = 0
        var tabs = 0
        while lead < raw.count && (raw[lead] == " " || raw[lead] == "\t" || raw[lead] == "\u{A0}") {
            if raw[lead] == "\t" { tabs += 1 }
            lead += 1
        }
        return Line(no: no, blank: false, text: text, gap: gap, indent: lead + 3 * tabs)
    }

    static func quoteCount(_ s: PText) -> Int { s.u.reduce(0) { $0 + ($1 == "\"" ? 1 : 0) } }

    /// `/(?:^|[,;\t|])\s*"[^"]*$/.test(raw)`: an opening quote whose field continues on the next line.
    private static func opensQuotedField(_ raw: PText) -> Bool {
        guard let q = raw.u.lastIndex(of: "\"") else { return false }
        var k = q
        while true {
            if k == 0 || ",;\t|".unicodeScalars.contains(raw[k - 1]) { return true }
            guard isWS(raw[k - 1]) else { return false }
            k -= 1
        }
    }

    static func preprocess(_ source: PText, dashList: Bool? = nil) -> [Line] {
        var t = source.u
        if t.first == "\u{FEFF}" { t.removeFirst() }
        // .replace(/\r\n?/g, '\n').replace(/[\u{2028}\u{2029}\u0085\v\f]/g, '\n')
        var norm: [Unicode.Scalar] = []
        norm.reserveCapacity(t.count)
        var i = 0
        while i < t.count {
            let c = t[i]
            switch c.value {
            case 0x0D:
                norm.append("\n")
                if i + 1 < t.count && t[i + 1] == "\n" { i += 1 }
            case 0x2028, 0x2029, 0x85, 0x0B, 0x0C:
                norm.append("\n")
            default:
                norm.append(c)
            }
            i += 1
        }
        let raws = spaceGluedDashes(norm.split(separator: "\n", omittingEmptySubsequences: false).map(PText.init), dashList: dashList)
        var lines: [Line] = []
        lines.reserveCapacity(raws.count)
        var r = 0
        while r < raws.count {
            var raw = raws[r]
            var span = [r + 1]
            // A quoted CSV field that continues on the next line(s).
            if quoteCount(raw) % 2 == 1 && opensQuotedField(raw) {
                var joined = raw
                var j = r + 1
                while j < raws.count && j <= r + 4 && !raws[j].trimmed().isEmpty {
                    joined = joined + " " + raws[j]
                    if quoteCount(joined) % 2 == 0 {
                        raw = joined
                        for k in (r + 1)...j { span.append(k + 1) }
                        r = j
                        break
                    }
                    j += 1
                }
            }
            let line = makeLine(raw, span[0])
            line.span = span
            lines.append(line)
            r += 1
        }
        return lines
    }

    // MARK: Classification

    static func stripMarker(_ s: PText) -> PText {
        var out = s
        if let end = markerEnd(out) { out = out.slice(end) }
        // A leading number cell ("12<TAB>le chat - die Katze") is numbering, unless it is the term itself.
        if let end = numberCellEnd(out) {
            let rest = out.slice(end)
            if rest.contains("\t") || rest.includes(" - ") || rest.includes(" = ") || rest.includes(": ") { out = rest }
        }
        return out
    }

    private static let codes: Set<PText> = ["FR", "DE", "EN", "ES", "IT"]

    private static let langNames: [PText: Int] = {
        var out: [PText: Int] = [:]
        let table: [(Int, String)] = [
            (fr, "französisch franzoesisch franz frz français francais french francés frances francese"),
            (de, "deutsch allemand german alemán aleman tedesco"),
            (en, "englisch anglais english inglés ingles inglese"),
            (es, "spanisch espagnol spanish español espanol spagnolo"),
            (it, "italienisch italien italian italiano"),
        ]
        for (concept, names) in table {
            for name in names.split(separator: " ") { out[PText(String(name))] = concept }
        }
        return out
    }()

    private static let labels: [PText: String] = {
        let pairs: [(String, String)] = [
            ("begriff", "term"), ("begriffe", "term"), ("term", "term"), ("terms", "term"), ("terme", "term"),
            ("definition", "def"), ("définition", "def"), ("definitionen", "def"), ("wort", "word"),
            ("wörter", "word"), ("vokabel", "word"), ("mot", "word"), ("mots", "word"), ("word", "word"),
            ("words", "word"), ("palabra", "word"), ("parola", "word"), ("übersetzung", "trans"),
            ("uebersetzung", "trans"), ("traduction", "trans"), ("translation", "trans"), ("traducción", "trans"),
            ("traduzione", "trans"), ("bedeutung", "meaning"), ("meaning", "meaning"), ("signification", "meaning"),
            ("frage", "q"), ("question", "q"), ("antwort", "a"), ("answer", "a"), ("réponse", "a"),
        ]
        var out: [PText: String] = [:]
        for (k, v) in pairs { out[PText(k)] = v }
        return out
    }()

    /// Result of `headerRow`: nil = no header row; `(nil, nil)` = a label row ("Begriff - Definition").
    struct HeaderRow {
        var left: Int?
        var right: Int?
    }

    /// Header row naming the languages or columns ("Französisch | Deutsch", "Begriff - Definition").
    static func headerRow(_ text: PText) -> HeaderRow? {
        // text.split(/[^\p{L}.]+/u).map((w) => w.replace(/\.+$/, '')).filter(Boolean)
        // Every word must be a language code, a language name or a column label, so the scan
        // stops at the first other word.
        var words: [PText] = []
        var current: [Unicode.Scalar] = []
        func flush() -> Bool {
            while current.last == "." { current.removeLast() }
            defer { current.removeAll() }
            if current.isEmpty { return true }
            let w = PText(current)
            if !codes.contains(w) {
                let lw = w.lowercased()
                if langNames[lw] == nil && labels[lw] == nil { return false }
            }
            words.append(w)
            return words.count <= 6
        }
        for c in text.u {
            if isL(c) || c == "." {
                current.append(c)
            } else if !flush() {
                return nil
            }
        }
        if !flush() { return nil }
        guard words.count >= 2 && words.count <= 6 else { return nil }
        if words.allSatisfy(codes.contains) && Set(words).count == words.count {
            return HeaderRow(left: index(ofCode: words[0]), right: index(ofCode: words[1]))
        }
        var langs: [Int] = []
        var found: [String] = []
        for w in words {
            let lw = w.lowercased()
            if let l = langNames[lw] {
                langs.append(l)
            } else if let label = labels[lw] {
                found.append(label)
            } else {
                return nil
            }
        }
        if Set(langs).count != langs.count || Set(found).count != found.count { return nil }
        if langs.count >= 2 { return HeaderRow(left: langs[0], right: langs[1]) }
        return HeaderRow(left: nil, right: nil)
    }

    private static func index(ofCode code: PText) -> Int? {
        index(of: Lang(rawValue: code.lowercased().string))
    }

    /// Number vocabulary ("11 - onze", or "onze" / "11" on alternating lines): the numbers are the
    /// definitions, not list markers or page numbers.
    static func numberVocabulary(_ ctx: Context, _ lines: [Line]) -> (keepMarkers: Bool, keepBare: Bool) {
        let flat = lines.filter { !$0.blank }.map(\.display)
        let numbered = flat.filter { numberedEnd($0) != nil }
        var keepMarkers = false
        if numbered.count >= 2 && Double(numbered.count) >= 0.8 * Double(flat.count) {
            // "1 - le chat - die Katze" is still a numbered list, and so are numbered lines that
            // alternate between two languages.
            keepMarkers = numberWords(ctx, numbered.map { $0.slice(numberedEnd($0) ?? 0) })
        }
        // Bare number lines that alternate 1:1 with such word lines are number vocabulary
        // ("onze" / "11"). Elsewhere they number table rows or are page numbers.
        let bare = flat.map(isBareNumber)
        var alternations = 0
        if flat.count > 1 {
            for k in 1..<flat.count where bare[k] != bare[k - 1] { alternations += 1 }
        }
        let keepBare = bare.filter { $0 }.count >= 3 && Double(alternations) >= 0.8 * Double(flat.count - 1)
            && numberWords(ctx, flat.indices.filter { !bare[$0] }.map { flat[$0] })
        return (keepMarkers, keepBare)
    }

    /// `BARE_NUMBER_RE = /^\d{1,4}$/`
    static func isBareNumber(_ s: PText) -> Bool {
        s.count >= 1 && s.count <= 4 && s.u.allSatisfy(isDigit)
    }

    /// `/\t| - | = |=| : |: |;|\||->|→/.test(t)`
    private static func hasDelimiterLike(_ t: PText) -> Bool {
        t.contains("\t") || t.includes(" - ") || t.contains("=") || t.includes(": ") || t.contains(";")
            || t.contains("|") || t.includes("->") || t.contains("→")
    }

    /// The word side of number vocabulary: one language, no delimiter and no second language
    /// inside a line.
    static func numberWords(_ ctx: Context, _ words: [PText]) -> Bool {
        if Double(words.filter(hasDelimiterLike).count) > 0.2 * Double(words.count) { return false }
        let shares = ctx.languageShares(words)
        if shares[1].share >= 0.3 { return false }
        let (l1, l2) = (shares[0].lang, shares[1].lang)
        return Double(words.filter { languageSplit(ctx, $0, l1, l2) != nil }.count) <= 0.2 * Double(words.count)
    }

    @discardableResult
    static func classify(_ ctx: Context, _ lines: [Line]) -> [Line] {
        let numbers = numberVocabulary(ctx, lines)
        for line in lines {
            if line.blank { continue }
            let flat = line.display
            if numbers.keepBare && isBareNumber(flat) { continue }
            if isPageNumber(flat) {
                ctx.skip(line, .pageNumber)
                continue
            }
            if !flat.hasLetter || hasURL(flat) {
                ctx.skip(line, .noise)
                continue
            }
            if !numbers.keepMarkers || numberedEnd(flat) == nil {
                line.text = stripMarker(line.text)
                line.gap = stripMarker(line.gap)
            }
            let t = line.display
            if !t.hasLetter {
                ctx.skip(line, .noise)
                continue
            }
            if let header = headerRow(t) {
                if ctx.header == nil, let left = header.left, let right = header.right { ctx.header = (left, right) }
                ctx.skip(line, .heading)
                continue
            }
            if let kwEnd = keywordEnd(t) {
                // rest = t.slice(kw[0].length).replace(/^[\s:.-]+/, '')
                var r = kwEnd
                while r < t.count && (isWS(t[r]) || t[r] == ":" || t[r] == "." || t[r] == "-") { r += 1 }
                let rest = t.slice(r)
                // "Vocabulaire : les animaux" is a title; "vocabulary - Wortschatz" is a card.
                let title = (t.first.map(isLu) ?? false) && !(keywordEnd(rest) != nil && !rest.contains(where: isWS))
                if rest.contains(where: isDigit) || hasRomanNumber(rest) || (!rest.isEmpty && title && isAlwaysHeading(t)) {
                    ctx.skip(line, .heading)
                    continue
                }
                if rest.isEmpty { line.weak = true }
            }
            if t.count == 1 && isLu(t[0]) {
                ctx.skip(line, .heading)
                continue
            }
            // Single letters and ALL-CAPS lines are probably titles, but may still pair.
            if (t.count == 1 && isLl(t[0])) || (!t.contains(where: isLl) && t.u.filter(isLu).count >= 4) {
                line.weak = true
            }
        }
        return lines
    }
}
