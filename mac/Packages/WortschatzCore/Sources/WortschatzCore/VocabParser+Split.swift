import Foundation

// Splitting helpers of parser.js: delimiter candidates, CSV fields, quotes, language-based splits
// and the joining of wrapped lines.

extension VocabParser {
    // MARK: Delimiter candidates

    /// A delimiter candidate (JS `{ id, kind, re?, joiner?, spaced? }`). `tag` stands for the JS
    /// object identity (`cand === COMMA`) and selects the regex of the `regex` kind.
    struct Candidate: Sendable {
        enum Kind: Sendable { case cells, first, regex, csv, gap }
        enum Tag: Int, Sendable, CaseIterable {
            case tab, dash, arrow, spacedEquals, equals, spacedColon, colon, fullColon, semicolon, pipe, gap, comma, tightComma,
                 custom
        }

        let tag: Tag
        let id: PText
        let kind: Kind
        var joiner: PText?
        var spaced: PText?

        static func == (a: Candidate, b: Candidate) -> Bool { a.tag == b.tag && a.tag != .custom }
    }

    /// Delimiter candidates for auto detection, in priority order. `first` and `regex` split on
    /// every occurrence; extra parts are resolved by language.
    static let candidates: [Candidate] = [
        Candidate(tag: .tab, id: "\t", kind: .cells),
        Candidate(tag: .dash, id: " - ", kind: .first),
        Candidate(tag: .arrow, id: " → ", kind: .regex),
        Candidate(tag: .spacedEquals, id: " = ", kind: .first),
        Candidate(tag: .equals, id: "=", kind: .first),
        Candidate(tag: .spacedColon, id: " : ", kind: .first),
        Candidate(tag: .colon, id: ": ", kind: .first),
        // Full-width colon ("你好：Hallo"): reported like ": ", the text keeps "：".
        Candidate(tag: .fullColon, id: ": ", kind: .regex, joiner: "："),
        Candidate(tag: .semicolon, id: ";", kind: .csv),
        Candidate(tag: .pipe, id: "|", kind: .csv),
        Candidate(tag: .gap, id: "  ", kind: .gap),
    ]
    static let gapCandidate = candidates[candidates.count - 1]
    static let comma = Candidate(tag: .comma, id: ",", kind: .csv)
    /// Quizlet's comma export: "beau, belle,schön" (no space after the separator, no quotes).
    static let tightComma = Candidate(tag: .tightComma, id: ",", kind: .regex, joiner: ", ")
    /// Delimiters inside the cells of two page columns ("le chat – die Katze<TAB>le chien – der Hund").
    static let innerCandidates = candidates.filter { $0.kind == .first || $0.kind == .regex }

    static func customCandidate(_ delim: PText) -> Candidate {
        if delim == "\t" { return Candidate(tag: .custom, id: "\t", kind: .cells) }
        if delim == "," || delim == ";" || delim == "|" { return Candidate(tag: .custom, id: delim, kind: .csv) }
        let spaced: PText? = delim.trimmed() == delim && !delim.isEmpty && delim.u.allSatisfy { !isL($0) && !isN($0) }
            ? " " + delim + " " : nil
        return Candidate(tag: .custom, id: delim, kind: .first, spaced: spaced)
    }

    // MARK: Fields

    /// Delimiter-separated fields with double-quote support ("a, b","c").
    static func csvSplit(_ text: PText, _ delim: PText) -> [PText] {
        let s = text.u
        var cells: [PText] = []
        var i = 0
        while true {
            var j = i
            while j < s.count && s[j] == " " { j += 1 }
            if j < s.count && s[j] == "\"" {
                var k = j + 1
                var val: [Unicode.Scalar] = []
                while k < s.count {
                    if s[k] == "\"" {
                        if k + 1 < s.count && s[k + 1] == "\"" {
                            val.append("\"")
                            k += 2
                            continue
                        }
                        break
                    }
                    val.append(s[k])
                    k += 1
                }
                if k >= s.count {
                    // Unterminated quote: keep the rest verbatim.
                    cells.append(text.slice(j).trimmed())
                    break
                }
                guard let next = text.indexOf(delim, from: k + 1) else {
                    cells.append((PText(val) + text.slice(k + 1)).trimmed())
                    break
                }
                cells.append((PText(val) + text.slice(k + 1, next)).trimmed())
                i = next + delim.count
            } else {
                guard let next = text.indexOf(delim, from: i) else {
                    cells.append(text.slice(i).trimmed())
                    break
                }
                cells.append(text.slice(i, next).trimmed())
                i = next + delim.count
            }
        }
        return cells
    }

    /// Pairs of surrounding quotes: "x", “x”, „x“, „x”, «x», »x«, ‹x›, 'x'.
    private static let quotePairs: Set<[UInt32]> = [
        [0x22, 0x22], [0x201C, 0x201D], [0x201E, 0x201C], [0x201E, 0x201D], [0xAB, 0xBB], [0xBB, 0xAB],
        [0x2039, 0x203A], [0x27, 0x27],
    ]

    /// Strip one pair of surrounding quotes.
    static func unquote(_ s: PText) -> PText {
        let t = s.trimmed()
        if t.count >= 2, let a = t.first, let b = t.last, quotePairs.contains([a.value, b.value]) {
            let inner = t.slice(1, t.count - 1)
            if !inner.contains(a) && !inner.contains(b) { return inner.trimmed() }
        }
        return t
    }

    struct SplitResult {
        var parts: [PText]
        var joiner: PText
    }

    /// Split one line with a candidate. One part = delimiter absent. The splits of the built-in
    /// candidates are cached on the line (detection, alignment and both language orders reuse them).
    static func splitWith(_ line: Line, _ cand: Candidate) -> SplitResult {
        let cacheable = cand.tag != .custom
        if cacheable, let cached = line.cachedSplit(cand.tag.rawValue) { return cached }
        let result: SplitResult
        switch cand.kind {
        case .cells: result = splitCells(line.text)
        case .gap: result = splitCells(line.gap)
        default: result = splitText(line.text, cand)
        }
        if cacheable { line.cacheSplit(result, cand.tag.rawValue) }
        return result
    }

    /// Tab-separated cells (the `cells` and `gap` candidates).
    private static func splitCells(_ src: PText) -> SplitResult {
        if !src.contains("\t") { return SplitResult(parts: [src.trimmed()], joiner: ", ") }
        return SplitResult(parts: csvSplit(src, "\t").map(unquote), joiner: ", ")
    }

    /// `splitWith({ text }, cand)`: the split of a bare text (a cell of two page columns).
    static func splitText(_ raw: PText, _ cand: Candidate) -> SplitResult {
        let text = raw.tabsToSpaces().trimmed()
        switch cand.kind {
        case .cells, .gap:
            // Not used on bare texts by the parser; splits at tabs like a line would.
            return splitCells(raw)
        case .csv:
            let joiner: PText = cand.id == ";" || cand.id == "," ? cand.id + " " : ", "
            // Without the delimiter and quotes there is a single cell.
            if !text.includes(cand.id) && !text.contains("\"") { return SplitResult(parts: [text], joiner: joiner) }
            let cells = csvSplit(text, cand.id)
            // Table borders: "| a | b |", or only one of them when OCR cropped the other edge.
            if cand.id == "|" && cells.count > 2 {
                let lead = cells[0].isEmpty
                let trail = cells[cells.count - 1].isEmpty
                if lead && trail { return SplitResult(parts: Array(cells[1..<(cells.count - 1)]), joiner: joiner) }
                if lead || trail {
                    return SplitResult(parts: lead ? Array(cells.dropFirst()) : Array(cells.dropLast()), joiner: joiner)
                }
            }
            return SplitResult(parts: cells, joiner: joiner)
        case .regex:
            let parts: [PText]
            switch cand.tag {
            case .tightComma: parts = splitTightComma(text).map(unquote)
            case .fullColon: parts = splitFullColon(text).map(unquote)
            default: parts = splitArrows(text).map(unquote)
            }
            return SplitResult(parts: parts, joiner: cand.joiner ?? cand.id)
        case .first:
            let delim = cand.spaced.map { text.includes($0) ? $0 : cand.id } ?? cand.id
            if text.includes(delim) { return SplitResult(parts: text.split(delim).map(unquote), joiner: delim) }
            // "le chat -" / "= die Katze": delimiter present but one side empty.
            let bare = delim.trimmed()
            if !bare.isEmpty && bare != delim {
                if text.hasSuffix(" " + bare) {
                    return SplitResult(parts: [unquote(text.slice(0, text.count - bare.count - 1)), .empty], joiner: delim)
                }
                if text.hasPrefix(bare + " ") {
                    return SplitResult(parts: [.empty, unquote(text.slice(bare.count + 1))], joiner: delim)
                }
            }
            return SplitResult(parts: [text], joiner: delim)
        }
    }

    /// How many cards a split represents for detection purposes (0 = not a pairing).
    static func pairingCount(_ parts: [PText], _ cand: Candidate) -> Int {
        if parts.count < 2 { return 0 }
        let filled = parts.filter { !$0.isEmpty }.count
        if cand == comma || cand == tightComma { return parts.count == 2 && filled == 2 ? 1 : 0 }
        if (cand.kind == .cells || cand.kind == .gap) && parts.count >= 4 && parts.count % 2 == 0 && filled == parts.count {
            return parts.count / 2
        }
        if filled == parts.count { return 1 }
        return parts.count == 2 && filled == 1 ? 1 : 0
    }

    /// Reduce >2 parts to [term, definition] at the position with the strongest language contrast
    /// (first occurrence when languages are unknown). `uncertain` marks a close call or a clearly
    /// misplaced part on either side.
    static func resolveSplit(
        _ ctx: Context, _ rawParts: [PText], _ a: Int?, _ b: Int?, _ joiner: PText
    ) -> (parts: [PText], uncertain: Bool) {
        if rawParts.count <= 2 { return (rawParts, false) }
        let parts = rawParts.filter { !$0.isEmpty }
        if parts.count < 2 { return ([parts.first ?? .empty, .empty], false) }
        var best = 1
        var uncertain = false
        if let a, let b, a != b {
            let d = parts.map { p -> Double in
                let s = ctx.score(p)
                return s[a] - s[b]
            }
            var prefixes: [Double] = []
            var prefix = 0.0
            for k in 1..<parts.count {
                prefix += d[k - 1]
                prefixes.append(prefix)
                if prefix > prefixes[best - 1] + 1e-9 { best = k }
            }
            var runnerUp = -Double.infinity
            for (i, p) in prefixes.enumerated() where i != best - 1 { runnerUp = max(runnerUp, p) }
            let misplaced = d.enumerated().contains { i, v in i < best ? v <= -splitMisfit : v >= splitMisfit }
            uncertain = misplaced || prefixes[best - 1] - runnerUp < splitMargin
        }
        return ([join(parts[..<best], joiner), join(parts[best...], joiner)], uncertain)
    }

    static func join(_ parts: ArraySlice<PText>, _ joiner: PText) -> PText {
        var out: [Unicode.Scalar] = []
        for (i, p) in parts.enumerated() {
            if i > 0 { out.append(contentsOf: joiner.u) }
            out.append(contentsOf: p.u)
        }
        return PText(out)
    }

    // MARK: Language splits

    struct Segment {
        var start: Int
        var end: Int
    }

    /// Word segments of a line: split at whitespace and at hyphens, commas and semicolons glued
    /// between letters ("chat-die", "plage,der"), keeping offsets so the text can be cut.
    static func segments(_ text: PText) -> [Segment] {
        let s = text.u
        var segs: [Segment] = []
        var i = 0
        // JS tests the neighbours as single UTF-16 code units: an astral letter is no letter there.
        let bmpLetter = { (c: Unicode.Scalar) in c.value <= 0xFFFF && isL(c) }
        while i < s.count {
            if isWS(s[i]) {
                i += 1
                continue
            }
            let m = i
            var e = i
            while e < s.count && !isWS(s[e]) { e += 1 }
            var start = m
            if e - m > 2 {
                for k in (m + 1)..<(e - 1) {
                    let c = s[k]
                    if (c == "-" || c == "," || c == ";") && bmpLetter(s[k - 1]) && bmpLetter(s[k + 1]) {
                        segs.append(Segment(start: start, end: k))
                        start = k + 1
                    }
                }
            }
            segs.append(Segment(start: start, end: e))
            i = e
        }
        return segs
    }

    /// Cut a line before segment k, dropping the separator characters around the cut.
    static func cutAt(_ text: PText, _ segs: [Segment], _ k: Int) -> (left: PText, right: PText) {
        // .replace(/[\s\-=:;,/|>→]+$/u, '') and .replace(/^[\s\-=:;,/|<>→]+/u, '')
        let leftEnd: (Unicode.Scalar) -> Bool = { isWS($0) || "-=:;,/|>→".unicodeScalars.contains($0) }
        let rightStart: (Unicode.Scalar) -> Bool = { isWS($0) || "-=:;,/|<>→".unicodeScalars.contains($0) }
        var left = Array(text.u[0..<segs[k - 1].end])
        while let c = left.last, leftEnd(c) { left.removeLast() }
        var r = segs[k].start
        while r < text.count && rightStart(text[r]) { r += 1 }
        return (unquote(PText(left)), unquote(text.slice(r)))
    }

    struct LanguageSplit {
        var left: PText
        var right: PText
        /// 1: left is language A; -1: left is language B.
        var order: Int
        var score: Double
    }

    /// Split a single bilingual line ("le chat die Katze") at the segment boundary with the
    /// strongest language contrast; the halves are then verified with full-context scoring.
    static func languageSplit(_ ctx: Context, _ rawText: PText, _ a: Int?, _ b: Int?) -> LanguageSplit? {
        guard let a, let b, a != b else { return nil }
        let key = Context.SplitKey(text: rawText, a: a, b: b)
        if let cached = ctx.languageSplits[key] { return cached }
        let result = computeLanguageSplit(ctx, rawText, a, b)
        ctx.languageSplits[key] = result
        return result
    }

    private static func computeLanguageSplit(_ ctx: Context, _ rawText: PText, _ a: Int, _ b: Int) -> LanguageSplit? {
        let text = rawText.tabsToSpaces()
        let segs = segments(text)
        if segs.count < 2 || segs.count > 24 { return nil }
        let d = segs.map { sg -> Double in
            let s = ctx.score(text.slice(sg.start, sg.end))
            return s[a] - s[b]
        }
        var total = 0.0
        for v in d { total += v }
        var prefix = 0.0
        var best: (k: Int, v: Double, order: Int)?
        for k in 1..<segs.count {
            prefix += d[k - 1]
            let suffix = total - prefix
            let v1 = min(prefix, -suffix)
            let v2 = min(-prefix, suffix)
            if best == nil || v1 > best!.v { best = (k, v1, 1) }
            if v2 > best!.v { best = (k, v2, -1) }
        }
        guard let best, best.v >= 1 else { return nil }
        let (left, right) = cutAt(text, segs, best.k)
        if !left.hasLetter || !right.hasLetter { return nil }
        let pl = ctx.pairProb(left, a, b)
        let pr = ctx.pairProb(right, a, b)
        let score = best.order == 1 ? min(pl, 1 - pr) : min(1 - pl, pr)
        return score >= 0.8 ? LanguageSplit(left: left, right: right, order: best.order, score: score) : nil
    }

    /// A line of exactly two words that lean to different languages ("chien Hund": "chien" looks a
    /// little German). There is only one place to cut, so each word leaning at least one unit to
    /// its side is enough where `languageSplit` asks for a clear call on both. Only used once the
    /// list is known to hold both languages on every line.
    static func twoWordSplit(_ ctx: Context, _ rawText: PText, _ a: Int, _ b: Int) -> LanguageSplit? {
        let text = rawText.tabsToSpaces()
        let segs = segments(text)
        if segs.count != 2 || a == b { return nil }
        let d = segs.map { sg -> Double in
            let s = ctx.score(text.slice(sg.start, sg.end))
            return s[a] - s[b]
        }
        if min(abs(d[0]), abs(d[1])) < 1 || (d[0] > 0) == (d[1] > 0) { return nil }
        let (left, right) = cutAt(text, segs, 1)
        if !left.hasLetter || !right.hasLetter { return nil }
        let order = d[0] > 0 ? 1 : -1
        let pl = ctx.pairProb(left, a, b)
        let pr = ctx.pairProb(right, a, b)
        let score = order == 1 ? min(pl, 1 - pr) : min(1 - pl, pr)
        return LanguageSplit(left: left, right: right, order: order, score: score)
    }

    // MARK: Wrapped lines

    /// Words after which a continuation line is joined with a plain space: articles, conjunctions,
    /// prepositions and German object placeholders ("sich mit jdm / verstehen"). Separable
    /// particles (an, aus, um, vor, nach) end German clauses and are left out.
    static let openEndings: Set<PText> = Set(
        ("der die das den dem des ein eine einen einem einer le la les l' un une du de à au aux et ou und oder the a "
            + "an to of and or el los las il lo gli i e y o sich se s' zu mit von für auf in en dans pour avec sur par chez "
            + "sans sous vers entre que ne jdm jdn jds etw über unter bei gegen ohne durch zum zur im am beim vom with for "
            + "from at on by into about").split(separator: " ").map { PText(String($0)) })

    static func lastWord(_ s: PText) -> PText {
        if s.u.allSatisfy(\.isASCII) {
            // ASCII: lowercasing maps each character on its own, so only the tail is needed.
            var i = s.count
            while i > 0 && (isL(s[i - 1]) || s[i - 1] == "'") { i -= 1 }
            return s.slice(i).lowercased()
        }
        let lower = s.lowercased().u
        var i = lower.count
        while i > 0 && (isL(lower[i - 1]) || lower[i - 1] == "'") { i -= 1 }
        return PText(lower[i...])
    }

    /// Does `prev` look unfinished (trailing comma, hyphenation, open article)?
    static func looksUnfinished(_ prev: PText) -> Bool {
        if let last = prev.last, ",;/(".unicodeScalars.contains(last) { return true }
        if endsWithLetterHyphen(prev) { return true }
        return openEndings.contains(lastWord(prev))
    }

    /// `/\p{L}-$/u`
    static func endsWithLetterHyphen(_ s: PText) -> Bool {
        s.count >= 2 && s[s.count - 1] == "-" && isL(s[s.count - 2])
    }

    /// `/[.!?…]$/u`
    static func endsSentence(_ s: PText) -> Bool {
        guard let c = s.last else { return false }
        return c == "." || c == "!" || c == "?" || c == "…"
    }

    static func startsUpper(_ s: PText) -> Bool { s.first.map(isLu) ?? false }
    static func startsLower(_ s: PText) -> Bool { s.first.map(isLl) ?? false }

    /// Cost of treating `next` as the continuation of `prev` on the same side.
    static func mergeCost(_ prev: PText, _ next: PText) -> Double {
        if looksUnfinished(prev) { return 0.5 }
        if let c = next.first, ",;/)".unicodeScalars.contains(c) { return 0.5 }
        if startsUpper(next) { return 4.5 }
        // "Où est" + "la gare ?": an article starts an entry, unless it ends a sentence.
        if startsEntry(next) {
            let endsColon = prev.last == ":"
            if !(endsSentence(next) && startsUpper(prev) && !(endsSentence(prev) || endsColon)) { return 4.5 }
        }
        return mergeCostDefault
    }

    /// A section heading labels a group of entries: a capitalised line ending in a colon or led by
    /// a letter or number ("Les couleurs:", "B) Couleurs et formes"), or a plural word or two.
    static func looksLikeHeading(_ text: PText, _ lang: Int?) -> Bool {
        guard let c = text.first, isLu(c) || isDigit(c) else { return false }
        if text.contains(",") || endsSentence(text) || looksUnfinished(text) { return false }
        if text.last == ":" || startsWithHeadingNumber(text) { return true }
        let words = text.split(" ")
        guard words.count <= 3, let last = words[words.count - 1].last else { return false }
        return lang == it ? (last == "i" || last == "e") : (last == "s" || last == "x")
    }

    /// Lines that continue a sentence rather than start an entry.
    static func continuesSentence(_ text: PText) -> Bool {
        endsSentence(text) || startsContinuation(text)
    }

    /// `(text.match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu) || []).length`
    static func wordCount(_ text: PText) -> Int {
        let s = text.u
        let isLN = { (c: Unicode.Scalar) in isL(c) || isN(c) }
        var count = 0
        var i = 0
        while i < s.count {
            guard isLN(s[i]) else {
                i += 1
                continue
            }
            while i < s.count && isLN(s[i]) { i += 1 }
            while i + 1 < s.count && (s[i] == "'" || s[i] == "’" || s[i] == "-") && isLN(s[i + 1]) {
                i += 1
                while i < s.count && isLN(s[i]) { i += 1 }
            }
            count += 1
        }
        return count
    }

    /// Does a term of `termWords` words match a definition of `defWords` words in length at least
    /// as well as the term without its first line (`restWords`)?
    static func restMatchesLength(_ termWords: Int, _ restWords: Int, _ defWords: Int) -> Bool {
        func misfit(_ w: Int) -> Double { abs(log(Double(max(1, w)) / Double(max(1, defWords)))) }
        return misfit(restWords) <= misfit(termWords)
    }

    /// Join a continuation line onto the previous part.
    static func joinParts(_ a: PText, _ b: PText) -> PText {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if endsWithLetterHyphen(a) { return startsLower(b) ? a.slice(0, a.count - 1) + b : a + b }
        if let c = b.first, ",;:)/".unicodeScalars.contains(c) { return a + b }
        if let c = a.last, ",;:/(".unicodeScalars.contains(c) { return a + " " + b }
        if openEndings.contains(lastWord(a)) { return a + " " + b }
        // A wrapped sentence: "Comment allez-vous" + "aujourd'hui ?", "The weather is nice" + "today".
        let sentenceStart = startsUpper(a) && !a.contains(",") && a.spaceSeparatedCount >= 3
        if startsLower(b) && !endsSentence(a) && (endsSentence(b) || sentenceStart) { return a + " " + b }
        if !a.contains(",") && startsLower(b) && b.u.dropFirst().allSatisfy({ isLl($0) || $0 == "'" || $0 == "-" }) {
            // A German verb ends its phrase: "sich die Zähne" + "putzen".
            if (b.hasSuffix("en") || b.hasSuffix("ern") || b.hasSuffix("eln")) && search(deArticleRE, " " + a) != nil
                && endsWithCapitalisedWord(a) {
                return a + " " + b
            }
            // A French verb phrase cut inside its object: "faire la grasse" + "matinée".
            if a.spaceSeparatedCount >= 3 && search(frObjectEndRE, a) != nil { return a + " " + b }
        }
        return a + ", " + b
    }

    /// `/\p{Lu}\p{Ll}*$/u`
    private static func endsWithCapitalisedWord(_ s: PText) -> Bool {
        var i = s.count
        while i > 0 && isLl(s[i - 1]) { i -= 1 }
        return i > 0 && isLu(s[i - 1])
    }

    // MARK: Pairs

    /// A term/definition pair under construction (a class: later passes extend it in place).
    final class Pair {
        var term: PText
        var def: PText
        var lines: [Int]
        var merged = false
        var langSplit = false
        /// The structure was a guess: shown as lowConfidence.
        var uncertain = false
        var group: Int?
        var order = 0

        init(_ term: PText, _ def: PText, _ lines: [Int]) {
            self.term = term
            self.def = def
            self.lines = Array(Set(lines)).sorted()
        }
    }

    static func makePair(
        _ term: PText, _ def: PText, _ lines: [Int], merged: Bool = false, langSplit: Bool = false,
        uncertain: Bool = false, group: Int? = nil
    ) -> Pair {
        let p = Pair(term, def, lines)
        p.merged = merged
        p.langSplit = langSplit
        p.uncertain = uncertain
        p.group = group
        return p
    }

    /// Loanwords / cognates ("charmant, charmante" = "charmant") carry no language signal.
    static func isCognate(_ a: PText, _ b: PText) -> Bool {
        func tokens(_ s: PText) -> [PText] {
            let lower = s.lowercased().u
            var out: [PText] = []
            var i = 0
            while i < lower.count {
                guard isL(lower[i]) else {
                    i += 1
                    continue
                }
                var e = i
                while e < lower.count && isL(lower[e]) { e += 1 }
                if e - i >= 3 { out.append(PText(lower[i..<e])) }
                i = e
            }
            return out
        }
        let ta = tokens(a)
        let tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return false }
        let (small, big) = ta.count <= tb.count ? (ta, Set(tb)) : (tb, Set(ta))
        return small.allSatisfy(big.contains)
    }
}
