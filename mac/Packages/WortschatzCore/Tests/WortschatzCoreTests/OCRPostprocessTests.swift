import Testing
import WortschatzCore

// Port of the fixGermanUmlauts cases of tests/layout.test.js, plus edge cases of the Swift port.
@Suite("OCRPostprocess (fixGermanUmlauts)")
struct OCRPostprocessTests {
    @Test("Restores umlauts read as circumflexes in German cells only")
    func germanCellsOnly() {
        #expect(
            OCRPostprocess.fixGermanUmlauts([
                "le chat\tdie Katze", "beau\tschôn", "le rôle\tdie Rolle", "vert\tgrûn", "fatigué\tmûde",
                "à côté de\tneben", "la porte\tdie Tûr",
            ]) == [
                "le chat\tdie Katze", "beau\tschön", "le rôle\tdie Rolle", "vert\tgrün", "fatigué\tmüde",
                "à côté de\tneben", "la porte\tdie Tür",
            ])
    }

    @Test("Without columns only clearly German lines change")
    func singleLines() {
        #expect(
            OCRPostprocess.fixGermanUmlauts([
                "tôt", "früh", "le rôle", "die Rolle", "beau", "schôn", "la porte", "die Tûr", "brûler", "brennen",
            ]) == ["tôt", "früh", "le rôle", "die Rolle", "beau", "schön", "la porte", "die Tür", "brûler", "brennen"])
    }

    @Test("Upper case cells and French circumflexes")
    func upperCaseAndFrench() {
        #expect(
            OCRPostprocess.fixGermanUmlauts(["LA PORTE\tDIE TÛR", "le chat\tdie Katze", "le chien\tder Hund"])
                == ["LA PORTE\tDIE TÜR", "le chat\tdie Katze", "le chien\tder Hund"])
        let french = ["le château\tdas Schloss", "le gâteau\tder Kuchen", "âgé\talt"]
        #expect(OCRPostprocess.fixGermanUmlauts(french) == french)
    }

    @Test("Empty input and text without circumflexes are returned unchanged")
    func unchanged() {
        #expect(OCRPostprocess.fixGermanUmlauts([]) == [])
        #expect(OCRPostprocess.fixGermanUmlauts(["", "\t", "die Katze"]) == ["", "\t", "die Katze"])
    }

    @Test("Decomposed circumflexes are left alone, like the JS regex")
    func decomposed() {
        let lines = ["scho\u{302}n\tbeau", "die Tu\u{302}r\tla porte"]
        let out = OCRPostprocess.fixGermanUmlauts(lines)
        #expect(out.map { Array($0.unicodeScalars) } == lines.map { Array($0.unicodeScalars) })
    }

    @Test("Empty cells keep the column positions")
    func emptyCells() {
        #expect(
            OCRPostprocess.fixGermanUmlauts(["le chat\t\tdie Katze", "beau\t\tschôn", "la porte\t\tdie Tûr"])
                == ["le chat\t\tdie Katze", "beau\t\tschön", "la porte\t\tdie Tür"])
    }
}
