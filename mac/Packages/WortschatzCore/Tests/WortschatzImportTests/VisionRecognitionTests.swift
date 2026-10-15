import CoreGraphics
import Foundation
import Testing
import WortschatzCore
@testable import WortschatzImport

// End-to-end text recognition with the real Vision engines on images and scanned PDFs drawn at
// test time (CoreText): two-column French/German tables, slightly rotated photos, small
// screenshots, HEIC photos and rasterised PDF pages.
@Suite("Text recognition with Vision", .serialized)
struct VisionRecognitionTests {
    static let languages = RecognitionLanguages.forSet(termLang: .fr, defLang: .de)
    static let expected = TestDocuments.tableLines()

    @Test("A two-column vocabulary photo becomes term<TAB>definition lines")
    func table() async throws {
        let png = TestDocuments.encode(TestDocuments.tableImage(), as: .png)
        let text = try await OCRService().recognizeImage(png, languages: Self.languages)
        #expect(text.components(separatedBy: "\n") == Self.expected)
    }

    @Test("A slightly rotated photo is straightened before the rows are rebuilt")
    func rotated() async throws {
        for angle in [0.035, -0.03, 0.06, -0.015] {
            let image = TestDocuments.tableImage(width: 1800, angle: angle)
            let text = try await OCRService().recognize(image, languages: Self.languages)
            #expect(text.components(separatedBy: "\n") == Self.expected, "angle \(angle)")
        }
    }

    @Test("A small screenshot is upscaled and still read")
    func smallScreenshot() async throws {
        let image = TestDocuments.tableImage(Array(TestDocuments.rows.prefix(5)), width: 640, fontSize: 17, pitch: 30, columns: (40, 330))
        let progress = ProgressLog()
        let text = try await OCRService().recognize(image, languages: Self.languages, progress: progress.handler)
        #expect(text.components(separatedBy: "\n") == Array(Self.expected.prefix(5)))
        #expect(progress.messages.first == "Texterkennung läuft …")
        #expect(progress.fractions.last == 1)
    }

    static let longList = TestDocuments.rows + [
        ("le vélo", "das Velo"), ("la gare", "der Bahnhof"), ("le billet", "die Fahrkarte"), ("manger", "essen"),
        ("boire", "trinken"), ("le pain", "das Brot"),
    ]

    /// Every row was paired and at most `misreads` rows differ (single letters may be misread at
    /// this print size, e.g. "fatigue" for "fatigué").
    static func expectRows(_ text: String, _ rows: [(String, String)], misreads: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let lines = text.components(separatedBy: "\n")
        let expected = TestDocuments.tableLines(rows)
        #expect(lines.count == expected.count, "\(lines)", sourceLocation: sourceLocation)
        #expect(lines.allSatisfy { $0.split(separator: "\t").count == 2 }, "\(lines)", sourceLocation: sourceLocation)
        let wrong = zip(lines, expected).filter { $0 != $1 }.count
        #expect(wrong <= misreads, "\(lines)", sourceLocation: sourceLocation)
    }

    @Test("Small print on a full page is read band by band")
    func smallPrintPage() async throws {
        let table = TestDocuments.tableImage(Self.longList, width: 2000, fontSize: 30, pitch: 39, columns: (200, 1000), angle: 0.012)
        let context = try #require(OCRImage.whiteContext(width: 2000, height: 2828))
        context.draw(table, in: CGRect(x: 0, y: 2828 - table.height - 300, width: table.width, height: table.height))
        let page = try #require(context.makeImage())
        let text = try await OCRService().recognize(page, languages: Self.languages)
        Self.expectRows(text, Self.longList, misreads: 3)
    }

    @Test("Far-apart columns of a wide, slightly rotated photo are both read and paired")
    func farApartColumns() async throws {
        for angle in [-0.024, 0.012] {
            let image = TestDocuments.tableImage(Self.longList, width: 2400, fontSize: 30, pitch: 44, columns: (80, 1300), angle: angle)
            let text = try await OCRService().recognize(image, languages: Self.languages)
            Self.expectRows(text, Self.longList, misreads: 2)
        }
    }

    @Test("HEIC photos are decoded natively")
    func heic() async throws {
        let heic = TestDocuments.encode(TestDocuments.tableImage(), as: .heic)
        #expect(ImportFileType.sniff(heic) == .heic)
        let file = try await ImportPipeline().read(ImportSource(data: heic, name: "IMG_0412.HEIC"))
        #expect(file.kind == .image)
        #expect(file.text.components(separatedBy: "\n") == Self.expected)
    }

    @Test("A scanned PDF without text layer is rendered and recognised")
    func scannedPDF() async throws {
        let scan = TestDocuments.tableImage(width: 1700, fontSize: 44, angle: 0.012)
        let data = TestDocuments.pdf(pages: [{ TestDocuments.drawScan(scan, in: $0) }])
        let output = try await PDFTextExtractor().extractText(from: data, languages: Self.languages)
        #expect(output.text.components(separatedBy: "\n") == Self.expected)
        #expect(output.warnings.isEmpty)
    }

    @Test("A text PDF with a scanned insert keeps both")
    func mixedPDF() async throws {
        let insert = TestDocuments.tableImage([("le vélo", "das Velo"), ("la gare", "der Bahnhof")], width: 1600, fontSize: 46)
        let data = TestDocuments.pdf(pages: [
            { TestDocuments.drawTable(Array(TestDocuments.rows.prefix(3)), in: $0) },
            { TestDocuments.drawScan(insert, in: $0) },
        ])
        let output = try await PDFTextExtractor().extractText(from: data, languages: Self.languages)
        let pages = output.text.components(separatedBy: "\n\n")
        #expect(pages.count == 2)
        #expect(pages.first?.components(separatedBy: "\n") == Array(Self.expected.prefix(3)))
        #expect(pages.last?.components(separatedBy: "\n") == ["le vélo\tdas Velo", "la gare\tder Bahnhof"])
    }

    @Test("The macOS 14 engine (VNRecognizeTextRequest) reads the same table")
    func legacyEngine() async throws {
        let service = OCRService(recognizer: LegacyVisionTextRecognizer())
        let text = try await service.recognize(TestDocuments.tableImage(), languages: Self.languages)
        #expect(text.components(separatedBy: "\n") == Self.expected)
    }

    @Test("Cancelling a recognition stops it with Import abgebrochen")
    func cancel() async throws {
        let image = TestDocuments.tableImage(Array(repeating: ("le château numéro", "das Schloss Nummer"), count: 40), width: 2400)
        for recognizer in [SystemTextRecognizer.make(), LegacyVisionTextRecognizer()] as [any TextRecognizing] {
            let service = OCRService(recognizer: recognizer)
            let task = Task { try await service.recognize(image, languages: Self.languages) }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            await #expect(throws: ImportError.aborted) { try await task.value }
        }
    }

    static let arabicRows: [(String, String)] = [
        ("كتاب", "das Buch"), ("قلم", "der Stift"), ("بيت", "das Haus"), ("مدرسة", "die Schule"), ("شكرا", "danke"),
    ]
    static let chineseRows: [(String, String)] = [
        ("你好", "hallo"), ("谢谢", "danke"), ("学生", "der Student"), ("中国", "China"), ("朋友", "der Freund"),
    ]

    /// Arabic (ar-SA) and Simplified Chinese (zh-Hans), alone and with German (the set's languages).
    /// Vision accepts both combinations; were one rejected, the term language alone would be used.
    @Test("Arabic and Chinese tables are read alone and together with German", arguments: [
        (["ar-SA"], "ar"), (RecognitionLanguages.forSet(termLang: .ar), "ar"),
        (["zh-Hans"], "zh"), (RecognitionLanguages.forSet(termLang: .zh), "zh"),
    ])
    func scripts(languages: [String], script: String) async throws {
        // The macOS 14 engine has no Arabic and misses this Chinese column without band passes.
        guard #available(macOS 15.0, *) else { return }
        let rows = script == "ar" ? Self.arabicRows : Self.chineseRows
        let text = try await OCRService().recognize(TestDocuments.tableImage(rows), languages: languages)
        #expect(text.components(separatedBy: "\n") == TestDocuments.tableLines(rows), "\(languages)")
    }

    @Test("A blank image has no text")
    func blank() async throws {
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        await #expect(throws: ImportError(.noText, ImportMessages.imageEmpty)) {
            try await ImportPipeline().read(ImportSource(data: png, contentType: .png))
        }
    }
}
