import Testing
import WortschatzCore

@Suite("Parity: text.js")
struct TextParityTests {
    @Test("TextNormalizer matches src/core/text.js on every fixture case")
    func fixture() throws {
        try runParity("text") { c in
            switch c.fn {
            case "normalizeBasic":
                return .string(TextNormalizer.normalizeBasic(c.optionalString(0), keepTabs: try c.bool(1)))
            case "stripDiacritics":
                return .string(TextNormalizer.stripDiacritics(try c.string(0)))
            case "foldUmlauts":
                return .string(TextNormalizer.foldUmlauts(try c.string(0)))
            case "isLetter":
                return .bool(TextNormalizer.isLetter(try c.string(0)))
            default:
                return nil
            }
        }
    }
}
