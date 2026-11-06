using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of PDFTextExtractorTests.swift. The Mac tests draw real PDFs and read them with PDFKit; here a
// fake IPdfDocument supplies the text layers, image probes and renders, so the extraction logic (which
// pages are text, which go through recognition, the 30-page limit, warnings, progress, cancellation)
// is tested on its own. Real-PDF layout checks (sample.pdf, rotation, Arabic/Chinese text layers)
// belong to the Windows IPdfReader implementation; PDFPageText.Items covers the shared word rules.
public class PDFTextExtractorTests
{
    public static readonly (string, string)[] TextRows =
    [
        ("le chat", "die Katze"), ("le chien", "der Hund"), ("la maison", "das Haus"), ("le jardin", "der Garten"),
    ];

    public static FakePage TextPage() => FakePdf.TablePage(TextRows);

    static readonly string TextRowLines = string.Join("\n", TextRows.Select(r => $"{r.Item1}\t{r.Item2}"));

    static PDFTextExtractor Extractor(ScriptedRecognizer recognizer, FakePdfReader? reader = null) =>
        new(reader ?? new FakePdfReader(), new OCRService(recognizer, new FakeImageDecoder()));

    // MARK: - Text layer

    [Fact]
    public async Task TableLayout()
    {
        var recognizer = ScriptedRecognizer.Unused();
        var reader = new FakePdfReader();
        var output = await Extractor(recognizer, reader).ExtractTextAsync(FakePdf.Encode(TextPage()));
        Assert.Equal(TextRowLines, output.Text);
        Assert.Empty(output.Warnings);
        Assert.Equal(0, recognizer.Calls);
        Assert.True(reader.Opened.Single().Disposed);
    }

    [Fact]
    public async Task PageJoin()
    {
        var data = FakePdf.Encode(FakePdf.TablePage(TextRows.Take(2)), FakePdf.BlankPage(), FakePdf.TablePage(TextRows.Skip(2)));
        // The blank middle page has no images, so nothing is recognised.
        var recognizer = ScriptedRecognizer.Unused();
        var output = await Extractor(recognizer).ExtractTextAsync(data);
        Assert.Equal("le chat\tdie Katze\nle chien\tder Hund\n\nla maison\tdas Haus\nle jardin\tder Garten", output.Text);
        Assert.Equal(0, recognizer.Calls);
    }

    [Fact]
    public void RightToLeftLines()
    {
        const string text = "das Buch الكتاب\nשלום\nle chat";
        Assert.True(PDFPageText.ContainsRightToLeft(text, 0, 15));
        Assert.True(PDFPageText.ContainsRightToLeft(text, 16, 20));
        Assert.False(PDFPageText.ContainsRightToLeft(text, 21, 28));
    }

    [Fact]
    public void Ligatures()
    {
        Assert.Equal("fin fleur effet", PDFPageText.ExpandingLigatures("ﬁn ﬂeur eﬀet"));
        Assert.Equal("le chat", PDFPageText.ExpandingLigatures("le chat"));
    }

    // MARK: - PDFPageText.Items (the word rules shared with the Windows PDF reader)

    [Fact]
    public void ItemsPerWordWithTrailingSpaces()
    {
        var items = FakePdf.Line("le  chat", 60, 100, size: 10);
        Assert.Equal(2, items.Count);
        Assert.Equal(new TextItem("le ", 60, 102, 5.5 * 2 * 3 / 2, 10), items[0]);
        Assert.Equal(new TextItem("chat", 60 + 4 * 5.5, 102, 4 * 5.5, 10), items[1]);
        Assert.Equal(6, PDFPageText.VisibleCharacterCount(items));
        // Lines are split at line breaks; ligatures are expanded.
        var two = PDFPageText.Items("ﬁn\r\nla rue", (loc, len) => new TextRect(loc * 6, 20, len * 6, 12));
        Assert.Equal(["fin", "la ", "rue"], two.Select(i => i.Str).ToList());
        // Ranges without geometry or with an empty box are skipped.
        Assert.Empty(PDFPageText.Items("le chat", (_, _) => null));
        Assert.Empty(PDFPageText.Items("le chat", (loc, len) => new TextRect(loc, 0, 0, 10)));
        Assert.Empty(PDFPageText.Items("", (loc, len) => new TextRect(loc, 0, len, 10)));
    }

    [Fact]
    public void ItemsSkipRotatedLines()
    {
        // A margin note written upwards: its characters march along y.
        var vertical = PDFPageText.Items("Seite 12", (loc, len) => new TextRect(560, 300 - loc * 6 - len * 6, 10, len * 6));
        Assert.Empty(vertical);
        // A slightly tilted line (0.1 rad) is kept.
        var tilted = PDFPageText.Items("le chat", (loc, len) => new TextRect(loc * 6, 100 + loc * 0.6, len * 6, 12));
        Assert.Equal(2, tilted.Count);
        // Arabic in logical order runs right to left: not mistaken for rotated text.
        const string arabic = "المدينة القديمة";
        var rtl = PDFPageText.Items(arabic, (loc, len) => new TextRect(400 - (loc + len) * 6, 100, len * 6, 12));
        Assert.Equal(2, rtl.Count);
        Assert.Equal([arabic], TextLayout.ItemsToLines(rtl));
        // The same geometry with Latin text is upside down (180°) and skipped.
        Assert.Empty(PDFPageText.Items("le chat noir", (loc, len) => new TextRect(400 - (loc + len) * 6, 100, len * 6, 12)));
    }

    // MARK: - Errors

    [Fact]
    public async Task OpenErrors()
    {
        var extractor = Extractor(ScriptedRecognizer.Unused());
        await ImportAssert.Throws(ImportErrorCode.PdfInvalid, ImportMessages.PdfInvalid,
            () => extractor.ExtractTextAsync("%PDF-1.7\nkaputt"u8.ToArray()));
        await ImportAssert.Throws(ImportErrorCode.PdfPassword, ImportMessages.PdfPassword, () => extractor.ExtractTextAsync(FakePdf.Locked));
        // Any other reader failure counts as a damaged PDF; without a reader the PDF cannot be read.
        await ImportAssert.Throws(ImportErrorCode.PdfInvalid, ImportMessages.PdfInvalid,
            () => new PDFTextExtractor(new ThrowingReader(), new OCRService(null)).ExtractTextAsync([1]));
        await ImportAssert.Throws(ImportErrorCode.PdfFailed, ImportMessages.PdfFailed,
            () => new PDFTextExtractor(null, new OCRService(null)).ExtractTextAsync(FakePdf.Encode(TextPage())));
    }

    sealed class ThrowingReader : IPdfReader
    {
        public IPdfDocument Open(byte[] data) => throw new InvalidOperationException("broken");
    }

    // MARK: - Scanned pages (tests/import-files.test.js)

    [Fact]
    public async Task ScannedFailure()
    {
        var data = FakePdf.Encode(TextPage(), FakePdf.ScannedPage());
        var progress = new ProgressLog();
        var output = await Extractor(ScriptedRecognizer.Failing()).ExtractTextAsync(data, progress: progress.Handler);
        Assert.Contains("le chat", output.Text);
        Assert.Contains("der Garten", output.Text);
        Assert.Single(output.Warnings);
        Assert.StartsWith("Seite 2 ist gescannt und konnte nicht gelesen werden", output.Warnings[0]);
        Assert.EndsWith("Versuche es später noch einmal.", output.Warnings[0]);
        Assert.Equal(ImportMessages.PdfReadPartially, progress.Messages[^1]);
    }

    [Fact]
    public async Task ScannedPagesListed()
    {
        var recognizer = ScriptedRecognizer.Failing();
        var data = FakePdf.Encode(TextPage(), FakePdf.ScannedPage(), TextPage(), FakePdf.ScannedPage());
        var output = await Extractor(recognizer).ExtractTextAsync(data);
        Assert.Single(output.Warnings);
        Assert.StartsWith("Die Seiten 2 und 4 sind gescannt und konnten nicht gelesen werden", output.Warnings[0]);
        // The first failure stops the recognition; page 4 is never tried.
        Assert.Equal(1, recognizer.Calls);
    }

    [Fact]
    public async Task PartialRecognition()
    {
        var recognizer = new ScriptedRecognizer(call => call == 0 ? FakeOCR.Table([("le vélo", "das Velo")]) : throw new RecognizerFailure());
        var data = FakePdf.Encode(TextPage(), FakePdf.ScannedPage(), TextPage(), FakePdf.ScannedPage());
        var output = await Extractor(recognizer).ExtractTextAsync(data);
        Assert.Contains("le vélo\tdas Velo", output.Text);
        Assert.Single(output.Warnings);
        Assert.StartsWith("Seite 4 ist gescannt und konnte nicht gelesen werden", output.Warnings[0]);
    }

    [Fact]
    public async Task TooManyInserts()
    {
        var recognizer = ScriptedRecognizer.Unused();
        var pages = new[] { TextPage() }.Concat(Enumerable.Range(0, 31).Select(_ => FakePdf.ScannedPage())).ToArray();
        var output = await Extractor(recognizer).ExtractTextAsync(FakePdf.Encode(pages));
        Assert.Contains("le chat", output.Text);
        Assert.Single(output.Warnings);
        Assert.StartsWith("31 Seiten sind gescannt und konnten nicht gelesen werden", output.Warnings[0]);
        Assert.Contains("30 Seiten beschränkt", output.Warnings[0]);
        Assert.Equal(0, recognizer.Calls);
    }

    [Fact]
    public async Task TooManyScannedPages()
    {
        var recognizer = ScriptedRecognizer.Unused();
        var data = FakePdf.Encode(Enumerable.Range(0, 31).Select(_ => FakePdf.ScannedPage()).ToArray());
        await ImportAssert.Throws(ImportErrorCode.PdfTooManyPages, ImportMessages.PdfTooManyPages(31), () => Extractor(recognizer).ExtractTextAsync(data));
        Assert.Equal(0, recognizer.Calls);
    }

    [Fact]
    public async Task NoWarnings()
    {
        var output = await Extractor(ScriptedRecognizer.Unused()).ExtractTextAsync(FakePdf.Encode(TextPage()));
        Assert.Contains("la maison", output.Text);
        Assert.Empty(output.Warnings);
    }

    [Fact]
    public async Task ScannedDocument()
    {
        var recognizer = new ScriptedRecognizer(call => FakeOCR.Table([($"page {call + 1}", $"Seite {call + 1}")]));
        var data = FakePdf.Encode(FakePdf.ScannedPage(), FakePdf.ScannedPage());
        var progress = new ProgressLog();
        var output = await Extractor(recognizer).ExtractTextAsync(data, ["it-IT", "de-DE"], progress.Handler);
        Assert.Equal("page 1\tSeite 1\n\npage 2\tSeite 2", output.Text);
        Assert.Equal([["it-IT", "de-DE"], ["it-IT", "de-DE"]], recognizer.Languages);
        var messages = progress.Messages;
        Assert.Equal("PDF wird geöffnet …", messages[0]);
        Assert.Contains("PDF enthält keinen Text – Texterkennung läuft …", messages);
        Assert.Contains("Seite 2 von 2 – Texterkennung läuft …", messages);
        Assert.Equal("PDF gelesen", messages[^1]);
        Assert.Equal(progress.Fractions.OrderBy(f => f).ToList(), progress.Fractions);
        Assert.Equal(1, progress.Fractions[^1]);
    }

    [Fact]
    public async Task ScannedPageKeepsItsHeaderWhenNothingIsRecognised()
    {
        // A page with a header (fewer than 40 characters) and an image: recognised, but empty.
        var header = new FakePage(FakePdf.Line("Lektion 4", 60, 60), HasImages: true);
        var output = await Extractor(new ScriptedRecognizer(_ => [])).ExtractTextAsync(FakePdf.Encode(TextPage(), header));
        Assert.Equal(TextRowLines + "\n\nLektion 4", output.Text);
        Assert.Empty(output.Warnings);
    }

    // MARK: - Cancellation

    [Fact]
    public async Task CancelWhileReading()
    {
        var data = FakePdf.Encode(TextPage(), TextPage(), TextPage());
        var progress = new ProgressLog();
        using var cts = new CancellationTokenSource();
        await ImportAssert.Aborted(() => Extractor(ScriptedRecognizer.Unused()).ExtractTextAsync(data, progress: update =>
        {
            progress.Handler(update);
            if (update.Message == "Seite 1 von 3 wird gelesen …") cts.Cancel();
        }, ct: cts.Token));
        Assert.DoesNotContain("Seite 2 von 3 wird gelesen …", progress.Messages);
    }

    [Fact]
    public async Task CancelDuringRecognition()
    {
        var recognizer = ScriptedRecognizer.Hanging();
        var reader = new FakePdfReader();
        var data = FakePdf.Encode(FakePdf.ScannedPage(), FakePdf.ScannedPage(), FakePdf.ScannedPage());
        using var cts = new CancellationTokenSource();
        var task = Extractor(recognizer, reader).ExtractTextAsync(data, ct: cts.Token);
        while (recognizer.Calls == 0) await Task.Delay(1);
        cts.Cancel();
        await ImportAssert.Aborted(() => task);
        Assert.Equal(1, recognizer.Calls);
        Assert.Single(reader.Opened.Single().Renders);
        Assert.True(reader.Opened.Single().Disposed);
    }

    [Fact]
    public async Task CancelIsNotAWarning()
    {
        var recognizer = ScriptedRecognizer.Hanging();
        using var cts = new CancellationTokenSource();
        var task = Extractor(recognizer).ExtractTextAsync(FakePdf.Encode(TextPage(), FakePdf.ScannedPage()), ct: cts.Token);
        while (recognizer.Calls == 0) await Task.Delay(1);
        cts.Cancel();
        await ImportAssert.Aborted(() => task);
    }

    // MARK: - Page probes and rendering

    [Fact]
    public async Task ImageProbeErrorsCountAsImages()
    {
        var recognizer = new ScriptedRecognizer(_ => FakeOCR.Table([("le vélo", "das Velo")]));
        var reader = new ProbeFailingReader();
        var output = await new PDFTextExtractor(reader, new OCRService(recognizer)).ExtractTextAsync(FakePdf.Encode(TextPage(), FakePdf.BlankPage()));
        Assert.EndsWith("le vélo\tdas Velo", output.Text);
        Assert.Equal(1, recognizer.Calls);
    }

    sealed class ProbeFailingReader : IPdfReader
    {
        public IPdfDocument Open(byte[] data) => new ProbeFailingDocument((FakePdfDocument)new FakePdfReader().Open(data));
    }

    sealed class ProbeFailingDocument(FakePdfDocument inner) : IPdfDocument
    {
        public int PageCount => inner.PageCount;
        public List<TextItem> Items(int pageIndex) => inner.Items(pageIndex);
        public bool PageHasImages(int pageIndex) => throw new InvalidOperationException("probe failed");
        public OcrBitmap Render(int pageIndex, double scale) => inner.Render(pageIndex, scale);
        public (double Width, double Height) PageSize(int pageIndex) => inner.PageSize(pageIndex);
        public void Dispose() => inner.Dispose();
    }

    [Fact]
    public async Task RenderScale()
    {
        Assert.True(Math.Abs(PDFPageRenderer.Scale(595, 842) - 2000.0 / 595) < 1e-9);
        Assert.Equal(1.5, PDFPageRenderer.Scale(2000, 1000));
        Assert.Equal(4, PDFPageRenderer.Scale(200, 300));
        Assert.Equal(1, PDFPageRenderer.Scale(0, 300));
        Assert.Equal((3000, 1500), PDFPageRenderer.PixelSize(2000, 1000, 1.5));
        Assert.Equal((1, 1), PDFPageRenderer.PixelSize(0.1, 0.1, 2));

        // Scanned pages are rendered at that scale (a landscape page: 2000 px wide) and
        // passed to the recognizer at their size (no extra rescaling).
        var recognizer = new ScriptedRecognizer(_ => []);
        var reader = new FakePdfReader();
        var landscape = new FakePage([], HasImages: true, Width: 842, Height: 595);
        await Extractor(recognizer, reader).ExtractTextAsync(FakePdf.Encode(landscape));
        var (page, scale) = reader.Opened.Single().Renders.Single();
        Assert.Equal(0, page);
        Assert.True(Math.Abs(scale - 2000.0 / 842) < 1e-9);
        var (w, h) = recognizer.Sizes.Single();
        Assert.True(w > h);
        Assert.True(w <= 3000 && h <= 3000);
    }

    [Fact]
    public async Task RenderFailureIsARecognitionFailure()
    {
        var reader = new RenderFailingReader();
        await ImportAssert.Throws(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed,
            () => new PDFTextExtractor(reader, new OCRService(new ScriptedRecognizer(_ => []))).ExtractTextAsync(FakePdf.Encode(FakePdf.ScannedPage())));
    }

    sealed class RenderFailingReader : IPdfReader
    {
        public IPdfDocument Open(byte[] data) => new RenderFailingDocument((FakePdfDocument)new FakePdfReader().Open(data));
    }

    sealed class RenderFailingDocument(FakePdfDocument inner) : IPdfDocument
    {
        public int PageCount => inner.PageCount;
        public List<TextItem> Items(int pageIndex) => inner.Items(pageIndex);
        public bool PageHasImages(int pageIndex) => inner.PageHasImages(pageIndex);
        public OcrBitmap Render(int pageIndex, double scale) => throw new OutOfMemoryException();
        public (double Width, double Height) PageSize(int pageIndex) => inner.PageSize(pageIndex);
        public void Dispose() => inner.Dispose();
    }
}
