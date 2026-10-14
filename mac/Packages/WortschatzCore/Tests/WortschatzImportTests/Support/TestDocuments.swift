import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import WortschatzImport

/// Builds images and PDFs at test time with CoreText / CoreGraphics (nothing is stored on disk).
enum TestDocuments {
    /// A French → German vocabulary table (Swiss spelling).
    static let rows: [(String, String)] = [
        ("le château", "das Schloss"),
        ("la fille", "das Mädchen"),
        ("beau, belle", "schön"),
        ("la porte", "die Tür"),
        ("fatigué", "müde"),
        ("avoir lieu", "stattfinden"),
        ("la rue", "die Strasse"),
        ("le garçon", "der Junge"),
    ]

    /// `term\tdefinition` lines of `rows`.
    static func tableLines(_ rows: [(String, String)] = rows) -> [String] {
        rows.map { "\($0.0)\t\($0.1)" }
    }

    // MARK: - Drawing

    /// Draws one line of text with its baseline start at `point` (bottom-left origin).
    static func draw(_ text: String, at point: CGPoint, size: CGFloat, angle: CGFloat = 0, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A white image with a two-column table, optionally rotated by `angle` radians around its centre.
    static func tableImage(
        _ rows: [(String, String)] = rows, width: Int = 1600, fontSize: CGFloat = 40, pitch: CGFloat = 72,
        columns: (CGFloat, CGFloat) = (110, 820), angle: CGFloat = 0, transparent: Bool = false
    ) -> CGImage {
        let height = Int(CGFloat(rows.count) * pitch + 3 * pitch)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: angle)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        for (i, row) in rows.enumerated() {
            let y = CGFloat(height) - 1.5 * pitch - CGFloat(i) * pitch
            draw(row.0, at: CGPoint(x: columns.0, y: y), size: fontSize, in: context)
            draw(row.1, at: CGPoint(x: columns.1, y: y), size: fontSize, in: context)
        }
        return context.makeImage()!
    }

    // MARK: - PDF

    static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// A PDF whose pages are drawn by the closures (bottom-left origin, A4).
    static func pdf(
        pages: [@Sendable (CGContext) -> Void], mediaBox: CGRect = a4, auxiliaryInfo: [CFString: Any] = [:]
    ) -> Data {
        let data = NSMutableData()
        var box = mediaBox
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, auxiliaryInfo as CFDictionary)!
        for page in pages {
            context.beginPDFPage(nil)
            page(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Draws a two-column table on a PDF page (text layer).
    static func drawTable(
        _ rows: [(String, String)], in context: CGContext, top: CGFloat = 760, pitch: CGFloat = 22, size: CGFloat = 12,
        columns: (CGFloat, CGFloat) = (60, 300)
    ) {
        for (i, row) in rows.enumerated() {
            let y = top - CGFloat(i) * pitch
            draw(row.0, at: CGPoint(x: columns.0, y: y), size: size, in: context)
            draw(row.1, at: CGPoint(x: columns.1, y: y), size: size, in: context)
        }
    }

    /// A text PDF with one two-column table page.
    static func tablePDF(_ rows: [(String, String)] = rows) -> Data {
        pdf(pages: [{ drawTable(rows, in: $0) }])
    }

    /// Draws `image` over the whole page, like a scanner (no text layer).
    static func drawScan(_ image: CGImage, in context: CGContext, page: CGRect = a4) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(page)
        let aspect = CGFloat(image.height) / CGFloat(image.width)
        let width = page.width - 40
        context.draw(image, in: CGRect(x: 20, y: page.height - 20 - width * aspect, width: width, height: width * aspect))
    }

    /// A blank "scan" (an image without any text).
    static func blankImage(width: Int = 400, height: Int = 300) -> CGImage {
        let context = OCRImage.whiteContext(width: width, height: height)!
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 60, height: 60))
        return context.makeImage()!
    }

    /// Re-saves a PDF with every page rotated by `degrees` (the /Rotate entry).
    static func rotatingPages(_ data: Data, by degrees: Int) -> Data {
        let document = PDFDocument(data: data)!
        for i in 0..<document.pageCount { document.page(at: i)!.rotation = degrees }
        return document.dataRepresentation()!
    }

    // MARK: - Image files

    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Rotates an image by quarter turns (counter-clockwise), for EXIF orientation tests.
    static func rotatedQuarter(_ image: CGImage) -> CGImage {
        let context = OCRImage.whiteContext(width: image.height, height: image.width)!
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!
    }

    // MARK: - Files

    /// A fresh temporary directory, removed by the caller with `remove()`.
    struct TempDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("WortschatzImportTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(_ name: String, _ data: Data) throws -> URL {
            let file = url.appendingPathComponent(name)
            try data.write(to: file)
            return file
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A resource copied from the web app's tests/fixtures.
    static func resource(_ name: String) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let url = try #require(
            Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Resources")
                ?? Bundle.module.url(forResource: base, withExtension: ext))
        return try Data(contentsOf: url)
    }
}

/// A text recognition engine driven by a script (the stubbed tesseract of tests/import-files.test.js).
actor ScriptedRecognizer: TextRecognizing {
    private(set) var calls = 0
    private(set) var languages: [[String]] = []
    private let script: @Sendable (Int) async throws -> [OCRLine]

    init(_ script: @escaping @Sendable (Int) async throws -> [OCRLine]) {
        self.script = script
    }

    func recognizeText(
        in image: CGImage, languages: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [OCRLine] {
        let call = calls
        calls += 1
        self.languages.append(languages)
        return try await script(call)
    }
}

struct RecognizerFailure: Error {}

/// Synthetic recognition results (port of the tessWord / tessTable helpers of tests/layout.test.js):
/// 11 px per character, word boxes 22 px above to 4 px below the baseline, rows 40 px apart.
enum FakeOCR {
    /// `slope` shears the rows like the JS helper (y + slope · x). `rotated` turns the whole page by
    /// `atan(slope)` instead; `rectified` then keeps every box level at its rotated position, like
    /// Vision's boxes for slightly rotated photos.
    static func word(
        _ text: String, x: Double, baseline: Double, slope: Double = 0, confidence: Double = 0.9,
        rotated: Bool = false, rectified: Bool = false
    ) -> OCRWord {
        let w = Double(text.count) * 11
        let angle = atan(slope)
        func turn(_ px: Double, _ py: Double) -> CGPoint {
            CGPoint(x: px * cos(angle) - py * sin(angle), y: px * sin(angle) + py * cos(angle))
        }
        func point(_ px: Double, _ py: Double) -> CGPoint {
            guard rotated else { return CGPoint(x: px, y: py + slope * px) }
            guard rectified else { return turn(px, py) }
            let anchor = turn(x, baseline)
            return CGPoint(x: anchor.x + (px - x), y: anchor.y + (py - baseline))
        }
        let quad = OCRQuad(
            topLeft: point(x, baseline - 22), topRight: point(x + w, baseline - 22),
            bottomRight: point(x + w, baseline + 4), bottomLeft: point(x, baseline + 4))
        return OCRWord(text: text, confidence: confidence, quad: quad)
    }

    /// One recognised line per cell: the term at x 60, the definition at x 520.
    static func table(
        _ rows: [(String, String)], slope: Double = 0, bars: Bool = false, rotated: Bool = false, rectified: Bool = false
    ) -> [OCRLine] {
        var lines: [OCRLine] = []
        for (r, row) in rows.enumerated() {
            let base = 120 + Double(r) * 40
            for (text, x0) in [(row.0, 60.0), (row.1, 520.0)] {
                var words: [OCRWord] = []
                var x = x0
                for part in text.split(separator: " ") {
                    words.append(word(String(part), x: x, baseline: base, slope: slope, rotated: rotated, rectified: rectified))
                    x += Double(part.count + 1) * 11
                }
                if bars && x0 == 60 { words.append(word("|", x: 420, baseline: base, slope: slope, confidence: 0.2)) }
                let quad = OCRQuad(
                    topLeft: words[0].quad.topLeft, topRight: words[words.count - 1].quad.topRight,
                    bottomRight: words[words.count - 1].quad.bottomRight, bottomLeft: words[0].quad.bottomLeft)
                lines.append(OCRLine(text: text, confidence: 0.9, quad: quad, words: words))
            }
        }
        return lines
    }
}
