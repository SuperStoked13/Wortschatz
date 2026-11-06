namespace Wortschatz.Core;

/// <summary>
/// Port of OCRImage.swift (image preparation for text recognition, <c>imageScaleFor</c> /
/// <c>toRecognitionCanvas</c> in src/import/ocr.js): images are decoded upright (by the
/// <see cref="IImageDecoder"/>), small ones are upscaled 2× for better accuracy, large ones are reduced,
/// and transparency is flattened onto white. The ImageIO/CoreGraphics code itself is replaced by
/// <see cref="IImageDecoder"/> and <see cref="OcrBitmap"/>.
/// </summary>
public static class OCRImage
{
    /// <summary>Narrower images are upscaled 2×.</summary>
    public const double SmallWidth = 1200;
    /// <summary>Longest side after scaling (only the width for very tall screenshots).</summary>
    public const double MaxSide = 3000;
    /// <summary>Pixel budget after scaling.</summary>
    public const double MaxPixels = 12e6;

    /// <summary>
    /// Scale factor applied before recognition (JS <c>imageScaleFor</c>): small images are upscaled 2×, large
    /// ones are reduced so the longest side stays ≤ 3000 px (tall screenshots keep their width) and the
    /// pixel count stays ≤ 12 MP. 1 for invalid sizes.
    /// </summary>
    public static double Scale(double width, double height)
    {
        if (!(width > 0) || !(height > 0)) return 1;
        double scale = width < SmallWidth ? 2.0 : 1.0;
        double limitedSide = height > 2 * width ? width : Math.Max(width, height);
        scale = Math.Min(scale, MaxSide / limitedSide);
        scale = Math.Min(scale, Math.Sqrt(MaxPixels / (width * height)));
        return scale;
    }

    /// <summary>
    /// Decodes and scales an image file for recognition (<c>toRecognitionCanvas</c>): the result is opaque,
    /// upright and sized by <see cref="Scale"/>. Throws ImportError(decode) for unreadable data.
    /// The Mac app decodes large photos at the reduced size right away; the decoder interface cannot tell
    /// the size before decoding, so here the full image is decoded and then reduced (same result).
    /// </summary>
    public static OcrBitmap PrepareForRecognition(byte[] data, IImageDecoder decoder, CancellationToken ct = default)
    {
        OcrBitmap decoded;
        try { decoded = decoder.Decode(data); }
        catch (Exception error) { throw ImportError.Wrap(error, new ImportError(ImportErrorCode.Decode, ImportMessages.Decode), ct); }
        return PrepareForRecognition(decoded);
    }

    /// <summary>Scales an already decoded image for recognition and flattens it onto white.</summary>
    public static OcrBitmap PrepareForRecognition(OcrBitmap image)
    {
        double factor = Scale(image.Width, image.Height);
        int width = Math.Max(1, (int)Math.Round(image.Width * factor, MidpointRounding.AwayFromZero));
        int height = Math.Max(1, (int)Math.Round(image.Height * factor, MidpointRounding.AwayFromZero));
        return Flattened(image, width, height);
    }

    /// <summary>Draws <paramref name="image"/> at width × height on an opaque white bitmap.</summary>
    internal static OcrBitmap Flattened(OcrBitmap image, int width, int height)
    {
        var flat = image.FlattenedOnWhite();
        return width == image.Width && height == image.Height ? flat : flat.Scaled(width, height);
    }
}
