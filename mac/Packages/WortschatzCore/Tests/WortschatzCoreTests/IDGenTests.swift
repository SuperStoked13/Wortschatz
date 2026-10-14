import Testing
import WortschatzCore

/// Port of tests/id.test.js (the crypto-fallback tests do not apply to Swift).
@Suite("IDGen (id.test.js)")
struct IDGenTests {
    static func urlSafe(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            ("A"..."Z").contains(u) || ("a"..."z").contains(u) || ("0"..."9").contains(u) || u == "_" || u == "-"
        }
    }

    @Test func defaultLengthIs16AndUrlSafe() {
        let id = IDGen.uid()
        #expect(id.count == 16)
        #expect(Self.urlSafe(id))
    }

    @Test func customSizesNeverShorterThan12() {
        #expect(IDGen.uid(12).count == 12)
        #expect(IDGen.uid(20).count == 20)
        #expect(IDGen.uid(5).count == 12)
        #expect(IDGen.uid(0).count == 16)
        #expect(IDGen.uid(-3).count == 12)
    }

    @Test func tenThousandIdsAreUnique() {
        var seen = Set<String>()
        for _ in 0..<10_000 { seen.insert(IDGen.uid()) }
        #expect(seen.count == 10_000)
    }

    @Test func usesTheWholeAlphabet() {
        var chars = Set<Character>()
        for _ in 0..<500 { chars.formUnion(IDGen.uid()) }
        #expect(chars.count > 60)
        #expect(chars.allSatisfy { Self.urlSafe(String($0)) })
        #expect(IDGen.ALPHABET.count == 64)
    }
}
