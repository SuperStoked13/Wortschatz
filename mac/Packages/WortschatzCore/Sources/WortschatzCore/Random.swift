import Foundation

/// A source of random numbers in [0, 1), like JS `Math.random`. Engines take an `RNG` so that
/// tests (and the parity fixtures) can replay exact sequences with `mulberry32`.
///
/// Not `Sendable`: a seeded generator carries mutable state. Create one per use.
public typealias RNG = () -> Double

/// The small seeded PRNG of the web tests (tests/learn.test.js), bit-for-bit identical:
/// `Math.imul` and `>>> 0` become wrapping `UInt32` arithmetic.
///
/// ```js
/// function mulberry32(seed) {
///   let a = seed >>> 0;
///   return function () {
///     a = (a + 0x6d2b79f5) >>> 0;
///     let t = a;
///     t = Math.imul(t ^ (t >>> 15), t | 1);
///     t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
///     return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
///   };
/// }
/// ```
public func mulberry32(seed: UInt32) -> RNG {
    var a = seed
    return {
        a = a &+ 0x6D2B_79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// JS `seed >>> 0` for any integer seed (negative or above 2³² wrap around).
public func mulberry32(seed: Int) -> RNG {
    mulberry32(seed: UInt32(truncatingIfNeeded: seed))
}

/// The system random source (`Math.random`): uniformly distributed in [0, 1).
public func systemRNG() -> RNG {
    { Double.random(in: 0..<1) }
}

/// The system random source (spec name); same as `systemRNG()`.
public var SystemRNG: RNG { systemRNG() }
