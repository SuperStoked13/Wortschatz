using System.Collections.Concurrent;
using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of WortschatzImportTests/Support/TestDocuments.swift. The Mac tests draw real PDFs and images
// with CoreGraphics; here fakes of the platform seams (IPdfReader, IImageDecoder, ITextRecognizer)
// stand in for them, so the import logic is tested without Windows APIs.

/// <summary>A text recognition engine driven by a script (the stubbed tesseract of tests/import-files.test.js).</summary>
public sealed class ScriptedRecognizer(Func<int, CancellationToken, Task<IReadOnlyList<OcrLine>>> script) : ITextRecognizer
{
    int _calls;
    readonly ConcurrentQueue<List<string>> _languages = new();
    readonly ConcurrentQueue<(int Width, int Height)> _sizes = new();

    public ScriptedRecognizer(Func<int, IReadOnlyList<OcrLine>> script) : this((call, _) => Task.FromResult(script(call))) { }

    public int Calls => Volatile.Read(ref _calls);
    public List<List<string>> Languages => _languages.ToList();
    public List<(int Width, int Height)> Sizes => _sizes.ToList();

    public Task<IReadOnlyList<OcrLine>> RecognizeTextAsync(OcrBitmap image, IReadOnlyList<string> languages, Action<double>? progress, CancellationToken ct)
    {
        int call = Interlocked.Increment(ref _calls) - 1;
        _languages.Enqueue(languages.ToList());
        _sizes.Enqueue((image.Width, image.Height));
        return script(call, ct);
    }

    /// <summary>Always fails like a broken engine.</summary>
    public static ScriptedRecognizer Failing() => new(_ => throw new RecognizerFailure());

    /// <summary>Waits until cancelled (a long recognition).</summary>
    public static ScriptedRecognizer Hanging() => new(async (_, ct) =>
    {
        await Task.Delay(TimeSpan.FromSeconds(60), ct);
        return [];
    });

    /// <summary>A recognizer that must not be called.</summary>
    public static ScriptedRecognizer Unused() => new(_ => throw new Xunit.Sdk.XunitException("text recognition was not expected"));
}

public sealed class RecognizerFailure : Exception;

/// <summary>Collects progress updates (thread-safe).</summary>
public sealed class ProgressLog
{
    readonly ConcurrentQueue<ImportProgress> _updates = new();
    public Action<ImportProgress> Handler => _updates.Enqueue;
    public List<string> Messages => _updates.Select(u => u.Message).ToList();
    public List<double> Fractions => _updates.Select(u => u.Fraction).ToList();
}

/// <summary>
/// Synthetic recognition results (port of the tessWord / tessTable helpers of tests/layout.test.js):
/// 11 px per character, word boxes 22 px above to 4 px below the baseline, rows 40 px apart.
/// </summary>
public static class FakeOCR
{
    /// <summary>
    /// <paramref name="slope"/> shears the rows like the JS helper (y + slope · x). <paramref name="rotated"/>
    /// turns the whole page by atan(slope) instead; <paramref name="rectified"/> then keeps every box level
    /// at its rotated position, like engine boxes for slightly rotated photos.
    /// </summary>
    public static OcrWord Word(string text, double x, double baseline, double slope = 0, double confidence = 0.9, bool rotated = false, bool rectified = false)
    {
        double w = text.Length * 11;
        double angle = Math.Atan(slope);
        OcrPoint Turn(double px, double py) => new(px * Math.Cos(angle) - py * Math.Sin(angle), px * Math.Sin(angle) + py * Math.Cos(angle));
        OcrPoint Point(double px, double py)
        {
            if (!rotated) return new OcrPoint(px, py + slope * px);
            if (!rectified) return Turn(px, py);
            var anchor = Turn(x, baseline);
            return new OcrPoint(anchor.X + (px - x), anchor.Y + (py - baseline));
        }
        var quad = new OcrQuad(Point(x, baseline - 22), Point(x + w, baseline - 22), Point(x + w, baseline + 4), Point(x, baseline + 4));
        return new OcrWord(text, confidence, quad);
    }

    /// <summary>One recognised line per cell: the term at x 60, the definition at x 520.</summary>
    public static List<OcrLine> Table(IEnumerable<(string, string)> rows, double slope = 0, bool bars = false, bool rotated = false, bool rectified = false)
    {
        var lines = new List<OcrLine>();
        int r = 0;
        foreach (var row in rows)
        {
            double baseY = 120 + r * 40;
            foreach (var (text, x0) in new[] { (row.Item1, 60.0), (row.Item2, 520.0) })
            {
                var words = new List<OcrWord>();
                double x = x0;
                foreach (var part in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                {
                    words.Add(Word(part, x, baseY, slope, rotated: rotated, rectified: rectified));
                    x += (part.Length + 1) * 11;
                }
                if (bars && x0 == 60) words.Add(Word("|", 420, baseY, slope, confidence: 0.2));
                var quad = new OcrQuad(words[0].Quad.TopLeft, words[^1].Quad.TopRight, words[^1].Quad.BottomRight, words[0].Quad.BottomLeft);
                lines.Add(new OcrLine(text, 0.9, quad, words));
            }
            r++;
        }
        return lines;
    }
}

/// <summary>
/// A fake image file format for <see cref="FakeImageDecoder"/>: the PNG signature (so the content
/// sniffing sees an image), "FAKE", width, height and a transparency flag.
/// </summary>
public static class FakeImages
{
    static readonly byte[] PngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    public static byte[] Png(int width = 400, int height = 300, bool transparent = false) =>
    [
        .. PngSignature, .. "FAKE"u8, .. BitConverter.GetBytes(width), .. BitConverter.GetBytes(height), (byte)(transparent ? 1 : 0),
    ];
}

/// <summary>Decodes <see cref="FakeImages.Png"/> data; anything else fails with ImportError(decode).</summary>
public sealed class FakeImageDecoder : IImageDecoder
{
    public int Calls { get; private set; }

    public OcrBitmap Decode(byte[] data, double? maxPixelSize = null)
    {
        Calls++;
        if (data.Length < 21 || !data.AsSpan(8, 4).SequenceEqual("FAKE"u8)) throw new ImportError(ImportErrorCode.Decode, ImportMessages.Decode);
        int width = BitConverter.ToInt32(data, 12), height = BitConverter.ToInt32(data, 16);
        bool transparent = data[20] == 1;
        // A grey square on white (or on transparent black), like TestDocuments.blankImage.
        var bitmap = transparent ? OcrBitmap.Filled(width, height, 0, 0, 0, 0) : OcrBitmap.Filled(width, height);
        for (int y = Math.Min(40, height - 1); y < Math.Min(100, height); y++)
            for (int x = Math.Min(40, width - 1); x < Math.Min(100, width); x++)
            {
                int i = (y * width + x) * 4;
                bitmap.Pixels[i] = bitmap.Pixels[i + 1] = bitmap.Pixels[i + 2] = 217;
                bitmap.Pixels[i + 3] = 255;
            }
        return bitmap;
    }
}

/// <summary>One page of a fake PDF: its text layer, whether it paints images, its size in points.</summary>
public sealed record FakePage(List<TextItem> Items, bool HasImages = false, double Width = 595, double Height = 842);

/// <summary>
/// Fake PDF files: "%PDF-fake:&lt;id&gt;" bytes that <see cref="FakePdfReader"/> opens as the registered pages.
/// Any other bytes are damaged PDFs; <see cref="Locked"/> is a password-protected one.
/// </summary>
public static class FakePdf
{
    static readonly ConcurrentDictionary<int, FakePage[]> Documents = new();
    static int _next;

    public static readonly byte[] Locked = Encoding.ASCII.GetBytes("%PDF-locked");

    public static byte[] Encode(params FakePage[] pages)
    {
        int id = Interlocked.Increment(ref _next);
        Documents[id] = pages;
        return Encoding.ASCII.GetBytes($"%PDF-fake:{id}");
    }

    internal static FakePage[]? Pages(byte[] data)
    {
        var s = Encoding.ASCII.GetString(data);
        return s.StartsWith("%PDF-fake:", StringComparison.Ordinal) && int.TryParse(s[10..], out var id) && Documents.TryGetValue(id, out var pages)
            ? pages
            : null;
    }

    // MARK: Pages (the drawings of TestDocuments.swift as text layers)

    /// <summary>
    /// The items of one text line drawn at <paramref name="x"/> with its baseline at <paramref name="baseline"/>
    /// (top-left origin): monospace glyph boxes (0.55 em wide) run through <see cref="PDFPageText.Items"/>.
    /// </summary>
    public static List<TextItem> Line(string text, double x, double baseline, double size = 12)
    {
        double cw = size * 0.55;
        return PDFPageText.Items(text, (loc, len) => new TextRect(x + loc * cw, baseline - 0.8 * size, len * cw, size));
    }

    /// <summary>A two-column table (TestDocuments.drawTable: top 760, pitch 22, 12 pt, columns 60 and 300, A4).</summary>
    public static FakePage TablePage(IEnumerable<(string, string)> rows, double top = 760, double pitch = 22, double size = 12)
    {
        var items = new List<TextItem>();
        int i = 0;
        foreach (var row in rows)
        {
            double baseline = 842 - (top - i * pitch);
            items.AddRange(Line(row.Item1, 60, baseline, size));
            items.AddRange(Line(row.Item2, 300, baseline, size));
            i++;
        }
        return new FakePage(items);
    }

    /// <summary>A scanned page: an image over the whole page, no text layer.</summary>
    public static FakePage ScannedPage() => new([], HasImages: true);

    /// <summary>A blank page: no text, no images.</summary>
    public static FakePage BlankPage() => new([]);
}

public sealed class FakePdfReader : IPdfReader
{
    public List<FakePdfDocument> Opened { get; } = [];

    public IPdfDocument Open(byte[] data)
    {
        if (data.AsSpan().SequenceEqual(FakePdf.Locked)) throw new ImportError(ImportErrorCode.PdfPassword, ImportMessages.PdfPassword);
        var pages = FakePdf.Pages(data) ?? throw new ImportError(ImportErrorCode.PdfInvalid, ImportMessages.PdfInvalid);
        var document = new FakePdfDocument(pages);
        Opened.Add(document);
        return document;
    }
}

public sealed class FakePdfDocument(FakePage[] pages) : IPdfDocument
{
    public List<(int Page, double Scale)> Renders { get; } = [];
    public bool Disposed { get; private set; }

    public int PageCount => pages.Length;
    public List<TextItem> Items(int pageIndex) => pages[pageIndex].Items.ToList();
    public bool PageHasImages(int pageIndex) => pages[pageIndex].HasImages;
    public (double Width, double Height) PageSize(int pageIndex) => (pages[pageIndex].Width, pages[pageIndex].Height);

    public OcrBitmap Render(int pageIndex, double scale)
    {
        Renders.Add((pageIndex, scale));
        var (w, h) = PDFPageRenderer.PixelSize(pages[pageIndex].Width, pages[pageIndex].Height, scale);
        return OcrBitmap.Filled(w, h);
    }

    public void Dispose() => Disposed = true;
}

/// <summary>Files of the Mac import tests (WortschatzImportTests/Resources), read in place.</summary>
public static class ImportResources
{
    public static byte[] Read(string name) => File.ReadAllBytes(Path.Combine(Fixtures.Dir, "..", "..", "WortschatzImportTests", "Resources", name));
}

/// <summary>A fresh temporary directory, removed on Dispose.</summary>
public sealed class TempDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "WortschatzImportTests-" + Guid.NewGuid().ToString("N"));

    public TempDirectory() => Directory.CreateDirectory(Path);

    public string File(string name, byte[] data)
    {
        var file = System.IO.Path.Combine(Path, name);
        System.IO.File.WriteAllBytes(file, data);
        return file;
    }

    public void Dispose()
    {
        try { Directory.Delete(Path, true); } catch (IOException) { }
    }
}

public static class ImportAssert
{
    /// <summary>Awaits <paramref name="action"/> and checks the ImportError's code and message.</summary>
    public static async Task Throws(ImportErrorCode code, string message, Func<Task> action)
    {
        var error = await Assert.ThrowsAsync<ImportError>(action);
        Assert.Equal(code, error.Code);
        Assert.Equal(message, error.Message);
    }

    public static Task Aborted(Func<Task> action) => Throws(ImportErrorCode.Aborted, ImportMessages.Aborted, action);
}
