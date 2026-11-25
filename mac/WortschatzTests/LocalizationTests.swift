import Foundation
import Testing
import WortschatzCore

@testable import Wortschatz

/// German and English (Resources/Localizable.xcstrings): the built app carries both, English
/// texts of the app and of the core resolve, and the tests themselves run in German.
@Suite("Sprachen: Deutsch und Englisch")
struct LocalizationTests {
    /// The app's English texts, whatever language the tests run in.
    private func english() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("Die App hat Deutsch und Englisch")
    func localizations() {
        #expect(Set(Bundle.main.localizations).isSuperset(of: ["de", "en"]))
    }

    @Test("Englische Texte der App und des Kerns")
    func englishTexts() throws {
        let en = try english()
        #expect(en.localizedString(forKey: "Abbrechen", value: nil, table: nil) == "Cancel")
        // A core text through `L()`, and a count of `Labels.plural` ("%@ Karten").
        #expect(en.localizedString(forKey: "Richtig!", value: nil, table: nil) == "Correct!")
        let cards = en.localizedString(forKey: "%@ Karten", value: nil, table: nil)
        #expect(CoreText.fill(cards, ["3"]) == "3 cards")
    }

    @Test("Die Tests laufen auf Deutsch")
    @MainActor
    func testsRunInGerman() {
        #expect(AppLanguage.current == "de")
        #expect(Labels.langName(.fr) == "Französisch")
        #expect(Labels.plural(3, "Karte", "Karten") == "3 Karten")
    }
}
