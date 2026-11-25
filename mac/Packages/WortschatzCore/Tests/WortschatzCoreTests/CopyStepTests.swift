import Testing
import WortschatzCore

/// When the copy step ("Richtige Antwort abtippen") moves on by itself (`CopyStep.isTypedOut`).
@Suite("Copy step")
struct CopyStepTests {
    func typedOut(_ value: String, _ expected: String, _ lang: Lang = .fr) -> Bool {
        CopyStep.isTypedOut(value, expected: expected, tolerance: .default, lang: lang)
    }

    @Test func exactlyAsShownOrApartFromCaseAndSpacing() {
        #expect(typedOut("le chemin", "le chemin"))
        #expect(typedOut("Le  Chemin ", "le chemin"))
        #expect(typedOut("le/la collègue", "le/la collègue"))
        #expect(typedOut("le cerveau, les cerveaux", "le cerveau, les cerveaux"))
    }

    @Test func acceptedLikeAnAnswerToTheQuestion() {
        #expect(typedOut("le collègue", "le/la collègue"))
        #expect(typedOut("la collègue", "le/la collègue"))
        #expect(typedOut("chemin", "le chemin"))
        #expect(typedOut("les cerveaux", "le cerveau, les cerveaux"))
    }

    @Test func notWhileItIsOnlyTheStartOfTheAnswerAsShown() {
        #expect(!typedOut("le cerveau", "le cerveau, les cerveaux"))
        #expect(!typedOut("le cerveau,", "le cerveau, les cerveaux"))
        #expect(!typedOut("Aussenminister", "Aussenminister(in)", .de))
        #expect(!typedOut("le coeur", "le cœur, les cœurs"))
    }

    @Test func neverWhenWrong() {
        #expect(!typedOut("", "le chemin"))
        #expect(!typedOut("le che", "le chemin"))
        #expect(!typedOut("la route", "le chemin"))
    }
}
