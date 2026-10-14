import CoreGraphics
import Foundation
import PDFKit
import WortschatzCore

/// Text layer of one PDF page as layout items (the PDFKit counterpart of `toLayoutItems` in
/// src/import/pdf.js): one item per word, in display space with a top-left origin (page rotation
/// and crop box applied), x = left edge, y = bottom of the glyph box, h = line height.
enum PDFPageText {
    /// Text lines rotated by more than this (radians) are skipped: margin notes, stamps.
    static let maxAngle = 0.2

    static func items(of page: PDFPage) -> [TextItem] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        let geometry = DisplayGeometry(page)
        var items: [TextItem] = []
        var lineStart = 0
        while lineStart < text.length {
            var lineEnd = lineStart
            while lineEnd < text.length, !isLineBreak(text.character(at: lineEnd)) { lineEnd += 1 }
            appendItems(ofLine: lineStart..<lineEnd, text: text, page: page, geometry: geometry, to: &items)
            lineStart = lineEnd + 1
        }
        return items
    }

    /// Non-whitespace UTF-16 units of the items (JS `visibleChars`).
    static func visibleCharacterCount(_ items: [TextItem]) -> Int {
        items.reduce(0) { count, item in
            count + item.str.unicodeScalars.reduce(0) { $0 + (JSCompat.isWhitespace($1) ? 0 : $1.utf16.count) }
        }
    }

    // MARK: - Lines and words

    private static func appendItems(
        ofLine line: Range<Int>, text: NSString, page: PDFPage, geometry: DisplayGeometry, to items: inout [TextItem]
    ) {
        var words: [Range<Int>] = []
        var i = line.lowerBound
        while i < line.upperBound {
            if isSpace(text.character(at: i)) {
                i += 1
                continue
            }
            let start = i
            while i < line.upperBound, !isSpace(text.character(at: i)) { i += 1 }
            words.append(start..<i)
        }
        guard let first = words.first, let last = words.last else { return }

        // Rotated text keeps its own lines in PDFKit; their characters march along the rotation.
        let firstChar = first.lowerBound
        let lastChar = last.upperBound - 1
        if lastChar > firstChar,
           let a = geometry.rect(of: NSRange(location: firstChar, length: 1), on: page),
           let b = geometry.rect(of: NSRange(location: lastChar, length: 1), on: page) {
            let dx = b.midX - a.midX
            let dy = b.midY - a.midY
            if (dx * dx + dy * dy).squareRoot() > 1, abs(atan2(dy, dx)) > maxAngle { return }
        }

        for word in words {
            guard let rect = geometry.rect(of: NSRange(location: word.lowerBound, length: word.count), on: page),
                  rect.width > 0, rect.height > 0
            else { continue }
            let str = expandingLigatures(text.substring(with: NSRange(location: word.lowerBound, length: word.count)))
            let length = Double(str.utf16.count)
            // A trailing space (with its width) marks the word boundary, like a space inside a pdf.js run.
            let spaced = word.upperBound < line.upperBound
            items.append(
                TextItem(
                    str: spaced ? str + " " : str, x: rect.minX, y: rect.maxY,
                    w: spaced ? rect.width * (length + 1) / length : rect.width, h: rect.height))
        }
    }

    /// Typographic ligatures (U+FB00…U+FB06) as plain letters, so "ﬁn" grades like "fin".
    static func expandingLigatures(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { ligatures[$0.value] != nil }) else { return s }
        var out = ""
        for scalar in s.unicodeScalars {
            if let plain = ligatures[scalar.value] { out += plain } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    private static let ligatures: [UInt32: String] = [
        0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
    ]

    private static func isLineBreak(_ u: unichar) -> Bool {
        u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029
    }

    /// JS `\s` on one UTF-16 unit (surrogates are never whitespace).
    private static func isSpace(_ u: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return JSCompat.isWhitespace(scalar)
    }
}

/// Maps PDFKit page space to the displayed page (rotation and crop box applied, top-left origin).
struct DisplayGeometry {
    let transform: CGAffineTransform
    let size: CGSize

    init(_ page: PDFPage) {
        transform = page.transform(for: .cropBox)
        let box = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// The display rectangle of a character range, nil when PDFKit has no geometry for it.
    func rect(of range: NSRange, on page: PDFPage) -> CGRect? {
        guard let selection = page.selection(for: range) else { return nil }
        let bounds = selection.bounds(for: page)
        guard !bounds.isNull, !bounds.isInfinite, bounds.minX.isFinite, bounds.minY.isFinite else { return nil }
        let display = bounds.applying(transform)
        return CGRect(x: display.minX, y: size.height - display.maxY, width: display.width, height: display.height)
    }
}

/// Whether a page paints images (the CoreGraphics counterpart of pdf.js `getOperatorList` checks):
/// image XObjects, also inside form XObjects, and inline images. Errors count as "has images".
enum PDFImageProbe {
    static func pageHasImages(_ page: CGPDFPage) -> Bool {
        let probe = Probe()
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        probe.scan(stream)
        return probe.found
    }

    /// Scanner state; the C callbacks reach it through the scanner's info pointer.
    private final class Probe {
        var found = false
        var depth = 0
        let table: CGPDFOperatorTableRef?

        init() {
            table = CGPDFOperatorTableCreate()
            guard let table else {
                found = true
                return
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let info else { return }
                Unmanaged<Probe>.fromOpaque(info).takeUnretainedValue().paintXObject(scanner)
            }
            for op in ["BI", "ID", "EI"] {
                CGPDFOperatorTableSetCallback(table, op) { _, info in
                    guard let info else { return }
                    Unmanaged<Probe>.fromOpaque(info).takeUnretainedValue().found = true
                }
            }
        }

        deinit {
            if let table { CGPDFOperatorTableRelease(table) }
        }

        func scan(_ stream: CGPDFContentStreamRef) {
            guard let table, !found else { return }
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            if !CGPDFScannerScan(scanner) { found = true }
            CGPDFScannerRelease(scanner)
        }

        private func paintXObject(_ scanner: CGPDFScannerRef) {
            var namePointer: UnsafePointer<CChar>?
            guard !found, CGPDFScannerPopName(scanner, &namePointer), let namePointer else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", namePointer) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream)
            else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                found = true
            case "Form" where depth < 8:
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let nested = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
                depth += 1
                scan(nested)
                depth -= 1
                CGPDFContentStreamRelease(nested)
            default:
                break
            }
        }
    }
}

/// Renders scanned pages for text recognition (port of `renderPage` in src/import/pdf.js).
enum PDFPageRenderer {
    /// Target width in pixels; pages are rendered at scale 2…4 and at most 3000 px on the long side.
    static let targetWidth = 2000.0
    static let maxSide = 3000.0

    static func scale(for size: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        let scale = min(4, max(2, targetWidth / size.width))
        return min(scale, maxSide / max(size.width, size.height))
    }

    /// The page as an opaque image (white background, rotation and crop box applied).
    static func render(_ page: PDFPage) -> CGImage? {
        let geometry = DisplayGeometry(page)
        let scale = scale(for: geometry.size)
        let width = max(1, Int((geometry.size.width * scale).rounded(.down)))
        let height = max(1, Int((geometry.size.height * scale).rounded(.down)))
        guard let context = OCRImage.whiteContext(width: width, height: height), let pageRef = page.pageRef else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(geometry.transform)
        context.drawPDFPage(pageRef)
        return context.makeImage()
    }
}
