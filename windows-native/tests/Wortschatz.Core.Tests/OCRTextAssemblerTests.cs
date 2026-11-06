using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of OCRTextAssemblerTests.swift (the ocrDataToText / imageScaleFor / ocrLangsFor cases of
// tests/layout.test.js, with engine-shaped results instead of tesseract's). The Vision-specific
// language matching (VisionSettings) is not part of the Windows core.
public class OCRTextAssemblerTests
{
    static readonly (string, string)[] Pairs =
    [
        ("le monsieur, messieurs", "der Herr"), ("l'homme", "der Mann"), ("la femme", "die Frau"),
        ("l'enfant", "das Kind"), ("le garçon", "der Junge"), ("la fille", "das Mädchen"),
    ];

    static List<string> Expected => Pairs.Select(p => $"{p.Item1}\t{p.Item2}").ToList();

    [Fact]
    public void Table() => Assert.Equal(Expected, OCRTextAssembler.Lines(FakeOCR.Table(Pairs)));

    [Fact]
    public void Skewed()
    {
        Assert.Equal(Expected, OCRTextAssembler.Lines(FakeOCR.Table(Pairs, slope: 0.05, bars: true)));
        Assert.Equal(Expected, OCRTextAssembler.Lines(FakeOCR.Table(Pairs, slope: -0.04)));
    }

    [Theory]
    [InlineData(0.035)] [InlineData(-0.035)] [InlineData(0.05)] [InlineData(-0.02)] [InlineData(0.08)] [InlineData(0.06)] [InlineData(-0.07)]
    public void RectifiedBoxes(double slope)
    {
        var lines = FakeOCR.Table(Pairs, slope: slope, rotated: true, rectified: true);
        Assert.Equal(Expected, OCRTextAssembler.Lines(lines));
        Assert.True(Math.Abs(OCRTextAssembler.EstimateSkew(lines) - slope) < 0.01, $"slope {slope}");
    }

    [Fact]
    public void SkewWithoutPairs()
    {
        var single = FakeOCR.Table(Pairs, slope: 0.04).Where(l => l.Quad.BottomLeft.X < 400).ToList();
        Assert.True(Math.Abs(OCRTextAssembler.EstimateSkew(single) - 0.04) < 1e-9);
        Assert.Equal(0, OCRTextAssembler.EstimateSkew([]));
    }

    [Fact]
    public void BorderBars()
    {
        var lines = FakeOCR.Table([("la rue", "die Strasse"), ("le nom", "der Name")]);
        var first = lines[0].Words[0];
        // "|la" with its box extended by one character to the left.
        var words = lines[0].Words.ToList();
        words[0] = FakeOCR.Word("|la", first.Quad.BottomLeft.X - 11, 120);
        lines[0] = lines[0] with { Words = words };
        Assert.Equal(["la rue\tdie Strasse", "le nom\tder Name"], OCRTextAssembler.Lines(lines));
    }

    [Fact]
    public void Noise()
    {
        var lines = FakeOCR.Table(Pairs.Take(3));
        var rule = OcrQuad.FromRect(300, 300, 200, 4);
        lines.Add(new OcrLine("───", 0.9, rule, [new OcrWord("───", 0.9, rule)]));
        var tilde = OcrQuad.FromRect(300, 140, 11, 26);
        lines.Add(new OcrLine("~", 0.1, tilde, [new OcrWord("~", 0.1, tilde)]));
        Assert.Equal(Expected.Take(3).ToList(), OCRTextAssembler.Lines(lines));
    }

    [Fact]
    public void PlainFallback()
    {
        var degenerate = OcrQuad.FromRect(10, 10, 0, 0);
        List<OcrLine> lines =
        [
            new("  le nom", 1, degenerate, [new OcrWord("le", 1, degenerate)]),
            new("der Name ", 1, degenerate, []),
        ];
        Assert.Equal(["le nom", "der Name"], OCRTextAssembler.Lines(lines));
        Assert.Empty(OCRTextAssembler.Lines([]));
        Assert.Equal(["die Tür", "la porte"], OCRTextAssembler.Lines([new OcrLine("die Tûr\nla porte", 1, degenerate, [])]));
    }

    [Fact]
    public void Umlauts() => Assert.Equal(
        ["beau, belle\tschön", "le rôle\tdie Rolle", "la porte\tdie Tür", "fatigué\tmüde"],
        OCRTextAssembler.Lines(FakeOCR.Table([("beau, belle", "schôn"), ("le rôle", "die Rolle"), ("la porte", "die Tûr"), ("fatigué", "mûde")])));

    [Fact]
    public void WordSlices()
    {
        var line = OcrLine.FromText("le chat noir", 1, OcrQuad.FromRect(100, 50, 220, 30));
        Assert.Equal(["le", "chat", "noir"], line.Words.Select(w => w.Text).ToList());
        Assert.Equal(100, line.Words[0].Quad.BottomLeft.X);
        Assert.True(Math.Abs(line.Words[2].Quad.BottomRight.X - 320) < 1e-9);
        Assert.True(line.Words[1].Quad.BottomLeft.X > line.Words[0].Quad.BottomRight.X);
        // An engine box wins when it is finite.
        var boxed = OcrLine.FromText("le chat", 1, OcrQuad.FromRect(0, 0, 70, 10), (start, length) =>
            start == 3 ? OcrQuad.FromRect(40, 0, 30, 10) : OcrQuad.FromRect(double.NaN, 0, 1, 1));
        Assert.Equal(40, boxed.Words[1].Quad.TopLeft.X);
        Assert.Equal(0, boxed.Words[0].Quad.TopLeft.X); // the NaN box falls back to the slice
    }

    [Fact]
    public void RtlWordSlices()
    {
        var line = OcrLine.FromText("ذهب الولد", 1, OcrQuad.FromRect(0, 0, 90, 20));
        Assert.Equal(["ذهب", "الولد"], line.Words.Select(w => w.Text).ToList());
        // 9 characters: the first word (logical order) is the rightmost third.
        Assert.True(Math.Abs(line.Words[0].Quad.BottomLeft.X - 60) < 1e-9);
        Assert.True(Math.Abs(line.Words[0].Quad.BottomRight.X - 90) < 1e-9);
        Assert.True(Math.Abs(line.Words[1].Quad.BottomLeft.X) < 1e-9);
        Assert.True(Math.Abs(line.Words[1].Quad.BottomRight.X - 50) < 1e-9);
        // Assembled, the words are read from right to left again.
        Assert.Equal(["ذهب الولد"], OCRTextAssembler.Lines([line]));
    }

    // MARK: - Arabic and Chinese

    [Fact]
    public void ChineseWords()
    {
        var words = new List<OcrWord>();
        double x = 60;
        foreach (var ch in new[] { "你", "好", "，", "朋", "友" })
        {
            words.Add(new OcrWord(ch, 0.9, OcrQuad.FromRect(x, 98, 22, 26)));
            x += 26;
        }
        words.AddRange([FakeOCR.Word("nǐ", 220, 120), FakeOCR.Word("hǎo", 250, 120)]);
        var line = new OcrLine("你 好 ， 朋 友 nǐ hǎo", 0.9, OcrQuad.FromRect(60, 98, 223, 26), words);
        Assert.Equal(["你好，朋友 nǐ hǎo"], OCRTextAssembler.Lines([line]));
    }

    [Fact]
    public void ChinesePlainText()
    {
        var degenerate = OcrQuad.FromRect(10, 10, 0, 0);
        Assert.Equal(["你好，朋友", "谢谢 xiè xie"], OCRTextAssembler.Lines([
            new OcrLine("你 好 ， 朋 友", 1, degenerate, []), new OcrLine("谢 谢 xiè xie", 1, degenerate, []),
        ]));
    }

    /// <summary>A recognised line of right-to-left words in logical order whose right edge is at <paramref name="right"/>.</summary>
    static OcrLine RtlLine(string text, double right, double baseline)
    {
        var words = new List<OcrWord>();
        double x1 = right;
        foreach (var w in text.Split(' '))
        {
            words.Add(FakeOCR.Word(w, x1 - w.Length * 11, baseline));
            x1 -= (w.Length + 1) * 11;
        }
        return Line(text, words, words[^1], words[0]);
    }

    /// <summary>A recognised line of left-to-right words starting at <paramref name="x"/>.</summary>
    static OcrLine LtrLine(string text, double x, double baseline)
    {
        var words = new List<OcrWord>();
        double x0 = x;
        foreach (var w in text.Split(' '))
        {
            words.Add(FakeOCR.Word(w, x0, baseline));
            x0 += (w.Length + 1) * 11;
        }
        return Line(text, words, words[0], words[^1]);
    }

    static OcrLine Line(string text, List<OcrWord> words, OcrWord leftmost, OcrWord rightmost) =>
        new(text, 0.9, new OcrQuad(leftmost.Quad.TopLeft, rightmost.Quad.TopRight, rightmost.Quad.BottomRight, leftmost.Quad.BottomLeft), words);

    [Fact]
    public void ArabicWords() =>
        Assert.Equal(["ذهب الولد إلى المدرسة"], OCRTextAssembler.Lines([RtlLine("ذهب الولد إلى المدرسة", 600, 120)]));

    [Fact]
    public void ArabicTable()
    {
        (string Ar, string De)[] rows = [("الكتاب", "das Buch"), ("القلم", "der Stift"), ("البيت", "das Haus"), ("المدرسة الجديدة", "die neue Schule")];
        var lines = new List<OcrLine>();
        for (int r = 0; r < rows.Length; r++)
        {
            double baseY = 120 + r * 40;
            lines.Add(RtlLine(rows[r].Ar, 400, baseY));
            lines.Add(LtrLine(rows[r].De, 460, baseY));
        }
        Assert.Equal(rows.Select(r => $"{r.Ar}\t{r.De}").ToList(), OCRTextAssembler.Lines(lines));
        // German on the left, Arabic on the right.
        var swapped = new List<OcrLine>();
        for (int r = 0; r < rows.Length; r++)
        {
            double baseY = 120 + r * 40;
            swapped.Add(LtrLine(rows[r].De, 60, baseY));
            swapped.Add(RtlLine(rows[r].Ar, 600, baseY));
        }
        Assert.Equal(rows.Select(r => $"{r.De}\t{r.Ar}").ToList(), OCRTextAssembler.Lines(swapped));
    }

    // MARK: - imageScaleFor

    [Fact]
    public void ImageScale()
    {
        Assert.Equal(2, OCRImage.Scale(600, 400));
        Assert.Equal(2, OCRImage.Scale(1199, 900));
        Assert.Equal(1, OCRImage.Scale(1600, 1200));
        Assert.Equal(3000, Math.Round(OCRImage.Scale(3024, 4032) * 4032));
        Assert.Equal(3000, Math.Round(OCRImage.Scale(4032, 3024) * 4032));
        // Very tall screenshot: the width stays legible, the pixel budget is respected.
        double s = OCRImage.Scale(1170, 8000);
        Assert.True(s > 1);
        Assert.True(1170 * 8000 * s * s <= 12e6 + 1);
        Assert.Equal(1, OCRImage.Scale(0, 100));
        Assert.Equal(1, OCRImage.Scale(double.NaN, 100));
        Assert.Equal(1, OCRImage.Scale(-5, 100));
    }

    [Fact]
    public void Prepare()
    {
        var decoder = new FakeImageDecoder();
        // A small transparent image is upscaled 2× and flattened onto white.
        var prepared = OCRImage.PrepareForRecognition(FakeImages.Png(800, 108, transparent: true), decoder);
        Assert.Equal(1600, prepared.Width);
        Assert.Equal(216, prepared.Height);
        Assert.Equal((255, 255, 255, 255), ((int, int, int, int))prepared.PixelAt(1, 1));
        Assert.True(Enumerable.Range(0, prepared.Pixels.Length / 4).All(i => prepared.Pixels[i * 4 + 3] == 255));
        // The grey square stays grey (scaled to 80…200).
        Assert.Equal((217, 217, 217, 255), ((int, int, int, int))prepared.PixelAt(140, 140));

        // Large images are reduced to 3000 px on the long side.
        var reduced = OCRImage.PrepareForRecognition(FakeImages.Png(4000, 3000), decoder);
        Assert.Equal(3000, reduced.Width);
        Assert.Equal(2250, reduced.Height);

        // Already decoded bitmaps at the recognition size are only flattened.
        var same = OCRImage.PrepareForRecognition(OcrBitmap.Filled(1600, 1200, 0, 0, 0, 0));
        Assert.Equal((1600, 1200), (same.Width, same.Height));
        Assert.Equal((255, 255, 255, 255), ((int, int, int, int))same.PixelAt(5, 5));
    }

    [Fact]
    public void Undecodable()
    {
        var error = Assert.Throws<ImportError>(() => OCRImage.PrepareForRecognition("kein Bild"u8.ToArray(), new FakeImageDecoder()));
        Assert.Equal(ImportErrorCode.Decode, error.Code);
        Assert.Equal(ImportMessages.Decode, error.Message);
        // Any other decoder failure becomes the same message.
        error = Assert.Throws<ImportError>(() => OCRImage.PrepareForRecognition([], new ThrowingDecoder()));
        Assert.Equal(ImportErrorCode.Decode, error.Code);
    }

    sealed class ThrowingDecoder : IImageDecoder
    {
        public OcrBitmap Decode(byte[] data, double? maxPixelSize = null) => throw new InvalidDataException("broken");
    }

    // MARK: - ocrLangsFor

    [Fact]
    public void Languages()
    {
        Assert.Equal(["fr-FR", "de-DE"], RecognitionLanguages.ForSet(Lang.Fr));
        Assert.Equal(["en-US", "de-DE"], RecognitionLanguages.ForSet(Lang.En));
        Assert.Equal(["es-ES", "de-DE"], RecognitionLanguages.ForSet(Lang.Es));
        Assert.Equal(["it-IT", "de-DE"], RecognitionLanguages.ForSet(Lang.It));
        Assert.Equal(["de-DE"], RecognitionLanguages.ForSet(Lang.De));
        Assert.Equal(["en-US", "de-DE"], RecognitionLanguages.ForSet(Lang.Other));
        Assert.Equal(["fr-FR", "de-DE"], RecognitionLanguages.ForSet(null));
        // The translation language of the set replaces German.
        Assert.Equal(["fr-FR", "en-US"], RecognitionLanguages.ForSet(Lang.Fr, Lang.En));
        Assert.Equal(["de-DE", "fr-FR"], RecognitionLanguages.ForSet(Lang.De, Lang.Fr));
        Assert.Equal(["it-IT", "de-DE"], RecognitionLanguages.ForSet(Lang.It, Lang.Other));
        Assert.Equal(["it-IT", "de-DE"], RecognitionLanguages.ForSet(Lang.It, null));
    }

    [Fact]
    public void ScriptLanguages()
    {
        Assert.Equal(["ar-SA", "de-DE"], RecognitionLanguages.ForSet(Lang.Ar));
        Assert.Equal(["zh-Hans", "de-DE"], RecognitionLanguages.ForSet(Lang.Zh));
        Assert.Equal(["de-DE", "zh-Hans"], RecognitionLanguages.ForSet(Lang.De, Lang.Zh));
    }

    // MARK: - OCRService

    [Fact]
    public async Task ServiceReportsProgressAndAssembles()
    {
        var recognizer = new ScriptedRecognizer(_ => FakeOCR.Table([("la gare", "der Bahnhof")]));
        var service = new OCRService(recognizer, new FakeImageDecoder());
        var progress = new ProgressLog();
        var text = await service.RecognizeImageAsync(FakeImages.Png(), ["fr-FR"], progress.Handler);
        Assert.Equal("la gare\tder Bahnhof", text);
        Assert.Equal([(800, 600)], recognizer.Sizes); // 400 × 300 upscaled 2×
        Assert.Equal(["Bild wird vorbereitet …", "Texterkennung läuft …", "Text erkannt"], progress.Messages);
        Assert.Equal(progress.Fractions.OrderBy(f => f).ToList(), progress.Fractions);
        // A decoded bitmap is rescaled unless told otherwise.
        await service.RecognizeAsync(OcrBitmap.Filled(500, 400), ["fr-FR"]);
        await service.RecognizeAsync(OcrBitmap.Filled(500, 400), ["fr-FR"], rescale: false);
        Assert.Equal([(800, 600), (1000, 800), (500, 400)], recognizer.Sizes);
    }

    [Fact]
    public async Task ServiceWithoutComponents()
    {
        await ImportAssert.Throws(ImportErrorCode.Decode, ImportMessages.Decode,
            () => new OCRService(new ScriptedRecognizer(_ => [])).RecognizeImageAsync(FakeImages.Png(), ["fr-FR"]));
        await ImportAssert.Throws(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed,
            () => new OCRService(null, new FakeImageDecoder()).RecognizeImageAsync(FakeImages.Png(), ["fr-FR"]));
    }
}
