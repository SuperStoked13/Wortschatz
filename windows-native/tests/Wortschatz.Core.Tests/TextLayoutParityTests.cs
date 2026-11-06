using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of TextLayoutParityTests.swift (Fixture layout.json, from src/import/layout.js).
public class TextLayoutParityTests
{
    [Theory]
    [InlineData(0)] [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public void Fixture(int slice)
    {
        int index = -1;
        ParityRunner.Run("layout", c => c.Fn switch
        {
            "itemsToLines" => TextLayout.ItemsToLines(
                (c.Arg(0).ArrayValue ?? []).Select(TextItem.FromJson).OfType<TextItem>().ToList(),
                LayoutOptions.FromJson(c.Arg(1))).ToJsonArray(),
            // `{ minWidth = 40 } = {}` (the generator only passes numbers or nothing)
            "estimateSlope" => JSONValue.Number(TextLayout.EstimateSlope(
                (c.Arg(0).ArrayValue ?? []).Select(BaselineSegment.FromJson).OfType<BaselineSegment>().ToList(),
                c.Arg(1)["minWidth"]?.NumberValue ?? 40)),
            // The generator only passes well-formed items and numeric (or null) slopes.
            "deskewItems" => TextLayout.DeskewItems(
                (c.Arg(0).ArrayValue ?? []).Select(TextItem.Decode).ToList(), c.OptNum(1) ?? double.NaN).ToJsonArray(),
            _ => null,
        }, only: _ => ++index % 4 == slice, maxReported: 8);
    }
}
