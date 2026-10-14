import Foundation

// Delimited lists of parser.js: delimiter detection, page columns, three-cell rows, runs of lines
// without the delimiter, inline lists and the explicit delimiter mode.

extension VocabParser {
    /// The structure found by one of the parsers, before `finish`.
    struct Outcome {
        var pairs: [Pair]
        var format: ParseFormat
        var delimiter: String?
    }

    /// One line of a delimited list after splitting (JS entry objects).
    final class Entry {
        let line: Line
        let skip: Bool
        var parts: [PText] = []
        var joiner: PText = .empty
        var count = 0
        /// One [term, def] per page column, when every cell holds a whole pair.
        var groups: [[PText]]?
        var uncertain = false

        init(line: Line, skip: Bool) {
            self.line = line
            self.skip = skip
        }
    }

    /// A line for the alignment (JS `{ line, text, block, weak }`).
    struct Item {
        let line: Line
        let text: PText
        let block: Int
        let weak: Bool
    }

    // MARK: Detection

    /// Content lines with a flag for lines that need not contain the delimiter: weak headings,
    /// wrapped continuation lines and section titles.
    static func contentWithOptional(_ lines: [Line]) -> [(line: Line, optional: Bool)] {
        var out: [(line: Line, optional: Bool)] = []
        var prev: Line?
        var afterGap = true
        for line in lines {
            if line.blank {
                prev = nil
                afterGap = true
                continue
            }
            if let kind = line.kind {
                if kind == .heading {
                    prev = nil
                    afterGap = true
                }
                continue
            }
            let t = line.display
            let continuation = line.indent >= 2 || (prev.map { looksUnfinished($0.display) } ?? false)
            let title = afterGap && (t.first.map { isLu($0) || isDigit($0) } ?? false) && !t.contains(",")
                && t.spaceSeparatedCount <= 6
            out.append((line, line.weak || continuation || title))
            prev = line
            afterGap = false
        }
        return out
    }

    static func detectDelimiter(_ ctx: Context, _ lines: [Line]) -> Candidate? {
        let content = contentWithOptional(lines)
        if content.isEmpty { return nil }
        func ratio(_ cand: Candidate, strict: Bool) -> Double {
            var n = 0
            var denom = 0
            for (line, optional) in content {
                let parts = splitWith(line, cand).parts
                let ok = strict ? parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty : pairingCount(parts, cand) > 0
                if ok {
                    n += 1
                    denom += 1
                } else if !optional {
                    denom += 1
                }
            }
            return n >= 1 && Double(n) >= 0.3 * Double(content.count) ? Double(n) / Double(max(1, denom)) : 0
        }
        var best: (cand: Candidate, ratio: Double)?
        for cand in candidates {
            let r = ratio(cand, strict: false)
            if r >= 0.7 && (best == nil || r > best!.ratio + 0.05) { best = (cand, r) }
        }
        if let best { return pageColumnsGap(ctx, content.map(\.line), best.cand) ? gapCandidate : best.cand }

        // Comma only as a last resort: exactly two fields on >= 80% of lines and the two sides
        // must look like different languages. Quizlet's export puts a bare comma between the
        // sides, so ", " inside a field is then kept.
        for cand in [comma, tightComma] {
            if ratio(cand, strict: true) < 0.8 { continue }
            var pairs: [[PText]] = []
            for (line, _) in content {
                let parts = splitWith(line, cand).parts
                if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty { pairs.append(parts) }
            }
            if sidesContrast(ctx, pairs) { return cand }
        }
        return nil
    }

    /// "le chat – die Katze      le chien – der Hund": the wide gap separates two page columns,
    /// and the winning delimiter splits each of them into a pair. The right page column may end
    /// early, so a few rows suffice when every wide row splits like that and the halves contrast.
    static func pageColumnsGap(_ ctx: Context, _ content: [Line], _ winner: Candidate) -> Bool {
        if !innerCandidates.contains(where: { $0 == winner }) { return false }
        var wide = 0
        var paired = 0
        var halves: [[PText]] = []
        for line in content {
            let cells = splitWith(line, gapCandidate).parts
            if cells.count < 2 { continue }
            wide += 1
            // An empty cell is a page column that ended early.
            let split = cells.filter { !$0.isEmpty }.map { splitText($0, winner).parts }
            if split.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty }) {
                paired += 1
                halves.append(contentsOf: split)
            }
        }
        if wide == 0 || Double(paired) < 0.8 * Double(wide) { return false }
        return (wide >= 2 && Double(wide) >= 0.7 * Double(content.count)) || (paired == wide && sidesContrast(ctx, halves))
    }

    static func sidesContrast(_ ctx: Context, _ pairs: [[PText]]) -> Bool {
        if pairs.isEmpty { return false }
        guard let l = ctx.detectColumn(pairs.map { $0[0] }).lang, let r = ctx.detectColumn(pairs.map { $0[1] }).lang,
              l != r
        else { return false }
        var agree = 0
        for p in pairs where ctx.pairProb(p[0], l, r) > 0.5 && ctx.pairProb(p[1], r, l) > 0.5 { agree += 1 }
        return Double(agree) / Double(pairs.count) >= 0.6
    }

    /// Whole lists on one line: "le chat - die Katze; le chien - der Hund".
    static func detectInline(_ ctx: Context, _ content: [Line]) -> Outcome? {
        for sep: PText in [";", ","] {
            let withSep = content.filter { $0.text.includes(sep) }.count
            if Double(withSep) / Double(content.count) < 0.6 { continue }
            var records: [Line] = []
            for line in content {
                for piece in csvSplit(line.text.tabsToSpaces(), sep) where !piece.isEmpty && piece.hasLetter {
                    records.append(makeLine(piece, line.no))
                }
            }
            // Each source line must hold several pairs, otherwise `sep` is part of the entries.
            if records.count < content.count * 2 { continue }
            for cand in candidates + (sep == ";" ? [comma] : []) {
                if cand.kind == .cells || cand.kind == .gap || cand.id == sep { continue }
                var pairs: [[PText]] = []
                for r in records {
                    let parts = splitWith(r, cand).parts
                    if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty { pairs.append(parts) }
                }
                if Double(pairs.count) / Double(records.count) < 0.7 { continue }
                if cand == comma && !sidesContrast(ctx, pairs) { continue }
                return parseDelimitedLines(ctx, records, cand)
            }
            // Records without a common delimiter ("le chat-die Katze;le chien-der Hund").
            if let bilingual = detectBilingual(ctx, records) { return bilingual }
        }
        return nil
    }

    // MARK: Columns inside rows

    /// Two page columns of "term – definition" entries side by side: every cell holds a whole
    /// pair. Sets `groups` (one [term, def] per cell) and returns true.
    static func splitInnerPairs(_ ctx: Context, _ entries: [Entry]) -> Bool {
        let rows = entries.filter { !$0.skip && $0.parts.filter { !$0.isEmpty }.count >= 2 }
        if rows.isEmpty { return false }
        for inner in innerCandidates {
            var pairs: [[PText]] = []
            var cells = 0
            for e in rows {
                for cell in e.parts where !cell.isEmpty {
                    cells += 1
                    let parts = splitText(cell, inner).parts
                    if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty { pairs.append(parts) }
                }
            }
            // The halves must contrast, unlike form tables ("aller - allé<TAB>gehen - gegangen").
            if Double(pairs.count) < 0.8 * Double(cells) || !sidesContrast(ctx, pairs) { continue }
            for e in entries {
                if e.skip || !e.parts.contains(where: { !$0.isEmpty }) { continue }
                // An empty cell is a page column that ended early; it keeps its group index.
                let groups = e.parts.map { $0.isEmpty ? [PText.empty, PText.empty] : splitText($0, inner).parts }
                let valid = groups.indices.allSatisfy { i in
                    e.parts[i].isEmpty || (groups[i].count == 2 && (!groups[i][0].isEmpty || !groups[i][1].isEmpty))
                }
                if valid {
                    e.groups = groups
                    e.count = groups.filter { !$0[0].isEmpty || !$0[1].isEmpty }.count
                }
            }
            return true
        }
        return false
    }

    private static let labelStop: Set<PText> = Set(
        "der die das den dem des ein eine einen the a an le la les l un une el los las il lo gli".split(separator: " ")
            .map { PText(String($0)) })

    /// `s.toLowerCase().match(/\p{L}+/gu) || []`
    private static func tokensOf(_ s: PText) -> [PText] {
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
            out.append(PText(lower[i..<e]))
            i = e
        }
        return out
    }

    /// Word class / gender columns repeat the same label ("Nomen, f.", "Verb") that never occurs
    /// in the translation column.
    static func isLabelColumn(_ col: [PText], _ other: [PText]) -> Bool {
        if col.count < 3 { return false }
        let seen = Set(other.flatMap(tokensOf))
        var counts: [PText: Int] = [:]
        for cell in col {
            for t in Set(tokensOf(cell)) { counts[t, default: 0] += 1 }
        }
        for (t, n) in counts where Double(n) >= Double(col.count) / 2 && !seen.contains(t) && !labelStop.contains(t) {
            return true
        }
        return false
    }

    /// `t.split(/\s+/).length`
    private static func wsSplitCount(_ t: PText) -> Int {
        var runs = 0
        var inRun = false
        for c in t.u {
            if isWS(c) {
                if !inRun { runs += 1 }
                inRun = true
            } else {
                inRun = false
            }
        }
        return runs + 1
    }

    private static func isSentence(_ t: PText) -> Bool {
        guard let c = t.last, c == "." || c == "!" || c == "?" else { return false }
        return wsSplitCount(t) >= 3
    }

    /// Rows with three cells: term | translation | example or note, Klett-style term | example |
    /// translation, or masculine | feminine | translation. Drops the column that is not part of
    /// the pair; rows that keep three cells are merged by language later, and marked uncertain
    /// when the columns are unclear.
    static func reduceThreeCells(_ ctx: Context, _ entries: [Entry], _ cand: Candidate) {
        let live = entries.filter { !$0.skip && $0.parts.count >= 2 }
        let rows = live.filter { $0.parts.count == 3 && $0.parts.allSatisfy { !$0.isEmpty } }
        if rows.count < 2 || Double(rows.count) < 0.6 * Double(live.count) { return }
        let cols = (0..<3).map { c in rows.map { $0.parts[c] } }
        let langs = cols.map { ctx.detectColumn($0).lang }
        let (l0, l1, l2) = (langs[0], langs[1], langs[2])
        // An example-sentence column is clearly wordier than the other two, or the only one
        // holding whole sentences ("Die Katze schläft.").
        let avg = cols.map { col in Double(col.reduce(0) { $0 + wsSplitCount($1) }) / Double(col.count) }
        let wordy = (0..<3).filter { i in avg[i] >= 4 && avg.indices.allSatisfy { j in j == i || avg[i] >= 2 * avg[j] } }
        let share = cols.map { col in Double(col.filter(isSentence).count) / Double(col.count) }
        let sentences = (0..<3).filter { i in share[i] >= 0.8 && share.indices.allSatisfy { j in j == i || share[j] <= 0.2 } }
        var drop = wordy.count == 1 ? wordy[0] : sentences.count == 1 ? sentences[0] : -1
        var uncertain = false
        if drop < 0 {
            if l0 != nil && l1 != nil && l0 != l1 && (l2 != l1 || isLabelColumn(cols[2], cols[1])) {
                drop = 2
            } else if l1 != nil && l2 != nil && l1 != l2 && l0 != l1 && l0 != l2 {
                drop = 0
            }
        }
        // Never drop the only column in the translation language: a misdetected middle column
        // (feminine forms) or a third language (English | French | German) is merged by language.
        let target = ctx.o.target
        if drop >= 0 && langs[drop] == target && !langs.indices.contains(where: { $0 != drop && langs[$0] == target }) {
            drop = -1
        }
        // Unclear outer columns, or three languages that cannot share two sides.
        if drop < 0 {
            uncertain = !(l0 != nil && l2 != nil && l0 != l2) || (l1 != nil && l1 != l0 && l1 != l2)
        }
        for e in rows {
            if drop >= 0 {
                e.parts.remove(at: drop)
                e.count = pairingCount(e.parts, cand)
            } else {
                e.uncertain = uncertain
            }
        }
    }

    // MARK: Parsing

    static func parseDelimitedLines(_ ctx: Context, _ lines: [Line], _ cand: Candidate) -> Outcome {
        let cellKind = cand.kind == .cells || cand.kind == .gap
        // Pass 1: split every line.
        let entries = lines.map { line -> Entry in
            if line.blank || line.kind != nil { return Entry(line: line, skip: true) }
            let e = Entry(line: line, skip: false)
            let split = splitWith(line, cand)
            e.parts = split.parts
            e.joiner = split.joiner
            e.count = pairingCount(split.parts, cand)
            return e
        }
        let pageColumns = cellKind && splitInnerPairs(ctx, entries)
        if cellKind && !pageColumns { reduceThreeCells(ctx, entries, cand) }

        // Column languages from clean two-part lines (else from the outer parts of longer lines).
        var two = entries.filter { !$0.skip && $0.parts.count == 2 && !$0.parts[0].isEmpty && !$0.parts[1].isEmpty }
            .map(\.parts)
        if two.isEmpty {
            two = entries.filter { !$0.skip && $0.parts.count > 2 && !$0.parts[0].isEmpty && !$0.parts[$0.parts.count - 1].isEmpty }
                .map { [$0.parts[0], $0.parts[$0.parts.count - 1]] }
        }
        var a = ctx.detectColumn(two.map { $0[0] }).lang
        var b = ctx.detectColumn(two.map { $0[1] }).lang
        if a == nil || a == b { a = nil }
        if b == nil || a == nil { b = nil }

        // Pass 2: build pairs; lines without the delimiter are collected in runs.
        var pairs: [Pair] = []
        // Two page columns are read left column first, even when the right one ends early.
        let multi = entries.filter { !$0.skip && $0.count >= 2 }.count
        let single = entries.filter { $0.count >= 1 }.count
        let columnMajor = (pageColumns && multi >= 1)
            || (cellKind && multi >= 2 && Double(multi) / Double(max(1, single)) >= 0.6)
        var run: [Line] = []
        var prevPair: Pair? // pair directly above (no blank line or heading in between)
        func flushRun(_ nextPair: Pair?) {
            if !run.isEmpty { handleRun(ctx, run, prevPair, nextPair, a, b, &pairs) }
            run = []
        }
        for e in entries {
            if e.skip {
                if e.line.blank || e.line.kind == .heading {
                    flushRun(nil)
                    prevPair = nil
                }
                continue
            }
            if e.groups == nil && (e.parts.count < 2 || (e.line.weak && e.count == 0)) {
                run.append(e.line)
                continue
            }
            var groups: [[PText]] = []
            var uncertain = e.uncertain
            if let g = e.groups {
                groups = g
            } else if cellKind && e.count >= 2 {
                var g = 0
                while g < e.parts.count {
                    groups.append([e.parts[g], g + 1 < e.parts.count ? e.parts[g + 1] : .empty])
                    g += 2
                }
            } else {
                let split = resolveSplit(ctx, e.parts, a, b, e.joiner)
                groups.append(split.parts)
                uncertain = uncertain || split.uncertain
            }
            var first: Pair?
            for (g, group) in groups.enumerated() {
                let (term, def) = (group[0], group[1])
                if term.isEmpty && def.isEmpty { continue }
                let pair = makePair(term, def, e.line.span, uncertain: uncertain, group: g)
                pairs.append(pair)
                if first == nil { first = pair }
            }
            flushRun(first)
            if first != nil { prevPair = pairs[pairs.count - 1] }
        }
        flushRun(nil)

        if columnMajor {
            for (i, p) in pairs.enumerated() { p.order = i }
            pairs.sort { x, y in
                let gx = x.group ?? 0
                let gy = y.group ?? 0
                return gx != gy ? gx < gy : x.order < y.order
            }
        }
        return Outcome(pairs: pairs, format: .delimited, delimiter: cand.kind == .gap ? "  " : cand.id.string)
    }

    /// Lines inside a delimited list that do not contain the delimiter.
    static func handleRun(
        _ ctx: Context, _ run: [Line], _ prevPair: Pair?, _ nextPair: Pair?, _ a: Int?, _ b: Int?, _ pairs: inout [Pair]
    ) {
        var i = 0
        var j = run.count
        func bilingual(_ line: Line) -> Bool {
            languageSplit(ctx, line.display, a, b)?.order == 1
        }
        // Wrapped definition of the pair above.
        if let prevPair {
            while i < j && !prevPair.def.isEmpty && !bilingual(run[i]) && isContinuation(ctx, run[i], prevPair.def, b, a) {
                prevPair.def = joinParts(prevPair.def, run[i].display)
                prevPair.lines = Array(Set(prevPair.lines + run[i].span)).sorted()
                prevPair.merged = true
                ctx.warnings.line(.merged, run[i].no)
                i += 1
            }
        }
        // Wrapped term that continues on the next delimited line.
        if j > i, let nextPair, !nextPair.term.isEmpty, !bilingual(run[j - 1]), isTermPrefix(ctx, run[j - 1].display, a, b) {
            nextPair.term = joinParts(run[j - 1].display, nextPair.term)
            nextPair.lines = Array(Set(nextPair.lines + run[j - 1].span)).sorted()
            nextPair.merged = true
            ctx.warnings.line(.merged, run[j - 1].no)
            j -= 1
        }
        if i >= j { return }
        let items = run[i..<j].map { Item(line: $0, text: $0.display, block: 0, weak: $0.weak) }
        let steps = alignBest(ctx, items, a, b, boundary: .none, allowSplit: true, unpairedCost: runUnpairedCost)
        var created: [Pair] = []
        for st in steps {
            if case let .skip(index, heading) = st {
                unpairedLine(ctx, items[index], inDelimitedList: true, a, b, isHeading: heading)
            } else if let pair = stepToPair(ctx, items, st) {
                created.append(pair)
            }
        }
        if let nextPair, let at = pairs.firstIndex(where: { $0 === nextPair }) {
            pairs.insert(contentsOf: created, at: at)
        } else {
            pairs.append(contentsOf: created)
        }
    }

    static func isContinuation(_ ctx: Context, _ line: Line, _ prevDef: PText, _ defLang: Int?, _ termLang: Int?) -> Bool {
        let text = line.display
        if !text.hasLetter || line.weak { return false }
        let known = defLang != nil && termLang != nil
        let p = ctx.pairProb(text, defLang, termLang)
        if known && p < 0.6 { return false }
        // Indented into the definition column (PDF / fixed-width layouts).
        if line.indent >= 2 { return true }
        if looksUnfinished(prevDef) { return true }
        if let c = text.first, ",;/)(".unicodeScalars.contains(c) { return true }
        return known && startsLower(text) && !startsEntry(text) && p >= 0.85
    }

    static func isTermPrefix(_ ctx: Context, _ text: PText, _ termLang: Int?, _ defLang: Int?) -> Bool {
        if termLang == nil || defLang == nil || !startsLower(text) { return false }
        if ctx.pairProb(text, termLang, defLang) < 0.6 { return false }
        return looksUnfinished(text)
    }

    static func unpairedLine(_ ctx: Context, _ item: Item, inDelimitedList: Bool, _ a: Int?, _ b: Int?, isHeading: Bool = false) {
        let t = item.text
        let words = t.spaceSeparatedCount
        var heading = isHeading || item.weak || keywordEnd(t) != nil || t.last == ":"
        if !heading, let c = t.first, isLu(c) || isDigit(c) {
            heading = inDelimitedList || (words >= 2 && !t.contains(","))
        }
        if !heading && inDelimitedList && a != nil && b != nil {
            let p = ctx.pairProb(t, a, b)
            heading = p > 0.25 && p < 0.75 // belongs to neither column: treat as a title
        }
        ctx.skipped.append(SkippedLine(line: item.line.no, text: t.string, reason: heading ? .heading : .unpaired))
        if !heading { ctx.warnings.line(.unpaired, item.line.no) }
    }

    // MARK: Explicit delimiter mode

    static func normalizeDelimiter(_ d: String) -> PText {
        var out: [Unicode.Scalar] = []
        for c in d.unicodeScalars {
            switch c.value {
            case 0x2013, 0x2014, 0x2012, 0x2010, 0x2011, 0x2212: out.append("-")
            case 0xA0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: out.append(" ")
            case 0x2019, 0x2018, 0x60, 0xB4, 0x2BC, 0x2032: out.append("'")
            default: out.append(c)
            }
        }
        return out.isEmpty ? "\t" : PText(out)
    }

    /// Records of the source separated by `sep`, with the 1-based line of their first non-blank
    /// character.
    static func recordsFrom(_ source: PText, _ sep: PText) -> [(chunk: PText, no: Int)] {
        var raw = source.u
        if raw.first == "\u{FEFF}" { raw.removeFirst() }
        // .replace(/\r\n?/g, '\n')
        var t: [Unicode.Scalar] = []
        t.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            if raw[i] == "\r" {
                t.append("\n")
                if i + 1 < raw.count && raw[i + 1] == "\n" { i += 1 }
            } else {
                t.append(raw[i])
            }
            i += 1
        }
        let text = PText(t)
        // newlines[k] = number of "\n" in t[0..<k]
        var newlines = [Int](repeating: 0, count: t.count + 1)
        for k in 0..<t.count { newlines[k + 1] = newlines[k] + (t[k] == "\n" ? 1 : 0) }
        var records: [(chunk: PText, no: Int)] = []
        var start = 0
        func push(_ end: Int) {
            let chunk = text.slice(start, end)
            var lead = 0
            while lead < chunk.count && isWS(chunk[lead]) { lead += 1 }
            records.append((chunk, newlines[start + lead] + 1))
        }
        if !sep.isEmpty && sep.u.allSatisfy({ $0 == "\n" }) {
            // Blank-line separated records: any run of blank lines separates (/\n[ \t]*\n\s*/g).
            var p = 0
            while p < t.count {
                guard t[p] == "\n" else {
                    p += 1
                    continue
                }
                var q = p + 1
                while q < t.count && (t[q] == " " || t[q] == "\t") { q += 1 }
                guard q < t.count && t[q] == "\n" else {
                    p += 1
                    continue
                }
                q += 1
                while q < t.count && isWS(t[q]) { q += 1 }
                push(p)
                start = q
                p = q
            }
        } else {
            var from = 0
            while let idx = text.indexOf(sep, from: from) {
                push(idx)
                start = idx + sep.count
                from = start
            }
        }
        push(t.count)
        return records
    }

    static func parseWithDelimiter(_ ctx: Context, _ source: PText) -> Outcome {
        let o = ctx.o
        let delim = normalizeDelimiter(o.delimiter ?? "\t")
        let sep = o.cardSeparator
        if delim.contains("\n") {
            // Term and definition on separate lines inside each record.
            var pairs: [Pair] = []
            let trimmedDelim = delim.trimmed()
            let inner: PText = trimmedDelim.isEmpty ? "\n" : trimmedDelim
            for (chunk, no) in recordsFrom(source, sep == "\n" ? "\n\n" : sep) {
                let trimmed = chunk.trimmed()
                if trimmed.isEmpty { continue }
                let idx = trimmed.indexOf(inner)
                let term = TextNormalizer.normalizeBasic(idx.map { trimmed.slice(0, $0) }?.string ?? trimmed.string)
                let def = idx.map { TextNormalizer.normalizeBasic(trimmed.slice($0 + inner.count).string) } ?? ""
                let lastLine = no + trimmed.u.filter { $0 == "\n" }.count
                if !term.isEmpty || !def.isEmpty {
                    pairs.append(makePair(PText(term), PText(def), Array(no...lastLine)))
                }
            }
            return Outcome(pairs: pairs, format: .delimited, delimiter: delim.string)
        }
        // The user picked the delimiter: glued en/em dashes are spaced only for a dash.
        let dashList = delim.trimmed() == "-"
        let lines: [Line]
        if sep == "\n" || sep == "\r\n" || sep == "\r" {
            lines = classify(ctx, preprocess(source, dashList: dashList))
        } else {
            let records = recordsFrom(source, sep).map { chunk, no -> Line in
                let joined = PText(chunk.u.map { $0 == "\n" ? " " : $0 })
                let line = makeLine(spaceGluedDashes([joined], dashList: dashList)[0], no)
                let extra = chunk.trimmed().u.filter { $0 == "\n" }.count
                line.span = Array(no...(no + extra))
                return line
            }
            lines = classify(ctx, records)
        }
        var result = parseDelimitedLines(ctx, lines, customCandidate(delim))
        result.delimiter = delim.string
        return result
    }
}
