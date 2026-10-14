import CoreGraphics
import Foundation
import WortschatzCore

/// Text recognition for photos, screenshots and scanned PDF pages (port of `recognizeImage` /
/// `ocrDataToText` in src/import/ocr.js on top of Vision).
///
/// Word boxes become `TextItem`s, the page is straightened (`TextLayout.deskewItems`), rows and table
/// columns are rebuilt (`TextLayout.itemsToLines`, columns separated by tabs) and umlauts misread
/// as circumflexes are restored (`OCRPostprocess.fixGermanUmlauts`).
public struct OCRService: Sendable {
    public var recognizer: any TextRecognizing

    /// `recognizer` nil uses the system's Vision engine.
    public init(recognizer: (any TextRecognizing)? = nil) {
        self.recognizer = recognizer ?? SystemTextRecognizer.make()
    }

    /// Recognises the text on an image file's bytes (any format ImageIO decodes, HEIC included).
    /// Returns plain text lines (table columns separated by tabs), "" when nothing was found.
    /// Throws `ImportError` (`.decode`, `.ocrFailed`, `.aborted`).
    public func recognizeImage(
        _ data: Data, languages: [String], progress: ImportProgressHandler? = nil
    ) async throws(ImportError) -> String {
        try await recognizeImage(data, languages: languages, reporter: ProgressReporter(progress))
    }

    /// Recognises the text on a decoded image. `rescale` applies `OCRImage.scale(width:height:)`
    /// (upscaling small images); rendered PDF pages are passed at their size.
    public func recognize(
        _ image: CGImage, languages: [String], rescale: Bool = true, progress: ImportProgressHandler? = nil
    ) async throws(ImportError) -> String {
        try await recognize(image, languages: languages, rescale: rescale, reporter: ProgressReporter(progress))
    }

    func recognizeImage(_ data: Data, languages: [String], reporter: ProgressReporter) async throws(ImportError) -> String {
        try Task.checkImportCancellation()
        reporter(0, ImportMessages.preparingImage)
        // Decode first, so that unreadable files fail before any recognition work.
        let image = try OCRImage.prepareForRecognition(data)
        try Task.checkImportCancellation()
        return try await recognize(image, languages: languages, rescale: false, reporter: reporter.slice(from: 0.1, width: 0.9))
    }

    func recognize(
        _ image: CGImage, languages: [String], rescale: Bool, reporter: ProgressReporter
    ) async throws(ImportError) -> String {
        try Task.checkImportCancellation()
        reporter(0, ImportMessages.recognizing)
        let prepared = rescale ? try OCRImage.prepareForRecognition(image) : image
        let lines: [OCRLine]
        do {
            lines = try await recognizer.recognizeText(in: prepared, languages: languages) { fraction in
                reporter(0.05 + 0.9 * fraction, ImportMessages.recognizing)
            }
        } catch {
            throw ImportError.wrap(error, fallback: ImportError(.ocrFailed, ImportMessages.ocrFailed))
        }
        try Task.checkImportCancellation()
        reporter(1, ImportMessages.recognized)
        return OCRTextAssembler.lines(from: lines).joined(separator: "\n")
    }
}

/// The recognition languages for a set (port of `ocrLangsFor`, with Vision's language tags).
public enum RecognitionLanguages {
    /// The learned language first, then the translation language: French + German by default,
    /// English for "other", German alone for German. The translation language defaults to German.
    public static func forSet(termLang: Lang?, defLang: Lang? = .de) -> [String] {
        let term = termLang.map { tag($0) ?? "en-US" } ?? "fr-FR"
        let definition = defLang.flatMap(tag) ?? "de-DE"
        return term == definition ? [term] : [term, definition]
    }

    /// Vision's tag for a set language; nil for `.other`.
    public static func tag(_ lang: Lang) -> String? {
        switch lang {
        case .fr: "fr-FR"
        case .de: "de-DE"
        case .en: "en-US"
        case .es: "es-ES"
        case .it: "it-IT"
        case .other: nil
        }
    }
}

/// Recognised lines → text lines (port of `ocrDataToText` for Vision results).
public enum OCRTextAssembler {
    /// Rebuilds rows and table columns from the word boxes: noise words (table rules, box drawing)
    /// are dropped, border bars glued to words are stripped, the page is straightened using the
    /// median baseline slope, and German umlauts misread as circumflexes are restored. Falls back to
    /// the plain line texts when no word box is usable.
    public static func lines(from recognized: [OCRLine]) -> [String] {
        var items: [TextItem] = []
        for line in recognized {
            for word in line.words {
                if let item = item(for: word) { items.append(item) }
            }
        }
        if items.isEmpty {
            let plain = JSCompat.trim(recognized.map(\.text).joined(separator: "\n"))
            return plain.isEmpty ? [] : OCRPostprocess.fixGermanUmlauts(plain.components(separatedBy: "\n"))
        }
        let slope = estimateSkew(recognized)
        return OCRPostprocess.fixGermanUmlauts(TextLayout.itemsToLines(TextLayout.deskewItems(items, slope: slope)))
    }

    /// The slope (dy/dx, top-left origin) of the text rows.
    ///
    /// The web version reads it from tesseract's baselines (`estimateSlope` of the line baselines,
    /// else of the word baselines). Vision's boxes follow small rotations only roughly (a 2° photo
    /// often gives level boxes), so that median is only the starting point: it is refined by
    /// aligning separate pieces of text that sit side by side, such as the term and the definition
    /// cell of a table row, which share their row whatever the rotation.
    static func estimateSkew(_ recognized: [OCRLine]) -> Double {
        var prior = TextLayout.estimateSlope(recognized.map { baseline($0.quad) }, minWidth: 120)
        if prior == 0 {
            prior = TextLayout.estimateSlope(recognized.flatMap { $0.words.map { baseline($0.quad) } }, minWidth: 80)
        }
        return refineSkew(prior, anchors: recognized.compactMap(Anchor.init))
    }

    /// The left end of a recognised line: the middle of its left edge, its right end and height.
    struct Anchor {
        let x: Double
        let y: Double
        let right: Double
        let height: Double

        init?(_ line: OCRLine) {
            let q = line.quad
            guard q.isFinite else { return nil }
            x = Double(q.topLeft.x + q.bottomLeft.x) / 2
            y = Double(q.topLeft.y + q.bottomLeft.y) / 2
            right = Double(max(q.topRight.x, q.bottomRight.x))
            let hx = Double(q.topLeft.x - q.bottomLeft.x)
            let hy = Double(q.topLeft.y - q.bottomLeft.y)
            height = (hx * hx + hy * hy).squareRoot()
            guard height > 0, right > x else { return nil }
        }
    }

    /// Searches the slope within ±0.12 of `prior` that puts the most pairs of side-by-side pieces on
    /// one row (Gaussian kernel of a quarter line height, with a gentle preference for `prior`).
    /// A slope that pairs every term with the definition one row below can score almost as well as
    /// the true one; among such near-equal candidates the one whose columns are straight wins:
    /// pieces stacked in a left-aligned column move sideways by `-slope` per pixel downwards.
    /// Returns `prior` when no two pieces sit side by side.
    static func refineSkew(_ prior: Double, anchors: [Anchor]) -> Double {
        let window = 0.12
        let reach = abs(prior) + window
        var rows: [(dx: Double, dy: Double, sigma: Double)] = []
        var columns: [(dx: Double, dy: Double, sigma: Double)] = []
        for (i, a) in anchors.enumerated() {
            for b in anchors[(i + 1)...] {
                let sigma = 0.25 * (a.height + b.height) / 2
                let height = max(a.height, b.height)
                let (left, right) = a.x <= b.x ? (a, b) : (b, a)
                let dx = right.x - left.x
                let dy = right.y - left.y
                if dx >= 2 * height, left.right <= right.x, abs(dy) <= reach * dx + height {
                    // Side by side (different columns): candidates for one row.
                    rows.append((dx, dy, sigma))
                } else if abs(dy) >= 1.5 * height, abs(dx) <= reach * abs(dy) + height {
                    // Stacked: candidates for one left-aligned column.
                    columns.append((dx, dy, sigma))
                }
            }
        }
        guard !rows.isEmpty else { return prior }

        func kernelSum(_ pairs: [(dx: Double, dy: Double, sigma: Double)], _ residual: (Double, Double, Double) -> Double) -> Double {
            var sum = 0.0
            for pair in pairs {
                let u = residual(pair.dx, pair.dy, pair.sigma)
                if abs(u) < 4 { sum += exp(-0.5 * u * u) }
            }
            return sum
        }

        let step = 0.001
        let slopes = (0...Int((2 * window / step).rounded())).map { prior - window + Double($0) * step }.filter { abs($0) <= 0.35 }
        let scores = slopes.map { slope in
            let distance = (slope - prior) / 0.06
            return kernelSum(rows) { dx, dy, sigma in (dy - slope * dx) / sigma } * exp(-0.5 * distance * distance)
        }
        guard let best = scores.max(), best >= 0.5 else { return prior }

        // Near-equal local maxima of the row score.
        var candidates: [Double] = []
        for (k, score) in scores.enumerated() where score >= 0.6 * best {
            let previous = k > 0 ? scores[k - 1] : -1
            let next = k + 1 < scores.count ? scores[k + 1] : -1
            if score >= previous && score > next { candidates.append(slopes[k]) }
        }
        let strongest = slopes[scores.firstIndex(of: best) ?? 0]
        guard candidates.count > 1 else { return strongest }
        let straightness = candidates.map { slope in
            kernelSum(columns) { dx, dy, sigma in (dx + slope * dy) / sigma }
        }
        guard let straightest = straightness.max(), straightest >= 1 else { return strongest }
        return candidates[straightness.firstIndex(of: straightest) ?? 0]
    }

    /// A layout item for one word: x/y is the start of its baseline (after stripped border bars),
    /// w its length along the baseline, h its height. A trailing space (with its width) marks the
    /// word boundary for the layout.
    static func item(for word: OCRWord) -> TextItem? {
        let raw = JSCompat.trim(word.text)
        let leading = String(String.UnicodeScalarView(raw.unicodeScalars.drop(while: isBar)))
        let text = JSCompat.trim(String(String.UnicodeScalarView(leading.unicodeScalars.reversed().drop(while: isBar).reversed())))
        guard !text.isEmpty, !text.unicodeScalars.allSatisfy(isNoise) else { return nil }
        if word.confidence.isFinite, word.confidence < 0.3, !text.unicodeScalars.contains(where: isLetterOrNumber) {
            return nil
        }
        let q = word.quad
        guard q.isFinite else { return nil }
        let dx = Double(q.bottomRight.x - q.bottomLeft.x)
        let dy = Double(q.bottomRight.y - q.bottomLeft.y)
        let length = (dx * dx + dy * dy).squareRoot()
        let hx = Double(q.topLeft.x - q.bottomLeft.x)
        let hy = Double(q.topLeft.y - q.bottomLeft.y)
        let height = (hx * hx + hy * hy).squareRoot()
        guard length > 0, height > 0 else { return nil }
        let rawLength = Double(raw.utf16.count)
        let textLength = Double(text.utf16.count)
        let per = length / max(1, rawLength)
        let lead = rawLength - Double(leading.utf16.count)
        let x = Double(q.bottomLeft.x) + lead * per * dx / length
        let y = Double(q.bottomLeft.y) + lead * per * dy / length
        let w = max(per, textLength * per)
        return TextItem(str: text + " ", x: x, y: y, w: w * (textLength + 1) / textLength, h: height)
    }

    private static func baseline(_ quad: OCRQuad) -> BaselineSegment {
        BaselineSegment(
            x0: Double(quad.bottomLeft.x), y0: Double(quad.bottomLeft.y),
            x1: Double(quad.bottomRight.x), y1: Double(quad.bottomRight.y))
    }

    /// `[|¦]` (border bars glued to words).
    private static func isBar(_ u: Unicode.Scalar) -> Bool { u == "|" || u == "¦" }

    /// `[|¦_─-▟]` (table rules and box drawing).
    private static func isNoise(_ u: Unicode.Scalar) -> Bool {
        isBar(u) || u == "_" || (0x2500...0x259F).contains(u.value)
    }

    /// `[\p{L}\p{N}]`
    private static func isLetterOrNumber(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }
}
