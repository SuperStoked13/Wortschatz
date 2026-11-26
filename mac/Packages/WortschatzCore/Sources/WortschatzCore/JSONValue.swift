import Foundation

/// An arbitrary JSON value. Used where the web app accepts loosely typed JSON (backup import,
/// lenient decoding of stored data) and by the parity tests to compare Swift and JS results.
///
/// Pitfall: Swift `String ==` (and therefore the synthesized `==` of this enum and dictionary
/// keys) uses Unicode canonical equivalence, so "é" (NFC) equals "e\u{301}" (NFD). JS compares
/// UTF-16 code units. Use `JSONValue.identical(_:_:)` or compare `unicodeScalars` when the
/// difference matters (the parity tests do).
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        // Each kind matches exactly one of the attempts; the most frequent come first, since
        // every failed attempt throws (loading a library threw ~4 errors per object, 2 per string).
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            // Integral values are written without a fraction ("5", not "5.0"), like JSON.stringify.
            if n.isFinite, n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
                try c.encode(Int64(n))
            } else {
                try c.encode(n)
            }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    // MARK: Parsing / conversion

    /// Parses JSON data (any top-level value).
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses a JSON string (any top-level value).
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Converts any Encodable value (encoded with `JSONEncoder`) into a JSONValue.
    /// Non-finite doubles are encoded as the strings "NaN", "Infinity", "-Infinity".
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = try encoder.encode(value)
        self = try JSONValue.parse(data)
    }

    /// Decodes this value as `T` (round trip through `JSONEncoder`/`JSONDecoder`).
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Serialises this value. `sortedKeys` gives a stable output.
    public func jsonData(prettyPrinted: Bool = false, sortedKeys: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var format: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
        if prettyPrinted { format.insert(.prettyPrinted) }
        if sortedKeys { format.insert(.sortedKeys) }
        encoder.outputFormatting = format
        return try encoder.encode(self)
    }

    /// Compact JSON text with sorted keys.
    public var jsonString: String {
        guard let data = try? jsonData(), let s = String(data: data, encoding: .utf8) else { return "<invalid>" }
        return s
    }

    // MARK: Accessors (JS-like)

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    /// `isObject` in the web code: a non-null, non-array object.
    public var isObject: Bool { if case .object = self { return true } else { return false } }
    public var isArray: Bool { if case .array = self { return true } else { return false } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a } else { return nil } }
    public var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    public var numberValue: Double? { if case let .number(n) = self { return n } else { return nil } }

    /// A finite number (`typeof v === 'number' && Number.isFinite(v)`).
    public var finiteNumber: Double? {
        if case let .number(n) = self, n.isFinite { return n }
        return nil
    }

    /// An integer-valued number (`Number.isInteger(v)`), as Int when it fits.
    public var integerValue: Int? {
        guard case let .number(n) = self, n.isFinite, n == n.rounded(.towardZero),
              abs(n) <= 9_007_199_254_740_992 else { return nil }
        return Int(n)
    }

    /// `String(v)` of the web code for primitives: strings as is, numbers in JS notation,
    /// booleans as "true"/"false". `nil` for null, arrays and objects.
    public var jsPrimitiveString: String? {
        switch self {
        case let .string(s): return s
        case let .number(n): return JSCompat.numberToString(n)
        case let .bool(b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Exact structural identity: strings compared by Unicode scalars (no canonical
    /// equivalence), numbers with `==`. Object key order is irrelevant.
    public static func identical(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case let (.array(x), .array(y)):
            return x.count == y.count && zip(x, y).allSatisfy { identical($0, $1) }
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            for (k, v) in x {
                guard let w = y[k], identical(v, w) else { return false }
            }
            return true
        default: return false
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}
