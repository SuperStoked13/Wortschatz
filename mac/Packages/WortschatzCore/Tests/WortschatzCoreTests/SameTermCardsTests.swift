import Testing
import WortschatzCore

// Same cases as SameTermCardsTests.cs of the Windows app.

@Suite("SameTermCards")
struct SameTermCardsTests {
    static let hijack = Card(id: "h", term: "to hijack sth", definition: "etw. entführen")
    static let kidnap = Card(id: "k", term: "to kidnap sb", definition: "jmdn. entführen")
    static let spark = Card(id: "s", term: "to spark sth", definition: "etw. entfachen")
    static let cards = [hijack, kidnap, spark]

    /// The German side is the prompt, the English side the answer.
    static func find(_ given: String, _ card: Card, _ cards: [Card] = cards, tolerance: Tolerance = .default) -> Card? {
        SameTermCards.answerOfOtherCard(
            given, card: card, cards: cards, ask: .term, tolerance: tolerance, promptLang: .de, answerLang: .en)
    }

    @Test func theOtherCardsAnswerForTheSameWordIsFound() {
        #expect(Self.find("to kidnap sb", Self.hijack) == Self.kidnap)
        #expect(Self.find("to hijack sth", Self.kidnap) == Self.hijack)
    }

    @Test func theSessionsToleranceDecides() {
        #expect(Self.find("to kidnapp sb", Self.hijack) == nil)
        var typos = Tolerance.default
        typos.typos = true
        #expect(Self.find("to kidnapp sb", Self.hijack, tolerance: typos) == Self.kidnap)
    }

    @Test func anotherWordOrAnyOtherAnswerIsNotTheSameTerm() {
        #expect(Self.find("to spark sth", Self.hijack) == nil)
        #expect(Self.find("to steal sth", Self.hijack) == nil)
        #expect(Self.find("", Self.hijack) == nil)
    }

    @Test func bracketsArticlesAndAlternativesDoNotMatter() {
        let a = Card(id: "a", term: "the weapons", definition: "die Waffen (Pl.)")
        let b = Card(id: "b", term: "arms", definition: "Waffen, Rüstung")
        #expect(Self.find("arms", a, [a, b]) == b)
        #expect(Self.find("the weapons", b, [a, b]) == a)
    }

    @Test func itWorksTheOtherWayRoundToo() {
        let a = Card(id: "a", term: "to kidnap sb", definition: "jmdn. entführen")
        let b = Card(id: "b", term: "to kidnap sth", definition: "etw. verschleppen")
        #expect(
            SameTermCards.answerOfOtherCard(
                "etw. verschleppen", card: a, cards: [a, b], ask: .definition, tolerance: .default, promptLang: .en,
                answerLang: .de) == b)
    }

    @Test func theTermKeyLeavesOutPlaceholders() {
        #expect(SameTermCards.termKeys("etw. entführen", lang: .de).contains("entfuhren"))
        #expect(SameTermCards.termKeys("jmdn. entführen", lang: .de).contains("entfuhren"))
        #expect(SameTermCards.termKeys("to kidnap sb", lang: .en).contains("kidnap"))
    }
}
