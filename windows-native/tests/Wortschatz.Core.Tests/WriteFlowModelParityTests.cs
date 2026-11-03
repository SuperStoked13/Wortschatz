using System.Text.RegularExpressions;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of WriteFlowModelParityTests.swift: replays the web app's results for write-model.js (and the
// answer diff of write-card.js) against the C# port, JSON for JSON. The reference JSON is embedded in
// the Mac test file WriteFlowWebCases.swift (between #""" and """#); it is read from there, never copied.
public class WriteFlowModelParityTests
{
    sealed record Reference(Dictionary<string, VocabSet> Sets, List<SessionState> Sessions, List<JSONValue> Cases);

    static readonly Lazy<Reference> Ref = new(() =>
    {
        var path = Path.Combine(Fixtures.Dir, "..", "WriteFlowWebCases.swift");
        var source = File.ReadAllText(path);
        var match = Regex.Match(source, "#\"\"\"\\s*\\n(.*)\\n\\s*\"\"\"#", RegexOptions.Singleline);
        Assert.True(match.Success, "no JSON in WriteFlowWebCases.swift");
        var doc = JSONValue.Parse(match.Groups[1].Value);
        var sets = new Dictionary<string, VocabSet>(StringComparer.Ordinal);
        foreach (var (name, value) in doc["sets"]!.ObjectValue!)
        {
            var o = new JsonObjectMap();
            foreach (var (k, v) in value.ObjectValue!) o[k] = v;
            o["id"] = name;
            o["title"] = name;
            sets[name] = VocabSet.FromJson(JSONValue.Object(o), 0)!;
        }
        return new Reference(sets, (doc["sessions"]?.ArrayValue ?? []).Select(WriteSession.CopyState).ToList(), doc["cases"]?.ArrayValue ?? []);
    });

    static Lang? LangOf(JSONValue? v) => EnumRaw.ParseJson<Lang>(v);

    internal static JSONValue QuestionJson(WriteFlow.Question q) => JSONValue.Obj(
        ("qid", q.Qid), ("cardId", q.CardId), ("ask", q.Ask.ToJson()), ("prompt", q.Prompt), ("expected", q.Expected),
        ("promptLang", q.PromptLang.ToJson()), ("answerLang", q.AnswerLang.ToJson()), ("promptLabel", q.PromptLabel),
        ("placeholder", q.Placeholder), ("placeholderShort", q.PlaceholderShort), ("starred", q.Starred));

    static WriteFlow.Question QuestionOf(VocabSet set, string cardId, string ask)
    {
        var card = set.Cards.First(c => c.Id == cardId);
        var side = ask == "term" ? AskSide.Term : AskSide.Definition;
        return WriteFlow.QuestionInfo(set, card, new SessionQuestion(WriteSession.Qid(cardId, side), cardId, side));
    }

    static JSONValue? Run(string fn, List<JSONValue> args, Reference r)
    {
        JSONValue Arg(int i) => i < args.Count ? args[i] : JSONValue.Null;
        VocabSet Set(int i) => r.Sets[Arg(i).StringValue ?? ""];
        SessionState Session(int i) => r.Sessions[Arg(i).IntegerValue!.Value];
        switch (fn)
        {
            case "questionInfo":
            {
                var q = Arg(3);
                var sq = new SessionQuestion(q["qid"]!.StringValue!, q["cardId"]!.StringValue!, q["ask"]?.StringValue == "definition" ? AskSide.Definition : AskSide.Term);
                return QuestionJson(WriteFlow.QuestionInfo(LangOf(Arg(0))!.Value, LangOf(Arg(1))!.Value, Card.FromJson(Arg(2))!, sq));
            }
            case "gradeQuestion":
            {
                var s = Set(0);
                var info = QuestionOf(s, Arg(1).StringValue ?? "", Arg(2).StringValue ?? "");
                var g = WriteFlow.GradeQuestion(s, info, Arg(3).StringValue ?? "", GradingParityTests.TolOf(Arg(4).IntegerValue ?? 0));
                return JSONValue.Obj(("result", g.Result.ToJson()), ("matchedCard", g.MatchedCard is { } m ? m.Id : JSONValue.Null));
            }
            case "copyAccepted":
            {
                var s = Set(0);
                var info = QuestionOf(s, Arg(1).StringValue ?? "", Arg(2).StringValue ?? "");
                return WriteFlow.CopyAccepted(Arg(3).StringValue, info, GradingParityTests.TolOf(Arg(4).IntegerValue ?? 0));
            }
            case "gradeQuestionOrphan":
            {
                var s = r.Sets["personen"];
                var info = QuestionOf(s, Arg(0).StringValue ?? "", "term") with { CardId = "gone" };
                var g = WriteFlow.GradeQuestion(s, info, Arg(1).StringValue ?? "", Tolerance.Default);
                Assert.Null(g.MatchedCard);
                return g.Result.ToJson();
            }
            case "diff":
            {
                var given = Arg(0).StringValue ?? "";
                var expected = Arg(1).StringValue ?? "";
                var l = LangOf(Arg(2));
                var view = WriteFlow.AnswerDiff(given, expected, l);
                return JSONValue.Obj(("closest", WriteFlow.ClosestDiff(given, expected, l).ToJsonArray()), ("view", view?.ToJsonArray() ?? JSONValue.Null));
            }
            case "pendingFeedback":
                return WriteFlow.PendingFeedbackOf(Session(0), Arg(1)).ToJsonOrNull();
            case "resumeGrid":
            {
                var s = Session(0);
                var resume = new List<JSONValue>();
                var results = new List<JSONValue>();
                foreach (bool forceNew in new[] { false, true })
                {
                    foreach (var subset in new StudySubset?[] { null, StudySubset.All, StudySubset.Starred, StudySubset.Missed, StudySubset.Learning })
                    {
                        resume.Add(WriteFlow.CanResume(s, forceNew, subset));
                        foreach (var marker in new double?[] { null, s.StartedAt, s.StartedAt + 1 })
                            results.Add(WriteFlow.CanShowResults(s, forceNew, subset, marker));
                    }
                }
                return JSONValue.Obj(("resume", JSONValue.Array(resume)), ("results", JSONValue.Array(results)));
            }
            case "compactDuration":
            {
                var d = WriteFlow.CompactDurationOf(Arg(0).NumberValue ?? double.NaN);
                return JSONValue.Obj(("value", d.Value), ("label", d.Label));
            }
            case "charColumns":
                return WriteFlow.CharColumns(Arg(0).NumberValue ?? double.NaN, Arg(1).NumberValue ?? double.NaN);
            default:
                return null;
        }
    }

    [Fact]
    public void ReferenceCases()
    {
        var r = Ref.Value;
        Assert.Equal(52, r.Sets["user"].Cards.Count);
        Assert.True(r.Cases.Count > 1500);
        var failures = new List<string>();
        var byFn = new HashSet<string>(StringComparer.Ordinal);
        for (int i = 0; i < r.Cases.Count; i++)
        {
            var c = r.Cases[i];
            var fn = c["fn"]?.StringValue ?? "?";
            var args = c["args"]?.ArrayValue ?? [];
            var actual = Run(fn, args, r);
            Assert.True(actual is not null, $"unknown fn {fn}");
            byFn.Add(fn);
            var diffs = ParityDiff.Differences(c["out"] ?? JSONValue.Null, actual!);
            if (diffs.Count > 0 && failures.Count < 25)
                failures.Add($"{fn}#{i}\n  {string.Join("\n  ", diffs)}\n  args: {ParityDiff.Describe(JSONValue.Array(args), 600)}");
        }
        Assert.True(failures.Count == 0, string.Join("\n\n", failures));
        Assert.Equal(
            new[] { "charColumns", "compactDuration", "copyAccepted", "diff", "gradeQuestion", "gradeQuestionOrphan", "pendingFeedback", "questionInfo", "resumeGrid" },
            byFn.Order(StringComparer.Ordinal));
    }
}
