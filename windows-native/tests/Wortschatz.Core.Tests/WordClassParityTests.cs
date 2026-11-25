using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of WordClassParityTests.swift: Fixtures/wordclass.json (mac/Parity/gen-wordclass.js) – side profiles, the
// class of texts with every kind of side, card classes of every fixture list and fuzzed lists, option shapes and
// similarity points, compared with src/core/wordclass.js.
public class WordClassParityTests
{
    static WordClass.SideProfile Side(JSONValue v) => new(
        EnumRaw.Parse<DetectedLanguage>(v["lang"]?.StringValue ?? "") ?? throw new InvalidDataException($"bad side {v}"),
        v["wordCaps"]?.BoolValue ?? false, v["capsNoun"]?.BoolValue ?? false, v["capsRare"]?.BoolValue ?? false);

    static WordClass.OptionShape Shape(JSONValue v) => new(
        v["article"]?.StringValue ?? "", v["head"]?.StringValue ?? "", v["words"]?.IntegerValue ?? 0, v["length"]?.IntegerValue ?? 0);

    static List<string> Texts(JSONValue v) => (v.ArrayValue ?? []).Select(x => x.StringValue ?? "").ToList();

    [Fact]
    public void Fixture() => ParityRunner.Run("wordclass", c =>
    {
        switch (c.Fn)
        {
            case "sideProfile":
                return WordClass.SideProfileOf(Texts(c.Arg(0))).ToJson();
            case "textClass":
                return WordClass.TextClassOf(c.Arg(0).StringValue ?? "", Side(c.Arg(1))).ToJson();
            case "optionShape":
                return WordClass.OptionShapeOf(c.Arg(0).StringValue ?? "", Side(c.Arg(1))).ToJson();
            case "cardClasses":
                var cards = (c.Arg(0).ArrayValue ?? [])
                    .Select(v => new Card("", v["term"]?.StringValue ?? "", v["definition"]?.StringValue ?? "")).ToList();
                var sides = WordClass.ListProfilesOf(cards);
                return JSONValue.Obj(("sides", sides.ToJson()), ("classes", cards.Select(cd => WordClass.CardClass(cd, sides)).ToJsonArray()));
            case "shapePoints":
                return WordClass.ShapePoints(Shape(c.Arg(0)), Shape(c.Arg(1)));
            case "nearPoints":
                return WordClass.NearPoints(c.Arg(0).IntegerValue ?? 0);
            default:
                return null;
        }
    });
}
