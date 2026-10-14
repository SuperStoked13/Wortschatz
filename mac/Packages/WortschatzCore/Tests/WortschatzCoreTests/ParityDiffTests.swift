import Testing
import WortschatzCore

/// Self-tests of the parity comparison, so that a broken comparator cannot hide mismatches.
@Suite("ParityDiff")
struct ParityDiffTests {
    func diff(_ e: JSONValue, _ a: JSONValue, tolerance: Double = 1e-9, nullMatchesMissing: Bool = false) -> [String] {
        ParityDiff.differences(expected: e, actual: a, tolerance: tolerance, nullMatchesMissing: nullMatchesMissing)
    }

    @Test func identicalValuesMatch() throws {
        let v = try JSONValue.parse(#"{"a":[1,2.5,"x",true,null],"b":{"c":"é"}}"#)
        #expect(diff(v, v).isEmpty)
    }

    @Test func numbersUseAbsoluteTolerance() {
        #expect(diff(1.0, .number(1.0 + 1e-10)).isEmpty)
        #expect(!diff(1.0, .number(1.0 + 1e-8)).isEmpty)
        #expect(!diff(0.5, .number(0.5 + 1e-12), tolerance: 0).isEmpty)
        #expect(!diff(1, "1").isEmpty)
        #expect(!diff(1, true).isEmpty)
    }

    @Test func stringsCompareScalarsNotCanonicalEquivalence() {
        // "é" precomposed vs decomposed are == in Swift but differ in JS.
        #expect(JSONValue.string("\u{E9}") == JSONValue.string("e\u{301}"))
        #expect(!diff(.string("\u{E9}"), .string("e\u{301}")).isEmpty)
        #expect(diff(.string("\u{E9}"), .string("\u{E9}")).isEmpty)
    }

    @Test func arraysCompareLengthAndElements() {
        #expect(!diff([1, 2], [1, 2, 3]).isEmpty)
        #expect(!diff([1, 2], [2, 1]).isEmpty)
    }

    @Test func objectKeys() {
        #expect(!diff(["a": 1], [:]).isEmpty) // missing key
        #expect(!diff([:], ["a": 1]).isEmpty) // unexpected key
        #expect(diff([:], ["a": nil]).isEmpty) // JS omitted, Swift wrote null
        #expect(!diff(["a": nil], [:]).isEmpty) // JS wrote null, Swift omitted
        #expect(diff(["a": nil], [:], nullMatchesMissing: true).isEmpty)
    }

    @Test func messagesNamePathAndInvisibleCharacters() {
        let d = diff(["k": ["a\u{200B}"]], ["k": ["a"]])
        #expect(d.count == 1)
        #expect(d[0].contains("$.k[0]"))
        #expect(d[0].contains("\\u{200B}"))
    }
}
