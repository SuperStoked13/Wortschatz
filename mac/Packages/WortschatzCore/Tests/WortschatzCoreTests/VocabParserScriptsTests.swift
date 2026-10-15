import Foundation
import Testing
@testable import WortschatzCore

// Port of the Arabic and Chinese part of tests/parser.test.js. Every input is also replayed field
// by field against the JS reference in VocabParserParityTests (Fixtures/parser.json).

private func parse(_ text: String?, _ options: ParseOptions = ParseOptions()) -> ParseResult {
    VocabParser.parseVocab(text, options: options)
}

private func pairs(_ r: ParseResult) -> [[String]] { r.cards.map { [$0.term, $0.definition] } }

private func flagged(_ r: ParseResult) -> [String] {
    r.cards.filter { !$0.flags.isEmpty }.map { "\($0.term): \($0.flags.map(\.rawValue))" }
}

/// JS `checkFixture(name, n, format, delimiter, termLang, defLang, swapped, some)`.
@discardableResult
private func checkFixture(
    _ name: String, _ n: Int, _ format: ParseFormat, _ delimiter: String?, _ termLang: Lang, _ defLang: Lang,
    _ swapped: Bool, _ some: [[String]], sourceLocation: SourceLocation = #_sourceLocation
) -> ParseResult {
    let r = parse(VocabParserWebFixtures.read(name))
    #expect(r.cards.count == n, "\(name)", sourceLocation: sourceLocation)
    #expect(r.format == format, "\(name)", sourceLocation: sourceLocation)
    #expect(r.delimiter == delimiter, "\(name)", sourceLocation: sourceLocation)
    #expect(r.termLang == termLang && r.defLang == defLang, "\(name): \(r.termLang)/\(r.defLang)", sourceLocation: sourceLocation)
    #expect(r.swapped == swapped, "\(name)", sourceLocation: sourceLocation)
    let all = pairs(r)
    for p in some { #expect(all.contains(p), "\(name) lacks \(p)", sourceLocation: sourceLocation) }
    return r
}

@Suite("VocabParser: Arabic and Chinese")
struct VocabParserScriptsTests {
    @Test("fixture: arabic-german.txt (Arabic kept as written, header and page number skipped)")
    func arabicFixture() {
        let r = checkFixture("arabic-german.txt", 13, .delimited, " - ", .ar, .de, false, [
            ["الكتاب", "das Buch"],
            ["مَدْرَسَة", "die Schule"], // vowel marks stay
            ["المعلّم", "der Lehrer"],
            ["سيارة، عربية", "das Auto"], // the Arabic comma separates alternatives, not the sides
            ["مع السلامة", "auf Wiedersehen"],
        ])
        #expect(r.skipped.map(\.reason) == [.heading, .pageNumber])
        #expect(flagged(r) == [])
    }

    @Test("fixture: chinese-german.txt (characters | pinyin | German become one card per row)")
    func chineseFixture() {
        let r = checkFixture("chinese-german.txt", 10, .delimited, "\t", .zh, .de, false, [
            ["你好 (nǐ hǎo)", "hallo"],
            ["老师 (lǎoshī)", "der Lehrer, die Lehrerin"],
            ["中国 (Zhōngguó)", "China"],
            ["我是学生。 (Wǒ shì xuésheng.)", "Ich bin Schüler."],
        ])
        // "中文 Pinyin Deutsch" is a header row.
        #expect(r.skipped == [SkippedLine(line: 1, text: "中文 Pinyin Deutsch", reason: .heading)])
        #expect(flagged(r) == [])
    }

    @Test("fixture: chinese-dash.txt (closing bracket glued to the dash)")
    func chineseDashFixture() {
        let r = checkFixture("chinese-dash.txt", 9, .delimited, " - ", .zh, .de, false, [
            ["你好（nǐ hǎo）", "Hallo"], // full-width brackets stay as written
            ["不客气（bú kèqi）", "bitte, gern geschehen"],
            ["早上好 (zǎoshang hǎo)", "guten Morgen"],
            ["晚安 (wǎn'ān)", "gute Nacht"],
            ["不 (bù)", "nein, nicht"],
        ])
        #expect(r.skipped == [SkippedLine(line: 1, text: "Chinesisch - Deutsch", reason: .heading)])
    }

    @Test("Chinese: a closing bracket glued to a spaced dash (hyphen, en dash, full-width or ASCII)",
          arguments: [("你好（nǐ hǎo）- Hallo", "你好（nǐ hǎo）"), ("你好（nǐ hǎo）– Hallo", "你好（nǐ hǎo）"), ("你好 (nǐ hǎo)- Hallo", "你好 (nǐ hǎo)")])
    func bracketDash(text: String, term: String) {
        let r = parse(text)
        #expect(pairs(r) == [[term, "Hallo"]], "\(text)")
        #expect(r.termLang == .zh)
    }

    @Test("Chinese: an en dash glued on both sides works like in Latin lists")
    func gluedEnDash() {
        #expect(pairs(parse("你好（nǐ hǎo）–Hallo\n谢谢（xièxie）–danke")) == [["你好（nǐ hǎo）", "Hallo"], ["谢谢（xièxie）", "danke"]])
    }

    @Test("Chinese: the full-width colon separates like \":\"")
    func fullWidthColon() {
        let r = parse("你好：Hallo\n谢谢：danke\n再见： auf Wiedersehen")
        #expect(pairs(r) == [["你好", "Hallo"], ["谢谢", "danke"], ["再见", "auf Wiedersehen"]])
        #expect(r.delimiter == ": ")
        #expect(r.termLang == .zh && r.defLang == .de)
        // A colon inside a side keeps its full-width form.
        #expect(pairs(parse("注意：小心 - Achtung\n你好 - Hallo")).first == ["注意：小心", "Achtung"])
        // In the explicit delimiter mode "：" is an ordinary custom delimiter.
        let custom = parse("你好：Hallo", ParseOptions(mode: .delimiter, delimiter: "："))
        #expect(pairs(custom) == [["你好", "Hallo"]])
    }

    @Test("Chinese: characters and pinyin cells in any order beside each other are merged")
    func hanPinyinMerge() {
        let expected = [["你好 (nǐ hǎo)", "Hallo"], ["谢谢 (xièxie)", "danke"], ["再见 (zàijiàn)", "auf Wiedersehen"]]
        #expect(pairs(parse("nǐ hǎo\t你好\tHallo\nxièxie\t谢谢\tdanke\nzàijiàn\t再见\tauf Wiedersehen")) == expected)
        #expect(pairs(parse("你好 - nǐ hǎo - Hallo\n谢谢 - xièxie - danke\n再见 - zàijiàn - auf Wiedersehen")) == expected)
        // German first: the merged side is turned to the term side.
        let de = parse("Hallo\t你好\tnǐ hǎo\ndanke\t谢谢\txièxie\nauf Wiedersehen\t再见\tzàijiàn")
        #expect(pairs(de) == expected)
        #expect(de.swapped)
        // Tone numbers, toneless pinyin, brackets already around the pinyin, a single row.
        #expect(pairs(parse("你好\tni3 hao3\tHallo\n谢谢\txie4xie5\tdanke")) == [["你好 (ni3 hao3)", "Hallo"], ["谢谢 (xie4xie5)", "danke"]])
        #expect(pairs(parse("你好\tni hao\tHallo\n谢谢\txiexie\tdanke")) == [["你好 (ni hao)", "Hallo"], ["谢谢 (xiexie)", "danke"]])
        #expect(pairs(parse("你好\t(nǐ hǎo)\tHallo\n谢谢\t（xièxie）\tdanke")) == [["你好 (nǐ hǎo)", "Hallo"], ["谢谢 (xièxie)", "danke"]])
        #expect(pairs(parse("你好\tnǐ hǎo\tHallo")) == [["你好 (nǐ hǎo)", "Hallo"]])
    }

    @Test("Chinese: a third column that is not pinyin is not merged")
    func noMerge() {
        // Characters | German | English: no pinyin column.
        let r = parse("你好\tHallo\thello\n谢谢\tdanke\tthank you\n再见\tauf Wiedersehen\tgoodbye")
        for c in r.cards { #expect(!c.term.contains(" ("), "\(c.term)") }
        // Two cells stay as they are.
        #expect(pairs(parse("你好\tHallo\n谢谢\tdanke")) == [["你好", "Hallo"], ["谢谢", "danke"]])
        #expect(pairs(parse("你好 nǐ hǎo\tHallo\n谢谢 xièxie\tdanke")) == [["你好 nǐ hǎo", "Hallo"], ["谢谢 xièxie", "danke"]])
    }

    @Test("Chinese and Arabic lists in other layouts")
    func otherLayouts() {
        let alt = parse("你好\nHallo\n谢谢\ndanke\n再见\nauf Wiedersehen")
        #expect(pairs(alt) == [["你好", "Hallo"], ["谢谢", "danke"], ["再见", "auf Wiedersehen"]])
        #expect(alt.termLang == .zh && alt.defLang == .de)
        let ar = parse("كتاب\nBuch\nقلم\nStift\nبيت\nHaus")
        #expect(pairs(ar) == [["كتاب", "Buch"], ["قلم", "Stift"], ["بيت", "Haus"]])
        #expect(ar.termLang == .ar && ar.defLang == .de)
        // Both languages on a line without a delimiter: cut at the script boundary.
        let bilingual = parse("كتاب Buch\nقلم Stift\nبيت Haus\nمدرسة Schule")
        #expect(pairs(bilingual) == [["كتاب", "Buch"], ["قلم", "Stift"], ["بيت", "Haus"], ["مدرسة", "Schule"]])
        // German first is turned around.
        let de = parse("Buch = كتاب\nStift = قلم\nHaus = بيت")
        #expect(pairs(de) == [["كتاب", "Buch"], ["قلم", "Stift"], ["بيت", "Haus"]])
        #expect(de.swapped)
    }

    @Test("Arabic text is stored as written: vowel marks, tatweel and presentation forms stay, bidi marks go")
    func arabicAsWritten() {
        let r = parse("الْكِتَابُ = das Buch\nكـتـاب = Buch\nﻛﺘﺎﺏ = Buch")
        // Compare code points: Swift's == would also accept canonically equivalent text.
        #expect(r.cards.map { Array($0.term.unicodeScalars) } == ["الْكِتَابُ", "كـتـاب", "ﻛﺘﺎﺏ"].map { Array($0.unicodeScalars) })
        #expect(r.cards.map(\.definition) == ["das Buch", "Buch", "Buch"])
        for mark in ["\u{200F}", "\u{200E}", "\u{61C}", "\u{202B}", "\u{2067}"] {
            let p = parse("\(mark)كتاب\(mark) = Buch\nقلم = Stift")
            #expect(p.cards.map { Array($0.term.unicodeScalars) } == [Array("كتاب".unicodeScalars), Array("قلم".unicodeScalars)])
        }
    }

    @Test("header rows name Arabic", arguments: ["Arabisch - Deutsch\nكتاب - Buch", "العربية | Deutsch\nكتاب | Buch",
                                               "AR ; DE\nكتاب ; Buch", "arabe = allemand\nكتاب = Buch"])
    func arabicHeaders(text: String) {
        let r = parse(text)
        #expect(r.skipped.map(\.reason) == [.heading], "\(text)")
        #expect(pairs(r) == [["كتاب", "Buch"]], "\(text)")
    }

    @Test("header rows name Chinese", arguments: ["Chinesisch - Deutsch", "中文 - Deutsch", "Mandarin - Deutsch", "ZH - DE",
                                                 "汉语 - Deutsch", "普通話 - Deutsch"])
    func chineseHeaders(header: String) {
        let r = parse("\(header)\n你好 - Hallo\n谢谢 - danke")
        #expect(r.skipped.map(\.reason) == [.heading], "\(header)")
        #expect(pairs(r) == [["你好", "Hallo"], ["谢谢", "danke"]])
    }

    @Test("Names of one language on both sides are a card, not a header")
    func sameLanguageNames() {
        #expect(pairs(parse("chinois - Chinesisch")) == [["chinois", "Chinesisch"]])
        #expect(pairs(parse("arabe - Arabisch")) == [["arabe", "Arabisch"]])
    }

    @Test("ar and zh are accepted as language hints", arguments: [Lang.ar, Lang.zh])
    func hints(lang: Lang) {
        let empty = parse("", ParseOptions(termLang: lang, defLang: .de))
        #expect(empty.termLang == lang && empty.defLang == .de)
        #expect(parse("", ParseOptions(termLang: .fr, defLang: lang)).defLang == lang)
        // The JSON options of the web app accept the codes too.
        let json = ParseOptions(json: .object(["termLang": .string(lang.rawValue), "defLang": .string("de")]))
        #expect(json.termLang == lang)
    }

    @Test("Pinyin without tone marks looks Romance; picked as Chinese it is Chinese")
    func pinyinHint() {
        let text = "ni hao - Hallo\nxiexie - danke\nzaijian - auf Wiedersehen"
        let r = parse(text, ParseOptions(termLang: .zh))
        #expect(r.termLang == .zh && r.defLang == .de)
        #expect(pairs(r) == [["ni hao", "Hallo"], ["xiexie", "danke"], ["zaijian", "auf Wiedersehen"]])
        // Without the hint the detection decides.
        #expect(parse(text).termLang != .zh)
        // Pinyin with tone marks needs no hint.
        #expect(parse("nǐ hǎo - Hallo\nduìbuqǐ - Entschuldigung\nlǎoshī - der Lehrer").termLang == .zh)
    }

    // MARK: Helpers

    @Test("spaceBracketDash spaces a glued closing bracket only on Arabic or Chinese lines")
    func spaceBracketDashRule() {
        typealias P = VocabParser.PText
        #expect(VocabParser.spaceBracketDash("你好（nǐ hǎo）- Hallo") == P("你好（nǐ hǎo） - Hallo"))
        #expect(VocabParser.spaceBracketDash("你好 (nǐ hǎo)– Hallo") == P("你好 (nǐ hǎo) – Hallo"))
        #expect(VocabParser.spaceBracketDash("كتاب (m)—\u{A0}Buch") == P("كتاب (m) —\u{A0}Buch"))
        #expect(VocabParser.spaceBracketDash("你好（nǐ）-\u{3000}Hallo") == P("你好（nǐ） -\u{3000}Hallo"))
        // Every glued bracket of the line.
        #expect(VocabParser.spaceBracketDash("你(a)- 好(b)- c") == P("你(a) - 好(b) - c"))
        // Not without a space after the dash, not with a tab or another spaced dash, not on Latin lines.
        #expect(VocabParser.spaceBracketDash("你好（nǐ）-Hallo") == P("你好（nǐ）-Hallo"))
        #expect(VocabParser.spaceBracketDash("你好（nǐ）- Hallo\tx") == P("你好（nǐ）- Hallo\tx"))
        #expect(VocabParser.spaceBracketDash("你好（nǐ）- Hallo - x") == P("你好（nǐ）- Hallo - x"))
        #expect(VocabParser.spaceBracketDash("le chat (m)- Katze") == P("le chat (m)- Katze"))
        // Known delimiter that is not a dash: nothing is rewritten.
        #expect(VocabParser.spaceGluedDashes(["你好（nǐ）- Hallo"], dashList: false) == [P("你好（nǐ）- Hallo")])
        #expect(VocabParser.spaceGluedDashes(["你好（nǐ）- Hallo"], dashList: true) == [P("你好（nǐ） - Hallo")])
    }

    @Test("isPinyinWord accepts syllables with tone marks, tone numbers or none")
    func pinyinWords() {
        typealias P = VocabParser.PText
        for w in ["nǐ", "hǎo", "Zhōngguó", "xī'ān", "xī’ān", "ni3hao3", "nihao", "lǜ", "lv4", "nüe", "er", "ér", "zhuang",
                  "XIÈXIE", "ê", "shuǐ", "duìbuqǐ", "n\u{30C}i", "lu\u{308}\u{300}"] {
            #expect(VocabParser.isPinyinWord(P(w)), "\(w)")
        }
        for w in ["hallo", "Buch", "der", "chat", "ni6", "x", "", "''", "123", "straße", "zhuangg", "你好"] {
            #expect(!VocabParser.isPinyinWord(P(w)), "\(w)")
        }
    }

    @Test("isPinyinCell, isHanCell and unbracket")
    func pinyinCells() {
        typealias P = VocabParser.PText
        #expect(VocabParser.isPinyinCell("nǐ hǎo"))
        #expect(VocabParser.isPinyinCell("（xièxie）"))
        #expect(VocabParser.isPinyinCell("(Wǒ shì xuésheng.)"))
        #expect(VocabParser.isPinyinCell("ni3, hao3; xie-xie / zai4jian4"))
        #expect(!VocabParser.isPinyinCell("你好 nǐ hǎo"))
        #expect(!VocabParser.isPinyinCell("der Lehrer"))
        #expect(!VocabParser.isPinyinCell("123"))
        #expect(!VocabParser.isPinyinCell("()"))
        #expect(VocabParser.isHanCell("我是学生。"))
        #expect(!VocabParser.isHanCell("你好 nǐ"))
        #expect(!VocabParser.isHanCell("Hallo"))
        #expect(VocabParser.unbracket("( nǐ hǎo )") == P("nǐ hǎo"))
        #expect(VocabParser.unbracket("（nǐ)") == P("nǐ"))
        #expect(VocabParser.unbracket("(a (b))") == P("(a (b))"))
        #expect(VocabParser.unbracket("nǐ") == P("nǐ"))
        #expect(VocabParser.unbracket("(") == P("("))
    }
}
