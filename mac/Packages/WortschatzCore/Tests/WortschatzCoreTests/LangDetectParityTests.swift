import Testing
import WortschatzCore

@Suite("Parity: langdetect.js")
struct LangDetectParityTests {
    @Test("LangDetect matches src/core/langdetect.js on every fixture case")
    func fixture() throws {
        try runParity("langdetect") { c in
            switch c.fn {
            case "scoreLanguages":
                return try encodeToJSONValue(LangDetect.scoreLanguages(Self.jsString(c.arg(0))))
            case "detectLanguage":
                return try encodeToJSONValue(LangDetect.detectLanguage(Self.jsString(c.arg(0))))
            case "detectColumn":
                return try encodeToJSONValue(LangDetect.detectColumn(Self.columnLines(c.arg(0))))
            default:
                return nil
            }
        }
    }

    /// `String(v)` as the JS code applies it to any argument (`text == null ? '' : String(text)`);
    /// nil for null / undefined.
    static func jsString(_ v: JSONValue) -> String? {
        switch v {
        case .null: return nil
        case let .string(s): return s
        case let .number(n): return JSCompat.numberToString(n)
        case let .bool(b): return b ? "true" : "false"
        case let .array(a): return a.map { jsString($0) ?? "" }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// `Array.isArray(lines) ? lines : lines == null ? [] : [lines]`, every entry as `String(line)`
    /// (null entries score like '').
    static func columnLines(_ v: JSONValue) -> [String] {
        switch v {
        case let .array(a): return a.map { jsString($0) ?? "" }
        case .null: return []
        default: return [jsString(v) ?? ""]
        }
    }
}
