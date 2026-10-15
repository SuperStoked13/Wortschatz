import Foundation
import Testing
import WortschatzCore

// Port of the right-to-left (Arabic) and Chinese part of tests/layout.test.js and of the pdf.js
// direction tests of tests/pdf.test.js (as layout items).

@Suite("TextLayout: right-to-left text and Chinese")
struct TextLayoutScriptsTests {
    typealias T = TextLayoutTests

    /// One item per word of a right-to-left phrase (logical order) whose right edge is at x1.
    static func rtlWords(_ x1: Double, _ y: Double, _ text: String, cw: Double = T.cw, h: Double = T.h) -> [TextItem] {
        var out: [TextItem] = []
        var cx = x1
        for w in text.components(separatedBy: " ") {
            let length = Double(w.utf16.count)
            cx -= length * cw
            out.append(TextItem(str: w, x: cx, y: y, w: length * cw, h: h))
            cx -= cw
        }
        return out
    }

    static let arRows: [(de: String, ar: String)] = [
        ("die alte Stadt", "المدينة القديمة"),
        ("der grosse Junge", "الولد الكبير"),
        ("das Buch", "الكتاب"),
        ("die Schule", "المدرسة"),
        ("der Lehrer", "المعلم"),
    ]

    static func lines(_ items: [TextItem]) -> [String] { TextLayout.itemsToLines(items) }

    @Test("the words of a right-to-left cell are read from right to left")
    func rtlCell() {
        #expect(Self.lines(Self.rtlWords(300, 100, "ذهب الولد إلى المدرسة")) == ["ذهب الولد إلى المدرسة"])
        // Mostly Arabic letters with a Latin word: still right to left.
        #expect(Self.lines(Self.rtlWords(300, 100, "الكتاب الجديد CD")) == ["الكتاب الجديد CD"])
        // Mostly Latin letters with an Arabic word: left to right.
        #expect(Self.lines(T.words(50, 100, "das Wort كتاب heisst Buch")) == ["das Wort كتاب heisst Buch"])
    }

    @Test("a right-aligned Arabic column is a column of its own, read right to left")
    func rightAlignedColumn() {
        var items: [TextItem] = []
        for (r, row) in Self.arRows.enumerated() {
            let y = 100 + Double(r) * T.pitch
            items += T.words(50, y, row.de)
            items += Self.rtlWords(400, y, row.ar)
        }
        #expect(Self.lines(items) == Self.arRows.map { "\($0.de)\t\($0.ar)" })
        // A long Arabic cell reaching into the gutter belongs to the column of its right edge.
        let long = "المدينة القديمة الجميلة جدا في الشمال"
        let items2 = items.filter { $0.y != 100 || $0.x < 200 } + Self.rtlWords(400, 100, long)
        #expect(Self.lines(items2).first == "die alte Stadt\t\(long)")
    }

    @Test("an Arabic column on the left (right-aligned) and a German column")
    func arabicLeftColumn() {
        var items: [TextItem] = []
        for (r, row) in Self.arRows.enumerated() {
            let y = 100 + Double(r) * T.pitch
            items += Self.rtlWords(200, y, row.ar)
            items += T.words(260, y, row.de)
        }
        #expect(Self.lines(T.shuffled(items)) == Self.arRows.map { "\($0.ar)\t\($0.de)" })
    }

    @Test("pdf.js right-to-left runs (dir rtl) keep their logical text")
    func rtlRuns() {
        var items: [TextItem] = []
        for (r, row) in Self.arRows.enumerated() {
            let y = 100 + Double(r) * T.pitch
            items.append(T.run(50, y, row.de))
            var ar = T.run(400 - Double(row.ar.utf16.count) * T.cw, y, row.ar)
            ar.dir = "rtl"
            items.append(ar)
        }
        #expect(Self.lines(items) == Self.arRows.map { "\($0.de)\t\($0.ar)" })
        // Several runs of one cell are joined right to left.
        let two = [
            TextItem(str: "المدينة", x: 400 - 7 * T.cw, y: 100, w: 7 * T.cw, h: T.h, dir: "rtl"),
            TextItem(str: "القديمة", x: 400 - 15 * T.cw, y: 100, w: 7 * T.cw, h: T.h, dir: "rtl"),
        ]
        #expect(Self.lines(two) == ["المدينة القديمة"])
        // A wide gap inside one rtl run: the first logical piece is the right one.
        #expect(Self.lines([TextItem(str: "كتاب    قلم", x: 100, y: 100, w: 11 * T.cw, h: T.h, dir: "rtl")]) == ["قلم\tكتاب"])
        #expect(Self.lines([TextItem(str: "كتاب    قلم", x: 100, y: 100, w: 11 * T.cw, h: T.h)]) == ["كتاب\tقلم"])
        // Only "rtl" counts as right to left.
        #expect(Self.lines([TextItem(str: "كتاب    قلم", x: 100, y: 100, w: 11 * T.cw, h: T.h, dir: "ltr")]) == ["كتاب\tقلم"])
    }

    @Test("pdf.test.js: an Arabic cell drawn as several runs is read from right to left")
    func pdfRuns() {
        // pdf.test.js item(str, x, y, 'rtl'): 6 units per character, rtl runs end at x (viewport flips y).
        func item(_ str: String, _ x: Double, _ y: Double, rtl: Bool = false) -> TextItem {
            let width = Double(str.utf16.count) * 6
            return TextItem(str: str, x: rtl ? x - width : x, y: 800 - y, w: width, h: 12, dir: rtl ? "rtl" : "ltr")
        }
        let rows = Array(Self.arRows.prefix(4))
        var items = [item("die alte Stadt", 50, 700), item("المدينة", 400, 700, rtl: true), item("القديمة", 400 - 8 * 6, 700, rtl: true)]
        for (k, row) in rows.enumerated().dropFirst() {
            items += [item(row.de, 50, 700 - Double(k) * 20), item(row.ar, 400, 700 - Double(k) * 20, rtl: true)]
        }
        let lines = Self.lines(items)
        #expect(lines.first == "die alte Stadt\tالمدينة القديمة")
        #expect(lines == rows.map { "\($0.de)\t\($0.ar)" })
    }

    @Test("Han characters are joined without spaces")
    func hanJoining() {
        let hw = 12.0 // a Han character is about twice as wide
        func han(_ x: Double, _ y: Double, _ s: String, trail: Bool = true) -> TextItem {
            TextItem(str: trail ? "\(s) " : s, x: x, y: y, w: Double(s.utf16.count + (trail ? 1 : 0)) * hw, h: T.h)
        }
        // OCR words with trailing spaces, and fragments further apart than a space.
        #expect(Self.lines([han(100, 100, "你"), han(114, 100, "好"), han(128, 100, "朋友")]) == ["你好朋友"])
        #expect(Self.lines([han(100, 100, "你好", trail: false), han(130, 100, "朋友", trail: false)]) == ["你好朋友"])
        // Pinyin and other words keep their spaces.
        #expect(Self.lines([han(100, 100, "你好")] + T.words(130, 100, "nǐ hǎo")) == ["你好 nǐ hǎo"])
        // A wrapped Chinese definition continues without a space.
        var t: [TextItem] = []
        let rows = [("Hallo", "你好"), ("danke", "谢谢"), ("auf Wiedersehen", "再见"), ("", "朋友"), ("die Schule", "学校")]
        for (r, row) in rows.enumerated() {
            let y = 100 + Double(r) * T.pitch
            if !row.0.isEmpty { t.append(T.run(50, y, row.0)) }
            t.append(TextItem(str: row.1, x: 300, y: y, w: Double(row.1.utf16.count) * hw, h: T.h))
        }
        #expect(Self.lines(t) == ["Hallo\t你好", "danke\t谢谢", "auf Wiedersehen\t再见朋友", "die Schule\t学校"])
        // Astral Han characters (Extension B) join too.
        #expect(Self.lines([han(100, 100, "𠀀"), han(124, 100, "𠀁")]) == ["𠀀𠀁"])
    }

    @Test("isRtlText: more than half of the letters are right-to-left")
    func rtlText() {
        #expect(TextLayout.isRtlText("كتاب"))
        #expect(TextLayout.isRtlText("שלום"))
        #expect(TextLayout.isRtlText("الكتاب الجديد CD"))
        #expect(!TextLayout.isRtlText("das Wort كتاب heisst Buch"))
        #expect(!TextLayout.isRtlText("ab كت")) // a tie is left to right
        #expect(!TextLayout.isRtlText("١٢٣ ،")) // digits and punctuation are no letters
        #expect(!TextLayout.isRtlText(""))
    }

    @Test("TextItem keeps dir through JSON and leaves it out when absent")
    func dirCoding() throws {
        let item = TextItem(str: "كتاب", x: 1, y: 2, w: 3, h: 4, dir: "rtl")
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(TextItem.self, from: data) == item)
        #expect(item.isRightToLeft)
        let plain = try JSONEncoder().encode(TextItem(str: "x", x: 1, y: 2))
        #expect(!String(decoding: plain, as: UTF8.self).contains("dir"))
        #expect(TextItem(json: ["str": "x", "x": 1, "y": 2, "dir": "rtl"])?.isRightToLeft == true)
        #expect(TextItem(json: ["str": "x", "x": 1, "y": 2, "dir": 1])?.dir == nil)
        // deskewItems keeps the direction like the JS spread.
        #expect(TextLayout.deskewItems([item], slope: 0.1)[0].dir == "rtl")
    }
}
