import Foundation

/// Bytes → string for imported text files (port of `decodeText` in src/import/files.js).
///
/// Byte order marks are honoured (UTF-8, UTF-16 LE/BE), UTF-16 without a BOM is recognised by its
/// zero byte lane, UTF-8 is tried strictly, and legacy files fall back to Windows-1252 (old
/// Excel/Windows exports) or, when that reads clearly worse, Mac OS Roman (old Mac exports).
public enum TextFileDecoder {
    /// The legacy encoding a non-UTF text file was read with.
    public enum Encoding: String, Sendable, Hashable {
        case utf8, utf16LittleEndian, utf16BigEndian, windows1252, macRoman
    }

    /// Decodes `data` like the web app's `decodeText` (plus the Mac OS Roman fallback).
    public static func decode(_ data: Data) -> String {
        decodeDetectingEncoding(data).text
    }

    /// Decodes `data` and reports the encoding that was used.
    public static func decodeDetectingEncoding(_ data: Data) -> (text: String, encoding: Encoding) {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (stripLeadingBOM(String(decoding: bytes.dropFirst(3), as: UTF8.self)), .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return (stripLeadingBOM(decodeUTF16(bytes.dropFirst(2), littleEndian: true)), .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return (stripLeadingBOM(decodeUTF16(bytes.dropFirst(2), littleEndian: false)), .utf16BigEndian)
        }
        if let littleEndian = utf16Lane(bytes) {
            return (
                stripLeadingBOM(decodeUTF16(bytes[...], littleEndian: littleEndian)),
                littleEndian ? .utf16LittleEndian : .utf16BigEndian
            )
        }
        if let text = strictUTF8(bytes) { return (text, .utf8) }
        let windows = decodeSingleByte(bytes, table: windows1252High)
        let mac = decodeSingleByte(bytes, table: macRomanHigh)
        return plausibility(mac, bytes: bytes) > plausibility(windows, bytes: bytes) ? (mac, .macRoman) : (windows, .windows1252)
    }

    /// Binary data decoded as text shows up as many control characters (JS `looksBinary`): more than
    /// 2 % of the first 4096 UTF-16 units are C0 controls other than tab/line breaks, or DEL.
    public static func looksBinary(_ text: String) -> Bool {
        let sample = text.utf16.prefix(4096)
        guard !sample.isEmpty else { return false }
        let controls = sample.filter { u in (u <= 0x08) || (0x0E...0x1F).contains(u) || u == 0x7F }.count
        return controls > 0 && Double(controls) > Double(sample.count) * 0.02
    }

    // MARK: - UTF-8 / UTF-16

    /// The `TextDecoder` default (`ignoreBOM: false`) drops one more leading BOM.
    private static func stripLeadingBOM(_ s: String) -> String {
        s.unicodeScalars.first == "\u{FEFF}" ? String(s.unicodeScalars.dropFirst()) : s
    }

    /// Strict (fatal) UTF-8: nil when any sequence is invalid.
    private static func strictUTF8(_ bytes: [UInt8]) -> String? {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    /// Lossy UTF-16 like `TextDecoder('utf-16le' | 'utf-16be')`: unpaired surrogates and a dangling
    /// odd byte become U+FFFD.
    private static func decodeUTF16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(littleEndian ? (b << 8 | a) : (a << 8 | b))
            i += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        if bytes.count % 2 == 1 { text.append("\u{FFFD}") }
        return text
    }

    /// UTF-16 without BOM: one of the two byte lanes is mostly zero (Latin text). true = little endian.
    private static func utf16Lane(_ bytes: [UInt8]) -> Bool? {
        let n = min(bytes.count, 1024) & ~1
        guard n >= 4 else { return nil }
        var evenZero = 0
        var oddZero = 0
        for i in stride(from: 0, to: n, by: 2) {
            if bytes[i] == 0 { evenZero += 1 }
            if bytes[i + 1] == 0 { oddZero += 1 }
        }
        let pairs = Double(n / 2)
        if Double(oddZero) > pairs * 0.4 && Double(evenZero) < pairs * 0.05 { return true }
        if Double(evenZero) > pairs * 0.4 && Double(oddZero) < pairs * 0.05 { return false }
        return nil
    }

    // MARK: - Single-byte encodings

    private static func decodeSingleByte(_ bytes: [UInt8], table: [UInt32]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value = byte < 0x80 ? UInt32(byte) : table[Int(byte) - 0x80]
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    /// How natural the high bytes of `bytes` read in `text`: letters and punctuation common in
    /// French, German, Spanish and Italian count +1, C1 controls and symbols that never occur in a
    /// vocabulary list count -2. Windows-1252 wins ties (the web app only knows Windows-1252).
    private static func plausibility(_ text: String, bytes: [UInt8]) -> Int {
        var score = 0
        for (scalar, byte) in zip(text.unicodeScalars, bytes) where byte >= 0x80 {
            if plausibleScalars.contains(scalar.value) {
                score += 1
            } else if (0x80...0x9F).contains(scalar.value) || implausibleScalars.contains(scalar.value) {
                score -= 2
            }
        }
        return score
    }

    private static let plausibleScalars: Set<UInt32> = Set(
        "àâäáãåæçéèêëíìîïñóòôöõúùûüœÀÂÄÁÃÅÆÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜŒ«»¿¡€–—‘’“”…°·".unicodeScalars.map(\.value)
            + [0xA0]
    )

    private static let implausibleScalars: Set<UInt32> = Set(
        "ƒ†‡ˆ‰Š‹šŽž˜™›Ÿ¦¨¯´¸¹²³¼½¾×÷√∆∑∏π∫Ω≈≠≤≥◊ºª¬±µ∂¥¤¶§©®".unicodeScalars.map(\.value)
    )

    /// Windows-1252 bytes 0x80…0xFF (WHATWG mapping: the 5 unassigned bytes map to C1 controls).
    private static let windows1252High: [UInt32] = {
        let c1: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
            0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
        ]
        return c1 + (0xA0...0xFF).map { UInt32($0) }
    }()

    /// Mac OS Roman bytes 0x80…0xFF (0xDB is the euro sign, as on Mac OS 8.5 and later).
    private static let macRomanHigh: [UInt32] = [
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, 0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3, 0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, 0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211, 0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, 0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA, 0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, 0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, 0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    ]
}
