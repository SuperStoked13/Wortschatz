using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// The order of Lernen since 1.4 (spacing, rechecks): a card comes back after at least MIN_GAP other questions
// and at the latest after about MAX_WAIT, mixed with new cards; a card answered wrong in a long session is
// checked once more 30–50 questions after it was mastered. LearnEngineParityTests replays the JS reference
// question for question; these tests state the rules themselves.
public class LearnSpacingTests
{
    const double T0 = 1_760_000_000_000;

    static List<Card> MakeCards(int n) => Enumerable.Range(1, n).Select(i => new Card($"c{i}", $"terme {i}", $"Begriff {i}")).ToList();

    static LearnState Create(IReadOnlyList<Card> cards, bool mc = true, bool recheck = false, uint seed = 1, int roundSize = 7) =>
        LearnEngine.CreateLearn(cards, AnswerWith.Term, new LearnOptions(roundSize, Mc: mc), rng: Rand.Mulberry32(seed), now: T0, recheck: recheck);

    /// <summary>The questions of a whole session in order; decide(question, index) says whether the answer is right.</summary>
    static (List<LearnQueueQuestion> Asked, LearnState Final) Run(LearnState s, IReadOnlyList<Card> cards, Func<LearnQueueQuestion, int, bool> decide, uint seed = 7)
    {
        var asked = new List<LearnQueueQuestion>();
        var rng = Rand.Mulberry32(seed);
        double t = T0;
        for (int guard = 0; !LearnEngine.IsFinished(s); guard++)
        {
            Assert.True(guard < 5000, "the session did not end");
            if (s.Queue.Count == 0)
            {
                s = LearnEngine.NextRound(s, cards, rng, t += 1000);
                continue;
            }
            var q = s.Queue[0];
            asked.Add(q);
            s = LearnEngine.Answer(s, decide(q, asked.Count - 1), t += 1000);
        }
        return (asked, s);
    }

    /// <summary>
    /// For every question of a card asked before: (other questions in between, cards still open then). Open = the cards
    /// asked from there on; with at least 11 of them the gap must be at least 10.
    /// </summary>
    static List<(int Gap, int Open)> Gaps(List<LearnQueueQuestion> asked)
    {
        var last = new Dictionary<string, int>(StringComparer.Ordinal);
        var gaps = new List<(int, int)>();
        for (int i = 0; i < asked.Count; i++)
        {
            if (last.TryGetValue(asked[i].CardId, out int before))
                gaps.Add((i - before - 1, asked.Skip(i).Select(q => q.CardId).Distinct(StringComparer.Ordinal).Count()));
            last[asked[i].CardId] = i;
        }
        return gaps;
    }

    [Fact]
    public void EveryCardComesBackAfterTenToFifteenOtherQuestions()
    {
        // Written only (the case that felt monotonous): every card twice, the second time 10–15 questions later.
        var cards = MakeCards(60);
        var (asked, final) = Run(Create(cards, mc: false), cards, (_, _) => true);
        Assert.Equal(120, asked.Count);
        Assert.All(cards, c => Assert.Equal(2, asked.Count(q => q.CardId == c.Id)));
        Assert.All(asked, q => Assert.Equal(QuestionType.Written, q.Type));
        // Until the last few cards (fewer than 11 open), the gap is at least 10; never more than a little over 15.
        foreach (var (gap, open) in Gaps(asked))
            Assert.InRange(gap, open > LearnEngine.MIN_GAP ? LearnEngine.MIN_GAP : 0, LearnEngine.MAX_WAIT + 3);
        Assert.Equal(60, LearnEngine.CountsOf(final).Mastered);
    }

    [Fact]
    public void NewCardsComeFirstThenRepeatsAreMixedInAtMostThreeInARow()
    {
        var cards = MakeCards(60);
        var (asked, _) = Run(Create(cards, mc: false, seed: 4), cards, (_, _) => true);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int run = 0, longest = 0, firstRepeat = -1;
        for (int i = 0; i < asked.Count; i++)
        {
            bool repeat = !seen.Add(asked[i].CardId);
            if (repeat && firstRepeat < 0) firstRepeat = i;
            run = repeat ? run + 1 : 0;
            if (seen.Count < cards.Count) longest = Math.Max(longest, run);
        }
        // The first 11 questions are new cards (nothing may come back before 10 others), then the mix starts.
        Assert.True(firstRepeat >= LearnEngine.MIN_GAP + 1);
        Assert.True(longest <= LearnEngine.MAX_REPEATS, $"{longest} repeats in a row while new cards were left");
    }

    [Fact]
    public void WithManyMistakesTheRepeatsStayLimited()
    {
        var cards = MakeCards(60);
        var rng = Rand.Mulberry32(99);
        var (asked, final) = Run(Create(cards, mc: false, seed: 5), cards, (_, _) => rng() < 0.7);
        Assert.True(LearnEngine.IsFinished(final));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int run = 0, longest = 0;
        foreach (var q in asked)
        {
            run = seen.Add(q.CardId) ? 0 : run + 1;
            if (seen.Count < cards.Count) longest = Math.Max(longest, run);
        }
        Assert.True(longest <= 2 * LearnEngine.MAX_REPEATS, $"{longest} repeats in a row while new cards were left");
        foreach (var (gap, open) in Gaps(asked))
            if (open > LearnEngine.MIN_GAP) Assert.True(gap >= LearnEngine.MIN_GAP, $"gap {gap} with {open} cards open");
    }

    [Fact]
    public void SmallSetsUseTheLargestGapPossible()
    {
        var cards = MakeCards(5);
        var (asked, _) = Run(Create(cards, seed: 3), cards, (_, _) => true);
        Assert.Equal(10, asked.Count);
        // Every card once, then every card again in the same order: four others in between.
        Assert.Equal(asked.Take(5).Select(q => q.CardId), asked.Skip(5).Select(q => q.CardId));
        Assert.All(Gaps(asked), g => Assert.Equal(4, g.Gap));
        Assert.All(asked.Take(5), q => Assert.Equal(QuestionType.Mc, q.Type));
        Assert.All(asked.Skip(5), q => Assert.Equal(QuestionType.Written, q.Type));
    }

    [Fact]
    public void AWrongAnswerIsNoLongerRetriedAtTheEndOfTheRound()
    {
        var cards = MakeCards(30);
        var s = Create(cards, mc: false);
        var first = s.Queue[0].CardId;
        s = LearnEngine.Answer(s, false, T0 + 1000);
        Assert.Equal(0, s.Stage[first]);
        Assert.DoesNotContain(s.Queue, q => q.CardId == first);
        var (asked, _) = Run(s, cards, (_, _) => true);
        // Back after the gap (the miss was question 0; it is now learned twice more).
        int again = asked.FindIndex(q => q.CardId == first);
        Assert.True(again + 1 >= LearnEngine.MIN_GAP, $"asked again after {again + 1} questions");
        Assert.Equal(2, asked.Count(q => q.CardId == first));
    }

    [Fact]
    public void LaterQuestionsOfACardInTheRoundFollowAWrongAnswer()
    {
        // Three cards, 7 questions per round: each card comes more than once in a round.
        var cards = MakeCards(3);
        var s = Create(cards, roundSize: 7);
        var id = s.Queue[0].CardId;
        Assert.Equal($"1.1:{id}", s.Queue[0].Qid);
        var later = s.Queue.FindIndex(1, q => q.CardId == id);
        Assert.True(later > 0);
        Assert.Equal($"1.1.2:{id}", s.Queue[later].Qid);
        Assert.Equal(QuestionType.Written, s.Queue[later].Type);
        // Wrong: the planned written question becomes multiple choice again (stage 0).
        s = LearnEngine.Answer(s, false, T0 + 1000);
        var again = s.Queue.First(q => q.CardId == id);
        Assert.Equal(QuestionType.Mc, again.Type);
        // "Ich hatte recht": stage 1 again, so written again.
        s = LearnEngine.Override(s, T0 + 2000);
        Assert.Equal(QuestionType.Written, s.Queue.First(q => q.CardId == id).Type);
    }

    [Fact]
    public void RechecksNeedTheOptionAndMoreThanSixtyCards()
    {
        Assert.Null(Create(MakeCards(61)).Recheck);
        Assert.Null(Create(MakeCards(60), recheck: true).Recheck);
        Assert.NotNull(Create(MakeCards(61), recheck: true).Recheck);
        Assert.Null(Create(MakeCards(61)).ToJson()["recheck"]);
        Assert.NotNull(Create(MakeCards(61), recheck: true).ToJson()["recheck"]);
    }

    [Fact]
    public void ACardMissedOnceIsCheckedAgainThirtyToFiftyQuestionsAfterItWasMastered()
    {
        var cards = MakeCards(80);
        var s = Create(cards, mc: false, recheck: true);
        var missed = s.Queue[0].CardId;
        var (asked, final) = Run(s, cards, (q, i) => i != 0);
        var mine = asked.Select((q, i) => (q, i)).Where(x => x.q.CardId == missed).ToList();
        // Wrong, then learned (twice right), then the recheck.
        Assert.Equal(4, mine.Count);
        Assert.True(LearnEngine.IsRecheckQuestion(mine[3].q.Qid));
        Assert.All(mine.Take(3), x => Assert.False(LearnEngine.IsRecheckQuestion(x.q.Qid)));
        int gap = mine[3].i - mine[2].i - 1;
        Assert.InRange(gap, LearnEngine.RECHECK_GAP, LearnEngine.RECHECK_WAIT + 3);
        // No other card was missed: no other recheck.
        Assert.Single(asked, q => LearnEngine.IsRecheckQuestion(q.Qid));
        Assert.True(LearnEngine.IsFinished(final));
        Assert.Empty(final.Recheck!.Due);
    }

    [Fact]
    public void TheRecheckIsMarkedAsSuchOnScreen()
    {
        // The study card shows "Nachkontrolle" (and the first one a hint): the question says what it is.
        var cards = MakeCards(80);
        var s = Create(cards, mc: false, recheck: true);
        var missed = s.Queue[0].CardId;
        double t = T0;
        var rng = Rand.Mulberry32(7);
        LearnEngine.Question? recheck = null;
        var learning = new List<LearnEngine.Question>();
        for (int guard = 0; recheck is null && !LearnEngine.IsFinished(s); guard++)
        {
            Assert.True(guard < 5000, "no recheck came");
            if (s.Queue.Count == 0)
            {
                s = LearnEngine.NextRound(s, cards, rng, t += 1000);
                continue;
            }
            var q = LearnEngine.Current(s)!;
            if (q.IsRecheck) recheck = q;
            else learning.Add(q);
            s = LearnEngine.Answer(s, s.Answered > 0, t += 1000);
        }
        Assert.NotNull(recheck);
        Assert.Equal(missed, recheck.CardId);
        Assert.False(recheck.IsReview);
        Assert.All(learning, q => Assert.False(q.IsRecheck));

        var card = cards.First(c => c.Id == recheck.CardId);
        var info = LearnFlow.QuestionInfoOf(recheck, card, cards, Lang.Fr, Lang.De);
        Assert.True(info.IsRecheck);
        Assert.False(info.IsReview);
        var first = learning[0];
        Assert.False(LearnFlow.QuestionInfoOf(first, cards.First(c => c.Id == first.CardId), cards, Lang.Fr, Lang.De).IsRecheck);
    }

    [Fact]
    public void AWrongRecheckLearnsTheCardAgainAndChecksItOnceMore()
    {
        var cards = MakeCards(80);
        var s = Create(cards, mc: false, recheck: true, seed: 2);
        var missed = s.Queue[0].CardId;
        bool firstRecheck = true;
        var (asked, final) = Run(s, cards, (q, i) =>
        {
            if (i == 0) return false;
            if (q.CardId == missed && LearnEngine.IsRecheckQuestion(q.Qid) && firstRecheck)
            {
                firstRecheck = false;
                return false;
            }
            return true;
        });
        var kinds = asked.Where(q => q.CardId == missed).Select(q => LearnEngine.IsRecheckQuestion(q.Qid)).ToList();
        // wrong, right, right, recheck (wrong), right, right, recheck (right)
        Assert.Equal([false, false, false, true, false, false, true], kinds);
        Assert.Equal(2, LearnEngine.FinalStatsOf(final).Hardest.Single(h => h.CardId == missed).Misses);
        Assert.True(LearnEngine.IsFinished(final));
    }

    [Fact]
    public void TheSessionIsOnlyFinishedAfterItsRechecks()
    {
        var cards = MakeCards(70);
        var s = Create(cards, mc: false, recheck: true, seed: 6);
        var missed = s.Queue[0].CardId;
        var rng = Rand.Mulberry32(3);
        double t = T0;
        bool sawPending = false;
        int i = 0;
        for (int guard = 0; !LearnEngine.IsFinished(s); guard++)
        {
            Assert.True(guard < 5000);
            if (s.Queue.Count == 0)
            {
                s = LearnEngine.NextRound(s, cards, rng, t += 1000);
                continue;
            }
            s = LearnEngine.Answer(s, i++ != 0, t += 1000);
            var pending = s.Recheck!.Due.Concat(s.Queue.Where(q => LearnEngine.IsRecheckQuestion(q.Qid)).Select(q => q.CardId)).ToList();
            if (pending.Count > 0)
            {
                sawPending = true;
                Assert.Equal([missed], pending);
                Assert.False(LearnEngine.IsFinished(s));
            }
        }
        Assert.True(sawPending, "the missed card never waited for its recheck");
    }

    [Fact]
    public void ARecheckOfACardMissedElsewhereBecomesALearningQuestion()
    {
        var cards = MakeCards(70);
        var s = Create(cards, mc: false, recheck: true);
        var missed = s.Queue[0].CardId;
        var progress = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        var rng = Rand.Mulberry32(8);
        double t = T0;
        int i = 0;
        // Play until the recheck is queued.
        while (!s.Queue.Any(q => LearnEngine.IsRecheckQuestion(q.Qid)))
        {
            if (s.Queue.Count == 0)
            {
                s = LearnEngine.NextRound(s, cards, rng, t += 1000);
                continue;
            }
            var q = s.Queue[0];
            bool ok = i++ != 0;
            progress[q.CardId] = Mastery.ApplyAnswer(progress.GetValueOrDefault(q.CardId), ok, t);
            s = LearnEngine.Answer(s, ok, t += 1000);
        }
        // Missed in Schreiben meanwhile.
        progress[missed] = Mastery.ApplyAnswer(progress[missed], false, t);
        s = LearnEngine.SyncProgress(s, progress, t += 1000);
        Assert.Equal(0, s.Stage[missed]);
        Assert.DoesNotContain(s.Queue, q => LearnEngine.IsRecheckQuestion(q.Qid));
        Assert.Contains(s.Queue, q => q.CardId == missed && q.Qid.Contains(".1", StringComparison.Ordinal));
        Assert.DoesNotContain(missed, s.Recheck!.Due);
    }

    [Fact]
    public void ASessionStoredBeforeSpacingGoesOn()
    {
        // A 1.3 session: batch (active), retries, no clock.
        var json = JSONValue.Parse("""
        {"v":1,"subset":"all","answerWith":"term","learn":{"roundSize":3,"mc":false,"written":true},
         "order":["c1","c2","c3","c4","c5"],"stage":{"c1":1,"c2":0,"c3":0,"c4":0,"c5":0},"initiallyMastered":[],
         "seen":{"c1":true,"c2":true},"active":["c1","c2","c3"],"round":1,
         "queue":[{"qid":"1.1:c3","cardId":"c3","type":"written","ask":"term"},{"qid":"1.2:c2","cardId":"c2","type":"written","ask":"term"}],
         "retried":{"c2":true},"roundLog":[{"qid":"1.1:c1","cardId":"c1","type":"written","ask":"term","correct":true,"stageAfter":1},
         {"qid":"1.1:c2","cardId":"c2","type":"written","ask":"term","correct":false,"stageAfter":0}],
         "rounds":[],"answered":2,"correct":1,"misses":{"c2":1},"last":null,"startedAt":0,"updatedAt":0,"finishedAt":null,"elapsedMs":0}
        """);
        var s = LearnState.FromJson(json);
        Assert.Equal(2, s.Clock);
        Assert.Empty(s.LastAt);
        Assert.Null(s.ToJson()["active"]);
        Assert.Null(s.ToJson()["retried"]);
        Assert.Equal(["1.1:c3", "1.2:c2"], s.Queue.Select(q => q.Qid));
        var cards = MakeCards(5);
        var (asked, final) = Run(s, cards, (_, _) => true);
        Assert.True(LearnEngine.IsFinished(final));
        Assert.Equal(5, LearnEngine.CountsOf(final).Mastered);
    }
}
