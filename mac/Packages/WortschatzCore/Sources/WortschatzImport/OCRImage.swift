import CoreGraphics
import Foundation
import ImageIO

/// Image preparation for text recognition (port of `imageScaleFor` / `toRecognitionCanvas` in
/// src/import/ocr.js): images are decoded upright (EXIF orientation applied), small ones are
/// upscaled 2× for better accuracy, large ones are reduced, and transparency is flattened onto white.
public enum OCRImage {
    /// Narrower images are upscaled 2×.
    public static let smallWidth = 1200.0
    /// Longest side after scaling (only the width for very tall screenshots).
    public static let maxSide = 3000.0
    /// Pixel budget after scaling.
    public static let maxPixels = 12e6

    /// Scale factor applied before recognition (JS `imageScaleFor`): small images are upscaled 2×,
    /// large ones are reduced so the longest side stays ≤ 3000 px (tall screenshots keep their
    /// width) and the pixel count stays ≤ 12 MP. 1 for invalid sizes.
    public static func scale(width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        var scale = width < smallWidth ? 2.0 : 1.0
        let limitedSide = height > 2 * width ? width : max(width, height)
        scale = min(scale, maxSide / limitedSide)
        scale = min(scale, (maxPixels / (width * height)).squareRoot())
        return scale
    }

    /// Decodes the first image of `data` upright. Throws `ImportError(.decode)` for unreadable data.
    public static func decode(_ data: Data) throws(ImportError) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImportError(.decode, ImportMessages.decode)
        }
        return try decode(source)
    }

    /// Decodes the first image of the file at `url` upright.
    public static func decode(contentsOf url: URL) throws(ImportError) -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImportError(.decode, ImportMessages.decode)
        }
        return try decode(source)
    }

    /// Decodes and scales an image for recognition in one step (`toRecognitionCanvas`): the result
    /// is opaque, upright and sized by `scale(width:height:)`.
    public static func prepareForRecognition(_ data: Data) throws(ImportError) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImportError(.decode, ImportMessages.decode)
        }
        // Large photos are decoded at the reduced size right away (less memory than decoding first).
        let size = try uprightSize(source)
        let factor = scale(width: size.width, height: size.height)
        let decoded: CGImage
        if factor < 1 {
            let longest = max(size.width, size.height) * factor
            decoded = try decode(source, maxPixelSize: max(1, longest.rounded()))
            return try flattened(decoded, width: decoded.width, height: decoded.height)
        }
        decoded = try decode(source)
        return try prepareForRecognition(decoded)
    }

    /// Scales an already decoded image for recognition and flattens it onto white.
    public static func prepareForRecognition(_ image: CGImage) throws(ImportError) -> CGImage {
        let factor = scale(width: Double(image.width), height: Double(image.height))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        return try flattened(image, width: width, height: height)
    }

    /// Draws `image` at `width` × `height` on an opaque white sRGB bitmap.
    static func flattened(_ image: CGImage, width: Int, height: Int) throws(ImportError) -> CGImage {
        guard let context = whiteContext(width: width, height: height) else {
            throw ImportError(.decode, ImportMessages.decode)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImportError(.decode, ImportMessages.decode) }
        return result
    }

    /// An opaque sRGB bitmap context filled with white.
    static func whiteContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    // MARK: - Decoding

    private static func decode(_ source: CGImageSource, maxPixelSize: Double? = nil) throws(ImportError) -> CGImage {
        guard CGImageSourceGetCount(source) > 0 else { throw ImportError(.decode, ImportMessages.decode) }
        let size = try uprightSize(source)
        // The thumbnail API applies the EXIF orientation; without a size limit it keeps full resolution.
        let limit = maxPixelSize ?? max(size.width, size.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(limit.rounded())),
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        throw ImportError(.decode, ImportMessages.decode)
    }

    /// Pixel size of the first image with its EXIF orientation applied.
    private static func uprightSize(_ source: CGImageSource) throws(ImportError) -> CGSize {
        guard CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else { throw ImportError(.decode, ImportMessages.decode) }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
