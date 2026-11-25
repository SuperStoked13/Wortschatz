import Testing
@testable import WortschatzCore

/// Replays Fixtures/wordclass.json (mac/Parity/gen-wordclass.js): side profiles, the class of texts
/// with every kind of side, card classes of every fixture list and fuzzed lists, option shapes and
/// similarity points, compared with src/core/wordclass.js.
@Suite("Parity: wordclass.js")
struct WordClassParityTests {
    struct BadSide: Error, CustomStringConvertible {
        let value: JSONValue
        var description: String { "bad side \(ParityDiff.describe(value))" }
    }

    static func side(_ v: JSONValue) throws -> WordClass.SideProfile {
        guard let o = v.objectValue, let lang = DetectedLanguage(rawValue: o["lang"]?.stringValue ?? "") else {
            throw BadSide(value: v)
        }
        return WordClass.SideProfile(
            lang: lang, wordCaps: o["wordCaps"]?.boolValue ?? false, capsNoun: o["capsNoun"]?.boolValue ?? false,
            capsRare: o["capsRare"]?.boolValue ?? false)
    }

    static func shape(_ v: JSONValue) -> WordClass.OptionShape {
        WordClass.OptionShape(
            article: v["article"]?.stringValue ?? "", head: v["head"]?.stringValue ?? "",
            words: v["words"]?.integerValue ?? 0, length: v["length"]?.integerValue ?? 0)
    }

    static func texts(_ v: JSONValue) -> [String] { (v.arrayValue ?? []).map { $0.stringValue ?? "" } }

    @Test("WordClass matches src/core/wordclass.js on every fixture case")
    func fixture() throws {
        try runParity("wordclass") { c in
            switch c.fn {
            case "sideProfile":
                return try encodeToJSONValue(WordClass.sideProfile(Self.texts(c.arg(0))))
            case "textClass":
                return try encodeToJSONValue(WordClass.textClass(c.arg(0).stringValue ?? "", side: Self.side(c.arg(1))))
            case "optionShape":
                return try encodeToJSONValue(WordClass.optionShape(c.arg(0).stringValue ?? "", side: Self.side(c.arg(1))))
            case "cardClasses":
                let cards = (c.arg(0).arrayValue ?? []).map { v in
                    Card(id: "", term: v["term"]?.stringValue ?? "", definition: v["definition"]?.stringValue ?? "")
                }
                let sides = WordClass.listProfiles(cards)
                return [
                    "sides": try encodeToJSONValue(sides),
                    "classes": .array(cards.map { .string(WordClass.cardClass($0, sides: sides)) }),
                ]
            case "shapePoints":
                return .number(Double(WordClass.shapePoints(Self.shape(c.arg(0)), Self.shape(c.arg(1)))))
            case "nearPoints":
                return .number(Double(WordClass.nearPoints(c.arg(0).integerValue ?? 0)))
            default:
                return nil
            }
        }
    }
}
