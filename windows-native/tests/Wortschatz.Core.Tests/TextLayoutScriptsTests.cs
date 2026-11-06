using Wortschatz.Core;
using Xunit;
using T = Wortschatz.Core.Tests.TextLayoutTests;

namespace Wortschatz.Core.Tests;

// Port of TextLayoutScriptsTests.swift: the right-to-left (Arabic) and Chinese part of
// tests/layout.test.js and the pdf.js direction tests of tests/pdf.test.js (as layout items).
public class TextLayoutScriptsTests
{
    /// <summary>One item per word of a right-to-left phrase (logical order) whose right edge is at x1.</summary>
    static List<TextItem> RtlWords(double x1, double y, string text, double cw = T.Cw, double h = T.H)
    {
        var output = new List<TextItem>();
        double cx = x1;
        foreach (var w in text.Split(' '))
        {
            cx -= w.Length * cw;
            output.Add(new TextItem(w, cx, y, w.Length * cw, h));
            cx -= cw;
        }
        return output;
    }

    static readonly (string De, string Ar)[] ArRows =
    [
        ("die alte Stadt", "المدينة القديمة"), ("der grosse Junge", "الولد الكبير"), ("das Buch", "الكتاب"),
        ("die Schule", "المدرسة"), ("der Lehrer", "المعلم"),
    ];

    static List<string> Lines(IReadOnlyList<TextItem> items) => TextLayout.ItemsToLines(items);

    [Fact]
    public void RtlCell()
    {
        Assert.Equal(["ذهب الولد إلى المدرسة"], Lines(RtlWords(300, 100, "ذهب الولد إلى المدرسة")));
        // Mostly Arabic letters with a Latin word: still right to left.
        Assert.Equal(["الكتاب الجديد CD"], Lines(RtlWords(300, 100, "الكتاب الجديد CD")));
        // Mostly Latin letters with an Arabic word: left to right.
        Assert.Equal(["das Wort كتاب heisst Buch"], Lines(T.Words(50, 100, "das Wort كتاب heisst Buch")));
    }

    [Fact]
    public void RightAlignedColumn()
    {
        var items = new List<TextItem>();
        for (int r = 0; r < ArRows.Length; r++)
        {
            double y = 100 + r * T.Pitch;
            items.AddRange(T.Words(50, y, ArRows[r].De));
            items.AddRange(RtlWords(400, y, ArRows[r].Ar));
        }
        Assert.Equal(ArRows.Select(r => $"{r.De}\t{r.Ar}").ToList(), Lines(items));
        // A long Arabic cell reaching into the gutter belongs to the column of its right edge.
        const string longText = "المدينة القديمة الجميلة جدا في الشمال";
        var items2 = items.Where(it => it.Y != 100 || it.X < 200).Concat(RtlWords(400, 100, longText)).ToList();
        Assert.Equal($"die alte Stadt\t{longText}", Lines(items2)[0]);
    }

    [Fact]
    public void ArabicLeftColumn()
    {
        var items = new List<TextItem>();
        for (int r = 0; r < ArRows.Length; r++)
        {
            double y = 100 + r * T.Pitch;
            items.AddRange(RtlWords(200, y, ArRows[r].Ar));
            items.AddRange(T.Words(260, y, ArRows[r].De));
        }
        Assert.Equal(ArRows.Select(r => $"{r.Ar}\t{r.De}").ToList(), Lines(T.Shuffled(items)));
    }

    [Fact]
    public void RtlRuns()
    {
        var items = new List<TextItem>();
        for (int r = 0; r < ArRows.Length; r++)
        {
            double y = 100 + r * T.Pitch;
            items.Add(T.Run(50, y, ArRows[r].De));
            items.Add(T.Run(400 - ArRows[r].Ar.Length * T.Cw, y, ArRows[r].Ar) with { Dir = "rtl" });
        }
        Assert.Equal(ArRows.Select(r => $"{r.De}\t{r.Ar}").ToList(), Lines(items));
        // Several runs of one cell are joined right to left.
        Assert.Equal(["المدينة القديمة"], Lines([
            new TextItem("المدينة", 400 - 7 * T.Cw, 100, 7 * T.Cw, T.H, "rtl"),
            new TextItem("القديمة", 400 - 15 * T.Cw, 100, 7 * T.Cw, T.H, "rtl"),
        ]));
        // A wide gap inside one rtl run: the first logical piece is the right one.
        Assert.Equal(["قلم\tكتاب"], Lines([new TextItem("كتاب    قلم", 100, 100, 11 * T.Cw, T.H, "rtl")]));
        Assert.Equal(["كتاب\tقلم"], Lines([new TextItem("كتاب    قلم", 100, 100, 11 * T.Cw, T.H)]));
        // Only "rtl" counts as right to left.
        Assert.Equal(["كتاب\tقلم"], Lines([new TextItem("كتاب    قلم", 100, 100, 11 * T.Cw, T.H, "ltr")]));
    }

    [Fact]
    public void PdfRuns()
    {
        // pdf.test.js item(str, x, y, 'rtl'): 6 units per character, rtl runs end at x (viewport flips y).
        static TextItem Item(string str, double x, double y, bool rtl = false)
        {
            double width = str.Length * 6;
            return new TextItem(str, rtl ? x - width : x, 800 - y, width, 12, rtl ? "rtl" : "ltr");
        }
        var rows = ArRows.Take(4).ToList();
        var items = new List<TextItem> { Item("die alte Stadt", 50, 700), Item("المدينة", 400, 700, true), Item("القديمة", 400 - 8 * 6, 700, true) };
        for (int k = 1; k < rows.Count; k++) items.AddRange([Item(rows[k].De, 50, 700 - k * 20), Item(rows[k].Ar, 400, 700 - k * 20, true)]);
        var lines = Lines(items);
        Assert.Equal("die alte Stadt\tالمدينة القديمة", lines[0]);
        Assert.Equal(rows.Select(r => $"{r.De}\t{r.Ar}").ToList(), lines);
    }

    [Fact]
    public void HanJoining()
    {
        const double hw = 12; // a Han character is about twice as wide
        static TextItem Han(double x, double y, string s, bool trail = true) =>
            new(trail ? s + " " : s, x, y, (s.Length + (trail ? 1 : 0)) * hw, T.H);
        // OCR words with trailing spaces, and fragments further apart than a space.
        Assert.Equal(["你好朋友"], Lines([Han(100, 100, "你"), Han(114, 100, "好"), Han(128, 100, "朋友")]));
        Assert.Equal(["你好朋友"], Lines([Han(100, 100, "你好", false), Han(130, 100, "朋友", false)]));
        // Pinyin and other words keep their spaces.
        Assert.Equal(["你好 nǐ hǎo"], Lines([Han(100, 100, "你好"), .. T.Words(130, 100, "nǐ hǎo")]));
        // A wrapped Chinese definition continues without a space.
        var t = new List<TextItem>();
        (string, string)[] rows = [("Hallo", "你好"), ("danke", "谢谢"), ("auf Wiedersehen", "再见"), ("", "朋友"), ("die Schule", "学校")];
        for (int r = 0; r < rows.Length; r++)
        {
            double y = 100 + r * T.Pitch;
            if (rows[r].Item1.Length > 0) t.Add(T.Run(50, y, rows[r].Item1));
            t.Add(new TextItem(rows[r].Item2, 300, y, rows[r].Item2.Length * hw, T.H));
        }
        Assert.Equal(["Hallo\t你好", "danke\t谢谢", "auf Wiedersehen\t再见朋友", "die Schule\t学校"], Lines(t));
        // Astral Han characters (Extension B) join too.
        Assert.Equal(["𠀀𠀁"], Lines([Han(100, 100, "𠀀"), Han(124, 100, "𠀁")]));
    }

    [Fact]
    public void RtlText()
    {
        Assert.True(TextLayout.IsRtlText("كتاب"));
        Assert.True(TextLayout.IsRtlText("שלום"));
        Assert.True(TextLayout.IsRtlText("الكتاب الجديد CD"));
        Assert.False(TextLayout.IsRtlText("das Wort كتاب heisst Buch"));
        Assert.False(TextLayout.IsRtlText("ab كت")); // a tie is left to right
        Assert.False(TextLayout.IsRtlText("١٢٣ ،")); // digits and punctuation are no letters
        Assert.False(TextLayout.IsRtlText(""));
    }

    [Fact]
    public void DirCoding()
    {
        var item = new TextItem("كتاب", 1, 2, 3, 4, "rtl");
        Assert.Equal(item, TextItem.Decode(JSONValue.Parse(item.ToJson().ToJsonString())));
        Assert.True(item.IsRightToLeft);
        Assert.DoesNotContain("dir", new TextItem("x", 1, 2).ToJson().ToJsonString());
        Assert.True(TextItem.FromJson(JSONValue.Parse("""{"str":"x","x":1,"y":2,"dir":"rtl"}"""))?.IsRightToLeft);
        Assert.Null(TextItem.FromJson(JSONValue.Parse("""{"str":"x","x":1,"y":2,"dir":1}"""))?.Dir);
        // deskewItems keeps the direction like the JS spread.
        Assert.Equal("rtl", TextLayout.DeskewItems([item], 0.1)[0].Dir);
    }
}
