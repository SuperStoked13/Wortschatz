import Foundation
import Testing
import UniformTypeIdentifiers
@testable import WortschatzImport

// Port of the detectFileKind / ACCEPT cases of tests/layout.test.js plus the sniffing of files.js.
@Suite("ImportFileType (files.js)")
struct ImportFileTypeTests {
    @Test("detectKind uses the MIME type and the extension")
    func detectKind() {
        let cases: [(String, String, ImportFileKind?)] = [
            ("vokabeln.txt", "text/plain", .text),
            ("export.csv", "application/vnd.ms-excel", .text),
            ("liste.TSV", "", .text),
            ("README", "", .text),
            ("notes.md", "text/markdown", .text),
            ("unite3.pdf", "", .pdf),
            ("scan", "application/pdf", .pdf),
            ("IMG_0412.HEIC", "", .image),
            ("foto.jpg", "image/jpeg", .image),
            ("image.png", "image/png", .image),
            ("bild.webp", "", .image),
            ("logo.svg", "image/svg+xml", nil),
            ("brief.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", nil),
            ("text.rtf", "text/rtf", nil),
            ("seite.html", "text/html", nil),
            // Additional cases of the same rules.
            ("liste.tab", "", .text),
            ("liste", "text/csv; charset=utf-8", .text),
            ("daten", "application/tab-separated-values", .text),
            (".bashrc", "", .text),
            ("archiv.zip", "application/zip", nil),
            ("seite.", "", .text),
            ("Tabelle.numbers", "", nil),
            ("scan.TIFF", "", .image),
            ("foto", "image/heic", .image),
            ("stil.css", "text/css", nil),
        ]
        for (name, type, expected) in cases {
            #expect(ImportFileType.detectKind(name: name, mimeType: type) == expected, "\(name) \(type)")
        }
    }

    @Test("Content sniffing recognises PDFs and images regardless of the name")
    func sniff() {
        #expect(ImportFileType.sniff(Array("%PDF-1.7\n".utf8)) == .pdf)
        #expect(ImportFileType.sniff([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == .image)
        #expect(ImportFileType.sniff([0xFF, 0xD8, 0xFF, 0xE0]) == .image)
        #expect(ImportFileType.sniff(Array("GIF89a".utf8)) == .image)
        #expect(ImportFileType.sniff(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == .image)
        #expect(ImportFileType.sniff([0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0]) == .heic)
        #expect(ImportFileType.sniff([0, 0, 0, 0x18] + Array("ftypmif1".utf8)) == .heic)
        #expect(ImportFileType.sniff([0, 0, 0, 0x18] + Array("ftypavif".utf8)) == .image)
        #expect(ImportFileType.sniff([0, 0, 0, 0x18] + Array("ftypisom".utf8)) == nil)
        #expect(ImportFileType.sniff(Array("le chat\tdie Katze".utf8)) == nil)
        #expect(ImportFileType.sniff([UInt8]()) == nil)
        #expect(ImportFileType.sniff(Array("%PDF".utf8)) == nil)
    }

    @Test("Sniffed content wins over the declared type")
    func resolveKind() {
        #expect(ImportFileType.resolveKind(name: "scan", mimeType: "", sniffed: .pdf) == .pdf)
        #expect(ImportFileType.resolveKind(name: "liste.txt", mimeType: "text/plain", sniffed: .image) == .image)
        #expect(ImportFileType.resolveKind(name: "foto.dat", mimeType: "", sniffed: .heic) == .image)
        #expect(ImportFileType.resolveKind(name: "brief.docx", mimeType: "", sniffed: nil) == nil)
        #expect(ImportFileType.resolveKind(name: "liste.txt", mimeType: "", sniffed: nil) == .text)
    }

    @Test("Office documents get a hint, other formats the plain message")
    func unsupportedMessage() {
        #expect(ImportFileType.unsupportedMessage(name: "brief.docx") == ImportMessages.document)
        #expect(ImportFileType.unsupportedMessage(name: "Vokabeln.pages") == ImportMessages.document)
        #expect(ImportFileType.unsupportedMessage(name: "logo.svg") == ImportMessages.unsupported)
        #expect(ImportMessages.document.hasPrefix(ImportMessages.unsupported))
    }

    @Test("The file picker accepts every supported family")
    func supportedContentTypes() {
        let types = ImportFileType.supportedContentTypes
        for type in [UTType.plainText, .commaSeparatedText, .tabSeparatedText, .pdf, .image, .heic] {
            #expect(types.contains(type))
        }
        for ext in [".txt", ".csv", ".tsv", ".pdf", ".heic"] {
            #expect(ImportFileType.acceptedExtensions.contains(String(ext.dropFirst())))
        }
        let jpeg = UTType(filenameExtension: "jpg")!
        #expect(types.contains { jpeg.conforms(to: $0) })
        let markdown = UTType(filenameExtension: "md")!
        #expect(types.contains { markdown.conforms(to: $0) })
    }

    @Test("ImportSource derives name and MIME type from a file URL")
    func sourceFromURL() {
        let source = ImportSource(url: URL(fileURLWithPath: "/tmp/Unité 3.pdf"))
        #expect(source.name == "Unité 3.pdf")
        #expect(source.mimeType == "application/pdf")
        let pasted = ImportSource(data: Data([1, 2]), contentType: .png)
        #expect(pasted.name.isEmpty)
        #expect(pasted.mimeType == "image/png")
    }

    @Test("No message contains the sharp s")
    func swissSpelling() {
        let messages = [
            ImportMessages.unsupported, ImportMessages.document, ImportMessages.empty, ImportMessages.tooLarge,
            ImportMessages.pdfEmpty, ImportMessages.read, ImportMessages.aborted, ImportMessages.imageEmpty,
            ImportMessages.ocrFailed, ImportMessages.decode, ImportMessages.pdfPassword, ImportMessages.pdfInvalid,
            ImportMessages.pdfFailed, ImportMessages.fileFailed, ImportMessages.pdfTooManyPages(31),
            PDFTextExtractor.skippedPagesMessage([2], cause: ImportError(.ocrFailed, "")),
            PDFTextExtractor.skippedPagesMessage(Array(1...9), cause: ImportError(.pdfTooManyPages, "")),
        ]
        for message in messages { #expect(!message.contains("\u{DF}"), "\(message)") }
        #expect(ImportMessages.tooLarge == "Die Textdatei ist zu gross (maximal 5 MB).")
    }
}
