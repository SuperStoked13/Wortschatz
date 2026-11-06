using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of OCRPostprocessParityTests.swift (Fixture ocr.json: fixGermanUmlauts, joinCjk via ocrDataToText).
public class OCRPostprocessParityTests
{
    static string? JsString(JSONValue v) => v.Kind switch
    {
        JSONKind.Null => null,
        JSONKind.Array => string.Join(",", v.ArrayValue!.Select(x => JsString(x) ?? "")),
        JSONKind.Object => "[object Object]",
        _ => v.JsPrimitiveString,
    };

    /// <summary><c>Array.isArray(lines) ? lines.map((l) => (l == null ? '' : String(l))) : []</c></summary>
    static List<string> Lines(JSONValue v) => v.ArrayValue?.Select(x => JsString(x) ?? "").ToList() ?? [];

    [Fact]
    public void Fixture() => ParityRunner.Run("ocr", c => c.Fn switch
    {
        "fixGermanUmlauts" => OCRPostprocess.FixGermanUmlauts(Lines(c.Arg(0))).ToJsonArray(),
        // ocrDataToText({ text, words: [] }): the plain-text fallback.
        "ocrPlainText" => JSONValue.String(string.Join("\n", OCRPostprocess.PlainTextLines(c.Str(0)))),
        _ => null,
    });
}
