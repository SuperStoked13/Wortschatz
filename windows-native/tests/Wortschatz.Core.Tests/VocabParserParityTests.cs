using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of VocabParserParityTests.swift (9'097 cases, 8 slices).
public class VocabParserParityTests
{
    static string JsInput(JSONValue v) => v.Kind switch
    {
        JSONKind.String => v.StringValue!,
        JSONKind.Null => "",
        JSONKind.Array => string.Join(",", v.ArrayValue!.Select(x => x.JsPrimitiveString ?? "")),
        JSONKind.Object => "[object Object]",
        _ => v.JsPrimitiveString ?? "",
    };

    [Theory]
    [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(5)] [InlineData(6)] [InlineData(7)]
    public void Fixture(int slice)
    {
        int index = -1;
        ParityRunner.Run("parser", c => c.Fn == "parseVocab"
            ? VocabParser.ParseVocab(JsInput(c.Arg(0)), ParseOptions.FromJson(c.Arg(1))).ToJson()
            : null, only: _ => ++index % 8 == slice, maxReported: 6);
    }
}
