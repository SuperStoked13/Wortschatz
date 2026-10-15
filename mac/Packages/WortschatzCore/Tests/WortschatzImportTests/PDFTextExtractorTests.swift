import CoreGraphics
import Foundation
import PDFKit
import Testing
import WortschatzCore
@testable import WortschatzImport

// PDF reading with PDFKit (port of tests/import-files.test.js, with PDFs created at test time and a
// scripted recognition engine in place of the stubbed tesseract) plus real-PDF layout checks.
@Suite("PDFTextExtractor (pdf.js)")
struct PDFTextExtractorTests {
    static let textRows: [(String, String)] = [
        ("le chat", "die Katze"),
        ("le chien", "der Hund"),
        ("la maison", "das Haus"),
        ("le jardin", "der Garten"),
    ]

    static func textPage(_ context: CGContext) { TestDocuments.drawTable(textRows, in: context) }

    static func scannedPage(_ context: CGContext) { TestDocuments.drawScan(TestDocuments.blankImage(), in: context) }

    static func extractor(_ recognizer: ScriptedRecognizer) -> PDFTextExtractor {
        PDFTextExtractor(ocr: OCRService(recognizer: recognizer))
    }

    /// A recognizer that must not be called.
    static func unusedRecognizer() -> ScriptedRecognizer {
        ScriptedRecognizer { _ in
            Issue.record("text recognition was not expected")
            return []
        }
    }

    // MARK: - Text layer

    @Test("A two-column table becomes term<TAB>definition lines")
    func tableLayout() async throws {
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: TestDocuments.tablePDF())
        #expect(output.text == TestDocuments.tableLines().joined(separator: "\n"))
        #expect(output.warnings.isEmpty)
    }

    @Test("The web fixture sample.pdf: table, four columns and stacked pairs")
    func samplePDF() async throws {
        let data = try TestDocuments.resource("sample.pdf")
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: data)
        #expect(output.warnings.isEmpty)
        let pairs = [
            "le monsieur, messieurs\tder Herr", "l'homme\tder Mann", "la femme\tdie Frau", "la dame\tdie Dame",
            "l'enfant\tdas Kind", "le garçon\tder Junge",
        ]
        let expected: [String] =
            // Page 1: heading, then a two-column table.
            ["Unité 1 – Les personnes", ""] + pairs
            + [
                "la fille\tdas Mädchen", "s'appeler\theissen", "le nom de famille\tder Familienname",
                "le prénom\tder Vorname", "marié, mariée\tverheiratet", "la rue\tdie Strasse", "",
            ]
            // Page 2: a four-column table, left pairs first, then right pairs.
            + pairs + [""]
            + ["brave\tlieb", "gentil, gentille\tlieb, nett", "aimable\tfreundlich", "sage\tbrav, artig", "calme\truhig", "bête\tdumm", ""]
            // Page 3: stacked pairs separated by blank lines.
            + ["brave", "lieb", "", "gentil, gentille", "lieb, nett", "", "aimable", "freundlich", "", "sage", "brav, artig", ""]
            + ["calme", "ruhig", "", "bête", "dumm"]
        #expect(output.text.components(separatedBy: "\n") == expected)
    }

    @Test("The user's 52-pair list survives a PDF round trip line by line")
    func userList() async throws {
        let text = String(decoding: try TestDocuments.resource("user-example.txt"), as: UTF8.self)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // One line per 16 pt, a new page every 44 lines.
        var pages: [@Sendable (CGContext) -> Void] = []
        for start in stride(from: 0, to: lines.count, by: 44) {
            let chunk = Array(lines[start..<min(lines.count, start + 44)])
            pages.append { context in
                for (i, line) in chunk.enumerated() where !line.isEmpty {
                    TestDocuments.draw(line, at: CGPoint(x: 60, y: 790 - CGFloat(i) * 16), size: 11, in: context)
                }
            }
        }
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: TestDocuments.pdf(pages: pages))
        let extracted = output.text.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(extracted == lines.filter { !$0.isEmpty })
    }

    @Test("Rotated pages are read upright; rotated margin notes are skipped")
    func rotation() async throws {
        // Content drawn sideways on a page with /Rotate 90 appears upright in a viewer.
        let sideways = TestDocuments.pdf(pages: [{ context in
            context.translateBy(x: 595, y: 0)
            context.rotate(by: .pi / 2)
            TestDocuments.drawTable(Self.textRows, in: context, top: 520, columns: (60, 320))
        }])
        let rotated = TestDocuments.rotatingPages(sideways, by: 90)
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: rotated)
        #expect(output.text == Self.textRows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n"))

        let withNotes = TestDocuments.pdf(pages: [{ context in
            TestDocuments.drawTable(Self.textRows, in: context)
            TestDocuments.draw("Seite 12 – Lektion 4", at: CGPoint(x: 560, y: 300), size: 10, angle: .pi / 2, in: context)
            TestDocuments.draw("Kopie", at: CGPoint(x: 200, y: 300), size: 30, angle: 0.6, in: context)
        }])
        let notes = try await Self.extractor(Self.unusedRecognizer()).extractText(from: withNotes)
        #expect(notes.text == Self.textRows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n"))
    }

    @Test("Arabic text layers: logical-order lines are not taken for rotated text; words are read right to left")
    func arabicTextLayer() async throws {
        let rows: [(String, String)] = [("الكتاب", "das Buch"), ("المدينة القديمة", "die alte Stadt"), ("مع السلامة", "auf Wiedersehen")]
        for table in [rows, rows.map { ($0.1, $0.0) }] {
            let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: TestDocuments.tablePDF(table))
            #expect(output.text == TestDocuments.tableLines(table).joined(separator: "\n"))
        }
    }

    @Test("Chinese text layers keep characters together and pinyin spaced")
    func chineseTextLayer() async throws {
        let rows: [(String, String)] = [("你好", "hallo"), ("我是学生。", "Ich bin Schüler."), ("你好 (nǐ hǎo)", "hallo")]
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: TestDocuments.tablePDF(rows))
        #expect(output.text == TestDocuments.tableLines(rows).joined(separator: "\n"))
    }

    @Test("Right-to-left characters are found by their code points")
    func rightToLeftLines() {
        let text = "das Buch الكتاب\nשלום\nle chat" as NSString
        #expect(PDFPageText.containsRightToLeft(text, 0..<15))
        #expect(PDFPageText.containsRightToLeft(text, 16..<20))
        #expect(!PDFPageText.containsRightToLeft(text, 21..<28))
    }

    @Test("Typographic ligatures become plain letters")
    func ligatures() {
        #expect(PDFPageText.expandingLigatures("ﬁn ﬂeur eﬀet") == "fin fleur effet")
        #expect(PDFPageText.expandingLigatures("le chat") == "le chat")
    }

    @Test("Pages are joined with a blank line and empty pages are dropped")
    func pageJoin() async throws {
        let data = TestDocuments.pdf(pages: [
            { TestDocuments.drawTable(Array(Self.textRows.prefix(2)), in: $0) },
            { _ in },
            { TestDocuments.drawTable(Array(Self.textRows.suffix(2)), in: $0) },
        ])
        // The blank middle page has no images, so nothing is recognised.
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: data)
        #expect(output.text == "le chat\tdie Katze\nle chien\tder Hund\n\nla maison\tdas Haus\nle jardin\tder Garten")
    }

    // MARK: - Errors

    @Test("Damaged and password-protected PDFs fail with German messages")
    func openErrors() async throws {
        let extractor = Self.extractor(Self.unusedRecognizer())
        await #expect(throws: ImportError(.pdfInvalid, ImportMessages.pdfInvalid)) {
            try await extractor.extractText(from: Data("%PDF-1.7\nkaputt".utf8))
        }
        let locked = TestDocuments.pdf(
            pages: [Self.textPage], auxiliaryInfo: [kCGPDFContextUserPassword: "geheim", kCGPDFContextOwnerPassword: "geheim"])
        await #expect(throws: ImportError(.pdfPassword, ImportMessages.pdfPassword)) {
            try await extractor.extractText(from: locked)
        }
    }

    // MARK: - Scanned pages (tests/import-files.test.js)

    @Test("Scanned pages that cannot be recognised are reported as a warning")
    func scannedFailure() async throws {
        let recognizer = ScriptedRecognizer { _ in throw RecognizerFailure() }
        let data = TestDocuments.pdf(pages: [Self.textPage, Self.scannedPage])
        let output = try await Self.extractor(recognizer).extractText(from: data)
        #expect(output.text.contains("le chat"))
        #expect(output.text.contains("der Garten"))
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].hasPrefix("Seite 2 ist gescannt und konnte nicht gelesen werden"))
        #expect(output.warnings[0].hasSuffix("Versuche es später noch einmal."))
    }

    @Test("Every skipped page is listed")
    func scannedPagesListed() async throws {
        let recognizer = ScriptedRecognizer { _ in throw RecognizerFailure() }
        let data = TestDocuments.pdf(pages: [Self.textPage, Self.scannedPage, Self.textPage, Self.scannedPage])
        let output = try await Self.extractor(recognizer).extractText(from: data)
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].hasPrefix("Die Seiten 2 und 4 sind gescannt und konnten nicht gelesen werden"))
        // The first failure stops the recognition; page 4 is never tried.
        #expect(await recognizer.calls == 1)
    }

    @Test("Only the scanned pages that failed are reported; recognised ones are kept")
    func partialRecognition() async throws {
        let recognizer = ScriptedRecognizer { call in
            if call == 0 { return FakeOCR.table([("le vélo", "das Velo")]) }
            throw RecognizerFailure()
        }
        let data = TestDocuments.pdf(pages: [Self.textPage, Self.scannedPage, Self.textPage, Self.scannedPage])
        let output = try await Self.extractor(recognizer).extractText(from: data)
        #expect(output.text.contains("le vélo\tdas Velo"))
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].hasPrefix("Seite 4 ist gescannt und konnte nicht gelesen werden"))
    }

    @Test("More scanned inserts than the limit are reported with the limit")
    func tooManyInserts() async throws {
        let pages = [Self.textPage] + Array(repeating: Self.scannedPage, count: 31)
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: TestDocuments.pdf(pages: pages))
        #expect(output.text.contains("le chat"))
        #expect(output.warnings.count == 1)
        #expect(output.warnings[0].hasPrefix("31 Seiten sind gescannt und konnten nicht gelesen werden"))
        #expect(output.warnings[0].contains("30 Seiten beschränkt"))
    }

    @Test("A scan with more than 30 pages is refused")
    func tooManyScannedPages() async throws {
        let data = TestDocuments.pdf(pages: Array(repeating: Self.scannedPage, count: 31))
        await #expect(throws: ImportError(.pdfTooManyPages, ImportMessages.pdfTooManyPages(31))) {
            try await Self.extractor(Self.unusedRecognizer()).extractText(from: data)
        }
    }

    @Test("A text PDF without scanned pages warns about nothing")
    func noWarnings() async throws {
        let output = try await Self.extractor(Self.unusedRecognizer()).extractText(from: TestDocuments.pdf(pages: [Self.textPage]))
        #expect(output.text.contains("la maison"))
        #expect(output.warnings.isEmpty)
    }

    @Test("A PDF without any text layer is recognised page by page with the set's languages")
    func scannedDocument() async throws {
        let recognizer = ScriptedRecognizer { call in FakeOCR.table([("page \(call + 1)", "Seite \(call + 1)")]) }
        let data = TestDocuments.pdf(pages: [Self.scannedPage, Self.scannedPage])
        let progress = ProgressLog()
        let output = try await Self.extractor(recognizer).extractText(
            from: data, languages: ["it-IT", "de-DE"], progress: progress.handler)
        #expect(output.text == "page 1\tSeite 1\n\npage 2\tSeite 2")
        #expect(await recognizer.languages == [["it-IT", "de-DE"], ["it-IT", "de-DE"]])
        let messages = progress.messages
        #expect(messages.first == "PDF wird geöffnet …")
        #expect(messages.contains("PDF enthält keinen Text – Texterkennung läuft …"))
        #expect(messages.contains("Seite 2 von 2 – Texterkennung läuft …"))
        #expect(messages.last == "PDF gelesen")
        #expect(progress.fractions == progress.fractions.sorted())
        #expect(progress.fractions.last == 1)
    }

    // MARK: - Cancellation

    @Test("Cancelling while pages are read stops at the next page")
    func cancelWhileReading() async throws {
        let data = TestDocuments.pdf(pages: [Self.textPage, Self.textPage, Self.textPage])
        let progress = ProgressLog()
        let extractor = Self.extractor(Self.unusedRecognizer())
        let task = Task {
            try await extractor.extractText(from: data, progress: { update in
                progress.handler(update)
                if update.message == "Seite 1 von 3 wird gelesen …" { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: ImportError.aborted) { try await task.value }
        #expect(!progress.messages.contains("Seite 2 von 3 wird gelesen …"))
    }

    @Test("Cancelling during text recognition stops the engine and renders no further page")
    func cancelDuringRecognition() async throws {
        let recognizer = ScriptedRecognizer { _ in
            try await Task.sleep(for: .seconds(60))
            return []
        }
        let data = TestDocuments.pdf(pages: [Self.scannedPage, Self.scannedPage, Self.scannedPage])
        let extractor = Self.extractor(recognizer)
        let task = Task { try await extractor.extractText(from: data) }
        while await recognizer.calls == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: ImportError.aborted) { try await task.value }
        #expect(await recognizer.calls == 1)
    }

    @Test("A cancellation is not turned into a scanned-page warning")
    func cancelIsNotAWarning() async throws {
        let recognizer = ScriptedRecognizer { _ in
            try await Task.sleep(for: .seconds(60))
            return []
        }
        let data = TestDocuments.pdf(pages: [Self.textPage, Self.scannedPage])
        let extractor = Self.extractor(recognizer)
        let task = Task { try await extractor.extractText(from: data) }
        while await recognizer.calls == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: ImportError.aborted) { try await task.value }
    }

    // MARK: - Page probes

    @Test("Image detection finds drawn images, also inside form XObjects")
    func imageProbe() throws {
        let data = TestDocuments.pdf(pages: [Self.textPage, Self.scannedPage, { context in
            // A transparency layer is written as a form XObject around the image.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.draw(TestDocuments.blankImage(), in: CGRect(x: 50, y: 50, width: 200, height: 150))
            context.endTransparencyLayer()
        }])
        let document = try #require(PDFDocument(data: data))
        let probes = (0..<3).map { PDFImageProbe.pageHasImages(document.page(at: $0)!.pageRef!) }
        #expect(probes == [false, true, true])
    }

    @Test("Scanned pages are rendered at 2000 px width, upright")
    func renderScale() throws {
        #expect(abs(PDFPageRenderer.scale(for: CGSize(width: 595, height: 842)) - 2000.0 / 595) < 1e-9)
        #expect(PDFPageRenderer.scale(for: CGSize(width: 2000, height: 1000)) == 1.5)
        #expect(PDFPageRenderer.scale(for: CGSize(width: 200, height: 300)) == 4)
        let document = try #require(PDFDocument(data: TestDocuments.rotatingPages(TestDocuments.tablePDF(), by: 90)))
        let page = try #require(document.page(at: 0))
        let image = try #require(PDFPageRenderer.render(page))
        #expect(image.width > image.height)
        #expect(image.height <= 3000 && image.width <= 3000)
    }
}

/// Collects progress updates (thread-safe).
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ImportProgress] = []

    var handler: ImportProgressHandler {
        { [self] update in lock.withLock { updates.append(update) } }
    }

    var messages: [String] { lock.withLock { updates.map(\.message) } }
    var fractions: [Double] { lock.withLock { updates.map(\.fraction) } }
}
