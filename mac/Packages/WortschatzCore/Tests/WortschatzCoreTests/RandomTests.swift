import Testing
import WortschatzCore

@Suite("Random")
struct RandomTests {
    @Test func mulberry32IsDeterministicAndInRange() {
        let a = mulberry32(seed: 42)
        let b = mulberry32(seed: 42)
        for _ in 0..<1000 {
            let x = a()
            #expect(x == b())
            #expect(x >= 0 && x < 1)
        }
    }

    @Test func intSeedsWrapLikeUnsignedShift() {
        let a = mulberry32(seed: -1)
        let b = mulberry32(seed: UInt32.max)
        let c = mulberry32(seed: 4_294_967_296 + 5)
        let d = mulberry32(seed: UInt32(5))
        for _ in 0..<50 {
            #expect(a() == b())
            #expect(c() == d())
        }
    }

    @Test func systemRNGIsInRange() {
        let rng = systemRNG()
        for _ in 0..<1000 {
            let x = rng()
            #expect(x >= 0 && x < 1)
        }
    }
}
