import Foundation
import UniformTypeIdentifiers

/// File type detection of src/import/files.js: extension and MIME type (`detectFileKind`) plus
/// content sniffing (`sniff`), so mislabeled files (a PDF without extension) still work.
public enum ImportFileType {
    /// The extensions the file picker offers (JS `ACCEPT`, without the MIME wildcards).
    public static let acceptedExtensions = ["txt", "text", "csv", "tsv", "tab", "md", "pdf", "heic", "heif"]

    /// Content types for `fileImporter` / drop targets: text, CSV/TSV, Markdown, PDF and every image
    /// format ImageIO can decode (HEIC included).
    public static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .commaSeparatedText, .tabSeparatedText, .utf8PlainText, .pdf, .image, .heic, .heif]
        for ext in ["md", "markdown", "tab", "text"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    static let textExtensions: Set<String> = ["txt", "text", "csv", "tsv", "tab", "md", "markdown"]
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp", "heic", "heif", "webp", "gif", "bmp", "avif", "tif", "tiff",
    ]
    static let documentExtensions: Set<String> = [
        "doc", "docx", "odt", "pages", "rtf", "xls", "xlsx", "numbers", "key", "ppt", "pptx",
    ]
    static let textTypes: Set<String> = ["application/csv", "application/x-csv", "application/tab-separated-values"]
    static let nonTextTextTypes: Set<String> = ["text/html", "text/rtf", "text/xml", "text/javascript", "text/css"]

    /// What the content sniffing found (JS `sniff`): `.heic` is reported separately from other images.
    public enum Sniffed: String, Sendable, Hashable {
        case pdf, image, heic
    }

    /// `.text`, `.pdf`, `.image` or nil (unsupported), from the MIME type and the file name (JS
    /// `detectFileKind`).
    public static func detectKind(name: String, mimeType: String) -> ImportFileKind? {
        let ext = extensionOf(name)
        let type = normalizedMIME(mimeType)
        if type == "application/pdf" || ext == "pdf" { return .pdf }
        if documentExtensions.contains(ext) { return nil }
        if textExtensions.contains(ext) { return .text }
        if type == "image/svg+xml" || ext == "svg" { return nil }
        if imageExtensions.contains(ext) || type.hasPrefix("image/") { return .image }
        if nonTextTextTypes.contains(type) { return nil }
        if type.hasPrefix("text/") || textTypes.contains(type) { return .text }
        if ext.isEmpty && type.isEmpty { return .text }
        return nil
    }

    /// The kind decided from the first bytes (JS `sniff`), nil when the bytes are not recognised.
    public static func sniff(_ bytes: some Collection<UInt8>) -> Sniffed? {
        let b = Array(bytes.prefix(16))
        func ascii(_ from: Int, _ to: Int) -> String {
            String(decoding: b[from..<to], as: Unicode.ASCII.self)
        }
        if b.count >= 5 && ascii(0, 5) == "%PDF-" { return .pdf }
        if b.count >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return .image }
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return .image }
        if b.count >= 4 && ascii(0, 4) == "GIF8" { return .image }
        if b.count >= 12 && ascii(0, 4) == "RIFF" && ascii(8, 12) == "WEBP" { return .image }
        if b.count >= 12 && ascii(4, 8) == "ftyp" {
            let brand = ascii(8, 12)
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
            if brand == "avif" || brand == "avis" { return .image }
        }
        return nil
    }

    /// The kind used for the import (JS `readImportFile`): sniffed content wins over the name.
    public static func resolveKind(name: String, mimeType: String, sniffed: Sniffed?) -> ImportFileKind? {
        switch sniffed {
        case .pdf: .pdf
        case .image, .heic: .image
        case nil: detectKind(name: name, mimeType: mimeType)
        }
    }

    /// The message for an unsupported file: office documents get a hint to paste the text or save
    /// as PDF.
    public static func unsupportedMessage(name: String) -> String {
        documentExtensions.contains(extensionOf(name)) ? ImportMessages.document : ImportMessages.unsupported
    }

    /// Lower-cased extension after the last dot; "" for none, a leading dot (".bashrc") or a
    /// trailing dot (JS `extensionOf`).
    static func extensionOf(_ name: String) -> String {
        let n = Array(name.lowercased().utf16)
        guard let dot = n.lastIndex(of: 0x2E), dot > 0, dot < n.count - 1 else { return "" }
        return String(decoding: n[(dot + 1)...], as: UTF16.self)
    }

    /// `type.toLowerCase().split(';')[0].trim()`
    static func normalizedMIME(_ type: String) -> String {
        let main = type.lowercased().split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return main.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
