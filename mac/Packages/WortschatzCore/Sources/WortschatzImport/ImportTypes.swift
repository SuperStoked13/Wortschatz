import Foundation
import UniformTypeIdentifiers
import WortschatzCore

// Shared types of the native importers (port of the contracts of src/import/files.js, pdf.js and
// ocr.js). All user-facing text is German with Swiss spelling, in the app's language through `L`.

/// What an imported file contained (JS `kind`).
public enum ImportFileKind: String, Sendable, Codable, Hashable, CaseIterable {
    case text, pdf, image
}

/// A file (or pasted data) to import.
public struct ImportSource: Sendable, Hashable {
    public enum Payload: Sendable, Hashable {
        /// A file on disk (dropped, picked with the file importer, or copied in the Finder).
        case file(URL)
        /// Bytes in memory, e.g. an image from the pasteboard.
        case data(Data)
    }

    public var payload: Payload
    /// The file name shown in messages and used as a set title; "" for pasted content.
    public var name: String
    /// The MIME type ("image/png"), "" when unknown. Like a browser's `File.type`, it is only a hint:
    /// the content is sniffed as well.
    public var mimeType: String

    public init(payload: Payload, name: String, mimeType: String = "") {
        self.payload = payload
        self.name = name
        self.mimeType = mimeType
    }

    /// A file on disk; the name is its last path component, the MIME type comes from its extension.
    public init(url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        self.init(payload: .file(url), name: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "")
    }

    /// Bytes in memory. Pasted content has no name.
    public init(data: Data, name: String = "", contentType: UTType? = nil) {
        self.init(payload: .data(data), name: name, mimeType: contentType?.preferredMIMEType ?? "")
    }
}

/// The text read from one file (JS `{ text, kind, name, warnings }`).
public struct ImportedFile: Sendable, Equatable, Hashable {
    public var text: String
    public var kind: ImportFileKind
    public var name: String
    /// Messages about content that could not be read although the import worked (e.g.
    /// scanned pages of a text PDF); empty when everything was read.
    public var warnings: [String]

    public init(text: String, kind: ImportFileKind, name: String, warnings: [String] = []) {
        self.text = text
        self.kind = kind
        self.name = name
        self.warnings = warnings
    }
}

/// Progress of a running import: a fraction 0…1 and a status line (in the app's language).
public struct ImportProgress: Sendable, Equatable, Hashable {
    public var fraction: Double
    public var message: String

    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

/// Receives progress updates. It is called from background threads; a UI hops to the main actor.
public typealias ImportProgressHandler = @Sendable (ImportProgress) -> Void

/// An import failure with a user-presentable message (JS errors with `err.code`; German source).
public struct ImportError: Error, LocalizedError, Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable, Hashable {
        /// Not a text file, PDF or image (also binary data in a "text" file).
        case unsupported
        /// The file has no bytes.
        case empty
        /// A text file above 5 MB.
        case tooLarge
        /// The file could not be read (missing, a folder, no permission).
        case read
        /// The import was cancelled.
        case aborted
        /// The PDF or image contained no readable text.
        case noText
        /// The image could not be decoded.
        case decode
        /// Text recognition failed.
        case ocrFailed
        /// The PDF is password protected.
        case pdfPassword
        /// The PDF is damaged or not a PDF.
        case pdfInvalid
        /// Any other PDF failure.
        case pdfFailed
        /// More scanned pages than text recognition handles.
        case pdfTooManyPages
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { "\(code.rawValue): \(message)" }

    /// `Import abgebrochen.`
    public static var aborted: ImportError { ImportError(.aborted, ImportMessages.aborted) }

    /// Maps any error of an import step: cancellation becomes `.aborted`, an `ImportError` stays,
    /// anything else becomes `fallback`.
    static func wrap(_ error: any Error, fallback: ImportError) -> ImportError {
        if let error = error as? ImportError { return error }
        if error is CancellationError || Task.isCancelled { return .aborted }
        return fallback
    }
}

/// The messages of the web importers (German source with Swiss spelling, translated with `L`).
public enum ImportMessages {
    public static var unsupported: String { L("Dieses Dateiformat wird nicht unterstützt.") }
    public static var document: String {
        L(
            "Dieses Dateiformat wird nicht unterstützt. Kopiere den Text aus dem Dokument und füge ihn ins Textfeld ein – oder speichere es als PDF.")
    }
    public static var empty: String { L("Die Datei ist leer.") }
    public static var tooLarge: String { L("Die Textdatei ist zu gross (maximal 5 MB).") }
    public static var pdfEmpty: String { L("In der PDF-Datei wurde kein Text gefunden.") }
    public static var read: String {
        L("Die Datei konnte nicht gelesen werden. Ist sie noch vorhanden und vollständig heruntergeladen?")
    }
    public static var aborted: String { L("Import abgebrochen.") }
    public static var imageEmpty: String {
        L(
            "Auf dem Bild wurde kein Text erkannt. Achte auf gutes Licht und eine scharfe Aufnahme und fotografiere die Seite möglichst gerade.")
    }
    public static var ocrFailed: String {
        L("Die Texterkennung ist fehlgeschlagen. Versuche es mit einem schärferen Foto oder einem Screenshot.")
    }
    public static var decode: String { L("Das Bild konnte nicht geöffnet werden.") }
    public static var pdfPassword: String {
        L("Diese PDF-Datei ist passwortgeschützt. Entferne den Schutz oder kopiere den Text direkt aus der PDF.")
    }
    public static var pdfInvalid: String { L("Die PDF-Datei ist beschädigt oder keine gültige PDF.") }
    public static var pdfFailed: String { L("Die PDF-Datei konnte nicht gelesen werden.") }
    /// Fallback for a failed file in a batch (editor-import.js).
    public static var fileFailed: String { L("Die Datei konnte nicht gelesen werden.") }

    static func pdfTooManyPages(_ count: Int) -> String {
        L(
            "Diese PDF-Datei enthält %@ gescannte Seiten. Die Texterkennung ist auf %@ Seiten beschränkt – teile die Datei bitte auf.",
            "\(count)", "\(PDFTextExtractor.maxOCRPages)")
    }

    // Progress lines.
    static var readingFile: String { L("Datei wird gelesen …") }
    static var fileRead: String { L("Datei gelesen") }
    static var preparingImage: String { L("Bild wird vorbereitet …") }
    static var recognizing: String { L("Texterkennung läuft …") }
    static var recognized: String { L("Text erkannt") }
    static var openingPDF: String { L("PDF wird geöffnet …") }
    static var readingPDF: String { L("PDF wird gelesen …") }
    static var pdfRead: String { L("PDF gelesen") }
    static var pdfReadPartially: String { L("PDF gelesen – gescannte Seiten konnten nicht erkannt werden.") }
}

// MARK: - Progress

/// Clamps and forwards progress like the web `reporter()`: fractions are kept within 0…1 and a
/// sub-reporter maps its own 0…1 onto a slice of its parent.
struct ProgressReporter: Sendable {
    private let handler: ImportProgressHandler?
    private let start: Double
    private let span: Double
    private let prefix: String

    init(_ handler: ImportProgressHandler?) {
        self.init(handler: handler, start: 0, span: 1, prefix: "")
    }

    private init(handler: ImportProgressHandler?, start: Double, span: Double, prefix: String) {
        self.handler = handler
        self.start = start
        self.span = span
        self.prefix = prefix
    }

    func callAsFunction(_ fraction: Double, _ message: String) {
        guard let handler else { return }
        let value = start + span * Self.clamp(fraction)
        handler(ImportProgress(fraction: Self.clamp(value), message: prefix + message))
    }

    /// A reporter whose 0…1 covers `from…from + width` of this one, with `prefix` before every message.
    func slice(from: Double, width: Double, prefix: String = "") -> ProgressReporter {
        ProgressReporter(
            handler: handler, start: start + span * Self.clamp(from), span: span * max(0, width),
            prefix: self.prefix + prefix)
    }

    private static func clamp(_ x: Double) -> Double {
        x.isNaN ? 0 : min(1, max(0, x))
    }
}

extension Task where Success == Never, Failure == Never {
    /// Throws `ImportError.aborted` when the current task is cancelled.
    static func checkImportCancellation() throws(ImportError) {
        if Task.isCancelled { throw ImportError.aborted }
    }
}
