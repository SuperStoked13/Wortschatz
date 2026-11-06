using Wortschatz.Core;
using Xunit;
using Region = Wortschatz.Core.BandedTextRecognizer.Region;
using Size = Wortschatz.Core.BandedTextRecognizer.Size;

namespace Wortschatz.Core.Tests;

// Port of BandedTextRecognizerTests.swift.
public class BandedTextRecognizerTests
{
    static OcrLine Line(string text, double x, double y, double width = 200, double height = 30, double confidence = 1)
    {
        var quad = OcrQuad.FromRect(x, y, width, height);
        return new OcrLine(text, confidence, quad, [new OcrWord(text, confidence, quad)]);
    }

    static readonly int[] Bands = [600, 1000];

    [Fact]
    public void Regions()
    {
        Assert.Equal([new Region(0, 0, 800, 600)], BandedTextRecognizer.Regions(new Size(800, 600), Bands, 0.25, 900, 1000));

        var page = BandedTextRecognizer.Regions(new Size(900, 2000), Bands, 0.25, 900, 1000);
        Assert.Equal(new Region(0, 0, 900, 2000), page[0]);
        var bands600 = page.Where(r => r.Height == 600).ToList();
        var bands1000 = page.Where(r => r.Height == 1000).ToList();
        Assert.Equal(5, bands600.Count);
        Assert.Equal(0, bands600[0].Y);
        Assert.Equal(1400, bands600[^1].Y);
        Assert.Equal([0, 500, 1000], bands1000.Select(r => r.Y).ToList());
        // Neighbouring bands overlap by at least a quarter.
        foreach (var bands in new[] { bands600, bands1000 })
            for (int i = 0; i + 1 < bands.Count; i++) Assert.True(bands[i].Y + bands[i].Height - bands[i + 1].Y >= bands[i].Height / 4);

        Assert.Equal([new Region(0, 0, 2400, 750), new Region(0, 0, 1440, 750), new Region(960, 0, 1440, 750)],
            BandedTextRecognizer.Regions(new Size(2400, 750), Bands, 0.25, 900, 1000));
    }

    [Fact]
    public void Place()
    {
        var image = new Size(2000, 3000);
        var band = new Region(0, 1000, 2000, 600);
        Assert.Null(BandedTextRecognizer.Place(Line("oben", 100, 1, height: 30), band, image));
        Assert.Null(BandedTextRecognizer.Place(Line("unten", 100, 575, height: 24), band, image));
        var inside = BandedTextRecognizer.Place(Line("la gare", 100, 300), band, image)!;
        Assert.Equal(new OcrPoint(100, 1300), inside.Quad.TopLeft);
        Assert.Equal(new OcrPoint(100, 1330), inside.Words[0].Quad.BottomLeft);
        // The image's own edges are not cuts.
        Assert.NotNull(BandedTextRecognizer.Place(Line("Titel", 100, 0), new Region(0, 0, 2000, 600), image));
        var right = new Region(800, 0, 1200, 3000);
        Assert.Null(BandedTextRecognizer.Place(Line("das Sch", 0, 500, width: 120), right, image));
        var moved = BandedTextRecognizer.Place(Line("das Haus", 400, 500), right, image)!;
        Assert.Equal(new OcrPoint(1200, 500), moved.Quad.TopLeft);
    }

    [Fact]
    public void Merge()
    {
        List<OcrLine> lines =
        [
            Line("le chateau", 100, 100, confidence: 1),
            Line("le château", 101, 101, confidence: 0.5),
            Line("le château", 99, 100, confidence: 0.5),
            Line("das Schloss", 900, 102),
            Line("das Schloss", 902, 101),
            Line("la fille", 100, 160),
            // A column of words read as one tall line.
            Line("Heatallatalandia", 880, 150, width: 60, height: 400, confidence: 1),
        ];
        Assert.Equal(["le château", "das Schloss", "la fille"], BandedTextRecognizer.Merge(lines).Select(l => l.Text).ToList());
    }

    [Fact]
    public async Task Passes()
    {
        var baseRecognizer = new ScriptedRecognizer(_ => []);
        var recognizer = new BandedTextRecognizer(baseRecognizer);
        var progress = new List<double>();
        await recognizer.RecognizeTextAsync(OcrBitmap.Filled(1200, 1800), ["fr-FR"], progress.Add, CancellationToken.None);
        var expected = BandedTextRecognizer.Regions(new Size(1200, 1800), Bands, 0.25, 900, 1000);
        Assert.Equal(expected.Select(r => (r.Width, r.Height)).ToList(), baseRecognizer.Sizes);
        Assert.Equal(expected.Count, progress.Count);
        Assert.Equal(1, progress[^1]);
        Assert.Equal(expected.Count, baseRecognizer.Calls);
    }

    [Fact]
    public async Task PassesMergeTheirLines()
    {
        // Every pass finds the same line at the same image position: one line survives.
        var image = OcrBitmap.Filled(1200, 1800);
        var regions = BandedTextRecognizer.Regions(new Size(1200, 1800), Bands, 0.25, 900, 1000);
        var baseRecognizer = new ScriptedRecognizer(call =>
        {
            var r = regions[call];
            return [Line("la gare", 450 - r.X, 700 - r.Y)];
        });
        var lines = await new BandedTextRecognizer(baseRecognizer).RecognizeTextAsync(image, ["fr-FR"], null, CancellationToken.None);
        Assert.Single(lines);
        Assert.Equal(new OcrPoint(450, 700), lines[0].Quad.TopLeft);
    }

    [Fact]
    public async Task Cancellation()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var baseRecognizer = new ScriptedRecognizer(_ => []);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new BandedTextRecognizer(baseRecognizer).RecognizeTextAsync(OcrBitmap.Filled(1200, 1800), ["fr-FR"], null, cts.Token));
        Assert.Equal(0, baseRecognizer.Calls);
    }
}
