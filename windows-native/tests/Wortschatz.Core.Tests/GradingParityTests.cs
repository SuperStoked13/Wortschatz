using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of GradingParityTests.swift (65'855 cases, run in 8 slices like the Mac tests).
public class GradingParityTests
{
    static string Text(JSONValue v) => v.JsPrimitiveString ?? "";
    static Lang? LangOf(JSONValue v) => Grading.ResolveLang(v.StringValue);

    static Tolerance TolOf(JSONValue v)
    {
        if (v["tolerance"] is { } inner && (inner.IsObject || inner.IsArray)) return Tolerance.FromJson(inner);
        return Tolerance.FromJson(v);
    }

    internal static Tolerance TolOf(int mask)
    {
        bool On(string key) => (mask & (1 << Math.Max(0, Array.IndexOf(Tolerance.Keys, key)))) != 0;
        return new Tolerance(On("articles"), On("abbreviations"), On("multipleAnswers"), On("parentheses"), On("ignoreCase"), On("ignoreAccents"), On("typos"));
    }

    static JSONValue Compact(GradeResult r) => JSONValue.Array(
        r.Correct, r.Exact, JSONValue.Array(r.Notes.Select(n => n.ToJson())), r.Hint.ToJson());

    static JSONValue Langs(IReadOnlyDictionary<Lang, string[]> table) =>
        JSONValue.Object(table.Select(p => new KeyValuePair<string, JSONValue>(p.Key.Raw(), p.Value.ToJsonArray())));

    public static JSONValue? Run(ParityCase c)
    {
        switch (c.Fn)
        {
            case "grade":
                return Grading.Grade(Text(c.Arg(0)), Text(c.Arg(1)), TolOf(c.Arg(2)), LangOf(c.Arg(3))).ToJson();
            case "gradeMatrix":
                var given = c.Str(0);
                var expected = c.Str(1);
                var lang = LangOf(c.Arg(2));
                var masks = (c.Arg(3).ArrayValue ?? []).Select(v => v.IntegerValue ?? 0);
                return JSONValue.Array(masks.Select(m => Compact(Grading.Grade(given, expected, TolOf(m), lang))));
            case "splitAlternatives":
                return Grading.SplitAlternatives(Text(c.Arg(0)), LangOf(c.Arg(1))).ToJsonArray();
            case "diffChars":
                return Grading.DiffChars(Text(c.Arg(0)), Text(c.Arg(1))).ToJsonArray();
            case "diffAnswer":
                return Grading.DiffAnswer(Text(c.Arg(0)), Text(c.Arg(1)), LangOf(c.Arg(2))).ToJsonArray();
            case "constants":
                return c.Str(0) switch
                {
                    "ARTICLES" => Langs(Grading.ARTICLES),
                    "REFLEXIVES" => Langs(Grading.REFLEXIVES),
                    "GLUED_ARTICLES" => Grading.GLUED_ARTICLES.ToJsonArray(),
                    "DEFAULT_TOLERANCE" => Grading.DEFAULT_TOLERANCE.ToJson(),
                    "ABBREVIATIONS" => JSONValue.Array(Grading.ABBREVIATIONS.Select(a => JSONValue.Array(a.Pattern, "giu", a.Canonical))),
                    _ => null,
                };
            default: return null;
        }
    }

    [Theory]
    [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)] [InlineData(6)] [InlineData(7)]
    public void Fixture(int slice)
    {
        int index = -1;
        ParityRunner.Run("grading", Run, only: _ => ++index % 8 == slice);
    }
}
