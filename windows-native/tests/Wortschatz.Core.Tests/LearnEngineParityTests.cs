using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LearnEngineParityTests.swift: replays Fixtures/learn.json (mac/Parity/gen-learn.js), scripted
// Learn sessions compared with src/core/learn.js snapshot by snapshot (state, current, counts,
// checkpoint, isRoundOver, isFinished, finalStats and matchesProgress after creation and after every
// action), plus buildChoices and stageFromProgress.
public class LearnEngineParityTests
{
    const double T0 = 1_760_000_000_000;

    static JSONValue? Run(ParityCase c) => c.Fn switch
    {
        "scenario" => Scenario(c),
        "restore" => Restore(c),
        "buildChoices" => BuildChoices(c),
        "stageFromProgress" => LearnEngine.StageFromProgress(CardProgress.FromJson(c.Arg(0))),
        _ => null,
    };

    [Fact]
    public void Fixture() => ParityRunner.Run("learn", Run);

    /// <summary>Every state the JS produced survives CopyState unchanged (JSON and typed) and encodes back to the same JSON.</summary>
    [Fact]
    public void JsStatesRoundTrip()
    {
        int checkedStates = 0;
        var failures = new List<string>();
        foreach (var c in Fixtures.Load("learn"))
        {
            if (c.Fn is not ("scenario" or "restore")) continue;
            var snaps = c.Out.ArrayValue ?? [];
            for (int step = 0; step < snaps.Count; step++)
            {
                if (snaps[step]["state"] is not { } json) continue;
                var repaired = LearnEngine.CopyState(json);
                var encoded = repaired.ToJson();
                var diffs = ParityDiff.Differences(json, encoded);
                var again = ParityDiff.Differences(encoded, LearnEngine.CopyState(repaired).ToJson());
                if ((diffs.Count > 0 || again.Count > 0) && failures.Count < 10)
                    failures.Add($"{c.Id} step {step}: {string.Join("; ", diffs.Concat(again))}");
                checkedStates++;
            }
        }
        Assert.True(failures.Count == 0, string.Join("\n", failures));
        Assert.True(checkedStates > 1500, $"only {checkedStates} states");
    }

    /// <summary>The fixture is complete, large and varied enough to mean something.</summary>
    [Fact]
    public void Coverage()
    {
        var cases = Fixtures.Load("learn");
        var byFn = new Dictionary<string, int>();
        var ops = new Dictionary<string, int>();
        int snapshots = 0;
        foreach (var c in cases)
        {
            byFn[c.Fn] = byFn.GetValueOrDefault(c.Fn) + 1;
            snapshots += c.Out.ArrayValue?.Count ?? 0;
            var actions = c.Fn == "scenario" ? c.Arg(3) : c.Fn == "restore" ? c.Arg(4) : JSONValue.Null;
            foreach (var a in actions.ArrayValue ?? [])
            {
                var op = a["op"]?.StringValue ?? "?";
                ops[op] = ops.GetValueOrDefault(op) + 1;
            }
        }
        Assert.Equal(new[] { "buildChoices", "restore", "scenario", "stageFromProgress" }, byFn.Keys.Order(StringComparer.Ordinal));
        Assert.True(byFn["scenario"] > 400);
        Assert.True(byFn["restore"] > 150);
        Assert.True(byFn["buildChoices"] > 400);
        Assert.True(snapshots > 5000);
        foreach (var op in new[] { "answer", "override", "nextRound", "removeCard", "tick", "sync", "write", "reset" })
            Assert.True(ops.GetValueOrDefault(op) > 20, $"few {op} actions");
    }

    // MARK: Replay

    /// <summary>A scripted run: the session, the set's cards and the tracked progress (what the store would hold).</summary>
    sealed class Replay(LearnState s, List<Card>? cards, Dictionary<string, CardProgress> progress, RNG rng, string caseId)
    {
        LearnState _s = s;
        List<Card>? _cards = cards;
        Dictionary<string, CardProgress> _progress = progress;

        public JSONValue Apply(JSONValue a)
        {
            double now = Time(a["now"]);
            var op = a["op"]?.StringValue ?? "";
            switch (op)
            {
                case "answer":
                {
                    bool correct = a["correct"]?.BoolValue == true;
                    if (LearnEngine.Current(_s) is { } q)
                        _progress[q.CardId] = Mastery.ApplyAnswer(_progress.GetValueOrDefault(q.CardId), correct, T0);
                    _s = LearnEngine.Answer(_s, correct, now);
                    break;
                }
                case "override":
                    if (LearnEngine.CopyState(_s).Last is { Correct: false } l && _progress.TryGetValue(l.CardId, out var prev)
                        && prev.LastResult == AnswerResult.Incorrect)
                        _progress[l.CardId] = Mastery.ApplyOverride(prev);
                    _s = LearnEngine.Override(_s, now);
                    break;
                case "nextRound":
                {
                    var list = _cards;
                    if (a["cards"] is { } value)
                    {
                        list = Cards(value);
                        if (value.IsArray) _cards = list;
                    }
                    _s = LearnEngine.NextRound(_s, list, RngFor(a), now);
                    break;
                }
                case "removeCard":
                {
                    var cardId = a["cardId"]?.StringValue ?? "";
                    if (a["cards"] is { } value)
                    {
                        List<Card>? list;
                        if (value.StringValue == "set") list = _cards;
                        else
                        {
                            list = Cards(value);
                            if (value.IsArray) _cards = list;
                        }
                        _s = LearnEngine.RemoveCard(_s, cardId, now, list, RngFor(a));
                    }
                    else _s = LearnEngine.RemoveCard(_s, cardId, now);
                    break;
                }
                case "tick":
                    _s = LearnEngine.Tick(_s, now);
                    break;
                case "sync":
                    if (a["progress"] is { } p) _progress = Progress(p);
                    _s = LearnEngine.SyncProgress(_s, _progress, now);
                    break;
                case "write":
                {
                    var cardId = a["cardId"]?.StringValue ?? "";
                    _progress[cardId] = Mastery.ApplyAnswer(_progress.GetValueOrDefault(cardId), a["correct"]?.BoolValue == true, T0);
                    return JSONValue.Obj(("matches", LearnEngine.MatchesProgress(_s, _progress)));
                }
                case "reset":
                    if (a["cardIds"]?.ArrayValue is { } ids)
                        foreach (var id in ids) _progress.Remove(id.StringValue ?? "");
                    else _progress = new(StringComparer.Ordinal);
                    return JSONValue.Obj(("matches", LearnEngine.MatchesProgress(_s, _progress)));
                default:
                    throw new InvalidOperationException($"{caseId}: unknown action {ParityDiff.Describe(a)}");
            }
            return Snapshot(_s, _progress, lite: op is "answer" or "override" or "tick");
        }

        /// <summary>The run's shared rng, or a fresh mulberry32 when the action carries its own seed.</summary>
        RNG RngFor(JSONValue a) => a["seed"]?.LongValue is { } seed ? Rand.Mulberry32(seed) : rng;
    }

    static JSONValue Scenario(ParityCase c)
    {
        var options = c.Arg(1);
        var create = c.Arg(2);
        var rng = Rand.Mulberry32(create["seed"]?.LongValue ?? 0);
        var cards = Cards(c.Arg(0));
        var progress = Progress(create["progress"]);
        var s = LearnEngine.CreateLearn(cards ?? [], EnumRaw.ParseJson<AnswerWith>(options["answerWith"]) ?? AnswerWith.Term,
            LearnOptions.FromJson(options["learn"] ?? JSONValue.Null), StudySubset.FromJson(create["subset"] ?? JSONValue.Null),
            progress, rng, Time(create["now"]));
        var run = new Replay(s, cards, progress, rng, c.Id);
        var output = new List<JSONValue> { Snapshot(s, progress) };
        foreach (var action in c.Arg(3).ArrayValue ?? []) output.Add(run.Apply(action));
        return JSONValue.Array(output);
    }

    static JSONValue Restore(ParityCase c)
    {
        var s = LearnEngine.CopyState(c.Arg(0));
        var progress = Progress(c.Arg(3));
        var run = new Replay(s, Cards(c.Arg(1)), progress, Rand.Mulberry32(c.Arg(2).LongValue ?? throw new InvalidOperationException("seed")), c.Id);
        var output = new List<JSONValue> { Snapshot(s, progress) };
        foreach (var action in c.Arg(4).ArrayValue ?? []) output.Add(run.Apply(action));
        return JSONValue.Array(output);
    }

    static JSONValue BuildChoices(ParityCase c)
    {
        var card = c.Arg(1);
        int n = c.Arg(4).FiniteNumber is { } x ? (x >= 1 ? (int)Math.Min(Math.Floor(x), int.MaxValue) : 0) : 0;
        var choices = LearnEngine.BuildChoices(ChoiceCards(c.Arg(0)),
            new Card(card["id"] is { } id ? LearnEngineJs(id) : "", ToStr(card["term"]), ToStr(card["definition"])),
            c.Arg(2).StringValue == "definition" ? AskSide.Definition : AskSide.Term,
            Rand.Mulberry32(c.Arg(3).LongValue ?? throw new InvalidOperationException("seed")), n);
        return choices.ToJsonArray();
    }

    /// <summary>
    /// The JS snapshot of s; lite (after answer, override, tick) reduces each queued question to its qid and
    /// records checkpoint and finalStats only once the round is over.
    /// </summary>
    static JSONValue Snapshot(LearnState s, IReadOnlyDictionary<string, CardProgress> progress, bool lite = false)
    {
        var state = LearnEngine.Tick(s, double.NaN).ToJson();
        bool over = LearnEngine.IsRoundOver(s);
        if (lite)
        {
            var o = new JsonObjectMap();
            foreach (var (k, v) in state.ObjectValue!)
                o[k] = k == "queue" ? JSONValue.Array((v.ArrayValue ?? []).Select(q => q["qid"] ?? JSONValue.Null)) : v;
            state = JSONValue.Object(o);
        }
        var output = new JsonObjectMap
        {
            [lite ? "stateLite" : "state"] = state,
            ["current"] = LearnEngine.Current(s).ToJsonOrNull(),
            ["counts"] = LearnEngine.CountsOf(s).ToJson(),
            ["isRoundOver"] = over,
            ["isFinished"] = LearnEngine.IsFinished(s),
            ["matches"] = LearnEngine.MatchesProgress(s, progress),
        };
        if (!lite || over)
        {
            output["checkpoint"] = LearnEngine.CheckpointOf(s).ToJson();
            output["finalStats"] = LearnEngine.FinalStatsOf(s).ToJson();
        }
        return JSONValue.Object(output);
    }

    // MARK: JS arguments → typed API

    /// <summary>A timestamp argument: JS null maps to NaN, which the engine treats the same way.</summary>
    static double Time(JSONValue? v) => v?.NumberValue ?? double.NaN;

    /// <summary>
    /// Scenario cards as createLearn and nextRound read them (null for a non-array): non-objects and entries
    /// without id are dropped, ids stringified, non-string sides count as empty, only starred === true stars.
    /// Repeated ids stay (the engine keeps the first).
    /// </summary>
    static List<Card>? Cards(JSONValue v)
    {
        if (v.ArrayValue is not { } list) return null;
        var output = new List<Card>();
        foreach (var raw in list)
        {
            if (raw.ObjectValue is null || raw["id"] is not { } id || id.IsNull || id.StringValue == "") continue;
            output.Add(new Card(LearnEngineJs(id), raw["term"]?.StringValue ?? "", raw["definition"]?.StringValue ?? "", raw["starred"]?.BoolValue == true));
        }
        return output;
    }

    /// <summary>buildChoices cards: every card with an id, sides read with answerSide's toStr.</summary>
    static List<Card> ChoiceCards(JSONValue v)
    {
        var output = new List<Card>();
        foreach (var raw in v.ArrayValue ?? [])
        {
            if (raw.ObjectValue is null || raw["id"] is not { } id || id.IsNull || id.StringValue == "") continue;
            output.Add(new Card(LearnEngineJs(id), ToStr(raw["term"]), ToStr(raw["definition"])));
        }
        return output;
    }

    /// <summary>progress[card.id] as the engine reads it: non-object maps are empty, non-object entries are "no progress".</summary>
    static Dictionary<string, CardProgress> Progress(JSONValue? v)
    {
        var output = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        foreach (var (k, x) in v?.ObjectValue ?? new JsonObjectMap())
            if (CardProgress.FromJson(x) is { } p) output[k] = p;
        return output;
    }

    /// <summary>toStr of synonyms.js: null/undefined → '', anything else String(v).</summary>
    static string ToStr(JSONValue? v) => v is null || v.IsNull ? "" : LearnEngineJs(v);

    static string LearnEngineJs(JSONValue v) => LearnEngine.JsString(v);
}
