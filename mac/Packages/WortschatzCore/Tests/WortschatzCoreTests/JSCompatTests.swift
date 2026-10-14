import Testing
import WortschatzCore

@Suite("JSCompat")
struct JSCompatTests {
    @Test func numberToStringMatchesJS() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (5, "5"), (-5, "-5"), (0.1, "0.1"), (1.5, "1.5"), (123.456, "123.456"),
            (1e21, "1e+21"), (1e20, "100000000000000000000"), (1e-7, "1e-7"), (0.000001, "0.000001"),
            (123456789012345683968, "123456789012345680000"), (1.5e-10, "1.5e-10"), (2.5e25, "2.5e+25"),
            (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"), (9007199254740992, "9007199254740992"),
        ]
        for (x, s) in cases { #expect(JSCompat.numberToString(x) == s, "\(x)") }
    }

    @Test func roundIsHalfUp() {
        #expect(JSCompat.round(0.5) == 1)
        #expect(JSCompat.round(1.5) == 2)
        #expect(JSCompat.round(2.5) == 3)
        #expect(JSCompat.round(-0.5) == 0)
        #expect(JSCompat.round(-1.5) == -1)
        #expect(JSCompat.round(0.49999999999999994) == 0)
    }

    @Test func trimUsesJSWhitespace() {
        #expect(JSCompat.trim("\u{FEFF}\u{A0} a b \u{2028}\t") == "a b")
        #expect(JSCompat.trim("\u{85}a") == "\u{85}a") // NEL is not JS whitespace
        #expect(JSCompat.trim("   ") == "")
    }

    @Test func timeClipTruncates() {
        #expect(JSCompat.timeClip(1.7) == 1)
        #expect(JSCompat.timeClip(-1.7) == -1)
        #expect(JSCompat.timeClip(.nan) == nil)
        #expect(JSCompat.timeClip(8.64e15 + 1) == nil)
    }

    @Test func jsonValueDistinguishesBoolsAndNumbers() throws {
        let v = try JSONValue.parse(#"[true, 1, 0, false, 1.5, "1", null]"#)
        #expect(v == [true, 1, 0, false, 1.5, "1", nil])
        #expect(v[1]?.integerValue == 1)
        #expect(v[4]?.integerValue == nil)
        #expect(try JSONValue(encoding: 5.0).jsonString == "5")
    }
}
