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
