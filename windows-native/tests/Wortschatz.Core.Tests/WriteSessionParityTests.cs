using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of WriteSessionParityTests.swift: replays Fixtures/session.json (mac/Parity/gen-session.js),
// scripted Write sessions compared with src/core/session.js snapshot by snapshot (state, current,
// counters, roundSummary, isRoundOver, isFinished, finalStats after creation and after every action).
public class WriteSessionParityTests
{
    [Fact]
    public void Fixture() => ParityRunner.Run("session", c => c.Fn switch
    {
        "scenario" => Scenario(c),
        "restore" => Restore(c),
        _ => null,
    });

    /// <summary>Every state the JS produced survives CopyState unchanged (JSON and typed) and encodes back to the same JSON.</summary>
    [Fact]
    public void JsStatesRoundTrip()
    {
        int checkedStates = 0;
        var failures = new List<string>();
        foreach (var c in Fixtures.Load("session"))
        {
            var snaps = c.Out.ArrayValue ?? [];
            for (int step = 0; step < snaps.Count; step++)
            {
                if (snaps[step]["state"] is not { } json)
                {
                    failures.Add($"{c.Id} step {step}: snapshot without state");
                    continue;
                }
                var repaired = WriteSession.CopyState(json);
                var encoded = repaired.ToJson();
                var diffs = ParityDiff.Differences(json, encoded).Concat(ParityDiff.Differences(encoded, WriteSession.CopyState(repaired).ToJson())).ToList();
                if (diffs.Count > 0 && failures.Count < 10) failures.Add($"{c.Id} step {step}: {string.Join("; ", diffs)}");
                checkedStates++;
            }
        }
        Assert.True(failures.Count == 0, string.Join("\n", failures));
        Assert.True(checkedStates > 3000, $"only {checkedStates} states");
    }

    static JSONValue Scenario(ParityCase c)
    {
        var options = c.Arg(1);
        var create = c.Arg(2);
        var rng = Rand.Mulberry32(create["seed"]?.LongValue ?? 0);
        var s = WriteSession.CreateSession(Cards(c.Arg(0)), EnumRaw.ParseJson<AnswerWith>(options["answerWith"]) ?? AnswerWith.Term,
            options["shuffle"]?.BoolValue != false, StudySubset.FromJson(create["subset"] ?? JSONValue.Null), rng, Time(create["now"]),
            Progress(create["progress"]));
        var output = new List<JSONValue> { Snapshot(s) };
        foreach (var action in c.Arg(3).ArrayValue ?? [])
        {
            s = Apply(action, s, rng, c.Id);
            output.Add(Snapshot(s));
        }
        return JSONValue.Array(output);
    }

    static JSONValue Restore(ParityCase c)
    {
        var rng = Rand.Mulberry32(c.Arg(1).LongValue ?? throw new InvalidOperationException("seed"));
        var s = WriteSession.CopyState(c.Arg(0));
        var output = new List<JSONValue> { Snapshot(s) };
        foreach (var action in c.Arg(2).ArrayValue ?? [])
        {
            s = Apply(action, s, rng, c.Id);
            output.Add(Snapshot(s));
        }
        return JSONValue.Array(output);
    }

    static SessionState Apply(JSONValue action, SessionState s, RNG rng, string caseId)
    {
        double now = Time(action["now"]);
        return action["op"]?.StringValue switch
        {
            "answer" => WriteSession.Answer(s, action["correct"]?.BoolValue == true, now),
            "override" => WriteSession.Override(s, action["qid"]?.StringValue ?? "", now),
            "nextRound" => WriteSession.NextRound(s, action["seed"]?.LongValue is { } seed ? Rand.Mulberry32(seed) : rng, now),
            "removeCard" => WriteSession.RemoveCard(s, action["cardId"]?.StringValue ?? "", now),
            "tick" => WriteSession.Tick(s, now),
            _ => throw new InvalidOperationException($"{caseId}: unknown action {ParityDiff.Describe(action)}"),
        };
    }

    static JSONValue Snapshot(SessionState s) => JSONValue.Obj(
        ("state", s.ToJson()),
        ("current", WriteSession.Current(s).ToJsonOrNull()),
        ("counters", WriteSession.CountersOf(s).ToJson()),
        ("roundSummary", WriteSession.RoundSummaryOf(s).ToJson()),
        ("isRoundOver", WriteSession.IsRoundOver(s)),
        ("isFinished", WriteSession.IsFinished(s)),
        ("finalStats", WriteSession.FinalStatsOf(s).ToJson()));

    /// <summary>A timestamp argument: JS null maps to NaN (the clock is left alone).</summary>
    static double Time(JSONValue? v) => v?.NumberValue ?? double.NaN;

    /// <summary>The cards as createSession reads them (see LearnEngineParityTests.Cards).</summary>
    static List<Card> Cards(JSONValue v)
    {
        var output = new List<Card>();
        foreach (var raw in v.ArrayValue ?? [])
        {
            if (raw.ObjectValue is null || raw["id"] is not { } id || id.IsNull || id.StringValue == "") continue;
            output.Add(new Card(LearnEngine.JsString(id), raw["term"]?.StringValue ?? "", raw["definition"]?.StringValue ?? "", raw["starred"]?.BoolValue == true));
        }
        return output;
    }

    static Dictionary<string, CardProgress> Progress(JSONValue? v)
    {
        var output = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        foreach (var (k, x) in v?.ObjectValue ?? new JsonObjectMap())
            if (CardProgress.FromJson(x) is { } p) output[k] = p;
        return output;
    }
}
