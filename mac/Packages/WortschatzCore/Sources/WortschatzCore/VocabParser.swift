// Port of src/core/parser.js: the smart vocabulary-list parser ("intelligente Texterkennung").
//
// Turns pasted, file-imported, PDF-extracted or OCR'd text into term/definition pairs. Handles
// delimited lists (tab, dash, equals, colon, semicolon, pipe, arrows, quoted CSV, Quizlet comma
// export, 2+ space PDF columns, 4-cell rows, 3-cell rows with an example or note column, page
// columns of "term – def" entries, mixed delimiters), line-based lists (blank-line blocks,
// alternating lines, wrapped continuation lines, two-column OCR order, number vocabulary) and noisy
// input (headings, page numbers, header rows, bullets). Ambiguous structure is resolved with
// per-line language detection: line-based lists are aligned by a small dynamic program that scores
// every possible grouping by how well each line's language fits its side.
//
// The implementation is split over VocabParser+*.swift (text primitives and regexes, context,
// lines, splitting, delimited lists, line-based lists). Strings are processed as Unicode scalar
// arrays with JS identity semantics so that every result matches the web app (see
// mac/Parity/gen-parser.js and VocabParserParityTests).
import Foundation

/// How `parseVocab` splits the text (JS `opts.mode`).
public enum ParseMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Detect the structure (delimiters, alternating lines, columns, …).
    case auto
    /// Split every record at `delimiter` (records separated by `cardSeparator`).
    case delimiter
    /// Line-based only (no delimiter detection).
    case lines
}

/// Options of `parseVocab` (JS `opts`, after `normalizeOptions`).
public struct ParseOptions: Codable, Sendable, Equatable, Hashable {
    public var mode: ParseMode
    /// Delimiter for `.delimiter` mode (JS default '\t' when nil). May contain "\n" (term and
    /// definition on separate lines inside each record).
    public var delimiter: String?
    /// Record separator for `.delimiter` mode ("\n" by default; "\n\n" = blank-line blocks).
    public var cardSeparator: String
    /// The language the user picked for the terms (a hint; `.other` = no hint), nil = none.
    public var termLang: Lang?
    /// The translation language hint. JS: `undefined` → 'de' (the default here); `null` or an
    /// invalid code → no hint (nil here).
    public var defLang: Lang?
    /// Put the translation language (German by default) on the definition side automatically.
    public var orient: Bool
    /// Swap the sides (applied after the automatic orientation).
    public var swap: Bool

    public init(
        mode: ParseMode = .auto, delimiter: String? = nil, cardSeparator: String = "\n", termLang: Lang? = nil,
        defLang: Lang? = .de, orient: Bool = true, swap: Bool = false
    ) {
        self.mode = mode
        self.delimiter = delimiter
        self.cardSeparator = cardSeparator
        self.termLang = termLang
        self.defLang = defLang
        self.orient = orient
        self.swap = swap
    }

    enum CodingKeys: String, CodingKey { case mode, delimiter, cardSeparator, termLang, defLang, orient, swap }

    /// `normalizeOptions(json)`: invalid mode → auto, empty delimiter/cardSeparator → defaults,
    /// absent defLang → de, null/invalid defLang → nil, `orient !== false`, `swap === true`.
    public init(json: JSONValue) {
        let o = json.objectValue ?? [:]
        mode = o["mode"]?.stringValue.flatMap(ParseMode.init(rawValue:)) ?? .auto
        let delim = o["delimiter"]?.stringValue
        delimiter = (delim?.isEmpty ?? true) ? nil : delim
        let sep = o["cardSeparator"]?.stringValue
        cardSeparator = (sep?.isEmpty ?? true) ? "\n" : sep!
        termLang = o["termLang"]?.stringValue.flatMap(Lang.init(rawValue:))
        if let d = o["defLang"] {
            defLang = d.stringValue.flatMap(Lang.init(rawValue:))
        } else {
            defLang = .de
        }
        orient = o["orient"] != .bool(false)
        swap = o["swap"] == .bool(true)
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeNullable(delimiter, forKey: .delimiter)
        try c.encode(cardSeparator, forKey: .cardSeparator)
        try c.encodeNullable(termLang, forKey: .termLang)
        try c.encodeNullable(defLang, forKey: .defLang)
        try c.encode(orient, forKey: .orient)
        try c.encode(swap, forKey: .swap)
    }
}

/// Detected layout of the input (`result.format`).
public enum ParseFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case empty
    /// One card per line/record, split at `delimiter`.
    case delimited
    /// Two page columns one after the other ("Zwei Spalten nacheinander").
    case columns
    /// Blank-line separated blocks (term line, definition line).
    case blocks
    /// Alternating term/definition lines.
    case alternating
}

/// Per-card review flags (`card.flags`).
public enum ParseFlag: String, Codable, Sendable, CaseIterable, Hashable {
    case merged, lowConfidence, langMismatch, missingTerm, missingDefinition, duplicate
}

/// Why a line was skipped (`skipped[].reason`).
public enum SkipReason: String, Codable, Sendable, CaseIterable, Hashable {
    case heading, pageNumber, noise, unpaired
}

/// A recognised card (`result.cards[]`).
public struct ParsedCard: Codable, Sendable, Equatable, Hashable {
    public var term: String
    public var definition: String
    /// 0…1, rounded to 2 decimals; < 0.5 is flagged `lowConfidence`.
    public var confidence: Double
    public var flags: [ParseFlag]
    /// 1-based source line numbers, ascending.
    public var lines: [Int]

    public init(term: String, definition: String, confidence: Double, flags: [ParseFlag] = [], lines: [Int] = []) {
        self.term = term
        self.definition = definition
        self.confidence = confidence
        self.flags = flags
        self.lines = lines
    }
}

/// A line without vocabulary (`result.skipped[]`).
public struct SkippedLine: Codable, Sendable, Equatable, Hashable {
    /// 1-based line number.
    public var line: Int
    public var text: String
    public var reason: SkipReason

    public init(line: Int, text: String, reason: SkipReason) {
        self.line = line
        self.text = text
        self.reason = reason
    }
}

/// Result of `parseVocab`. `delimiter` is encoded as explicit `null` when absent (like JS).
public struct ParseResult: Codable, Sendable, Equatable, Hashable {
    public var cards: [ParsedCard]
    public var format: ParseFormat
    /// The delimiter of a `.delimited` result ("\t", " - ", " → ", "=", ";", ",", "  " for
    /// space-separated columns, " " for both languages in one line, …), else nil.
    public var delimiter: String?
    public var termLang: Lang
    public var defLang: Lang
    /// Whether the sides were swapped (automatic orientation XOR `options.swap`).
    public var swapped: Bool
    /// Skipped lines, ascending by line number.
    public var skipped: [SkippedLine]
    /// German warnings for the detection bar.
    public var warnings: [String]

    public init(
        cards: [ParsedCard], format: ParseFormat, delimiter: String?, termLang: Lang, defLang: Lang, swapped: Bool,
        skipped: [SkippedLine], warnings: [String]
    ) {
        self.cards = cards
        self.format = format
        self.delimiter = delimiter
        self.termLang = termLang
        self.defLang = defLang
        self.swapped = swapped
        self.skipped = skipped
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey { case cards, format, delimiter, termLang, defLang, swapped, skipped, warnings }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cards, forKey: .cards)
        try c.encode(format, forKey: .format)
        try c.encodeNullable(delimiter, forKey: .delimiter)
        try c.encode(termLang, forKey: .termLang)
        try c.encode(defLang, forKey: .defLang)
        try c.encode(swapped, forKey: .swapped)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(warnings, forKey: .warnings)
    }
}

/// Port of src/core/parser.js: the smart vocabulary-list parser. Pure and never throws.
public enum VocabParser {
    /// Warning of the JS catch-all fallback. The Swift port has no failure path; the constant is
    /// kept for callers that compare warnings.
    public static let FAILURE_WARNING = "Der Text konnte nicht verarbeitet werden."

    /// Turns pasted, file-imported, PDF-extracted or OCR'd text into term/definition pairs.
    /// `nil` is treated as "" (JS `input == null`).
    ///
    /// Pure and reentrant (no shared state), so it can run off the main actor, e.g. for the
    /// debounced live recognition in the editor. About 15 ms for 500 pairs in a release build.
    public static func parseVocab(_ text: String?, options: ParseOptions = ParseOptions()) -> ParseResult {
        let o = Options(options)
        let source = PText(text ?? "")
        let ctx = Context(o)
        if o.mode == .delimiter { return finish(ctx, parseWithDelimiter(ctx, source)) }
        let lines = classify(ctx, preprocess(source))
        let content = lines.filter { !$0.blank && $0.kind == nil }
        if content.isEmpty { return finish(ctx, Outcome(pairs: [], format: .empty, delimiter: nil)) }
        if o.mode == .auto {
            if let inline = detectInline(ctx, content) { return finish(ctx, inline) }
            if let cand = detectDelimiter(ctx, lines) { return finish(ctx, parseDelimitedLines(ctx, lines, cand)) }
            if let bilingual = detectBilingual(ctx, content) { return finish(ctx, bilingual) }
        }
        return finish(ctx, parseLineBased(ctx, lines, allowSplit: o.mode == .auto))
    }
}

// MARK: - Orchestration & post-processing

extension VocabParser {
    /// Pick distinct languages when both columns detect the same one.
    static func distinctLanguages(
        _ ctx: Context, _ leftTexts: [PText], _ rightTexts: [PText], _ l: Int?, _ r: Int?
    ) -> (Int?, Int?) {
        guard let l, l == r else { return (l, r) }
        let ls = ctx.languageShares(leftTexts)
        let rs = ctx.languageShares(rightTexts)
        var best: (s: Double, l: Int, r: Int)?
        for a in ls {
            for b in rs {
                if a.lang == b.lang || a.share < 0.15 || b.share < 0.15 { continue }
                let s = a.share + b.share
                if best == nil || s > best!.s { best = (s, a.lang, b.lang) }
            }
        }
        return best.map { ($0.l, $0.r) } ?? (l, r)
    }

    /// The language the user picked for the terms wins over a close call ("lesson", "chapter"
    /// also look French). The term side is the one that is not the definition language; a
    /// decisive detection is kept.
    static func applyTermHint(
        _ ctx: Context, _ leftTexts: [PText], _ rightTexts: [PText], _ langs: (Int?, Double, Int?, Double)
    ) -> (Int?, Double, Int?, Double) {
        let (l, lConf, r, rConf) = langs
        guard let hint = ctx.o.termHint else { return langs }
        let target = ctx.o.target
        if hint == target || l == hint || r == hint { return langs }
        // Pinyin without tone marks looks French or Italian; picked as Chinese it is Chinese.
        func pinyin(_ texts: [PText]) -> Bool {
            hint == zh && !texts.isEmpty && Double(texts.filter(isPinyinCell).count) >= 0.8 * Double(texts.count)
        }
        if l != nil && l != target && pinyin(leftTexts) { return (hint, max(lConf, 0.55), r, rConf) }
        if l == target && r != nil && pinyin(rightTexts) { return (l, lConf, hint, max(rConf, 0.55)) }
        func close(_ texts: [PText]) -> Bool {
            let shares = ctx.languageShares(texts)
            guard let pos = shares.firstIndex(where: { $0.lang == hint }) else { return false }
            return pos < 2 && shares[pos].share >= 0.5 * shares[0].share
        }
        if l != nil && l != target && close(leftTexts) { return (hint, max(lConf, 0.55), r, rConf) }
        if l == target && r != nil && close(rightTexts) { return (l, lConf, hint, max(rConf, 0.55)) }
        return langs
    }

    /// The duplicate key of a term: `term.toLowerCase().replace(/[\s.!?]+$/, '').replace(/\s+/g, ' ')`.
    static func duplicateKey(_ term: PText) -> PText {
        var u = term.lowercased().u
        while let c = u.last, isWS(c) || c == "." || c == "!" || c == "?" { u.removeLast() }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(u.count)
        var inRun = false
        for c in u {
            if isWS(c) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(c)
                inRun = false
            }
        }
        return PText(out)
    }

    static func finish(_ ctx: Context, _ result: Outcome) -> ParseResult {
        let o = ctx.o
        let pairs = result.pairs.filter { !$0.term.isEmpty || !$0.def.isEmpty }
        let leftTexts = pairs.map(\.term).filter { !$0.isEmpty }
        let rightTexts = pairs.map(\.def).filter { !$0.isEmpty }
        let lc = ctx.detectColumn(leftTexts)
        let rc = ctx.detectColumn(rightTexts)
        var (l, r) = distinctLanguages(ctx, leftTexts, rightTexts, lc.lang, rc.lang)
        var lConf = lc.confidence
        var rConf = rc.confidence
        (l, lConf, r, rConf) = applyTermHint(ctx, leftTexts, rightTexts, (l, lConf, r, rConf))

        // A header row ("Französisch | Deutsch") decides when detection is unsure.
        if let header = ctx.header {
            if l == nil || lConf < 0.55 { (l, lConf) = (header.left, 0.6) }
            if r == nil || rConf < 0.55 { (r, rConf) = (header.right, 0.6) }
        }

        // Orientation: the definition side is the translation language (German by default).
        let target = o.target
        var autoSwap = false
        if o.orient && l != nil && r != nil && l != r {
            if l == target && r != target {
                autoSwap = true
            } else if r != target, let hint = o.termHint, r == hint, l != hint {
                autoSwap = true
            }
        } else if o.orient && (l != nil) != (r != nil) {
            // Only one side has words ("12 - douze"): it is the learned side unless it is German.
            autoSwap = r != nil ? r != target : l == target
        }
        let swapped = autoSwap != o.swap
        if swapped {
            for p in pairs { (p.term, p.def) = (p.def, p.term) }
            (l, r) = (r, l)
            (lConf, rConf) = (rConf, lConf)
        }

        let distinct = l != nil && r != nil && l != r
        var cards: [ParsedCard] = []
        var seen: [PText: Int] = [:]
        var seenEntries: [(term: PText, lines: [Int])] = []
        for p in pairs {
            var term = p.term
            var def = p.def
            var pT: Double? = term.isEmpty ? nil : ctx.pairProb(term, l, r)
            var pD: Double? = def.isEmpty ? nil : ctx.pairProb(def, r, l)
            let cognate = !term.isEmpty && !def.isEmpty && isCognate(term, def)
            // A single card written the other way round.
            if distinct && !cognate, let t = pT, let d = pD, t < 0.1 && d < 0.1 {
                (term, def) = (def, term)
                (pT, pD) = (1 - d, 1 - t)
                ctx.warnings.line(.reversed, p.lines[0])
            }
            var flags: [ParseFlag] = []
            var confidence = 0.75
            var mismatch = false
            if distinct && !cognate {
                if let t = pT, let d = pD {
                    confidence = (t * d) / (t * d + (1 - t) * (1 - d))
                } else {
                    confidence = pT ?? pD ?? 0.5
                }
                mismatch = (pT.map { $0 < 0.1 } ?? false) || (pD.map { $0 < 0.1 } ?? false)
            }
            if p.merged { confidence *= 0.85 }
            if p.langSplit { confidence *= 0.85 }
            if p.uncertain { confidence *= 0.45 } // always below the lowConfidence threshold
            if p.merged { flags.append(.merged) }
            if confidence < 0.5 {
                flags.append(.lowConfidence)
                ctx.warnings.line(.lowConfidence, p.lines[0])
            }
            if mismatch {
                flags.append(.langMismatch)
                ctx.warnings.line(.langMismatch, p.lines[0])
            }
            if term.isEmpty {
                flags.append(.missingTerm)
                ctx.warnings.line(.missingTerm, p.lines[0])
            }
            if def.isEmpty {
                flags.append(.missingDefinition)
                ctx.warnings.line(.missingDefinition, p.lines[0])
            }
            let key = duplicateKey(term)
            if !key.isEmpty {
                if let at = seen[key] {
                    flags.append(.duplicate)
                    seenEntries[at].lines.append(p.lines[0])
                } else {
                    seen[key] = seenEntries.count
                    seenEntries.append((term, [p.lines[0]]))
                }
            }
            cards.append(ParsedCard(
                term: term.string, definition: def.string, confidence: JSCompat.round(confidence * 100) / 100,
                flags: flags, lines: p.lines))
        }

        for entry in seenEntries where entry.lines.count > 1 { ctx.warnings.duplicate(entry.term.string, entry.lines) }
        let skipCount = ctx.skipped.filter { $0.reason != .unpaired }.count
        if skipCount > 0 {
            ctx.warnings.add(skipCount == 1
                ? "1 Zeile ohne Vokabeln wurde übersprungen."
                : "\(skipCount) Zeilen ohne Vokabeln wurden übersprungen.")
        }
        if cards.count >= 3 && !distinct { ctx.warnings.add("Die Sprachen der beiden Seiten konnten nicht sicher erkannt werden.") }

        func pickLang(_ lang: Int?, _ conf: Double, _ hint: Lang?) -> Lang {
            if let lang, conf >= 0.55 || hint == nil { return VocabParser.lang(lang) }
            return hint ?? .other
        }
        let format: ParseFormat = !cards.isEmpty || result.format != .empty ? result.format : .empty
        return ParseResult(
            cards: cards,
            format: format,
            delimiter: format == .delimited ? result.delimiter : nil,
            termLang: pickLang(l, lConf, o.termHintRaw),
            defLang: pickLang(r, rConf, o.defHintRaw),
            swapped: swapped,
            skipped: stableSorted(ctx.skipped) { $0.line < $1.line },
            warnings: ctx.warnings.build())
    }
}
