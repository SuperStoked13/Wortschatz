import Testing
import WortschatzCore

@Suite("Parity: mulberry32")
struct RandomParityTests {
    @Test("mulberry32 produces the JS sequences bit for bit")
    func fixture() throws {
        // Exact comparison: the values are k / 2^32 and must be identical.
        try runParity("random", tolerance: 0) { c in
            switch c.fn {
            case "mulberry32":
                let seed = try c.int(0)
                let rng = mulberry32(seed: UInt32(seed))
                return .array((0..<(try c.int(1))).map { _ in .number(rng()) })
            case "mulberry32Int":
                let rng = mulberry32(seed: try c.int(0))
                return .array((0..<(try c.int(1))).map { _ in .number(rng()) })
            case "shuffle":
                let rng = mulberry32(seed: UInt32(try c.int(0)))
                var a = Array(0..<(try c.int(1)))
                var i = a.count - 1
                while i > 0 {
                    var j = Int((rng() * Double(i + 1)).rounded(.down))
                    if !(j >= 0) { j = 0 }
                    if j > i { j = i }
                    a.swapAt(i, j)
                    i -= 1
                }
                return .array(a.map { .number(Double($0)) })
            default:
                return nil
            }
        }
    }
}
