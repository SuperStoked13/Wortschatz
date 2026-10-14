import Foundation
import Testing
import WortschatzCore

// Port of the layout.js part of tests/layout.test.js (itemsToLines, estimateSlope, deskewItems).
// The OCR / file helpers tested in the same JS file (ocrLangsFor, ocrDataToText, imageScaleFor,
// detectFileKind, fixGermanUmlauts) belong to src/import/ocr.js and files.js, not to this module.
// Where the JS tests continue with parseVocab, the itemsToLines output is checked instead.

@Suite("TextLayout (layout.test.js)")
struct TextLayoutTests {
    // Geometry used by the helpers: 6 px per character, 12 px glyph height, 16 px line pitch.
    static let cw = 6.0
    static let h = 12.0
    static let pitch = 16.0

    /// One item per word, separated by a normal space (like OCR word boxes).
    static func words(_ x: Double, _ y: Double, _ text: String, cw: Double = cw, h: Double = h) -> [TextItem] {
        var out: [TextItem] = []
        var cx = x
        for w in text.components(separatedBy: " ") {
            let length = Double(w.utf16.count)
            out.append(TextItem(str: w, x: cx, y: y, w: length * cw, h: h))
            cx += (length + 1) * cw
        }
        return out
    }

    /// One item per cell (like pdf.js text runs).
    static func run(_ x: Double, _ y: Double, _ text: String, cw: Double = cw, h: Double = h) -> TextItem {
        TextItem(str: text, x: x, y: y, w: Double(text.utf16.count) * cw, h: h)
    }

    /// A table: rows of cells at the given column x positions.
    static func table(_ rows: [[String]], _ xs: [Double], y0: Double = 100, pitch: Double = pitch,
                      perWord: Bool = false) -> [TextItem] {
        var items: [TextItem] = []
        for (r, cells) in rows.enumerated() {
            for (c, text) in cells.enumerated() where !text.isEmpty {
                let y = y0 + Double(r) * pitch
                if perWord { items += words(xs[c], y, text) } else { items.append(run(xs[c], y, text)) }
            }
        }
        return items
    }

    /// The deterministic LCG shuffle of the JS tests (in Double arithmetic, like JS).
    static func shuffled<T>(_ list: [T], seed: Double = 7) -> [T] {
        var a = list
        var s = seed
        var i = a.count - 1
        while i > 0 {
            s = (s * 1_103_515_245 + 12345).truncatingRemainder(dividingBy: 2_147_483_648)
            let j = Int(s.truncatingRemainder(dividingBy: Double(i + 1)))
            a.swapAt(i, j)
            i -= 1
        }
        return a
    }

    static let pairs: [[String]] = [
        ["le monsieur, messieurs", "der Herr"],
        ["l'homme", "der Mann"],
        ["la femme", "die Frau"],
        ["l'enfant", "das Kind"],
        ["le garçon", "der Junge"],
        ["la fille", "das Mädchen"],
    ]

    static let more: [[String]] = [
        ["appeler", "nennen"],
        ["s'appeler", "heissen"],
        ["le nom", "der Name"],
        ["le prénom", "der Vorname"],
        ["la rue", "die Strasse"],
    ]

    static func tabbed(_ rows: [[String]]) -> [String] { rows.map { "\($0[0])\t\($0[1])" } }

    static func lines(_ items: [TextItem], _ options: LayoutOptions = LayoutOptions()) -> [String] {
        TextLayout.itemsToLines(items, options: options)
    }

    // MARK: Basics

    @Test("empty and invalid input yields no lines")
    func emptyInput() {
        #expect(Self.lines([]).isEmpty)
        #expect(Self.lines([TextItem(str: "   ", x: 0, y: 0), TextItem(str: "x", x: .nan, y: 1)]).isEmpty)
        // [null, { str: '   ', x: 0, y: 0 }, { str: 'x', x: NaN, y: 1 }, { x: 1, y: 1 }] read leniently
        let json: [JSONValue] = [.null, ["str": "   ", "x": 0, "y": 0], ["str": "x", "x": .null, "y": 1], ["x": 1, "y": 1]]
        let items = json.compactMap(TextItem.init(json:))
        #expect(items.count == 1)
        #expect(Self.lines(items).isEmpty)
    }

    @Test("null options fall back to defaults")
    func nullOptions() {
        #expect(Self.lines(Self.words(10, 10, "der Herr"), LayoutOptions(json: .null)) == ["der Herr"])
        #expect(Self.lines(Self.words(10, 10, "der Herr"), LayoutOptions(yTolerance: .nan, gapFactor: .infinity)) == ["der Herr"])
    }

    @Test("words on one baseline become one line with single spaces")
    func oneBaseline() {
        #expect(Self.lines(Self.words(10, 50, "le monsieur, messieurs")) == ["le monsieur, messieurs"])
    }

    @Test("fragments without a gap are joined without a space")
    func fragments() {
        let items = [Self.run(10, 20, "das Fr"), TextItem(str: "äulein", x: 10 + 6 * Self.cw, y: 20, w: 6 * Self.cw, h: Self.h)]
        #expect(Self.lines(items) == ["das Fräulein"])
    }

    @Test("trailing and leading spaces inside items mark word boundaries")
    func spacesMarkBoundaries() {
        let items = [
            TextItem(str: "der ", x: 10, y: 20, w: 4 * Self.cw, h: Self.h),
            TextItem(str: "Herr", x: 10 + 4 * Self.cw, y: 20, w: 4 * Self.cw, h: Self.h),
            TextItem(str: " und", x: 10 + 8 * Self.cw, y: 20, w: 4 * Self.cw, h: Self.h),
        ]
        #expect(Self.lines(items) == ["der Herr und"])
    }

    @Test("rows are grouped by y despite small jitter")
    func jitter() {
        let items = [
            TextItem(str: "le", x: 10, y: 101.5, w: 2 * Self.cw, h: Self.h),
            TextItem(str: "monsieur", x: 10 + 3 * Self.cw, y: 98.5, w: 8 * Self.cw, h: Self.h),
            TextItem(str: "der", x: 10, y: 117.2, w: 3 * Self.cw, h: Self.h),
            TextItem(str: "Herr", x: 10 + 4 * Self.cw, y: 114.6, w: 4 * Self.cw, h: Self.h),
        ]
        #expect(Self.lines(items) == ["le monsieur", "der Herr"])
    }

    @Test("items out of order are put back in reading order")
    func readingOrder() {
        var items: [TextItem] = []
        for (i, p) in Self.pairs.enumerated() {
            items += Self.words(20, 100 + Double(i * 2) * Self.pitch, p[0])
            items += Self.words(20, 100 + Double(i * 2 + 1) * Self.pitch, p[1])
        }
        let expected = Self.pairs.flatMap { $0 }
        #expect(Self.lines(items) == expected)
        #expect(Self.lines(Self.shuffled(items)) == expected)
        #expect(Self.lines(Self.shuffled(items, seed: 99)) == expected)
    }

    @Test("missing widths and heights are estimated")
    func missingSizes() {
        let items = [
            TextItem(str: "le nom", x: 10, y: 20),
            TextItem(str: "der Name", x: 300, y: 20),
            TextItem(str: "la rue", x: 10, y: 40),
            TextItem(str: "die Strasse", x: 300, y: 40),
        ]
        #expect(Self.lines(items) == ["le nom\tder Name", "la rue\tdie Strasse"])
    }

    @Test("invisible characters and odd spaces are cleaned")
    func invisibleCharacters() {
        let items = [TextItem(str: "la\u{00A0}mademoiselle\u{00AD}", x: 0, y: 0, w: 16 * Self.cw, h: Self.h)]
        #expect(Self.lines(items) == ["la mademoiselle"])
    }

    // MARK: Columns

    @Test("a wide horizontal gap becomes a tab")
    func wideGap() {
        #expect(Self.lines(Self.words(10, 20, "le nom") + Self.words(200, 20, "der Name")) == ["le nom\tder Name"])
    }

    @Test("gapFactor controls when a gap counts as a column break")
    func gapFactor() {
        let items = Self.words(10, 20, "le nom") + Self.words(10 + 9 * Self.cw, 20, "der Name")
        // 3-character gap: > 2.2 × char width → tab; with gapFactor 4 it is a space.
        #expect(Self.lines(items) == ["le nom\tder Name"])
        #expect(Self.lines(items, LayoutOptions(gapFactor: 4)) == ["le nom der Name"])
    }

    @Test("two-column vocabulary table → term<TAB>definition rows")
    func twoColumnTable() {
        let rows = Self.pairs + Self.more
        #expect(Self.lines(Self.table(rows, [40, 260], perWord: true)) == Self.tabbed(rows))
    }

    @Test("two-column table from shuffled pdf runs")
    func shuffledRuns() {
        let rows = Self.pairs + Self.more
        #expect(Self.lines(Self.shuffled(Self.table(rows, [40, 260]))) == Self.tabbed(rows))
    }

    @Test("two-column table with y jitter per cell")
    func jitterPerCell() {
        let items = Self.table(Self.pairs, [40, 260]).enumerated().map { i, it in
            var it = it
            it.y += Double(i % 3 - 1) * 2.5
            return it
        }
        #expect(Self.lines(items) == Self.tabbed(Self.pairs))
    }

    @Test("four-column table → left pairs first, then right pairs")
    func fourColumns() {
        let rows = Self.pairs.enumerated().map { i, p in p + (i < Self.more.count ? Self.more[i] : []) }
        let lines = Self.lines(Self.shuffled(Self.table(rows, [30, 190, 360, 520], perWord: true)))
        #expect(lines == Self.tabbed(Self.pairs) + [""] + Self.tabbed(Self.more))
    }

    @Test("four-column table where the right half is longer")
    func fourColumnsRightLonger() {
        let right = Self.more + [["calme", "ruhig"], ["sage", "brav, artig"], ["bête", "dumm"]]
        let rows = right.enumerated().map { i, p in (i < Self.pairs.count ? Self.pairs[i] : ["", ""]) + p }
        #expect(Self.lines(Self.table(rows, [30, 190, 360, 520])) == Self.tabbed(Self.pairs) + [""] + Self.tabbed(right))
    }

    @Test("a heading spanning the table does not break column detection")
    func spanningHeading() {
        let heading = "Unité 3 – Les personnes et les adjectifs du caractère"
        let lines = Self.lines(Self.words(30, 60, heading) + Self.table(Self.pairs, [30, 260]))
        #expect(lines.first == heading)
        #expect(Array(lines.suffix(Self.pairs.count)) == Self.tabbed(Self.pairs))
    }

    @Test("a numbering column is dropped")
    func numberingColumn() {
        let rows = Self.pairs.enumerated().map { i, p in ["\(i + 1).", p[0], p[1]] }
        #expect(Self.lines(Self.table(rows, [20, 60, 280])) == Self.tabbed(Self.pairs))
    }

    @Test("a numbered single-column list keeps only the text")
    func numberedList() {
        let rows = Self.pairs.prefix(4).enumerated().map { i, p in ["\(i + 1))", p[0]] }
        #expect(Self.lines(Self.table(rows, [20, 60])) == Self.pairs.prefix(4).map { $0[0] })
    }

    @Test("an example-sentence column between term and translation is dropped")
    func sentenceColumn() {
        let rows = [
            ["le monsieur", "Le monsieur parle avec sa voisine.", "der Herr"],
            ["la femme", "La femme de Paul est très gentille.", "die Frau"],
            ["le garçon", "Le garçon joue au foot avec ses amis.", "der Junge"],
            ["la fille", "La fille de mes voisins a dix ans.", "das Mädchen"],
        ]
        #expect(Self.lines(Self.table(rows, [20, 160, 420])) == rows.map { "\($0[0])\t\($0[2])" })
    }

    @Test("monospace columns inside one item are split at runs of spaces")
    func monospace() {
        let items = [
            Self.run(10, 20, "le nom          der Name"),
            Self.run(10, 36, "la rue          die Strasse"),
            Self.run(10, 52, "le prénom       der Vorname"),
        ]
        #expect(Self.lines(items) == ["le nom\tder Name", "la rue\tdie Strasse", "le prénom\tder Vorname"])
    }

    @Test("fake-bold duplicates are removed")
    func fakeBold() {
        let items = [Self.run(10, 20, "der Herr"), Self.run(10.4, 20, "der Herr"), Self.run(200, 20, "le monsieur")]
        #expect(Self.lines(items) == ["der Herr\tle monsieur"])
    }

    // MARK: Wrapped cells

    @Test("wrapped definitions are merged into their row")
    func wrappedDefinitions() {
        let items = Self.words(30, 100, "le nom de famille") + Self.words(260, 100, "der Familienname,")
            + Self.words(260, 116, "der Nachname") + Self.words(30, 132, "le prénom") + Self.words(260, 132, "der Vorname")
            + Self.words(30, 148, "l'adresse") + Self.words(260, 148, "die Adresse,") + Self.words(260, 164, "die Anschrift")
            + Self.words(30, 180, "la rue") + Self.words(260, 180, "die Strasse")
        #expect(Self.lines(items) == [
            "le nom de famille\tder Familienname, der Nachname",
            "le prénom\tder Vorname",
            "l'adresse\tdie Adresse, die Anschrift",
            "la rue\tdie Strasse",
        ])
    }

    @Test("a wrapped term ending with a comma is merged")
    func wrappedTermComma() {
        let items = Self.words(30, 100, "le monsieur,") + Self.words(260, 100, "der Herr") + Self.words(30, 116, "messieurs")
            + Self.words(30, 132, "la femme") + Self.words(260, 132, "die Frau")
            + Self.words(30, 148, "la dame") + Self.words(260, 148, "die Dame")
        #expect(Self.lines(items) == ["le monsieur, messieurs\tder Herr", "la femme\tdie Frau", "la dame\tdie Dame"])
    }

    @Test("a wrapped lowercase term is merged when rows are spaced wider than lines")
    func wrappedLowercaseTerm() {
        let items = Self.words(30, 100, "le numéro de la") + Self.words(260, 100, "die Hausnummer") + Self.words(30, 115, "maison")
            + Self.words(30, 140, "la rue") + Self.words(260, 140, "die Strasse")
            + Self.words(30, 165, "la personne") + Self.words(260, 165, "die Person")
        #expect(Self.lines(items) == ["le numéro de la maison\tdie Hausnummer", "la rue\tdie Strasse", "la personne\tdie Person"])
    }

    @Test("a section heading inside a table stays a separate line")
    func sectionHeading() {
        let items = Self.table(Array(Self.pairs.prefix(3)), [30, 260], y0: 100)
            + Self.words(30, 100 + 2 * Self.pitch + 3 * Self.pitch, "Les adjectifs")
            + Self.table(Array(Self.more.prefix(3)), [30, 260], y0: 100 + 6 * Self.pitch)
        #expect(Self.lines(items) == Self.tabbed(Array(Self.pairs.prefix(3))) + ["", "Les adjectifs"] + Self.tabbed(Array(Self.more.prefix(3))))
    }

    // MARK: Paragraphs and page columns

    /// term, definition, "" between pairs
    static func stacked(_ rows: [[String]]) -> [String] {
        rows.enumerated().flatMap { i, p in (i > 0 ? [""] : []) + p }
    }

    @Test("paragraph gaps become blank lines (stacked term / definition list)")
    func paragraphGaps() {
        var items: [TextItem] = []
        var y = 80.0
        for p in Self.pairs {
            items += Self.words(40, y, p[0])
            items += Self.words(40, y + Self.pitch, p[1])
            y += Self.pitch * 5
        }
        #expect(Self.lines(Self.shuffled(items)) == Self.stacked(Self.pairs))
    }

    @Test("three evenly but widely spaced rows are not paragraphs")
    func evenWideRows() {
        let rows = Array(Self.pairs.prefix(3))
        #expect(Self.lines(Self.table(rows, [20, 300], pitch: 50)) == Self.tabbed(rows))
    }

    @Test("three rows with one wide gap get one blank line")
    func oneWideGap() {
        let items = Self.words(40, 100, "le nom") + Self.words(40, 116, "der Name") + Self.words(40, 180, "la rue")
        #expect(Self.lines(items) == ["le nom", "der Name", "", "la rue"])
    }

    @Test("two lines far apart are separate paragraphs")
    func twoLinesFarApart() {
        let items = Self.words(40, 100, "Vocabulaire") + Self.words(40, 100 + 4 * Self.pitch, "le nom")
        #expect(Self.lines(items) == ["Vocabulaire", "", "le nom"])
    }

    @Test("whitespace-only and empty pdf items are ignored")
    func whitespaceItems() {
        let items = [
            Self.run(40, 100, "le nom"),
            TextItem(str: " ", x: 40 + 6 * Self.cw, y: 100, w: 140, h: Self.h),
            TextItem(str: "", x: 0, y: 100, w: 0, h: 0),
            Self.run(260, 100, "der Name"),
            Self.run(40, 116, "la rue"),
            Self.run(260, 116, "die Strasse"),
        ]
        #expect(Self.lines(items) == ["le nom\tder Name", "la rue\tdie Strasse"])
    }

    @Test("a normal line pitch never creates blank lines")
    func normalPitch() {
        let items = Self.pairs.flatMap { $0 }.enumerated().flatMap { i, text in Self.words(40, 100 + Double(i) * Self.pitch, text) }
        #expect(!Self.lines(items).contains(""))
    }

    @Test("uniform double spacing is not treated as paragraphs")
    func doubleSpacing() {
        let flat = Self.pairs.flatMap { $0 }
        let items = flat.enumerated().flatMap { i, text in Self.words(40, 100 + Double(i) * Self.pitch * 2, text) }
        #expect(Self.lines(items) == flat)
    }

    @Test("stacked pairs in two page columns are read column by column")
    func stackedTwoColumns() {
        let left = Array(Self.pairs.prefix(4))
        let right = Array(Self.more.prefix(4))
        var items: [TextItem] = []
        for (col, list) in [left, right].enumerated() {
            var y = 100.0
            for p in list {
                items += Self.words(col == 1 ? 320 : 40, y, p[0])
                items += Self.words(col == 1 ? 320 : 40, y + Self.pitch, p[1])
                y += Self.pitch * 4
            }
        }
        #expect(Self.lines(items) == Self.stacked(left) + [""] + Self.stacked(right))
    }

    @Test("unaligned text columns are read column by column")
    func unalignedColumns() {
        let left = Self.pairs.flatMap { $0 }
        let right = Self.more.flatMap { $0 }
        // Same leading, but the right column is shifted by half a line.
        let items = left.enumerated().flatMap { i, t in Self.words(40, 100 + Double(i) * Self.pitch, t) }
            + right.enumerated().flatMap { i, t in Self.words(330, 108 + Double(i) * Self.pitch, t) }
        #expect(Self.lines(items) == left + [""] + right)
    }

    @Test("indented definitions in a single column keep the row order")
    func indentedDefinitions() {
        var items: [TextItem] = []
        var y = 100.0
        for p in Self.pairs {
            items += Self.words(40, y, p[0])
            items += Self.words(120, y + Self.pitch, p[1])
            y += Self.pitch * 3
        }
        #expect(Self.lines(items) == Self.stacked(Self.pairs))
    }

    @Test("a lonely right-aligned page number does not create a column")
    func pageNumber() {
        var items = Self.pairs.flatMap { $0 }.enumerated().flatMap { i, t in Self.words(40, 100 + Double(i) * Self.pitch, t) }
        items += Self.words(500, 100 + 14 * Self.pitch, "12")
        let lines = Self.lines(items)
        #expect(Array(lines.prefix(12)) == Self.pairs.flatMap { $0 })
        #expect(lines.last == "12")
    }

    @Test("a larger heading font does not split or merge rows")
    func largerHeading() {
        let items = Self.words(40, 60, "Vocabulaire", cw: 12, h: 24) + Self.table(Array(Self.pairs.prefix(4)), [40, 260], y0: 100)
        #expect(Self.lines(items) == ["Vocabulaire", ""] + Self.tabbed(Array(Self.pairs.prefix(4))))
    }

    @Test("yTolerance controls row grouping")
    func yTolerance() {
        let items = [Self.run(10, 100, "le nom"), Self.run(200, 104, "der Name"), Self.run(10, 118, "la rue"), Self.run(200, 122, "die Strasse")]
        #expect(Self.lines(items) == ["le nom\tder Name", "la rue\tdie Strasse"])
        #expect(Self.lines(items, LayoutOptions(yTolerance: 0.2)) == ["le nom", "der Name", "la rue", "die Strasse"])
    }

    // MARK: Skew

    @Test("estimateSlope uses the median of long baselines")
    func estimateSlope() {
        let segs = [
            BaselineSegment(x0: 0, y0: 100, x1: 400, y1: 108),
            BaselineSegment(x0: 0, y0: 200, x1: 400, y1: 208.4),
            BaselineSegment(x0: 0, y0: 300, x1: 400, y1: 307.6),
            BaselineSegment(x0: 0, y0: 10, x1: 10, y1: 30), // too short
        ]
        #expect(abs(TextLayout.estimateSlope(segs) - 0.02) < 1e-9)
        #expect(TextLayout.estimateSlope([]) == 0)
    }

    @Test("deskewItems straightens rotated rows")
    func deskew() {
        let slope = 0.06 // ≈ 3.4°, too much for plain row grouping
        let flat = Self.table(Self.pairs, [40, 400], pitch: 24, perWord: true)
        let skewed = flat.map { it in
            var it = it
            it.y += it.x * slope
            return it
        }
        #expect(Self.lines(skewed) != Self.tabbed(Self.pairs))
        #expect(Self.lines(TextLayout.deskewItems(skewed, slope: slope)) == Self.tabbed(Self.pairs))
    }

    @Test("deskewItems is a no-op for tiny or invalid slopes")
    func deskewNoOp() {
        let items = Self.words(10, 10, "la rue")
        #expect(TextLayout.deskewItems(items, slope: 0) == items)
        #expect(TextLayout.deskewItems(items, slope: .nan) == items)
        #expect(TextLayout.deskewItems([], slope: 0.1).isEmpty)
    }

    // MARK: Review regressions

    static let rows22: [[String]] = [
        ["avoir lieu", "stattfinden"],
        ["le chat", "die Katze"],
        ["le chien", "der Hund"],
        ["manger", "essen"],
        ["boire", "trinken"],
    ]

    @Test("a row whose term and definition both wrap stays one entry")
    func bothWrap() {
        // Continuation line 14 below its row; table rows 22 apart.
        var items = [Self.run(50, 100, "s'entendre bien avec"), Self.run(260, 100, "sich mit jdm gut"),
                     Self.run(50, 114, "qn"), Self.run(260, 114, "verstehen")]
        for (i, p) in Self.rows22.enumerated() {
            items += [Self.run(50, 136 + Double(i) * 22, p[0]), Self.run(260, 136 + Double(i) * 22, p[1])]
        }
        #expect(Self.lines(items) == ["s'entendre bien avec qn\tsich mit jdm gut verstehen"] + Self.tabbed(Self.rows22))
    }

    @Test("lowercase rows at a slightly uneven pitch are not merged")
    func unevenPitch() {
        let verbs = [["manger", "essen"], ["boire", "trinken"], ["dormir", "schlafen"], ["parler", "sprechen"],
                     ["lire", "lesen"], ["écrire", "schreiben"]]
        let ys: [Double] = [100, 122, 141, 163, 185, 207]
        let items = verbs.enumerated().flatMap { i, p in [Self.run(50, ys[i], p[0]), Self.run(260, ys[i], p[1])] }
        #expect(Self.lines(items) == Self.tabbed(verbs))
    }

    @Test("two page columns of \"term – definition\" entries become one line per row")
    func entryColumns() {
        let left = Self.pairs + Self.more.prefix(2)
        let right = Self.more.dropFirst(2) + [["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"]]
        var items: [TextItem] = []
        for (i, p) in left.enumerated() { items.append(Self.run(50, 100 + Double(i) * Self.pitch, "\(p[0]) – \(p[1])")) }
        for (i, p) in right.enumerated() { items.append(Self.run(320, 100 + Double(i) * Self.pitch, "\(p[0]) – \(p[1])")) }
        let lines = Self.lines(items)
        #expect(lines.first == "\(left[0][0]) – \(left[0][1])\t\(right[right.startIndex][0]) – \(right[right.startIndex][1])")
        // The JS reference output (parseVocab then reads one card per entry, left column first).
        #expect(lines == [
            "le monsieur, messieurs – der Herr\tle nom – der Name",
            "l'homme – der Mann\tle prénom – der Vorname",
            "la femme – die Frau\tla rue – die Strasse",
            "l'enfant – das Kind\tle chat – die Katze",
            "le garçon – der Junge\tle chien – der Hund",
            "la fille – das Mädchen\tla vache – die Kuh",
            "appeler – nennen\tle cheval – das Pferd",
            "s'appeler – heissen",
        ])
    }

    @Test("a right page column that ends early keeps its rows next to the left ones", arguments: [6, 5, 3, 1])
    func rightColumnEndsEarly(k: Int) {
        let left = Self.pairs + Self.more.prefix(4)
        let right = [["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"],
                     ["la souris", "die Maus"], ["le cochon", "das Schwein"]]
        var items: [TextItem] = []
        for (i, p) in left.enumerated() { items.append(Self.run(50, 100 + Double(i) * Self.pitch, "\(p[0]) – \(p[1])")) }
        for (i, p) in right.prefix(k).enumerated() { items.append(Self.run(320, 100 + Double(i) * Self.pitch, "\(p[0]) – \(p[1])")) }
        let expected = left.enumerated().map { i, p in
            "\(p[0]) – \(p[1])" + (i < k ? "\t\(right[i][0]) – \(right[i][1])" : "")
        }
        #expect(Self.lines(items) == expected)
    }

    // MARK: Lenient JSON (readItems / opts / segments)

    @Test("TextItem(json:) reads items like readItems")
    func itemJSON() throws {
        let item = try #require(TextItem(json: ["str": 42, "x": "120", "y": " 200.5px", "w": "12", "h": "abc"]))
        #expect(item == TextItem(str: "42", x: 120, y: 200.5, w: 12, h: 0))
        #expect(TextItem(json: ["str": true, "x": 1, "y": "1e2"]) == TextItem(str: "true", x: 1, y: 100))
        #expect(TextItem(json: ["str": ["a", .null, 1], "x": 0, "y": 0])?.str == "a,,1")
        #expect(TextItem(json: ["str": [:], "x": 0, "y": 0])?.str == "[object Object]")
        #expect(TextItem(json: .null) == nil)
        #expect(TextItem(json: "le chat") == nil)
        #expect(TextItem(json: ["x": 1, "y": 1]) == nil)
        #expect(TextItem(json: ["str": .null, "x": 1, "y": 1]) == nil)
        #expect(TextItem(json: ["str": "x", "x": "abc", "y": 1]) == nil)
        #expect(TextItem(json: ["str": "x", "x": "Infinity", "y": 1]) == nil)
        #expect(TextItem(json: ["str": "x", "x": 1]) == nil)
    }

    @Test("TextItem decodes leniently")
    func itemDecoding() throws {
        let data = Data(#"[{"str":"le nom","x":"10","y":20,"w":null},{"x":5}]"#.utf8)
        let items = try JSONDecoder().decode([TextItem].self, from: data)
        #expect(items == [TextItem(str: "le nom", x: 10, y: 20), TextItem(str: "", x: 5, y: 0)])
        let encoded = try JSONEncoder().encode(items[0])
        #expect(try JSONDecoder().decode(TextItem.self, from: encoded) == items[0])
    }

    @Test("LayoutOptions(json:) and BaselineSegment(json:) follow the JS defaults")
    func optionsAndSegments() {
        #expect(LayoutOptions(json: ["yTolerance": "0.2", "gapFactor": 4]) == LayoutOptions(yTolerance: 0.2, gapFactor: 4))
        #expect(LayoutOptions(json: ["yTolerance": "abc", "gapFactor": .null]) == LayoutOptions())
        #expect(LayoutOptions(json: "opts") == LayoutOptions())
        #expect(BaselineSegment(json: ["x0": 0, "y0": "1", "x1": 2.5, "y1": 3]) == BaselineSegment(x0: 0, y0: 1, x1: 2.5, y1: 3))
        #expect(BaselineSegment(json: ["x0": 0, "y0": 1, "x1": 2]) == nil)
        #expect(BaselineSegment(json: .null) == nil)
    }

    @Test("estimateSlope skips segments with non-finite coordinates")
    func nonFiniteSegments() {
        let segs = [BaselineSegment(x0: 0, y0: 0, x1: .nan, y1: 4), BaselineSegment(x0: 0, y0: 0, x1: 100, y1: 1)]
        #expect(TextLayout.estimateSlope(segs) == 0.01)
        #expect(TextLayout.estimateSlope(segs, minWidth: 200) == 0)
    }

    @Test("deskewItems keeps items with non-finite positions unchanged")
    func deskewNonFinite() {
        let odd = TextItem(str: "x", x: .infinity, y: 3, w: 1, h: 1)
        let out = TextLayout.deskewItems([odd, TextItem(str: "y", x: 10, y: 0)], slope: 0.1)
        #expect(out[0] == odd)
        #expect(abs(out[1].x - 10 * cos(atan(0.1))) < 1e-12)
        #expect(abs(out[1].y + 10 * sin(atan(0.1))) < 1e-12)
    }
}
