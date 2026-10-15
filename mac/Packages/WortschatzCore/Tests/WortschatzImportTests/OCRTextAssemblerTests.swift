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

    @Test("Right-to-left words without an engine box are sliced from the right end of their line")
    func rtlWordSlices() {
        let quad = OCRQuad(x: 0, y: 0, width: 90, height: 20)
        let line = OCRLine(text: "ذهب الولد", confidence: 1, quad: quad, wordQuad: { _ in nil })
        #expect(line.words.map(\.text) == ["ذهب", "الولد"])
        // 9 characters: the first word (logical order) is the rightmost third.
        #expect(abs(line.words[0].quad.bottomLeft.x - 60) < 1e-9)
        #expect(abs(line.words[0].quad.bottomRight.x - 90) < 1e-9)
        #expect(abs(line.words[1].quad.bottomLeft.x) < 1e-9)
        #expect(abs(line.words[1].quad.bottomRight.x - 50) < 1e-9)
        // Assembled, the words are read from right to left again.
        #expect(OCRTextAssembler.lines(from: [line]) == ["ذهب الولد"])
    }

    // MARK: - Arabic and Chinese

    @Test("Chinese words are joined without spaces, pinyin keeps its spaces")
    func chineseWords() {
        var words: [OCRWord] = []
        var x = 60.0
        for ch in ["你", "好", "，", "朋", "友"] {
            words.append(OCRWord(text: ch, confidence: 0.9, quad: OCRQuad(x: x, y: 98, width: 22, height: 26)))
            x += 26
        }
        words += [FakeOCR.word("nǐ", x: 220, baseline: 120), FakeOCR.word("hǎo", x: 250, baseline: 120)]
        let quad = OCRQuad(x: 60, y: 98, width: 223, height: 26)
        let line = OCRLine(text: "你 好 ， 朋 友 nǐ hǎo", confidence: 0.9, quad: quad, words: words)
        #expect(OCRTextAssembler.lines(from: [line]) == ["你好，朋友 nǐ hǎo"])
    }

    @Test("Chinese text without word boxes is joined too")
    func chinesePlainText() {
        let degenerate = OCRQuad(x: 10, y: 10, width: 0, height: 0)
        let lines = [
            OCRLine(text: "你 好 ， 朋 友", confidence: 1, quad: degenerate, words: []),
            OCRLine(text: "谢 谢 xiè xie", confidence: 1, quad: degenerate, words: []),
        ]
        #expect(OCRTextAssembler.lines(from: lines) == ["你好，朋友", "谢谢 xiè xie"])
    }

    /// A recognised line of right-to-left words in logical order whose right edge is at `right`.
    static func rtlLine(_ text: String, right: Double, baseline: Double) -> OCRLine {
        var words: [OCRWord] = []
        var x1 = right
        for w in text.split(separator: " ").map(String.init) {
            words.append(FakeOCR.word(w, x: x1 - Double(w.count) * 11, baseline: baseline))
            x1 -= Double(w.count + 1) * 11
        }
        return line(text, words: words, leftmost: words[words.count - 1], rightmost: words[0])
    }

    /// A recognised line of left-to-right words starting at `x`.
    static func ltrLine(_ text: String, x: Double, baseline: Double) -> OCRLine {
        var words: [OCRWord] = []
        var x0 = x
        for w in text.split(separator: " ").map(String.init) {
            words.append(FakeOCR.word(w, x: x0, baseline: baseline))
            x0 += Double(w.count + 1) * 11
        }
        return line(text, words: words, leftmost: words[0], rightmost: words[words.count - 1])
    }

    private static func line(_ text: String, words: [OCRWord], leftmost: OCRWord, rightmost: OCRWord) -> OCRLine {
        let quad = OCRQuad(
            topLeft: leftmost.quad.topLeft, topRight: rightmost.quad.topRight,
            bottomRight: rightmost.quad.bottomRight, bottomLeft: leftmost.quad.bottomLeft)
        return OCRLine(text: text, confidence: 0.9, quad: quad, words: words)
    }

    @Test("Arabic words in logical order with boxes from right to left are read in that order")
    func arabicWords() {
        #expect(OCRTextAssembler.lines(from: [Self.rtlLine("ذهب الولد إلى المدرسة", right: 600, baseline: 120)]) == ["ذهب الولد إلى المدرسة"])
    }

    @Test("A right-aligned Arabic column and a German column from word boxes")
    func arabicTable() {
        let rows = [("الكتاب", "das Buch"), ("القلم", "der Stift"), ("البيت", "das Haus"), ("المدرسة الجديدة", "die neue Schule")]
        var lines: [OCRLine] = []
        for (r, row) in rows.enumerated() {
            let base = 120 + Double(r) * 40
            lines.append(Self.rtlLine(row.0, right: 400, baseline: base))
            lines.append(Self.ltrLine(row.1, x: 460, baseline: base))
        }
        #expect(OCRTextAssembler.lines(from: lines) == rows.map { "\($0.0)\t\($0.1)" })
        // German on the left, Arabic on the right.
        var swapped: [OCRLine] = []
        for (r, row) in rows.enumerated() {
            let base = 120 + Double(r) * 40
            swapped.append(Self.ltrLine(row.1, x: 60, baseline: base))
            swapped.append(Self.rtlLine(row.0, right: 600, baseline: base))
        }
        #expect(OCRTextAssembler.lines(from: swapped) == rows.map { "\($0.1)\t\($0.0)" })
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

    @Test("Recognition languages for Arabic and Chinese sets")
    func scriptLanguages() {
        #expect(RecognitionLanguages.forSet(termLang: .ar) == ["ar-SA", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .zh) == ["zh-Hans", "de-DE"])
        #expect(RecognitionLanguages.forSet(termLang: .de, defLang: .zh) == ["de-DE", "zh-Hans"])
    }

    @Test("Only languages Vision supports are requested, each once (by full identifier)")
    func supportedLanguages() {
        let available = ["en-Latn-US", "fr-Latn-FR", "de-Latn-DE"]
        #expect(VisionSettings.supported(["fr-FR", "de-DE"], available: available) == ["fr-FR", "de-DE"])
        #expect(VisionSettings.supported(["it-IT", "de-DE", "de-CH"], available: available) == ["de-DE", "de-CH"])
        #expect(VisionSettings.supported(["fr-FR", "fr", "fr-FR"], available: available) == ["fr-FR"])
        #expect(VisionSettings.supported([], available: available) == [])
    }

    @Test("Arabic and Chinese are matched by language and script")
    func supportedScripts() {
        // The shapes of RecognizeTextRequest (maximal identifiers) and VNRecognizeTextRequest.
        for available in [
            ["en-Latn-US", "de-Latn-DE", "zh-Hans-CN", "zh-Hant-TW", "yue-Hans-CN", "ar-Arab-SA", "ars-Arab-SA"],
            ["en-US", "de-DE", "zh-Hans", "zh-Hant", "yue-Hans", "ar-SA", "ars-SA"],
        ] {
            #expect(VisionSettings.supported(["zh-Hans", "de-DE"], available: available) == ["zh-Hans", "de-DE"])
            #expect(VisionSettings.supported(["ar-SA", "de-DE"], available: available) == ["ar-SA", "de-DE"])
            #expect(VisionSettings.supported(["zh-Hans", "zh-Hant"], available: available) == ["zh-Hans", "zh-Hant"])
            #expect(VisionSettings.supported(["zh-Hans", "zh"], available: available) == ["zh-Hans"])
        }
        // Simplified Chinese is not supported by an engine that only knows traditional characters.
        #expect(VisionSettings.supported(["zh-Hans", "de-DE"], available: ["zh-Hant", "de-DE"]) == ["de-DE"])
        #expect(VisionSettings.supported(["ar-SA"], available: ["en-US", "de-DE"]) == [])
    }

    @Test("A rejected language combination is retried with the term language alone")
    func languageFallback() async throws {
        let calls = Calls()
        let result = try await VisionSettings.withFallback(["zh-Hans", "de-DE"]) { tags in
            await calls.add(tags)
            if tags.count > 1 { throw RecognizerFailure() }
            return tags.joined(separator: "+")
        }
        #expect(result == "zh-Hans")
        #expect(await calls.list == [["zh-Hans", "de-DE"], ["zh-Hans"]])

        // A supported combination runs once.
        let once = Calls()
        _ = try await VisionSettings.withFallback(["fr-FR", "de-DE"]) { tags in await once.add(tags) }
        #expect(await once.list == [["fr-FR", "de-DE"]])

        // A single language (or none) has nothing to fall back to; the second failure is reported.
        await #expect(throws: RecognizerFailure.self) {
            try await VisionSettings.withFallback(["ar-SA"]) { _ -> Int in throw RecognizerFailure() }
        }
        await #expect(throws: RecognizerFailure.self) {
            try await VisionSettings.withFallback(["ar-SA", "de-DE"]) { _ -> Int in throw RecognizerFailure() }
        }
        // A cancellation is never retried.
        let cancelled = Calls()
        await #expect(throws: CancellationError.self) {
            try await VisionSettings.withFallback(["zh-Hans", "de-DE"]) { tags -> Int in
                await cancelled.add(tags)
                throw CancellationError()
            }
        }
        #expect(await cancelled.list.count == 1)
    }

    /// The language lists a fallback test saw.
    actor Calls {
        private(set) var list: [[String]] = []
        func add(_ tags: [String]) { list.append(tags) }
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(OCRImage.whiteContext(width: 1, height: 1))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = try #require(context.data)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return [bytes[0], bytes[1], bytes[2]]
    }
}
