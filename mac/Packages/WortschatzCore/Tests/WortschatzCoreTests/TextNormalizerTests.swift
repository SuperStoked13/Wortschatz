import Testing
import WortschatzCore

/// Port of tests/text.test.js.
@Suite("TextNormalizer (text.test.js)")
struct TextNormalizerTests {
    @Test func normalizeBasicUnifiesApostrophesDashesAndSpaces() {
        #expect(TextNormalizer.normalizeBasic("  l’homme  ") == "l'homme")
        #expect(TextNormalizer.normalizeBasic("c’est–à–dire") == "c'est-à-dire")
        #expect(TextNormalizer.normalizeBasic("la rue \n  ") == "la rue")
        #expect(TextNormalizer.normalizeBasic(nil) == "")
    }

    @Test func normalizeBasicKeepsTabsWhenAsked() {
        #expect(TextNormalizer.normalizeBasic(" le nom \t  der Name ", keepTabs: true) == "le nom\tder Name")
        #expect(TextNormalizer.normalizeBasic("a\tb") == "a b")
    }

    @Test func normalizeBasicProducesNFC() {
        let decomposed = "e\u{301}"
        let out = TextNormalizer.normalizeBasic(decomposed)
        #expect(Array(out.unicodeScalars) == ["\u{E9}"])
    }

    @Test func stripDiacritics() {
        #expect(TextNormalizer.stripDiacritics("séparée") == "separee")
        #expect(TextNormalizer.stripDiacritics("garçon") == "garcon")
        #expect(TextNormalizer.stripDiacritics("Mädchen") == "Madchen")
        #expect(TextNormalizer.stripDiacritics("Straße") == "Strasse")
        #expect(TextNormalizer.stripDiacritics("cœur") == "coeur")
    }

    @Test func foldUmlauts() {
        #expect(TextNormalizer.foldUmlauts("Mädchen") == "Maedchen")
        #expect(TextNormalizer.foldUmlauts("hübsch") == "huebsch")
        #expect(TextNormalizer.foldUmlauts("Ärger") == "Aerger")
        #expect(TextNormalizer.foldUmlauts("séparée") == "separee")
    }

    @Test func isLetter() {
        #expect(TextNormalizer.isLetter("é"))
        #expect(!TextNormalizer.isLetter("'"))
    }

    // Swift-specific: zero-width characters, odd spaces and JS-only whitespace.
    @Test func swiftSpecificEdgeCases() {
        #expect(TextNormalizer.normalizeBasic("a\u{200B}b\u{FEFF}") == "ab")
        #expect(TextNormalizer.normalizeBasic("a\u{00A0}\u{2009}b") == "a b")
        #expect(TextNormalizer.normalizeBasic("a\u{2028}b") == "a b")
        #expect(TextNormalizer.normalizeBasic("a\u{2028}b", keepTabs: true) == "a\u{2028}b")
        #expect(TextNormalizer.normalizeBasic("a \t \t b", keepTabs: true) == "a\t\tb")
        // NEL (U+0085) is not whitespace in JS.
        #expect(TextNormalizer.normalizeBasic("a\u{85}b") == "a\u{85}b")
    }
}

/// Port of the Arabic and Chinese tests of tests/text.test.js. Compared scalar for scalar
/// (`JSCompat.identical`): Swift `==` would accept a decomposed result.
@Suite("TextNormalizer: Arabic and Chinese folds")
struct TextNormalizerScriptTests {
    func same(_ a: String, _ b: String) -> Bool { JSCompat.identical(a, b) }

    @Test("normalizeBasic drops bidi controls like zero-width characters")
    func bidiControls() {
        #expect(same(TextNormalizer.normalizeBasic("\u{200F}كتاب\u{200F}"), "كتاب"))
        #expect(same(TextNormalizer.normalizeBasic("\u{200E}hello\u{200E}"), "hello"))
        #expect(same(TextNormalizer.normalizeBasic("\u{61C}أ\u{202B}ب\u{202C}\u{202A}ج\u{202D}\u{202E}"), "أبج"))
        #expect(same(TextNormalizer.normalizeBasic("\u{2066}a\u{2067}b\u{2068}c\u{2069}"), "abc"))
        #expect(same(TextNormalizer.normalizeBasic("\u{200F}كتاب\u{200F}\tBuch", keepTabs: true), "كتاب\tBuch"))
    }

    @Test("foldScripts removes vowel marks, Quranic marks and tatweel, keeps hamza and madda")
    func arabicMarks() {
        #expect(same(TextNormalizer.foldScripts("كِتَابٌ"), "كتاب")) // kasra, fatha, dammatan
        #expect(same(TextNormalizer.foldScripts("مُدَرِّسَةٌ"), "مدرسة")) // shadda
        #expect(same(TextNormalizer.foldScripts("قُلْ"), "قل")) // sukun
        #expect(same(TextNormalizer.foldScripts("هٰذا"), "هذا")) // superscript alef
        #expect(same(TextNormalizer.foldScripts("عَلَيْهِ\u{610}"), "عليه")) // Quranic sign U+0610
        #expect(same(TextNormalizer.foldScripts("الرَّحْمَٰنِ\u{6D6}"), "الرحمن")) // small high ligature U+06D6
        #expect(same(TextNormalizer.foldScripts("كتـــاب"), "كتاب")) // tatweel
        #expect(same(TextNormalizer.foldScripts("أب"), "أب"))
        #expect(same(TextNormalizer.foldScripts("القرآن"), "القرآن"))
        #expect(same(TextNormalizer.foldScripts("إسلام"), "إسلام"))
        // A hamza kept apart from its alef by a Quranic mark composes again.
        #expect(same(TextNormalizer.foldScripts("\u{627}\u{6D6}\u{654}"), "\u{623}"))
        // Decomposed input comes out composed (NFC); String.folding would keep the marks.
        #expect(same(TextNormalizer.foldScripts("\u{627}\u{653}"), "\u{622}"))
    }

    @Test("foldScripts turns presentation forms into plain letters (those characters only)")
    func presentationForms() {
        #expect(same(TextNormalizer.foldScripts("ﻛﺘﺎﺏ"), "كتاب"))
        #expect(same(TextNormalizer.foldScripts("ﻻ"), "لا"))
        #expect(same(TextNormalizer.foldScripts("ﻵ"), "لآ"))
        // No whole-string NFKC: ligatures, superscripts and fractions of other text stay.
        #expect(same(TextNormalizer.foldScripts("ﬁn ² ½ ﻛ"), "ﬁn ² ½ ك"))
    }

    @Test("foldScripts maps Arabic and full-width punctuation to ASCII")
    func punctuation() {
        #expect(same(TextNormalizer.foldScripts("كتاب، دفتر؛ قلم؟"), "كتاب, دفتر; قلم?"))
        #expect(same(TextNormalizer.foldScripts("你好（nǐ hǎo），再见！"), "你好(nǐ hǎo),再见!"))
        #expect(same(TextNormalizer.foldScripts("谢谢、多谢；再见：好吗？"), "谢谢,多谢;再见:好吗?"))
        #expect(same(TextNormalizer.foldScripts("我是学生。"), "我是学生."))
        #expect(same(TextNormalizer.foldScripts("【注意】［x］"), "[注意][x]"))
        #expect(same(TextNormalizer.foldScripts("ＡＢＣ１２３～"), "ABC123~"))
        // Quotes stay (grading drops them as punctuation).
        #expect(same(TextNormalizer.foldScripts("「你好」《书》"), "「你好」《书》"))
    }

    @Test("foldScripts removes spaces between two Han characters only")
    func hanSpaces() {
        #expect(same(TextNormalizer.foldScripts("你 好"), "你好"))
        #expect(same(TextNormalizer.foldScripts("我 是  学 生"), "我是学生"))
        #expect(same(TextNormalizer.foldScripts("你好 nǐ hǎo"), "你好 nǐ hǎo"))
        #expect(same(TextNormalizer.foldScripts("nǐ hǎo 你好"), "nǐ hǎo 你好"))
        // Extension B, Extension A, the compatibility block (U+FA0E has no decomposition).
        #expect(same(TextNormalizer.foldScripts("\u{20000} \u{20001} \u{3400} \u{FA0E}"), "\u{20000}\u{20001}\u{3400}\u{FA0E}"))
        #expect(same(TextNormalizer.foldScripts("東京 Tokyo"), "東京 Tokyo"))
    }

    @Test("foldScripts leaves Latin text alone (NFC only)")
    func latin() {
        for s in ["l'homme", "Straße", "cœur", "garçon, fille", "a … b", "¿Qué?", "« oui »", "ﬁ"] {
            #expect(same(TextNormalizer.foldScripts(s), s))
        }
        #expect(same(TextNormalizer.foldScripts("e\u{301}"), "\u{E9}"))
        #expect(TextNormalizer.foldScripts("") == "")
    }

    @Test("stripArabicMarks drops vowel marks and tatweel, nothing else")
    func stripArabicMarks() {
        #expect(same(TextNormalizer.stripArabicMarks("كِتَابٌ"), "كتاب"))
        #expect(same(TextNormalizer.stripArabicMarks("كتـاب"), "كتاب"))
        #expect(same(TextNormalizer.stripArabicMarks("أَب"), "أب"))
        #expect(same(TextNormalizer.stripArabicMarks("café"), "café"))
    }

    @Test("hasArabic and hasHan use explicit script ranges")
    func scriptRanges() {
        #expect(TextNormalizer.hasArabic("كتاب"))
        #expect(TextNormalizer.hasArabic("ﻛ"))
        #expect(TextNormalizer.hasArabic("\u{750}")) // Arabic Supplement
        #expect(!TextNormalizer.hasArabic("café"))
        #expect(!TextNormalizer.hasArabic("\u{FEFF}"))
        #expect(TextNormalizer.hasHan("你好"))
        #expect(TextNormalizer.hasHan("a漢b"))
        #expect(TextNormalizer.hasHan("\u{20000}"))
        #expect(!TextNormalizer.hasHan("nǐ hǎo"))
        #expect(!TextNormalizer.hasHan("。、"))
        #expect(!TextNormalizer.hasHan("かな"))
    }
}
