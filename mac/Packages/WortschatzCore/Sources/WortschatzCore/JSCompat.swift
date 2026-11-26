import Foundation

/// Small helpers that reproduce JavaScript semantics exactly. Ports should use these instead of
/// the "obvious" Swift/Foundation counterparts, which differ in edge cases:
/// - `String.trimmingCharacters(in: .whitespacesAndNewlines)` uses a different character set
///   than JS `trim()` / `\s`.
/// - `Double.rounded()` rounds half away from zero; JS `Math.round` rounds half up.
/// - `"\(double)"` prints "5.0" / "1e-07"; JS prints "5" / "1e-7".
public enum JSCompat {
    // MARK: Whitespace (`\s` and `String.prototype.trim` in JS)

    /// Whether `u` matches JS `\s` (WhiteSpace + LineTerminator).
    public static func isWhitespace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// JS `s.trim() === ''`, without building the trimmed copy.
    public static func isBlank(_ s: String) -> Bool {
        !s.unicodeScalars.contains { !isWhitespace($0) }
    }

    /// JS `s.trim()`.
    public static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[first...last])
    }

    // MARK: Numbers

    /// JS `Math.round` (half rounds toward +∞). NaN and ±∞ are returned unchanged.
    public static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let f = x.rounded(.down)
        return x - f >= 0.5 ? f + 1 : f
    }

    /// JS `String(x)` / template-literal formatting of a number.
    public static func numberToString(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x == .infinity { return "Infinity" }
        if x == -.infinity { return "-Infinity" }
        if x == 0 { return "0" }
        let negative = x < 0
        // Swift's description gives the shortest round-trip digits, like JS.
        let desc = "\(abs(x))"
        var mantissa = Substring(desc)
        var exponent = 0
        if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = desc[..<e]
            exponent = Int(desc[desc.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(intPart + fracPart)
        var n = intPart.count + exponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            n -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let ds = String(digits)
        var out: String
        if k <= n && n <= 21 {
            out = ds + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            out = String(digits[0..<n]) + "." + String(digits[n...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n) + ds
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            out = k == 1 ? ds : String(digits[0]) + "." + String(digits[1...])
            out += "e\(sign)\(abs(e))"
        }
        return negative ? "-" + out : out
    }

    // MARK: Dates

    /// JS `TimeClip`: the time value a `Date` built from `ms` holds (fraction truncated), or nil
    /// for an invalid date (NaN, ±∞, beyond ±8.64e15).
    public static func timeClip(_ ms: Double) -> Double? {
        guard ms.isFinite, abs(ms) <= 8.64e15 else { return nil }
        return ms.rounded(.towardZero) + 0 // + 0 turns -0 into +0
    }

    // MARK: Strings

    /// JS `s.length` (UTF-16 code units).
    public static func length(_ s: String) -> Int { s.utf16.count }

    /// `s.normalize('NFC')`.
    public static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// `s.normalize('NFD')`.
    public static func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }

    /// Exact string equality like JS `===` (Unicode scalars, no canonical equivalence).
    public static func identical(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }
}

// MARK: - Lenient decoding helpers (internal)

extension KeyedDecodingContainer {
    /// The raw JSON value at `key`, or nil when the key is absent (or undecodable).
    func json(_ key: Key) -> JSONValue? {
        (try? decodeIfPresent(JSONValue.self, forKey: key)) ?? nil
    }
}

extension KeyedEncodingContainer {
    /// Encodes `value`, writing an explicit `null` for nil (JS keeps such keys as `null`).
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

/// A plain string key for keyed containers with dynamic keys.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue) }
}
