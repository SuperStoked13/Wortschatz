import Testing
import WortschatzCore

@Suite("Parity: ocr.js (fixGermanUmlauts, joinCjk)")
struct OCRPostprocessParityTests {
    @Test("OCRPostprocess matches src/import/ocr.js on every fixture case")
    func fixture() throws {
        try runParity("ocr") { c in
            switch c.fn {
            case "fixGermanUmlauts":
                return try encodeToJSONValue(OCRPostprocess.fixGermanUmlauts(Self.lines(c.arg(0))))
            case "ocrPlainText":
                // ocrDataToText({ text, words: [] }): the plain-text fallback.
                return .string(OCRPostprocess.plainTextLines(try c.string(0)).joined(separator: "\n"))
            default:
                return nil
            }
        }
    }

    /// `Array.isArray(lines) ? lines.map((l) => (l == null ? '' : String(l))) : []`
    static func lines(_ v: JSONValue) -> [String] {
        guard case let .array(entries) = v else { return [] }
        return entries.map { LangDetectParityTests.jsString($0) ?? "" }
    }
}
