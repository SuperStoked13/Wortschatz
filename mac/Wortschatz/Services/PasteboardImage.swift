import AppKit
import Foundation
import UniformTypeIdentifiers
import WortschatzImport

/// Import sources from the pasteboard ("Bild aus Zwischenablage", ⌘V in the editor) and from
/// drag and drop: files copied in the Finder, or image data copied from a screenshot, Preview or
/// a browser.
enum PasteboardImage {
    /// Image types read from the pasteboard, best first (TIFF is what most apps put there).
    static let imageTypes: [UTType] = [.png, .heic, .jpeg, .tiff, .gif, .webP, .bmp]

    /// Content types the editor accepts for ⌘V (`onPasteCommand`) and drops (`onDrop`).
    static let acceptedTypes: [UTType] = [.fileURL] + imageTypes

    /// Whether the pasteboard holds something for the importer: files or an image.
    static func hasImportableContent(_ pasteboard: NSPasteboard = .general) -> Bool {
        !fileURLs(on: pasteboard).isEmpty || pasteboard.availableType(from: imageTypes.map(pasteboardType)) != nil
    }

    /// Whether the pasteboard holds an image (for enabling "Bild aus Zwischenablage").
    static func hasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: imageTypes.map(pasteboardType)) != nil
    }

    /// The import sources on the pasteboard: copied files (in order), else the image in its best
    /// type. Empty when there is nothing to import.
    static func importSources(from pasteboard: NSPasteboard = .general) -> [ImportSource] {
        let files = fileURLs(on: pasteboard)
        if !files.isEmpty { return files.map(ImportSource.init(url:)) }
        return image(from: pasteboard).map { [$0] } ?? []
    }

    /// The image on the pasteboard as a nameless source (pasted content has no file name).
    static func image(from pasteboard: NSPasteboard = .general) -> ImportSource? {
        for type in imageTypes {
            if let data = pasteboard.data(forType: pasteboardType(type)), !data.isEmpty {
                return ImportSource(data: data, contentType: type)
            }
        }
        return nil
    }

    /// Import sources from dropped or pasted item providers (`onDrop`, `onPasteCommand`): file
    /// URLs as files, other items as image data. Items that cannot be loaded are skipped.
    static func importSources(from providers: [NSItemProvider]) async -> [ImportSource] {
        var sources: [ImportSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(from: provider) {
                sources.append(ImportSource(url: url))
            } else if let type = imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
                      let data = await data(from: provider, type: type) {
                sources.append(ImportSource(data: data, name: provider.suggestedName.map { "\($0).\(type.preferredFilenameExtension ?? "png")" } ?? "", contentType: type))
            }
        }
        return sources
    }

    // MARK: - Helpers

    private static func pasteboardType(_ type: UTType) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(type.identifier)
    }

    /// File URLs on the pasteboard. Unsupported files are kept: the importer explains why they
    /// cannot be read (e.g. "speichere es als PDF" for a Word document).
    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
