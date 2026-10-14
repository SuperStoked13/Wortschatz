import Foundation
import Testing
import WortschatzCore
@testable import WortschatzImport

// readImportFile (src/import/files.js) and the editor's multi-file loop (editor-import.js), with a
// scripted recognition engine; real Vision runs are in VisionRecognitionTests.
@Suite("ImportPipeline (files.js)")
struct ImportPipelineTests {
    static func pipeline(_ recognizer: ScriptedRecognizer = ScriptedRecognizer { _ in
        FakeOCR.table([("la gare", "der Bahnhof")])
    }) -> ImportPipeline {
        ImportPipeline(ocr: OCRService(recognizer: recognizer))
    }

    // MARK: - Text files

    @Test("A text file is decoded; its BOM is removed")
    func textFile() async throws {
        let dir = try TestDocuments.TempDirectory()
        defer { dir.remove() }
        let url = try dir.file("Unité 3.txt", Data([0xEF, 0xBB, 0xBF] + Array("le chat\tdie Katze\n".utf8)))
        let progress = ProgressLog()
        let file = try await Self.pipeline().read(ImportSource(url: url), progress: progress.handler)
        #expect(file == ImportedFile(text: "le chat\tdie Katze\n", kind: .text, name: "Unité 3.txt", warnings: []))
        #expect(progress.messages == ["Datei wird gelesen …", "Datei gelesen"])
        #expect(progress.fractions == [0, 1])
    }

    @Test("The web fixture windows-bom.txt reads as text")
    func webFixture() async throws {
        let data = try TestDocuments.resource("windows-bom.txt")
        let file = try await Self.pipeline().read(ImportSource(data: data, name: "windows-bom.txt"))
        #expect(file.kind == .text)
        #expect(file.text.hasPrefix("le chien"))
    }

    @Test("Windows-1252 CSV exports are read")
    func legacyCSV() async throws {
        let bytes = "la fenêtre;das Fenster\r\nle rôle;die Rolle\r\nmûr;reif\r\nà côté;daneben".unicodeScalars.map { UInt8($0.value) }
        let file = try await Self.pipeline().read(ImportSource(data: Data(bytes), name: "export.csv"))
        #expect(file.text == "la fenêtre;das Fenster\r\nle rôle;die Rolle\r\nmûr;reif\r\nà côté;daneben")
    }

    // MARK: - Errors

    @Test("Empty, unreadable and unsupported files fail with German messages")
    func errors() async throws {
        let dir = try TestDocuments.TempDirectory()
        defer { dir.remove() }
        let pipeline = Self.pipeline(ScriptedRecognizer { _ in [] })
        await #expect(throws: ImportError(.empty, ImportMessages.empty)) {
            try await pipeline.read(ImportSource(url: try dir.file("leer.txt", Data())))
        }
        await #expect(throws: ImportError(.read, ImportMessages.read)) {
            try await pipeline.read(ImportSource(url: dir.url))
        }
        await #expect(throws: ImportError(.read, ImportMessages.read)) {
            try await pipeline.read(ImportSource(url: dir.url.appendingPathComponent("fehlt.pdf")))
        }
        await #expect(throws: ImportError(.unsupported, ImportMessages.document)) {
            try await pipeline.read(ImportSource(url: try dir.file("brief.docx", Data("PK\u{3}\u{4}".utf8))))
        }
        await #expect(throws: ImportError(.unsupported, ImportMessages.unsupported)) {
            try await pipeline.read(ImportSource(url: try dir.file("logo.svg", Data("<svg/>".utf8))))
        }
        // A "text" file full of binary data.
        await #expect(throws: ImportError(.unsupported, ImportMessages.unsupported)) {
            try await pipeline.read(ImportSource(data: Data((0..<200).map { UInt8($0 % 9) }), name: "daten.txt"))
        }
        await #expect(throws: ImportError(.tooLarge, ImportMessages.tooLarge)) {
            let big = Data(repeating: 0x61, count: ImportPipeline.maxTextBytes + 1)
            return try await pipeline.read(ImportSource(url: try dir.file("gross.txt", big)))
        }
        await #expect(throws: ImportError(.noText, ImportMessages.pdfEmpty)) {
            try await pipeline.read(ImportSource(data: TestDocuments.pdf(pages: [{ _ in }]), name: "leer.pdf"))
        }
        await #expect(throws: ImportError(.decode, ImportMessages.decode)) {
            try await pipeline.read(ImportSource(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), name: "kaputt.png"))
        }
    }

    @Test("Recognition failures and empty results of images")
    func imageErrors() async throws {
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        let failing = Self.pipeline(ScriptedRecognizer { _ in throw RecognizerFailure() })
        await #expect(throws: ImportError(.ocrFailed, ImportMessages.ocrFailed)) {
            try await failing.read(ImportSource(data: png, contentType: .png))
        }
        let empty = Self.pipeline(ScriptedRecognizer { _ in [] })
        await #expect(throws: ImportError(.noText, ImportMessages.imageEmpty)) {
            try await empty.read(ImportSource(data: png, contentType: .png))
        }
    }

    // MARK: - Kinds

    @Test("Mislabeled files are recognised by their content")
    func sniffing() async throws {
        let dir = try TestDocuments.TempDirectory()
        defer { dir.remove() }
        let pdf = try await Self.pipeline().read(ImportSource(url: try dir.file("scan", TestDocuments.tablePDF())))
        #expect(pdf.kind == .pdf)
        #expect(pdf.text == TestDocuments.tableLines().joined(separator: "\n"))
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        let image = try await Self.pipeline().read(ImportSource(url: try dir.file("liste.txt", png)))
        #expect(image.kind == .image)
        #expect(image.text == "la gare\tder Bahnhof")
    }

    @Test("Pasted images use the set's recognition languages")
    func pastedImage() async throws {
        let recognizer = ScriptedRecognizer { _ in FakeOCR.table([("el tren", "der Zug")]) }
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        let progress = ProgressLog()
        let file = try await Self.pipeline(recognizer).read(
            ImportSource(data: png, contentType: .png), termLang: .es, defLang: .de, progress: progress.handler)
        #expect(file == ImportedFile(text: "el tren\tder Zug", kind: .image, name: ""))
        #expect(await recognizer.languages == [["es-ES", "de-DE"]])
        #expect(progress.messages.first == "Bild wird vorbereitet …")
        #expect(progress.messages.contains("Texterkennung läuft …"))
        #expect(progress.fractions.last == 1)
    }

    // MARK: - Several files

    @Test("Several files: texts in order, failures and warnings with the file name")
    func batch() async throws {
        let dir = try TestDocuments.TempDirectory()
        defer { dir.remove() }
        let mixed = TestDocuments.pdf(pages: [PDFTextExtractorTests.textPage, PDFTextExtractorTests.scannedPage])
        let sources = [
            ImportSource(url: try dir.file("liste.txt", Data("  le vélo\tdas Velo  \n".utf8))),
            ImportSource(url: try dir.file("brief.docx", Data("PK".utf8))),
            ImportSource(url: try dir.file("unite.pdf", mixed)),
            ImportSource(url: try dir.file("leer.txt", Data("   \n".utf8))),
        ]
        let progress = ProgressLog()
        let batch = try await Self.pipeline(ScriptedRecognizer { _ in throw RecognizerFailure() })
            .readAll(sources, progress: progress.handler)
        #expect(batch.texts == ["le vélo\tdas Velo", PDFTextExtractorTests.textRows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n")])
        #expect(batch.text == batch.texts.joined(separator: "\n\n"))
        #expect(batch.files.map(\.name) == ["liste.txt", "unite.pdf", "leer.txt"])
        #expect(batch.firstName == "liste.txt")
        #expect(batch.errorMessages == ["«brief.docx»: \(ImportMessages.document)"])
        #expect(batch.failures.map(\.error.code) == [.unsupported])
        #expect(batch.warnings.count == 1)
        #expect(batch.warnings[0].hasPrefix("«unite.pdf»: Seite 2 ist gescannt"))
        #expect(progress.messages.first == "Datei 1 von 4: Datei wird gelesen …")
        #expect(progress.messages.contains("Datei 3 von 4: PDF wird geöffnet …"))
        #expect(progress.fractions == progress.fractions.sorted())
        #expect(batch.appended(to: "  la gare\tder Bahnhof \n") == "la gare\tder Bahnhof\n\n" + batch.text)
        #expect(batch.appended(to: " \n ") == batch.text)
    }

    @Test("Pasted content gets no name prefix and no title suggestion")
    func pastedBatch() async throws {
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        let failing = try await Self.pipeline(ScriptedRecognizer { _ in throw RecognizerFailure() })
            .readAll([ImportSource(data: png, contentType: .png)])
        #expect(failing.errorMessages == [ImportMessages.ocrFailed])
        let ok = try await Self.pipeline().readAll([ImportSource(data: png, contentType: .png)])
        #expect(ok.texts == ["la gare\tder Bahnhof"])
        #expect(ok.firstName == nil)
    }

    // MARK: - Cancellation

    @Test("An already cancelled import rejects before anything is read")
    func alreadyCancelled() async throws {
        let recognizer = ScriptedRecognizer { _ in [] }
        let pipeline = Self.pipeline(recognizer)
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.readAll([ImportSource(data: png, contentType: .png)])
        }
        await #expect(throws: ImportError.aborted) { try await task.value }
        #expect(await recognizer.calls == 0)
    }

    @Test("Cancelling a batch stops it and drops its results")
    func cancelBatch() async throws {
        let recognizer = ScriptedRecognizer { _ in
            try await Task.sleep(for: .seconds(60))
            return []
        }
        let pipeline = Self.pipeline(recognizer)
        let png = TestDocuments.encode(TestDocuments.blankImage(), as: .png)
        let sources = [ImportSource(data: Data("le chat\tdie Katze".utf8), name: "a.txt"), ImportSource(data: png, name: "b.png")]
        let task = Task { try await pipeline.readAll(sources) }
        while await recognizer.calls == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: ImportError.aborted) { try await task.value }
    }
}
