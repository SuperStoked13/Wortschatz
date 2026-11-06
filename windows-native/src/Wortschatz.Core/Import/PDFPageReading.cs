namespace Wortschatz.Core;

/// <summary>
/// Port of the platform-independent part of PDFPageReading.swift: the text layer of one PDF page as
/// layout items (the counterpart of <c>toLayoutItems</c> in src/import/pdf.js): one item per word, in display
/// space with a top-left origin (page rotation and crop box applied), x = left edge, y = bottom of the
/// glyph box, h = line height. PDFKit itself is replaced by a rectangle provider, so an
/// <see cref="IPdfDocument"/> implementation can reuse the same rules.
/// </summary>
public static class PDFPageText
{
    /// <summary>Text lines rotated by more than this (radians) are skipped: margin notes, stamps.</summary>
    public const double MaxAngle = 0.2;

    /// <summary>
    /// The layout items of a page whose text (in reading order, lines separated by line breaks) is
    /// <paramref name="text"/>. <paramref name="rectOf"/> returns the display rectangle (top-left origin) of a
    /// UTF-16 character range (location, length), or null when there is no geometry for it (PDFKit's
    /// <c>selection(for:).bounds</c> mapped through the page transform).
    /// </summary>
    public static List<TextItem> Items(string text, Func<int, int, TextRect?> rectOf)
    {
        var items = new List<TextItem>();
        int lineStart = 0;
        while (lineStart < text.Length)
        {
            int lineEnd = lineStart;
            while (lineEnd < text.Length && !IsLineBreak(text[lineEnd])) lineEnd++;
            AppendItems(lineStart, lineEnd, text, rectOf, items);
            lineStart = lineEnd + 1;
        }
        return items;
    }

    /// <summary>Non-whitespace UTF-16 units of the items (JS <c>visibleChars</c>).</summary>
    public static int VisibleCharacterCount(IEnumerable<TextItem> items) =>
        items.Sum(item => item.Str.Count(c => !JSCompat.IsWhitespace(c)));

    static void AppendItems(int start, int end, string text, Func<int, int, TextRect?> rectOf, List<TextItem> items)
    {
        var words = new List<(int Lo, int Hi)>();
        int i = start;
        while (i < end)
        {
            if (JSCompat.IsWhitespace(text[i]))
            {
                i++;
                continue;
            }
            int s = i;
            while (i < end && !JSCompat.IsWhitespace(text[i])) i++;
            words.Add((s, i));
        }
        if (words.Count == 0) return;

        // Rotated text keeps its own lines; their characters march along the rotation. Lines come in
        // logical order: with right-to-left text (Arabic) the last character may sit left of the first
        // one, so only the slope counts there.
        int firstChar = words[0].Lo;
        int lastChar = words[^1].Hi - 1;
        if (lastChar > firstChar && rectOf(firstChar, 1) is { } a && rectOf(lastChar, 1) is { } b)
        {
            double dx = b.MidX - a.MidX;
            double dy = b.MidY - a.MidY;
            bool mixed = ContainsRightToLeft(text, start, end);
            if (Math.Sqrt(dx * dx + dy * dy) > 1 && Math.Abs(Math.Atan2(dy, mixed ? Math.Abs(dx) : dx)) > MaxAngle) return;
        }

        foreach (var (lo, hi) in words)
        {
            if (rectOf(lo, hi - lo) is not { } rect || !(rect.Width > 0) || !(rect.Height > 0)) continue;
            var str = ExpandingLigatures(text[lo..hi]);
            double length = str.Length;
            // A trailing space (with its width) marks the word boundary, like a space inside a pdf.js run.
            bool spaced = hi < end;
            items.Add(new TextItem(spaced ? str + " " : str, rect.MinX, rect.MaxY,
                spaced ? rect.Width * (length + 1) / length : rect.Width, rect.Height));
        }
    }

    /// <summary>Typographic ligatures (U+FB00…U+FB06) as plain letters, so "ﬁn" grades like "fin".</summary>
    public static string ExpandingLigatures(string s)
    {
        if (!s.Any(c => c is >= 'ﬀ' and <= 'ﬆ')) return s;
        var sb = new System.Text.StringBuilder(s.Length + 4);
        foreach (char c in s)
        {
            sb.Append(c switch
            {
                'ﬀ' => "ff",
                'ﬁ' => "fi",
                'ﬂ' => "fl",
                'ﬃ' => "ffi",
                'ﬄ' => "ffl",
                'ﬅ' or 'ﬆ' => "st",
                _ => c.ToString(),
            });
        }
        return sb.ToString();
    }

    /// <summary>
    /// Whether the UTF-16 range start..end of <paramref name="text"/> holds right-to-left characters (Hebrew,
    /// Arabic, … and their presentation forms; <c>RTL_CHAR</c> of layout.js).
    /// </summary>
    public static bool ContainsRightToLeft(string text, int start, int end)
    {
        for (int i = start; i < end; i++)
            if (TextLayout.IsRtlScalar(text[i])) return true;
        return false;
    }

    static bool IsLineBreak(char u) => u is '\n' or '\r' or (char)0x2028 or (char)0x2029;
}

/// <summary>Render scale for scanned pages (port of <c>PDFPageRenderer</c>, <c>renderPage</c> in src/import/pdf.js).</summary>
public static class PDFPageRenderer
{
    /// <summary>Target width in pixels; pages are rendered at scale 2…4 and at most 3000 px on the long side.</summary>
    public const double TargetWidth = 2000;
    public const double MaxSide = 3000;

    /// <summary>The render scale for a displayed page size in points.</summary>
    public static double Scale(double width, double height)
    {
        if (!(width > 0) || !(height > 0)) return 1;
        double scale = Math.Min(4, Math.Max(2, TargetWidth / width));
        return Math.Min(scale, MaxSide / Math.Max(width, height));
    }

    /// <summary>The pixel size of a page rendered at <see cref="Scale"/> (floor, at least 1).</summary>
    public static (int Width, int Height) PixelSize(double width, double height, double scale) =>
        (Math.Max(1, (int)Math.Floor(width * scale)), Math.Max(1, (int)Math.Floor(height * scale)));
}
