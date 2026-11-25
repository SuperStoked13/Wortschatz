import Foundation
import Testing
import WortschatzCore

/// Long words in study texts shrink to about 70 % at most, then break at syllables with «-»
/// (`LongWords`, Windows' StudyText.FitWords). Widths here: half the size per character.
@Suite("Long words: shrink a little, then break at syllables")
struct LongWordsTests {
    static func width(_ text: String, _ size: Double) -> Double { Double(text.count) * size * 0.5 }

    /// «Ge-schwin-dig-keits-be-gren-zung», as the system's German hyphenation has it.
    static func points(_ word: String) -> [Int] {
        word == "Geschwindigkeitsbegrenzung" ? [2, 8, 11, 16, 18, 22] : []
    }

    @Test func theFloorIsAboutSeventyPercentNeverBelow26() {
        #expect(abs(LongWords.floor(46) - 32.2) < 0.001)
        #expect(LongWords.floor(36) == 26)
        #expect(LongWords.floor(22) == 22)
    }

    @Test func wordsThatFitStayAsTheyAre() {
        let r = LongWords.fit(
            "la maison", size: 40, floor: 28, maxWidth: 600, width: Self.width, points: Self.points)
        #expect(r.size == 40)
        #expect(r.text == "la maison")
    }

    @Test func aLongWordShrinksAtMostToTheFloorThenBreaksAtSyllables() {
        // 26 letters: 520 wide at 40, 364 at 28 – the line is 300.
        let r = LongWords.fit(
            "die Geschwindigkeitsbegrenzung", size: 40, floor: 28, maxWidth: 300, width: Self.width,
            points: Self.points)
        #expect(r.size == 28)
        #expect(r.text == "die Geschwindigkeitsbe-grenzung")
        // Each piece with its «-» fits the line.
        for piece in r.text.split(separator: " ").last!.split(separator: "-") {
            #expect(Self.width(String(piece) + "-", r.size) <= 296)
        }
    }

    @Test func aNarrowLineTakesAsManySyllablesAsFitEachTime() {
        let text = LongWords.breakLongWords(
            "Geschwindigkeitsbegrenzung", size: 20, maxWidth: 104, width: Self.width, points: Self.points)
        #expect(text == "Geschwin-digkeits-begrenzung")
    }

    @Test func shrinkingAloneIsEnoughWhenTheWordFitsAboveTheFloor() {
        let r = LongWords.fit(
            "Geschwindigkeitsbegrenzung", size: 40, floor: 28, maxWidth: 420, width: Self.width, points: Self.points)
        #expect(r.size == 32)
        #expect(r.text == "Geschwindigkeitsbegrenzung")
    }

    @Test func anExistingHyphenIsABreakAndGetsNoSecondOne() {
        let text = LongWords.breakLongWords(
            "Rhein-Main-Gebietsverkehrsverbund", size: 20, maxWidth: 150, width: Self.width, points: { _ in [] })
        #expect(text == "Rhein-Main-Gebietsverkehrsverbund")
        let narrow = LongWords.breakLongWords(
            "Rhein-Main-Flughafen", size: 20, maxWidth: 120, width: Self.width, points: { _ in [] })
        #expect(narrow == "Rhein-Main-Flughafen")
    }

    @Test func withoutSyllablesAWordStaysAndSpacesAreKept() {
        let text = LongWords.breakLongWords(
            "مستشفىمستشفىمستشفى  ok", size: 40, maxWidth: 100, width: Self.width, points: { _ in [] })
        #expect(text == "مستشفىمستشفىمستشفى  ok")
    }
}
