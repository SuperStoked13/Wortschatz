import CoreGraphics
import Foundation
import PDFKit
import WortschatzCore

/// PDF text extraction with PDFKit (port of `extractPdfText` in src/import/pdf.js).
///
/// Text-layer pages are read directly and their layout (table columns, paragraphs) is rebuilt with
/// `TextLayout.itemsToLines`. Scanned pages without a text layer are rendered and passed through
/// text recognition: all pages when the document has no text at all (at most 30), otherwise the
/// nearly empty pages that contain images. Pages are separated by a blank line.
public struct PDFTextExtractor: Sendable {
    /// Text recognition is limited to this many scanned pages.
    public static let maxOCRPages = 30

    /// The extracted text and the German warnings about pages that could not be read.
    public struct Output: Sendable, Equatable {
        public var text: String
        public var warnings: [String]

        public init(text: String, warnings: [String]) {
            self.text = text
            self.warnings = warnings
        }
    }

    public var ocr: OCRService

    public init(ocr: OCRService = OCRService()) {
        self.ocr = ocr
    }

    /// Extracts the text of a PDF. `languages` are the recognition languages for scanned pages
    /// (`RecognitionLanguages.forSet`). Throws `ImportError`: `.pdfInvalid`, `.pdfPassword`,
    /// `.pdfTooManyPages` (a scan with more than 30 pages), `.ocrFailed`, `.aborted`.
    public func extractText(
        from data: Data, languages: [String] = RecognitionLanguages.forSet(termLang: .fr),
        progress: ImportProgressHandler? = nil
    ) async throws(ImportError) -> Output {
        try await extractText(from: data, languages: languages, reporter: ProgressReporter(progress))
    }

    func extractText(from data: Data, languages: [String], reporter report: ProgressReporter) async throws(ImportError) -> Output {
        report(0, ImportMessages.openingPDF)
        try Task.checkImportCancellation()
        guard let document = PDFDocument(data: data) else { throw ImportError(.pdfInvalid, ImportMessages.pdfInvalid) }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw ImportError(.pdfPassword, ImportMessages.pdfPassword)
        }
        return try await extract(document, languages: languages, report: report)
    }

    private func extract(_ document: PDFDocument, languages: [String], report: ProgressReporter) async throws(ImportError) -> Output {
        let n = document.pageCount
        var texts = [String](repeating: "", count: n)
        var chars = [Int](repeating: 0, count: n)
        var textShare = 1.0
        for i in 0..<n {
            try Task.checkImportCancellation()
            report(Double(i) / Double(n) * textShare, n > 1 ? "Seite \(i + 1) von \(n) wird gelesen …" : ImportMessages.readingPDF)
            guard let page = document.page(at: i) else { continue }
            let items = PDFPageText.items(of: page)
            chars[i] = PDFPageText.visibleCharacterCount(items)
            texts[i] = TextLayout.itemsToLines(items).joined(separator: "\n")
            // A first page without text hints at a scan: leave room for the recognition phase.
            if i == 0 && chars[0] < 3 { textShare = 0.1 }
        }

        // Pages to recognise: all of them when the document has no text layer at all, otherwise
        // text-less pages that contain images (scanned inserts).
        let allEmpty = chars.allSatisfy { $0 < 3 }
        var ocrPages: [Int] = []
        for i in 0..<n {
            if allEmpty {
                ocrPages.append(i)
            } else if chars[i] < 40 {
                try Task.checkImportCancellation()
                if let page = document.page(at: i), let pageRef = page.pageRef, PDFImageProbe.pageHasImages(pageRef) {
                    ocrPages.append(i)
                }
            }
        }

        var doneMessage = ImportMessages.pdfRead
        var warnings: [String] = []
        if !ocrPages.isEmpty && allEmpty {
            if ocrPages.count > Self.maxOCRPages {
                throw ImportError(.pdfTooManyPages, ImportMessages.pdfTooManyPages(ocrPages.count))
            }
            var done = Set<Int>()
            try await recognize(
                ocrPages, of: document, into: &texts, done: &done, languages: languages,
                report: report, start: textShare, label: "PDF enthält keinen Text")
        } else if !ocrPages.isEmpty {
            // Mixed document: scanned inserts are a bonus. If their recognition fails (or there are
            // too many), keep the text that was read and tell the learner which pages are missing.
            var done = Set<Int>()
            var failure: ImportError?
            if ocrPages.count > Self.maxOCRPages {
                failure = ImportError(.pdfTooManyPages, ImportMessages.pdfFailed)
            } else {
                do throws(ImportError) {
                    try await recognize(
                        ocrPages, of: document, into: &texts, done: &done, languages: languages,
                        report: report, start: 0.95, label: "Gescannte Seiten")
                } catch {
                    if error.code == .aborted { throw error }
                    failure = error
                }
            }
            if let failure {
                let missing = ocrPages.filter { !done.contains($0) }.map { $0 + 1 }
                if !missing.isEmpty {
                    doneMessage = ImportMessages.pdfReadPartially
                    warnings.append(Self.skippedPagesMessage(missing, cause: failure))
                }
            }
        }

        report(1, doneMessage)
        let text = texts.map(JSCompat.trim).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Output(text: text, warnings: warnings)
    }

    /// Renders the given pages (0-based) and replaces their text with the recognition result.
    /// Recognised pages are added to `done` (also when a later page fails).
    private func recognize(
        _ pages: [Int], of document: PDFDocument, into texts: inout [String], done: inout Set<Int>,
        languages: [String], report: ProgressReporter, start: Double, label: String
    ) async throws(ImportError) {
        let span = 1 - start
        report(start, "\(label) – \(ImportMessages.recognizing)")
        for (k, index) in pages.enumerated() {
            try Task.checkImportCancellation()
            let width = span / Double(pages.count)
            let prefix = pages.count > 1 ? "Seite \(k + 1) von \(pages.count) – " : ""
            let pageReport = report.slice(from: start + span * Double(k) / Double(pages.count), width: width, prefix: prefix)
            guard let page = document.page(at: index), let image = PDFPageRenderer.render(page) else {
                throw ImportError(.ocrFailed, ImportMessages.ocrFailed)
            }
            let text = try await ocr.recognize(image, languages: languages, rescale: false, reporter: pageReport)
            // Keep any real text the page had (e.g. a header) if recognition found nothing.
            if !JSCompat.trim(text).isEmpty { texts[index] = text }
            done.insert(index)
        }
    }

    /// Shown when scanned pages (1-based numbers) of an otherwise readable PDF could not be recognised.
    static func skippedPagesMessage(_ pages: [Int], cause: ImportError) -> String {
        let which: String
        switch pages.count {
        case 1:
            which = "Seite \(pages[0]) ist gescannt und konnte"
        case 2...6:
            let head = pages.dropLast().map(String.init).joined(separator: ", ")
            which = "Die Seiten \(head) und \(pages[pages.count - 1]) sind gescannt und konnten"
        default:
            which = "\(pages.count) Seiten sind gescannt und konnten"
        }
        let reason = cause.code == .pdfTooManyPages
            ? "Die Texterkennung ist auf \(maxOCRPages) Seiten beschränkt – teile die Datei bitte auf."
            : "Versuche es später noch einmal."
        return "\(which) nicht gelesen werden – die Vokabeln darauf fehlen. \(reason)"
    }
}
