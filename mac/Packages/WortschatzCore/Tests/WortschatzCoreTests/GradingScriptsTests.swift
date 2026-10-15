import Testing
import WortschatzCore

// Port of the Arabic and Chinese tests of tests/grading.test.js (the parity fixture replays them
// too; these say what each rule is for). `Tolerance(typos: true)` is the JS `{ typos: true }`:
// the defaults with one change.

@Suite("Grading: Arabic")
struct GradingArabicTests: GradingAssertions {
    @Test("Vowel marks, Quranic marks and tatweel never matter and give no note")
    func vowelMarks() {
        exactMatch("كتاب", "كِتَابٌ", .ar)
        exactMatch("كِتَابٌ", "كتاب", .ar)
        exactMatch("مدرسة", "مُدَرِّسَةٌ", .ar)
        exactMatch("هذا", "هٰذَا", .ar)
        exactMatch("الرحمن", "الرَّحْمَٰنِ", .ar)
        exactMatch("كتـــاب", "كتاب", .ar)
        exactMatch("كتاب", "كتـاب", .ar)
        // Whatever the accents setting, and in sets of another language.
        exactMatch("كتاب", "كِتَابٌ", .ar, Tolerance(ignoreAccents: false, typos: false))
        exactMatch("كتاب", "كِتَابٌ", nil)
        exactMatch("كتاب", "كِتَابٌ", .other)
    }

    @Test("Presentation forms and bidi marks never matter")
    func presentationFormsAndBidi() {
        exactMatch("كتاب", "ﻛﺘﺎﺏ", .ar)
        exactMatch("ﻛﺘﺎﺏ", "كتاب", .ar)
        exactMatch("لا", "ﻻ", .ar)
        exactMatch("كتاب", "\u{200F}كتاب\u{200F}", .ar)
        exactMatch("\u{202B}كتاب\u{202C}", "كتاب", .ar)
    }

    @Test("Letter variants are correct with the note «Schreibvariante», always")
    func letterVariants() {
        accepts("مدرسه", "مدرسة", .ar, .default, [.variant]) // ة/ه
        accepts("مدرسة", "مدرسه", .ar, .default, [.variant])
        accepts("مستشفي", "مستشفى", .ar, .default, [.variant]) // ى/ي
        accepts("اب", "أب", .ar, .default, [.variant]) // hamza on alef
        accepts("اسلام", "إسلام", .ar, .default, [.variant])
        accepts("القران", "القرآن", .ar, .default, [.variant]) // madda
        accepts("اسم", "ٱسم", .ar, .default, [.variant]) // alef wasla
        accepts("مسوول", "مسؤول", .ar, .default, [.variant]) // ؤ → و
        accepts("رييس", "رئيس", .ar, .default, [.variant]) // ئ → ي
        accepts("مدرسه", "مدرسة", .ar, gradingAllOff, [.variant])
        // Gated on the script, not on the set's language.
        accepts("اب", "أب", nil, .default, [.variant])
        accepts("مدرسه", "مدرسة", .other, .default, [.variant])
        #expect(Labels.NOTE_LABELS[.variant] == "Schreibvariante")
    }

    @Test("A hamza difference is a variant, not an accent or a typo")
    func hamzaIsAVariant() {
        accepts("اب", "أب", .ar, Tolerance(ignoreAccents: true), [.variant])
        accepts("مسوول", "مسؤول", .ar, Tolerance(ignoreAccents: true, typos: true), [.variant])
        accepts("مدرسة", "مدرسه", .ar, Tolerance(typos: true), [.variant])
        accepts("مستشفي", "مستشفى", .ar, Tolerance(ignoreAccents: true, typos: true), [.variant])
    }

    @Test("A variant and a real typo together")
    func variantAndTypo() {
        accepts("مدرصه", "مدرسة", .ar, Tolerance(typos: true), [.variant, .typo])
        rejects("مدرصه", "مدرسة", .ar, .default, .typo)
        // The typo comparator is tried before its variant twin: a budget of 2 takes both.
        accepts("مدرسه كبيرا", "مدرسة كبيرة", .ar, Tolerance(typos: true), [.typo])
    }

    @Test("ال is a glued article")
    func gluedArticle() {
        accepts("كتاب", "الكتاب", .ar, .default, [.article])
        accepts("شمس", "الشَّمْسُ", .ar, .default, [.article])
        rejects("كتاب", "الكتاب", .ar, Tolerance(articles: false), .missingArticle)
        accepts("الكتاب", "كتاب", .ar, .default, []) // an extra article is ignored
        exactMatch("الكتاب", "الكتاب", .ar)
        accepts("ال كتاب", "الكتاب", .ar, .default, [])
        accepts("مدرسه", "المدرسة", .ar, .default, [.article, .variant])
        accepts("المدرسه", "المدرسة", .ar, .default, [.variant])
        // Dictionary forms: "كتاب، ال" and a bracketed article.
        accepts("الكتاب", "كتاب، ال", .ar, .default, [])
        accepts("كتاب", "(ال)كتاب", .ar, .default, [.parentheses])
        exactMatch("ال", "ال", .ar)
        rejects("كتاب", "الكتاب", .fr)
    }

    @Test("، and ؛ separate alternatives, ؟ is punctuation")
    func separators() {
        accepts("كتاب", "كتاب، دفتر", .ar, .default, [.partial])
        accepts("دفتر", "كتاب ؛ دفتر", .ar, .default, [.partial])
        accepts("دفتر، كتاب", "كتاب، دفتر", .ar, .default, [.order])
        exactMatch("كتاب، دفتر", "كتاب, دفتر", .ar)
        exactMatch("هل", "هل؟", .ar)
        exactMatch("هل؟", "هل", .ar)
        exactMatch("نعم", "نعم!", .ar)
    }

    @Test("A sentence ending in . ? ! or … is one answer despite its commas")
    func sentences() {
        rejects("كيف حالك", "كيف حالك، يا أحمد؟", .ar)
        rejects("مرحبا", "مرحبا، أنا طالب.", .ar)
        exactMatch("مرحبا، أنا طالب", "مرحبا، أنا طالب.", .ar)
        accepts("مرحبا", "مرحبا، أنا طالب", .ar, .default, [.partial])
        #expect(Grading.splitAlternatives("مرحبا، أنا طالب.", lang: .ar) == ["مرحبا، أنا طالب."])
        #expect(Grading.splitAlternatives("مرحبا، أنا طالب.") == ["مرحبا، أنا طالب."])
    }

    @Test("splitAlternatives keeps the vowel marks and characters as written")
    func splitKeepsTheText() {
        #expect(identical(Grading.splitAlternatives("كتاب، دفتر"), ["كتاب", "دفتر"]))
        #expect(identical(Grading.splitAlternatives("كِتَابٌ، دَفْتَرٌ", lang: .ar), ["كِتَابٌ", "دَفْتَرٌ"]))
        #expect(identical(Grading.splitAlternatives("كتاب؛ قلم؛ دفتر"), ["كتاب", "قلم", "دفتر"]))
        #expect(identical(Grading.splitAlternatives("كتـاب، أب"), ["كتـاب", "أب"]))
        #expect(identical(Grading.splitAlternatives("هل؟"), ["هل؟"]))
        #expect(identical(Grading.splitAlternatives("كتاب/دفتر"), ["كتاب", "دفتر"]))
    }

    @Test("Wrong answers stay wrong")
    func wrongAnswers() {
        rejects("كتب", "كتاب", .ar, .default, .typo)
        accepts("كتب", "كتاب", .ar, Tolerance(typos: true), [.typo])
        rejects("قلم", "كتاب", .ar, .default, noHint)
        rejects("بيت", "بنت", .ar, .default, noHint)
    }
}

@Suite("Grading: Chinese")
struct GradingChineseTests: GradingAssertions {
    @Test("Characters or pinyin are both correct")
    func charactersOrPinyin() {
        accepts("你好", "你好 (nǐ hǎo)", .zh, .default, [])
        accepts("nǐ hǎo", "你好 (nǐ hǎo)", .zh, .default, [.pinyin])
        exactMatch("你好 (nǐ hǎo)", "你好 (nǐ hǎo)", .zh)
        accepts("你好 nǐ hǎo", "你好 (nǐ hǎo)", .zh, .default, [])
        accepts("你好nǐhǎo", "你好 (nǐ hǎo)", .zh, .default, [])
        // Full-width brackets, no brackets, pinyin first.
        accepts("你好", "你好（nǐ hǎo）", .zh, .default, [])
        accepts("nǐ hǎo", "你好（nǐ hǎo）", .zh, .default, [.pinyin])
        accepts("你好", "你好 nǐ hǎo", .zh, .default, [])
        accepts("nǐ hǎo", "你好 nǐ hǎo", .zh, .default, [.pinyin])
        accepts("你好", "nǐ hǎo 你好", .zh, .default, [])
        accepts("nǐ hǎo", "nǐ hǎo 你好", .zh, .default, [.pinyin])
        accepts("nǐ hǎo", "nǐ hǎo (你好)", .zh, .default, [.pinyin])
        #expect(Labels.NOTE_LABELS[.pinyin] == "Nur Pinyin")
    }

    @Test("The characters alone get no brackets note, whatever the brackets setting")
    func noBracketsNote() {
        accepts("你好", "你好 (nǐ hǎo)", .zh, Tolerance(parentheses: true), [])
        accepts("你好", "你好 (nǐ hǎo)", .zh, Tolerance(parentheses: false), [])
        accepts("nǐ hǎo", "你好 (nǐ hǎo)", .zh, Tolerance(parentheses: false), [.pinyin])
        accepts("你好", "你好 (问候)", .zh, .default, [.parentheses])
    }

    @Test("Cards with only characters need characters; several readings each count")
    func charactersOnlyAndReadings() {
        rejects("nǐ hǎo", "你好", .zh)
        rejects("ni hao", "你好", .zh, Tolerance(ignoreAccents: true, typos: true))
        accepts("你好", "你好", .zh, .default, [])
        accepts("nǐ hǎo", "你好 (nǐ hǎo, ní hǎo)", .zh, .default, [.pinyin])
        accepts("ní hǎo", "你好 (nǐ hǎo, ní hǎo)", .zh, .default, [.pinyin])
        accepts("你好", "你好 (nǐ hǎo, ní hǎo)", .zh, .default, [])
    }

    @Test("Tone numbers equal tone marks")
    func toneNumbers() {
        accepts("ni3 hao3", "你好 (nǐ hǎo)", .zh, .default, [.pinyin])
        accepts("ni3hao3", "你好 (nǐ hǎo)", .zh, .default, [.pinyin])
        accepts("xie4xie5", "谢谢 (xiè xie)", .zh, .default, [.pinyin])
        accepts("xie4xie", "谢谢 (xiè xie)", .zh, .default, [.pinyin])
        accepts("nǐ hǎo", "你好 (ni3 hao3)", .zh, .default, [.pinyin])
        exactMatch("ma1", "mā", .zh)
        exactMatch("ma2", "má", .zh)
        exactMatch("ma3", "mǎ", .zh)
        exactMatch("ma4", "mà", .zh)
        exactMatch("ma5", "ma", .zh)
        exactMatch("ma0", "ma", .zh)
        exactMatch("Ni3", "Nǐ", .zh)
    }

    @Test("The tone mark goes on a or e, on o in ou, otherwise on the last vowel")
    func toneMarkPlacement() {
        exactMatch("hao3", "hǎo", .zh)
        exactMatch("xie4", "xiè", .zh)
        exactMatch("dou1", "dōu", .zh)
        exactMatch("liu2", "liú", .zh)
        exactMatch("gui4", "guì", .zh)
        exactMatch("lüe4", "lüè", .zh)
        exactMatch("zhuang4", "zhuàng", .zh)
        exactMatch("er2", "ér", .zh)
    }

    @Test("v and u: stand for ü in tone syllables; other digits stay")
    func umlautAndDigits() {
        exactMatch("lv4", "lǜ", .zh)
        exactMatch("lǜ", "lv4", .zh)
        exactMatch("nu:3", "nǚ", .zh)
        exactMatch("nv3", "nǚ", .zh)
        exactMatch("lv5", "lü", .zh)
        rejects("lv", "lü", .zh)
        exactMatch("3个", "3个", .zh)
        exactMatch("MP3", "MP3", .zh)
        rejects("ni3", "ni", .zh, .default, .tonesOnly)
    }

    @Test("Spaces do not count")
    func spaces() {
        accepts("nihao", "你好 (ni hao)", .zh, .default, [.pinyin])
        accepts("nǐhǎo", "你好 (nǐ hǎo)", .zh, .default, [.pinyin])
        accepts("ni hao", "nihao", .zh, .default, [])
        exactMatch("你 好", "你好", .zh)
        exactMatch("你好", "你 好", .zh)
        accepts("我是 学生", "我是学生", .zh, .default, [])
    }

    @Test("Missing tones behave like accents (Töne)")
    func tones() {
        rejects("ni hao", "你好 (nǐ hǎo)", .zh, .default, .tonesOnly)
        rejects("nihao", "你好 (nǐ hǎo)", .zh, .default, .tonesOnly)
        accepts("ni hao", "你好 (nǐ hǎo)", .zh, Tolerance(ignoreAccents: true), [.pinyin, .tones])
        rejects("ma", "mā", .zh, .default, .tonesOnly)
        rejects("mà", "mā", .zh, .default, .tonesOnly)
        accepts("mà", "mā", .zh, Tolerance(ignoreAccents: true), [.tones])
        accepts("lu", "lǜ", .zh, Tolerance(ignoreAccents: true), [.tones])
        // Other languages keep «Akzente».
        rejects("ni hao", "nǐ hǎo", .fr, .default, .accentsOnly)
        accepts("ni hao", "nǐ hǎo", .fr, Tolerance(ignoreAccents: true), [.accents])
        #expect(Labels.NOTE_LABELS[.tones] == "Töne")
        #expect(Labels.HINT_LABELS[.tonesOnly] == "Nur die Töne fehlen")
    }

    @Test("A wrong character is never a typo; pinyin keeps the typo rule")
    func typos() {
        rejects("太", "大", .zh, Tolerance(typos: true))
        rejects("我是学士", "我是学生", .zh, Tolerance(typos: true))
        rejects("中家 zhōngguó", "中国 (zhōng guó)", .zh, Tolerance(typos: true))
        accepts("zhōnggua", "中国 (zhōng guó)", .zh, Tolerance(typos: true), [.pinyin, .typo])
        accepts("中国 zhōnggua", "中国 (zhōng guó)", .zh, Tolerance(typos: true), [.typo])
        rejects("zhōnggua", "中国 (zhōng guó)", .zh, .default, .typo)
    }

    @Test("，、； and / separate alternatives; full-width brackets are brackets")
    func separators() {
        accepts("谢谢", "谢谢，多谢", .zh, .default, [.partial])
        accepts("多谢", "谢谢、多谢", .zh, .default, [.partial])
        accepts("多谢", "谢谢；多谢", .zh, .default, [.partial])
        accepts("多谢", "谢谢/多谢", .zh, .default, [.partial])
        accepts("您", "你/您", .zh, .default, [.partial])
        #expect(Grading.splitAlternatives("谢谢，多谢") == ["谢谢", "多谢"])
        #expect(Grading.splitAlternatives("谢谢、多谢；再见") == ["谢谢", "多谢", "再见"])
        #expect(Grading.splitAlternatives("谢谢/多谢") == ["谢谢", "多谢"])
        #expect(Grading.splitAlternatives("你/您") == ["你", "您"])
        #expect(Grading.splitAlternatives("你好（nǐ hǎo，ní hǎo），您好") == ["你好（nǐ hǎo，ní hǎo）", "您好"])
    }

    @Test("CJK punctuation and quotes never matter; a final 。 makes a sentence")
    func punctuationAndSentences() {
        exactMatch("你好", "你好！", .zh)
        exactMatch("你好！", "你好", .zh)
        exactMatch("你好", "你好。", .zh)
        exactMatch("好吗", "好吗？", .zh)
        exactMatch("你好", "「你好」", .zh)
        exactMatch("红楼梦", "《红楼梦》", .zh)
        exactMatch("你好", "『你好』", .zh)
        exactMatch("你好", "〈你好〉", .zh)
        rejects("你好", "你好，我是学生。", .zh)
        exactMatch("你好，我是学生", "你好，我是学生。", .zh)
        #expect(Grading.splitAlternatives("你好，我是学生。", lang: .zh) == ["你好，我是学生。"])
        #expect(Grading.splitAlternatives("你好，我是学生。") == ["你好，我是学生。"])
        rejects("你好", "你好，你叫什么名字？", .zh)
    }

    @Test("The pinyin rules apply only when the answer language is Chinese")
    func onlyForChinese() {
        rejects("nǐ hǎo", "你好 (nǐ hǎo)", .fr)
        accepts("你好", "你好 (nǐ hǎo)", .fr, .default, [.parentheses])
        accepts("你好", "你好 (nǐ hǎo)", nil, .default, [.parentheses])
        rejects("ni3", "nǐ", .fr)
        rejects("nihao", "ni hao", .fr)
        exactMatch("你 好", "你好", .fr)
    }

    @Test("Note and hint order with Chinese and Arabic notes")
    func noteOrder() {
        let r = Grading.grade(
            given: "ni hao, xie xie", expected: "你好 (nǐ hǎo), 谢谢 (xiè xie)", tolerance: Tolerance(ignoreAccents: true),
            lang: .zh)
        #expect(r.correct)
        #expect(r.notes == [.pinyin, .tones])
        accepts("مدرسه", "المدرسة", .ar, .default, [.article, .variant])
        accepts("مدرسه, كتاب", "كتاب، المدرسة", .ar, Tolerance(typos: true), [.article, .variant, .order])
    }
}

@Suite("Grading: Arabic and Chinese diffs")
struct GradingScriptDiffTests: GradingAssertions {
    @Test("diffChars keeps marks with their letter")
    func marksStayWithTheLetter() {
        #expect(Grading.diffChars("كتب", "كِتَبَ") == [seg(.del, "كتب"), seg(.add, "كِتَبَ")])
        #expect(Grading.diffChars("كِتب", "كِتَبَ") == [seg(.same, "كِ"), seg(.del, "تب"), seg(.add, "تَبَ")])
        // A Latin letter with a mark that has no precomposed form is one character too.
        #expect(Grading.diffChars("q", "q\u{301}") == [seg(.del, "q"), seg(.add, "q\u{301}")])
    }

    @Test("diffAnswer shows Arabic vowel marks only when the learner typed some")
    func arabicMarks() {
        #expect(Grading.diffAnswer("كتاب", "كِتَابٌ") == [seg(.same, "كتاب")])
        #expect(Grading.diffAnswer("كتب", "كِتَابٌ") == [seg(.same, "كت"), seg(.add, "ا"), seg(.same, "ب")])
        #expect(Grading.diffAnswer("كتاب", "كتـاب") == [seg(.same, "كتاب")])
        #expect(Grading.diffAnswer("كِتاب", "كِتَابٌ") == [
            seg(.same, "كِ"), seg(.del, "ت"), seg(.add, "تَ"), seg(.same, "ا"), seg(.del, "ب"), seg(.add, "بٌ"),
        ])
    }

    @Test("diffAnswer for Chinese diffs against the form typed, tone numbers as marks")
    func chineseForms() {
        #expect(Grading.diffAnswer("ni hao", "你好 (nǐ hǎo)", lang: .zh) == [
            seg(.same, "n"), seg(.del, "i"), seg(.add, "ǐ"), seg(.same, " h"), seg(.del, "a"), seg(.add, "ǎ"),
            seg(.same, "o"),
        ])
        #expect(Grading.diffAnswer("ni3 hao", "你好（nǐ hǎo）", lang: .zh) == [
            seg(.same, "nǐ h"), seg(.del, "a"), seg(.add, "ǎ"), seg(.same, "o"),
        ])
        #expect(Grading.diffAnswer("你们", "你好 (nǐ hǎo)", lang: .zh) == [seg(.same, "你"), seg(.del, "们"), seg(.add, "好")])
        #expect(Grading.diffAnswer("你好 (ni hǎo)", "你好 (nǐ hǎo)", lang: .zh) == [
            seg(.same, "你好 (n"), seg(.del, "i"), seg(.add, "ǐ"), seg(.same, " hǎo)"),
        ])
        // Without the language: the whole answer, as before.
        #expect(Grading.diffAnswer("ni hao", "你好 (nǐ hǎo)").first == seg(.add, "你好 ("))
    }

    @Test("Write and Learn diff the closest form with the answer language")
    func closestDiff() {
        #expect(WriteFlow.closestDiff(given: "ni hao", expected: "你好 (nǐ hǎo), 您好 (nín hǎo)", lang: .zh) == [
            seg(.same, "n"), seg(.del, "i"), seg(.add, "ǐ"), seg(.same, " h"), seg(.del, "a"), seg(.add, "ǎ"),
            seg(.same, "o"),
        ])
        #expect(WriteFlow.closestDiff(given: "دفتر", expected: "كِتَابٌ، دَفْتَرٌ", lang: .ar) == [seg(.same, "دفتر")])
        #expect(WriteFlow.closestDiff(given: "كتب", expected: "كِتَابٌ، دَفْتَرٌ", lang: .ar) == [
            seg(.same, "كت"), seg(.add, "ا"), seg(.same, "ب"),
        ])
    }

    @Test("Latin regressions: accents, brackets, spaces and typos as before")
    func latinRegressions() {
        rejects("garcon", "garçon", .fr, .default, .accentsOnly)
        accepts("garcon", "garçon", .fr, Tolerance(ignoreAccents: true), [.accents])
        accepts("le pain", "le pain (frais)", .fr, .default, [.parentheses])
        rejects("frais", "le pain (frais)", .fr)
        rejects("lepain", "le pain", .fr)
        rejects("Haus", "Hand", .de, Tolerance(typos: true))
        accepts("Strase", "Strasse", .de, Tolerance(typos: true), [.typo])
        accepts("ja", "ja, nein.", .de, .default, [.partial])
        rejects("Ça va", "Ça va bien, merci.", .fr)
        accepts("homme", "l'homme", .fr, .default, [.article])
        #expect(Grading.splitAlternatives("le chat (frais), la chatte") == ["le chat (frais)", "la chatte"])
        #expect(Grading.diffAnswer("garcon", "garçon") == [seg(.same, "gar"), seg(.del, "c"), seg(.add, "ç"), seg(.same, "on")])
    }
}
