import Foundation
import Testing
import WortschatzCore

/// Replays Fixtures/parser.json (mac/Parity/gen-parser.js): every input of tests/parser.test.js,
/// every web fixture under an options matrix, thousands of synthesised lists and fuzz text. Each
/// case compares the whole `parseVocab` result field by field (cards with flags, confidence and
/// lines, format, delimiter, languages, swapped, skipped lines, warnings). The fixture is large, so
/// it runs in slices on several cores (the same reporting as `runParity`).
@Suite("Parity: parser.js")
struct VocabParserParityTests {
    static let slices = 8
    private static let fixture = Result { try Fixtures.load("parser") }

    /// The Swift result of one case (nil for an unknown fn).
    static func run(_ c: ParityCase) throws -> JSONValue? {
        switch c.fn {
        case "parseVocab":
            let text = jsInput(c.arg(0))
            return try encodeToJSONValue(VocabParser.parseVocab(text, options: ParseOptions(json: c.arg(1))))
        default:
            return nil
        }
    }

    @Test("VocabParser.parseVocab matches src/core/parser.js on every fixture case", arguments: 0..<slices)
    func fixture(slice: Int) throws {
        let doc = try Self.fixture.get()
        var failed = 0
        var unknown: Set<String> = []
        for (index, c) in doc.cases.enumerated() where index % Self.slices == slice {
            let actual: JSONValue?
            do {
                actual = try Self.run(c)
            } catch {
                failed += 1
                if failed <= 10 { Issue.record("\(c.id) threw: \(error)") }
                continue
            }
            guard let actual else {
                unknown.insert(c.fn)
                continue
            }
            let diffs = ParityDiff.differences(expected: c.out, actual: actual)
            if MacOnlyDivergences.allows("parser", c.id) {
                if diffs.isEmpty { MacOnlyDivergences.recordStale("parser", c.id) }
                continue
            }
            if diffs.isEmpty { continue }
            failed += 1
            if failed <= 10 {
                Issue.record(Comment(rawValue: "Parity mismatch \(c.id)\n  " + diffs.joined(separator: "\n  ")
                    + "\n  args: " + ParityDiff.describe(.array(c.args), max: 600)))
            }
        }
        #expect(unknown.isEmpty, "unhandled fns \(unknown.sorted())")
        #expect(failed == 0, "slice \(slice): \(failed) cases differ")
    }

    @Test("the fixture is complete and covers every format, flag, skip reason and option kind")
    func coverage() throws {
        let doc = try Self.fixture.get()
        #expect(doc.module == "parser")
        #expect(doc.count == doc.cases.count)
        #expect(doc.count > 6000)
        #expect(Set(doc.cases.map(\.fn)) == ["parseVocab"])
        var formats: Set<String> = []
        var flags: Set<String> = []
        var reasons: Set<String> = []
        var delimiters: Set<String> = []
        var modes: Set<String> = []
        var warnings = 0
        for c in doc.cases {
            let out = c.out.objectValue ?? [:]
            if let f = out["format"]?.stringValue { formats.insert(f) }
            if let d = out["delimiter"]?.stringValue { delimiters.insert(d) }
            for card in out["cards"]?.arrayValue ?? [] {
                for f in card.objectValue?["flags"]?.arrayValue ?? [] { flags.insert(f.stringValue ?? "") }
            }
            for s in out["skipped"]?.arrayValue ?? [] { reasons.insert(s.objectValue?["reason"]?.stringValue ?? "") }
            warnings += out["warnings"]?.arrayValue?.count ?? 0
            modes.insert(c.arg(1).objectValue?["mode"]?.stringValue ?? "auto")
        }
        #expect(formats == Set(ParseFormat.allCases.map(\.rawValue)))
        #expect(flags == Set(ParseFlag.allCases.map(\.rawValue)))
        #expect(reasons == Set(SkipReason.allCases.map(\.rawValue)))
        #expect(modes.isSuperset(of: ["auto", "delimiter", "lines"]))
        #expect(delimiters.isSuperset(of: ["\t", " - ", " → ", " = ", "=", ": ", ";", "|", ",", "  ", " "]))
        #expect(warnings > 5000)
    }

    @Test("the web fixture texts embedded for the unit tests are byte-for-byte the generator's inputs")
    func webFixtureTexts() throws {
        let doc = try Self.fixture.get()
        var inputs: Set<[Unicode.Scalar]> = []
        for c in doc.cases where c.args.count == 1 {
            if let s = c.arg(0).stringValue { inputs.insert(Array(s.unicodeScalars)) }
        }
        for name in VocabParserWebFixtures.names {
            #expect(inputs.contains(Array(VocabParserWebFixtures.read(name).unicodeScalars)), "\(name)")
        }
    }

    /// The parser input as JS sees it: `typeof input === 'string' ? input : input == null ? '' :
    /// String(input)` (the test file also passes numbers, booleans, arrays and objects).
    static func jsInput(_ v: JSONValue) -> String? {
        v == .null ? nil : jsString(v)
    }

    /// JS `String(v)` for JSON values.
    static func jsString(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return JSCompat.numberToString(n)
        case let .string(s): return s
        case let .array(a): return a.map { $0 == .null ? "" : jsString($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }
}
