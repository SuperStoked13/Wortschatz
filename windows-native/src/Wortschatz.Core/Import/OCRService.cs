namespace Wortschatz.Core;

/// <summary>
/// Port of OCRService.swift: text recognition for photos, screenshots and scanned PDF pages
/// (<c>recognizeImage</c> / <c>ocrDataToText</c> in src/import/ocr.js) on top of an
/// <see cref="ITextRecognizer"/>.
///
/// Word boxes become TextItems, the page is straightened (<see cref="TextLayout.DeskewItems"/>), rows and
/// table columns are rebuilt (<see cref="TextLayout.ItemsToLines"/>, columns separated by tabs), Chinese
/// words are joined and umlauts misread as circumflexes are restored. The Mac app wraps its Vision
/// engine in a <see cref="BandedTextRecognizer"/>; here the caller decides which recognizer to pass.
/// </summary>
public sealed class OCRService(ITextRecognizer? recognizer, IImageDecoder? decoder = null)
{
    public ITextRecognizer? Recognizer { get; } = recognizer;
    public IImageDecoder? Decoder { get; } = decoder;

    /// <summary>
    /// Recognises the text on an image file's bytes. Returns plain text lines (table columns separated by
    /// tabs), "" when nothing was found. Throws ImportError (decode, ocrFailed, aborted).
    /// </summary>
    public Task<string> RecognizeImageAsync(byte[] data, IReadOnlyList<string> languages, Action<ImportProgress>? progress = null, CancellationToken ct = default) =>
        RecognizeImageAsync(data, languages, new ProgressReporter(progress), ct);

    /// <summary>
    /// Recognises the text on a decoded image. <paramref name="rescale"/> applies <see cref="OCRImage.Scale"/>
    /// (upscaling small images); rendered PDF pages are passed at their size.
    /// </summary>
    public Task<string> RecognizeAsync(OcrBitmap image, IReadOnlyList<string> languages, bool rescale = true, Action<ImportProgress>? progress = null, CancellationToken ct = default) =>
        RecognizeAsync(image, languages, rescale, new ProgressReporter(progress), ct);

    internal async Task<string> RecognizeImageAsync(byte[] data, IReadOnlyList<string> languages, ProgressReporter reporter, CancellationToken ct)
    {
        ImportError.CheckCancellation(ct);
        reporter.Report(0, ImportMessages.PreparingImage);
        if (Decoder is null) throw new ImportError(ImportErrorCode.Decode, ImportMessages.Decode);
        // Decode first, so that unreadable files fail before any recognition work.
        var image = OCRImage.PrepareForRecognition(data, Decoder, ct);
        ImportError.CheckCancellation(ct);
        return await RecognizeAsync(image, languages, false, reporter.Slice(0.1, 0.9), ct).ConfigureAwait(false);
    }

    internal async Task<string> RecognizeAsync(OcrBitmap image, IReadOnlyList<string> languages, bool rescale, ProgressReporter reporter, CancellationToken ct)
    {
        ImportError.CheckCancellation(ct);
        reporter.Report(0, ImportMessages.Recognizing);
        if (Recognizer is null) throw new ImportError(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed);
        var prepared = rescale ? OCRImage.PrepareForRecognition(image) : image;
        IReadOnlyList<OcrLine> lines;
        try
        {
            lines = await Recognizer.RecognizeTextAsync(prepared, languages,
                fraction => reporter.Report(0.05 + 0.9 * fraction, ImportMessages.Recognizing), ct).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            throw ImportError.Wrap(error, new ImportError(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed, error), ct);
        }
        ImportError.CheckCancellation(ct);
        reporter.Report(1, ImportMessages.Recognized);
        return string.Join("\n", OCRTextAssembler.Lines(lines));
    }
}

/// <summary>The recognition languages for a set (port of <c>ocrLangsFor</c>, with BCP 47 tags).</summary>
public static class RecognitionLanguages
{
    /// <summary>
    /// The learned language first, then the translation language: French + German by default, English for
    /// "other", German alone for German. The translation language defaults to German.
    /// </summary>
    public static List<string> ForSet(Lang? termLang, Lang? defLang = Lang.De)
    {
        var term = termLang is { } t ? Tag(t) ?? "en-US" : "fr-FR";
        var definition = (defLang is { } d ? Tag(d) : null) ?? "de-DE";
        return term == definition ? [term] : [term, definition];
    }

    /// <summary>The tag for a set language; null for Other.</summary>
    public static string? Tag(Lang lang) => lang switch
    {
        Lang.Fr => "fr-FR",
        Lang.De => "de-DE",
        Lang.En => "en-US",
        Lang.Es => "es-ES",
        Lang.It => "it-IT",
        Lang.Ar => "ar-SA",
        Lang.Zh => "zh-Hans",
        _ => null,
    };
}

/// <summary>Recognised lines → text lines (port of <c>ocrDataToText</c> for word-box results).</summary>
public static class OCRTextAssembler
{
    /// <summary>
    /// Rebuilds rows and table columns from the word boxes: noise words (table rules, box drawing) are
    /// dropped, border bars glued to words are stripped, the page is straightened using the median
    /// baseline slope, Chinese words are joined without spaces and German umlauts misread as circumflexes
    /// are restored. Falls back to the plain line texts when no word box is usable.
    /// </summary>
    public static List<string> Lines(IReadOnlyList<OcrLine> recognized)
    {
        var items = new List<TextItem>();
        foreach (var line in recognized)
            foreach (var word in line.Words)
                if (Item(word) is { } item) items.Add(item);
        if (items.Count == 0)
        {
            var plain = JSCompat.Trim(string.Join("\n", recognized.Select(l => l.Text)));
            return plain.Length == 0 ? [] : OCRPostprocess.PlainTextLines(plain);
        }
        double slope = EstimateSkew(recognized);
        var lines = TextLayout.ItemsToLines(TextLayout.DeskewItems(items, slope));
        return OCRPostprocess.FixGermanUmlauts(lines.Select(OCRPostprocess.JoinCJK).ToList());
    }

    /// <summary>
    /// The slope (dy/dx, top-left origin) of the text rows: the median baseline slope of the lines (else
    /// of the words) as the starting point, refined by aligning separate pieces of text that sit side by
    /// side, such as the term and the definition cell of a table row (engine boxes follow small rotations
    /// only roughly).
    /// </summary>
    public static double EstimateSkew(IReadOnlyList<OcrLine> recognized)
    {
        double prior = TextLayout.EstimateSlope(recognized.Select(l => Baseline(l.Quad)), minWidth: 120);
        if (prior == 0) prior = TextLayout.EstimateSlope(recognized.SelectMany(l => l.Words.Select(w => Baseline(w.Quad))), minWidth: 80);
        return RefineSkew(prior, recognized.Select(Anchor.Of).OfType<Anchor>().ToList());
    }

    /// <summary>The left end of a recognised line: the middle of its left edge, its right end and height.</summary>
    internal sealed record Anchor(double X, double Y, double Right, double Height)
    {
        public static Anchor? Of(OcrLine line)
        {
            var q = line.Quad;
            if (!q.IsFinite) return null;
            double x = (q.TopLeft.X + q.BottomLeft.X) / 2;
            double y = (q.TopLeft.Y + q.BottomLeft.Y) / 2;
            double right = Math.Max(q.TopRight.X, q.BottomRight.X);
            double hx = q.TopLeft.X - q.BottomLeft.X;
            double hy = q.TopLeft.Y - q.BottomLeft.Y;
            double height = Math.Sqrt(hx * hx + hy * hy);
            if (!(height > 0) || !(right > x)) return null;
            return new Anchor(x, y, right, height);
        }
    }

    /// <summary>
    /// Searches the slope within ±0.12 of <paramref name="prior"/> that puts the most pairs of side-by-side
    /// pieces on one row (Gaussian kernel of a quarter line height, with a gentle preference for the prior).
    /// Among near-equal candidates the one whose columns are straight wins: pieces stacked in a
    /// left-aligned column move sideways by -slope per pixel downwards. Returns the prior when no two
    /// pieces sit side by side.
    /// </summary>
    internal static double RefineSkew(double prior, IReadOnlyList<Anchor> anchors)
    {
        const double window = 0.12;
        double reach = Math.Abs(prior) + window;
        var rows = new List<(double Dx, double Dy, double Sigma)>();
        var columns = new List<(double Dx, double Dy, double Sigma)>();
        for (int i = 0; i < anchors.Count; i++)
        {
            var a = anchors[i];
            for (int j = i + 1; j < anchors.Count; j++)
            {
                var b = anchors[j];
                double sigma = 0.25 * (a.Height + b.Height) / 2;
                double height = Math.Max(a.Height, b.Height);
                var (left, right) = a.X <= b.X ? (a, b) : (b, a);
                double dx = right.X - left.X;
                double dy = right.Y - left.Y;
                if (dx >= 2 * height && left.Right <= right.X && Math.Abs(dy) <= reach * dx + height)
                    rows.Add((dx, dy, sigma)); // Side by side (different columns): candidates for one row.
                else if (Math.Abs(dy) >= 1.5 * height && Math.Abs(dx) <= reach * Math.Abs(dy) + height)
                    columns.Add((dx, dy, sigma)); // Stacked: candidates for one left-aligned column.
            }
        }
        if (rows.Count == 0) return prior;

        static double KernelSum(List<(double Dx, double Dy, double Sigma)> pairs, Func<double, double, double, double> residual)
        {
            double sum = 0;
            foreach (var p in pairs)
            {
                double u = residual(p.Dx, p.Dy, p.Sigma);
                if (Math.Abs(u) < 4) sum += Math.Exp(-0.5 * u * u);
            }
            return sum;
        }

        const double step = 0.001;
        int count = (int)Math.Round(2 * window / step, MidpointRounding.AwayFromZero);
        var slopes = Enumerable.Range(0, count + 1).Select(k => prior - window + k * step).Where(s => Math.Abs(s) <= 0.35).ToList();
        var scores = slopes.Select(slope =>
        {
            double distance = (slope - prior) / 0.06;
            return KernelSum(rows, (dx, dy, sigma) => (dy - slope * dx) / sigma) * Math.Exp(-0.5 * distance * distance);
        }).ToList();
        if (scores.Count == 0) return prior;
        double best = scores.Max();
        if (!(best >= 0.5)) return prior;

        // Near-equal local maxima of the row score.
        var candidates = new List<double>();
        for (int k = 0; k < scores.Count; k++)
        {
            double score = scores[k];
            if (score < 0.6 * best) continue;
            double previous = k > 0 ? scores[k - 1] : -1;
            double next = k + 1 < scores.Count ? scores[k + 1] : -1;
            if (score >= previous && score > next) candidates.Add(slopes[k]);
        }
        double strongest = slopes[scores.IndexOf(best)];
        if (candidates.Count <= 1) return strongest;
        var straightness = candidates.Select(slope => KernelSum(columns, (dx, dy, sigma) => (dx + slope * dy) / sigma)).ToList();
        double straightest = straightness.Max();
        if (!(straightest >= 1)) return strongest;
        return candidates[straightness.IndexOf(straightest)];
    }

    /// <summary>
    /// A layout item for one word: x/y is the start of its baseline (after stripped border bars), w its
    /// length along the baseline, h its height. A trailing space (with its width) marks the word boundary
    /// for the layout.
    /// </summary>
    internal static TextItem? Item(OcrWord word)
    {
        var raw = JSCompat.Trim(word.Text);
        var leading = raw.TrimStart('|', '¦');
        var text = JSCompat.Trim(leading.TrimEnd('|', '¦'));
        if (text.Length == 0 || JSCompat.Scalars(text).All(IsNoise)) return null;
        if (double.IsFinite(word.Confidence) && word.Confidence < 0.3 && !JSCompat.Scalars(text).Any(IsLetterOrNumber)) return null;
        var q = word.Quad;
        if (!q.IsFinite) return null;
        double dx = q.BottomRight.X - q.BottomLeft.X;
        double dy = q.BottomRight.Y - q.BottomLeft.Y;
        double length = Math.Sqrt(dx * dx + dy * dy);
        double hx = q.TopLeft.X - q.BottomLeft.X;
        double hy = q.TopLeft.Y - q.BottomLeft.Y;
        double height = Math.Sqrt(hx * hx + hy * hy);
        if (!(length > 0) || !(height > 0)) return null;
        double rawLength = raw.Length;
        double textLength = text.Length;
        double per = length / Math.Max(1, rawLength);
        double lead = rawLength - leading.Length;
        double x = q.BottomLeft.X + lead * per * dx / length;
        double y = q.BottomLeft.Y + lead * per * dy / length;
        double w = Math.Max(per, textLength * per);
        return new TextItem(text + " ", x, y, w * (textLength + 1) / textLength, height);
    }

    static BaselineSegment Baseline(OcrQuad quad) => new(quad.BottomLeft.X, quad.BottomLeft.Y, quad.BottomRight.X, quad.BottomRight.Y);

    /// <summary><c>[|¦_─-▟]</c> (table rules and box drawing).</summary>
    static bool IsNoise(int u) => u is '|' or '¦' or '_' or (>= 0x2500 and <= 0x259F);

    /// <summary><c>[\p{L}\p{N}]</c></summary>
    static bool IsLetterOrNumber(int u) => JSCompat.Category(u) is
        System.Globalization.UnicodeCategory.UppercaseLetter or System.Globalization.UnicodeCategory.LowercaseLetter
        or System.Globalization.UnicodeCategory.TitlecaseLetter or System.Globalization.UnicodeCategory.ModifierLetter
        or System.Globalization.UnicodeCategory.OtherLetter or System.Globalization.UnicodeCategory.DecimalDigitNumber
        or System.Globalization.UnicodeCategory.LetterNumber or System.Globalization.UnicodeCategory.OtherNumber;
}
