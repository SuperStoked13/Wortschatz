import Foundation
import Testing
import WortschatzCore

// Parity test helpers. Conventions: mac/Parity/README.md.

/// One generated case: `fn` names the JS function, `args` its JSON arguments, `out` the JS result.
struct ParityCase: Decodable, Sendable {
    let id: String
    let fn: String
    let args: [JSONValue]
    let out: JSONValue

    /// Argument `i` (`.null` when absent, like a missing JS argument).
    func arg(_ i: Int) -> JSONValue { i < args.count ? args[i] : .null }

    func string(_ i: Int) throws -> String {
        guard let s = arg(i).stringValue else { throw ParityError.badArgument(id, i, "string", arg(i)) }
        return s
    }

    func optionalString(_ i: Int) -> String? { arg(i).stringValue }

    func double(_ i: Int) throws -> Double {
        guard let n = arg(i).numberValue else { throw ParityError.badArgument(id, i, "number", arg(i)) }
        return n
    }

    func optionalDouble(_ i: Int) -> Double? { arg(i).numberValue }

    func int(_ i: Int) throws -> Int {
        guard let n = arg(i).integerValue else { throw ParityError.badArgument(id, i, "integer", arg(i)) }
        return n
    }

    func bool(_ i: Int) throws -> Bool {
        guard let b = arg(i).boolValue else { throw ParityError.badArgument(id, i, "boolean", arg(i)) }
        return b
    }

    /// Decodes argument `i` with `T`'s Decodable conformance.
    func decode<T: Decodable>(_ i: Int, as type: T.Type = T.self) throws -> T {
        try arg(i).decode(as: T.self)
    }
}

/// A fixture document written by mac/scripts/gen-fixtures.sh.
struct ParityFixture: Decodable, Sendable {
    let module: String
    let count: Int
    let cases: [ParityCase]
}

enum ParityError: Error, CustomStringConvertible {
    case missingFixture(String)
    case badArgument(String, Int, String, JSONValue)

    var description: String {
        switch self {
        case let .missingFixture(name):
            return "Fixture \(name).json not found in the test bundle (run mac/scripts/gen-fixtures.sh)"
        case let .badArgument(id, i, kind, v):
            return "\(id): argument \(i) is not a \(kind): \(ParityDiff.describe(v))"
        }
    }
}

enum Fixtures {
    /// URL of `Fixtures/<name>.json` in the test bundle.
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw ParityError.missingFixture(name)
        }
        return url
    }

    /// Loads and decodes `Fixtures/<name>.json`.
    static func load(_ name: String) throws -> ParityFixture {
        let data = try Data(contentsOf: try url(name))
        return try JSONDecoder().decode(ParityFixture.self, from: data)
    }
}

/// Fixture cases where the Mac app deliberately differs from the web reference until the change is
/// ported there (fixture name → case ids). A listed case may differ. A listed case that matches the
/// fixture again fails the test, so the list gets cleared once the web app has caught up and the
/// fixtures are regenerated.
enum MacOnlyDivergences {
    static let cases: [String: Set<String>] = [:]

    /// Whether case `id` of `fixture` may differ from the web reference.
    static func allows(_ fixture: String, _ id: String) -> Bool {
        cases[fixture]?.contains(id) ?? false
    }

    /// Records an issue for a listed case that matches the web reference again.
    static func recordStale(_ fixture: String, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
        Issue.record(
            Comment(rawValue: "\(id) matches the web reference again: remove it from MacOnlyDivergences[\"\(fixture)\"]"),
            sourceLocation: sourceLocation)
    }
}

/// Encodes any Encodable result as a JSONValue (for comparison with the JS output).
func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONValue(encoding: value)
}

/// Compares `actual` (Swift) with `expected` (JS) and records an issue with a readable diff.
/// Returns whether they match.
@discardableResult
func assertParity(
    _ actual: JSONValue, _ expected: JSONValue, _ caseID: String = "", args: [JSONValue] = [],
    tolerance: Double = 1e-9, nullMatchesMissing: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    let diffs = ParityDiff.differences(
        expected: expected, actual: actual, tolerance: tolerance, nullMatchesMissing: nullMatchesMissing)
    if diffs.isEmpty { return true }
    var message = "Parity mismatch \(caseID)\n  " + diffs.joined(separator: "\n  ")
    if !args.isEmpty {
        message += "\n  args: " + ParityDiff.describe(.array(args), max: 600)
    }
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    return false
}

/// `assertParity` for an Encodable result.
@discardableResult
func assertParity<T: Encodable>(
    _ actual: T, _ expected: JSONValue, _ caseID: String = "", args: [JSONValue] = [], tolerance: Double = 1e-9,
    nullMatchesMissing: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
) throws -> Bool {
    assertParity(
        try encodeToJSONValue(actual), expected, caseID, args: args, tolerance: tolerance,
        nullMatchesMissing: nullMatchesMissing, sourceLocation: sourceLocation)
}

/// Runs every case of `Fixtures/<fixture>.json` through `body`, which returns the Swift result
/// for the case (or nil when it does not know `case.fn`, which fails the test). At most
/// `maxReported` mismatches are reported individually; the summary counts all of them.
func runParity(
    _ fixture: String, tolerance: Double = 1e-9, nullMatchesMissing: Bool = false, maxReported: Int = 25,
    sourceLocation: SourceLocation = #_sourceLocation, _ body: (ParityCase) throws -> JSONValue?
) throws {
    let doc = try Fixtures.load(fixture)
    #expect(doc.count == doc.cases.count, "fixture \(fixture): count does not match", sourceLocation: sourceLocation)
    #expect(!doc.cases.isEmpty, "fixture \(fixture) has no cases", sourceLocation: sourceLocation)
    var failed = 0
    var unknown: Set<String> = []
    var byFn: [String: Int] = [:]
    for c in doc.cases {
        let actual: JSONValue?
        do {
            actual = try body(c)
        } catch {
            failed += 1
            if failed <= maxReported {
                Issue.record(Comment(rawValue: "\(c.id) threw: \(error)"), sourceLocation: sourceLocation)
            }
            continue
        }
        guard let actual else {
            unknown.insert(c.fn)
            continue
        }
        let diffs = ParityDiff.differences(
            expected: c.out, actual: actual, tolerance: tolerance, nullMatchesMissing: nullMatchesMissing)
        if MacOnlyDivergences.allows(fixture, c.id) {
            if diffs.isEmpty { MacOnlyDivergences.recordStale(fixture, c.id, sourceLocation: sourceLocation) }
            continue
        }
        if diffs.isEmpty { continue }
        failed += 1
        byFn[c.fn, default: 0] += 1
        if failed <= maxReported {
            let message = "Parity mismatch \(c.id)\n  " + diffs.joined(separator: "\n  ")
                + "\n  args: " + ParityDiff.describe(.array(c.args), max: 600)
            Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
        }
    }
    #expect(unknown.isEmpty, "fixture \(fixture): unhandled fns \(unknown.sorted())", sourceLocation: sourceLocation)
    let summary = byFn.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    #expect(failed == 0, "fixture \(fixture): \(failed) of \(doc.cases.count) cases differ (\(summary))",
            sourceLocation: sourceLocation)
}

/// Europe/Zurich, the zone the fixtures are generated in.
let zurich = TimeZone(identifier: "Europe/Zurich")!
