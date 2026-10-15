import CoreGraphics
import Foundation
import Vision
import WortschatzCore

/// A quadrilateral in image pixels with a top-left origin (y grows downwards).
public struct OCRQuad: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// An axis-aligned rectangle (top-left origin).
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(
            topLeft: CGPoint(x: x, y: y), topRight: CGPoint(x: x + width, y: y),
            bottomRight: CGPoint(x: x + width, y: y + height), bottomLeft: CGPoint(x: x, y: y + height))
    }

    /// The part of the quad between `from` and `to` (fractions 0…1 along the baseline direction).
    func slice(from: Double, to: Double) -> OCRQuad {
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return OCRQuad(
            topLeft: lerp(topLeft, topRight, from), topRight: lerp(topLeft, topRight, to),
            bottomRight: lerp(bottomLeft, bottomRight, to), bottomLeft: lerp(bottomLeft, bottomRight, from))
    }

    var isFinite: Bool {
        [topLeft, topRight, bottomRight, bottomLeft].allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

/// One recognised word with its box.
public struct OCRWord: Sendable, Equatable {
    public var text: String
    /// 0…1
    public var confidence: Double
    public var quad: OCRQuad

    public init(text: String, confidence: Double, quad: OCRQuad) {
        self.text = text
        self.confidence = confidence
        self.quad = quad
    }
}

/// One recognised text line (a Vision observation) with its words.
public struct OCRLine: Sendable, Equatable {
    public var text: String
    /// 0…1
    public var confidence: Double
    public var quad: OCRQuad
    public var words: [OCRWord]

    public init(text: String, confidence: Double, quad: OCRQuad, words: [OCRWord]) {
        self.text = text
        self.confidence = confidence
        self.quad = quad
        self.words = words
    }

    /// Splits `text` into whitespace-separated words. `wordQuad` returns the engine's box of a word
    /// range; words without one get a slice of the line box proportional to their position, counted
    /// from the right end for right-to-left text (Arabic words are in logical order).
    init(text: String, confidence: Double, quad: OCRQuad, wordQuad: (Range<String.Index>) -> OCRQuad?) {
        var words: [OCRWord] = []
        let total = Double(max(1, text.count))
        let rtl = TextLayout.isRtlText(text)
        var offset = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                offset += 1
                continue
            }
            let start = index
            let startOffset = offset
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
                offset += 1
            }
            let range = start..<index
            let from = Double(startOffset) / total
            let to = Double(offset) / total
            let box = wordQuad(range).flatMap { $0.isFinite ? $0 : nil }
                ?? (rtl ? quad.slice(from: 1 - to, to: 1 - from) : quad.slice(from: from, to: to))
            words.append(OCRWord(text: String(text[range]), confidence: confidence, quad: box))
        }
        self.init(text: text, confidence: confidence, quad: quad, words: words)
    }
}

/// A text recognition engine: finds the text lines and word boxes on an image.
public protocol TextRecognizing: Sendable {
    /// Recognises the text on `image`. `languages` are BCP 47 tags in priority order ("fr-FR",
    /// "de-DE"); unsupported ones are ignored. Coordinates are image pixels with a top-left origin.
    /// `progress` (optional) receives the done fraction 0…1 of a long recognition.
    /// Implementations stop with `CancellationError` (or their own cancellation error) when the
    /// task is cancelled.
    func recognizeText(
        in image: CGImage, languages: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [OCRLine]
}

extension TextRecognizing {
    public func recognizeText(in image: CGImage, languages: [String]) async throws -> [OCRLine] {
        try await recognizeText(in: image, languages: languages, progress: nil)
    }
}

/// Helpers both Vision engines use.
enum VisionSettings {
    /// The requested tags whose language Vision supports, in the requested order: an available
    /// language has the tag's language code and script ("zh-Hans" is not "zh-Hant"; scripts are
    /// compared on the maximal identifiers, so "fr-FR" matches "fr-Latn-FR"). Duplicates are dropped
    /// by full identifier ("fr" and "fr-FR" are one, "zh-Hans" and "zh-Hant" two).
    static func supported(_ requested: [String], available: [String]) -> [String] {
        let languages = available.map(Locale.Language.init(identifier:))
        var seen = Set<String>()
        return requested.filter { tag in
            let language = Locale.Language(identifier: tag)
            guard let code = language.languageCode else { return false }
            let script = maximalScript(language)
            let isAvailable = languages.contains { $0.languageCode == code && maximalScript($0) == script }
            return isAvailable && seen.insert(language.maximalIdentifier).inserted
        }
    }

    /// The script of a language, with the likely one filled in ("zh" → Hans, "ar-SA" → Arab).
    private static func maximalScript(_ language: Locale.Language) -> String? {
        Locale.Language(identifier: language.maximalIdentifier).script?.identifier
    }

    /// Runs `recognize` with `tags`. When Vision rejects the combination (any failure other than a
    /// cancellation) and there are several tags, recognises once more with the first one alone: the
    /// set's term language ("zh-Hans" may not combine with "de-DE").
    static func withFallback<T>(_ tags: [String], _ recognize: ([String]) async throws -> T) async throws -> T {
        do {
            return try await recognize(tags)
        } catch {
            guard tags.count > 1, !(error is CancellationError), !Task.isCancelled else { throw error }
            return try await recognize([tags[0]])
        }
    }
}

/// Text recognition with the Swift Vision API (`RecognizeTextRequest`, accurate level with
/// language correction).
@available(macOS 15.0, *)
public struct VisionTextRecognizer: TextRecognizing {
    public var usesLanguageCorrection: Bool

    public init(usesLanguageCorrection: Bool = true) {
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(
        in image: CGImage, languages: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [OCRLine] {
        func makeRequest(_ tags: [String]) -> RecognizeTextRequest {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = usesLanguageCorrection
            request.automaticallyDetectsLanguage = false
            if !tags.isEmpty { request.recognitionLanguages = tags.map { Locale.Language(identifier: $0) } }
            return request
        }
        let available = makeRequest([]).supportedRecognitionLanguages.map(\.maximalIdentifier)
        let tags = VisionSettings.supported(languages, available: available)

        let observations = try await VisionSettings.withFallback(tags) { tags in
            try await makeRequest(tags).perform(on: image)
        }
        try Task.checkCancellation()
        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ p: NormalizedPoint) -> CGPoint { p.toImageCoordinates(size, origin: .upperLeft) }
        func quad(_ q: some QuadrilateralProviding) -> OCRQuad {
            OCRQuad(topLeft: pixels(q.topLeft), topRight: pixels(q.topRight),
                    bottomRight: pixels(q.bottomRight), bottomLeft: pixels(q.bottomLeft))
        }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string, confidence: Double(candidate.confidence), quad: quad(observation),
                wordQuad: { range in candidate.boundingBox(for: range).map(quad) })
        }
    }
}

/// Text recognition with `VNRecognizeTextRequest` (macOS 14 fallback; same settings).
public struct LegacyVisionTextRecognizer: TextRecognizing {
    public var usesLanguageCorrection: Bool

    public init(usesLanguageCorrection: Bool = true) {
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(
        in image: CGImage, languages: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [OCRLine] {
        try Task.checkCancellation()
        let available = (try? makeRequest().supportedRecognitionLanguages()) ?? []
        let tags = VisionSettings.supported(languages, available: available)
        let observations = try await VisionSettings.withFallback(tags) { tags in
            try await perform(on: image, tags: tags, progress: progress)
        }
        try Task.checkCancellation()

        let size = CGSize(width: image.width, height: image.height)
        func pixels(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
        func quad(_ r: VNRectangleObservation) -> OCRQuad {
            OCRQuad(topLeft: pixels(r.topLeft), topRight: pixels(r.topRight),
                    bottomRight: pixels(r.bottomRight), bottomLeft: pixels(r.bottomLeft))
        }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string, confidence: Double(candidate.confidence), quad: quad(observation),
                wordQuad: { range in (try? candidate.boundingBox(for: range)).map(quad) })
        }
    }

    private func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        return request
    }

    /// One recognition pass with the given languages (all supported ones, or none).
    private func perform(
        on image: CGImage, tags: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [VNRecognizedTextObservation] {
        let request = makeRequest()
        if !tags.isEmpty { request.recognitionLanguages = tags }
        if let progress {
            request.progressHandler = { _, fraction, _ in progress(fraction) }
        }
        let box = RequestBox(request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let request = box.request
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        continuation.resume(returning: request.results ?? [])
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.request.cancel()
        }
    }

    /// Hands the request to the Vision queue and the cancellation handler (`cancel()` is thread-safe).
    private final class RequestBox: @unchecked Sendable {
        let request: VNRecognizeTextRequest
        init(_ request: VNRecognizeTextRequest) { self.request = request }
    }
}

/// The best Vision engine of the running system, with band passes for small print.
public enum SystemTextRecognizer {
    public static func make() -> any TextRecognizing {
        if #available(macOS 15.0, *) { return BandedTextRecognizer(base: VisionTextRecognizer()) }
        return BandedTextRecognizer(base: LegacyVisionTextRecognizer())
    }
}
