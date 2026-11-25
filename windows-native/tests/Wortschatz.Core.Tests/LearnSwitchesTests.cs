using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LearnSwitchesTests.swift.
// «Wiederholungsfragen» and «Nachkontrolle nach Fehlern» apply to a running session at once (since 24.11.2026).
// Before, a session kept what it was started with: switched off in Einstellungen, a long session went on asking
// rechecks for days.
public class LearnSwitchesTests
{
    const double T0 = 1_760_000_000_000;

    static List<Card> MakeCards(int n) => Enumerable.Range(1, n).Select(i => new Card($"c{i}", $"terme {i}", $"Begriff {i}")).ToList();

    static VocabSet Set(List<Card> cards) => new() { Id = "set1", Title = "Wörter", TermLang = Lang.Fr, DefLang = Lang.De, Cards = cards, CreatedAt = T0 };

    static Dictionary<string, CardProgress> Mastered(IEnumerable<string> ids)
    {
        var p = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        int i = 0;
        foreach (var id in ids)
            p[id] = new CardProgress(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 100_000 + i++);
        return p;
    }

    static CardProgress MasteredAt(double t) => new(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: t);

    static string J(LearnState? s) => s?.ToJson().ToJsonString(sortedKeys: true) ?? "null";

    static bool IsRecheck(LearnQueueQuestion q) => LearnEngine.IsRecheckQuestion(q.Qid);

    /// <summary>Plays written questions (the first card wrong once) until a recheck is queued.</summary>
    static (LearnState State, Dictionary<string, CardProgress> Progress, double T) UntilARecheckIsQueued(List<Card> cards)
    {
        var s = LearnEngine.CreateLearn(cards, AnswerWith.Term, new LearnOptions(7, Mc: false), rng: Rand.Mulberry32(1u), now: T0, recheck: true);
        string missed = s.Queue[0].CardId;
        var progress = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        var rng = Rand.Mulberry32(4u);
        double t = T0;
        bool first = true;
        while (!s.Queue.Any(IsRecheck))
        {
            Assert.True(t < T0 + 5_000_000, "no recheck came");
            t += 1000;
            if (s.Queue.Count == 0)
            {
                s = LearnEngine.NextRound(s, cards, rng, t);
                continue;
            }
            var q = s.Queue[0];
            bool ok = !(first && q.CardId == missed);
            first = false;
            progress[q.CardId] = Mastery.ApplyAnswer(progress.GetValueOrDefault(q.CardId), ok, t);
            s = LearnEngine.Answer(s, ok, t);
        }
        return (s, progress, t);
    }

    /// <summary>Every card not mastered yet mastered meanwhile (in Schreiben): only the queued recheck is left.</summary>
    static (LearnState State, Dictionary<string, CardProgress> Progress) OnlyTheRecheckLeft(List<Card> cards, LearnState queued,
        Dictionary<string, CardProgress> progress, double t)
    {
        var all = new Dictionary<string, CardProgress>(progress, StringComparer.Ordinal);
        foreach (var card in cards)
            if (Mastery.CardStatusOf(all.GetValueOrDefault(card.Id)) != CardStatus.Mastered) all[card.Id] = MasteredAt(t);
        return (LearnEngine.SyncProgress(queued, all, t + 1), all);
    }

    // MARK: - Engine

    [Fact]
    public void RechecksSwitchedOffGoAtOnce()
    {
        var cards = MakeCards(70);
        var (s, _, t) = UntilARecheckIsQueued(cards);
        var off = LearnEngine.SetRecheck(s, false, t + 1);
        Assert.Null(off.Recheck);
        Assert.DoesNotContain(off.Queue, IsRecheck);
        Assert.Equal(s.Queue.Count - s.Queue.Count(IsRecheck), off.Queue.Count);
        // Stored without the key, like a session that never had them.
        Assert.False(off.ToJson().ObjectValue!.ContainsKey("recheck"));
    }

    [Fact]
    public void RechecksSwitchedOnCountFromNowOn()
    {
        var large = LearnEngine.CreateLearn(MakeCards(70), AnswerWith.Term, LearnOptions.Default, now: T0);
        var on = LearnEngine.SetRecheck(large, true, T0).Recheck;
        Assert.NotNull(on);
        Assert.Empty(on.Due);
        // Only sessions with more than 60 cards have rechecks.
        var small = LearnEngine.CreateLearn(MakeCards(60), AnswerWith.Term, LearnOptions.Default, now: T0);
        Assert.Null(LearnEngine.SetRecheck(small, true, T0).Recheck);
        // Already on: the cards waiting stay (nothing changes).
        var (s, _, t) = UntilARecheckIsQueued(MakeCards(70));
        Assert.Same(s, LearnEngine.SetRecheck(s, true, t));
    }

    [Fact]
    public void RepetitionQuestionsSwitchedOffGoAtOnce()
    {
        var cards = MakeCards(9);
        var progress = Mastered(["c1", "c2", "c3", "c4"]);
        var s = LearnEngine.CreateLearn(cards, AnswerWith.Term, new LearnOptions(9), progress: progress, rng: Rand.Mulberry32(3u), now: T0, review: true);
        Assert.Contains(s.Queue, q => LearnEngine.IsReviewQuestion(q.Qid));
        var off = LearnEngine.SetReview(s, false, progress, T0 + 1);
        Assert.Null(off.Review);
        Assert.DoesNotContain(off.Queue, q => LearnEngine.IsReviewQuestion(q.Qid));
        Assert.Null(LearnEngine.ReviewStatsOf(off));
        // They still count as mastered before the session.
        Assert.Equal(s.InitiallyMastered, off.InitiallyMastered);
    }

    [Fact]
    public void RepetitionQuestionsSwitchedOnAskTheMasteredCardsMostOverdueFirst()
    {
        var cards = MakeCards(9);
        // Answered longest ago: c3, then c2, then c1 (whatever the shuffled order).
        var progress = Mastered(["c1", "c2", "c3"]);
        progress["c3"] = progress["c3"] with { LastAnsweredAt = T0 - 900_000 };
        progress["c1"] = progress["c1"] with { LastAnsweredAt = T0 - 1 };
        for (uint seed = 1; seed <= 6; seed++)
        {
            var created = LearnEngine.CreateLearn(cards, AnswerWith.Term, LearnOptions.Default, progress: progress, rng: Rand.Mulberry32(seed), now: T0);
            Assert.Equal(["c3", "c2", "c1"], LearnEngine.SetReview(created, true, progress, T0 + 1).Review?.Due);
        }
        var s = LearnEngine.CreateLearn(cards, AnswerWith.Term, LearnOptions.Default, progress: progress, rng: Rand.Mulberry32(3u), now: T0);
        var on = LearnEngine.SetReview(s, true, progress, T0 + 1);
        Assert.Equal(new LearnEngine.ReviewStats(0, 0, 3), LearnEngine.ReviewStatsOf(on));
        Assert.False(LearnEngine.IsFinished(on));
    }

    [Fact]
    public void ASessionWithNothingLeftButRechecksEndsWhenTheyAreSwitchedOff()
    {
        var cards = MakeCards(62);
        var (queued, progress, t) = UntilARecheckIsQueued(cards);
        var (s, _) = OnlyTheRecheckLeft(cards, queued, progress, t);
        Assert.NotEmpty(s.Queue);
        Assert.All(s.Queue, q => Assert.True(IsRecheck(q)));
        Assert.False(LearnEngine.IsFinished(s));
        var off = LearnEngine.SetRecheck(s, false, t + 2);
        Assert.True(LearnEngine.IsFinished(off));
        Assert.Equal(t + 2, off.FinishedAt);
    }

    [Fact]
    public void AFinishedSessionIsLeftAsItIs()
    {
        var cards = MakeCards(3);
        var s = LearnEngine.CreateLearn(cards, AnswerWith.Term, LearnOptions.Default, progress: Mastered(["c1", "c2", "c3"]), now: T0);
        Assert.True(LearnEngine.IsFinished(s));
        Assert.Same(s, LearnEngine.SetReview(s, true, now: T0 + 1));
    }

    // MARK: - Screen

    [Fact]
    public void AStoredSessionSwitchedKeepsItsOpenMiss()
    {
        var cards = MakeCards(70);
        var (session, _, t) = UntilARecheckIsQueued(cards);
        var feedback = LearnFlow.PendingFeedback.Written("1.1:c1", "c1", AskSide.Term, "faux", false);
        var saved = new LearnFlow.SavedLearn(session, feedback);
        var off = saved.Switching(recheck: false, progress: new Dictionary<string, CardProgress>(), now: t);
        Assert.NotNull(off);
        Assert.Null(off.State.Recheck);
        Assert.Equal(saved.Feedback?.ToJsonString(sortedKeys: true), off.Feedback?.ToJsonString(sortedKeys: true));
        // Nothing to change: null (nothing is written).
        Assert.Null(off.Switching(recheck: false, progress: new Dictionary<string, CardProgress>(), now: t));
        Assert.Null(saved.Switching(progress: new Dictionary<string, CardProgress>(), now: t));
    }

    [Fact]
    public void SwitchingInTheOptionsAppliesWithoutARestart()
    {
        var cards = MakeCards(6);
        var progress = Mastered(["c1", "c2"]);
        var (start, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, rng: Rand.Mulberry32(2u), now: T0);
        var env = new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 1000, progress);
        var (s, _) = LearnFlow.Reduce(start, new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options), env);
        List<LearnFlow.Effect> effects;
        (s, effects) = LearnFlow.Reduce(s, new LearnFlow.Event.ReviewChanged(true), env);
        // At once, also while the options are open (so the stored session is never behind).
        Assert.NotNull(s.Session?.Review);
        Assert.Contains(effects, e => e is LearnFlow.Effect.SaveLearn);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.OverlayDismissed(), env);
        Assert.Null(s.Prompt);
        Assert.NotNull(s.Session?.Review);
    }

    [Fact]
    public void OtherOptionsStillAskToRestartButNotForTheSwitches()
    {
        var cards = MakeCards(70);
        var (start, _) = LearnFlow.Start(Set(cards), new Dictionary<string, CardProgress>(), StudyOptions.Default, recheck: true,
            rng: Rand.Mulberry32(2u), now: T0);
        Assert.NotNull(start.Session?.Recheck);
        var env = new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 1000);
        var (s, _) = LearnFlow.Reduce(start, new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options), env);
        var options = s.Options with { Learn = s.Options.Learn with { RoundSize = 12 } };
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.OptionsChanged(options), env);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.RecheckChanged(false), env);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.OverlayDismissed(), env);
        Assert.Null(s.Session?.Recheck);
        Assert.Equal(new LearnFlow.Prompt.RestartForOptions([LearnFlow.SettingsChange.RoundSize]), s.Prompt);
    }

    [Fact]
    public void ARecheckOnScreenMakesWayWhenTheyAreSwitchedOff()
    {
        var cards = MakeCards(70);
        var (session, progress, t0) = UntilARecheckIsQueued(cards);
        // Up to the recheck, every answer recorded as the app does.
        var stored = session;
        var p = new Dictionary<string, CardProgress>(progress, StringComparer.Ordinal);
        double t = t0;
        while (stored.Queue.FirstOrDefault() is { } q && !IsRecheck(q))
        {
            t += 1000;
            p[q.CardId] = Mastery.ApplyAnswer(p.GetValueOrDefault(q.CardId), true, t);
            stored = LearnEngine.Answer(stored, true, t);
        }
        Assert.True(LearnEngine.MatchesProgress(stored, p));
        var (start, _) = LearnFlow.Start(Set(cards), p, StudyOptions.Default, new LearnFlow.SavedLearn(stored), recheck: true,
            rng: Rand.Mulberry32(2u), now: t + 1000);
        var shown = start.Question;
        Assert.NotNull(shown);
        Assert.True(shown.IsRecheck);
        var env = new LearnFlow.Env(Rand.Mulberry32(2u), t + 2000, p);
        var (after, effects) = LearnFlow.Reduce(start, new LearnFlow.Event.RecheckChanged(false), env);
        Assert.Null(after.Session?.Recheck);
        Assert.NotEqual(true, after.Question?.IsRecheck);
        Assert.True(after.Question?.Qid != shown.Qid || after.Phase != start.Phase);
        Assert.Contains(effects, e => e is LearnFlow.Effect.SaveLearn);
    }

    [Fact]
    public void AResumedSessionFollowsTheRecheckSwitch()
    {
        var cards = MakeCards(70);
        var (session, progress, t) = UntilARecheckIsQueued(cards);
        var (resumed, effects) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, new LearnFlow.SavedLearn(session), recheck: false,
            rng: Rand.Mulberry32(2u), now: t + 1000);
        Assert.Null(resumed.Session?.Recheck);
        Assert.DoesNotContain(resumed.Session!.Queue, IsRecheck);
        Assert.Equal(session.Answered, resumed.Session.Answered);
        Assert.Contains(effects, e => e is LearnFlow.Effect.SaveLearn);
    }

    [Fact]
    public void AResumedSessionFinishedByTheSwitchIsStoredAsFinished()
    {
        // Only a recheck was left: without the Nachkontrolle the session is done, and stored so, or «Weiterlernen» would
        // keep offering it.
        var cards = MakeCards(62);
        var (queued, progress, t) = UntilARecheckIsQueued(cards);
        var (s, all) = OnlyTheRecheckLeft(cards, queued, progress, t);
        Assert.False(LearnEngine.IsFinished(s));
        var (screen, effects) = LearnFlow.Start(Set(cards), all, StudyOptions.Default, new LearnFlow.SavedLearn(s), recheck: false,
            rng: Rand.Mulberry32(2u), now: t + 1000);
        Assert.Equal(LearnFlow.Phase.AllMastered, screen.Phase);
        var saved = effects.OfType<LearnFlow.Effect.SaveLearn>().Select(e => e.State).ToList();
        Assert.Single(saved);
        Assert.NotNull(saved[0].FinishedAt);
        Assert.Equal(s.Answered, saved[0].Answered);
    }

    [Fact]
    public void AResumedSessionKeepsItsRepetitionQuestions()
    {
        // Started for them («Alle wiederholen»): the switch being off does not end them.
        var cards = MakeCards(5);
        var progress = Mastered(cards.Select(c => c.Id));
        var (first, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, review: true, rng: Rand.Mulberry32(2u), now: T0);
        var session = first.Session!;
        Assert.NotNull(session.Review);
        var (resumed, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, new LearnFlow.SavedLearn(session), review: false,
            rng: Rand.Mulberry32(2u), now: T0 + 1000);
        Assert.NotNull(resumed.Session?.Review);
        Assert.True(resumed.Question?.IsReview);
    }

    [Fact]
    public void SwitchingRechecksDoesNotEndRepetitionQuestionsStartedForThem()
    {
        var cards = MakeCards(5);
        var progress = Mastered(cards.Select(c => c.Id));
        var (first, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, review: true, rng: Rand.Mulberry32(2u), now: T0);
        var (resumed, _) = LearnFlow.Start(Set(cards), progress, StudyOptions.Default, new LearnFlow.SavedLearn(first.Session!), review: false,
            rng: Rand.Mulberry32(2u), now: T0 + 1000, recheck: true);
        var env = new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 2000, progress);
        var (s, _) = LearnFlow.Reduce(resumed, new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options), env);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.RecheckChanged(false), env);
        (s, _) = LearnFlow.Reduce(s, new LearnFlow.Event.OverlayDismissed(), env);
        Assert.NotNull(s.Session?.Review);
    }
}
