import Foundation

/// Port of src/lib/id.js: random, URL-safe identifiers.
public enum IDGen {
    /// The 64-character URL-safe alphabet.
    public static let ALPHABET = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    /// 16 × 6 bits = 96 bits of randomness.
    public static let DEFAULT_SIZE = 16

    /// A url-safe id of `size` characters (minimum 12; 0 means the default 16), like `uid(size)`.
    public static func uid(_ size: Int = DEFAULT_SIZE) -> String {
        let n = size == 0 ? DEFAULT_SIZE : max(12, size)
        var generator = SystemRandomNumberGenerator()
        var id = ""
        id.reserveCapacity(n)
        for _ in 0..<n {
            let byte = UInt8.random(in: 0...255, using: &generator)
            id.append(ALPHABET[Int(byte & 63)])
        }
        return id
    }
}
