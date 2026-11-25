import Foundation

/// A backup file that cannot be read or is not a JSON object (message for the UI).
public struct BackupFileError: Error, Equatable, Sendable, LocalizedError {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Port of src/store/backup.js (the pure parts; save panels and file access are the app's job),
/// plus the file names of the web app's downloads.
public enum Backup {
    /// `READ_ERROR`
    public static var READ_ERROR: String { L("Die Datei konnte nicht gelesen werden.") }
    /// `PARSE_ERROR`
    public static var PARSE_ERROR: String { L("Die Datei ist keine gültige Backup-Datei (JSON).") }

    // MARK: Text export

    /// Quizlet-compatible text export (default: term TAB definition, one card per line). Line
    /// breaks/tabs inside a field become spaces; with ";" between cards a ";" inside a field
    /// becomes ", "; a field that still contains a separator is quoted CSV-style.
    public static func setToText(_ set: VocabSet, termSep: String = "\t", cardSep: String = "\n") -> String {
        setToText(cards: set.cards, termSep: termSep, cardSep: cardSep)
    }

    /// `setToText` for a card list (cards with both sides blank are left out).
    public static func setToText(cards: [Card], termSep: String = "\t", cardSep: String = "\n") -> String {
        cards
            .filter { !JSCompat.trim($0.term).isEmpty || !JSCompat.trim($0.definition).isEmpty }
            .map { exportField($0.term, termSep, cardSep) + termSep + exportField($0.definition, termSep, cardSep) }
            .joined(separator: cardSep)
    }

    /// One field of the text export (`exportField` of backup.js).
    static func exportField(_ value: String, _ termSep: String, _ cardSep: String) -> String {
        var s = Array(value.unicodeScalars)
        s = collapseRuns(s, where: { $0 == "\r" || $0 == "\n" || $0 == "\t" }, minimum: 1)
        if JSCompat.identical(JSCompat.trim(cardSep), ";") { s = replaceSemicolons(s) }
        s = collapseRuns(s, where: { $0 == " " }, minimum: 2)
        var text = JSCompat.trim(string(s))
        let clashes = [termSep, cardSep].contains { sep in
            !sep.isEmpty && !JSCompat.trim(sep).isEmpty && contains(text, sep)
        }
        if clashes {
            text = "\"" + string(Array(text.unicodeScalars).flatMap { $0 == "\"" ? ["\"", "\""] : [$0] }) + "\""
        }
        return text
    }

    // MARK: Backup files

    /// `readJsonFile`: parses a backup file's bytes (UTF-8, a leading byte order mark is
    /// ignored) with the rules of JS `JSON.parse` (strict grammar, the last of duplicate keys
    /// wins). Throws `BackupFileError(PARSE_ERROR)` unless the content is a JSON object.
    public static func readJSON(_ data: Data) throws -> JSONValue {
        // The browser's UTF-8 decoding drops one BOM, readJsonFile another one.
        var scalars = Substring(String(decoding: data, as: UTF8.self)).unicodeScalars
        for _ in 0..<2 where scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var parser = BackupJSONParser(String(scalars))
        guard let json = parser.parseDocument(), json.isObject else { throw BackupFileError(message: PARSE_ERROR) }
        return json
    }

    /// `downloadJson` content: the backup formatted like `JSON.stringify(data, null, 2)` of the
    /// web app, with its key order (maps such as progress or activity sorted), so exports are
    /// deterministic and look the same from both apps.
    public static func jsonData(_ backup: BackupDocument) throws -> Data {
        Data(jsonText(try JSONValue(encoding: backup)).utf8)
    }

    /// `JSON.stringify(value, null, 2)` with the web app's key order for known objects (see
    /// `jsonData`); non-finite numbers are written as `null` like in JS.
    public static func jsonText(_ value: JSONValue) -> String {
        var out = ""
        BackupJSONWriter.write(value, indent: "", into: &out)
        return out
    }

    /// The web app's backup file name: "wortschatz-backup-YYYY-MM-DD.json" (local day).
    public static func backupFileName(now: Double = TimeUtil.nowMs(), timeZone: TimeZone = .current) -> String {
        "wortschatz-backup-\(TimeUtil.dateKey(now, timeZone: timeZone)).json"
    }

    /// The web app's text export file name (`fileNameFor` of set.js): the NFC title without
    /// characters that are invalid in file names, whitespace collapsed, at most 80 UTF-16 units,
    /// "Lernset" when empty, plus ".txt".
    public static func textFileName(for title: String) -> String {
        let scalars = Array(JSCompat.nfc(title).unicodeScalars)
        let invalid: (Unicode.Scalar) -> Bool = { u in u.value < 0x20 || "\\/:*?\"<>|".unicodeScalars.contains(u) }
        var s = collapseRuns(scalars, where: invalid, minimum: 1)
        s = collapseRuns(s, where: JSCompat.isWhitespace, minimum: 1)
        let trimmed = JSCompat.trim(string(s))
        var base = String.UnicodeScalarView()
        var units = 0
        for u in trimmed.unicodeScalars {
            let width = u.value > 0xFFFF ? 2 : 1
            if units + width > 80 { break }
            units += width
            base.append(u)
        }
        return (base.isEmpty ? "Lernset" : String(base)) + ".txt"
    }

    // MARK: Private

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Replaces every run of at least `minimum` matching scalars with one space (`/x{n,}/g → ' '`).
    private static func collapseRuns(
        _ s: [Unicode.Scalar], where matches: (Unicode.Scalar) -> Bool, minimum: Int
    ) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            guard matches(s[i]) else {
                out.append(s[i])
                i += 1
                continue
            }
            var j = i
            while j < s.count && matches(s[j]) { j += 1 }
            if j - i >= minimum { out.append(" ") } else { out.append(contentsOf: s[i..<j]) }
            i = j
        }
        return out
    }

    /// `s.replace(/\s*;\s*/g, ', ')` (JS `\s`, leftmost-longest like the regex engine).
    private static func replaceSemicolons(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            var j = i
            while j < s.count && JSCompat.isWhitespace(s[j]) { j += 1 }
            if j < s.count && s[j] == ";" {
                var k = j + 1
                while k < s.count && JSCompat.isWhitespace(s[k]) { k += 1 }
                out.append(contentsOf: [",", " "])
                i = k
            } else {
                // No match can start anywhere in s[i...j]: copy it.
                let end = min(j + 1, s.count)
                out.append(contentsOf: s[i..<end])
                i = end
            }
        }
        return out
    }

    /// JS `haystack.includes(needle)` (exact code points, no canonical equivalence).
    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.unicodeScalars)
        let n = Array(needle.unicodeScalars)
        guard !n.isEmpty else { return true }
        guard n.count <= h.count else { return false }
        for start in 0...(h.count - n.count) where h[start] == n[0] {
            if h[start..<(start + n.count)].elementsEqual(n) { return true }
        }
        return false
    }
}

/// The JSON text of `Backup.jsonText`: `JSON.stringify(value, null, 2)` formatting.
private enum BackupJSONWriter {
    /// Keys in the order the web app creates them (exportAll, sanitizeSet, buildCards,
    /// sanitizeStudyPatch, DEFAULT_SETTINGS, normalizeProgress); other keys follow, sorted.
    private static let keyRank: [String: Int] = Dictionary(
        uniqueKeysWithValues: [
            "app", "version", "exportedAt", "sets", "progress", "settings", "activity",
            "id", "title", "description", "termLang", "defLang", "cards", "term", "definition", "starred",
            "studyOptions", "theme", "study", "answerWith", "shuffle", "copyAnswer", "autoAdvance", "audio",
            "tolerance", "articles", "abbreviations", "multipleAnswers", "parentheses", "ignoreCase", "ignoreAccents",
            "typos", "learn", "roundSize", "mc", "written", "retype", "createdAt", "updatedAt", "lastStudiedAt",
            "correct", "incorrect", "streak", "streakBefore", "lastResult", "lastAnsweredAt",
        ].enumerated().map { ($0.element, $0.offset) })

    static func write(_ value: JSONValue, indent: String, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case let .bool(b):
            out += b ? "true" : "false"
        case let .number(n):
            out += n.isFinite ? JSCompat.numberToString(n) : "null"
        case let .string(s):
            writeString(s, into: &out)
        case let .array(items):
            guard !items.isEmpty else {
                out += "[]"
                return
            }
            let inner = indent + "  "
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += inner
                write(item, indent: inner, into: &out)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += indent + "]"
        case let .object(object):
            guard !object.isEmpty else {
                out += "{}"
                return
            }
            let keys = object.keys.sorted { a, b in
                switch (keyRank[a], keyRank[b]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.utf16.lexicographicallyPrecedes(b.utf16)
                }
            }
            let inner = indent + "  "
            out += "{\n"
            for (i, key) in keys.enumerated() {
                out += inner
                writeString(key, into: &out)
                out += ": "
                write(object[key] ?? .null, indent: inner, into: &out)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += indent + "}"
        }
    }

    /// JS `QuoteJSONString`: quotes, backslashes and control characters are escaped, everything
    /// else (including "/" and non-ASCII) is written as is.
    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20:
                let hex = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }
}

/// A strict JSON parser with the semantics of JS `JSON.parse` (Foundation's parsers accept
/// trailing commas and keep the first of duplicate keys). Numbers beyond the Double range become
/// ±infinity like in JS; lone surrogate escapes become U+FFFD (Swift strings cannot hold them).
private struct BackupJSONParser {
    private let bytes: [UInt8]
    private var pos = 0
    private var depth = 0
    private static let maxDepth = 512

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    /// The single JSON value of the text, nil when the text is not valid JSON.
    mutating func parseDocument() -> JSONValue? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return pos == bytes.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
    }

    private mutating func consume(_ literal: String) -> Bool {
        let expected = Array(literal.utf8)
        guard bytes.count - pos >= expected.count, Array(bytes[pos..<(pos + expected.count)]) == expected else {
            return false
        }
        pos += expected.count
        return true
    }

    private mutating func parseValue() -> JSONValue? {
        guard pos < bytes.count else { return nil }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return parseObject()
        case UInt8(ascii: "["): return parseArray()
        case UInt8(ascii: "\""): return parseString().map(JSONValue.string)
        case UInt8(ascii: "t"): return consume("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return consume("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return consume("null") ? .null : nil
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { return nil }
        pos += 1
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") {
            pos += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\""), let key = parseString() else { return nil }
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { return nil }
            pos += 1
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipWhitespace()
            guard pos < bytes.count else { return nil }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
                continue
            }
            guard bytes[pos] == UInt8(ascii: "}") else { return nil }
            pos += 1
            return .object(object)
        }
    }

    private mutating func parseArray() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { return nil }
        pos += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
            pos += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipWhitespace()
            guard pos < bytes.count else { return nil }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
                continue
            }
            guard bytes[pos] == UInt8(ascii: "]") else { return nil }
            pos += 1
            return .array(array)
        }
    }

    /// A string literal starting at the opening quote.
    private mutating func parseString() -> String? {
        pos += 1
        var out: [UInt8] = []
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            switch b {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard pos < bytes.count else { return nil }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = parseHex4() else { return nil }
                    var scalar = Unicode.Scalar(unit)
                    if (0xD800...0xDBFF).contains(unit), bytes.count - pos >= 6,
                       bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u")
                    {
                        let save = pos
                        pos += 2
                        if let low = parseHex4(), (0xDC00...0xDFFF).contains(low) {
                            scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
                        } else {
                            pos = save
                        }
                    }
                    out.append(contentsOf: Array(String(Character(scalar ?? "\u{FFFD}")).utf8))
                default:
                    return nil
                }
            default:
                // Unescaped control characters are not allowed in JSON strings.
                guard b >= 0x20 else { return nil }
                out.append(b)
            }
        }
        return nil
    }

    private mutating func parseHex4() -> UInt16? {
        guard bytes.count - pos >= 4 else { return nil }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let b = bytes[pos]
            let digit: UInt16
            switch b {
            case 0x30...0x39: digit = UInt16(b - 0x30)
            case 0x41...0x46: digit = UInt16(b - 0x41 + 10)
            case 0x61...0x66: digit = UInt16(b - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
            pos += 1
        }
        return value
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    private mutating func parseNumber() -> JSONValue? {
        let start = pos
        func digits() -> Int {
            let from = pos
            while pos < bytes.count, (0x30...0x39).contains(bytes[pos]) { pos += 1 }
            return pos - from
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        guard pos < bytes.count else { return nil }
        if bytes[pos] == UInt8(ascii: "0") {
            pos += 1
        } else if (0x31...0x39).contains(bytes[pos]) {
            _ = digits()
        } else {
            return nil
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
            pos += 1
            guard digits() > 0 else { return nil }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            guard digits() > 0 else { return nil }
        }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        return Double(text).map(JSONValue.number)
    }
}
