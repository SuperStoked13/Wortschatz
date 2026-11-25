import Foundation

// Line-based lists of parser.js: alignment by dynamic programming, two-column OCR order and lists
// with both languages on every line.

extension VocabParser {
    /// How strongly a blank line separates entries (JS `BOUNDARY`).
    enum Boundary {
        case none, weak, medium, strong

        /// [extra cost of merging lines across a blank line, of a term->definition junction across one]
        var costs: (merge: Double, junction: Double) {
            switch self {
            case .none: (0, 0)
            case .weak: (1, 0)
            case .medium: (2.5, 1.5)
            case .strong: (5, 5)
            }
        }
    }

    /// A line split into its two halves.
    struct SplitChoice {
        var left: PText
        var right: PText
        var cost: Double
        /// Split by language (no explicit delimiter).
        var lang: Bool
        var delimId: PText
    }

    /// One step of an alignment.
    enum Step {
        /// A card from term lines and definition lines (indices into the items).
        case card(term: [Int], def: [Int])
        /// One line holding both sides.
        case split(index: Int, split: SplitChoice)
        /// A line without partner.
        case skip(index: Int, heading: Bool)
    }

    /// A line split at an explicit delimiter. `pl`/`pr` = P(left/right half is language A).
    struct DelimiterSplit {
        var left: PText
        var right: PText
        var pl: Double
        var pr: Double
        var delimId: PText
    }

    // MARK: Bilingual lines

    /// A line split at the first explicit delimiter whose halves contrast (any delimiter when the
    /// languages are unknown).
    static func delimiterSplit(_ ctx: Context, _ line: Line, _ a: Int?, _ b: Int?) -> DelimiterSplit? {
        let known = a != nil && b != nil && a != b
        for cand in candidates where cand.kind != .gap {
            let split = splitWith(line, cand)
            if split.parts.count < 2 || split.parts.contains(where: \.isEmpty) { continue }
            let parts = resolveSplit(ctx, split.parts, a, b, split.joiner).parts
            let (left, right) = (parts[0], parts[1])
            if left.isEmpty || right.isEmpty { continue }
            if !known { return DelimiterSplit(left: left, right: right, pl: 0.5, pr: 0.5, delimId: cand.id) }
            let pl = ctx.pairProb(left, a, b)
            let pr = ctx.pairProb(right, a, b)
            if (pl - 0.5) * (pr - 0.5) < 0 && abs(pl - pr) >= 0.3 {
                return DelimiterSplit(left: left, right: right, pl: pl, pr: pr, delimId: cand.id)
            }
        }
        return nil
    }

    /// A line that holds both languages: delimiter split with language contrast, or a pure
    /// language split.
    private static func bilingualParts(
        _ ctx: Context, _ item: Item, _ a: Int?, _ b: Int?, _ known: Bool
    ) -> (left: PText, right: PText, pl: Double, pr: Double, delim: Bool, delimId: PText?)? {
        if let split = delimiterSplit(ctx, item.line, known ? a : nil, known ? b : nil) {
            return (split.left, split.right, split.pl, split.pr, true, split.delimId)
        }
        if !known || item.line.text.contains("\t") { return nil }
        guard let ls = languageSplit(ctx, item.text, a, b) else { return nil }
        return (ls.left, ls.right, ctx.pairProb(ls.left, a, b), ctx.pairProb(ls.right, a, b), false, nil)
    }

    // MARK: Alignment

    private enum Choice {
        case skip, split
        case card(Int, Int)
    }

    /// The parts of an alignment that do not depend on the language order (computed once for
    /// both orders).
    private struct AlignBase {
        /// `mergeCost(items[i - 1].text, items[i].text)` (index 0 unused).
        let merge: [Double]
        /// Line i starts lowercase and does not continue a sentence (heading test of line i - 1).
        let opensEntry: [Bool]
        let words: [Int]
        /// Cognate pairs ("intelligent" = "intelligent") carry no language signal: as a 1:1 card
        /// each side costs at most an even guess.
        let cognate: [Bool]

        init(_ items: [Item]) {
            let n = items.count
            var merge = [Double](repeating: 0, count: n)
            var opensEntry = [Bool](repeating: false, count: n)
            for i in 1..<max(n, 1) {
                merge[i] = mergeCost(items[i - 1].text, items[i].text)
                opensEntry[i] = startsLower(items[i].text) && !continuesSentence(items[i].text)
            }
            self.merge = merge
            self.opensEntry = opensEntry
            words = items.map { wordCount($0.text) }
            cognate = (0..<n).map { i in
                i + 1 < n && !items[i].weak && !items[i + 1].weak && isCognate(items[i].text, items[i + 1].text)
            }
        }
    }

    private static func align(
        _ ctx: Context, _ items: [Item], _ a: Int?, _ b: Int?, boundary: Boundary, allowSplit: Bool, unpairedCost: Double,
        base: AlignBase
    ) -> (cost: Double, steps: [Step]) {
        let n = items.count
        let (xm, xj) = boundary.costs
        let known = a != nil && b != nil && a != b
        var cT = [Double](repeating: 0, count: n)
        var cD = [Double](repeating: 0, count: n)
        var splits = [SplitChoice?](repeating: nil, count: n)
        for i in 0..<n {
            if allowSplit, let bil = bilingualParts(ctx, items[i], a, b, known) {
                // A line holding both languages is costed as its two halves.
                let extra = known ? 0.0 : 1.0
                cT[i] = nlog(bil.pl) + nlog(bil.pr) + extra
                cD[i] = nlog(1 - bil.pl) + nlog(1 - bil.pr) + extra
                if !known || (bil.pl >= 0.5 && bil.pr <= 0.5) {
                    let cost = nlog(bil.pl) + nlog(1 - bil.pr) + (bil.delim ? delimSplitCost : langSplitCost)
                    splits[i] = SplitChoice(left: bil.left, right: bil.right, cost: cost, lang: !bil.delim, delimId: bil.delimId ?? " ")
                }
            } else {
                let p = known ? ctx.pairProb(items[i].text, a, b) : 0.5
                cT[i] = nlog(p)
                cD[i] = nlog(1 - p)
            }
        }
        // mc[i]: cost of continuing line i-1 with line i on the same side. heading[i]: line i may
        // be a section heading in front of the term that starts on line i+1 ("Les couleurs" before
        // "rouge"). Skipping it is cheaper, and merging it into that term costs extra unless the
        // merged term matches the definition's length better (a wrapped sentence). German terms
        // are exempt because German nouns are capitalised, and so are the lines of one block in a
        // blocks list.
        var mc = [Double](repeating: 0, count: n)
        let headings = known && a != de
        var heading = [Bool](repeating: false, count: n)
        if n > 1 {
            for i in 1..<n {
                let sameBlock = items[i].block == items[i - 1].block
                let inBlock = sameBlock && boundary == .strong
                mc[i] = base.merge[i]
                if inBlock { mc[i] = min(mc[i], 1) }
                if !sameBlock { mc[i] += xm }
                heading[i - 1] = headings && !inBlock && base.opensEntry[i] && looksLikeHeading(items[i - 1].text, a)
            }
        }
        let words = base.words
        let cognate = base.cognate
        let ln2 = 0.6931471805599453 // Math.LN2
        var best = [Double](repeating: 0, count: n + 1)
        var choice = [Choice](repeating: .skip, count: n + 1)
        var i = n - 1
        while i >= 0 {
            let skipCost = items[i].weak ? weakHeadingCost : heading[i] ? min(headingSkipCost, unpairedCost) : unpairedCost
            var bc = skipCost + best[i + 1]
            var ch = Choice.skip
            if let sp = splits[i], sp.cost + best[i + 1] < bc {
                bc = sp.cost + best[i + 1]
                ch = .split
            }
            var termCost = 0.0
            var termWords = 0
            var ta = 1
            while ta <= 3 && i + ta < n {
                let ti = i + ta - 1
                termCost += cT[ti] + (ta > 1 ? mc[ti] : 0)
                termWords += words[ti]
                let junction = items[i + ta].block != items[i + ta - 1].block ? xj : 0
                var defCost = 0.0
                var defWords = 0
                var db = 1
                while db <= 3 && i + ta + db <= n {
                    let di = i + ta + db - 1
                    defCost += cD[di] + (db > 1 ? mc[di] : 0)
                    defWords += words[di]
                    var total = termCost + junction + defCost + best[i + ta + db]
                    if ta > 1 && heading[i] && restMatchesLength(termWords, termWords - words[i], defWords) {
                        total += headingMergeCost
                    }
                    if ta == 1 && db == 1 && cognate[i] {
                        total = min(total, min(cT[i], ln2) + junction + min(cD[i + 1], ln2) + best[i + 2])
                    }
                    if total < bc - 1e-9 {
                        bc = total
                        ch = .card(ta, db)
                    }
                    db += 1
                }
                ta += 1
            }
            best[i] = bc
            choice[i] = ch
            i -= 1
        }
        var steps: [Step] = []
        var k = 0
        while k < n {
            switch choice[k] {
            case let .card(ta, db):
                steps.append(.card(term: Array(k..<(k + ta)), def: Array((k + ta)..<(k + ta + db))))
                k += ta + db
            case .split:
                steps.append(.split(index: k, split: splits[k]!))
                k += 1
            case .skip:
                steps.append(.skip(index: k, heading: heading[k]))
                k += 1
            }
        }
        return (best[0], steps)
    }

    /// Try both language orders (which language comes first in the source).
    static func alignBest(
        _ ctx: Context, _ items: [Item], _ a: Int?, _ b: Int?, boundary: Boundary, allowSplit: Bool, unpairedCost: Double
    ) -> [Step] {
        if items.isEmpty { return [] }
        let base = AlignBase(items)
        let first = align(ctx, items, a, b, boundary: boundary, allowSplit: allowSplit, unpairedCost: unpairedCost, base: base)
        guard let a, let b, a != b else { return first.steps }
        let second = align(ctx, items, b, a, boundary: boundary, allowSplit: allowSplit, unpairedCost: unpairedCost, base: base)
        return (second.cost < first.cost - 1e-9 ? second : first).steps
    }

    /// The pair of a card or split step (nil for a skipped line).
    static func stepToPair(_ ctx: Context, _ items: [Item], _ st: Step) -> Pair? {
        switch st {
        case let .split(index, split):
            return makePair(split.left, split.right, items[index].line.span, langSplit: split.lang)
        case let .card(termIdx, defIdx):
            let term = termIdx.map { items[$0].text }.reduce(PText.empty, joinParts)
            let def = defIdx.map { items[$0].text }.reduce(PText.empty, joinParts)
            let lines = (termIdx + defIdx).flatMap { items[$0].line.span }
            let mergedLines = (termIdx.dropFirst() + defIdx.dropFirst()).map { items[$0].line.no }
            for no in mergedLines { ctx.warnings.line(.merged, no) }
            return makePair(term, def, lines, merged: !mergedLines.isEmpty)
        case .skip:
            return nil
        }
    }

    // MARK: Two-column OCR order

    private final class Run {
        var label: Int
        var idx: [Int]
        init(label: Int, idx: [Int]) {
            self.label = label
            self.idx = idx
        }
    }

    /// Two-column OCR order: all term lines first, then all definition lines (possibly repeated
    /// per page). Returns pairs or nil.
    static func detectColumns(_ ctx: Context, _ items: [Item], _ l1: Int?, _ l2: Int?) -> [Pair]? {
        guard let l1, let l2, items.count >= 4 else { return nil }
        let labels = items.map { it -> Int in
            let p = ctx.pairProb(it.text, l1, l2)
            return p > 0.65 ? 1 : p < 0.35 ? 2 : 0
        }
        // Alternating lists change language on almost every line; columns rarely do.
        let labelled = labels.filter { $0 != 0 }
        var changes = 0
        if labelled.count > 1 {
            for k in 1..<labelled.count where labelled[k] != labelled[k - 1] { changes += 1 }
        }
        if labelled.count < 4 || Double(changes) / Double(labelled.count - 1) >= 0.35 { return nil }

        // One page: the first half is one language, the second half the other. A few cognates or
        // weakly scored lines ("charmant") must not hide that.
        if items.count % 2 == 0 {
            let h = items.count / 2
            let top = labels[..<h].filter { $0 != 0 }
            let bottom = labels[h...].filter { $0 != 0 }
            func share(_ list: [Int], _ lab: Int) -> Double { Double(list.filter { $0 == lab }.count) / Double(list.count) }
            for (x, y) in [(1, 2), (2, 1)]
            where top.count >= 2 && bottom.count >= 2 && share(top, x) >= 0.8 && share(bottom, y) >= 0.8 {
                return (0..<h).map { k in
                    let (p, q) = (items[k], items[k + h])
                    return makePair(p.text, q.text, p.line.span + q.line.span)
                }
            }
        }

        var runs: [Run] = []
        for (i, lab) in labels.enumerated() {
            if let last = runs.last, lab == 0 || last.label == lab || last.label == 0 {
                if last.label == 0 { last.label = lab }
                last.idx.append(i)
            } else {
                runs.append(Run(label: lab, idx: [i]))
            }
        }
        // Absorb a single misdetected line inside a long run, or at either end.
        var changed = true
        while changed {
            changed = false
            if runs.count > 2 {
                for r in 1..<(runs.count - 1) {
                    let (a, m, b) = (runs[r - 1], runs[r], runs[r + 1])
                    if m.idx.count == 1 && a.label == b.label && a.idx.count >= 2 && b.idx.count >= 2 {
                        a.idx.append(contentsOf: m.idx + b.idx)
                        runs.removeSubrange(r...(r + 1))
                        changed = true
                        break
                    }
                }
            }
            if changed || runs.count < 3 { continue }
            if runs[0].idx.count == 1 && runs[1].idx.count >= 3 {
                runs[1].idx.insert(contentsOf: runs[0].idx, at: 0)
                runs.removeFirst()
                changed = true
            } else if runs[runs.count - 1].idx.count == 1 && runs[runs.count - 2].idx.count >= 3 {
                runs[runs.count - 2].idx.append(contentsOf: runs[runs.count - 1].idx)
                runs.removeLast()
                changed = true
            }
        }
        if runs.count < 2 || runs.count % 2 != 0 || Double(items.count) / Double(runs.count) < 3 { return nil }
        for r in 0..<runs.count where runs[r].label == 0 || (r > 0 && runs[r].label == runs[r - 1].label) { return nil }

        // Validate every column pair before emitting anything.
        var columns: [(left: [Int], right: [Int], m: Int)] = []
        var r = 0
        while r < runs.count {
            var left = runs[r].idx
            var right = runs[r + 1].idx
            if runs.count == 2 && items.count % 2 == 0 && abs(left.count - right.count) <= 2 {
                left = Array(0..<(items.count / 2))
                right = Array((items.count / 2)..<items.count)
            }
            let m = min(left.count, right.count)
            if Double(abs(left.count - right.count)) > max(1, JSCompat.round(Double(m) * 0.25)) { return nil }
            columns.append((left, right, m))
            r += 2
        }
        var pairs: [Pair] = []
        for (left, right, m) in columns {
            if left.count != right.count {
                ctx.warnings.add(
                    L("Die beiden Spalten sind unterschiedlich lang (%@ und %@ Zeilen).", "\(left.count)", "\(right.count)"))
            }
            for k in 0..<m {
                let (p, q) = (items[left[k]], items[right[k]])
                pairs.append(makePair(p.text, q.text, p.line.span + q.line.span))
            }
            for i in left.dropFirst(m) + right.dropFirst(m) {
                unpairedLine(ctx, items[i], inDelimitedList: false, l1, l2)
            }
        }
        return pairs
    }

    // MARK: Line-based lists

    static func parseLineBased(_ ctx: Context, _ lines: [Line], allowSplit: Bool) -> Outcome {
        var items: [Item] = []
        var block = 0
        var open = false
        for line in lines {
            if line.blank {
                if open { block += 1 }
                open = false
                continue
            }
            if line.kind != nil { continue }
            items.append(Item(line: line, text: line.display, block: block, weak: line.weak))
            open = true
        }
        // Blocks are numbered consecutively, so the block sizes can be counted by index.
        var sizes: [Int] = []
        for it in items {
            while sizes.count <= it.block { sizes.append(0) }
            sizes[it.block] += 1
        }
        let counts = sizes.filter { $0 > 0 }
        let nb = Double(counts.count)
        let share1 = Double(counts.filter { $0 == 1 }.count) / nb
        let share2 = Double(counts.filter { $0 == 2 }.count) / nb
        var boundary = Boundary.medium
        if counts.count <= 1 {
            boundary = .none
        } else if share1 >= 0.6 {
            boundary = .weak
        } else if share2 >= 0.5 {
            boundary = .strong
        }

        let (l1, l2) = ctx.topTwoLanguages(items.map(\.text))
        if boundary != .strong, let pairs = detectColumns(ctx, items, l1, l2) {
            return Outcome(pairs: pairs, format: .columns, delimiter: nil)
        }
        let steps = alignBest(ctx, items, l1, l2, boundary: boundary, allowSplit: allowSplit, unpairedCost: unpairedCost)
        var pairs: [Pair] = []
        var used: [PText] = []
        for st in steps {
            switch st {
            case let .skip(index, heading):
                unpairedLine(ctx, items[index], inDelimitedList: false, l1, l2, isHeading: heading)
            case let .split(_, split):
                if let pair = stepToPair(ctx, items, st) { pairs.append(pair) }
                used.append(split.delimId)
            case .card:
                if let pair = stepToPair(ctx, items, st) { pairs.append(pair) }
            }
        }
        // Mostly one-line pairs with mixed delimiters ("le lit - das Bett", "le mur = die Wand").
        if !pairs.isEmpty && Double(used.count) >= 0.6 * Double(pairs.count) {
            return Outcome(pairs: pairs, format: .delimited, delimiter: mostFrequent(used)?.string)
        }
        return Outcome(pairs: pairs, format: boundary == .strong ? .blocks : .alternating, delimiter: nil)
    }

    /// The most frequent element; ties go to the one seen first.
    static func mostFrequent<T: Hashable>(_ list: [T]) -> T? {
        var counts: [T: Int] = [:]
        var order: [T] = []
        for x in list {
            if counts[x] == nil { order.append(x) }
            counts[x, default: 0] += 1
        }
        var best: T?
        for x in order where best == nil || counts[x]! > counts[best!]! { best = x }
        return best
    }

    // MARK: Both languages on every line

    /// Bilingual lines without one common delimiter: no delimiter at all ("le chat die Katze",
    /// collapsed PDF columns) or a mix of several (tabs and " - ").
    static func detectBilingual(_ ctx: Context, _ content: [Line]) -> Outcome? {
        var (l1, l2) = ctx.topTwoLanguages(content.map(\.display))
        // Each line of a short list votes for one language ("le chat die Katze" is German
        // overall); its words show both.
        let byWords = { ctx.topTwoLanguages(content.prefix(200).flatMap { $0.display.split(" ") }) }
        let lineVote = l2 != nil
        if l1 != nil && l2 == nil { (l1, l2) = byWords() }
        guard let first = l1, let second = l2 else { return nil }
        func split(_ text: PText, _ a: Int, _ b: Int) -> LanguageSplit? {
            languageSplit(ctx, text, a, b) ?? twoWordSplit(ctx, text, a, b)
        }
        /// The two languages in line order when most lines split into them, else nil.
        func ordered(_ first: Int, _ second: Int) -> (a: Int, b: Int)? {
            var ok = 0
            var order = 0
            for line in content {
                if let d = delimiterSplit(ctx, line, first, second) {
                    ok += 1
                    order += d.pl > d.pr ? 1 : -1
                } else if let s = split(line.display, first, second) {
                    ok += 1
                    order += s.order
                }
            }
            if Double(ok) / Double(content.count) < 0.7 || Double(abs(order)) / Double(ok) < 0.6 { return nil }
            return order > 0 ? (first, second) : (second, first)
        }
        var pair = ordered(first, second)
        // A heading or a wrong language hint can make a third language the runner-up of the line
        // votes ("Les couleurs:" above an English/German list); the words still show both
        // languages.
        if pair == nil && lineVote, case let (w1?, w2?) = byWords(), Set([w1, w2]) != Set([first, second]) {
            pair = ordered(w1, w2)
        }
        guard let (a, b) = pair else { return nil }
        var slots: [PendingSlot] = []
        var used: [PText] = []
        var shapes: [(Int, Int)] = []
        var pending: [(line: Line, at: Int)] = []
        for line in content {
            // An explicit delimiter in the line wins over the language boundary (a reversed line
            // is turned around in finish()).
            if let d = delimiterSplit(ctx, line, a, b) {
                slots.append(.pair(makePair(d.left, d.right, line.span)))
                used.append(d.delimId)
                continue
            }
            if let s = split(line.display, a, b), s.order == 1 {
                slots.append(.pair(makePair(s.left, s.right, line.span, langSplit: true)))
                shapes.append((segments(s.left).count, segments(s.right).count))
                used.append(" ")
            } else {
                // Placeholder keeps the source order until the run is resolved.
                slots.append(.empty)
                pending.append((line, slots.count - 1))
            }
        }
        resolvePending(ctx, &slots, pending, shapes, a, b)
        let explicit = used.filter { $0 != " " }
        let delimiter: String? = Double(explicit.count) >= 0.5 * Double(used.count) ? mostFrequent(explicit)?.string : " "
        let pairs = slots.flatMap { slot -> [Pair] in
            switch slot {
            case let .pair(p): [p]
            case let .many(list): list
            case .empty: []
            }
        }
        return Outcome(pairs: pairs, format: .delimited, delimiter: delimiter)
    }

    /// A position in the source order of a "both languages per line" list.
    enum PendingSlot {
        case pair(Pair)
        case many([Pair])
        case empty
    }

    /// Lines of a "both languages per line" list that no language split was sure about. When
    /// they have the same word count as most split lines ("essayer versuchen" among "attendre
    /// warten"), they are cut at the usual boundary; a cut against the language evidence is
    /// marked uncertain. Other lines go through the run alignment like in delimited lists.
    static func resolvePending(
        _ ctx: Context, _ slots: inout [PendingSlot], _ pending: [(line: Line, at: Int)], _ shapes: [(Int, Int)],
        _ a: Int, _ b: Int
    ) {
        var run: [(line: Line, at: Int)] = []
        func flush() {
            if run.isEmpty { return }
            var created: [Pair] = []
            handleRun(ctx, run.map(\.line), nil, nil, a, b, &created)
            slots[run[0].at] = .many(created)
            run = []
        }
        var prevAt = -2
        for p in pending {
            if p.at != prevAt + 1 { flush() }
            prevAt = p.at
            let text = p.line.display
            let segs = segments(text)
            let k = usualBoundary(shapes, segs.count)
            if k > 0 {
                let (left, right) = cutAt(text, segs, k)
                if left.hasLetter && right.hasLetter {
                    flush()
                    func lean(_ t: PText) -> Double {
                        let s = ctx.score(t)
                        return s[a] - s[b]
                    }
                    slots[p.at] = .pair(makePair(left, right, p.line.span, langSplit: true, uncertain: lean(left) <= lean(right)))
                    continue
                }
            }
            run.append(p)
        }
        flush()
    }

    /// Left word count used by most successful splits of lines with `total` words.
    static func usualBoundary(_ shapes: [(Int, Int)], _ total: Int) -> Int {
        let same = shapes.filter { $0.0 + $0.1 == total }
        if same.count < 3 { return 0 }
        guard let left = mostFrequent(same.map(\.0)) else { return 0 }
        return Double(same.filter { $0.0 == left }.count) >= 0.6 * Double(same.count) ? left : 0
    }
}
