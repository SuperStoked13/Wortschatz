import Foundation
import WortschatzCore

/// Turns dropped, picked or pasted files into text for the vocabulary parser (port of
/// `readImportFile` in src/import/files.js and the file loop of the web editor's import panel):
/// text files are decoded, PDFs go through PDFKit, photos and screenshots through Vision.
public struct ImportPipeline: Sendable {
    /// Text files above this size are refused.
    public static let maxTextBytes = 5 * 1024 * 1024

    public var ocr: OCRService

    public init(ocr: OCRService = OCRService()) {
        self.ocr = ocr
    }

    /// Reads one file. Text recognition uses the set's languages (`RecognitionLanguages.forSet`).
    /// Throws `ImportError` with a German message: `.unsupported`, `.empty`, `.tooLarge`, `.read`,
    /// `.noText`, `.decode`, `.ocrFailed`, `.pdf…`, or `.aborted` when the task is cancelled.
    public func read(
        _ source: ImportSource, termLang: Lang? = .fr, defLang: Lang? = .de, progress: ImportProgressHandler? = nil
    ) async throws(ImportError) -> ImportedFile {
        try await read(source, languages: RecognitionLanguages.forSet(termLang: termLang, defLang: defLang),
                       reporter: ProgressReporter(progress))
    }

    /// Reads several files one after another (the editor's drop and file picker). Texts are
    /// collected in order, failures and warnings get the file name as a «name»: prefix (none for
    /// pasted content). Only cancellation stops the batch: it throws `ImportError.aborted`.
    public func readAll(
        _ sources: [ImportSource], termLang: Lang? = .fr, defLang: Lang? = .de, progress: ImportProgressHandler? = nil
    ) async throws(ImportError) -> ImportBatch {
        let languages = RecognitionLanguages.forSet(termLang: termLang, defLang: defLang)
        let report = ProgressReporter(progress)
        let count = Double(sources.count)
        var batch = ImportBatch()
        for (i, source) in sources.enumerated() {
            try Task.checkImportCancellation()
            let prefix = sources.count > 1 ? "Datei \(i + 1) von \(sources.count): " : ""
            let label = source.name.isEmpty ? "" : "«\(source.name)»: "
            let fileReport = report.slice(from: Double(i) / count, width: 1 / count, prefix: prefix)
            do throws(ImportError) {
                let file = try await read(source, languages: languages, reporter: fileReport)
                batch.files.append(file)
                let text = JSCompat.trim(file.text)
                if !text.isEmpty {
                    batch.texts.append(text)
                    if batch.firstName == nil, !file.name.isEmpty { batch.firstName = file.name }
                }
                batch.warnings += file.warnings.map { label + $0 }
            } catch {
                if error.code == .aborted { throw error }
                batch.failures.append(ImportFailure(name: source.name, error: error, message: label + error.message))
            }
        }
        return batch
    }

    // MARK: - One file

    func read(_ source: ImportSource, languages: [String], reporter report: ProgressReporter) async throws(ImportError) -> ImportedFile {
        try Task.checkImportCancellation()
        let file = try SourceBytes(source)
        defer { file.close() }
        if file.size == 0 { throw ImportError(.empty, ImportMessages.empty) }

        let sniffed = ImportFileType.sniff(file.head)
        guard let kind = ImportFileType.resolveKind(name: source.name, mimeType: source.mimeType, sniffed: sniffed) else {
            throw ImportError(.unsupported, ImportFileType.unsupportedMessage(name: source.name))
        }

        switch kind {
        case .text:
            if file.size > Self.maxTextBytes { throw ImportError(.tooLarge, ImportMessages.tooLarge) }
            report(0, ImportMessages.readingFile)
            let data = try file.contents()
            try Task.checkImportCancellation()
            var text = TextFileDecoder.decode(data)
            if text.unicodeScalars.first == "\u{FEFF}" { text = String(text.unicodeScalars.dropFirst()) }
            if TextFileDecoder.looksBinary(text) { throw ImportError(.unsupported, ImportMessages.unsupported) }
            report(1, ImportMessages.fileRead)
            return ImportedFile(text: text, kind: .text, name: source.name)

        case .pdf:
            let data = try file.contents()
            let output = try await PDFTextExtractor(ocr: ocr).extractText(from: data, languages: languages, reporter: report)
            if JSCompat.trim(output.text).isEmpty { throw ImportError(.noText, ImportMessages.pdfEmpty) }
            return ImportedFile(text: output.text, kind: .pdf, name: source.name, warnings: output.warnings)

        case .image:
            let data = try file.contents()
            let text = try await ocr.recognizeImage(data, languages: languages, reporter: report)
            if JSCompat.trim(text).isEmpty { throw ImportError(.noText, ImportMessages.imageEmpty) }
            return ImportedFile(text: text, kind: .image, name: source.name)
        }
    }
}

/// The result of importing several files.
public struct ImportBatch: Sendable, Equatable {
    /// Every file that was read, in order.
    public var files: [ImportedFile] = []
    /// The trimmed, non-empty texts of `files`.
    public var texts: [String] = []
    /// Files that could not be read.
    public var failures: [ImportFailure] = []
    /// Problems that did not stop an import (e.g. scanned PDF pages), with a «name»: prefix.
    public var warnings: [String] = []
    /// The name of the first file that gave text (a set title suggestion); nil for pasted content.
    public var firstName: String?

    public init() {}

    /// All texts, separated by blank lines.
    public var text: String { texts.joined(separator: "\n\n") }

    /// The failure messages («name»: message), e.g. for error toasts.
    public var errorMessages: [String] { failures.map(\.message) }

    /// The import text after this batch: the existing text (trimmed) first, then the new texts,
    /// separated by blank lines.
    public func appended(to existing: String) -> String {
        let current = JSCompat.trim(existing)
        return ((current.isEmpty ? [] : [current]) + texts).joined(separator: "\n\n")
    }
}

/// A file of a batch that could not be read.
public struct ImportFailure: Sendable, Equatable {
    /// The file name ("" for pasted content).
    public var name: String
    public var error: ImportError
    /// The message for the learner, with a «name»: prefix when the file has a name.
    public var message: String

    public init(name: String, error: ImportError, message: String) {
        self.name = name
        self.error = error
        self.message = message
    }
}

/// Access to the bytes of an import source: size and the first bytes without reading the whole
/// file, security-scoped access for sandboxed file URLs.
private struct SourceBytes {
    let size: Int
    let head: [UInt8]
    private let load: () throws(ImportError) -> Data
    private let release: () -> Void

    init(_ source: ImportSource) throws(ImportError) {
        switch source.payload {
        case let .data(data):
            size = data.count
            head = Array(data.prefix(16))
            load = { () throws(ImportError) -> Data in data }
            release = {}
        case let .file(url):
            let scoped = url.startAccessingSecurityScopedResource()
            release = { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                // A dropped folder cannot be imported.
                if values.isDirectory == true { throw ImportError(.read, ImportMessages.read) }
                size = values.fileSize ?? 0
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                head = Array(try handle.read(upToCount: 16) ?? Data())
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw ImportError.wrap(error, fallback: ImportError(.read, ImportMessages.read))
            }
            load = { () throws(ImportError) -> Data in
                do {
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                } catch {
                    throw ImportError(.read, ImportMessages.read)
                }
            }
        }
    }

    func contents() throws(ImportError) -> Data { try load() }

    func close() { release() }
}
