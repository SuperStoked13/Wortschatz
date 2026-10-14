import Testing
import WortschatzCore

/// Replays Fixtures/grading.json (mac/Parity/gen-grading.js): about 90,000 gradings of answers
/// derived from every test input and every fixture card, plus splitAlternatives, diffChars,
/// diffAnswer and the constants. The fixture is large, so it runs in slices on several cores.
@Suite("Parity: grading.js")
struct GradingParityTests {
    static let slices = 8
    private static let fixture = Result { try Fixtures.load("grading") }

    /// JS `toStr`: strings as is, numbers and booleans via `String(v)`, null → "".
    static func text(_ v: JSONValue) -> String { v.jsPrimitiveString ?? "" }

    /// JS `resolveLang`: only strings count ("DE", " de-CH" → `.de`).
    static func lang(_ v: JSONValue) -> Lang? { Grading.resolveLang(v.stringValue) }

    /// JS `resolveTolerance`: booleans of an object, or of the `tolerance` object of a full
    /// StudyOptions; anything else keeps the defaults.
    static func tolerance(_ v: JSONValue) -> Tolerance {
        if let inner = v.objectValue?["tolerance"], inner.isObject || inner.isArray { return Tolerance(json: inner) }
        return Tolerance(json: v)
    }

    /// A tolerance mask of the generator: bit b = `Tolerance.keys[b]`.
    static func tolerance(mask: Int) -> Tolerance {
        func on(_ key: String) -> Bool { mask & (1 << (Tolerance.keys.firstIndex(of: key) ?? 0)) != 0 }
        return Tolerance(
            articles: on("articles"), abbreviations: on("abbreviations"), multipleAnswers: on("multipleAnswers"),
            parentheses: on("parentheses"), ignoreCase: on("ignoreCase"), ignoreAccents: on("ignoreAccents"),
            typos: on("typos"))
    }

    /// `[correct, exact, notes, hint]` (the compact form of the gradeMatrix cases).
    static func compact(_ r: GradeResult) -> JSONValue {
        let notes = JSONValue.array(r.notes.map { .string($0.rawValue) })
        return [.bool(r.correct), .bool(r.exact), notes, r.hint.map { .string($0.rawValue) } ?? .null]
    }

    /// The Swift result of one case (nil for an unknown fn).
    static func run(_ c: ParityCase) throws -> JSONValue? {
        switch c.fn {
        case "grade":
            let r = Grading.grade(
                given: text(c.arg(0)), expected: text(c.arg(1)), tolerance: tolerance(c.arg(2)), lang: lang(c.arg(3)))
            return try encodeToJSONValue(r)
        case "gradeMatrix":
            let given = try c.string(0)
            let expected = try c.string(1)
            let answerLang = lang(c.arg(2))
            let masks = c.arg(3).arrayValue?.compactMap(\.integerValue) ?? []
            return .array(masks.map { mask in
                compact(
                    Grading.grade(given: given, expected: expected, tolerance: tolerance(mask: mask), lang: answerLang))
            })
        case "splitAlternatives":
            return .array(Grading.splitAlternatives(text(c.arg(0)), lang: lang(c.arg(1))).map(JSONValue.string))
        case "diffChars":
            return try encodeToJSONValue(Grading.diffChars(text(c.arg(0)), text(c.arg(1))))
        case "diffAnswer":
            return try encodeToJSONValue(Grading.diffAnswer(text(c.arg(0)), text(c.arg(1))))
        case "constants":
            switch try c.string(0) {
            case "ARTICLES": return try encodeToJSONValue(Grading.ARTICLES)
            case "REFLEXIVES": return try encodeToJSONValue(Grading.REFLEXIVES)
            case "DEFAULT_TOLERANCE": return try encodeToJSONValue(Grading.DEFAULT_TOLERANCE)
            case "ABBREVIATIONS":
                return .array(Grading.ABBREVIATIONS.map { [.string($0.pattern), "giu", .string($0.canonical)] })
            default: return nil
            }
        default:
            return nil
        }
    }

    @Test("The fixture is complete and covers every function")
    func fixtureShape() throws {
        let doc = try Self.fixture.get()
        #expect(doc.module == "grading")
        #expect(doc.count == doc.cases.count)
        let fns = Set(doc.cases.map(\.fn))
        #expect(fns == ["grade", "gradeMatrix", "splitAlternatives", "diffChars", "diffAnswer", "constants"])
        let gradings = doc.cases.reduce(0) { n, c in
            n + (c.fn == "grade" ? 1 : c.fn == "gradeMatrix" ? c.arg(3).arrayValue?.count ?? 0 : 0)
        }
        #expect(gradings > 30_000)
    }

    @Test("Grading matches src/core/grading.js on every fixture case", arguments: 0..<slices)
    func fixture(slice: Int) throws {
        let doc = try Self.fixture.get()
        var failed = 0
        var unknown: Set<String> = []
        var byFn: [String: Int] = [:]
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
            if diffs.isEmpty { continue }
            failed += 1
            byFn[c.fn, default: 0] += 1
            if failed <= 10 {
                Issue.record(Comment(rawValue: "Parity mismatch \(c.id)\n  " + diffs.joined(separator: "\n  ")
                    + "\n  args: " + ParityDiff.describe(.array(c.args), max: 600)))
            }
        }
        #expect(unknown.isEmpty, "unhandled fns \(unknown.sorted())")
        let summary = byFn.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        #expect(failed == 0, "slice \(slice): \(failed) cases differ (\(summary))")
    }
}
