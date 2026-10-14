import Testing
import WortschatzCore

// Port of tests/synonyms.test.js. Cards are values in Swift, so "the same card" means the same
// id; JS-only inputs (null cards, non-object entries) cannot reach the typed API.

@Suite("Synonyms")
struct SynonymsTests {
    /// The cards of the user's 52-pair list (term = French, definition = German), ids c1…c52.
    static let cards: [Card] = gradingPairs.enumerated().map { i, pair in
        Card(id: "c\(i + 1)", term: pair.term, definition: pair.definition)
    }

    static func byTerm(_ term: String) -> Card {
        cards.first { $0.term == term } ?? Card(id: "missing", term: term, definition: "")
    }

    static func terms(_ cards: [Card]) -> [String] { cards.map(\.term) }

    /// The prompts that appear on two cards of the user's list (ask .term: the German definition
    /// is shown, the French term is typed).
    static let synonymPairs: [(String, String)] = [
        ("laid, laide", "moche"), // hässlich
        ("le visage", "la figure"), // das Gesicht
        ("brave", "gentil, gentille"), // lieb | lieb, nett
        ("la femme", "la mademoiselle, mesdemoiselles"), // die Frau | das Fräulein, die Frau
    ]

    // MARK: promptSide / answerSide

    @Test("promptSide/answerSide: ask is the side the learner types")
    func sides() {
        let card = Self.byTerm("moche")
        #expect(Synonyms.promptSide(card, ask: .term) == "hässlich")
        #expect(Synonyms.answerSide(card, ask: .term) == "moche")
        #expect(Synonyms.promptSide(card, ask: .definition) == "moche")
        #expect(Synonyms.answerSide(card, ask: .definition) == "hässlich")
    }

    @Test("promptSide/answerSide: leniently decoded cards")
    func sidesOfOddCards() throws {
        #expect(Synonyms.promptSide(try #require(Card(json: ["term": 42])), ask: .definition) == "42")
        #expect(Synonyms.answerSide(try #require(Card(json: ["term": nil])), ask: .term) == "")
    }

    // MARK: findSynonymCards

    @Test("findSynonymCards: the four shared prompts of the user list, both ways")
    func fourSharedPrompts() {
        for (a, b) in Self.synonymPairs {
            #expect(Self.terms(Synonyms.findSynonymCards(Self.cards, card: Self.byTerm(a), ask: .term)) == [b])
            #expect(Self.terms(Synonyms.findSynonymCards(Self.cards, card: Self.byTerm(b), ask: .term)) == [a])
        }
    }

    @Test("findSynonymCards: no other card of the user list has a synonym")
    func noOtherSynonyms() {
        let paired = Set(Self.synonymPairs.flatMap { [$0.0, $0.1] })
        for card in Self.cards {
            if !paired.contains(card.term) {
                #expect(Synonyms.findSynonymCards(Self.cards, card: card, ask: .term).isEmpty, "\(card.term)")
            }
            // Asking for the German side shows distinct French prompts: no synonyms at all.
            #expect(Synonyms.findSynonymCards(Self.cards, card: card, ask: .definition).isEmpty, "\(card.term)")
        }
        // "Frau" (la madame) and "die Frau" (la femme) are different prompts.
        #expect(Synonyms.findSynonymCards(Self.cards, card: Self.byTerm("la madame, mesdames"), ask: .term).isEmpty)
    }

    @Test("findSynonymCards: works when the definition is asked")
    func definitionAsked() {
        let cards = [
            Card(id: "a", term: "la figure", definition: "das Gesicht"),
            Card(id: "b", term: "La Figure", definition: "die Figur"),
            Card(id: "c", term: "le visage", definition: "das Gesicht"),
        ]
        #expect(Synonyms.findSynonymCards(cards, card: cards[0], ask: .definition).map(\.id) == ["b"])
        #expect(Synonyms.findSynonymCards(cards, card: cards[1], ask: .definition).map(\.id) == ["a"])
        #expect(Synonyms.findSynonymCards(cards, card: cards[2], ask: .definition).map(\.id) == [])
        #expect(Synonyms.findSynonymCards(cards, card: cards[0], ask: .term).map(\.id) == ["c"])
    }

    @Test("findSynonymCards: prompts match by alternative, case, ß/ss and punctuation")
    func promptKeys() {
        let cards = [
            Card(id: "1", term: "grand", definition: "gross, hoch"),
            Card(id: "2", term: "haut", definition: "Hoch!"),
            Card(id: "3", term: "gros", definition: "groß"),
            Card(id: "4", term: "large", definition: "breit"),
        ]
        #expect(Synonyms.findSynonymCards(cards, card: cards[0], ask: .term).map(\.id) == ["2", "3"])
        #expect(Synonyms.findSynonymCards(cards, card: cards[2], ask: .term).map(\.id) == ["1"])
        #expect(Synonyms.findSynonymCards(cards, card: cards[3], ask: .term).map(\.id) == [])
    }

    @Test("findSynonymCards: ligatures, hyphens and brackets do not matter")
    func promptKeyNormalisation() {
        let cards = [
            Card(id: "1", term: "le cœur", definition: "das Herz"),
            Card(id: "2", term: "le coeur", definition: "die Mitte"),
            Card(id: "3", term: "e-mail", definition: "die E-Mail"),
            Card(id: "4", term: "le mail", definition: "(die) E Mail"),
        ]
        #expect(Synonyms.findSynonymCards(cards, card: cards[0], ask: .definition).map(\.id) == ["2"])
        #expect(Synonyms.findSynonymCards(cards, card: cards[2], ask: .term).map(\.id) == ["4"])
    }

    @Test("findSynonymCards: skips the card itself, cards with the same id and empty answers")
    func skipsSelfAndEmptyAnswers() {
        let card = Card(id: "x", term: "moche", definition: "hässlich")
        let copy = Card(id: "x", term: "moche", definition: "hässlich") // same id
        let empty = Card(id: "y", term: "  ", definition: "hässlich")
        let other = Card(id: "z", term: "laid", definition: "hässlich")
        #expect(Synonyms.findSynonymCards([card, copy, empty, other], card: card, ask: .term) == [other])
        #expect(Synonyms.findSynonymCards([other], card: other, ask: .term) == [])
        #expect(Synonyms.findSynonymCards([], card: card, ask: .term) == [])
        // A card without a prompt has no synonyms.
        #expect(Synonyms.findSynonymCards([card, other], card: Card(id: "w", term: "x", definition: ""), ask: .term) == [])
    }

    // MARK: gradeWithSynonyms

    @Test("gradeWithSynonyms: a synonym card's answer is accepted, both ways")
    func synonymAnswerAccepted() {
        for (a, b) in Self.synonymPairs {
            for (asked, other) in [(Self.byTerm(a), Self.byTerm(b)), (Self.byTerm(b), Self.byTerm(a))] {
                let given = other.term
                #expect(!Grading.grade(given: given, expected: asked.term, tolerance: Grading.DEFAULT_TOLERANCE, lang: .fr).correct)
                let r = Synonyms.gradeWithSynonyms(
                    given: given, card: asked, cards: Self.cards, ask: .term, tolerance: Grading.DEFAULT_TOLERANCE,
                    answerLang: .fr)
                #expect(r.result.correct, "\(given)")
                #expect(r.result.notes.first == .synonym)
                #expect(!r.result.exact)
                #expect(r.result.hint == nil)
                #expect(r.result.expectedDisplay == asked.term)
                #expect(r.matchedCard == other)
            }
        }
    }

    @Test("gradeWithSynonyms: single forms of a synonym card count, with its tolerance notes")
    func singleForms() {
        let moche = Self.byTerm("moche")
        let r1 = Synonyms.gradeWithSynonyms(given: "laide", card: moche, cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(r1.result.correct)
        #expect(r1.result.notes == [.synonym]) // "partial" describes the other card
        #expect(r1.matchedCard == Self.byTerm("laid, laide"))
        let r2 = Synonyms.gradeWithSynonyms(
            given: "visage", card: Self.byTerm("la figure"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(r2.result.notes == [.synonym, .article])
        let r3 = Synonyms.gradeWithSynonyms(
            given: "gentile", card: Self.byTerm("brave"), cards: Self.cards, ask: .term, tolerance: Tolerance(typos: true),
            answerLang: .fr)
        #expect(r3.result.correct)
        #expect(r3.result.notes == [.synonym, .typo])
        // Tolerances still apply: the typo is wrong with typos off.
        let r4 = Synonyms.gradeWithSynonyms(
            given: "gentile", card: Self.byTerm("brave"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(!r4.result.correct)
    }

    @Test("gradeWithSynonyms: the asked card wins and keeps its own result")
    func askedCardWins() {
        let asked = Self.byTerm("laid, laide")
        let own = Grading.grade(given: "laid", expected: asked.term, lang: .fr)
        let r = Synonyms.gradeWithSynonyms(given: "laid", card: asked, cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(r.result == own)
        #expect(r.matchedCard == nil)
        let exact = Synonyms.gradeWithSynonyms(
            given: "moche", card: Self.byTerm("moche"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(exact.result.exact)
        #expect(exact.result.notes == [])
        #expect(exact.matchedCard == nil)
    }

    @Test("gradeWithSynonyms: answers of unrelated cards stay wrong")
    func unrelatedCards() {
        let cases = [
            ("le garçon", "la fille"),
            ("sage", "brave"), // "brav, artig" is not "lieb"
            ("la madame", "la femme"), // "Frau" is not "die Frau"
            ("joli", "moche"),
        ]
        for (given, askedTerm) in cases {
            let asked = Self.byTerm(askedTerm)
            let r = Synonyms.gradeWithSynonyms(given: given, card: asked, cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
            #expect(r.result == Grading.grade(given: given, expected: asked.term, lang: .fr), "\(given)")
            #expect(r.matchedCard == nil)
        }
        // A wrong answer keeps the asked card's hint.
        let right = Synonyms.gradeWithSynonyms(
            given: "le visage", card: Self.byTerm("la figure"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(right.result.correct)
        let wrong = Synonyms.gradeWithSynonyms(
            given: "la visage", card: Self.byTerm("la figure"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(!wrong.result.correct)
        #expect(wrong.matchedCard == nil)
    }

    @Test("gradeWithSynonyms: works when the definition is asked")
    func gradeDefinitionAsked() {
        let cards = [
            Card(id: "a", term: "la figure", definition: "das Gesicht"),
            Card(id: "b", term: "la figure", definition: "die Figur"),
        ]
        let r = Synonyms.gradeWithSynonyms(given: "Figur", card: cards[0], cards: cards, ask: .definition, tolerance: .default, answerLang: .de)
        #expect(r.result.correct)
        #expect(r.result.notes == [.synonym, .article])
        #expect(r.result.expectedDisplay == "das Gesicht")
        #expect(r.matchedCard == cards[1])
        // The user's list asked for German: distinct French prompts, no synonyms.
        let own = Synonyms.gradeWithSynonyms(
            given: "hässlich", card: Self.byTerm("le visage"), cards: Self.cards, ask: .definition, tolerance: .default,
            answerLang: .de)
        #expect(!own.result.correct)
        #expect(own.matchedCard == nil)
    }

    @Test("gradeWithSynonyms: the closest synonym match is reported")
    func closestMatch() {
        let cards = [
            Card(id: "a", term: "beau", definition: "schön"),
            Card(id: "b", term: "jolie", definition: "schön"),
            Card(id: "c", term: "joli, jolie", definition: "schön, hübsch"),
        ]
        let r = Synonyms.gradeWithSynonyms(given: "jolie", card: cards[0], cards: cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(r.matchedCard == cards[1]) // exact beats partial
        #expect(r.result.notes == [.synonym])
    }

    @Test("gradeWithSynonyms: odd input never matches")
    func oddInput() throws {
        let card = Self.byTerm("moche")
        let junk = try [#require(Card(json: [:])), #require(Card(json: ["term": 1]))]
        for cards in [[], junk] {
            let r = Synonyms.gradeWithSynonyms(given: "laide", card: card, cards: cards, ask: .term, tolerance: .default, answerLang: .fr)
            #expect(!r.result.correct)
            #expect(r.matchedCard == nil)
        }
        let empty = Synonyms.gradeWithSynonyms(given: "", card: card, cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(!empty.result.correct)
        let noAnswer = Synonyms.gradeWithSynonyms(
            given: "x", card: Card(id: "n", term: "", definition: ""), cards: Self.cards, ask: .term, tolerance: .default,
            answerLang: .fr)
        #expect(!noAnswer.result.correct)
    }

    @Test("SynonymGradeResult encodes like JS, with an explicit null matchedCard")
    func resultJSON() throws {
        let miss = Synonyms.gradeWithSynonyms(
            given: "x", card: Self.byTerm("moche"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        let json = try JSONValue(encoding: miss)
        #expect(json["matchedCard"] == .null)
        let hit = Synonyms.gradeWithSynonyms(
            given: "laid", card: Self.byTerm("moche"), cards: Self.cards, ask: .term, tolerance: .default, answerLang: .fr)
        #expect(try JSONValue(encoding: hit)["matchedCard"] == JSONValue(encoding: Self.byTerm("laid, laide")))
    }
}
