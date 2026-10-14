import CoreGraphics
import Foundation

/// Runs a recognizer on the whole image and on overlapping parts of it, then merges the results.
///
/// Vision's accurate recognizer reliably misses small print on large images: on a photographed
/// vocabulary page or a scanned A4 page it often returns only one of two table columns, or a few
/// rows. Recognising full-width bands of the image (two band heights, a quarter overlapping)
/// shows the text larger, and a left and a right part help wide images with far-apart columns;
/// the union of all passes finds almost every line (97 % instead of 67 % of the cells in
/// synthetic page tests). Duplicates are removed by geometry, preferring lines confirmed by
/// several passes; lines cut by a part's edge are ignored (another pass sees them whole).
public struct BandedTextRecognizer: TextRecognizing {
    public var base: any TextRecognizing
    /// Band heights in pixels; each one is a separate set of overlapping bands.
    public var bandHeights: [Int]
    /// Fraction of a band shared with the next one.
    public var overlap: Double
    /// Images up to this height get a single pass.
    public var singlePassHeight: Int

    /// Images at least this wide also get a left and a right pass (each 60 % of the width).
    public var splitWidth: Int

    public init(
        base: any TextRecognizing, bandHeights: [Int] = [600, 1000], overlap: Double = 0.25, singlePassHeight: Int = 900,
        splitWidth: Int = 1000
    ) {
        self.base = base
        self.bandHeights = bandHeights
        self.overlap = overlap
        self.singlePassHeight = singlePassHeight
        self.splitWidth = splitWidth
    }

    public func recognizeText(
        in image: CGImage, languages: [String], progress: (@Sendable (Double) -> Void)?
    ) async throws -> [OCRLine] {
        let size = Size(width: image.width, height: image.height)
        let regions = Self.regions(
            for: size, bandHeights: bandHeights, overlap: overlap, singlePassHeight: singlePassHeight, splitWidth: splitWidth)
        var pool: [OCRLine] = []
        for (k, region) in regions.enumerated() {
            try Task.checkCancellation()
            let isFull = region == Region(x: 0, y: 0, width: size.width, height: size.height)
            let crop = isFull ? image : image.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
            if let crop {
                let lines = try await base.recognizeText(in: crop, languages: languages, progress: nil)
                pool += lines.compactMap { Self.place($0, in: region, image: size) }
            }
            progress?(Double(k + 1) / Double(regions.count))
        }
        return regions.count == 1 ? pool : Self.merge(pool)
    }

    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    /// A part of the image (pixels, top-left origin).
    struct Region: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// The whole image; for tall images, for every band height, evenly spaced full-width bands that
    /// overlap by at least `overlap` and cover the image from top to bottom; for wide images, a
    /// left and a right part (60 % of the width each, full height).
    static func regions(for size: Size, bandHeights: [Int], overlap: Double, singlePassHeight: Int, splitWidth: Int) -> [Region] {
        var regions = [Region(x: 0, y: 0, width: size.width, height: size.height)]
        if size.height > singlePassHeight {
            for band in bandHeights where band > 0 && band < size.height {
                let stride = Double(band) * (1 - min(0.9, max(0, overlap)))
                let count = Int((Double(size.height - band) / stride).rounded(.up)) + 1
                let step = Double(size.height - band) / Double(count - 1)
                for k in 0..<count {
                    regions.append(Region(x: 0, y: Int((Double(k) * step).rounded()), width: size.width, height: band))
                }
            }
        }
        if size.width >= splitWidth {
            let part = Int((Double(size.width) * 0.6).rounded())
            regions.append(Region(x: 0, y: 0, width: part, height: size.height))
            regions.append(Region(x: size.width - part, y: 0, width: part, height: size.height))
        }
        return regions
    }

    /// Moves a line found in `region` into image coordinates; nil when it touches a cut edge of the
    /// region (an edge that is not an edge of the image).
    static func place(_ line: OCRLine, in region: Region, image: Size) -> OCRLine? {
        let box = bounds(line.quad)
        let margin = max(2, 0.1 * box.height)
        if region.y > 0 && box.minY < margin { return nil }
        if region.y + region.height < image.height && box.maxY > Double(region.height) - margin { return nil }
        if region.x > 0 && box.minX < margin { return nil }
        if region.x + region.width < image.width && box.maxX > Double(region.width) - margin { return nil }
        guard region.x != 0 || region.y != 0 else { return line }
        let dx = Double(region.x)
        let dy = Double(region.y)
        func shift(_ q: OCRQuad) -> OCRQuad {
            func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
            return OCRQuad(topLeft: move(q.topLeft), topRight: move(q.topRight), bottomRight: move(q.bottomRight), bottomLeft: move(q.bottomLeft))
        }
        var placed = line
        placed.quad = shift(line.quad)
        placed.words = line.words.map { word in
            var moved = word
            moved.quad = shift(word.quad)
            return moved
        }
        return placed
    }

    /// Removes duplicates and misreads from the lines of all passes:
    /// - boxes more than 2.2 × the median line height are dropped (a column of short words read as
    ///   one line);
    /// - every line is supported by the overlapping lines of other passes with the same text;
    /// - greedily, the best-supported (then most confident, then longest) line wins and suppresses
    ///   the lines it overlaps by more than 40 % of the smaller box.
    static func merge(_ lines: [OCRLine]) -> [OCRLine] {
        let boxes = lines.map { bounds($0.quad) }
        let heights = boxes.map(\.height).filter { $0 > 0 }.sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
        let candidates = lines.indices.filter { i in
            boxes[i].width > 0 && boxes[i].height > 0 && (lines.count < 3 || boxes[i].height <= 2.2 * medianHeight)
        }
        let support = candidates.map { i in
            candidates.filter { j in j != i && lines[j].text == lines[i].text && overlapRatio(boxes[i], boxes[j]) > 0.4 }.count
        }
        let order = candidates.indices.sorted { a, b in
            let (i, j) = (candidates[a], candidates[b])
            if support[a] != support[b] { return support[a] > support[b] }
            if lines[i].confidence != lines[j].confidence { return lines[i].confidence > lines[j].confidence }
            if lines[i].text.count != lines[j].text.count { return lines[i].text.count > lines[j].text.count }
            return i < j
        }
        var accepted: [Int] = []
        for k in order {
            let i = candidates[k]
            if accepted.contains(where: { overlapRatio(boxes[i], boxes[$0]) > 0.4 }) { continue }
            accepted.append(i)
        }
        return accepted.sorted { boxes[$0].minY != boxes[$1].minY ? boxes[$0].minY < boxes[$1].minY : boxes[$0].minX < boxes[$1].minX }
            .map { lines[$0] }
    }

    /// Intersection area relative to the smaller box.
    static func overlapRatio(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? Double(intersection.width * intersection.height / smaller) : 0
    }

    static func bounds(_ q: OCRQuad) -> CGRect {
        let xs = [q.topLeft.x, q.topRight.x, q.bottomRight.x, q.bottomLeft.x]
        let ys = [q.topLeft.y, q.topRight.y, q.bottomRight.y, q.bottomLeft.y]
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
