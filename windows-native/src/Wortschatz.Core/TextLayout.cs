using System.Globalization;
using System.Text;

namespace Wortschatz.Core;

/// <summary>
/// A positioned text fragment (from a PDF page or an OCR word box). Coordinates are top-origin:
/// <c>X</c> is the left edge, <c>Y</c> the baseline (or the bottom of the word box), <c>W</c> the width and
/// <c>H</c> the glyph/font height. Missing or non-positive <c>W</c>/<c>H</c> are estimated by
/// <see cref="TextLayout.ItemsToLines"/>; items with a non-finite <c>X</c>/<c>Y</c> are skipped by it.
/// <c>Dir</c> is the text direction of a PDF text run (pdf.js <c>dir</c>): "rtl" for a right-to-left run,
/// whose text is in logical order and starts at the right edge. Encoded only when present.
/// </summary>
public sealed record TextItem(string Str, double X, double Y, double W = 0, double H = 0, string? Dir = null) : IJsonEncodable
{
    /// <summary>A right-to-left run (<c>it.dir === 'rtl'</c>).</summary>
    public bool IsRightToLeft => Dir == "rtl";

    /// <summary>
    /// An item as JS <c>readItems</c> reads it (Swift <c>init?(json:)</c>): null when the entry is not an
    /// object, has no <c>str</c> (null or missing) or no finite <c>x</c>/<c>y</c> (numbers or numeric strings).
    /// <c>str</c> becomes <c>String(str)</c>; invalid <c>w</c>/<c>h</c> become 0. <c>dir</c> is kept when it is a string.
    /// </summary>
    public static TextItem? FromJson(JSONValue? json)
    {
        if (json?.ObjectValue is not { } o) return null;
        if (!o.TryGetValue("str", out var raw) || TextLayout.JsString(raw) is not { } str) return null;
        if (TextLayout.ToNumber(json["x"]) is not { } x || TextLayout.ToNumber(json["y"]) is not { } y) return null;
        return new TextItem(str, x, y, TextLayout.ToNumber(json["w"]) ?? 0, TextLayout.ToNumber(json["h"]) ?? 0, json["dir"]?.StringValue);
    }

    /// <summary>
    /// Lenient decoding (Swift <c>init(from:)</c>): numbers or numeric strings are accepted; <c>w</c>/<c>h</c>
    /// default to 0; missing <c>str</c>/<c>x</c>/<c>y</c> decode as ""/0.
    /// </summary>
    public static TextItem Decode(JSONValue? json) => new(
        json?["str"] is { } s ? TextLayout.JsString(s) ?? "" : "",
        TextLayout.ToNumber(json?["x"]) ?? 0,
        TextLayout.ToNumber(json?["y"]) ?? 0,
        TextLayout.ToNumber(json?["w"]) ?? 0,
        TextLayout.ToNumber(json?["h"]) ?? 0,
        json?["dir"]?.StringValue);

    public JSONValue ToJson()
    {
        var map = new JsonObjectMap
        {
            ["str"] = Str,
            ["x"] = X,
            ["y"] = Y,
            ["w"] = W,
            ["h"] = H,
        };
        if (Dir is not null) map["dir"] = Dir;
        return JSONValue.Object(map);
    }
}

/// <summary>Options of <see cref="TextLayout.ItemsToLines"/> (JS <c>opts</c>).</summary>
/// <param name="YTolerance">Row grouping tolerance as a fraction of the median glyph height (min 0.05).</param>
/// <param name="GapFactor">Horizontal gap (× char width) that splits a row into cells (min 0.5).</param>
public sealed record LayoutOptions(double YTolerance = LayoutOptions.DefaultYTolerance, double GapFactor = LayoutOptions.DefaultGapFactor)
{
    public const double DefaultYTolerance = 0.5;
    public const double DefaultGapFactor = 2.2;

    /// <summary><c>opts || {}</c>: numbers or numeric strings are taken, anything else gives the default.</summary>
    public static LayoutOptions FromJson(JSONValue? json) => new(
        TextLayout.ToNumber(json?["yTolerance"]) ?? DefaultYTolerance,
        TextLayout.ToNumber(json?["gapFactor"]) ?? DefaultGapFactor);
}

/// <summary>A text-line baseline segment <c>{ x0, y0, x1, y1 }</c> (top-origin), e.g. from OCR.</summary>
public sealed record BaselineSegment(double X0, double Y0, double X1, double Y1)
{
    /// <summary>A segment as <c>estimateSlope</c> reads it: null unless all four coordinates are finite numbers (or numeric strings).</summary>
    public static BaselineSegment? FromJson(JSONValue? json)
    {
        if (json?.ObjectValue is null) return null;
        if (TextLayout.ToNumber(json["x0"]) is not { } x0 || TextLayout.ToNumber(json["y0"]) is not { } y0
            || TextLayout.ToNumber(json["x1"]) is not { } x1 || TextLayout.ToNumber(json["y1"]) is not { } y1) return null;
        return new BaselineSegment(x0, y0, x1, y1);
    }
}

/// <summary>
/// Port of TextLayout.swift (src/import/layout.js): positioned text items (PDF text runs or OCR word
/// boxes) → plain text lines.
///
/// Pipeline: items → rows (grouped by y) → cells (split at wide horizontal gaps) → page-level column
/// model (gutters found by projecting cells onto the x axis) → reading order:
/// single column: rows top to bottom, "" at paragraph gaps; 2-column table: "term\tdefinition" per row,
/// wrapped cells merged; 4-column table: left pairs first, then right pairs; stacked pairs per column:
/// each page column top to bottom; unaligned text columns: each page column top to bottom.
///
/// Right-to-left text (Arabic, Hebrew): a cell whose letters are mostly RTL is read from right to left
/// and belongs to the column of its right edge. Han characters (Chinese) are joined without spaces.
/// C# strings are UTF-16 like JS, so lengths and indices match the JS code directly; the floating-point
/// arithmetic follows the JS expression order exactly.
/// </summary>
public static class TextLayout
{
    /// <summary>Reading-order text lines: rows top to bottom, "" at paragraph gaps, "term\tdefinition" for table rows.</summary>
    public static List<string> ItemsToLines(IReadOnlyList<TextItem> items, LayoutOptions? options = null)
    {
        options ??= new LayoutOptions();
        double yTolerance = double.IsFinite(options.YTolerance) ? options.YTolerance : LayoutOptions.DefaultYTolerance;
        double gapFactor = double.IsFinite(options.GapFactor) ? options.GapFactor : LayoutOptions.DefaultGapFactor;
        var raw = ReadItems(items);
        if (raw.Count == 0) return [];
        var metrics = Measure(raw);
        var pieces = ToPieces(raw, metrics);
        var rows = GroupRows(pieces, JsMax(0.05, yTolerance) * metrics.Height, metrics);
        foreach (var r in rows) r.Cells = BuildCells(r, metrics, JsMax(0.5, gapFactor));
        var textRows = rows.Where(r => r.Cells.Count > 0).ToList();
        double step = LineStepOf(textRows.Select(r => r.Y).ToList(), metrics.Height);
        var ctx = new Context(metrics, ParagraphFactor * step);

        var bounds = FindColumnBounds(textRows, metrics);
        if (bounds is null)
            return Tidy(EmitRows(textRows, r => string.Join("\t", r.Cells.Select(c => c.Text)), ctx));

        int k = AssignColumns(textRows, bounds);
        var cols = Enumerable.Range(0, k).Where(c => !IsMarkerColumn(textRows, c)).ToList();
        if (cols.Count == 0) cols = Enumerable.Range(0, k).ToList();
        int sentence = SentenceColumn(textRows, cols);
        if (sentence >= 0) cols = cols.Where(c => c != sentence).ToList();
        string Joined(Row r) => string.Join("\t", cols.Select(c => r.Cols[c]).Where(t => t.Length > 0));

        if (cols.Count == 1) return Tidy(EmitRows(textRows, Joined, ctx));

        int aligned = textRows.Count(r => cols.Count(c => r.Cols[c].Length > 0) >= 2);
        int withText = textRows.Count(r => cols.Any(c => r.Cols[c].Length > 0));
        List<string> lines;
        if (IsStackedPairs(textRows, cols, ctx)) lines = EmitFlow(textRows, cols, ctx);
        else if (aligned >= 2 && aligned >= 0.3 * withText)
            lines = cols.Count % 2 == 0 ? EmitTable(textRows, cols, ctx) : EmitRows(textRows, Joined, ctx);
        else if (IsIndependentFlow(textRows, cols, ctx)) lines = EmitFlow(textRows, cols, ctx);
        else lines = EmitRows(textRows, Joined, ctx);
        return Tidy(lines);
    }

    /// <summary>
    /// Median slope (dy/dx, top-origin) of the baseline segments; segments narrower than
    /// <paramref name="minWidth"/> or steeper than 0.35 are ignored, as are segments with non-finite
    /// coordinates. 0 when unknown.
    /// </summary>
    public static double EstimateSlope(IEnumerable<BaselineSegment> segments, double minWidth = 40)
    {
        var slopes = new List<double>();
        foreach (var s in segments)
        {
            if (!double.IsFinite(s.X0) || !double.IsFinite(s.Y0) || !double.IsFinite(s.X1) || !double.IsFinite(s.Y1)) continue;
            double dx = s.X1 - s.X0;
            if (dx < minWidth) continue;
            double slope = (s.Y1 - s.Y0) / dx;
            if (Math.Abs(slope) <= 0.35) slopes.Add(slope);
        }
        return slopes.Count == 0 ? 0 : Median(slopes);
    }

    /// <summary>
    /// Rotates item positions so that text lines with the given slope become horizontal (straightens
    /// slightly rotated photos before row grouping). Returns the items unchanged for a non-finite slope
    /// or |slope| &lt; 1e-4 or &gt; 0.5; items with a non-finite <c>X</c>/<c>Y</c> are kept as is.
    /// </summary>
    public static List<TextItem> DeskewItems(IReadOnlyList<TextItem> items, double slope)
    {
        if (!double.IsFinite(slope) || Math.Abs(slope) < 1e-4 || Math.Abs(slope) > 0.5) return items.ToList();
        double theta = Math.Atan(slope);
        double cosine = Math.Cos(theta);
        double sine = Math.Sin(theta);
        return items.Select(it =>
        {
            if (!double.IsFinite(it.X) || !double.IsFinite(it.Y)) return it;
            return it with { X = it.X * cosine + it.Y * sine, Y = -it.X * sine + it.Y * cosine };
        }).ToList();
    }

    // MARK: - Pipeline

    /// <summary>Gap (× char width) above which two fragments are separate words.</summary>
    const double SpaceFactor = 0.25;
    /// <summary>Vertical gap (× line step) that starts a new paragraph.</summary>
    const double ParagraphFactor = 1.8;

    sealed record RawItem(string Str, double X, double Y, double W, double H, bool Rtl);

    /// <summary>Lead/Trail: whitespace was trimmed before / after the piece inside its item (a word boundary).</summary>
    sealed record Piece(string Str, double X, double Y, double W, double H, bool Lead, bool Trail);

    /// <summary>Rtl: mostly right-to-left letters, read from right to left, anchored at the right edge.</summary>
    sealed record Cell(string Text, double X0, double X1, bool Rtl);

    sealed class Row(List<Piece> items, double sumY, double y)
    {
        public List<Piece> Items = items;
        public double SumY = sumY;
        public double Y = y;
        public double H;
        public List<Cell> Cells = [];
        /// <summary>Cell texts per page column (after AssignColumns).</summary>
        public List<string> Cols = [];
    }

    readonly record struct Metrics(double Height, double CharW);

    readonly record struct Context(Metrics Metrics, double Paragraph);

    // MARK: Items

    static List<RawItem> ReadItems(IReadOnlyList<TextItem> items)
    {
        var raw = new List<RawItem>();
        foreach (var it in items)
        {
            var str = Cleaned(it.Str);
            if (JSCompat.Trim(str).Length == 0) continue;
            if (!double.IsFinite(it.X) || !double.IsFinite(it.Y)) continue;
            double w = double.IsFinite(it.W) && it.W > 0 ? it.W : 0;
            double h = double.IsFinite(it.H) && it.H > 0 ? it.H : 0;
            raw.Add(new RawItem(str, it.X, it.Y, w, h, it.IsRightToLeft));
        }
        return raw;
    }

    /// <summary>Removes <c>INVISIBLE</c> characters and turns <c>ODD_SPACES</c> into plain spaces.</summary>
    static string Cleaned(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s)
        {
            switch (c)
            {
                case '\u00AD' or (>= '\u200B' and <= '\u200D') or '\u2060' or '\uFEFF':
                    continue;
                case '\u00A0' or '\u1680' or (>= '\u2000' and <= '\u200A') or '\u202F' or '\u205F' or '\u3000':
                    sb.Append(' ');
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    static Metrics Measure(List<RawItem> raw)
    {
        double height = OrIfFalsy(Median(raw.Where(r => r.H > 0).Select(r => r.H).ToList()), 10);
        var widths = raw.Where(r => r.W > 0).Select(r => r.W / r.Str.Length).ToList();
        double charW = OrIfFalsy(Median(widths), height * 0.5);
        return new Metrics(height, charW);
    }

    /// <summary>
    /// Fills missing sizes, then splits every item into visible pieces: leading and trailing whitespace
    /// is trimmed (remembered as word boundaries) and runs of tabs / 3+ spaces inside one item become
    /// separate pieces (monospace columns). A right-to-left item starts at its right edge.
    /// </summary>
    static List<Piece> ToPieces(List<RawItem> raw, Metrics metrics)
    {
        var pieces = new List<Piece>();
        foreach (var it in raw)
        {
            int n = it.Str.Length;
            double length = n;
            double h = OrIfFalsy(it.H, metrics.Height);
            double w = OrIfFalsy(it.W, length * metrics.CharW * (h / metrics.Height));
            double cw = w / length;
            foreach (var (lo, hi) in PieceRanges(it.Str))
            {
                pieces.Add(new Piece(
                    it.Str[lo..hi],
                    it.Rtl ? it.X + (n - hi) * cw : it.X + lo * cw,
                    it.Y,
                    (hi - lo) * cw,
                    h,
                    lo > 0,
                    hi < n));
            }
        }
        return pieces;
    }

    /// <summary>
    /// The matches of <c>PIECE = /[^\s]+(?: {1,2}[^\s]+)*/g</c>: a word followed by single or double spaces
    /// stays one piece; tabs, other whitespace or 3+ spaces split.
    /// </summary>
    static List<(int Lo, int Hi)> PieceRanges(string u)
    {
        var output = new List<(int, int)>();
        int n = u.Length;
        int i = 0;
        while (i < n)
        {
            if (JSCompat.IsWhitespace(u[i]))
            {
                i++;
                continue;
            }
            int start = i;
            while (i < n && !JSCompat.IsWhitespace(u[i])) i++;
            while (i < n && u[i] == ' ')
            {
                // two spaces; one space would leave a space as the next unit
                int next = i + 1 < n && u[i + 1] == ' ' ? i + 2 : i + 1;
                if (!(next < n && !JSCompat.IsWhitespace(u[next]))) break;
                i = next;
                while (i < n && !JSCompat.IsWhitespace(u[i])) i++;
            }
            output.Add((start, i));
        }
        return output;
    }

    // MARK: Rows and cells

    static List<Row> GroupRows(List<Piece> pieces, double tolerance, Metrics metrics)
    {
        var sorted = StableSorted(pieces, (a, b) =>
        {
            if (a.Y < b.Y) return -1;
            if (a.Y > b.Y) return 1;
            return a.X < b.X ? -1 : a.X > b.X ? 1 : 0;
        });
        var rows = new List<Row>();
        foreach (var it in sorted)
        {
            if (rows.Count > 0 && it.Y - rows[^1].Y <= tolerance)
            {
                var last = rows[^1];
                last.Items.Add(it);
                last.SumY += it.Y;
                last.Y = last.SumY / last.Items.Count;
            }
            else rows.Add(new Row([it], it.Y, it.Y));
        }
        foreach (var r in rows)
        {
            var byX = StableSorted(r.Items, (a, b) => a.X < b.X ? -1 : a.X > b.X ? 1 : 0);
            r.Items = Dedupe(byX, metrics.CharW * 0.5);
            r.H = Median(r.Items.Select(p => p.H).ToList());
        }
        return rows;
    }

    /// <summary>Some PDFs fake bold text by drawing the same string twice with a tiny offset.</summary>
    static List<Piece> Dedupe(List<Piece> items, double maxShift)
    {
        var output = new List<Piece>();
        foreach (var it in items)
            if (!output.Any(o => JSCompat.Identical(o.Str, it.Str) && Math.Abs(o.X - it.X) < maxShift)) output.Add(it);
        return output;
    }

    static List<Cell> BuildCells(Row row, Metrics metrics, double gapFactor)
    {
        double cw = metrics.CharW * Clamp(row.H / metrics.Height, 0.6, 3);
        double tabGap = gapFactor * cw;
        double spaceGap = SpaceFactor * cw;
        var cells = new List<(List<Piece> Items, double X0, double X1)>();
        foreach (var it in row.Items)
        {
            if (cells.Count > 0 && it.X - cells[^1].X1 <= tabGap)
            {
                var last = cells[^1];
                last.Items.Add(it);
                cells[^1] = (last.Items, last.X0, JsMax(last.X1, it.X + it.W));
                continue;
            }
            cells.Add(([it], it.X, it.X + it.W));
        }
        return cells
            .Select(c =>
            {
                bool rtl = IsRtlText(string.Concat(c.Items.Select(p => p.Str)));
                var text = JSCompat.Trim(CollapseWhitespace(CellText(c.Items, rtl, spaceGap)));
                return new Cell(text, c.X0, c.X1, rtl);
            })
            .Where(c => c.Text.Length > 0)
            .ToList();
    }

    /// <summary>
    /// The pieces of one cell in reading order (right to left for RTL text). A gap wider than a space or
    /// a word boundary inside an item becomes a space, except between two Han characters.
    /// </summary>
    static string CellText(List<Piece> items, bool rtl, double spaceGap)
    {
        var order = rtl ? Enumerable.Reverse(items).ToList() : items;
        var text = new StringBuilder(order[0].Str);
        double edge = rtl ? order[0].X : order[0].X + order[0].W; // where the text read so far ends
        bool trail = order[0].Trail;
        bool endsHan = EndsWithHan(order[0].Str);
        foreach (var it in order.Skip(1))
        {
            double gap = rtl ? edge - (it.X + it.W) : it.X - edge;
            bool space = (trail || it.Lead || gap > spaceGap) && !(endsHan && StartsWithHan(it.Str));
            if (space) text.Append(' ');
            text.Append(it.Str);
            endsHan = EndsWithHan(it.Str);
            edge = rtl ? JsMin(edge, it.X) : JsMax(edge, it.X + it.W);
            trail = it.Trail;
        }
        return text.ToString();
    }

    /// <summary>
    /// Typical baseline-to-baseline distance of consecutive lines. The lower quartile is used so that
    /// frequent paragraph gaps (e.g. "term, definition, blank line" lists) do not inflate it.
    /// </summary>
    static double LineStepOf(List<double> ys, double height)
    {
        var pitches = new List<double>();
        for (int i = 1; i < ys.Count; i++)
        {
            double d = ys[i] - ys[i - 1];
            if (d > 0.75 * height) pitches.Add(d);
        }
        if (pitches.Count >= 3) return LowerQuartile(pitches);
        // Two pitches: the smaller one is the line step (equal ones mean uniform spacing).
        if (pitches.Count == 2) return JsMin(pitches[0], pitches[1]);
        // A single pitch cannot be compared: assume a normal leading.
        return JsMin(pitches.Count > 0 ? pitches[0] : double.PositiveInfinity, 1.25 * height);
    }

    // MARK: Column model

    /// <summary>
    /// Projects all cells onto the x axis and looks for gutters: x ranges that (almost) no cell covers and
    /// that have cells starting to their right. Returns the boundaries between columns, or null for a
    /// single column.
    /// </summary>
    static List<double>? FindColumnBounds(List<Row> rows, Metrics metrics)
    {
        var cells = rows.SelectMany(r => r.Cells).ToList();
        if (cells.Count < 4) return null;
        double xMin = double.PositiveInfinity;
        double xMax = double.NegativeInfinity;
        foreach (var c in cells)
        {
            xMin = JsMin(xMin, c.X0);
            xMax = JsMax(xMax, c.X1);
        }
        double span = xMax - xMin;
        if (!(span > 0)) return null;
        double binW = JsMax(metrics.CharW * 0.5, span / 4000);
        // binW >= span / 4000, so nb <= 4002 for every finite span; the guard only protects against
        // overflowing coordinates (where the JS typed arrays would be empty or throw).
        double nbValue = Math.Floor(span / binW) + 2;
        if (!double.IsFinite(nbValue) || !(nbValue >= 2) || !(nbValue <= 1_000_000)) return null;
        int nb = (int)nbValue;
        var cover = new int[nb];
        var starts = new int[nb];
        foreach (var c in cells)
        {
            double b0Value = Math.Floor((c.X0 - xMin) / binW);
            double b1Value = JsMax(b0Value, Math.Ceiling((c.X1 - xMin) / binW) - 1);
            if (!double.IsFinite(b0Value) || !double.IsFinite(b1Value) || !(b0Value >= 0)) continue;
            int b0 = (int)Math.Min(b0Value, nbValue);
            int b1 = (int)Math.Min(b1Value, nbValue);
            // Right-to-left text starts at the right edge (right-aligned columns have ragged left edges).
            int start = c.Rtl ? b1 : b0;
            if (start < nb) starts[start]++;
            for (int bb = b0; bb <= b1 && bb < nb; bb++) cover[bb]++;
        }
        int textRows = rows.Count(r => r.Cells.Count > 0);
        int allowed = Math.Max(1, (int)Math.Floor(textRows * 0.12));
        double minWidth = JsMax(1, JSCompat.Round(metrics.CharW / binW));

        // Starts to the right of each bin (suffix sums) to reject trailing runs.
        var startsAfter = new int[nb + 1];
        for (int bb = nb - 1; bb >= 0; bb--) startsAfter[bb] = startsAfter[bb + 1] + starts[bb];

        var bounds = new List<double>();
        int b = 0;
        while (b < nb)
        {
            if (cover[b] > allowed || starts[b] > 0)
            {
                b++;
                continue;
            }
            int e = b;
            while (e + 1 < nb && cover[e + 1] <= allowed && starts[e + 1] == 0) e++;
            bool hasLeft = b > 0;
            bool hasRight = startsAfter[e + 1] > 0;
            if (hasLeft && hasRight && e - b + 1 >= minWidth) bounds.Add(xMin + ((double)(b + e + 1) / 2) * binW);
            b = e + 1;
        }
        if (bounds.Count == 0) return null;
        return PruneBounds(bounds, cells);
    }

    static int ColumnIndex(List<double> bounds, double x)
    {
        int i = 0;
        while (i < bounds.Count && x >= bounds[i]) i++;
        return i;
    }

    /// <summary>A cell belongs to the column of the edge its text starts at.</summary>
    static double AnchorX(Cell cell) => cell.Rtl ? cell.X1 : cell.X0;

    /// <summary>
    /// Drops columns that only a handful of cells start in (stray page numbers, one indented line, …) by
    /// merging them into a neighbour.
    /// </summary>
    static List<double>? PruneBounds(List<double> bounds, List<Cell> cells)
    {
        var bs = new List<double>(bounds);
        while (true)
        {
            if (bs.Count == 0) return null;
            var counts = new int[bs.Count + 1];
            foreach (var c in cells) counts[ColumnIndex(bs, AnchorX(c))]++;
            int maximum = counts.Max();
            int minStarts = Math.Max(2, (int)Math.Ceiling(maximum * 0.2));
            int weakest = -1;
            for (int i = 0; i < counts.Length; i++)
                if (counts[i] < minStarts && (weakest < 0 || counts[i] < counts[weakest])) weakest = i;
            if (weakest < 0) return bs;
            // Remove the boundary on the weak column's left (or right for the first column).
            bs.RemoveAt(weakest == 0 ? 0 : weakest - 1);
        }
    }

    static int AssignColumns(List<Row> rows, List<double> bounds)
    {
        int k = bounds.Count + 1;
        foreach (var r in rows)
        {
            var parts = Enumerable.Range(0, k).Select(_ => new List<string>()).ToList();
            foreach (var c in r.Cells) parts[ColumnIndex(bounds, AnchorX(c))].Add(c.Text);
            // Several cells in one column are read like the pieces of a cell.
            r.Cols = parts.Select(p =>
            {
                if (p.Count == 0) return "";
                if (IsRtlText(string.Concat(p)))
                {
                    var acc = p[^1];
                    for (int i = p.Count - 2; i >= 0; i--) acc = JoinWords(acc, p[i]);
                    return acc;
                }
                var text = p[0];
                for (int i = 1; i < p.Count; i++) text = JoinWords(text, p[i]);
                return text;
            }).ToList();
        }
        return k;
    }

    static bool IsMarkerColumn(List<Row> rows, int c)
    {
        var values = rows.Select(r => r.Cols[c]).Where(t => t.Length > 0).ToList();
        if (values.Count < 2) return false;
        int markers = values.Count(IsMarker);
        return markers >= values.Count * 0.8;
    }

    /// <summary>
    /// <c>MARKER = /^(?:\(?\d{1,4}[.)]?|\(?[a-zA-Z][.)]|[•▪◦·∙●○■□►▸‣⁃*–—-])$/</c>: a list number, letter or
    /// bullet on its own.
    /// </summary>
    static bool IsMarker(string u)
    {
        if (u.Length == 1 && Bullets.Contains(u[0])) return true;
        int i = 0;
        if (i < u.Length && u[i] == '(') i++;
        // \d{1,4}[.)]?
        int j = i;
        while (j < u.Length && u[j] is >= '0' and <= '9') j++;
        int digits = j - i;
        if (digits >= 1 && digits <= 4)
        {
            if (j == u.Length) return true;
            if (j + 1 == u.Length && (u[j] == '.' || u[j] == ')')) return true;
        }
        // [a-zA-Z][.)]
        return i + 2 == u.Length && IsAsciiLetter(u[i]) && (u[i + 1] == '.' || u[i + 1] == ')');
    }

    static readonly HashSet<char> Bullets =
    [
        '•', '▪', '◦', '·', '∙', '●', '○', '■', '□', '►', '▸', '‣', '⁃',
        '*', '–', '—', '-',
    ];

    static int WordCount(string s)
    {
        int count = 0;
        bool inWord = false;
        foreach (char c in s)
        {
            if (JSCompat.IsWhitespace(c)) inWord = false;
            else if (!inWord)
            {
                inWord = true;
                count++;
            }
        }
        return count;
    }

    /// <summary>
    /// In a term | example sentence | translation table, the sentence column is clearly wordier than the
    /// other two and is not useful for flash cards. -1 when there is none.
    /// </summary>
    static int SentenceColumn(List<Row> rows, List<int> cols)
    {
        if (cols.Count != 3) return -1;
        var avg = cols.Select(c =>
        {
            var values = rows.Select(r => r.Cols[c]).Where(t => t.Length > 0).ToList();
            return values.Count == 0 ? 0 : (double)values.Sum(WordCount) / values.Count;
        }).ToList();
        var candidates = Enumerable.Range(0, avg.Count)
            .Where(i => avg[i] >= 4 && Enumerable.Range(0, avg.Count).All(j => j == i || avg[i] >= 2 * avg[j]))
            .ToList();
        return candidates.Count == 1 ? cols[candidates[0]] : -1;
    }

    // MARK: Layout classification

    static List<Row> ColumnLines(List<Row> rows, int c) => rows.Where(r => r.Cols[c].Length > 0).ToList();

    static List<List<Row>> BlocksOf(List<Row> lines, double paragraph)
    {
        var blocks = new List<List<Row>>();
        double prevY = 0;
        foreach (var row in lines)
        {
            if (blocks.Count == 0 || row.Y - prevY > paragraph) blocks.Add([]);
            blocks[^1].Add(row);
            prevY = row.Y;
        }
        return blocks;
    }

    /// <summary>"term / definition / gap" pairs laid out in several page columns.</summary>
    static bool IsStackedPairs(List<Row> rows, List<int> cols, Context ctx)
    {
        int checkedCount = 0;
        foreach (int c in cols)
        {
            var lines = ColumnLines(rows, c);
            if (lines.Count < 4) continue;
            var blocks = BlocksOf(lines, ctx.Paragraph);
            int pairs = blocks.Count(b => b.Count == 2);
            if (blocks.Count < 3 || pairs < blocks.Count * 0.75) return false;
            checkedCount++;
        }
        return checkedCount >= 2;
    }

    /// <summary>Text columns whose lines do not line up (different leading or offsets).</summary>
    static bool IsIndependentFlow(List<Row> rows, List<int> cols, Context ctx)
    {
        var ranges = new List<(double A, double B)>();
        foreach (int c in cols)
        {
            var lines = ColumnLines(rows, c);
            if (lines.Count < 3) continue;
            double step = LineStepOf(lines.Select(r => r.Y).ToList(), ctx.Metrics.Height);
            if (step > 2 * ctx.Metrics.Height) return false;
            ranges.Add((lines[0].Y, lines[^1].Y));
        }
        if (ranges.Count < 2) return false;
        // JS: ranges.sort((a, b) => b[1] - b[0] - (a[1] - a[0])), longest first, stable.
        ranges = StableSorted(ranges, (a, b) =>
        {
            double d = (b.B - b.A) - (a.B - a.A);
            return d < 0 ? -1 : d > 0 ? 1 : 0;
        });
        var (r1, r2) = (ranges[0], ranges[1]);
        double overlap = JsMin(r1.B, r2.B) - JsMax(r1.A, r2.A);
        return overlap >= 0.5 * JsMax(1e-6, r2.B - r2.A);
    }

    // MARK: Emitters

    static List<string> EmitRows(List<Row> rows, Func<Row, string> textOf, Context ctx)
    {
        var output = new List<string>();
        double? prevY = null;
        foreach (var row in rows)
        {
            var text = textOf(row);
            if (text.Length == 0) continue;
            if (prevY is { } p && row.Y - p > ctx.Paragraph) output.Add("");
            output.Add(text);
            prevY = row.Y;
        }
        return output;
    }

    static List<string> EmitFlow(List<Row> rows, List<int> cols, Context ctx)
    {
        var output = new List<string>();
        foreach (int c in cols)
        {
            var lines = EmitRows(rows, r => r.Cols[c], ctx);
            if (lines.Count == 0) continue;
            if (output.Count > 0) output.Add("");
            output.AddRange(lines);
        }
        return output;
    }

    static string JoinWrapped(string a, string b)
    {
        if (a.Length == 0) return b;
        return a[^1] == '-' ? a + b : JoinWords(a, b);
    }

    /// <summary><c>WRAP_END = /[,;:\-–(/]$/</c></summary>
    static bool EndsWithWrapMark(string s) =>
        s.Length > 0 && s[^1] is ',' or ';' or ':' or '-' or '–' or '(' or '/';

    static bool EndsOpen(string s) => EndsWithWrapMark(s) || EndsWithOpenWord(s);

    /// <summary>
    /// Typical distance between two consecutive rows that both fill columns a and b. Unlike the row pitch
    /// it is not inflated by wrapped lines in between.
    /// </summary>
    static double FullRowGap(List<Row> rows, int a, int b)
    {
        var filled = rows.Where(r => r.Cols[a].Length > 0 || r.Cols[b].Length > 0).ToList();
        var gaps = new List<double>();
        for (int i = 1; i < filled.Count; i++)
        {
            var (p, r) = (filled[i - 1], filled[i]);
            if (p.Cols[a].Length > 0 && p.Cols[b].Length > 0 && r.Cols[a].Length > 0 && r.Cols[b].Length > 0) gaps.Add(r.Y - p.Y);
        }
        return gaps.Count >= 2 ? Median(gaps) : double.PositiveInfinity;
    }

    sealed class Entry(string a, string b, double lastY, bool gapBefore)
    {
        public string A = a;
        public string B = b;
        public double LastY = lastY;
        public readonly bool GapBefore = gapBefore;
    }

    /// <summary>
    /// Both cells of a row wrapped onto one tighter line ("s'entendre bien avec | sich mit jdm gut" +
    /// "qn | verstehen"). Each side must read as a continuation, two articles ("la femme | die Frau") start
    /// a new entry, and the row needs an open ending or a clearly tighter gap, so that lowercase entries
    /// ("manger | essen") at a slightly uneven pitch stay separate rows.
    /// </summary>
    static bool ContinuesBoth(Entry prev, string ta, string tb, double gap, double rowGap)
    {
        if (!double.IsFinite(rowGap) || !(gap < 0.85 * rowGap)) return false;
        if (StartsEntry(ta) && StartsEntry(tb)) return false;
        static bool Continues(string before, string next) => StartsLower(next) || EndsOpen(before);
        if (!Continues(prev.A, ta) || !Continues(prev.B, tb)) return false;
        return EndsOpen(prev.A) || EndsOpen(prev.B) || gap < 0.7 * rowGap;
    }

    static List<string> EmitTable(List<Row> rows, List<int> cols, Context ctx)
    {
        var output = new List<string>();
        for (int g = 0; g + 1 < cols.Count; g += 2)
        {
            int a = cols[g];
            int b = cols[g + 1];
            var complete = rows.Where(r => r.Cols[a].Length > 0 && r.Cols[b].Length > 0).Select(r => r.Y).ToList();
            double rowPitch = complete.Count >= 2
                ? Median(Enumerable.Range(1, complete.Count - 1).Select(i => complete[i] - complete[i - 1]).ToList())
                : double.PositiveInfinity;
            double rowGap = FullRowGap(rows, a, b);
            var entries = new List<Entry>();
            foreach (var row in rows)
            {
                var ta = row.Cols[a];
                var tb = row.Cols[b];
                if (ta.Length == 0 && tb.Length == 0) continue;
                var prev = entries.Count > 0 ? entries[^1] : null;
                double gap = prev is not null ? row.Y - prev.LastY : double.PositiveInfinity;
                bool near = gap <= ctx.Paragraph;
                if (prev is not null && near)
                {
                    if (ta.Length == 0 && tb.Length > 0)
                    {
                        prev.B = JoinWrapped(prev.B, tb);
                        prev.LastY = row.Y;
                        continue;
                    }
                    if (ta.Length > 0 && tb.Length == 0 && prev.A.Length > 0 && prev.B.Length > 0)
                    {
                        bool tighter = gap < 0.85 * rowPitch;
                        if (EndsWithWrapMark(prev.A) || (tighter && StartsLower(ta)))
                        {
                            prev.A = JoinWrapped(prev.A, ta);
                            prev.LastY = row.Y;
                            continue;
                        }
                    }
                    if (ta.Length > 0 && tb.Length > 0 && prev.A.Length > 0 && prev.B.Length > 0
                        && ContinuesBoth(prev, ta, tb, gap, rowGap))
                    {
                        prev.A = JoinWrapped(prev.A, ta);
                        prev.B = JoinWrapped(prev.B, tb);
                        prev.LastY = row.Y;
                        continue;
                    }
                }
                entries.Add(new Entry(ta, tb, row.Y, prev is not null && !near));
            }
            if (entries.Count == 0) continue;
            if (output.Count > 0) output.Add("");
            foreach (var e in entries)
            {
                if (e.GapBefore) output.Add("");
                output.Add(e.A.Length > 0 && e.B.Length > 0 ? $"{e.A}\t{e.B}" : e.A.Length == 0 ? e.B : e.A);
            }
        }
        return output;
    }

    /// <summary>
    /// Collapses runs of spaces, removes spaces around tabs, trims, keeps single blank lines between
    /// blocks and drops trailing ones.
    /// </summary>
    static List<string> Tidy(List<string> lines)
    {
        var output = new List<string>();
        foreach (var line in lines)
        {
            var t = JSCompat.Trim(TightenTabs(CollapseSpaces(line)));
            if (t.Length == 0)
            {
                if (output.Count > 0 && output[^1].Length > 0) output.Add("");
            }
            else output.Add(t);
        }
        while (output.Count > 0 && output[^1].Length == 0) output.RemoveAt(output.Count - 1);
        return output;
    }

    // MARK: - Word lists (case-insensitive like the JS `/iu` regexes)

    /// <summary><c>OPEN_END</c>: a cell ending in an article, preposition or object placeholder continues on the next line.</summary>
    static readonly int[][] OpenEndWords = new[]
    {
        "le", "la", "les", "l'", "un", "une", "des", "du", "de", "d'", "à", "au", "aux", "en", "et", "ou", "avec",
        "pour", "sur", "dans", "par", "chez", "der", "die", "das", "den", "dem", "ein", "eine", "einen", "einem",
        "einer", "und", "oder", "mit", "von", "für", "auf", "zu", "zum", "zur", "im", "am", "in", "über", "bei", "jdm",
        "jdn", "jds", "etw", "sich", "the", "a", "to", "of", "and", "or", "with", "for", "from", "into",
    }.Select(w => JSCompat.Scalars(w).ToArray()).ToArray();

    /// <summary>The article alternatives of <c>ENTRY_START</c> (each followed by whitespace).</summary>
    static readonly int[][] EntryStartWords = new[]
    {
        "le", "la", "les", "un", "une", "des", "du", "der", "die", "das", "den", "dem", "ein", "eine", "the", "a",
        "an", "to", "el", "los", "las", "il", "lo", "gli", "uno", "una",
    }.Select(w => JSCompat.Scalars(w).ToArray()).ToArray();

    /// <summary><c>OPEN_END = /(?:^|\s)(?:le|la|…|into)$/iu</c></summary>
    static bool EndsWithOpenWord(string s)
    {
        var u = JSCompat.Scalars(s).Select(CaseFold).ToArray();
        return OpenEndWords.Any(w =>
        {
            if (u.Length < w.Length || !u.AsSpan(u.Length - w.Length).SequenceEqual(w)) return false;
            return u.Length == w.Length || JSCompat.IsWhitespace(u[u.Length - w.Length - 1]);
        });
    }

    /// <summary><c>ENTRY_START = /^(?:(?:le|la|…|una)\s|l')/iu</c></summary>
    static bool StartsEntry(string s)
    {
        var u = JSCompat.Scalars(s).Select(CaseFold).ToArray();
        if (u.Length >= 2 && u[0] == 'l' && u[1] == '\'') return true;
        return EntryStartWords.Any(w => u.Length > w.Length && u.AsSpan(0, w.Length).SequenceEqual(w) && JSCompat.IsWhitespace(u[w.Length]));
    }

    /// <summary>
    /// <c>Canonicalize</c> of a <c>/iu</c> regex restricted to the scalars that fold onto a pattern letter of the
    /// word lists (verified against JavaScriptCore over all code points): A-Z, À, Ü, the long s (U+017F)
    /// and the Kelvin sign (U+212A).
    /// </summary>
    static int CaseFold(int u) => u switch
    {
        >= 0x41 and <= 0x5A or 0xC0 or 0xDC => u + 0x20,
        0x17F => 's',
        0x212A => 'k',
        _ => u,
    };

    /// <summary><c>STARTS_LOWER = /^[(\[]?[a-zà-ÿœæ]/</c> (UTF-16, case-sensitive).</summary>
    static bool StartsLower(string s)
    {
        if (s.Length == 0) return false;
        int i = s[0] == '(' || s[0] == '[' ? 1 : 0;
        if (i >= s.Length) return false;
        return s[i] is (>= 'a' and <= 'z') or (>= 'à' and <= 'ÿ') or 'œ';
    }

    // MARK: - Scripts

    /// <summary>
    /// <c>RTL_CHAR = /[֐-ࣿיִ-﷿ﹰ-﻾]/u</c>: right-to-left scripts (Hebrew, Arabic,
    /// Syriac, Thaana, NKo, …) and their presentation forms.
    /// </summary>
    internal static bool IsRtlScalar(int u) => u is (>= 0x590 and <= 0x8FF) or (>= 0xFB1D and <= 0xFDFF) or (>= 0xFE70 and <= 0xFEFE);

    /// <summary>More than half of the letters are right-to-left (Arabic, Hebrew, …): such text is read from right to left.</summary>
    public static bool IsRtlText(string s)
    {
        int letters = 0, rtl = 0;
        foreach (int u in JSCompat.Scalars(s))
        {
            if (!TextNormalizer.IsLetterScalar(u)) continue;
            letters++;
            if (IsRtlScalar(u)) rtl++;
        }
        return rtl * 2 > letters;
    }

    /// <summary><c>HAN_END.test(s)</c>: the last character is a Han character.</summary>
    static bool EndsWithHan(string s)
    {
        if (s.Length == 0) return false;
        int i = s.Length - 1;
        if (char.IsLowSurrogate(s[i]) && i > 0 && char.IsHighSurrogate(s[i - 1])) i--;
        return TextNormalizer.IsHanScalar(JSCompat.CodePointAt(s, i));
    }

    /// <summary><c>HAN_START.test(s)</c>: the first character is a Han character.</summary>
    static bool StartsWithHan(string s) => s.Length > 0 && TextNormalizer.IsHanScalar(JSCompat.CodePointAt(s, 0));

    /// <summary>Joins two words with a space, except between two Han characters.</summary>
    static string JoinWords(string a, string b) => EndsWithHan(a) && StartsWithHan(b) ? a + b : $"{a} {b}";

    static bool IsAsciiLetter(char u) => u is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z');

    /// <summary><c>s.replace(/\s+/g, ' ')</c></summary>
    static string CollapseWhitespace(string s)
    {
        var sb = new StringBuilder(s.Length);
        bool inRun = false;
        foreach (char c in s)
        {
            if (JSCompat.IsWhitespace(c))
            {
                if (!inRun) sb.Append(' ');
                inRun = true;
            }
            else
            {
                sb.Append(c);
                inRun = false;
            }
        }
        return sb.ToString();
    }

    /// <summary><c>s.replace(/ +/g, ' ')</c></summary>
    static string CollapseSpaces(string s)
    {
        var sb = new StringBuilder(s.Length);
        bool previousSpace = false;
        foreach (char c in s)
        {
            if (c == ' ' && previousSpace) continue;
            sb.Append(c);
            previousSpace = c == ' ';
        }
        return sb.ToString();
    }

    /// <summary><c>s.replace(/ *\t */g, '\t')</c></summary>
    static string TightenTabs(string s)
    {
        var sb = new StringBuilder(s.Length);
        bool afterTab = false;
        foreach (char c in s)
        {
            if (c == '\t')
            {
                while (sb.Length > 0 && sb[^1] == ' ') sb.Length--;
                sb.Append(c);
                afterTab = true;
            }
            else if (c == ' ' && afterTab) continue;
            else
            {
                sb.Append(c);
                afterTab = false;
            }
        }
        return sb.ToString();
    }

    /// <summary><c>x || fallback</c> for numbers: 0 and NaN are falsy.</summary>
    static double OrIfFalsy(double x, double fallback) => x == 0 || double.IsNaN(x) ? fallback : x;

    /// <summary>JS <c>Math.max(a, b)</c>: NaN wins, +0 beats -0.</summary>
    internal static double JsMax(double a, double b)
    {
        if (double.IsNaN(a) || double.IsNaN(b)) return double.NaN;
        if (a == b) return double.IsNegative(a) ? b : a;
        return a > b ? a : b;
    }

    /// <summary>JS <c>Math.min(a, b)</c>: NaN wins, -0 beats +0.</summary>
    internal static double JsMin(double a, double b)
    {
        if (double.IsNaN(a) || double.IsNaN(b)) return double.NaN;
        if (a == b) return double.IsNegative(a) ? a : b;
        return a < b ? a : b;
    }

    static double Clamp(double v, double lo, double hi) => JsMin(hi, JsMax(lo, v));

    static double Median(List<double> values)
    {
        if (values.Count == 0) return 0;
        var s = values.ToArray();
        Array.Sort(s);
        int mid = s.Length >> 1;
        return s.Length % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
    }

    static double LowerQuartile(List<double> values)
    {
        if (values.Count == 0) return 0;
        var s = values.ToArray();
        Array.Sort(s);
        return s[(int)Math.Floor((s.Length - 1) * 0.25)];
    }

    /// <summary><c>Array.prototype.sort</c> with a JS-style comparator (negative = a first): stable, like JSC.</summary>
    static List<T> StableSorted<T>(List<T> list, Func<T, T, int> compare)
    {
        var indexed = list.Select((e, i) => (e, i)).ToArray();
        Array.Sort(indexed, (a, b) =>
        {
            int c = compare(a.e, b.e);
            return c != 0 ? c : a.i.CompareTo(b.i);
        });
        return indexed.Select(p => p.e).ToList();
    }

    // MARK: - Lenient JSON (shared with the item / option / segment readers)

    /// <summary>JS <c>toNumber</c>: a finite number, or a string read with <c>parseFloat</c>; null otherwise.</summary>
    internal static double? ToNumber(JSONValue? v)
    {
        if (v is null) return null;
        switch (v.Kind)
        {
            case JSONKind.Number:
                return double.IsFinite(v.NumberValue!.Value) ? v.NumberValue : null;
            case JSONKind.String:
                double n = ParseFloat(v.StringValue!);
                return double.IsFinite(n) ? n : null;
            default:
                return null;
        }
    }

    /// <summary>JS <c>parseFloat</c>: the longest decimal-literal prefix after leading whitespace, NaN if none.</summary>
    internal static double ParseFloat(string s)
    {
        int n = s.Length;
        int i = 0;
        while (i < n && JSCompat.IsWhitespace(s[i])) i++;
        bool negative = false;
        if (i < n && (s[i] == '+' || s[i] == '-'))
        {
            negative = s[i] == '-';
            i++;
        }
        double sign = negative ? -1.0 : 1.0;
        if (string.CompareOrdinal(s, i, "Infinity", 0, 8) == 0 && n - i >= 8) return sign * double.PositiveInfinity;
        int Digits(int start)
        {
            int j = start;
            while (j < n && s[j] is >= '0' and <= '9') j++;
            return j - start;
        }
        int intDigits = Digits(i);
        int end = i + intDigits;
        int fracDigits = 0;
        if (end < n && s[end] == '.')
        {
            fracDigits = Digits(end + 1);
            if (intDigits > 0 || fracDigits > 0) end += 1 + fracDigits;
        }
        if (intDigits + fracDigits == 0) return double.NaN;
        var literal = new StringBuilder(intDigits > 0 ? s.Substring(i, intDigits) : "0");
        if (fracDigits > 0) literal.Append('.').Append(s, i + intDigits + 1, fracDigits);
        if (end < n && (s[end] == 'e' || s[end] == 'E'))
        {
            int k = end + 1;
            string exponentSign = "";
            if (k < n && (s[k] == '+' || s[k] == '-'))
            {
                exponentSign = s[k] == '-' ? "-" : "";
                k++;
            }
            int expDigits = Digits(k);
            if (expDigits > 0) literal.Append('e').Append(exponentSign).Append(s, k, expDigits);
        }
        return double.TryParse(literal.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            ? sign * value
            : double.NaN;
    }

    /// <summary>JS <c>String(v)</c> for a JSON value; null for null.</summary>
    internal static string? JsString(JSONValue v) => v.Kind switch
    {
        JSONKind.Null => null,
        JSONKind.String => v.StringValue,
        JSONKind.Number => JSCompat.NumberToString(v.NumberValue!.Value),
        JSONKind.Bool => v.BoolValue == true ? "true" : "false",
        JSONKind.Array => string.Join(",", v.ArrayValue!.Select(x => JsString(x) ?? "")),
        _ => "[object Object]",
    };
}
