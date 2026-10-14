import CoreGraphics
import Foundation
import ImageIO
import Testing
import WortschatzCore
@testable import WortschatzImport

// Port of the ocrDataToText / imageScaleFor / ocrLangsFor cases of tests/layout.test.js, with
// Vision-shaped results instead of tesseract's.
@Suite("OCR helpers (ocr.js)")
struct OCRTextAssemblerTests {
    static let pairs: [(String, String)] = [
        ("le monsieur, messieurs", "der Herr"),
        ("l'homme", "der Mann"),
        ("la femme", "die Frau"),
        ("l'enfant", "das Kind"),
        ("le garçon", "der Junge"),
        ("la fille", "das Mädchen"),
    ]

    static var expected: [String] { pairs.map { "\($0.0)\t\($0.1)" } }

    @Test("Rebuilds a two-column table from word boxes")
    func table() {
        #expect(OCRTextAssembler.lines(from: FakeOCR.table(Self.pairs)) == Self.expected)
    }

    @Test("Drops table rules and straightens skewed photos")
    func skewed() {
        #expect(OCRTextAssembler.lines(from: FakeOCR.table(Self.pairs, slope: 0.05, bars: true)) == Self.expected)
        #expect(OCRTextAssembler.lines(from: FakeOCR.table(Self.pairs, slope: -0.04)) == Self.expected)
    }

    @Test("Level boxes of a slightly rotated photo: the rows are found by aligning the cells")
    func rectifiedBoxes() {
        for slope in [0.035, -0.035, 0.05, -0.02, 0.08, 0.06, -0.07] {
            let lines = FakeOCR.table(Self.pairs, slope: slope, rotated: true, rectified: true)
            #expect(OCRTextAssembler.lines(from: lines) == Self.expected, "slope \(slope)")
            #expect(abs(OCRTextAssembler.estimateSkew(lines) - slope) < 0.01, "slope \(slope)")
        }
    }

    @Test("Skew refinement keeps the engine's slope without side-by-side pieces")
    func skewWithoutPairs() {
        let single = FakeOCR.table(Self.pairs, slope: 0.04).filter { $0.quad.bottomLeft.x < 400 }
        #expect(abs(OCRTextAssembler.estimateSkew(single) - 0.04) < 1e-9)
        #expect(OCRTextAssembler.estimateSkew([]) == 0)
    }

    @Test("Strips border bars glued to words")
    func borderBars() {
        var lines = FakeOCR.table([("la rue", "die Strasse"), ("le nom", "der Name")])
        let first = lines[0].words[0]
        // "|la" with its box extended by one character to the left.
        lines[0].words[0] = FakeOCR.word("|la", x: Double(first.quad.bottomLeft.x) - 11, baseline: 120)
        #expect(OCRTextAssembler.lines(from: lines) == ["la rue\tdie Strasse", "le nom\tder Name"])
    }

    @Test("Noise words and unsure symbols are dropped")
    func noise() {
        var lines = FakeOCR.table(Array(Self.pairs.prefix(3)))
        lines.append(OCRLine(
            text: "───", confidence: 0.9, quad: OCRQuad(x: 300, y: 300, width: 200, height: 4),
            words: [OCRWord(text: "───", confidence: 0.9, quad: OCRQuad(x: 300, y: 300, width: 200, height: 4))]))
        lines.append(OCRLine(
            text: "~", confidence: 0.1, quad: OCRQuad(x: 300, y: 140, width: 11, height: 26),
            words: [OCRWord(text: "~", confidence: 0.1, quad: OCRQuad(x: 300, y: 140, width: 11, height: 26))]))
        #expect(OCRTextAssembler.lines(from: lines) == Array(Self.expected.prefix(3)))
    }

    @Test("Falls back to the plain line texts without usable word boxes")
    func plainFallback() {
        let degenerate = OCRQuad(x: 10, y: 10, width: 0, height: 0)
        let lines = [
            OCRLine(text: "  le nom", confidence: 1, quad: degenerate, words: [OCRWord(text: "le", confidence: 1, quad: degenerate)]),
            OCRLine(text: "der Name ", confidence: 1, quad: degenerate, words: []),
        ]
        #expect(OCRTextAssembler.lines(from: lines) == ["le nom", "der Name"])
        #expect(OCRTextAssembler.lines(from: []) == [])
        let umlauts = [OCRLine(text: "die Tûr\nla porte", confidence: 1, quad: degenerate, words: [])]
        #expect(OCRTextAssembler.lines(from: umlauts) == ["die Tür", "la porte"])
    }

    @Test("Restores German umlauts misread as circumflexes")
    func umlauts() {
        let rows = [("beau, belle", "schôn"), ("le rôle", "die Rolle"), ("la porte", "die Tûr"), ("fatigué", "mûde")]
        #expect(
            OCRTextAssembler.lines(from: FakeOCR.table(rows))
                == ["beau, belle\tschön", "le rôle\tdie Rolle", "la porte\tdie Tür", "fatigué\tmüde"])
    }

    @Test("Words without an engine box get a slice of their line")
    func wordSlices() {
        let quad = OCRQuad(x: 100, y: 50, width: 220, height: 30)
        let line = OCRLine(text: "le chat noir", confidence: 1, quad: quad, wordQuad: { _ in nil })
        #expect(line.words.map(\.text) == ["le", "chat", "noir"])
        #expect(line.words[0].quad.bottomLeft.x == 100)
        #expect(abs(line.words[2].quad.bottomRight.x - 320) < 1e-9)
        #expect(line.words[1].quad.bottomLeft.x > line.words[0].quad.bottomRight.x)
    }

    // MARK: - imageScaleFor

    @Test("imageScaleFor upscales small images and limits large ones")
    func imageScale() {
        #expect(OCRImage.scale(width: 600, height: 400) == 2)
        #expect(OCRImage.scale(width: 1199, height: 900) == 2)
        #expect(OCRImage.scale(width: 1600, height: 1200) == 1)
        #expect((OCRImage.scale(width: 3024, height: 4032) * 4032).rounded() == 3000)
        #expect((OCRImage.scale(width: 4032, height: 3024) * 4032).rounded() == 3000)
        // Very tall screenshot: the width stays legible, the pixel budget is respected.
        let s = OCRImage.scale(width: 1170, height: 8000)
        #expect(s > 1)
        #expect(1170 * 8000 * s * s <= 12e6 + 1)
        #expect(OCRImage.scale(width: 0, height: 100) == 1)
        #expect(OCRImage.scale(width: .nan, height: 100) == 1)
        #expect(OCRImage.scale(width: -5, height: 100) == 1)
    }

    @Test("Images are prepared upright, opaque and at the recognition scale")
    func prepare() throws {
        // A small transparent PNG is upscaled 2× and flattened onto white.
        let small = TestDocuments.tableImage(Array(TestDocuments.rows.prefix(2)), width: 800, fontSize: 20, pitch: 36, transparent: true)
        let prepared = try OCRImage.prepareForRecognition(TestDocuments.encode(small, as: .png))
        #expect(prepared.width == small.width * 2)
        #expect(prepared.height == small.height * 2)
        #expect(prepared.alphaInfo == .noneSkipLast)
        #expect(try Self.pixel(prepared, x: 1, y: 1) == [255, 255, 255])

        // A JPEG whose pixels are stored sideways with EXIF orientation 6 (rotate 90° clockwise) is
        // decoded upright.
        let upright = TestDocuments.tableImage(width: 1600)
        let stored = TestDocuments.rotatedQuarter(upright)
        let jpeg = TestDocuments.encode(stored, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let decoded = try OCRImage.decode(jpeg)
        #expect(decoded.width == upright.width)
        #expect(decoded.height == upright.height)

        // Large images are reduced to 3000 px on the long side.
        let large = try #require(OCRImage.whiteContext(width: 4000, height: 3000)?.makeImage())
        let reduced = try OCRImage.prepareForRecognition(TestDocuments.encode(large, as: .png))
        #expect(reduced.width == 3000)
        #expect(reduced.height == 2250)
    }

    @Test("Unreadable image data fails with the German decode message")
    func undecodable() {
        #expect(throws: ImportError(.decode, ImportMessages.decode)) {
            try OCRImage.prepareForRecognition(Data("kein Bild".utf8))
        }
        #expect(throws: ImportError(.decode, ImportMessages.decode)) {
            try OCRImage.decode(Data())
        }
    }

    // MARK: - ocrLangsFor

    @Test("Recognition languages follow the set (ocrLangsFor)")
    func languages() {
        #expect(RecognitionLanguages.forSet(termLang: .fr) == ["fr-FR", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .en) == ["en-US", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .es) == ["es-ES", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .it) == ["it-IT", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .de) == ["de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .other) == ["en-US", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: nil) == ["fr-FR", "de-DE"])
        // The translation language of the set replaces German.
        #expect(RecognitionLanguages.forSet(termLang: .fr, defLang: .en) == ["fr-FR", "en-US"])
        #expect(RecognitionLanguages.forSet(termLang: .de, defLang: .fr) == ["de-DE", "fr-FR"])
        #expect(RecognitionLanguages.forSet(termLang: .it, defLang: .other) == ["it-IT", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .it, defLang: nil) == ["it-IT", "de-DE"])
    }

    @Test("Only languages Vision supports are requested, each once")
    func supportedLanguages() {
        let available = ["en-Latn-US", "fr-Latn-FR", "de-Latn-DE"]
        #expect(VisionSettings.supported(["fr-FR", "de-DE"], available: available) == ["fr-FR", "de-DE"])
        #expect(VisionSettings.supported(["it-IT", "de-DE", "de-CH"], available: available) == ["de-DE"])
        #expect(VisionSettings.supported([], available: available) == [])
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(OCRImage.whiteContext(width: 1, height: 1))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = try #require(context.data)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return [bytes[0], bytes[1], bytes[2]]
    }
}
