using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of TextLayoutTests.swift (the layout.js part of tests/layout.test.js: itemsToLines,
// estimateSlope, deskewItems). Where the JS tests continue with parseVocab, the itemsToLines output
// is checked instead.
public class TextLayoutTests
{
    // Geometry used by the helpers: 6 px per character, 12 px glyph height, 16 px line pitch.
    public const double Cw = 6, H = 12, Pitch = 16;

    /// <summary>One item per word, separated by a normal space (like OCR word boxes).</summary>
    public static List<TextItem> Words(double x, double y, string text, double cw = Cw, double h = H)
    {
        var output = new List<TextItem>();
        double cx = x;
        foreach (var w in text.Split(' '))
        {
            output.Add(new TextItem(w, cx, y, w.Length * cw, h));
            cx += (w.Length + 1) * cw;
        }
        return output;
    }

    /// <summary>One item per cell (like pdf.js text runs).</summary>
    public static TextItem Run(double x, double y, string text, double cw = Cw, double h = H) => new(text, x, y, text.Length * cw, h);

    /// <summary>A table: rows of cells at the given column x positions.</summary>
    public static List<TextItem> Table(IReadOnlyList<string[]> rows, double[] xs, double y0 = 100, double pitch = Pitch, bool perWord = false)
    {
        var items = new List<TextItem>();
        for (int r = 0; r < rows.Count; r++)
            for (int c = 0; c < rows[r].Length; c++)
            {
                var text = rows[r][c];
                if (text.Length == 0) continue;
                double y = y0 + r * pitch;
                if (perWord) items.AddRange(Words(xs[c], y, text)); else items.Add(Run(xs[c], y, text));
            }
        return items;
    }

    /// <summary>The deterministic LCG shuffle of the JS tests (in double arithmetic, like JS).</summary>
    public static List<T> Shuffled<T>(IReadOnlyList<T> list, double seed = 7)
    {
        var a = list.ToList();
        double s = seed;
        for (int i = a.Count - 1; i > 0; i--)
        {
            s = (s * 1_103_515_245 + 12345) % 2_147_483_648;
            int j = (int)(s % (i + 1));
            (a[i], a[j]) = (a[j], a[i]);
        }
        return a;
    }

    static readonly string[][] Pairs =
    [
        ["le monsieur, messieurs", "der Herr"], ["l'homme", "der Mann"], ["la femme", "die Frau"],
        ["l'enfant", "das Kind"], ["le garçon", "der Junge"], ["la fille", "das Mädchen"],
    ];

    static readonly string[][] More =
    [
        ["appeler", "nennen"], ["s'appeler", "heissen"], ["le nom", "der Name"], ["le prénom", "der Vorname"], ["la rue", "die Strasse"],
    ];

    static List<string> Tabbed(IEnumerable<string[]> rows) => rows.Select(r => $"{r[0]}\t{r[1]}").ToList();

    public static List<string> Lines(IReadOnlyList<TextItem> items, LayoutOptions? options = null) => TextLayout.ItemsToLines(items, options);

    static List<T> Cat<T>(params IEnumerable<T>[] parts) => parts.SelectMany(p => p).ToList();

    // MARK: Basics

    [Fact]
    public void EmptyInput()
    {
        Assert.Empty(Lines([]));
        Assert.Empty(Lines([new TextItem("   ", 0, 0), new TextItem("x", double.NaN, 1)]));
        // [null, { str: '   ', x: 0, y: 0 }, { str: 'x', x: NaN, y: 1 }, { x: 1, y: 1 }] read leniently
        var json = JSONValue.Parse("""[null, {"str":"   ","x":0,"y":0}, {"str":"x","x":null,"y":1}, {"x":1,"y":1}]""");
        var items = json.ArrayValue!.Select(TextItem.FromJson).OfType<TextItem>().ToList();
        Assert.Single(items);
        Assert.Empty(Lines(items));
    }

    [Fact]
    public void NullOptions()
    {
        Assert.Equal(["der Herr"], Lines(Words(10, 10, "der Herr"), LayoutOptions.FromJson(JSONValue.Null)));
        Assert.Equal(["der Herr"], Lines(Words(10, 10, "der Herr"), new LayoutOptions(double.NaN, double.PositiveInfinity)));
    }

    [Fact]
    public void OneBaseline() => Assert.Equal(["le monsieur, messieurs"], Lines(Words(10, 50, "le monsieur, messieurs")));

    [Fact]
    public void Fragments() =>
        Assert.Equal(["das Fräulein"], Lines([Run(10, 20, "das Fr"), new TextItem("äulein", 10 + 6 * Cw, 20, 6 * Cw, H)]));

    [Fact]
    public void SpacesMarkBoundaries() => Assert.Equal(["der Herr und"], Lines([
        new TextItem("der ", 10, 20, 4 * Cw, H), new TextItem("Herr", 10 + 4 * Cw, 20, 4 * Cw, H), new TextItem(" und", 10 + 8 * Cw, 20, 4 * Cw, H),
    ]));

    [Fact]
    public void Jitter() => Assert.Equal(["le monsieur", "der Herr"], Lines([
        new TextItem("le", 10, 101.5, 2 * Cw, H), new TextItem("monsieur", 10 + 3 * Cw, 98.5, 8 * Cw, H),
        new TextItem("der", 10, 117.2, 3 * Cw, H), new TextItem("Herr", 10 + 4 * Cw, 114.6, 4 * Cw, H),
    ]));

    [Fact]
    public void ReadingOrder()
    {
        var items = new List<TextItem>();
        for (int i = 0; i < Pairs.Length; i++)
        {
            items.AddRange(Words(20, 100 + i * 2 * Pitch, Pairs[i][0]));
            items.AddRange(Words(20, 100 + (i * 2 + 1) * Pitch, Pairs[i][1]));
        }
        var expected = Pairs.SelectMany(p => p).ToList();
        Assert.Equal(expected, Lines(items));
        Assert.Equal(expected, Lines(Shuffled(items)));
        Assert.Equal(expected, Lines(Shuffled(items, 99)));
    }

    [Fact]
    public void MissingSizes() => Assert.Equal(["le nom\tder Name", "la rue\tdie Strasse"], Lines([
        new TextItem("le nom", 10, 20), new TextItem("der Name", 300, 20), new TextItem("la rue", 10, 40), new TextItem("die Strasse", 300, 40),
    ]));

    [Fact]
    public void InvisibleCharacters() =>
        Assert.Equal(["la mademoiselle"], Lines([new TextItem("la\u00A0mademoiselle\u00AD", 0, 0, 16 * Cw, H)]));

    // MARK: Columns

    [Fact]
    public void WideGap() => Assert.Equal(["le nom\tder Name"], Lines(Cat(Words(10, 20, "le nom"), Words(200, 20, "der Name"))));

    [Fact]
    public void GapFactor()
    {
        var items = Cat(Words(10, 20, "le nom"), Words(10 + 9 * Cw, 20, "der Name"));
        // 3-character gap: > 2.2 × char width → tab; with gapFactor 4 it is a space.
        Assert.Equal(["le nom\tder Name"], Lines(items));
        Assert.Equal(["le nom der Name"], Lines(items, new LayoutOptions(GapFactor: 4)));
    }

    [Fact]
    public void TwoColumnTable()
    {
        var rows = Pairs.Concat(More).ToList();
        Assert.Equal(Tabbed(rows), Lines(Table(rows, [40, 260], perWord: true)));
    }

    [Fact]
    public void ShuffledRuns()
    {
        var rows = Pairs.Concat(More).ToList();
        Assert.Equal(Tabbed(rows), Lines(Shuffled(Table(rows, [40, 260]))));
    }

    [Fact]
    public void JitterPerCell()
    {
        var items = Table(Pairs, [40, 260]).Select((it, i) => it with { Y = it.Y + (i % 3 - 1) * 2.5 }).ToList();
        Assert.Equal(Tabbed(Pairs), Lines(items));
    }

    [Fact]
    public void FourColumns()
    {
        var rows = Pairs.Select((p, i) => i < More.Length ? p.Concat(More[i]).ToArray() : p).ToList();
        var lines = Lines(Shuffled(Table(rows, [30, 190, 360, 520], perWord: true)));
        Assert.Equal(Cat(Tabbed(Pairs), [""], Tabbed(More)), lines);
    }

    [Fact]
    public void FourColumnsRightLonger()
    {
        var right = More.Concat([["calme", "ruhig"], ["sage", "brav, artig"], ["bête", "dumm"]]).ToList();
        var rows = right.Select((p, i) => (i < Pairs.Length ? Pairs[i] : ["", ""]).Concat(p).ToArray()).ToList();
        Assert.Equal(Cat(Tabbed(Pairs), [""], Tabbed(right)), Lines(Table(rows, [30, 190, 360, 520])));
    }

    [Fact]
    public void SpanningHeading()
    {
        const string heading = "Unité 3 – Les personnes et les adjectifs du caractère";
        var lines = Lines(Cat(Words(30, 60, heading), Table(Pairs, [30, 260])));
        Assert.Equal(heading, lines[0]);
        Assert.Equal(Tabbed(Pairs), lines.TakeLast(Pairs.Length).ToList());
    }

    [Fact]
    public void NumberingColumn()
    {
        var rows = Pairs.Select((p, i) => new[] { $"{i + 1}.", p[0], p[1] }).ToList();
        Assert.Equal(Tabbed(Pairs), Lines(Table(rows, [20, 60, 280])));
    }

    [Fact]
    public void NumberedList()
    {
        var rows = Pairs.Take(4).Select((p, i) => new[] { $"{i + 1})", p[0] }).ToList();
        Assert.Equal(Pairs.Take(4).Select(p => p[0]).ToList(), Lines(Table(rows, [20, 60])));
    }

    [Fact]
    public void SentenceColumn()
    {
        string[][] rows =
        [
            ["le monsieur", "Le monsieur parle avec sa voisine.", "der Herr"],
            ["la femme", "La femme de Paul est très gentille.", "die Frau"],
            ["le garçon", "Le garçon joue au foot avec ses amis.", "der Junge"],
            ["la fille", "La fille de mes voisins a dix ans.", "das Mädchen"],
        ];
        Assert.Equal(rows.Select(r => $"{r[0]}\t{r[2]}").ToList(), Lines(Table(rows, [20, 160, 420])));
    }

    [Fact]
    public void Monospace() => Assert.Equal(["le nom\tder Name", "la rue\tdie Strasse", "le prénom\tder Vorname"], Lines([
        Run(10, 20, "le nom          der Name"), Run(10, 36, "la rue          die Strasse"), Run(10, 52, "le prénom       der Vorname"),
    ]));

    [Fact]
    public void FakeBold() =>
        Assert.Equal(["der Herr\tle monsieur"], Lines([Run(10, 20, "der Herr"), Run(10.4, 20, "der Herr"), Run(200, 20, "le monsieur")]));

    // MARK: Wrapped cells

    [Fact]
    public void WrappedDefinitions()
    {
        var items = Cat(Words(30, 100, "le nom de famille"), Words(260, 100, "der Familienname,"),
            Words(260, 116, "der Nachname"), Words(30, 132, "le prénom"), Words(260, 132, "der Vorname"),
            Words(30, 148, "l'adresse"), Words(260, 148, "die Adresse,"), Words(260, 164, "die Anschrift"),
            Words(30, 180, "la rue"), Words(260, 180, "die Strasse"));
        Assert.Equal([
            "le nom de famille\tder Familienname, der Nachname", "le prénom\tder Vorname",
            "l'adresse\tdie Adresse, die Anschrift", "la rue\tdie Strasse",
        ], Lines(items));
    }

    [Fact]
    public void WrappedTermComma()
    {
        var items = Cat(Words(30, 100, "le monsieur,"), Words(260, 100, "der Herr"), Words(30, 116, "messieurs"),
            Words(30, 132, "la femme"), Words(260, 132, "die Frau"), Words(30, 148, "la dame"), Words(260, 148, "die Dame"));
        Assert.Equal(["le monsieur, messieurs\tder Herr", "la femme\tdie Frau", "la dame\tdie Dame"], Lines(items));
    }

    [Fact]
    public void WrappedLowercaseTerm()
    {
        var items = Cat(Words(30, 100, "le numéro de la"), Words(260, 100, "die Hausnummer"), Words(30, 115, "maison"),
            Words(30, 140, "la rue"), Words(260, 140, "die Strasse"), Words(30, 165, "la personne"), Words(260, 165, "die Person"));
        Assert.Equal(["le numéro de la maison\tdie Hausnummer", "la rue\tdie Strasse", "la personne\tdie Person"], Lines(items));
    }

    [Fact]
    public void SectionHeading()
    {
        var items = Cat(Table(Pairs.Take(3).ToList(), [30, 260], y0: 100), Words(30, 100 + 2 * Pitch + 3 * Pitch, "Les adjectifs"),
            Table(More.Take(3).ToList(), [30, 260], y0: 100 + 6 * Pitch));
        Assert.Equal(Cat(Tabbed(Pairs.Take(3)), ["", "Les adjectifs"], Tabbed(More.Take(3))), Lines(items));
    }

    // MARK: Paragraphs and page columns

    /// <summary>term, definition, "" between pairs</summary>
    static List<string> Stacked(IEnumerable<string[]> rows) =>
        rows.SelectMany((p, i) => (i > 0 ? new[] { "" } : []).Concat(p)).ToList();

    [Fact]
    public void ParagraphGaps()
    {
        var items = new List<TextItem>();
        double y = 80;
        foreach (var p in Pairs)
        {
            items.AddRange(Words(40, y, p[0]));
            items.AddRange(Words(40, y + Pitch, p[1]));
            y += Pitch * 5;
        }
        Assert.Equal(Stacked(Pairs), Lines(Shuffled(items)));
    }

    [Fact]
    public void EvenWideRows()
    {
        var rows = Pairs.Take(3).ToList();
        Assert.Equal(Tabbed(rows), Lines(Table(rows, [20, 300], pitch: 50)));
    }

    [Fact]
    public void OneWideGap() =>
        Assert.Equal(["le nom", "der Name", "", "la rue"], Lines(Cat(Words(40, 100, "le nom"), Words(40, 116, "der Name"), Words(40, 180, "la rue"))));

    [Fact]
    public void TwoLinesFarApart() =>
        Assert.Equal(["Vocabulaire", "", "le nom"], Lines(Cat(Words(40, 100, "Vocabulaire"), Words(40, 100 + 4 * Pitch, "le nom"))));

    [Fact]
    public void WhitespaceItems() => Assert.Equal(["le nom\tder Name", "la rue\tdie Strasse"], Lines([
        Run(40, 100, "le nom"), new TextItem(" ", 40 + 6 * Cw, 100, 140, H), new TextItem("", 0, 100, 0, 0),
        Run(260, 100, "der Name"), Run(40, 116, "la rue"), Run(260, 116, "die Strasse"),
    ]));

    [Fact]
    public void NormalPitch()
    {
        var items = Pairs.SelectMany(p => p).SelectMany((text, i) => Words(40, 100 + i * Pitch, text)).ToList();
        Assert.DoesNotContain("", Lines(items));
    }

    [Fact]
    public void DoubleSpacing()
    {
        var flat = Pairs.SelectMany(p => p).ToList();
        var items = flat.SelectMany((text, i) => Words(40, 100 + i * Pitch * 2, text)).ToList();
        Assert.Equal(flat, Lines(items));
    }

    [Fact]
    public void StackedTwoColumns()
    {
        var left = Pairs.Take(4).ToList();
        var right = More.Take(4).ToList();
        var items = new List<TextItem>();
        foreach (var (list, col) in new[] { (left, 0), (right, 1) })
        {
            double y = 100;
            foreach (var p in list)
            {
                items.AddRange(Words(col == 1 ? 320 : 40, y, p[0]));
                items.AddRange(Words(col == 1 ? 320 : 40, y + Pitch, p[1]));
                y += Pitch * 4;
            }
        }
        Assert.Equal(Cat(Stacked(left), [""], Stacked(right)), Lines(items));
    }

    [Fact]
    public void UnalignedColumns()
    {
        var left = Pairs.SelectMany(p => p).ToList();
        var right = More.SelectMany(p => p).ToList();
        // Same leading, but the right column is shifted by half a line.
        var items = Cat(left.SelectMany((t, i) => Words(40, 100 + i * Pitch, t)), right.SelectMany((t, i) => Words(330, 108 + i * Pitch, t)));
        Assert.Equal(Cat(left, [""], right), Lines(items));
    }

    [Fact]
    public void IndentedDefinitions()
    {
        var items = new List<TextItem>();
        double y = 100;
        foreach (var p in Pairs)
        {
            items.AddRange(Words(40, y, p[0]));
            items.AddRange(Words(120, y + Pitch, p[1]));
            y += Pitch * 3;
        }
        Assert.Equal(Stacked(Pairs), Lines(items));
    }

    [Fact]
    public void PageNumber()
    {
        var items = Pairs.SelectMany(p => p).SelectMany((t, i) => Words(40, 100 + i * Pitch, t)).ToList();
        items.AddRange(Words(500, 100 + 14 * Pitch, "12"));
        var lines = Lines(items);
        Assert.Equal(Pairs.SelectMany(p => p).ToList(), lines.Take(12).ToList());
        Assert.Equal("12", lines[^1]);
    }

    [Fact]
    public void LargerHeading()
    {
        var items = Cat(Words(40, 60, "Vocabulaire", cw: 12, h: 24), Table(Pairs.Take(4).ToList(), [40, 260], y0: 100));
        Assert.Equal(Cat(["Vocabulaire", ""], Tabbed(Pairs.Take(4))), Lines(items));
    }

    [Fact]
    public void YTolerance()
    {
        List<TextItem> items = [Run(10, 100, "le nom"), Run(200, 104, "der Name"), Run(10, 118, "la rue"), Run(200, 122, "die Strasse")];
        Assert.Equal(["le nom\tder Name", "la rue\tdie Strasse"], Lines(items));
        Assert.Equal(["le nom", "der Name", "la rue", "die Strasse"], Lines(items, new LayoutOptions(YTolerance: 0.2)));
    }

    // MARK: Skew

    [Fact]
    public void EstimateSlope()
    {
        List<BaselineSegment> segs =
        [
            new(0, 100, 400, 108), new(0, 200, 400, 208.4), new(0, 300, 400, 307.6),
            new(0, 10, 10, 30), // too short
        ];
        Assert.True(Math.Abs(TextLayout.EstimateSlope(segs) - 0.02) < 1e-9);
        Assert.Equal(0, TextLayout.EstimateSlope([]));
    }

    [Fact]
    public void Deskew()
    {
        const double slope = 0.06; // ≈ 3.4°, too much for plain row grouping
        var flat = Table(Pairs, [40, 400], pitch: 24, perWord: true);
        var skewed = flat.Select(it => it with { Y = it.Y + it.X * slope }).ToList();
        Assert.NotEqual(Tabbed(Pairs), Lines(skewed));
        Assert.Equal(Tabbed(Pairs), Lines(TextLayout.DeskewItems(skewed, slope)));
    }

    [Fact]
    public void DeskewNoOp()
    {
        var items = Words(10, 10, "la rue");
        Assert.Equal(items, TextLayout.DeskewItems(items, 0));
        Assert.Equal(items, TextLayout.DeskewItems(items, double.NaN));
        Assert.Empty(TextLayout.DeskewItems([], 0.1));
    }

    // MARK: Review regressions

    static readonly string[][] Rows22 =
    [
        ["avoir lieu", "stattfinden"], ["le chat", "die Katze"], ["le chien", "der Hund"], ["manger", "essen"], ["boire", "trinken"],
    ];

    [Fact]
    public void BothWrap()
    {
        // Continuation line 14 below its row; table rows 22 apart.
        var items = new List<TextItem> { Run(50, 100, "s'entendre bien avec"), Run(260, 100, "sich mit jdm gut"), Run(50, 114, "qn"), Run(260, 114, "verstehen") };
        for (int i = 0; i < Rows22.Length; i++) items.AddRange([Run(50, 136 + i * 22, Rows22[i][0]), Run(260, 136 + i * 22, Rows22[i][1])]);
        Assert.Equal(Cat(["s'entendre bien avec qn\tsich mit jdm gut verstehen"], Tabbed(Rows22)), Lines(items));
    }

    [Fact]
    public void UnevenPitch()
    {
        string[][] verbs = [["manger", "essen"], ["boire", "trinken"], ["dormir", "schlafen"], ["parler", "sprechen"], ["lire", "lesen"], ["écrire", "schreiben"]];
        double[] ys = [100, 122, 141, 163, 185, 207];
        var items = verbs.SelectMany((p, i) => new[] { Run(50, ys[i], p[0]), Run(260, ys[i], p[1]) }).ToList();
        Assert.Equal(Tabbed(verbs), Lines(items));
    }

    [Fact]
    public void EntryColumns()
    {
        var left = Pairs.Concat(More.Take(2)).ToList();
        var right = More.Skip(2).Concat([["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"]]).ToList();
        var items = Cat(left.Select((p, i) => Run(50, 100 + i * Pitch, $"{p[0]} – {p[1]}")), right.Select((p, i) => Run(320, 100 + i * Pitch, $"{p[0]} – {p[1]}")));
        var lines = Lines(items);
        Assert.Equal($"{left[0][0]} – {left[0][1]}\t{right[0][0]} – {right[0][1]}", lines[0]);
        // The JS reference output (parseVocab then reads one card per entry, left column first).
        Assert.Equal([
            "le monsieur, messieurs – der Herr\tle nom – der Name",
            "l'homme – der Mann\tle prénom – der Vorname",
            "la femme – die Frau\tla rue – die Strasse",
            "l'enfant – das Kind\tle chat – die Katze",
            "le garçon – der Junge\tle chien – der Hund",
            "la fille – das Mädchen\tla vache – die Kuh",
            "appeler – nennen\tle cheval – das Pferd",
            "s'appeler – heissen",
        ], lines);
    }

    [Theory]
    [InlineData(6)] [InlineData(5)] [InlineData(3)] [InlineData(1)]
    public void RightColumnEndsEarly(int k)
    {
        var left = Pairs.Concat(More.Take(4)).ToList();
        string[][] right = [["le chat", "die Katze"], ["le chien", "der Hund"], ["la vache", "die Kuh"], ["le cheval", "das Pferd"], ["la souris", "die Maus"], ["le cochon", "das Schwein"]];
        var items = Cat(left.Select((p, i) => Run(50, 100 + i * Pitch, $"{p[0]} – {p[1]}")), right.Take(k).Select((p, i) => Run(320, 100 + i * Pitch, $"{p[0]} – {p[1]}")));
        var expected = left.Select((p, i) => $"{p[0]} – {p[1]}" + (i < k ? $"\t{right[i][0]} – {right[i][1]}" : "")).ToList();
        Assert.Equal(expected, Lines(items));
    }

    // MARK: Lenient JSON (readItems / opts / segments)

    static TextItem? Item(string json) => TextItem.FromJson(JSONValue.Parse(json));

    [Fact]
    public void ItemJson()
    {
        Assert.Equal(new TextItem("42", 120, 200.5, 12, 0), Item("""{"str":42,"x":"120","y":" 200.5px","w":"12","h":"abc"}"""));
        Assert.Equal(new TextItem("true", 1, 100), Item("""{"str":true,"x":1,"y":"1e2"}"""));
        Assert.Equal("a,,1", Item("""{"str":["a",null,1],"x":0,"y":0}""")?.Str);
        Assert.Equal("[object Object]", Item("""{"str":{},"x":0,"y":0}""")?.Str);
        Assert.Null(Item("null"));
        Assert.Null(Item("\"le chat\""));
        Assert.Null(Item("""{"x":1,"y":1}"""));
        Assert.Null(Item("""{"str":null,"x":1,"y":1}"""));
        Assert.Null(Item("""{"str":"x","x":"abc","y":1}"""));
        Assert.Null(Item("""{"str":"x","x":"Infinity","y":1}"""));
        Assert.Null(Item("""{"str":"x","x":1}"""));
    }

    [Fact]
    public void ItemDecoding()
    {
        var items = JSONValue.Parse("""[{"str":"le nom","x":"10","y":20,"w":null},{"x":5}]""").ArrayValue!.Select(TextItem.Decode).ToList();
        Assert.Equal([new TextItem("le nom", 10, 20), new TextItem("", 5, 0)], items);
        Assert.Equal(items[0], TextItem.Decode(JSONValue.Parse(items[0].ToJson().ToJsonString())));
    }

    [Fact]
    public void OptionsAndSegments()
    {
        Assert.Equal(new LayoutOptions(0.2, 4), LayoutOptions.FromJson(JSONValue.Parse("""{"yTolerance":"0.2","gapFactor":4}""")));
        Assert.Equal(new LayoutOptions(), LayoutOptions.FromJson(JSONValue.Parse("""{"yTolerance":"abc","gapFactor":null}""")));
        Assert.Equal(new LayoutOptions(), LayoutOptions.FromJson(JSONValue.String("opts")));
        Assert.Equal(new BaselineSegment(0, 1, 2.5, 3), BaselineSegment.FromJson(JSONValue.Parse("""{"x0":0,"y0":"1","x1":2.5,"y1":3}""")));
        Assert.Null(BaselineSegment.FromJson(JSONValue.Parse("""{"x0":0,"y0":1,"x1":2}""")));
        Assert.Null(BaselineSegment.FromJson(JSONValue.Null));
    }

    [Fact]
    public void NonFiniteSegments()
    {
        List<BaselineSegment> segs = [new(0, 0, double.NaN, 4), new(0, 0, 100, 1)];
        Assert.Equal(0.01, TextLayout.EstimateSlope(segs));
        Assert.Equal(0, TextLayout.EstimateSlope(segs, minWidth: 200));
    }

    [Fact]
    public void DeskewNonFinite()
    {
        var odd = new TextItem("x", double.PositiveInfinity, 3, 1, 1);
        var output = TextLayout.DeskewItems([odd, new TextItem("y", 10, 0)], 0.1);
        Assert.Equal(odd, output[0]);
        Assert.True(Math.Abs(output[1].X - 10 * Math.Cos(Math.Atan(0.1))) < 1e-12);
        Assert.True(Math.Abs(output[1].Y + 10 * Math.Sin(Math.Atan(0.1))) < 1e-12);
    }
}
