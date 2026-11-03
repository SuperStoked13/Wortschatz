using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of MasteryParityTests.swift.
public class MasteryParityTests
{
    static CardProgress? Progress(JSONValue v) => CardProgress.FromJson(v);

    static Dictionary<string, double>? Activity(JSONValue v)
    {
        if (v.ObjectValue is not { } o) return null;
        var map = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var (k, n) in o) map[k] = n.NumberValue ?? 0;
        return map;
    }

    [Fact]
    public void Fixture() => ParityRunner.Run("mastery", c =>
    {
        switch (c.Fn)
        {
            case "MASTERY_STREAK": return Mastery.MASTERY_STREAK;
            case "normalizeProgress": return Mastery.NormalizeProgress(Progress(c.Arg(0))).ToJson();
            case "cardStatus": return Mastery.CardStatusOf(Progress(c.Arg(0))).ToJson();
            case "setProgress":
                return Mastery.SetProgressOf(VocabSet.FromJson(c.Arg(0)), Mastery.ProgressMapFromJson(c.Arg(1))).ToJson();
            case "studyStreak":
                return Mastery.StudyStreakOf(Activity(c.Arg(0)), c.Num(1), Fixtures.Zurich).ToJson();
            case "applyAnswer": return Mastery.ApplyAnswer(Progress(c.Arg(0)), c.Bool(1), c.Num(2)).ToJson();
            case "applyOverride": return Mastery.ApplyOverride(Progress(c.Arg(0))).ToJson();
            case "sequence":
                CardProgress? p = null;
                var output = new List<JSONValue>();
                foreach (var op in c.Arg(0).ArrayValue ?? [])
                {
                    p = op["override"]?.BoolValue == true
                        ? Mastery.ApplyOverride(p)
                        : Mastery.ApplyAnswer(p, op["correct"]?.BoolValue ?? false, op["at"]?.NumberValue ?? 0);
                    output.Add(JSONValue.Obj(("progress", p.ToJson()), ("status", Mastery.CardStatusOf(p).ToJson())));
                }
                return JSONValue.Array(output);
            default: return null;
        }
    });
}
