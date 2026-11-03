using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Ports of TextParityTests.swift, TimeParityTests.swift and RandomParityTests.swift.
public class BasicsParityTests
{
    [Fact]
    public void Text() => ParityRunner.Run("text", c => c.Fn switch
    {
        "normalizeBasic" => JSONValue.String(TextNormalizer.NormalizeBasic(c.OptStr(0), c.Bool(1))),
        "stripDiacritics" => JSONValue.String(TextNormalizer.StripDiacritics(c.Str(0))),
        "foldUmlauts" => JSONValue.String(TextNormalizer.FoldUmlauts(c.Str(0))),
        "isLetter" => JSONValue.Bool(TextNormalizer.IsLetter(c.Str(0))),
        "foldScripts" => JSONValue.String(TextNormalizer.FoldScripts(c.Str(0))),
        "stripArabicMarks" => JSONValue.String(TextNormalizer.StripArabicMarks(c.Str(0))),
        "hasArabic" => JSONValue.Bool(TextNormalizer.HasArabic(c.Str(0))),
        "hasHan" => JSONValue.Bool(TextNormalizer.HasHan(c.Str(0))),
        _ => null,
    });

    [Fact]
    public void Time() => ParityRunner.Run("time", c => c.Fn switch
    {
        "dateKey" => JSONValue.String(TimeUtil.DateKey(c.Num(0), Fixtures.Zurich)),
        "formatDate" => JSONValue.String(TimeUtil.FormatDate(c.OptNum(0), Fixtures.Zurich)),
        "calendarDaysBetween" => JSONValue.Number(TimeUtil.CalendarDaysBetween(c.Num(0), c.Num(1), Fixtures.Zurich)),
        "relativeTime" => JSONValue.String(TimeUtil.RelativeTime(c.OptNum(0), c.Num(1), Fixtures.Zurich)),
        "formatDuration" => JSONValue.String(TimeUtil.FormatDuration(c.Num(0))),
        "localTimestamp" => JSONValue.Number(TimeUtil.LocalTimestamp(c.Int(0), c.Int(1), c.Int(2), c.Int(3), c.Int(4), c.Int(5), 0, Fixtures.Zurich)),
        _ => null,
    });

    [Fact]
    public void Random() => ParityRunner.Run("random", c =>
    {
        switch (c.Fn)
        {
            case "mulberry32":
            {
                var rng = Rand.Mulberry32((uint)c.Arg(0).LongValue!.Value);
                return JSONValue.Array(Enumerable.Range(0, c.Int(1)).Select(_ => JSONValue.Number(rng())));
            }
            case "mulberry32Int":
            {
                var rng = Rand.Mulberry32(c.Arg(0).LongValue!.Value);
                return JSONValue.Array(Enumerable.Range(0, c.Int(1)).Select(_ => JSONValue.Number(rng())));
            }
            case "shuffle":
            {
                var rng = Rand.Mulberry32((uint)c.Arg(0).LongValue!.Value);
                var a = Enumerable.Range(0, c.Int(1)).ToArray();
                for (int i = a.Length - 1; i > 0; i--)
                {
                    int j = (int)Math.Floor(rng() * (i + 1));
                    if (!(j >= 0)) j = 0;
                    if (j > i) j = i;
                    (a[i], a[j]) = (a[j], a[i]);
                }
                return JSONValue.Array(a.Select(x => JSONValue.Number(x)));
            }
            default: return null;
        }
    }, tolerance: 0);
}
