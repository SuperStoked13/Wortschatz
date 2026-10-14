import Foundation

// Options, the per-parse context (score cache, hint-aware prior, skipped lines, warnings) and the
// language helpers of parser.js. Languages are indices into `LangDetect.SUPPORTED`
// (fr, de, en, es, it); nil stands for JS `null` and for "unknown".

extension VocabParser {
    static let fr = 0, de = 1, en = 2, es = 3, it = 4

    // Alignment costs are negative log probabilities (nats).
    static let clipP = 0.04
    static let pairK = 0.9
    static let mergeCostDefault = 1.5
    static let unpairedCost = 4.0
    static let runUnpairedCost = 1.5
    static let weakHeadingCost = 0.6
    // A capitalised line before a lowercase term may be a section heading: cheaper to skip, dearer
    // to merge into the term (see align()).
    static let headingSkipCost = 2.5
    static let headingMergeCost = 3.0
    static let delimSplitCost = 0.3
    static let langSplitCost = 1.2
    // Lines with 3+ parts: a part this far into the other language is misplaced; split points
    // closer than splitMargin are a close call.
    static let splitMisfit = 2.0
    static let splitMargin = 0.5

    /// The index of `lang` in `LangDetect.SUPPORTED`, nil for nil and `.other`.
    static func index(of lang: Lang?) -> Int? {
        guard let lang else { return nil }
        return LangDetect.SUPPORTED.firstIndex(of: lang)
    }

    /// The `Lang` of a language index.
    static func lang(_ index: Int) -> Lang { LangDetect.SUPPORTED[index] }

    /// `normalizeOptions(opts)` on top of the typed `ParseOptions`.
    struct Options {
        var mode: ParseMode
        var delimiter: String?
        var cardSeparator: PText
        var termHintRaw: Lang?
        var defHintRaw: Lang?
        /// The hints without `.other`.
        var termHint: Int?
        var defHint: Int?
        var orient: Bool
        var swap: Bool

        init(_ o: ParseOptions) {
            mode = o.mode
            delimiter = (o.delimiter?.isEmpty ?? true) ? nil : o.delimiter
            cardSeparator = o.cardSeparator.isEmpty ? "\n" : PText(o.cardSeparator)
            termHintRaw = o.termLang
            defHintRaw = o.defLang
            termHint = VocabParser.index(of: o.termLang)
            defHint = VocabParser.index(of: o.defLang)
            orient = o.orient
            swap = o.swap
        }

        /// `o.defHint || 'de'`: the translation language.
        var target: Int { defHint ?? VocabParser.de }
    }

    /// The per-parse state (JS `createContext`).
    final class Context {
        let o: Options
        /// Hint-aware prior in `SUPPORTED` order.
        let prior: [Double]
        var skipped: [SkippedLine] = []
        let warnings = Warnings()
        /// Languages of the first header row that names them ("Französisch | Deutsch").
        var header: (left: Int, right: Int)?
        private var cache: [PText: [Double]] = [:]

        struct SplitKey: Hashable {
            let text: PText
            let a: Int
            let b: Int
        }

        /// `languageSplit` results (pure in text and language order).
        var languageSplits: [SplitKey: LanguageSplit?] = [:]

        init(_ o: Options) {
            self.o = o
            var p = [0.2, 0.25, 0.1, 0.05, 0]
            if let t = o.termHint { p[t] += 0.4 }
            if let d = o.defHint { p[d] += 0.3 }
            prior = p
        }

        /// `scoreLanguages(text)` (cached) in `SUPPORTED` order.
        func score(_ text: PText) -> [Double] {
            if let s = cache[text] { return s }
            let s = LangDetect.score(text.string)
            cache[text] = s
            return s
        }

        func skip(_ line: Line, _ reason: SkipReason) {
            line.kind = reason
            skipped.append(SkippedLine(line: line.no, text: line.display.string, reason: reason))
        }

        /// Probability that `text` is in language `a` rather than `b`.
        func pairProb(_ text: PText, _ a: Int?, _ b: Int?) -> Double {
            guard let a, let b, a != b, !text.isEmpty else { return 0.5 }
            let s = score(text)
            return 1 / (1 + exp(-VocabParser.pairK * (s[a] - s[b])))
        }

        /// Soft language votes over many texts (with the hint-aware prior), sorted by share
        /// (descending, ties in `SUPPORTED` order).
        func languageShares(_ texts: [PText]) -> [(lang: Int, share: Double)] {
            var votes = [Double](repeating: 0, count: 5)
            var n = 0
            var e = [Double](repeating: 0, count: 5)
            for t in texts {
                let s = score(t)
                guard LangDetect.hasEvidence(s) else { continue }
                var maximum = -Double.infinity
                for l in 0..<5 { maximum = max(maximum, s[l] + prior[l]) }
                var sum = 0.0
                for l in 0..<5 {
                    e[l] = exp(s[l] + prior[l] - maximum)
                    sum += e[l]
                }
                for l in 0..<5 { votes[l] += e[l] / sum }
                n += 1
            }
            let shares = (0..<5).map { (lang: $0, share: n > 0 ? votes[$0] / Double(n) : 0) }
            return VocabParser.stableSorted(shares) { $0.share > $1.share }
        }

        func topTwoLanguages(_ texts: [PText]) -> (Int?, Int?) {
            let shares = languageShares(texts)
            if shares[0].share == 0 { return (nil, nil) }
            return (shares[0].lang, shares[1].share >= 0.1 ? shares[1].lang : nil)
        }

        /// `detectColumn(lines)` of langdetect.js on the cached scores (the same computation as
        /// `LangDetect.detectColumn`). `lang` is nil for "unknown".
        func detectColumn(_ lines: [PText]) -> (lang: Int?, confidence: Double) {
            var votes = [Double](repeating: 0, count: 5)
            var evidence = [Double](repeating: 0, count: 5)
            var n = 0
            for line in lines {
                let scores = score(line)
                guard LangDetect.hasEvidence(scores) else { continue }
                let p = LangDetect.softmax(scores)
                var best = 0.0
                for l in 0..<5 { best = max(best, scores[l]) }
                for l in 0..<5 {
                    votes[l] += p[l]
                    evidence[l] += max(-8, scores[l] - best)
                }
                n += 1
            }
            guard n > 0 else { return (nil, 0) }
            let count = Double(n)
            var order = LangDetect.rank(votes)
            let (a, b) = (order[0], order[1])
            if abs(votes[a] - votes[b]) / count < 0.04 && evidence[b] > evidence[a] { order = [b, a] }
            let share = votes[order[0]] / count
            let secondShare = votes[order[1]] / count
            let separation = share / (share + secondShare)
            let sizeFactor = min(1, 0.7 + 0.1 * count)
            let confidence = max(0, min(1, separation * sizeFactor))
            return (order[0], JSCompat.round(confidence * 1000) / 1000)
        }
    }

    static func clip(_ p: Double) -> Double { min(1 - clipP, max(clipP, p)) }

    static func nlog(_ p: Double) -> Double { -log(clip(p)) }

    /// A stable sort (JS `Array.prototype.sort` is stable).
    static func stableSorted<T>(_ list: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        list.enumerated()
            .sorted { a, b in
                if areInIncreasingOrder(a.element, b.element) { return true }
                if areInIncreasingOrder(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}

// MARK: - German warnings

extension VocabParser {
    final class Warnings {
        /// In the order of JS `LINE_WARNINGS`.
        enum Kind: CaseIterable {
            case unpaired, merged, reversed, lowConfidence, langMismatch, missingTerm, missingDefinition

            var texts: (one: String, many: String) {
                switch self {
                case .unpaired:
                    ("Zeile {n} konnte keinem Paar zugeordnet werden.", "Zeilen {n} konnten keinem Paar zugeordnet werden.")
                case .merged:
                    ("Zeile {n} wurde als Fortsetzung der vorherigen Zeile übernommen.",
                     "Zeilen {n} wurden als Fortsetzung der vorherigen Zeile übernommen.")
                case .reversed:
                    ("Zeile {n}: Begriff und Definition waren vertauscht und wurden umgedreht.",
                     "Zeilen {n}: Begriff und Definition waren vertauscht und wurden umgedreht.")
                case .lowConfidence:
                    ("Zeile {n} wurde unsicher erkannt – bitte prüfen.", "Zeilen {n} wurden unsicher erkannt – bitte prüfen.")
                case .langMismatch:
                    ("Zeile {n} passt sprachlich nicht zu ihrer Spalte.", "Zeilen {n} passen sprachlich nicht zu ihrer Spalte.")
                case .missingTerm:
                    ("Zeile {n}: Der Begriff fehlt.", "Zeilen {n}: Der Begriff fehlt.")
                case .missingDefinition:
                    ("Zeile {n}: Die Definition fehlt.", "Zeilen {n}: Die Definition fehlt.")
                }
            }
        }

        private var byKind: [Kind: [Int]] = [:]
        private var extra: [String] = []
        private var dups: [(term: String, nos: [Int])] = []

        func line(_ kind: Kind, _ no: Int) {
            var list = byKind[kind] ?? []
            if !list.contains(no) { list.append(no) }
            byKind[kind] = list
        }

        func add(_ message: String) {
            if !extra.contains(message) { extra.append(message) }
        }

        func duplicate(_ term: String, _ nos: [Int]) {
            dups.append((term, nos))
        }

        func build() -> [String] {
            var out: [String] = []
            for kind in Kind.allCases {
                let nos = (byKind[kind] ?? []).sorted()
                if nos.isEmpty { continue }
                let (one, many) = kind.texts
                out.append((nos.count == 1 ? one : many).replacingOccurrences(of: "{n}", with: Self.listNumbers(nos)))
            }
            if dups.count > 3 {
                out.append("\(dups.count) Begriffe kommen mehrfach vor.")
            } else {
                for d in dups { out.append("«\(d.term)» kommt mehrfach vor (Zeilen \(Self.listNumbers(d.nos))).") }
            }
            return out + extra
        }

        static func listNumbers(_ nos: [Int]) -> String {
            let shown = nos.prefix(6).map(String.init)
            let more = nos.count - shown.count
            if more > 0 { return "\(shown.joined(separator: ", ")) und \(more) weitere" }
            if shown.count == 1 { return shown[0] }
            return "\(shown.dropLast().joined(separator: ", ")) und \(shown[shown.count - 1])"
        }
    }
}
