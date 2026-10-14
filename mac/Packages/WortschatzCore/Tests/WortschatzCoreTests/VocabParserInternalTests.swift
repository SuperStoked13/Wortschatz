// Checks of the parser's internal shortcuts against the straightforward definitions they replace
// (normalisation fast path, cached column detection, regex prefilters). They need internal access,
// which `swift test` has in debug builds only.
#if DEBUG
import Foundation
import Testing
@testable import WortschatzCore

@Suite("VocabParser internals")
struct VocabParserInternalTests {
    typealias P = VocabParser

    /// Lines of every web fixture plus seeded random strings over an alphabet full of the
    /// characters the normaliser and the regexes treat specially.
    static let samples: [String] = {
        var out: [String] = []
        for name in VocabParserWebFixtures.names {
            out.append(contentsOf: VocabParserWebFixtures.read(name).components(separatedBy: "\n"))
        }
        let alphabet = [
            "a", "Z", "é", "e\u{301}", "ü", "ß", "ſ", "\u{212A}", "\u{212B}", "İ", "Σ", "ς", " ", "  ", "\t", "\u{A0}", "\u{2007}",
            "\u{2003}", "\u{202F}", "\u{3000}", "\u{200B}", "\u{FEFF}", "\u{2060}", "\u{0B}", "\u{0C}", "\r", "’", "`", "´", "ʹ",
            "–", "—", "−", "-", "1", "12", "(", ")", ".", ":", ";", ",", "|", "=", ">", "→", "⇒", "<->", "•", "▶", "*", "'", "\"",
            "«", "»", "Seite", "page", "Lektion", "Unité", "IV", "www.", "http://", "©", "(c) ", "le ", "der ", "s'", "qu'", "🐱",
            "𝄞", "\u{2000}", "\u{2001}", "A\u{30A}", "\u{FB01}",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ n: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(n))
        }
        for _ in 0..<3000 {
            var s = ""
            for _ in 0..<next(24) { s += alphabet[next(alphabet.count)] }
            out.append(s)
        }
        return out
    }()

    @Test("normalizeKeepTabs equals TextNormalizer.normalizeBasic(keepTabs: true)")
    func normalisation() {
        for s in Self.samples {
            let fast = P.normalizeKeepTabs(P.PText(s))
            let reference = P.PText(TextNormalizer.normalizeBasic(s, keepTabs: true))
            #expect(fast == reference, "\(s.debugDescription)")
        }
    }

    @Test("text below U+0300 is already in NFC")
    func nfcBelowCombiningMarks() {
        for v in 0..<0x300 {
            guard let u = Unicode.Scalar(v) else { continue }
            let s = String(u)
            #expect(Array(s.precomposedStringWithCanonicalMapping.unicodeScalars) == [u], "U+\(String(v, radix: 16))")
        }
    }

    @Test("the cached detectColumn equals LangDetect.detectColumn")
    func detectColumn() {
        let ctx = P.Context(P.Options(ParseOptions()))
        var columns: [[String]] = []
        for name in VocabParserWebFixtures.names {
            let r = VocabParser.parseVocab(VocabParserWebFixtures.read(name))
            columns.append(r.cards.map(\.term))
            columns.append(r.cards.map(\.definition))
            columns.append(VocabParserWebFixtures.read(name).components(separatedBy: "\n"))
        }
        for k in stride(from: 0, to: Self.samples.count - 8, by: 8) { columns.append(Array(Self.samples[k..<(k + 8)])) }
        columns.append([])
        for column in columns {
            let cached = ctx.detectColumn(column.map { P.PText($0) })
            let reference = LangDetect.detectColumn(column)
            #expect(cached.lang.map(P.lang) == reference.lang.lang, "\(column)")
            #expect(cached.confidence == reference.confidence, "\(column)")
        }
    }

    @Test("every KEYWORD_RE word passes the keyword prefilter")
    func keywordPrefixes() {
        let words = [
            "seite", "page", "unit", "unite", "unité", "unita", "unità", "lektion", "lecon", "leçon", "lesson", "chapitre",
            "chapter", "kapitel", "capitolo", "capitulo", "capítulo", "unidad", "lezione", "leccion", "lección", "modul",
            "module", "theme", "thème", "thema", "tema", "vocabulaire", "vocabulary", "vocabulario", "vocabolario", "wortschatz",
            "vokabeln", "vokabular", "glossar", "glossaire", "dossier", "etape", "étape", "abschnitt", "section",
        ]
        for w in words {
            for variant in [w, w.uppercased(), w.capitalized, "\(w) 3", "\(w.capitalized): les animaux"] {
                let t = P.PText(variant)
                #expect(P.keywordEnd(t) == P.matchEnd(P.keywordRE, t), "\(variant)")
                #expect(P.keywordEnd(t) != nil, "\(variant)")
            }
        }
        // The long s and the Kelvin sign fold like in /iu regexes.
        #expect(P.keywordEnd("ſeite 3") == 5)
        #expect(P.keywordEnd("\u{212A}apitel 2") == 7)
        #expect(P.keywordEnd("units") == nil)
    }

    @Test("the regex prefilters never reject a match")
    func prefilters() {
        for s in Self.samples {
            let flat = P.normalizeKeepTabs(P.PText(s)).tabsToSpaces().trimmed()
            for t in [flat, P.PText(s)] {
                #expect(P.isPageNumber(t) == P.matchesAtStart(P.pageRE, t), "\(t)")
                #expect(P.hasURL(t) == (P.search(P.urlRE, t) != nil), "\(t)")
                #expect(P.keywordEnd(t) == P.matchEnd(P.keywordRE, t), "\(t)")
                #expect(P.isAlwaysHeading(t) == P.matchesAtStart(P.alwaysHeadingRE, t), "\(t)")
                #expect(P.markerEnd(t) == P.matchEnd(P.markerRE, t), "\(t)")
                #expect(P.numberCellEnd(t) == P.matchEnd(P.numberCellRE, t), "\(t)")
                #expect(P.numberedEnd(t) == P.matchEnd(P.numberedRE, t), "\(t)")
                #expect(P.startsEntry(t) == P.matchesAtStart(P.entryStartRE, t), "\(t)")
                #expect(P.startsContinuation(t) == P.matchesAtStart(P.sentenceContinuationRE, t), "\(t)")
                #expect(P.startsWithHeadingNumber(t) == P.matchesAtStart(P.headingNumberRE, t), "\(t)")
                #expect(P.hasRomanNumber(t) == (P.search(P.romanRE, t) != nil), "\(t)")
                #expect(P.splitArrows(t) == P.split(t, P.arrowRE), "\(t)")
                #expect(P.splitTightComma(t) == P.split(t, P.tightCommaRE), "\(t)")
            }
        }
    }

    @Test("regex ports behave like the JS regexes on hand-picked inputs")
    func regexes() {
        // PAGE_RE
        for page in ["12", "- 12 -", "Seite 3", "seite3", "S. 4", "p.5", "pag 6", "página 7", "3 / 9", "3 von 9", "Page 2 of 4", "7 -"] {
            #expect(P.isPageNumber(P.PText(page)), "\(page)")
        }
        for text in ["12345", "Seite", "Seite 3 Vokabeln", "3 -- 4", "p 5x"] { #expect(!P.isPageNumber(P.PText(text)), "\(text)") }
        // MARKER_RE (lengths include the following blanks)
        #expect(P.markerEnd("1. le chat") == 3)
        #expect(P.markerEnd("(12) le chat") == 5)
        #expect(P.markerEnd("12 - le chat") == 5)
        #expect(P.markerEnd("12 -le chat") == nil)
        #expect(P.markerEnd("a) le chat") == 3)
        #expect(P.markerEnd("•\t\tle chat") == 3)
        #expect(P.markerEnd("1234. le chat") == nil)
        // ARROW_RE splits like String.prototype.split
        #expect(P.splitArrows("a -> b --> c<->d") == ["a", "b", "c", "d"])
        #expect(P.splitArrows("→ x") == ["", "x"])
        #expect(P.splitTightComma("beau, belle,schön,") == ["beau, belle", "schön", ""])
        // ENTRY_START_RE: s' unless "s'il"
        #expect(P.startsEntry("s'appeler"))
        #expect(!P.startsEntry("s'il vous plaît"))
        #expect(P.startsEntry("S'ils"))
        #expect(P.startsEntry("Les chats"))
        #expect(!P.startsEntry("lesson"))
    }

    @Test("astral letters follow the spec (JSC misses some; see gen-parser.js)")
    func astralLetters() {
        let bold = "\u{1D400}" // MATHEMATICAL BOLD CAPITAL A, \p{Lu}
        #expect(P.endsWithLetterHyphen(P.PText("x\(bold)-")))
        // JS tests single UTF-16 code units next to a glued hyphen: an astral letter is no letter
        // there, so "a-<astral>" stays one segment.
        #expect(P.segments(P.PText("a-\(bold)")).count == 1)
        #expect(P.segments(P.PText("ab-cd")).count == 2)
    }

    @Test("the split cache is invalidated when a line changes")
    func splitCache() {
        let line = P.makeLine("1. le chat - die Katze", 1)
        let dash = P.candidates[1]
        #expect(P.splitWith(line, dash).parts == ["1. le chat", "die Katze"])
        line.text = P.stripMarker(line.text)
        #expect(P.splitWith(line, dash).parts == ["le chat", "die Katze"])
    }
}
#endif
