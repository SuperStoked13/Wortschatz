import Testing
@testable import WortschatzCore

/// Typing on a multiple-choice question: the letters highlight the one option they start (with
/// enough letters after the article), Return chooses it.
@Suite("LearnFlow typing on multiple choice")
struct LearnTypeAheadTests {
    static let T0: Double = 1_760_000_000_000

    static func pick(_ typed: String, _ choices: [String], lang: Lang? = .fr) -> Int? {
        LearnFlow.typeAhead(typed, choices: choices, lang: lang).selected
    }

    /// One character folded like the type-ahead compares it.
    static func fold(_ ch: String) -> String { TypeAheadText.fold(Character(ch)) }

    // MARK: Matching

    @Test("An article alone never picks; two letters after it do, if only one option fits")
    func needsTwoLettersAfterTheArticle() {
        let choices = ["la voiture", "le chat", "la maison", "un arbre"]
        #expect(Self.pick("la", choices) == nil)
        #expect(Self.pick("la ", choices) == nil)
        #expect(Self.pick("la v", choices) == nil)
        #expect(Self.pick("la vo", choices) == 0)
        #expect(Self.pick("la voiture", choices) == 0)
        #expect(Self.pick("La VOI", choices) == 0)
        // "la " narrows to the options with that article.
        let narrowed = LearnFlow.typeAhead("la ", choices: choices, lang: .fr)
        #expect(narrowed.matching == [0, 2])
        #expect(narrowed.isActive && !narrowed.hasEnoughLetters)
    }

    @Test("Two options starting alike need more letters")
    func ambiguousNeedsMore() {
        let choices = ["la voiture", "la vache", "le vélo", "la maison"]
        #expect(Self.pick("la v", choices) == nil)
        #expect(LearnFlow.typeAhead("la va", choices: choices, lang: .fr).matching == [1])
        #expect(Self.pick("la va", choices) == 1)
        #expect(Self.pick("la vo", choices) == 0)
        // Without the article: "ve" fits only le vélo (accents do not matter).
        #expect(Self.pick("ve", choices) == 2)
        #expect(Self.pick("v", choices) == nil)
    }

    @Test("The option can be started without its article, at an alternative, or with a pronoun")
    func startsInsideTheOption() {
        #expect(Self.pick("voi", ["la voiture", "le chat", "la maison", "un arbre"]) == 0)
        #expect(Self.pick("ch", ["la voiture", "le chat", "la maison", "un arbre"]) == 1)
        let alternatives = ["laid, laide", "beau", "joli", "moche"]
        #expect(Self.pick("lai", alternatives) == 0)
        #expect(LearnFlow.typeAhead("laide", choices: alternatives, lang: .fr).ranges[0] == 6..<11)
        let verbs = ["se dépêcher", "se laver", "partir", "dormir"]
        #expect(Self.pick("se d", verbs) == nil)
        #expect(Self.pick("se de", verbs) == 0)
        #expect(Self.pick("dep", verbs) == 0)
        let german = ["der Hund", "die Katze", "das Haus", "der Hase"]
        #expect(Self.pick("der h", german, lang: .de) == nil)
        #expect(Self.pick("der hu", german, lang: .de) == 0)
        #expect(Self.pick("ha", german, lang: .de) == nil)
        #expect(Self.pick("hau", german, lang: .de) == 2)
    }

    @Test("Apostrophes and accents do not matter; l' counts as an article")
    func apostrophes() {
        let choices = ["l'été", "la tête", "le thé", "la fête"]
        #expect(Self.pick("l'e", choices) == nil)
        #expect(Self.pick("l’et", choices) == 0)
        #expect(Self.pick("te", choices) == 1)
        #expect(Self.pick("the", choices) == 2)
    }

    @Test("The typed article decides between options that only differ there")
    func articleDecides() {
        let choices = ["le livre", "la livraison", "le lit", "la lune"]
        // Strong match "le liv" wins over "la livraison" (matching only after its article).
        #expect(LearnFlow.typeAhead("le liv", choices: choices, lang: .fr).matching == [0])
        #expect(Self.pick("le liv", choices) == 0)
        // Another article than the option's still finds it when nothing else fits.
        #expect(Self.pick("le voi", ["la voiture", "le chat", "la maison", "un arbre"]) == 0)
    }

    @Test("An option typed in full wins over a longer one starting the same")
    func completeOptionWins() {
        let choices = ["le pain", "le pain de mie", "le lait", "l'eau"]
        #expect(Self.pick("le pai", choices) == nil)
        #expect(Self.pick("le pain", choices) == 0)
        #expect(Self.pick("le pain d", choices) == 1)
        // A one-letter option typed in full.
        #expect(Self.pick("y", ["y", "en", "le", "lui"]) == 0)
    }

    @Test("Letters that start no option match nothing; ranges cover the typed part")
    func noMatchAndRanges() {
        let choices = ["La Voiture", "le chat", "la maison", "un arbre"]
        let none = LearnFlow.typeAhead("xyz", choices: choices, lang: .fr)
        #expect(none.isActive && none.matching.isEmpty && none.selected == nil)
        #expect(LearnFlow.typeAhead("la vo", choices: choices, lang: .fr).ranges[0] == 0..<5)
        #expect(LearnFlow.typeAhead("voi", choices: choices, lang: .fr).ranges[0] == 3..<6)
        #expect(LearnFlow.typeAhead("  ", choices: choices, lang: .fr) == LearnFlow.TypeAhead())
        // Several spaces count as one.
        #expect(Self.pick("la   vo", choices) == 0)
    }

    // MARK: Arabic and Chinese (mirrored by the tests in Website/tests/typeahead.test.js; ranges are
    // `Character` offsets here, UTF-16 offsets there)

    @Test("Arabic: vowel marks, tatweel and presentation forms do not matter")
    func arabicMarks() {
        #expect(Self.pick("كتا", ["كِتَابٌ", "قلم", "بيت"], lang: .ar) == 0)
        #expect(Self.pick("كِتَا", ["كتاب", "قلم", "بيت"], lang: .ar) == 0)
        #expect(Self.pick("كتـا", ["كتاب", "قلم", "بيت"], lang: .ar) == 0)
        #expect(Self.pick("كتا", ["كتـــاب", "قلم", "بيت"], lang: .ar) == 0)
        #expect(Self.pick("مد", ["ﻣﺪﺭﺳﺔ", "قلم", "بيت"], lang: .ar) == 0)
        // The typed part is underlined over the original characters, marks included.
        #expect(LearnFlow.typeAhead("كتا", choices: ["كِتَابٌ"], lang: .ar).ranges[0] == 0..<3)
    }

    @Test("Arabic: hamza forms, ة/ه and ى/ي do not matter")
    func arabicVariants() {
        #expect(Self.pick("اب", ["أب", "أم", "بيت"], lang: .ar) == 0)
        #expect(Self.pick("اس", ["إسلام", "قلم"], lang: .ar) == 0)
        #expect(Self.pick("اسم", ["ٱسم", "قلم"], lang: .ar) == 0)
        #expect(Self.pick("مسو", ["مسؤول", "قلم"], lang: .ar) == 0)
        #expect(Self.pick("ريي", ["رئيس", "قلم"], lang: .ar) == 0)
        #expect(Self.pick("مدرسه", ["مدرسة", "مدرس", "قلم"], lang: .ar) == 0)
        #expect(Self.pick("مستشفي", ["مستشفى", "قلم"], lang: .ar) == 0)
    }

    @Test("Arabic: ال is a glued article")
    func arabicArticle() {
        let choices = ["الكتاب", "المدرسة", "قلم", "بيت"]
        #expect(ExtendedSynonyms.articlePrefixes(.ar) == ["ال"])
        #expect(ExtendedSynonyms.articlePrefixes(nil).contains("ال"))
        #expect(ExtendedSynonyms.articlePrefixes(nil).contains("la "))
        // Without the article.
        #expect(Self.pick("كت", choices, lang: .ar) == 0)
        #expect(LearnFlow.typeAhead("كت", choices: choices, lang: .ar).ranges[0] == 2..<4)
        #expect(Self.pick("مد", choices, lang: .ar) == 1)
        // The article alone picks nothing; two letters after it do.
        #expect(Self.pick("ال", choices, lang: .ar) == nil)
        #expect(LearnFlow.typeAhead("ال", choices: choices, lang: .ar).matching == [0, 1])
        #expect(Self.pick("الك", choices, lang: .ar) == nil)
        #expect(Self.pick("الكت", choices, lang: .ar) == 0)
        // Any language (nil) knows it too.
        #expect(Self.pick("كت", choices, lang: nil) == 0)
    }

    @Test("Arabic: ، separates alternatives")
    func arabicComma() {
        #expect(Self.pick("دف", ["كتاب، دفتر", "قلم", "بيت"], lang: .ar) == 0)
        #expect(LearnFlow.typeAhead("دف", choices: ["كتاب، دفتر"], lang: .ar).ranges[0] == 6..<8)
    }

    @Test("Chinese: pinyin after the characters starts an option, spaces do not matter")
    func chinesePinyin() {
        let choices = ["你好 (nǐ hǎo)", "谢谢 (xiè xie)", "再见（zài jiàn）", "您好 nín hǎo"]
        #expect(Self.pick("xie", choices, lang: .zh) == 1)
        #expect(Self.pick("zai", choices, lang: .zh) == 2)
        #expect(Self.pick("nin", choices, lang: .zh) == 3)
        // "ni" starts nǐ hǎo and nín hǎo.
        #expect(Self.pick("ni", choices, lang: .zh) == nil)
        #expect(LearnFlow.typeAhead("ni", choices: choices, lang: .zh).matching == [0, 3])
        #expect(Self.pick("nih", choices, lang: .zh) == 0)
        #expect(Self.pick("ni hao", choices, lang: .zh) == 0)
        #expect(Self.pick("nihao", choices, lang: .zh) == 0)
        #expect(Self.pick("zaijian", choices, lang: .zh) == 2)
        #expect(LearnFlow.typeAhead("nih", choices: choices, lang: .zh).ranges[0] == 4..<8)
        // The characters still work.
        #expect(Self.pick("你好", choices, lang: .zh) == 0)
        #expect(Self.pick("你 好", choices, lang: .zh) == 0)
    }

    @Test("Chinese: spaces between characters never matter, other spaces only for Chinese")
    func chineseSpaces() {
        #expect(Self.pick("你好", ["你 好", "谢谢"], lang: .fr) == 0)
        #expect(Self.pick("xiexie", ["谢谢 (xiè xie)", "你好 (nǐ hǎo)"], lang: .fr) == nil)
        #expect(Self.pick("xie xie", ["谢谢 (xiè xie)", "你好 (nǐ hǎo)"], lang: .fr) == 0)
    }

    @Test("Latin options do not start after a bracket")
    func latinBrackets() {
        #expect(Self.pick("fr", ["le pain (frais)", "le vin"], lang: .fr) == nil)
        #expect(Self.pick("fr", ["le pain (frais)", "le vin"], lang: .zh) == nil)
    }

    @Test("Folding is NFD without marks, like typeahead.js")
    func folding() {
        #expect(Self.fold("É") == "e")
        #expect(Self.fold("ß") == "ss")
        #expect(Self.fold("ǜ") == "u")
        #expect(Self.fold("أ") == "ا")
        #expect(Self.fold("ٱ") == "ا")
        #expect(Self.fold("ة") == "ه")
        #expect(Self.fold("ى") == "ي")
        #expect(Self.fold("كِ") == "ك")
        #expect(Self.fold("ـ") == "")
        #expect(Self.fold("（") == "(")
        #expect(Self.fold("’") == "'")
    }

    @Test("Arabic-Indic digits are digits")
    func arabicIndicDigits() {
        #expect(LearnFlow.digitValue("3") == 3)
        #expect(LearnFlow.digitValue("٠") == 0)
        #expect(LearnFlow.digitValue("١") == 1)
        #expect(LearnFlow.digitValue("٩") == 9)
        #expect(LearnFlow.digitValue("۰") == 0)
        #expect(LearnFlow.digitValue("۴") == 4)
        for x in ["a", "", "12", "١٢", " "] { #expect(LearnFlow.digitValue(x) == nil) }
    }

    // MARK: Reducer

    /// A Learn session over four new cards: the first question is multiple choice.
    struct Session {
        var state: LearnFlow.State
        var now = LearnTypeAheadTests.T0
        let rng = mulberry32(seed: 7)

        init() {
            let cards = [
                Card(id: "c1", term: "la voiture", definition: "das Auto"),
                Card(id: "c2", term: "le chat", definition: "die Katze"),
                Card(id: "c3", term: "la maison", definition: "das Haus"),
                Card(id: "c4", term: "un arbre", definition: "der Baum"),
            ]
            let set = VocabSet(id: "s", title: "Wörter", termLang: .fr, defLang: .de, cards: cards, createdAt: LearnTypeAheadTests.T0)
            state = LearnFlow.start(set: set, progress: [:], options: .default, rng: rng, now: now).0
        }

        mutating func send(_ event: LearnFlow.Event) {
            now += 1000
            state = LearnFlow.reduce(state, event, env: LearnFlow.Env(rng: rng, now: now)).0
        }

        mutating func type(_ text: String) {
            for ch in text { send(.key(.character(String(ch)))) }
        }

        var correctText: String {
            state.question.flatMap { q in q.choices.first { $0.cardId == q.cardId }?.text } ?? ""
        }

        var correctIndex: Int? {
            state.question.flatMap { q in q.choices.firstIndex { $0.cardId == q.cardId } }
        }
    }

    @Test("Typing the answer highlights it and Return chooses it")
    func typeAndReturn() {
        var s = Session()
        #expect(s.state.phase == .question(.mc))
        let answer = s.correctText
        s.type(String(answer.prefix(2)))
        // An article (or two letters of it) is not enough.
        #expect(s.state.highlighted == nil)
        #expect(LearnFlow.returnAction(s.state) == nil)
        // All but its last letter: picked, not typed out yet.
        s.type(String(answer.dropFirst(2).dropLast()))
        #expect(s.state.typed == String(answer.dropLast()))
        #expect(s.state.highlighted == s.correctIndex)
        #expect(LearnFlow.returnAction(s.state) == "Auswählen")
        #expect(LearnFlow.optionState(s.state, at: s.correctIndex ?? 0) == .highlighted)
        s.send(.key(.returnKey))
        #expect(s.state.phase == .feedback(.correct))
        #expect(s.state.typed.isEmpty)
    }

    @Test("Typing a whole option chooses it without Return")
    func typedOutChooses() {
        var s = Session()
        let answer = s.correctText
        s.type(answer)
        #expect(s.state.phase == .feedback(.correct))
        #expect(s.state.typed.isEmpty)
    }

    @Test("Typed out means to the end of the option or of an alternative, and only one option fits")
    func typedOut() {
        func out(_ typed: String, _ choices: [String], lang: Lang = .fr) -> Bool {
            LearnFlow.typeAhead(typed, choices: choices, lang: lang).isTypedOut
        }
        let choices = ["la voiture", "le chat", "la maison", "un arbre"]
        #expect(out("la voiture", choices))
        #expect(out("La Voiture", choices))
        #expect(out("voiture", choices))
        #expect(!out("la voitur", choices))
        // "le pain" could still become "le pain de mie": Return picks it.
        let bread = ["le pain", "le pain de mie", "la rue", "le chemin"]
        #expect(Self.pick("le pain", bread) == 0)
        #expect(!out("le pain", bread))
        #expect(out("le pain de mie", bread))
        // One alternative is enough.
        let brain = ["le cerveau, les cerveaux", "le cœur", "la tête", "le bras"]
        #expect(out("le cerveau", brain))
        #expect(out("les cerveaux", brain))
        #expect(!out("le cervea", brain))
        #expect(out("to affect sb", ["to affect sb/ sth", "to cover sb/ sth", "to form", "to revise"], lang: .en))
        // A note in brackets may still follow ("Aussenminister(in)"): Return picks it.
        let minister = ["Aussenminister(in)", "Aussenpolitik", "Bundesrat", "Kanton"]
        #expect(Self.pick("Aussenminister", minister, lang: .de) == 0)
        #expect(!out("Aussenminister", minister, lang: .de))
    }

    @Test("Options the letters do not start fade; ⌫ deletes, esc clears before leaving")
    func filterDeleteAndEscape() {
        var s = Session()
        s.type("la ")
        let filtered = (0..<4).filter { LearnFlow.optionState(s.state, at: $0) == .filtered }
        let texts = s.state.question?.choices.map(\.text) ?? []
        #expect(filtered.map { texts[$0] }.sorted() == ["le chat", "un arbre"])
        s.type("vo")
        #expect(s.state.highlighted.map { texts[$0] } == "la voiture")
        s.send(.key(.deleteBackward))
        #expect(s.state.typed == "la v")
        #expect(s.state.highlighted == nil)
        s.send(.key(.escape))
        #expect(s.state.typed.isEmpty)
        #expect(s.state.phase == .question(.mc))
        // Nothing typed: esc leaves.
        let effects = LearnFlow.reduce(s.state, .key(.escape), env: LearnFlow.Env(rng: s.rng, now: s.now + 1000)).1
        #expect(effects.contains(.navigate(.set)))
    }

    @Test("Held ⌫ keeps deleting, ⌥⌫ deletes a word; other held keys do nothing")
    func deletingWhileHeld() {
        var s = Session()
        s.type("la voi")
        s.send(.key(.deleteWordBackward))
        #expect(s.state.typed == "la ")
        s.type("vo")
        #expect(s.state.highlighted != nil)
        // Held ⌫: the repeats delete too, one letter each.
        s.send(.key(.deleteBackward))
        s.send(.key(.deleteBackward, isRepeat: true))
        #expect(s.state.typed == "la ")
        #expect(s.state.highlighted == nil)
        s.send(.key(.deleteBackward, isRepeat: true))
        s.send(.key(.deleteBackward, isRepeat: true))
        s.send(.key(.deleteBackward, isRepeat: true))
        #expect(s.state.typed.isEmpty)
        // More ⌫ on nothing typed does nothing (and never leaves the question).
        s.send(.key(.deleteBackward, isRepeat: true))
        s.send(.key(.deleteWordBackward))
        #expect(s.state.phase == .question(.mc))
        // A held letter still types only once.
        s.send(.key(.character("x")))
        s.send(.key(.character("x"), isRepeat: true))
        #expect(s.state.typed == "x")
        // ⌥⌫ over trailing spaces takes the word before them.
        s.type("ab cd  ")
        s.send(.key(.deleteWordBackward))
        #expect(s.state.typed == "xab ")
    }

    @Test("Return with letters that pick nothing is rejected; digits and arrows still work")
    func rejectAndOtherKeys() {
        var s = Session()
        s.type("xq")
        let rejections = s.state.rejections
        s.send(.key(.returnKey))
        #expect(s.state.phase == .question(.mc))
        #expect(s.state.rejections == rejections + 1)
        // Arrows take over from typing.
        s.send(.key(.arrow(.down)))
        #expect(s.state.typed.isEmpty)
        #expect(s.state.highlighted == 0)
        // A digit still chooses directly.
        s.type("la")
        s.send(.key(.digit((s.correctIndex ?? 0) + 1)))
        #expect(s.state.phase == .feedback(.correct))
    }

    @Test("A leading space is ignored and the next question starts with nothing typed")
    func resetsBetweenQuestions() {
        var s = Session()
        s.type(" ")
        #expect(s.state.typed.isEmpty)
        s.type("zz")
        s.send(.choose(s.correctIndex ?? 0))
        #expect(s.state.typed.isEmpty)
        s.send(.key(.returnKey))
        #expect(s.state.typed.isEmpty)
        #expect(s.state.highlighted == nil)
    }
}
