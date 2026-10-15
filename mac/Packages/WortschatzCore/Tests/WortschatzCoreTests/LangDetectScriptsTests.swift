import Testing
import WortschatzCore

// Port of the Arabic and Chinese part of tests/langdetect.test.js: both are recognised by their
// script (and pinyin by its tone marks); results for Latin-script text stay as with five languages.

@Suite("LangDetect: Arabic and Chinese")
struct LangDetectScriptsTests {
    private static let latin: [Lang] = [.fr, .de, .en, .es, .it]

    private static func latinScores(_ text: String) -> [Double] {
        let s = LangDetect.scoreLanguages(text)
        return latin.map { s[$0] ?? -1 }
    }

    private static func score(_ text: String, _ lang: Lang) -> Double { LangDetect.scoreLanguages(text)[lang] ?? -1 }

    private static func lang(_ text: String) -> DetectedLanguage { LangDetect.detectLanguage(text).lang }

    /// `text.split('\n').filter((l) => l.trim())` of a web fixture.
    private static func contentLines(_ name: String) -> [String] {
        LangDetectWebFixtures.read(name).unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
            .filter { !JSCompat.trim($0).isEmpty }
    }

    @Test("Arabic words are Arabic and give no Latin evidence",
          arguments: ["كتاب", "مدرسة", "الكتاب", "مرحبا", "مع السلامة", "سيارة، عربية"])
    func arabicWords(word: String) {
        #expect(Self.latinScores(word) == [0, 0, 0, 0, 0], "\(word)")
        #expect(Self.score(word, .ar) > 3)
        #expect(Self.score(word, .zh) == 0)
        let d = LangDetect.detectLanguage(word)
        #expect(d.lang == .ar, "\(word)")
        #expect(d.confidence > 0.85)
    }

    @Test("Every Arabic word counts")
    func arabicWordCount() {
        #expect(Self.score("مع السلامة", .ar) > Self.score("السلامة", .ar))
        #expect(Self.score("مع السلامة", .ar) == 8)
    }

    @Test("Arabic vowel marks, the tatweel and presentation forms do not change the evidence")
    func arabicMarks() {
        let plain = LangDetect.scoreLanguages("الكتاب")
        #expect(LangDetect.scoreLanguages("الْكِتَابُ") == plain) // harakat would otherwise split the word
        #expect(LangDetect.scoreLanguages("الكـتـاب") == plain)
        #expect(LangDetect.scoreLanguages("مَدْرَسَةٌ جَمِيلَةٌ") == LangDetect.scoreLanguages("مدرسة جميلة"))
        #expect(LangDetect.scoreLanguages("ﻛﺘﺎﺏ") == LangDetect.scoreLanguages("كتاب"))
        // Hamza above (U+0654, a variant mark for grading) does not split a word either.
        #expect(LangDetect.scoreLanguages("ب\u{654}ت") == LangDetect.scoreLanguages("بت"))
        #expect(Self.score("ب\u{654}ت", .ar) == 4)
    }

    @Test("Han runs are Chinese and give no Latin evidence", arguments: ["你好", "我是学生。", "谢谢", "中国", "书"])
    func hanRuns(word: String) {
        #expect(Self.latinScores(word) == [0, 0, 0, 0, 0], "\(word)")
        #expect(Self.score(word, .zh) > 3)
        #expect(Self.score(word, .ar) == 0)
        #expect(Self.lang(word) == .zh, "\(word)")
    }

    @Test("A run of characters is one piece of evidence; separate runs add up")
    func hanRunCount() {
        #expect(Self.score("我是学生", .zh) == Self.score("书", .zh))
        #expect(Self.score("你好，朋友", .zh) > Self.score("你好", .zh))
        // Characters outside the Basic Multilingual Plane (Extension B) are Han too.
        #expect(Self.score("𠀀𠀁", .zh) == 4)
    }

    @Test("pinyin tone marks are Chinese evidence",
          arguments: ["nǐ hǎo", "shuǐ", "lǎoshī", "duìbuqǐ", "Běijīng", "lǜ", "māma", "zǎoshang hǎo", "kāfēi"])
    func pinyinWords(word: String) {
        #expect(Self.lang(word) == .zh, "\(word)")
    }

    @Test("A pinyin word is pinyin as a whole; the caron counts more than the macron")
    func pinyinWeights() {
        // No Latin evidence for a word with a tone mark (shuǐ looks English).
        #expect(Self.latinScores("shuǐ") == [0, 0, 0, 0, 0])
        #expect(Self.score("hǎo", .zh) > Self.score("hē", .zh))
        #expect(Self.score("hǎo", .zh) == 3.5)
        #expect(Self.score("hē", .zh) == 2.8)
        #expect(Self.score("lǎoshī", .zh) == Self.score("hǎo", .zh))
        #expect(Self.score("nǐ hǎo", .zh) == 2 * Self.score("hǎo", .zh))
        #expect(Self.score("你好 (nǐ hǎo)", .zh) > Self.score("你好", .zh))
        #expect(Self.lang("你好 (nǐ hǎo)") == .zh)
        // Upper-case tone marks are lowercased first.
        #expect(Self.score("NǏ", .zh) == 3.5)
    }

    @Test("Latin-script text never gets Arabic or Chinese evidence",
          arguments: ["le chat", "die Katze", "the house", "el niño", "la città", "Straße", "œuvre", "xièxie", "ni3 hao3", "Москва"])
    func latinText(text: String) {
        #expect(Self.score(text, .ar) == 0, "\(text)")
        #expect(Self.score(text, .zh) == 0, "\(text)")
    }

    @Test("Without evidence Arabic and Chinese take no share of the probability")
    func noShare() {
        #expect(LangDetect.detectColumn(["le chat", "le chien", "la souris", "la maison"]).lang == .fr)
        #expect(LangDetect.detectLanguage("le chat").confidence > 0.99)
        #expect(LangDetect.detectColumn(["xyz"]).lang != .ar)
    }

    @Test("Mixed lines: script words skip the Latin signals, Latin words keep them")
    func mixedLines() {
        let s = LangDetect.scoreLanguages("كتاب Buch")
        #expect(s[.ar] == Self.score("كتاب", .ar))
        #expect((s[.de] ?? 0) > 3)
        // Han glued to Latin letters is cut at the script boundary.
        let g = LangDetect.scoreLanguages("你好Hallo")
        #expect(g[.zh] == Self.score("你好", .zh))
        #expect((g[.de] ?? 0) > 1)
        #expect(Self.lang("الكتاب - das Buch") != .unknown)
    }

    @Test("detectColumn: Arabic and Chinese columns")
    func columns() {
        let ar = LangDetect.detectColumn(["كتاب", "قلم", "بيت", "مدرسة", "المعلّم"])
        #expect(ar.lang == .ar)
        #expect(ar.confidence > 0.9)
        let zh = LangDetect.detectColumn(["你好", "谢谢", "再见", "学生", "朋友"])
        #expect(zh.lang == .zh)
        #expect(zh.confidence > 0.9)
        #expect(LangDetect.detectColumn(["你好 (nǐ hǎo)", "谢谢 (xièxie)", "再见 (zàijiàn)"]).lang == .zh)
        // A German column with one Arabic line stays German.
        #expect(LangDetect.detectColumn(["die Katze", "der Hund", "كتاب", "das Haus", "die Maus"]).lang == .de)
    }

    @Test("detectColumn: right language for the Arabic and Chinese fixtures")
    func fixtureColumns() {
        let ar = Self.contentLines("arabic-german.txt").filter { $0.contains(" - ") }.dropFirst()
            .map { $0.components(separatedBy: " - ") }
        #expect(LangDetect.detectColumn(ar.map { $0[0] }).lang == .ar)
        #expect(LangDetect.detectColumn(ar.map { $0[1] }).lang == .de)
        let zh = Self.contentLines("chinese-german.txt").dropFirst().map { $0.components(separatedBy: "\t") }
        #expect(LangDetect.detectColumn(zh.map { $0[0] }).lang == .zh)
        #expect(LangDetect.detectColumn(zh.map { $0[2] }).lang == .de)
        // split(/\s*-\s/)
        let dash = Self.contentLines("chinese-dash.txt").dropFirst().map { line -> [String] in
            let parts = line.components(separatedBy: "- ")
            return [JSCompat.trim(parts[0]), parts.dropFirst().joined(separator: "- ")]
        }
        #expect(LangDetect.detectColumn(dash.map { $0[0] }).lang == .zh)
        #expect(LangDetect.detectColumn(dash.map { $0[1] }).lang == .de)
    }

    @Test("DetectedLanguage and scoreLanguages cover Arabic and Chinese")
    func detectedLanguages() {
        #expect(DetectedLanguage(.ar) == .ar && DetectedLanguage(.zh) == .zh)
        #expect(DetectedLanguage.ar.lang == .ar && DetectedLanguage.zh.lang == .zh)
        #expect(Set(LangDetect.scoreLanguages("كتاب").keys) == Set(LangDetect.SUPPORTED))
    }
}
