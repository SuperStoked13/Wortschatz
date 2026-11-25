using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LearnReviewTests.swift (engine and Learn screen).
// Repetition questions (Wiederholungsfragen, LearnReview) are a Mac option the web app lacks, so the
// JS fixture does not cover them: cards mastered before the session are asked once more, mixed into
// the rounds; a miss sends them back to "Am Lernen".
public class LearnReviewTests
{
    const double T0 = 1_760_000_000_000;

    static List<Card> MakeCards(int n) => Enumerable.Range(1, n).Select(i => new Card($"c{i}", $"terme {i}", $"Begriff {i}")).ToList();

    /// <summary>Mastered cards, c1 answered longest ago.</summary>
    static Dictionary<string, CardProgress> Mastered(IEnumerable<Card> cards)
    {
        var p = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        int i = 0;
        foreach (var c in cards)
            p[c.Id] = new CardProgress(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 100_000 + i++);
        return p;
    }

    static LearnState Create(IReadOnlyList<Card> cards, IReadOnlyDictionary<string, CardProgress>? progress = null, int roundSize = 7,
        bool review = true, uint seed = 3) =>
        LearnEngine.CreateLearn(cards, AnswerWith.Term, new LearnOptions(roundSize), progress: progress, rng: Rand.Mulberry32(seed), now: T0, review: review);

    /// <summary>Answers the round's questions; decide says whether an answer is right.</summary>
    static LearnState Play(LearnState state, Func<LearnEngine.Question, bool> decide, double start = T0)
    {
        var s = state;
        double t = start;
        int guardCount = 0;
        while (LearnEngine.Current(s) is { } q)
        {
            Assert.True(++guardCount <= 200, "round did not end");
            t += 1000;
            s = LearnEngine.Answer(s, decide(q), t);
        }
        return s;
    }

    static bool SameJson(LearnState a, LearnState b) => a.ToJson().ToJsonString(sortedKeys: true) == b.ToJson().ToJsonString(sortedKeys: true);

    [Fact]
    public void RepetitionQuestionsAreRecognisedByTheirId()
    {
        Assert.True(LearnEngine.IsReviewQuestion("1.3:c1"));
        Assert.True(LearnEngine.IsReviewQuestion("12.3:a:b"));
        Assert.False(LearnEngine.IsReviewQuestion("1.1:c1"));
        Assert.False(LearnEngine.IsReviewQuestion("1.2:c1"));
        Assert.False(LearnEngine.IsReviewQuestion(".3:c1"));
        Assert.False(LearnEngine.IsReviewQuestion("x.3:c1"));
        Assert.False(LearnEngine.IsReviewQuestion("1.q3:c1"));
        Assert.False(LearnEngine.IsReviewQuestion("13"));
        Assert.False(LearnEngine.IsReviewQuestion("1.33:c1"));
        Assert.False(LearnEngine.IsReviewQuestion("1.4:c1"));
        Assert.False(LearnEngine.IsReviewQuestion("1.3.x:c1"));
        Assert.True(LearnEngine.IsReviewQuestion("2.3.2:c1"));
        Assert.True(LearnEngine.IsRecheckQuestion("1.4:c1"));
        Assert.True(LearnEngine.IsRecheckQuestion("3.4.2:a:b"));
        Assert.False(LearnEngine.IsRecheckQuestion("1.3:c1"));
    }

    [Fact]
    public void WithoutTheOptionNothingChanges()
    {
        var cards = MakeCards(9);
        var progress = Mastered(cards.Take(4));
        progress["c5"] = new CardProgress(Correct: 1, Streak: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 5);
        var plain = LearnEngine.CreateLearn(cards, AnswerWith.Term, new LearnOptions(7), progress: progress, rng: Rand.Mulberry32(3u), now: T0);
        var off = Create(cards, progress, review: false);
        Assert.True(SameJson(plain, off));
        Assert.Null(off.Review);
        Assert.DoesNotContain(off.Queue, q => LearnEngine.IsReviewQuestion(q.Qid));
        Assert.Null(LearnEngine.ReviewStatsOf(off));
        Assert.Null(off.ToJson()["review"]);
    }

    [Fact]
    public void EverythingMasteredWithoutTheOptionIsFinishedAtOnce()
    {
        var cards = MakeCards(5);
        var s = Create(cards, Mastered(cards), review: false);
        Assert.True(LearnEngine.IsFinished(s));
        Assert.Empty(s.Queue);
    }

    [Fact]
    public void RepetitionQuestionsAreMixedInAmongTheNewCardsMostOverdueFirst()
    {
        var cards = MakeCards(10);
        // c1…c6 mastered (c1 answered longest ago), c7…c10 new.
        var s = Create(cards, Mastered(cards.Take(6)));
        Assert.Equal(7, s.Queue.Count);
        Assert.False(LearnEngine.IsFinished(s));
        Assert.Equal(new LearnEngine.ReviewStats(0, 0, 6), LearnEngine.ReviewStatsOf(s));
        // Planned repetition questions leave the due list; the rest waits, the most overdue first.
        var planned = s.Queue.Where(q => LearnEngine.IsReviewQuestion(q.Qid)).Select(q => q.CardId).ToList();
        Assert.Equal(new[] { "c1", "c2", "c3", "c4", "c5", "c6" }.Except(planned), s.Review!.Due);
        // The whole session: every mastered card is asked once more, in that order, written, with options ready
        // should it have to be asked as multiple choice; the new cards come in between.
        var asked = new List<LearnQueueQuestion>();
        double t = T0;
        for (int round = 0; !LearnEngine.IsFinished(s) && round < 20; round++)
        {
            while (s.Queue.Count > 0)
            {
                asked.Add(s.Queue[0]);
                s = LearnEngine.Answer(s, true, t += 1000);
            }
            s = LearnEngine.NextRound(s, cards, Rand.Mulberry32((uint)round + 10), t += 1000);
        }
        Assert.True(LearnEngine.IsFinished(s));
        var reviews = asked.Where(q => LearnEngine.IsReviewQuestion(q.Qid)).ToList();
        Assert.Equal(["c1", "c2", "c3", "c4", "c5", "c6"], reviews.Select(q => q.CardId));
        Assert.All(reviews, q =>
        {
            Assert.Equal(QuestionType.Written, q.Type);
            Assert.NotNull(q.RetryChoices);
            Assert.Matches(@"^\d+\.3:c\d+$", q.Qid);
        });
        int firstNew = asked.FindIndex(q => !LearnEngine.IsReviewQuestion(q.Qid));
        int lastReview = asked.FindLastIndex(q => LearnEngine.IsReviewQuestion(q.Qid));
        Assert.True(firstNew < lastReview, "the repetition questions are mixed in among the new cards");
        Assert.Equal(new LearnEngine.ReviewStats(6, 6, 0), LearnEngine.ReviewStatsOf(s));
    }

    [Fact]
    public void AWholeRoundOfRepetitionWhenEverythingIsMastered()
    {
        var cards = MakeCards(10);
        var s = Create(cards, Mastered(cards), roundSize: 7);
        Assert.False(LearnEngine.IsFinished(s));
        Assert.Null(s.FinishedAt);
        Assert.Equal(7, s.Queue.Count);
        Assert.All(s.Queue, q => Assert.True(LearnEngine.IsReviewQuestion(q.Qid)));
        Assert.True(LearnEngine.Current(s)?.IsReview);
        Assert.Equal(3, s.Review!.Due.Count);
    }

    [Fact]
    public void TheSessionEndsOnceEveryMasteredCardWasAskedAgain()
    {
        var cards = MakeCards(10);
        var s = Create(cards, Mastered(cards), roundSize: 7);
        s = Play(s, _ => true);
        Assert.True(LearnEngine.IsRoundOver(s));
        Assert.False(LearnEngine.IsFinished(s));
        s = LearnEngine.NextRound(s, cards, Rand.Mulberry32(4u), T0 + 60_000);
        Assert.Equal(2, s.Round);
        Assert.Equal(3, s.Queue.Count);
        s = Play(s, _ => true, T0 + 60_000);
        Assert.True(LearnEngine.IsFinished(s));
        Assert.NotNull(s.FinishedAt);
        Assert.Equal(new LearnEngine.ReviewStats(10, 10, 0), LearnEngine.ReviewStatsOf(s));
        var stats = LearnEngine.FinalStatsOf(s);
        Assert.Equal(10, stats.Mastered);
        Assert.Equal(10, stats.AlreadyMastered);
    }

    [Fact]
    public void AMissedRepetitionQuestionSendsTheCardBackToLearning()
    {
        var cards = MakeCards(6);
        var progress = Mastered(cards);
        var s = Create(cards, progress, roundSize: 5);
        var first = LearnEngine.Current(s)!;
        Assert.True(first.IsReview);
        s = LearnEngine.Answer(s, false, T0 + 1000);
        Assert.Equal(0, s.Stage[first.CardId]);
        Assert.DoesNotContain(first.CardId, s.InitiallyMastered);
        Assert.False(s.Review!.Results[first.CardId]);
        // No retry at the end of the round any more: it comes back later, as a card being learned.
        Assert.DoesNotContain(s.Queue, q => q.CardId == first.CardId);
        Assert.Equal(5, LearnEngine.CountsOf(s).Mastered);
        // What the store records for it: no longer mastered.
        var recorded = Mastery.ApplyAnswer(progress[first.CardId], false, T0 + 1000);
        Assert.Equal(CardStatus.Learning, Mastery.CardStatusOf(recorded));
        Assert.Equal(new LearnEngine.ReviewStats(1, 0, 5), LearnEngine.ReviewStatsOf(s));
    }

    [Fact]
    public void AMissedCardIsLearnedAgainUntilItIsMastered()
    {
        var cards = MakeCards(4);
        var s = Create(cards, Mastered(cards), roundSize: 7);
        var missed = LearnEngine.Current(s)!.CardId;
        bool first = true;
        s = Play(s, _ =>
        {
            bool result = !first;
            first = false;
            return result;
        });
        // The miss sent it to stage 0; the next round learns it again: written twice (answered right before; the only
        // card left, so it may come right after itself).
        Assert.Equal(0, s.Stage[missed]);
        Assert.False(LearnEngine.IsFinished(s));
        s = LearnEngine.NextRound(s, cards, Rand.Mulberry32(9u), T0 + 60_000);
        Assert.Equal([$"2.1:{missed}", $"2.1.2:{missed}"], s.Queue.Select(q => q.Qid));
        Assert.Equal([QuestionType.Written, QuestionType.Written], s.Queue.Select(q => q.Type));
        s = Play(s, _ => true, T0 + 60_000);
        Assert.True(LearnEngine.IsFinished(s));
        Assert.Equal(3, LearnEngine.FinalStatsOf(s).AlreadyMastered);
        Assert.Equal(new LearnEngine.ReviewStats(4, 3, 0), LearnEngine.ReviewStatsOf(s));
    }

    [Fact]
    public void IWasRightKeepsTheCardMastered()
    {
        var cards = MakeCards(4);
        var s = Create(cards, Mastered(cards), roundSize: 7);
        var q = LearnEngine.Current(s)!;
        s = LearnEngine.Answer(s, false, T0 + 1000);
        s = LearnEngine.Override(s, T0 + 2000);
        Assert.Equal(2, s.Stage[q.CardId]);
        Assert.Contains(q.CardId, s.InitiallyMastered);
        Assert.Equal(s.Order.Where(s.InitiallyMastered.Contains), s.InitiallyMastered);
        Assert.True(s.Review!.Results[q.CardId]);
        Assert.DoesNotContain(s.Queue, x => x.CardId == q.CardId);
    }

    [Fact]
    public void OnlyTheFirstAnswerOfARepetitionCounts()
    {
        var cards = MakeCards(3);
        var s = Create(cards, Mastered(cards), roundSize: 7);
        var q = LearnEngine.Current(s)!;
        s = LearnEngine.Answer(s, false, T0 + 1000);
        s = Play(s, _ => true, T0 + 1000);
        Assert.False(s.Review!.Results[q.CardId]);
        Assert.Equal(2, LearnEngine.ReviewStatsOf(s)?.Kept);
    }

    [Fact]
    public void ADeletedCardLeavesTheRepetition()
    {
        var cards = MakeCards(10);
        var s = Create(cards, Mastered(cards.Take(6)));
        s = LearnEngine.RemoveCard(s, "c3", T0 + 1000, cards.Where(c => c.Id != "c3").ToList());
        Assert.DoesNotContain("c3", s.Review!.Due);
        Assert.DoesNotContain(s.Queue, q => q.CardId == "c3");
        s = LearnEngine.RemoveCard(s, "c1", T0 + 2000);
        Assert.DoesNotContain(s.Queue, q => q.CardId == "c1");
        Assert.Equal(4, LearnEngine.ReviewStatsOf(s)?.Left);
    }

    [Fact]
    public void ACardMissedElsewhereIsLearnedInsteadOfRepeated()
    {
        var cards = MakeCards(8);
        var progress = Mastered(cards.Take(6));
        var s = Create(cards, progress);
        // c5 is answered wrong in Schreiben: no longer mastered.
        progress["c5"] = Mastery.ApplyAnswer(progress["c5"], false, T0 + 500);
        s = LearnEngine.SyncProgress(s, progress, T0 + 600);
        Assert.DoesNotContain(s.Queue, q => q.CardId == "c5" && LearnEngine.IsReviewQuestion(q.Qid));
        var asked = new List<string>();
        double t = T0 + 600;
        for (int round = 0; !LearnEngine.IsFinished(s) && round < 20; round++)
        {
            while (s.Queue.Count > 0)
            {
                asked.Add(s.Queue[0].Qid);
                s = LearnEngine.Answer(s, true, t += 1000);
            }
            s = LearnEngine.NextRound(s, cards, Rand.Mulberry32((uint)round + 5), t += 1000);
            Assert.DoesNotContain("c5", s.Review!.Due);
        }
        // Learned (multiple choice, then written) instead of repeated.
        Assert.Equal(2, asked.Count(qid => qid.EndsWith(":c5", StringComparison.Ordinal)));
        Assert.DoesNotContain(asked, qid => qid.EndsWith(":c5", StringComparison.Ordinal) && LearnEngine.IsReviewQuestion(qid));
        Assert.True(LearnEngine.IsFinished(s));
    }

    [Fact]
    public void TheRepetitionSurvivesStorage()
    {
        var cards = MakeCards(8);
        var s = Create(cards, Mastered(cards.Take(5)));
        s = LearnEngine.Answer(s, true, T0 + 1000);
        var json = s.ToJson();
        Assert.NotNull(json["review"]?["due"]);
        Assert.True(SameJson(LearnState.FromJson(json), s));
        Assert.True(SameJson(LearnState.FromJson(JSONValue.Parse(json.ToJsonString())), s));
        // Unknown cards and junk are dropped on repair.
        var o = new JsonObjectMap();
        foreach (var (k, v) in json.ObjectValue!) o[k] = v;
        o["review"] = JSONValue.Parse("""{"due": ["c4", "zz", 7, "c4"], "results": {"c1": true, "zz": false, "c2": "x"}}""");
        var repaired = LearnState.FromJson(JSONValue.Object(o));
        Assert.Equal(["c4"], repaired.Review!.Due);
        Assert.Equal(new Dictionary<string, bool> { ["c1"] = true }, repaired.Review.Results);
    }
    // MARK: - The Learn screen

    static VocabSet Set(List<Card> cards) => new() { Id = "set1", Title = "Wörter", TermLang = Lang.Fr, DefLang = Lang.De, Cards = cards, CreatedAt = T0 };

    [Fact]
    public void TheScreenStartsWithRepetitionWhenEverythingIsMastered()
    {
        var cards = MakeCards(5);
        var progress = Mastered(cards);
        var (off, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, now: T0);
        Assert.Equal(LearnFlow.Phase.AllMastered, off.Phase);
        Assert.True(LearnFlow.MessageOf(off)?.OffersReview);

        var (on, effects) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, review: true, rng: Rand.Mulberry32(2u), now: T0);
        Assert.Equal(LearnFlow.Phase.Written, on.Phase);
        Assert.True(on.Question?.IsReview);
        Assert.Contains(effects, e => e is LearnFlow.Effect.SaveLearn);
    }

    [Fact]
    public void RepeatAllStartsARepetitionSession()
    {
        var cards = MakeCards(5);
        var progress = Mastered(cards);
        var (state, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, now: T0);
        var (next, _) = LearnFlow.Reduce(state, new LearnFlow.Event.StartReview(), new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 5000, progress));
        Assert.Equal(LearnFlow.Phase.Written, next.Phase);
        Assert.NotNull(next.Session?.Review);
        Assert.True(next.Question?.IsReview);
        // The option itself stays as it was.
        Assert.False(next.Review);
    }

    [Fact]
    public void AMissedRepetitionSaysTheCardIsLearnedAgain()
    {
        var cards = MakeCards(5);
        var progress = Mastered(cards);
        var (state, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, review: true, rng: Rand.Mulberry32(2u), now: T0);
        var cardId = state.Question!.CardId;
        var env = new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 3000, progress);
        (state, _) = LearnFlow.Reduce(state, new LearnFlow.Event.DraftChanged("faux"), env);
        env.Now += 2000;
        var (after, effects) = LearnFlow.Reduce(state, new LearnFlow.Event.Submit("faux"), env);
        Assert.Equal(LearnFlow.Phase.FeedbackOf(LearnFlow.FeedbackKind.Wrong), after.Phase);
        Assert.True(after.Feedback?.Demoted);
        Assert.Contains(new LearnFlow.Effect.RecordAnswer(cardId, false, env.Now), effects);
        Assert.Contains(effects, e => e is LearnFlow.Effect.Announce a && a.Text.Contains(LearnFlow.DEMOTED_TEXT));
        progress[cardId] = Mastery.ApplyAnswer(progress[cardId], false, env.Now);
        Assert.Equal(CardStatus.Learning, Mastery.CardStatusOf(progress[cardId]));
    }

    /// <summary>Since 24.11.2026 the switch applies to the running session (before: «Neu starten?»).</summary>
    [Fact]
    public void SwitchingTheOptionAppliesAtOnce()
    {
        var cards = MakeCards(6);
        var progress = Mastered(cards.Take(2));
        var (start, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, rng: Rand.Mulberry32(2u), now: T0);
        var env = new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 1000, progress);
        var (s, _) = LearnFlow.Reduce(start, new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options), env);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.ReviewChanged(true), env);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.OverlayDismissed(), env);
        Assert.Null(s.Prompt);
        Assert.NotNull(s.Session?.Review);
        Assert.True(LearnFlow.SessionSettingsOf(s.Session!).Review);
    }

    [Fact]
    public void TheFinishLineCountsTheRepetitions()
    {
        Assert.Equal("4 gemeisterte Begriffe wiederholt, 1 davon ist wieder am Lernen.", LearnFlow.ReviewLine(new LearnEngine.ReviewStats(4, 3, 0)));
        Assert.Equal("1 gemeisterten Begriff wiederholt, er sass noch.", LearnFlow.ReviewLine(new LearnEngine.ReviewStats(1, 1, 0)));
        Assert.Null(LearnFlow.ReviewLine(new LearnEngine.ReviewStats(0, 0, 3)));
    }
}
