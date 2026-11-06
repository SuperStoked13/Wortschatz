using SkiaSharp;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Exceptions;
using Wortschatz.Core;
#if WINDOWS
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using WinOcr = Windows.Media.Ocr;
using Windows.Storage.Streams;
using WinPdf = Windows.Data.Pdf;
#endif

namespace Wortschatz.App.Services;

// The Windows side of the PDF and photo import (Mac: PDFTextExtractor/PDFPageReading with PDFKit, OCRImage with ImageIO,
// VisionTextRecognizer with Vision). The logic (which pages need text recognition, layout, clean-up) is in
// Wortschatz.Core (ImportPipeline, PDFTextExtractor, OCRService, TextLayout, OCRPostprocess); this file only provides:
//   - PDF text with positions: PdfPig (managed, also on Linux), words → TextItem (top-origin, baseline y)
//   - PDF page images for scanned pages: Windows.Data.Pdf (Windows only)
//   - image decoding: Windows.Graphics.Imaging (EXIF orientation, HEIC/TIFF when Windows has the codec); Skia elsewhere
//   - text recognition: Windows.Media.Ocr, one engine per script (Latin, Chinese, Arabic) of the set's languages

/// <summary>Builds the import pipeline with this platform's PDF reader, image decoder and text recognition.</summary>
public static class ImportServices
{
    public static ImportPipeline CreatePipeline() => new(new PdfPigReader(), CreateImageDecoder(), CreateRecognizer());

    public static IImageDecoder CreateImageDecoder() =>
#if WINDOWS
        new WindowsImageDecoder();
#else
        PlatformImageDecoder?.Invoke() ?? new SkiaImageDecoder();
#endif

    public static ITextRecognizer? CreateRecognizer() =>
#if WINDOWS
        new BandedTextRecognizer(new WindowsTextRecognizer());
#else
        PlatformRecognizer?.Invoke();
#endif

    /// <summary>Another platform's text recognition (a phone: ML Kit), set before the app starts.</summary>
    public static Func<ITextRecognizer>? PlatformRecognizer { get; set; }

    /// <summary>Another platform's image decoder (a phone: also HEIC photos), set before the app starts.</summary>
    public static Func<IImageDecoder>? PlatformImageDecoder { get; set; }

    /// <summary>
    /// A set language without a Windows text recognizer was asked for (its name, e.g. "Französisch"). The editor
    /// explains how to add it; recognition still runs with another recognizer of the same script when there is one.
    /// </summary>
    public static event Action<Lang>? MissingRecognizer;

    public static void ReportMissing(Lang lang) => MissingRecognizer?.Invoke(lang);
}

// MARK: PDF

/// <summary>PDFs through PdfPig (text with positions, whether a page has images); pages render with Windows.Data.Pdf.</summary>
public sealed class PdfPigReader : IPdfReader
{
    public IPdfDocument Open(byte[] data)
    {
        try
        {
            return new PdfPigDocument(PdfDocument.Open(data, new ParsingOptions { UseLenientParsing = true }), data);
        }
        catch (PdfDocumentEncryptedException)
        {
            throw new ImportError(ImportErrorCode.PdfPassword, ImportMessages.PdfPassword);
        }
        catch (Exception e) when (e is not ImportError and not OperationCanceledException)
        {
            throw new ImportError(ImportErrorCode.PdfInvalid, ImportMessages.PdfInvalid);
        }
    }
}

sealed class PdfPigDocument(PdfDocument document, byte[] data) : IPdfDocument
{
#if WINDOWS
    WinPdf.PdfDocument? _rendered;
#endif

    public int PageCount => document.NumberOfPages;

    Page Page(int index) => document.GetPage(index + 1);

    public (double Width, double Height) PageSize(int pageIndex)
    {
        var page = Page(pageIndex);
        return (page.Width, page.Height);
    }

    /// <summary>
    /// The page's words as text items (Mac: PDFPageReading.items): x = left edge, y = baseline from the top, w = width,
    /// h = font size. Ligatures are expanded like on the Mac. TextLayout.itemsToLines rebuilds rows and columns.
    /// </summary>
    public List<TextItem> Items(int pageIndex)
    {
        var page = Page(pageIndex);
        var items = new List<TextItem>();
        foreach (var word in page.GetWords())
        {
            if (word.Letters.Count == 0 || string.IsNullOrWhiteSpace(word.Text)) continue;
            var first = word.Letters[0];
            double size = word.Letters.Max(l => l.PointSize);
            if (!(size > 0)) size = word.BoundingBox.Height;
            var box = word.BoundingBox;
            items.Add(new TextItem(PDFPageText.ExpandingLigatures(word.Text), box.Left, page.Height - first.StartBaseLine.Y, box.Width, size));
        }
        return items;
    }

    public bool PageHasImages(int pageIndex)
    {
        try { return Page(pageIndex).GetImages().Any(); }
        catch (Exception e) when (e is not OperationCanceledException) { return false; }
    }

    public OcrBitmap Render(int pageIndex, double scale)
    {
#if WINDOWS
        return RenderAsync(pageIndex, scale).GetAwaiter().GetResult();
#else
        throw new ImportError(ImportErrorCode.OcrFailed, "Gescannte PDF-Seiten können nur unter Windows gelesen werden.");
#endif
    }

#if WINDOWS
    async Task<OcrBitmap> RenderAsync(int pageIndex, double scale)
    {
        try
        {
            _rendered ??= await WinPdf.PdfDocument.LoadFromStreamAsync(await WinRT.Stream(data));
            using var page = _rendered.GetPage((uint)pageIndex);
            // Windows gives the displayed page size (rotation and crop box applied) in DIPs (1/96 inch); scale is per point.
            double width = page.Size.Width * 72 / 96, height = page.Size.Height * 72 / 96;
            using var output = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(output, new WinPdf.PdfPageRenderOptions
            {
                DestinationWidth = (uint)Math.Max(1, Math.Round(width * scale)),
                DestinationHeight = (uint)Math.Max(1, Math.Round(height * scale)),
                BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255),
            });
            output.Seek(0);
            return await WinRT.Decode(output);
        }
        catch (Exception e) when (e is not ImportError and not OperationCanceledException)
        {
            throw new ImportError(ImportErrorCode.PdfFailed, ImportMessages.PdfFailed);
        }
    }
#endif

    public void Dispose() => document.Dispose();
}

// MARK: Images

/// <summary>Decodes images with Skia (PNG, JPEG, WebP, GIF, BMP); used where the Windows decoder is not available.</summary>
public sealed class SkiaImageDecoder : IImageDecoder
{
    public OcrBitmap Decode(byte[] data, double? maxPixelSize = null)
    {
        using var codec = SKCodec.Create(new SKMemoryStream(data)) ?? throw new ImportError(ImportErrorCode.Decode, ImportMessages.Decode);
        using var decoded = SKBitmap.Decode(codec, codec.Info.WithColorType(SKColorType.Bgra8888).WithAlphaType(SKAlphaType.Unpremul))
            ?? throw new ImportError(ImportErrorCode.Decode, ImportMessages.Decode);
        using var upright = Orient(decoded, codec.EncodedOrigin);
        var bitmap = new OcrBitmap(upright.Width, upright.Height, upright.Bytes);
        return Limit(bitmap, maxPixelSize);
    }

    public static OcrBitmap Limit(OcrBitmap bitmap, double? maxPixelSize)
    {
        if (maxPixelSize is not { } max || Math.Max(bitmap.Width, bitmap.Height) <= max) return bitmap;
        double f = max / Math.Max(bitmap.Width, bitmap.Height);
        return bitmap.Scaled(Math.Max(1, (int)Math.Round(bitmap.Width * f)), Math.Max(1, (int)Math.Round(bitmap.Height * f)));
    }

    static SKBitmap Orient(SKBitmap source, SKEncodedOrigin origin)
    {
        if (origin is SKEncodedOrigin.TopLeft or SKEncodedOrigin.Default) return source.Copy();
        bool swap = origin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
        var result = new SKBitmap(new SKImageInfo(swap ? source.Height : source.Width, swap ? source.Width : source.Height, SKColorType.Bgra8888, SKAlphaType.Unpremul));
        using var canvas = new SKCanvas(result);
        int w = source.Width, h = source.Height;
        switch (origin)
        {
            case SKEncodedOrigin.TopRight: canvas.Scale(-1, 1, w / 2f, 0); break;
            case SKEncodedOrigin.BottomRight: canvas.RotateDegrees(180, w / 2f, h / 2f); break;
            case SKEncodedOrigin.BottomLeft: canvas.Scale(1, -1, 0, h / 2f); break;
            case SKEncodedOrigin.LeftTop: canvas.Translate(0, w); canvas.RotateDegrees(-90); canvas.Scale(1, -1, 0, h / 2f); break;
            case SKEncodedOrigin.RightTop: canvas.Translate(h, 0); canvas.RotateDegrees(90); break;
            case SKEncodedOrigin.RightBottom: canvas.Translate(h, 0); canvas.RotateDegrees(90); canvas.Scale(-1, -1, w / 2f, h / 2f); break;
            case SKEncodedOrigin.LeftBottom: canvas.Translate(0, w); canvas.RotateDegrees(-90); break;
        }
        canvas.DrawBitmap(source, 0, 0);
        return result;
    }
}

#if WINDOWS
/// <summary>Decodes images with Windows (EXIF orientation applied; HEIC and TIFF when Windows has the codec).</summary>
public sealed class WindowsImageDecoder : IImageDecoder
{
    public OcrBitmap Decode(byte[] data, double? maxPixelSize = null)
    {
        OcrBitmap bitmap;
        try { bitmap = DecodeAsync(data).GetAwaiter().GetResult(); }
        catch (Exception e) when (e is not ImportError and not OperationCanceledException)
        {
            // Not a format Windows knows (or no codec, e.g. HEIC without the extension): try Skia.
            return new SkiaImageDecoder().Decode(data, maxPixelSize);
        }
        return SkiaImageDecoder.Limit(bitmap, maxPixelSize);
    }

    static async Task<OcrBitmap> DecodeAsync(byte[] data)
    {
        using var stream = await WinRT.Stream(data);
        return await WinRT.Decode(stream);
    }
}

/// <summary>WinRT helpers: byte arrays as streams, decoding to BGRA.</summary>
static class WinRT
{
    public static async Task<IRandomAccessStream> Stream(byte[] data)
    {
        var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(data.AsBuffer());
        stream.Seek(0);
        return stream;
    }

    public static async Task<OcrBitmap> Decode(IRandomAccessStream stream)
    {
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(),
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        return new OcrBitmap((int)decoder.OrientedPixelWidth, (int)decoder.OrientedPixelHeight, pixels.DetachPixelData());
    }
}

// MARK: Text recognition

/// <summary>
/// Text recognition with Windows.Media.Ocr (Mac: VisionTextRecognizer). Windows recognizes one language per engine and
/// only languages that are installed (Einstellungen › Zeit und Sprache › Sprache). The set's languages are grouped by
/// script: one engine for Latin (the first set language that is installed, else any installed Latin one – it reads
/// French accents well enough), one for Chinese, one for Arabic. With several engines, overlapping lines keep the
/// version in the line's own script.
/// </summary>
public sealed class WindowsTextRecognizer : ITextRecognizer
{
    enum Script { Latin, Chinese, Arabic }

    static Script ScriptOf(string tag) => tag.Split('-')[0].ToLowerInvariant() switch
    {
        "zh" or "ja" or "ko" => Script.Chinese,
        "ar" or "fa" or "ur" => Script.Arabic,
        _ => Script.Latin,
    };

    static Lang? LangOf(string tag) => tag.Split('-')[0].ToLowerInvariant() switch
    {
        "fr" => Lang.Fr, "en" => Lang.En, "es" => Lang.Es, "it" => Lang.It, "ar" => Lang.Ar, "zh" => Lang.Zh, "de" => Lang.De,
        _ => null,
    };

    public async Task<IReadOnlyList<OcrLine>> RecognizeTextAsync(OcrBitmap image, IReadOnlyList<string> languages, Action<double>? progress, CancellationToken ct)
    {
        var engines = Engines(languages.Count > 0 ? languages : ["de-DE"]);
        if (engines.Count == 0)
            throw new ImportError(ImportErrorCode.OcrFailed,
                "Windows hat keine Texterkennung installiert. Füge unter «Einstellungen › Zeit und Sprache › Sprache» eine Sprache hinzu und versuche es nochmals.");

        // Windows limits the image size; larger images are scaled down and the boxes scaled back.
        double f = Math.Min(1, WinOcr.OcrEngine.MaxImageDimension / (double)Math.Max(image.Width, image.Height));
        var input = f < 1 ? image.Scaled(Math.Max(1, (int)(image.Width * f)), Math.Max(1, (int)(image.Height * f))) : image;
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(input.FlattenedOnWhite().Pixels.AsBuffer(), BitmapPixelFormat.Bgra8,
            input.Width, input.Height, BitmapAlphaMode.Premultiplied);

        var results = new List<(Script Script, List<OcrLine> Lines)>();
        for (int i = 0; i < engines.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var (script, engine) = engines[i];
            var result = await engine.RecognizeAsync(bitmap).AsTask(ct);
            // Windows straightens skewed text before reading it and reports the boxes in the straightened image
            // (rotated by TextAngle around its centre): turned back here, so every pass of BandedTextRecognizer
            // places the same line at the same spot.
            var geometry = new Geometry(result.TextAngle ?? 0, input.Width / 2.0, input.Height / 2.0, 1 / f);
            results.Add((script, result.Lines.Select(l => Convert(l, script, geometry)).Where(l => l is not null).Select(l => l!).ToList()));
            progress?.Invoke((i + 1) / (double)engines.Count);
        }
        return Merge(results);
    }

    /// <summary>One engine per script, in the order of the set's languages.</summary>
    static List<(Script, WinOcr.OcrEngine)> Engines(IReadOnlyList<string> tags)
    {
        var available = WinOcr.OcrEngine.AvailableRecognizerLanguages.ToList();
        var engines = new List<(Script, WinOcr.OcrEngine)>();
        foreach (var group in tags.GroupBy(ScriptOf))
        {
            Language? pick = null;
            foreach (var tag in group)
            {
                var primary = tag.Split('-')[0];
                pick = available.FirstOrDefault(l => string.Equals(l.LanguageTag, tag, StringComparison.OrdinalIgnoreCase))
                    ?? available.FirstOrDefault(l => l.LanguageTag.Split('-')[0].Equals(primary, StringComparison.OrdinalIgnoreCase));
                if (pick is not null) break;
                if (LangOf(tag) is { } missing) ImportServices.ReportMissing(missing);
            }
            pick ??= available.FirstOrDefault(l => ScriptOf(l.LanguageTag) == group.Key);
            if (pick is not null && WinOcr.OcrEngine.TryCreateFromLanguage(pick) is { } engine) engines.Add((group.Key, engine));
        }
        return engines;
    }

    /// <summary>From the straightened image back to the input: rotate by the text angle (clockwise, degrees) around the centre, then scale.</summary>
    readonly record struct Geometry(double AngleDegrees, double Cx, double Cy, double Scale)
    {
        public OcrPoint Map(double x, double y)
        {
            double a = AngleDegrees * Math.PI / 180, cos = Math.Cos(a), sin = Math.Sin(a);
            double dx = x - Cx, dy = y - Cy;
            return new OcrPoint((Cx + dx * cos - dy * sin) * Scale, (Cy + dx * sin + dy * cos) * Scale);
        }

        public OcrQuad Quad(double left, double top, double right, double bottom) =>
            new(Map(left, top), Map(right, top), Map(right, bottom), Map(left, bottom));
    }

    static OcrLine? Convert(WinOcr.OcrLine line, Script script, Geometry g)
    {
        if (line.Words.Count == 0) return null;
        var words = line.Words.Select(w => new OcrWord(w.Text, 1,
            g.Quad(w.BoundingRect.X, w.BoundingRect.Y, w.BoundingRect.X + w.BoundingRect.Width, w.BoundingRect.Y + w.BoundingRect.Height))).ToList();
        double left = line.Words.Min(w => w.BoundingRect.X), top = line.Words.Min(w => w.BoundingRect.Y);
        double right = line.Words.Max(w => w.BoundingRect.X + w.BoundingRect.Width), bottom = line.Words.Max(w => w.BoundingRect.Y + w.BoundingRect.Height);
        var text = script == Script.Chinese ? JoinCjk(line.Text) : line.Text;
        return new OcrLine(text, 1, g.Quad(left, top, right, bottom), words);
    }

    /// <summary>Windows puts a space between Chinese characters ("你 好"): removed between two CJK characters.</summary>
    internal static string JoinCjk(string text)
    {
        var sb = new System.Text.StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == ' ' && sb.Length > 0 && IsCjk(sb[^1]) && i + 1 < text.Length && IsCjk(text[i + 1])) continue;
            sb.Append(text[i]);
        }
        return sb.ToString();
    }

    static bool IsCjk(char c) => c is >= '　' and <= '鿿' or >= '豈' and <= '﫿' or >= '＀' and <= '￯';
    static bool IsArabic(char c) => c is >= '؀' and <= 'ۿ' or >= 'ݐ' and <= 'ݿ' or >= 'ﭐ' and <= '﷿' or >= 'ﹰ' and <= '﻿';

    /// <summary>
    /// One engine: its lines. Several: all lines, and where lines of two engines cover the same place, the line of the
    /// Chinese/Arabic engine when it contains that script, else the Latin one.
    /// </summary>
    static List<OcrLine> Merge(List<(Script Script, List<OcrLine> Lines)> results)
    {
        if (results.Count == 1) return results[0].Lines;
        var kept = new List<(Script Script, OcrLine Line)>();
        foreach (var (script, lines) in results)
            foreach (var line in lines)
            {
                int clash = kept.FindIndex(k => k.Script != script && Overlap(k.Line.Quad, line.Quad) > 0.5);
                if (clash < 0) { kept.Add((script, line)); continue; }
                if (Score(script, line.Text) > Score(kept[clash].Script, kept[clash].Line.Text)) kept[clash] = (script, line);
            }
        return kept.OrderBy(k => BandedTextRecognizer.Bounds(k.Line.Quad).MinY).ThenBy(k => BandedTextRecognizer.Bounds(k.Line.Quad).MinX).Select(k => k.Line).ToList();
    }

    static int Score(Script script, string text) => script switch
    {
        Script.Chinese => text.Any(IsCjk) ? 2 : 0,
        Script.Arabic => text.Any(IsArabic) ? 2 : 0,
        _ => text.Any(char.IsLetter) && !text.Any(c => IsCjk(c) || IsArabic(c)) ? 1 : 0,
    };

    static double Overlap(OcrQuad a, OcrQuad b) => BandedTextRecognizer.OverlapRatio(BandedTextRecognizer.Bounds(a), BandedTextRecognizer.Bounds(b));
}
#endif
