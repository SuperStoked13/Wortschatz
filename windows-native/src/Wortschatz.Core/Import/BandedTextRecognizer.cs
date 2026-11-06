using System.Globalization;

namespace Wortschatz.Core;

/// <summary>
/// Port of BandedTextRecognizer.swift: runs a recognizer on the whole image and on overlapping parts of
/// it, then merges the results.
///
/// Recognizers reliably miss small print on large images: on a photographed vocabulary page or a scanned
/// A4 page they often return only one of two table columns, or a few rows. Recognising full-width bands
/// of the image (two band heights, a quarter overlapping) shows the text larger, and a left and a right
/// part help wide images with far-apart columns. Duplicates are removed by geometry, preferring lines
/// confirmed by several passes; lines cut by a part's edge are ignored (another pass sees them whole).
/// </summary>
public sealed class BandedTextRecognizer(
    ITextRecognizer baseRecognizer, IReadOnlyList<int>? bandHeights = null, double overlap = 0.25, int singlePassHeight = 900,
    int splitWidth = 1000) : ITextRecognizer
{
    public ITextRecognizer Base { get; } = baseRecognizer;
    /// <summary>Band heights in pixels; each one is a separate set of overlapping bands.</summary>
    public IReadOnlyList<int> BandHeights { get; } = bandHeights ?? [600, 1000];
    /// <summary>Fraction of a band shared with the next one.</summary>
    public double Overlap { get; } = overlap;
    /// <summary>Images up to this height get a single pass.</summary>
    public int SinglePassHeight { get; } = singlePassHeight;
    /// <summary>Images at least this wide also get a left and a right pass (each 60 % of the width).</summary>
    public int SplitWidth { get; } = splitWidth;

    public async Task<IReadOnlyList<OcrLine>> RecognizeTextAsync(OcrBitmap image, IReadOnlyList<string> languages, Action<double>? progress, CancellationToken ct)
    {
        var size = new Size(image.Width, image.Height);
        var regions = Regions(size, BandHeights, Overlap, SinglePassHeight, SplitWidth);
        var pool = new List<OcrLine>();
        for (int k = 0; k < regions.Count; k++)
        {
            ct.ThrowIfCancellationRequested();
            var region = regions[k];
            bool isFull = region == new Region(0, 0, size.Width, size.Height);
            var crop = isFull ? image : image.Crop(region.X, region.Y, region.Width, region.Height);
            var lines = await Base.RecognizeTextAsync(crop, languages, null, ct).ConfigureAwait(false);
            pool.AddRange(lines.Select(l => Place(l, region, size)).OfType<OcrLine>());
            progress?.Invoke((double)(k + 1) / regions.Count);
        }
        return regions.Count == 1 ? pool : Merge(pool);
    }

    public readonly record struct Size(int Width, int Height);

    /// <summary>A part of the image (pixels, top-left origin).</summary>
    public readonly record struct Region(int X, int Y, int Width, int Height);

    /// <summary>
    /// The whole image; for tall images, for every band height, evenly spaced full-width bands that overlap
    /// by at least <paramref name="overlap"/> and cover the image from top to bottom; for wide images, a
    /// left and a right part (60 % of the width each, full height).
    /// </summary>
    public static List<Region> Regions(Size size, IReadOnlyList<int> bandHeights, double overlap, int singlePassHeight, int splitWidth)
    {
        var regions = new List<Region> { new(0, 0, size.Width, size.Height) };
        if (size.Height > singlePassHeight)
        {
            foreach (int band in bandHeights)
            {
                if (band <= 0 || band >= size.Height) continue;
                double stride = band * (1 - Math.Min(0.9, Math.Max(0, overlap)));
                int count = (int)Math.Ceiling((size.Height - band) / stride) + 1;
                double step = (double)(size.Height - band) / (count - 1);
                for (int k = 0; k < count; k++)
                    regions.Add(new Region(0, (int)Math.Round(k * step, MidpointRounding.AwayFromZero), size.Width, band));
            }
        }
        if (size.Width >= splitWidth)
        {
            int part = (int)Math.Round(size.Width * 0.6, MidpointRounding.AwayFromZero);
            regions.Add(new Region(0, 0, part, size.Height));
            regions.Add(new Region(size.Width - part, 0, part, size.Height));
        }
        return regions;
    }

    /// <summary>
    /// Moves a line found in <paramref name="region"/> into image coordinates; null when it touches a cut
    /// edge of the region (an edge that is not an edge of the image).
    /// </summary>
    public static OcrLine? Place(OcrLine line, Region region, Size image)
    {
        var box = Bounds(line.Quad);
        double margin = Math.Max(2, 0.1 * box.Height);
        if (region.Y > 0 && box.MinY < margin) return null;
        if (region.Y + region.Height < image.Height && box.MaxY > region.Height - margin) return null;
        if (region.X > 0 && box.MinX < margin) return null;
        if (region.X + region.Width < image.Width && box.MaxX > region.Width - margin) return null;
        if (region.X == 0 && region.Y == 0) return line;
        double dx = region.X, dy = region.Y;
        return line with
        {
            Quad = line.Quad.Offset(dx, dy),
            Words = line.Words.Select(w => w with { Quad = w.Quad.Offset(dx, dy) }).ToList(),
        };
    }

    /// <summary>
    /// Removes duplicates and misreads from the lines of all passes: boxes more than 2.2 × the median line
    /// height are dropped (a column of short words read as one line); every line is supported by the
    /// overlapping lines of other passes with the same text; greedily, the best-supported (then most
    /// confident, then longest) line wins and suppresses the lines it overlaps by more than 40 % of the
    /// smaller box.
    /// </summary>
    public static List<OcrLine> Merge(IReadOnlyList<OcrLine> lines)
    {
        var boxes = lines.Select(l => Bounds(l.Quad)).ToList();
        var heights = boxes.Select(b => b.Height).Where(h => h > 0).OrderBy(h => h).ToList();
        double medianHeight = heights.Count == 0 ? 0 : heights[heights.Count / 2];
        var candidates = Enumerable.Range(0, lines.Count)
            .Where(i => boxes[i].Width > 0 && boxes[i].Height > 0 && (lines.Count < 3 || boxes[i].Height <= 2.2 * medianHeight))
            .ToList();
        // Swift compares texts with ==, i.e. canonical equivalence.
        var normalized = lines.Select(l => JSCompat.Nfc(l.Text)).ToList();
        var support = candidates.Select(i =>
            candidates.Count(j => j != i && normalized[j] == normalized[i] && OverlapRatio(boxes[i], boxes[j]) > 0.4)).ToList();
        var order = Enumerable.Range(0, candidates.Count).ToList();
        order.Sort((a, b) =>
        {
            int i = candidates[a], j = candidates[b];
            if (support[a] != support[b]) return support[b].CompareTo(support[a]);
            if (lines[i].Confidence != lines[j].Confidence) return lines[j].Confidence.CompareTo(lines[i].Confidence);
            int li = new StringInfo(lines[i].Text).LengthInTextElements, lj = new StringInfo(lines[j].Text).LengthInTextElements;
            if (li != lj) return lj.CompareTo(li);
            return i.CompareTo(j);
        });
        var accepted = new List<int>();
        foreach (int k in order)
        {
            int i = candidates[k];
            if (accepted.Any(a => OverlapRatio(boxes[i], boxes[a]) > 0.4)) continue;
            accepted.Add(i);
        }
        return accepted.OrderBy(i => boxes[i].MinY).ThenBy(i => boxes[i].MinX).Select(i => lines[i]).ToList();
    }

    /// <summary>Intersection area relative to the smaller box.</summary>
    public static double OverlapRatio(TextRect a, TextRect b)
    {
        double smaller = Math.Min(a.Width * a.Height, b.Width * b.Height);
        return smaller > 0 ? a.IntersectionArea(b) / smaller : 0;
    }

    public static TextRect Bounds(OcrQuad q)
    {
        double[] xs = [q.TopLeft.X, q.TopRight.X, q.BottomRight.X, q.BottomLeft.X];
        double[] ys = [q.TopLeft.Y, q.TopRight.Y, q.BottomRight.Y, q.BottomLeft.Y];
        return new TextRect(xs.Min(), ys.Min(), xs.Max() - xs.Min(), ys.Max() - ys.Min());
    }
}
