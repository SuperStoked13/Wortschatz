import CoreGraphics
import Foundation
import Testing
@testable import WortschatzImport

@Suite("BandedTextRecognizer")
struct BandedTextRecognizerTests {
    typealias Region = BandedTextRecognizer.Region
    typealias Size = BandedTextRecognizer.Size

    static func line(_ text: String, x: Double, y: Double, width: Double = 200, height: Double = 30, confidence: Double = 1) -> OCRLine {
        let quad = OCRQuad(x: x, y: y, width: width, height: height)
        return OCRLine(text: text, confidence: confidence, quad: quad, words: [OCRWord(text: text, confidence: confidence, quad: quad)])
    }

    @Test("Small images get one pass; tall ones bands, wide ones a left and a right part")
    func regions() {
        let small = BandedTextRecognizer.regions(
            for: Size(width: 800, height: 600), bandHeights: [600, 1000], overlap: 0.25, singlePassHeight: 900, splitWidth: 1000)
        #expect(small == [Region(x: 0, y: 0, width: 800, height: 600)])

        let page = BandedTextRecognizer.regions(
            for: Size(width: 900, height: 2000), bandHeights: [600, 1000], overlap: 0.25, singlePassHeight: 900, splitWidth: 1000)
        #expect(page.first == Region(x: 0, y: 0, width: 900, height: 2000))
        let bands600 = page.filter { $0.height == 600 }
        let bands1000 = page.filter { $0.height == 1000 }
        #expect(bands600.count == 5)
        #expect(bands600.first?.y == 0 && bands600.last?.y == 1400)
        #expect(bands1000.map(\.y) == [0, 500, 1000])
        // Neighbouring bands overlap by at least a quarter.
        for bands in [bands600, bands1000] {
            for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.y + a.height - b.y >= a.height / 4) }
        }

        let wide = BandedTextRecognizer.regions(
            for: Size(width: 2400, height: 750), bandHeights: [600, 1000], overlap: 0.25, singlePassHeight: 900, splitWidth: 1000)
        #expect(wide == [
            Region(x: 0, y: 0, width: 2400, height: 750), Region(x: 0, y: 0, width: 1440, height: 750),
            Region(x: 960, y: 0, width: 1440, height: 750),
        ])
    }

    @Test("Lines touching a cut edge are dropped, the others move into image coordinates")
    func place() throws {
        let image = Size(width: 2000, height: 3000)
        let band = Region(x: 0, y: 1000, width: 2000, height: 600)
        #expect(BandedTextRecognizer.place(Self.line("oben", x: 100, y: 1, height: 30), in: band, image: image) == nil)
        #expect(BandedTextRecognizer.place(Self.line("unten", x: 100, y: 575, height: 24), in: band, image: image) == nil)
        let inside = try #require(BandedTextRecognizer.place(Self.line("la gare", x: 100, y: 300), in: band, image: image))
        #expect(inside.quad.topLeft == CGPoint(x: 100, y: 1300))
        #expect(inside.words[0].quad.bottomLeft == CGPoint(x: 100, y: 1330))
        // The image's own edges are not cuts.
        let top = Region(x: 0, y: 0, width: 2000, height: 600)
        #expect(BandedTextRecognizer.place(Self.line("Titel", x: 100, y: 0), in: top, image: image) != nil)
        let right = Region(x: 800, y: 0, width: 1200, height: 3000)
        #expect(BandedTextRecognizer.place(Self.line("das Sch", x: 0, y: 500, width: 120), in: right, image: image) == nil)
        let moved = try #require(BandedTextRecognizer.place(Self.line("das Haus", x: 400, y: 500), in: right, image: image))
        #expect(moved.quad.topLeft == CGPoint(x: 1200, y: 500))
    }

    @Test("Merging keeps one line per place, preferring lines confirmed by several passes")
    func merge() {
        let lines = [
            Self.line("le chateau", x: 100, y: 100, confidence: 1),
            Self.line("le château", x: 101, y: 101, confidence: 0.5),
            Self.line("le château", x: 99, y: 100, confidence: 0.5),
            Self.line("das Schloss", x: 900, y: 102),
            Self.line("das Schloss", x: 902, y: 101),
            Self.line("la fille", x: 100, y: 160),
            // A column of words read as one tall line.
            Self.line("Heatallatalandia", x: 880, y: 150, width: 60, height: 400, confidence: 1),
        ]
        let merged = BandedTextRecognizer.merge(lines)
        #expect(merged.map(\.text) == ["le château", "das Schloss", "la fille"])
    }

    @Test("Passes run on crops of the image and report progress")
    func passes() async throws {
        let sizes = SizeLog()
        let base = ScriptedRecognizer { _ in [] }
        let recognizer = BandedTextRecognizer(base: SizeRecordingRecognizer(base: base, log: sizes))
        let image = try #require(OCRImage.whiteContext(width: 1200, height: 1800)?.makeImage())
        let progress = ProgressLog()
        _ = try await recognizer.recognizeText(in: image, languages: ["fr-FR"]) { fraction in
            progress.handler(ImportProgress(fraction: fraction, message: ""))
        }
        let expected = BandedTextRecognizer.regions(
            for: Size(width: 1200, height: 1800), bandHeights: [600, 1000], overlap: 0.25, singlePassHeight: 900, splitWidth: 1000)
        #expect(sizes.sizes == expected.map { Size(width: $0.width, height: $0.height) })
        #expect(progress.fractions.count == expected.count)
        #expect(progress.fractions.last == 1)
        #expect(await base.calls == expected.count)
    }
}

/// Records the image size of every pass.
final class SizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BandedTextRecognizer.Size] = []

    func append(_ size: BandedTextRecognizer.Size) { lock.withLock { recorded.append(size) } }
    var sizes: [BandedTextRecognizer.Size] { lock.withLock { recorded } }
}

struct SizeRecordingRecognizer: TextRecognizing {
    let base: any TextRecognizing
    let log: SizeLog

    func recognizeText(
        in image: CGImage, languages: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [OCRLine] {
        log.append(BandedTextRecognizer.Size(width: image.width, height: image.height))
        return try await base.recognizeText(in: image, languages: languages, progress: progress)
    }
}
