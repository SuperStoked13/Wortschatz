import Foundation
import Testing
@testable import WortschatzImport

@Suite("TextFileDecoder (decodeText)")
struct TextFileDecoderTests {
    static let sample = "le château\tdas Schloss\nla fille\tdas Mädchen\nl’œuvre\tdas Werk"

    static func utf16(_ s: String, littleEndian: Bool, bom: Bool) -> Data {
        var bytes: [UInt8] = bom ? (littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]) : []
        for unit in s.utf16 {
            let hi = UInt8(unit >> 8), lo = UInt8(unit & 0xFF)
            bytes += littleEndian ? [lo, hi] : [hi, lo]
        }
        return Data(bytes)
    }

    @Test("UTF-8 with and without BOM")
    func utf8() {
        #expect(TextFileDecoder.decode(Data(Self.sample.utf8)) == Self.sample)
        let bom = TextFileDecoder.decodeDetectingEncoding(Data([0xEF, 0xBB, 0xBF] + Array(Self.sample.utf8)))
        #expect(bom.text == Self.sample)
        #expect(bom.encoding == .utf8)
        // TextDecoder drops one more BOM after the stripped one.
        #expect(TextFileDecoder.decode(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("x".utf8))) == "x")
        // With a BOM, invalid bytes are replaced instead of switching to Windows-1252.
        #expect(TextFileDecoder.decode(Data([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0x62])) == "a\u{FFFD}b")
    }

    @Test("UTF-16 with a BOM in both byte orders")
    func utf16WithBOM() {
        let le = TextFileDecoder.decodeDetectingEncoding(Self.utf16(Self.sample, littleEndian: true, bom: true))
        #expect(le.text == Self.sample)
        #expect(le.encoding == .utf16LittleEndian)
        let be = TextFileDecoder.decodeDetectingEncoding(Self.utf16(Self.sample, littleEndian: false, bom: true))
        #expect(be.text == Self.sample)
        #expect(be.encoding == .utf16BigEndian)
        // A dangling odd byte becomes a replacement character.
        #expect(TextFileDecoder.decode(Self.utf16("ab", littleEndian: true, bom: true) + Data([0x63])) == "ab\u{FFFD}")
    }

    @Test("UTF-16 without a BOM is recognised by its zero byte lane")
    func utf16WithoutBOM() {
        let le = TextFileDecoder.decodeDetectingEncoding(Self.utf16(Self.sample, littleEndian: true, bom: false))
        #expect(le.text == Self.sample)
        #expect(le.encoding == .utf16LittleEndian)
        let be = TextFileDecoder.decodeDetectingEncoding(Self.utf16(Self.sample, littleEndian: false, bom: false))
        #expect(be.text == Self.sample)
        #expect(be.encoding == .utf16BigEndian)
        // Too short to tell: read as UTF-8.
        #expect(TextFileDecoder.decode(Data([0x61, 0x00])) == "a\u{0}")
    }

    @Test("Windows-1252 is the fallback for invalid UTF-8")
    func windows1252() {
        // "le château – das Mädchen €" in Windows-1252.
        let bytes: [UInt8] = Array("le ch".utf8) + [0xE2] + Array("teau ".utf8) + [0x96] + Array(" das M".utf8) + [0xE4]
            + Array("dchen ".utf8) + [0x80]
        let result = TextFileDecoder.decodeDetectingEncoding(Data(bytes))
        #expect(result.text == "le château – das Mädchen €")
        #expect(result.encoding == .windows1252)
        // French with only "é" reads the same in both: Windows-1252 wins the tie, like the web app.
        #expect(TextFileDecoder.decode(Data(Array("caf".utf8) + [0xE9])) == "café")
        // Unassigned Windows-1252 bytes map to C1 controls (WHATWG) ...
        let undefined = TextFileDecoder.decodeDetectingEncoding(Data([0xE4, 0xFC, 0xF6, 0x81]))
        #expect(undefined.text.unicodeScalars.map(\.value) == [0xE4, 0xFC, 0xF6, 0x81])
        #expect(undefined.encoding == .windows1252)
        // ... which alone make Mac OS Roman the better reading ("Å").
        #expect(TextFileDecoder.decode(Data([0x61, 0x81, 0x62])) == "aÅb")
    }

    @Test("Mac OS Roman is used when it reads clearly better")
    func macRoman() {
        // "le château – das Mädchen, schön, l’œuvre" in Mac OS Roman.
        let bytes: [UInt8] = Array("le ch".utf8) + [0x89] + Array("teau ".utf8) + [0xD0] + Array(" das M".utf8) + [0x8A]
            + Array("dchen, sch".utf8) + [0x9A] + Array("n, l".utf8) + [0xD5, 0xCF] + Array("uvre".utf8)
        let result = TextFileDecoder.decodeDetectingEncoding(Data(bytes))
        #expect(result.text == "le château – das Mädchen, schön, l’œuvre")
        #expect(result.encoding == .macRoman)
    }

    @Test("Windows-1252 German text is not mistaken for Mac OS Roman")
    func windowsGerman() {
        let text = "die Tür\tla porte\nmüde\tfatigué\nschön\tbeau\nder Bäcker\tle boulanger\nà côté de\tneben"
        let bytes = text.unicodeScalars.map { UInt8($0.value) }
        let result = TextFileDecoder.decodeDetectingEncoding(Data(bytes))
        #expect(result.text == text)
        #expect(result.encoding == .windows1252)
    }

    @Test("The web fixture windows-bom.txt (UTF-8 BOM, CRLF, odd spaces)")
    func webFixture() throws {
        let data = try TestDocuments.resource("windows-bom.txt")
        let text = TextFileDecoder.decode(data)
        #expect(text.hasPrefix("le chien\u{A0}-\u{A0}der Hund\r\n"))
        #expect(!text.contains("\u{FEFF}"))
        #expect(!TextFileDecoder.looksBinary(text))
    }

    @Test("Binary data is recognised by its control characters")
    func looksBinary() {
        #expect(!TextFileDecoder.looksBinary(""))
        #expect(!TextFileDecoder.looksBinary("le chat\tdie Katze\r\nle chien\tder Hund\n"))
        let png = TextFileDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]))
        #expect(TextFileDecoder.looksBinary(png))
        // One stray control character in a long text is fine (≤ 2 %).
        #expect(!TextFileDecoder.looksBinary(String(repeating: "a", count: 100) + "\u{1}"))
        #expect(TextFileDecoder.looksBinary(String(repeating: "a", count: 40) + "\u{1}"))
    }
}
