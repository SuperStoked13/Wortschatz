import Testing
import WortschatzCore

@Suite("Parity: layout.js")
struct TextLayoutParityTests {
    @Test("TextLayout matches src/import/layout.js on every fixture case")
    func fixture() throws {
        try runParity("layout") { c in
            switch c.fn {
            case "itemsToLines":
                let items = (c.arg(0).arrayValue ?? []).compactMap(TextItem.init(json:))
                return try encodeToJSONValue(TextLayout.itemsToLines(items, options: LayoutOptions(json: c.arg(1))))
            case "estimateSlope":
                let segments = (c.arg(0).arrayValue ?? []).compactMap(BaselineSegment.init(json:))
                // `{ minWidth = 40 } = {}` (the generator only passes numbers or nothing)
                let minWidth = c.arg(1).objectValue?["minWidth"]?.numberValue ?? 40
                return .number(TextLayout.estimateSlope(segments, minWidth: minWidth))
            case "deskewItems":
                // The generator only passes well-formed items and numeric (or null) slopes.
                let items = try (c.arg(0).arrayValue ?? []).map { try $0.decode(as: TextItem.self) }
                return try encodeToJSONValue(TextLayout.deskewItems(items, slope: c.optionalDouble(1) ?? .nan))
            default:
                return nil
            }
        }
    }
}
