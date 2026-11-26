import Foundation
import Testing
import WortschatzCore

/// `JSONValue(encoding:)` builds the JSON values directly (`JSONValueEncoder`); it must give
/// exactly what `JSONEncoder`'s text read back with `JSONDecoder` gives (numbers bit for bit,
/// strings scalar for scalar).
@Suite("JSONValue(encoding:) = JSONEncoder text read back")
struct JSONValueEncoderTests {
    /// The text round trip `JSONValue(encoding:)` replaced.
    static func viaText<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try JSONValue.parse(try encoder.encode(value))
    }

    static func exact(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x.bitPattern == y.bitPattern
        case let (.string(x), .string(y)): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case let (.array(x), .array(y)): return x.count == y.count && zip(x, y).allSatisfy { exact($0, $1) }
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            return x.allSatisfy { key, value in y[key].map { exact(value, $0) } ?? false }
        default: return false
        }
    }

    static func expectSame<T: Encodable>(_ value: T, _ comment: Comment? = nil) throws {
        #expect(exact(try JSONValue(encoding: value), try viaText(value)), comment)
    }

    enum Shape: Codable { case plain, pair(Int, String), point(x: Double, y: [Int?]) }

    struct Inner: Codable {
        var name: String
        var values: [Double]
        var flag: Bool?
    }

    struct Sample: Codable {
        var text: String
        var double: Double
        var float: Float
        var int: Int
        var int64: Int64
        var uint64: UInt64
        var int8: Int8
        var some: Int?
        var none: String?
        var list: [Double?]
        var byText: [String: [Int]]
        var byNumber: [Int: String]
        var inner: Inner?
        var shape: Shape
        var date: Date
        var json: JSONValue
    }

    struct Special: Codable {
        var data: Data
        var url: URL
        var decimal: Decimal
    }

    @Test("Numbers, texts, optionals, nesting, enums and keys")
    func samples() throws {
        let doubles: [Double] = [0, -0.0, .nan, .infinity, -.infinity, 5e-324, 1e308, 0.1 + 0.2, 9_007_199_254_740_993]
        let floats: [Float] = [0.1, -0.0, .nan, .infinity, 1e30, 1.0 / 3]
        let texts = ["", "\u{FEFF}le chien", "e\u{301}", "é", "😀", "quote \" back\\slash /", "ctrl \u{0}\u{1F}", "ß œ"]
        for (i, double) in doubles.enumerated() {
            let sample = Sample(
                text: texts[i % texts.count], double: double, float: floats[i % floats.count], int: -i * 1_000_003,
                int64: i == 0 ? .min : Int64(i) << 60, uint64: i == 1 ? .max : UInt64(i) << 62, int8: Int8(i) - 64,
                some: i, none: nil, list: [double, nil, 1.5], byText: [texts[i % texts.count]: [i], "b": []],
                byNumber: [i: "x", -3: "y"], inner: i.isMultiple(of: 2) ? Inner(name: "n", values: [double], flag: nil) : nil,
                shape: [Shape.plain, .pair(i, "p"), .point(x: double, y: [1, nil])][i % 3],
                date: Date(timeIntervalSinceReferenceDate: Double(i) * 12_345.678),
                json: .object(["a": .number(double), "b": .array([.null, .bool(true), .string("\u{FEFF}")])]))
            try Self.expectSame(sample, "sample \(i)")
        }
        try Self.expectSame([1.5, .nan], "top-level array")
        try Self.expectSame("\u{FEFF}x", "top-level string")
        try Self.expectSame(Int?.none, "top-level nil")
        try Self.expectSame(Special(data: Data([0, 255]), url: URL(string: "https://example.com/a?b=c")!, decimal: 12.345))
    }

    @Test("Learn and Write sessions as they are stored after answers")
    func sessions() throws {
        let cards = (0..<60).map { i in
            Card(id: "c\(i)", term: ["le chat", "la maison, le foyer", "courir (v.)", "l'été"][i % 4] + " \(i)", definition: "Wort \(i)")
        }
        for seed in 1...4 {
            let rng = mulberry32(seed: seed)
            var learn = LearnEngine.createLearn(
                cards, answerWith: .both, learn: LearnOptions(roundSize: 7, mc: true, written: true), rng: rng, now: 1000,
                review: true, recheck: true)
            var write = WriteSession.createSession(cards, answerWith: .both, shuffle: true, rng: rng, now: 1000)
            for step in 0..<20 {
                try Self.expectSame(learn, "learn \(seed)/\(step)")
                try Self.expectSame(write, "write \(seed)/\(step)")
                learn =
                    learn.queue.isEmpty
                    ? LearnEngine.nextRound(learn, cards: cards, rng: rng, now: 2000)
                    : LearnEngine.answer(learn, correct: step % 3 != 0, now: Double(3000 + step))
                write =
                    WriteSession.isRoundOver(write)
                    ? WriteSession.nextRound(write, rng: rng, now: 4000)
                    : WriteSession.answer(write, correct: step % 4 != 0, now: Double(5000 + step))
            }
        }
    }
}
