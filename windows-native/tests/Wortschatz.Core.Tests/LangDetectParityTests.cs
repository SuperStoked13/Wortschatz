using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LangDetectParityTests.swift.
public class LangDetectParityTests
{
    static string? JsString(JSONValue v) => v.Kind switch
    {
        JSONKind.Null => null,
        JSONKind.Array => string.Join(",", v.ArrayValue!.Select(x => JsString(x) ?? "")),
        JSONKind.Object => "[object Object]",
        _ => v.JsPrimitiveString,
    };

    static List<string?> ColumnLines(JSONValue v) => v.Kind switch
    {
        JSONKind.Array => v.ArrayValue!.Select(x => (string?)(JsString(x) ?? "")).ToList(),
        JSONKind.Null => [],
        _ => [JsString(v) ?? ""],
    };

    public static JSONValue Scores(Dictionary<Lang, double> s) =>
        JSONValue.Object(s.Select(p => new KeyValuePair<string, JSONValue>(p.Key.Raw(), p.Value)));

    [Fact]
    public void Fixture() => ParityRunner.Run("langdetect", c => c.Fn switch
    {
        "scoreLanguages" => Scores(LangDetect.ScoreLanguages(JsString(c.Arg(0)))),
        "detectLanguage" => LangDetect.DetectLanguage(JsString(c.Arg(0))).ToJson(),
        "detectColumn" => LangDetect.DetectColumn(ColumnLines(c.Arg(0))).ToJson(),
        _ => null,
    });
}
