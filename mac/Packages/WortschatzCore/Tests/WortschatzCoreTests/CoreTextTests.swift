import Testing
import WortschatzCore

@Suite("CoreText")
struct CoreTextTests {
    @Test("%@ takes the arguments in order")
    func sequential() {
        #expect(CoreText.fill("Runde %@: %@ von %@", ["2", "3", "5"]) == "Runde 2: 3 von 5")
    }

    @Test("%1$@ … pick an argument, so a translation can reorder them")
    func numbered() {
        #expect(CoreText.fill("%2$@ of %1$@ right", ["5", "3"]) == "3 of 5 right")
    }

    @Test("%% is a percent sign, a lone % stays")
    func percent() {
        #expect(CoreText.fill("%@ %%", ["42"]) == "42 %")
        #expect(CoreText.fill("50 % Rabatt", []) == "50 % Rabatt")
        #expect(CoreText.fill("Ende %", []) == "Ende %")
    }

    @Test("Missing arguments become empty, extra ones are ignored")
    func argumentCount() {
        #expect(CoreText.fill("%@ und %@", ["a"]) == "a und ")
        #expect(CoreText.fill("nur %@", ["a", "b"]) == "nur a")
    }

    @Test("Without the app the texts stay German")
    func defaultIsGerman() {
        #expect(CoreText.translate("Richtig!") == "Richtig!")
    }
}
