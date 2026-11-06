using System.Globalization;

namespace Wortschatz.Core;

// Port of the platform-independent part of TextRecognition.swift (OCRQuad, OCRWord, OCRLine and the
// TextRecognizing protocol) plus the seams that replace Apple's frameworks on Windows: OcrBitmap
// stands in for CGImage, IImageDecoder for ImageIO, IPdfReader / IPdfDocument for PDFKit. The Vision
// engines themselves (VisionTextRecognizer, LegacyVisionTextRecognizer, VisionSettings) are not ported.

/// <summary>32-bit BGRA pixels (byte order B,G,R,A, straight alpha), top-left origin, stride = Width*4.</summary>
public sealed class OcrBitmap
{
    public OcrBitmap(int width, int height, byte[] pixels)
    {
        ArgumentNullException.ThrowIfNull(pixels);
        if (width <= 0 || height <= 0) throw new ArgumentOutOfRangeException(nameof(width), "The bitmap must not be empty.");
        if (pixels.Length != checked(width * height * 4)) throw new ArgumentException("Pixels must hold Width*Height*4 bytes.", nameof(pixels));
        Width = width;
        Height = height;
        Pixels = pixels;
    }

    public int Width { get; }
    public int Height { get; }
    public byte[] Pixels { get; }

    /// <summary>An opaque bitmap of one colour (white by default).</summary>
    public static OcrBitmap Filled(int width, int height, byte b = 255, byte g = 255, byte r = 255, byte a = 255)
    {
        var pixels = new byte[checked(width * height * 4)];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = b;
            pixels[i + 1] = g;
            pixels[i + 2] = r;
            pixels[i + 3] = a;
        }
        return new OcrBitmap(width, height, pixels);
    }

    /// <summary>The pixel at (x, y).</summary>
    public (byte B, byte G, byte R, byte A) PixelAt(int x, int y)
    {
        int i = (y * Width + x) * 4;
        return (Pixels[i], Pixels[i + 1], Pixels[i + 2], Pixels[i + 3]);
    }

    /// <summary>A copy of the part (x, y, width, height); the rectangle must lie inside the bitmap.</summary>
    public OcrBitmap Crop(int x, int y, int width, int height)
    {
        if (x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > Width || y + height > Height)
            throw new ArgumentOutOfRangeException(nameof(x), "The crop rectangle must lie inside the bitmap.");
        var pixels = new byte[width * height * 4];
        for (int row = 0; row < height; row++)
            Buffer.BlockCopy(Pixels, ((y + row) * Width + x) * 4, pixels, row * width * 4, width * 4);
        return new OcrBitmap(width, height, pixels);
    }

    /// <summary>
    /// The bitmap resampled to width × height: area averaging where it shrinks, bilinear interpolation
    /// where it grows (per axis), weighted by alpha so transparent pixels do not bleed their colour.
    /// </summary>
    public OcrBitmap Scaled(int width, int height)
    {
        if (width <= 0 || height <= 0) throw new ArgumentOutOfRangeException(nameof(width), "The size must not be empty.");
        if (width == Width && height == Height) return new OcrBitmap(Width, Height, (byte[])Pixels.Clone());
        var (xStart, xWeights) = Contributions(Width, width);
        var (yStart, yWeights) = Contributions(Height, height);
        var output = new byte[width * height * 4];
        var cache = new Dictionary<int, float[]>();
        var acc = new float[width * 4];
        for (int oy = 0; oy < height; oy++)
        {
            int y0 = yStart[oy];
            foreach (var key in cache.Keys.Where(k => k < y0).ToList()) cache.Remove(key);
            Array.Clear(acc);
            var wy = yWeights[oy];
            for (int k = 0; k < wy.Length; k++)
            {
                int sy = y0 + k;
                if (!cache.TryGetValue(sy, out var row)) cache[sy] = row = HorizontalRow(sy, width, xStart, xWeights);
                float w = wy[k];
                for (int i = 0; i < acc.Length; i++) acc[i] += w * row[i];
            }
            int o = oy * width * 4;
            for (int ox = 0; ox < width; ox++)
            {
                int i = ox * 4;
                float a = acc[i + 3];
                if (a > 0)
                {
                    output[o + i] = ToByte(acc[i] / a);
                    output[o + i + 1] = ToByte(acc[i + 1] / a);
                    output[o + i + 2] = ToByte(acc[i + 2] / a);
                }
                output[o + i + 3] = ToByte(a);
            }
        }
        return new OcrBitmap(width, height, output);
    }

    /// <summary>The bitmap composited onto white: an opaque result.</summary>
    public OcrBitmap FlattenedOnWhite()
    {
        var pixels = new byte[Pixels.Length];
        for (int i = 0; i < Pixels.Length; i += 4)
        {
            int a = Pixels[i + 3];
            for (int c = 0; c < 3; c++) pixels[i + c] = (byte)((Pixels[i + c] * a + 255 * (255 - a) + 127) / 255);
            pixels[i + 3] = 255;
        }
        return new OcrBitmap(Width, Height, pixels);
    }

    /// <summary>One source row resampled horizontally, premultiplied (colour × alpha, alpha).</summary>
    float[] HorizontalRow(int sy, int width, int[] xStart, float[][] xWeights)
    {
        var row = new float[width * 4];
        int baseIndex = sy * Width * 4;
        for (int ox = 0; ox < width; ox++)
        {
            float b = 0, g = 0, r = 0, a = 0;
            var wx = xWeights[ox];
            int s = baseIndex + xStart[ox] * 4;
            for (int k = 0; k < wx.Length; k++, s += 4)
            {
                float alpha = Pixels[s + 3];
                float w = wx[k] * alpha;
                b += w * Pixels[s];
                g += w * Pixels[s + 1];
                r += w * Pixels[s + 2];
                a += wx[k] * alpha;
            }
            int i = ox * 4;
            row[i] = b;
            row[i + 1] = g;
            row[i + 2] = r;
            row[i + 3] = a;
        }
        return row;
    }

    /// <summary>For every target index: the first source index and the normalised weights of the source run.</summary>
    static (int[] Start, float[][] Weights) Contributions(int source, int target)
    {
        var start = new int[target];
        var weights = new float[target][];
        double scale = (double)source / target;
        for (int i = 0; i < target; i++)
        {
            if (scale > 1)
            {
                double a = i * scale, b = a + scale;
                int s0 = (int)Math.Floor(a);
                int s1 = Math.Min(source, (int)Math.Ceiling(b));
                var w = new float[Math.Max(1, s1 - s0)];
                double sum = 0;
                for (int j = s0; j < s1; j++)
                {
                    double cover = Math.Min(b, j + 1) - Math.Max(a, j);
                    w[j - s0] = (float)Math.Max(0, cover);
                    sum += w[j - s0];
                }
                for (int k = 0; k < w.Length; k++) w[k] = sum > 0 ? (float)(w[k] / sum) : 1f / w.Length;
                start[i] = s0;
                weights[i] = w;
            }
            else
            {
                double c = Math.Clamp((i + 0.5) * scale - 0.5, 0, source - 1);
                int j = (int)Math.Floor(c);
                double t = c - j;
                start[i] = j;
                weights[i] = j + 1 < source && t > 0 ? [(float)(1 - t), (float)t] : [1f];
            }
        }
        return (start, weights);
    }

    static byte ToByte(float v) => (byte)Math.Clamp((int)MathF.Round(v), 0, 255);
}

/// <summary>A point in image pixels (top-left origin).</summary>
public readonly record struct OcrPoint(double X, double Y);

/// <summary>A quadrilateral in image pixels with a top-left origin (y grows downwards).</summary>
public sealed record OcrQuad(OcrPoint TopLeft, OcrPoint TopRight, OcrPoint BottomRight, OcrPoint BottomLeft)
{
    /// <summary>An axis-aligned rectangle (top-left origin).</summary>
    public static OcrQuad FromRect(double x, double y, double width, double height) => new(
        new OcrPoint(x, y), new OcrPoint(x + width, y), new OcrPoint(x + width, y + height), new OcrPoint(x, y + height));

    /// <summary>The part of the quad between <paramref name="from"/> and <paramref name="to"/> (fractions 0…1 along the baseline direction).</summary>
    public OcrQuad Slice(double from, double to)
    {
        static OcrPoint Lerp(OcrPoint a, OcrPoint b, double t) => new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);
        return new OcrQuad(Lerp(TopLeft, TopRight, from), Lerp(TopLeft, TopRight, to), Lerp(BottomLeft, BottomRight, to), Lerp(BottomLeft, BottomRight, from));
    }

    /// <summary>The quad moved by (dx, dy).</summary>
    public OcrQuad Offset(double dx, double dy)
    {
        OcrPoint Move(OcrPoint p) => new(p.X + dx, p.Y + dy);
        return new OcrQuad(Move(TopLeft), Move(TopRight), Move(BottomRight), Move(BottomLeft));
    }

    public bool IsFinite => new[] { TopLeft, TopRight, BottomRight, BottomLeft }.All(p => double.IsFinite(p.X) && double.IsFinite(p.Y));
}

/// <summary>One recognised word with its box. Confidence 0…1.</summary>
public sealed record OcrWord(string Text, double Confidence, OcrQuad Quad);

/// <summary>One recognised text line with its words. Confidence 0…1.</summary>
public sealed record OcrLine(string Text, double Confidence, OcrQuad Quad, IReadOnlyList<OcrWord> Words)
{
    /// <summary>
    /// Splits <paramref name="text"/> into whitespace-separated words (Swift <c>OCRLine.init(text:confidence:quad:wordQuad:)</c>).
    /// <paramref name="wordQuad"/> returns the engine's box of a word (UTF-16 start and length); words
    /// without one get a slice of the line box proportional to their position (counted in user-perceived
    /// characters like Swift), from the right end for right-to-left text (Arabic words are in logical order).
    /// </summary>
    public static OcrLine FromText(string text, double confidence, OcrQuad quad, Func<int, int, OcrQuad?>? wordQuad = null)
    {
        var elements = new List<(int Start, int Length, bool Space)>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var element = (string)e.Current;
            elements.Add((e.ElementIndex, element.Length, char.IsWhiteSpace(element, 0)));
        }
        double total = Math.Max(1, elements.Count);
        bool rtl = TextLayout.IsRtlText(text);
        var words = new List<OcrWord>();
        int index = 0;
        while (index < elements.Count)
        {
            if (elements[index].Space)
            {
                index++;
                continue;
            }
            int first = index;
            while (index < elements.Count && !elements[index].Space) index++;
            int start = elements[first].Start;
            int end = elements[index - 1].Start + elements[index - 1].Length;
            double from = first / total, to = index / total;
            var box = wordQuad?.Invoke(start, end - start) is { IsFinite: true } q
                ? q
                : rtl ? quad.Slice(1 - to, 1 - from) : quad.Slice(from, to);
            words.Add(new OcrWord(text[start..end], confidence, box));
        }
        return new OcrLine(text, confidence, quad, words);
    }
}

/// <summary>An axis-aligned rectangle (top-left origin), the CGRect of the Swift code.</summary>
public readonly record struct TextRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;

    /// <summary>The area both rectangles cover (0 when they do not intersect).</summary>
    public double IntersectionArea(TextRect other)
    {
        double w = Math.Min(MaxX, other.MaxX) - Math.Max(MinX, other.MinX);
        double h = Math.Min(MaxY, other.MaxY) - Math.Max(MinY, other.MinY);
        return w > 0 && h > 0 ? w * h : 0;
    }
}

/// <summary>
/// Port of TextRecognizing: a text recognition engine that finds the text lines and word boxes on an
/// image. Pixel coordinates, top-left origin. Languages: BCP 47 tags in priority order ("fr-FR",
/// "de-DE"); unsupported ones are ignored. <c>progress</c> (optional) receives the done fraction 0…1.
/// Implementations stop with an <see cref="OperationCanceledException"/> when <c>ct</c> is cancelled.
/// </summary>
public interface ITextRecognizer
{
    Task<IReadOnlyList<OcrLine>> RecognizeTextAsync(OcrBitmap image, IReadOnlyList<string> languages, Action<double>? progress, CancellationToken ct);
}

/// <summary>Decodes PNG/JPEG/… (upright, EXIF orientation applied). maxPixelSize limits the longer side. Throws ImportError(decode).</summary>
public interface IImageDecoder
{
    OcrBitmap Decode(byte[] data, double? maxPixelSize = null);
}

/// <summary>Opens PDF documents; throws ImportError pdfInvalid / pdfPassword.</summary>
public interface IPdfReader
{
    IPdfDocument Open(byte[] data);
}

/// <summary>An open PDF document (the PDFKit part of the Mac importer).</summary>
public interface IPdfDocument : IDisposable
{
    int PageCount { get; }

    /// <summary>The text layer of a page as layout items, like PDFPageReading.items: top-origin, baseline y (see <see cref="PDFPageText.Items"/>).</summary>
    List<TextItem> Items(int pageIndex);

    /// <summary>Whether the page paints images (also inside form XObjects, inline images); errors count as true.</summary>
    bool PageHasImages(int pageIndex);

    /// <summary>The page as an opaque image: pixels = points * scale, white background, rotation and crop box applied.</summary>
    OcrBitmap Render(int pageIndex, double scale);

    /// <summary>The displayed page size in points (rotation and crop box applied).</summary>
    (double Width, double Height) PageSize(int pageIndex);
}
