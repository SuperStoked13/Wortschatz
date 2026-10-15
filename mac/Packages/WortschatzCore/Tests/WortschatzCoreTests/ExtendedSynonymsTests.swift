import Testing
import WortschatzCore

/// Synonyms that are not in the set: the pure helpers around the on-device model's lists, and
/// grading with `extraAnswers` in Learn and Write mode.
@Suite("Extended synonyms")
struct ExtendedSynonymsTests {
    static let T0: Double = 1_760_000_000_000

    static let cards: [Card] = [
        Card(id: "c1", term: "en commun", definition: "gemeinsam"),
        Card(id: "c2", term: "le chat", definition: "die Katze"),
        Card(id: "c3", term: "la voiture", definition: "das Auto"),
        Card(id: "c4", term: "rapide", definition: "schnell"),
    ]

    static let query = SynonymQuery(prompt: "gemeinsam", expected: "en commun", promptLang: .de, answerLang: .fr)

    static func wrong(_ given: String, expected: String = "en commun") -> GradeResult {
        Grading.grade(given: given, expected: expected, tolerance: .default, lang: .fr)
    }

    // MARK: looseKey

    @Test("looseKey: case, accents, ß, articles, pronouns and notes do not matter")
    func looseKeys() {
        #expect(ExtendedSynonyms.looseKey("La Voiture", lang: .fr) == "voiture")
        #expect(ExtendedSynonyms.looseKey("l’été", lang: .fr) == "ete")
        #expect(ExtendedSynonyms.looseKey("die Straße", lang: .de) == "strasse")
        #expect(ExtendedSynonyms.looseKey("sich beeilen", lang: .de) == "beeilen")
        #expect(ExtendedSynonyms.looseKey("le boulot (fam.)", lang: .fr) == "boulot")
        #expect(ExtendedSynonyms.looseKey("peut-être", lang: .fr) == "peut etre")
        // An article alone stays a word.
        #expect(ExtendedSynonyms.looseKey("la", lang: .fr) == "la")
    }

    // MARK: Model lists

    @Test("cleanTranslations: splits alternatives, drops notes, quotes and duplicates")
    func cleaning() {
        #expect(ExtendedSynonyms.cleanTranslations(["ensemble", "ensemble", "Ensemble"], lang: .fr) == ["ensemble"])
        #expect(
            ExtendedSynonyms.cleanTranslations(["das Auto, der Wagen", "das Fahrzeug (n)", "\"Auto\""], lang: .de)
                == ["das Auto", "der Wagen", "das Fahrzeug"])
        #expect(ExtendedSynonyms.cleanTranslations(["", "…", "  "], lang: .fr).isEmpty)
        let many = (1...20).map { "mot\($0)" }
        #expect(ExtendedSynonyms.cleanTranslations(many, lang: .fr).count == 8)
    }

    @Test("matchingTranslation: the learner's tolerance applies")
    func forwardMatch() {
        #expect(
            ExtendedSynonyms.matchingTranslation("ensemble", in: ["collectivement", "ensemble"], tolerance: .default, lang: .fr)
                == "ensemble")
        // Articles are optional by default.
        #expect(
            ExtendedSynonyms.matchingTranslation("automobile", in: ["l'automobile"], tolerance: .default, lang: .fr)
                == "l'automobile")
        #expect(ExtendedSynonyms.matchingTranslation("le camion", in: ["la voiture"], tolerance: .default, lang: .fr) == nil)
    }

    @Test("confirmsPrompt: the answer translated back gives the prompt (or an alternative) first")
    func backMatch() {
        #expect(ExtendedSynonyms.confirmsPrompt(["gemeinsam", "zusammen"], prompt: "gemeinsam", lang: .de))
        #expect(ExtendedSynonyms.confirmsPrompt(["das Auto", "das Fahrzeug"], prompt: "das Auto", lang: .de))
        #expect(ExtendedSynonyms.confirmsPrompt(["nett", "freundlich"], prompt: "lieb, nett", lang: .de))
        #expect(ExtendedSynonyms.confirmsPrompt(["groß"], prompt: "gross", lang: .de))
        #expect(!ExtendedSynonyms.confirmsPrompt(["die Katze"], prompt: "der Hund", lang: .de))
        #expect(!ExtendedSynonyms.confirmsPrompt(["alles zusammen"], prompt: "gemeinsam", lang: .de))
        #expect(!ExtendedSynonyms.confirmsPrompt([], prompt: "gemeinsam", lang: .de))
        // Further down the list the model drifts into related words: "le loup" → … der Hund.
        #expect(!ExtendedSynonyms.confirmsPrompt(["der Wolf", "der Löwe", "der Hund"], prompt: "der Hund", lang: .de))
        #expect(!ExtendedSynonyms.confirmsPrompt(["die Straße", "der Weg"], prompt: "der Weg", lang: .de))
    }

    @Test("translationRequest: names both languages, never breaks the quotes")
    func request() {
        #expect(
            ExtendedSynonyms.translationRequest("gemeinsam", from: .de, to: .fr)
                == "Translate the German word or phrase \"gemeinsam\" into French.")
        #expect(
            ExtendedSynonyms.translationRequest("der \"Hund\"", from: .de, to: .en)
                == "Translate the German word or phrase \"der 'Hund'\" into English.")
        #expect(ExtendedSynonyms.translationRequest("x", from: .other, to: .fr) == nil)
    }

    // MARK: worthChecking

    @Test("worthChecking: a different word is checked")
    func checksDifferentWords() {
        let card = Self.cards[0]
        #expect(
            ExtendedSynonyms.worthChecking(
                given: "ensemble", result: Self.wrong("ensemble"), query: Self.query, card: card, cards: Self.cards,
                ask: .term))
    }

    @Test("worthChecking: near misses, the prompt, other cards, sentences and odd languages are not")
    func skipsObviousMisses() {
        let card = Self.cards[0]
        func worth(_ given: String, query: SynonymQuery = Self.query) -> Bool {
            ExtendedSynonyms.worthChecking(
                given: given, result: Self.wrong(given), query: query, card: card, cards: Self.cards, ask: .term)
        }
        // A typo of the card's answer (hint "Fast – ein kleiner Tippfehler").
        #expect(Self.wrong("en comun").hint != nil)
        #expect(!worth("en comun"))
        // The prompt typed again.
        #expect(!worth("gemeinsam"))
        // Another card's answer: two cards mixed up.
        #expect(!worth("le chat"))
        #expect(!worth("chat"))
        // Sentences, empty or letter-less answers.
        #expect(!worth("nous faisons tout cela ensemble chaque jour"))
        #expect(!worth("   "))
        #expect(!worth("123"))
        // Languages the model is not asked about, or the same language on both sides.
        #expect(!worth("ensemble", query: SynonymQuery(prompt: "gemeinsam", expected: "en commun", promptLang: .de, answerLang: .other)))
        #expect(!worth("ensemble", query: SynonymQuery(prompt: "gemeinsam", expected: "en commun", promptLang: .fr, answerLang: .fr)))
        // A correct answer needs no check.
        #expect(
            !ExtendedSynonyms.worthChecking(
                given: "en commun", result: Self.wrong("en commun"), query: Self.query, card: card, cards: Self.cards,
                ask: .term))
    }

    // MARK: Grading

    @Test("gradeWithSynonyms: an extra answer counts, marked as a synonym outside the set")
    func gradesExtraAnswers() {
        let graded = Synonyms.gradeWithSynonyms(
            given: "ensemble", card: Self.cards[0], cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr,
            extraAnswers: ["collectivement", "ensemble"])
        #expect(graded.result.correct)
        #expect(!graded.result.exact)
        #expect(graded.result.notes == [.extendedSynonym])
        #expect(graded.result.expectedDisplay == "en commun")
        #expect(graded.matchedCard == nil)
        #expect(graded.isSynonym)
        #expect(Labels.NOTE_LABELS[.extendedSynonym] == "Synonym – nicht im Set")
    }

    @Test("gradeWithSynonyms: tolerances apply to extra answers too")
    func toleranceOnExtraAnswers() {
        let tolerant = Tolerance(ignoreAccents: true)
        let graded = Synonyms.gradeWithSynonyms(
            given: "debuter", card: Self.cards[0], cards: Self.cards, ask: .term, tolerance: tolerant, answerLang: .fr,
            extraAnswers: ["débuter"])
        #expect(graded.result.correct)
        #expect(graded.result.notes.first == .extendedSynonym)
        #expect(graded.result.notes.contains(.accents))
    }

    @Test("gradeWithSynonyms: no extra answers, no match, or another card's answer stay wrong")
    func extraAnswersStayStrict() {
        func grade(_ given: String, _ extras: [String]) -> SynonymGradeResult {
            Synonyms.gradeWithSynonyms(
                given: given, card: Self.cards[0], cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr,
                extraAnswers: extras)
        }
        #expect(!grade("ensemble", []).result.correct)
        #expect(!grade("ensemble", ["collectivement"]).result.correct)
        // The model listed a word that is another card's answer: a mix-up, not a synonym.
        #expect(!grade("le chat", ["le chat"]).result.correct)
        // The model repeated the prompt: typing the prompt again is no answer.
        #expect(!grade("gemeinsam", ["gemeinsam", "ensemble"]).result.correct)
        // The card's own answer stays exact.
        let own = grade("en commun", ["ensemble"])
        #expect(own.result.exact && !own.isSynonym)
    }

    @Test("Learn: a written answer from outside the set is right, marked and shows the card's answer")
    func learnFlowAcceptsExtraAnswers() throws {
        let set = VocabSet(id: "s", title: "Wörter", termLang: .fr, defLang: .de, cards: Self.cards, createdAt: Self.T0)
        var progress: ProgressMap = [:]
        for c in Self.cards {
            progress[c.id] = CardProgress(correct: 1, streak: 1, lastResult: .correct, lastAnsweredAt: Self.T0 - 1000)
        }
        let rng = mulberry32(seed: 3)
        var (state, _) = LearnFlow.start(
            set: set, progress: progress, options: StudyOptions(learn: LearnOptions(mc: false, written: true)),
            rng: rng, now: Self.T0)
        let q = try #require(state.question)
        #expect(state.phase == .question(.written))
        let extras: [SynonymQuery: [String]] = [q.synonymQuery: ["mot inventé"]]
        let env = LearnFlow.Env(
            rng: rng, now: Self.T0 + 2000, progress: progress, extraAnswers: { extras[$0] ?? [] })
        (state, _) = LearnFlow.reduce(state, .submit("mot inventé"), env: env)
        #expect(state.phase == .feedback(.correct))
        let f = try #require(state.feedback)
        #expect(f.synonym)
        #expect(f.title == LearnFlow.SYNONYM_TITLE)
        #expect(f.exactLabel == "Gesucht war:")
        #expect(f.result?.notes == [.extendedSynonym])
        #expect(f.result?.expectedDisplay == q.expected)
    }

    @Test("Write: gradeQuestion accepts extra answers")
    func writeFlowAcceptsExtraAnswers() {
        let set = VocabSet(id: "s", title: "Wörter", termLang: .fr, defLang: .de, cards: Self.cards, createdAt: Self.T0)
        let question = WriteFlow.Question(
            qid: "q1", cardId: "c1", ask: .term, prompt: "gemeinsam", expected: "en commun", promptLang: .de,
            answerLang: .fr, promptLabel: "Deutsch", placeholder: "", placeholderShort: "", starred: false)
        #expect(question.synonymQuery == Self.query)
        let graded = WriteFlow.gradeQuestion(
            set: set, question: question, given: "ensemble", tolerance: .default, extraAnswers: ["ensemble"])
        #expect(graded.result.correct && graded.isSynonym)
        let feedback = WriteFlow.Feedback(given: "ensemble", result: graded.result, dontKnow: false, synonym: true)
        #expect(feedback.exactLabel == "Gesucht war:")
        #expect(feedback.notes.map(\.note) == [.extendedSynonym])
        #expect(feedback.notes.allSatisfy { $0.isSynonym })
    }

    // MARK: Arabic and Chinese

    @Test("The model is asked about Chinese, not Arabic")
    func scriptLanguages() {
        #expect(ExtendedSynonyms.modelLanguageNames[.zh] == "Chinese")
        #expect(ExtendedSynonyms.modelLanguageNames[.ar] == nil)
        let zh = SynonymQuery(prompt: "Hallo", expected: "你好 (nǐ hǎo)", promptLang: .de, answerLang: .zh)
        #expect(ExtendedSynonyms.supports(zh))
        let ar = SynonymQuery(prompt: "Buch", expected: "كتاب", promptLang: .de, answerLang: .ar)
        #expect(!ExtendedSynonyms.supports(ar))
        #expect(ExtendedSynonyms.translationRequest("Hallo", from: .de, to: .zh) == "Translate the German word or phrase \"Hallo\" into Chinese.")
    }

    @Test("looseKey: Arabic marks, tatweel, ال and full-width punctuation do not matter")
    func scriptLooseKeys() {
        #expect(ExtendedSynonyms.looseKey("الكِتَابُ", lang: .ar) == "كتاب")
        #expect(ExtendedSynonyms.looseKey("كتـــاب", lang: .ar) == "كتاب")
        #expect(ExtendedSynonyms.looseKey("ﻛﺘﺎﺏ", lang: nil) == "كتاب")
        #expect(ExtendedSynonyms.looseKey("你 好！", lang: .zh) == "你好")
        #expect(ExtendedSynonyms.looseKey("你好（nǐ hǎo）", lang: .zh) == "你好")
        #expect(ExtendedSynonyms.looseKey("nǐ hǎo", lang: .zh) == "ni hao")
    }
}
