import Foundation
import WortschatzCore

/// Structural comparison of JSON values for the parity tests.
///
/// Rules (documented in mac/Parity/README.md):
/// - numbers: equal within an absolute `tolerance` (default 1e-9);
/// - strings: identical Unicode scalars (no canonical equivalence, unlike Swift `==`);
/// - arrays: same length, element by element;
/// - objects: same keys, except that a key JS omitted may be `null` on the Swift side. With
///   `nullMatchesMissing` a JS `null` also matches a key Swift omitted.
enum ParityDiff {
    static func differences(
        expected: JSONValue, actual: JSONValue, tolerance: Double = 1e-9, nullMatchesMissing: Bool = false,
        limit: Int = 12
    ) -> [String] {
        var out: [String] = []
        walk(expected, actual, path: "$", tolerance: tolerance, nullMatchesMissing: nullMatchesMissing, limit: limit, into: &out)
        return out
    }

    private static func walk(
        _ e: JSONValue, _ a: JSONValue, path: String, tolerance: Double, nullMatchesMissing: Bool, limit: Int,
        into out: inout [String]
    ) {
        guard out.count < limit else { return }
        switch (e, a) {
        case (.null, .null):
            return
        case let (.bool(x), .bool(y)):
            if x != y { out.append("\(path): expected \(x), got \(y)") }
        case let (.number(x), .number(y)):
            if x == y || (x.isFinite && y.isFinite && abs(x - y) <= tolerance) { return }
            out.append("\(path): expected \(JSCompat.numberToString(x)), got \(JSCompat.numberToString(y))")
        case let (.string(x), .string(y)):
            if !JSCompat.identical(x, y) {
                out.append("\(path): expected \(describe(e)), got \(describe(a))")
            }
        case let (.array(x), .array(y)):
            if x.count != y.count {
                out.append("\(path): expected \(x.count) elements, got \(y.count)")
            }
            for i in 0..<min(x.count, y.count) {
                walk(x[i], y[i], path: "\(path)[\(i)]", tolerance: tolerance, nullMatchesMissing: nullMatchesMissing,
                     limit: limit, into: &out)
            }
        case let (.object(x), .object(y)):
            for key in x.keys.sorted() {
                let child = "\(path).\(key)"
                guard let yv = y[key] else {
                    if nullMatchesMissing, x[key] == .null { continue }
                    out.append("\(child): missing (expected \(describe(x[key]!)))")
                    continue
                }
                walk(x[key]!, yv, path: child, tolerance: tolerance, nullMatchesMissing: nullMatchesMissing,
                     limit: limit, into: &out)
            }
            for key in y.keys.sorted() where x[key] == nil {
                if y[key] == .null { continue } // JS omitted the key, Swift wrote null
                out.append("\(path).\(key): unexpected key (got \(describe(y[key]!)))")
            }
        default:
            out.append("\(path): expected \(describe(e)), got \(describe(a))")
        }
    }

    /// Compact, readable JSON: invisible and non-ASCII-space characters are shown as \u{…}.
    static func describe(_ v: JSONValue, max: Int = 240) -> String {
        var s: String
        switch v {
        case let .string(str): s = quote(str)
        default:
            s = v.jsonString
            if s.unicodeScalars.contains(where: isInvisible) { s = escapeInvisible(s) }
        }
        if s.count > max { s = String(s.prefix(max)) + "…" }
        return s
    }

    static func quote(_ s: String) -> String {
        "\"" + escapeInvisible(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")) + "\""
    }

    static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        if u.value < 0x20 || u.value == 0x7F { return true }
        switch u.properties.generalCategory {
        case .spaceSeparator: return u != " "
        case .format, .lineSeparator, .paragraphSeparator, .control, .nonspacingMark, .enclosingMark, .spacingMark,
             .surrogate, .unassigned, .privateUse:
            return true
        default: return false
        }
    }

    static func escapeInvisible(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if isInvisible(u) {
                out += String(format: "\\u{%04X}", u.value)
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}
