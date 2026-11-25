using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LearnSessionSimulationTests.swift.
// Whole Learn sessions played through the screen logic (LearnFlow), as the app does: every answer is recorded in the
// progress the next step reads, with random right and wrong answers, "Weiss ich nicht?", "Ich hatte recht" and
// checkpoints. They check the promise behind the options: a card answered right twice in a row is mastered and not
// asked again, unless a repetition question (Wiederholungsfragen) or a recheck (Nachkontrolle) asks it once more, and
// only while that option is on (Anthony 24.11.2026: «words I did correctly a second time come again»).
public class LearnSessionSimulationTests
{
    const double T0 = 1_760_000_000_000;

    static List<Card> MakeCards(int n) => Enumerable.Range(1, n).Select(i => new Card($"c{i}", $"terme {i}", $"Begriff {i}")).ToList();

    static VocabSet Set(List<Card> cards) => new() { Id = "set1", Title = "Wörter", TermLang = Lang.Fr, DefLang = Lang.De, Cards = cards, CreatedAt = T0 };

    static CardProgress MasteredBefore() => new(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 9000);

    /// <summary>One question as it was shown, with the progress of its card at that moment.</summary>
    /// <param name="MissedBefore">The card was answered wrong earlier in the session (and not corrected).</param>
    sealed record Asked(LearnFlow.QuestionInfo Question, int Streak, bool MissedBefore);

    sealed record Outcome(List<Asked> AskedList, Dictionary<string, CardProgress> Progress, LearnFlow.State State);

    /// <summary>
    /// Plays a session from LearnFlow.Start to its end. rightChance in percent; a wrong written answer is now and then
    /// corrected with "Ich hatte recht".
    /// </summary>
    static Outcome Play(List<Card> cards, Dictionary<string, CardProgress>? start = null, StudyOptions? options = null, bool review = false,
        bool recheck = false, int seed = 1, int rightChance = 70)
    {
        var progress = new Dictionary<string, CardProgress>(start ?? [], StringComparer.Ordinal);
        var pick = Rand.Mulberry32((long)seed + 1000);
        int Roll(int n) => (int)(pick() * n);
        double now = T0;
        var (state, effects) = LearnFlow.Start(Set(cards), progress, options ?? StudyOptions.Default, review: review, recheck: recheck,
            rng: Rand.Mulberry32((long)seed), now: now);
        var asked = new List<Asked>();
        var misses = new Dictionary<string, int>(StringComparer.Ordinal);

        void Apply(List<LearnFlow.Effect> list)
        {
            foreach (var effect in list)
            {
                switch (effect)
                {
                    case LearnFlow.Effect.RecordAnswer r:
                        progress[r.CardId] = Mastery.ApplyAnswer(progress.GetValueOrDefault(r.CardId), r.Correct, r.At);
                        if (!r.Correct) misses[r.CardId] = misses.GetValueOrDefault(r.CardId) + 1;
                        break;
                    case LearnFlow.Effect.OverrideLastAnswer o:
                        progress[o.CardId] = Mastery.ApplyOverride(progress.GetValueOrDefault(o.CardId));
                        misses[o.CardId] = misses.GetValueOrDefault(o.CardId, 1) - 1;
                        break;
                    case LearnFlow.Effect.ResetProgress reset:
                        if (reset.CardIds is { } ids) foreach (var id in ids) progress.Remove(id);
                        else progress.Clear();
                        break;
                }
            }
        }
        void Send(LearnFlow.Event e)
        {
            // Past every input lock and auto-advance delay.
            now += 5000;
            var env = new LearnFlow.Env(Rand.Mulberry32((long)seed + (long)(now % 997)), now, progress);
            (state, effects) = LearnFlow.Reduce(state, e, env);
            Apply(effects);
        }
        Apply(effects);

        int steps = 0;
        while (true)
        {
            Assert.True(++steps < 20_000, "the session did not end");
            switch (state.Phase.Kind)
            {
                case LearnFlow.PhaseKind.Question:
                {
                    var q = state.Question!;
                    asked.Add(new Asked(q, progress.GetValueOrDefault(q.CardId)?.Streak ?? 0, misses.GetValueOrDefault(q.CardId) > 0));
                    bool right = Roll(100) < rightChance;
                    if (state.Phase.QuestionType == QuestionType.Mc)
                    {
                        int correct = q.Choices.ToList().FindIndex(c => c.CardId == q.CardId);
                        if (right) Send(new LearnFlow.Event.Choose(correct));
                        else if (Roll(4) == 0) Send(new LearnFlow.Event.DontKnow());
                        else Send(new LearnFlow.Event.Choose((correct + 1) % q.Choices.Count));
                    }
                    else if (right)
                    {
                        Send(new LearnFlow.Event.Submit(q.Expected));
                    }
                    else if (Roll(5) == 0)
                    {
                        Send(new LearnFlow.Event.DontKnow());
                    }
                    else
                    {
                        Send(new LearnFlow.Event.Submit("xyz"));
                        // "Ich hatte recht" now and then.
                        if (Roll(6) == 0) Send(new LearnFlow.Event.Override());
                    }
                    // The store echoes the answer back to the screen.
                    Send(new LearnFlow.Event.ProgressChanged());
                    break;
                }
                case LearnFlow.PhaseKind.Feedback or LearnFlow.PhaseKind.Checkpoint:
                    Send(new LearnFlow.Event.Proceed());
                    break;
                case LearnFlow.PhaseKind.Copy:
                    Send(new LearnFlow.Event.Submit(state.Question!.Expected));
                    break;
                default:
                    return new Outcome(asked, progress, state);
            }
        }
    }

    /// <summary>Without repetition questions and rechecks no card is asked once it was answered right twice in a row (in this session or before it).</summary>
    [Theory]
    [InlineData(5)]
    [InlineData(12)]
    [InlineData(40)]
    [InlineData(75)]
    public void ACardRightTwiceInARowIsNotAskedAgain(int cardCount)
    {
        var cards = MakeCards(cardCount);
        for (int seed = 1; seed <= 6; seed++)
        {
            foreach (var (mc, written) in new[] { (true, true), (false, true), (true, false) })
            {
                var options = StudyOptions.Default with
                {
                    Learn = StudyOptions.Default.Learn with { Mc = mc, Written = written, RoundSize = new[] { 7, 15, 30 }[seed % 3] },
                };
                var run = Play(cards, options: options, seed: seed, rightChance: new[] { 50, 70, 90 }[seed % 3]);
                var again = run.AskedList.Where(a => a.Streak >= Mastery.MASTERY_STREAK).ToList();
                Assert.True(again.Count == 0,
                    $"seed {seed}, {cardCount} cards, mc {mc}, written {written}: asked again after two right answers: {string.Join(", ", again.Select(a => a.Question.Qid))}");
                Assert.Equal(LearnFlow.Phase.Finished, run.State.Phase);
                Assert.All(cards, c => Assert.Equal(CardStatus.Mastered, Mastery.CardStatusOf(run.Progress.GetValueOrDefault(c.Id))));
                Assert.DoesNotContain(run.AskedList, a => a.Question.IsReview || a.Question.IsRecheck);
            }
        }
    }

    /// <summary>Cards mastered before the session (and those answered right once before) need what is left: none / one more right answer.</summary>
    [Fact]
    public void ProgressFromBeforeTheSessionCounts()
    {
        var cards = MakeCards(20);
        var start = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        foreach (var card in cards.Take(6)) start[card.Id] = MasteredBefore();
        foreach (var card in cards.Skip(6).Take(6))
            start[card.Id] = new CardProgress(Correct: 1, Streak: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 9000);
        for (int seed = 1; seed <= 10; seed++)
        {
            var run = Play(cards, start, seed: seed, rightChance: 100);
            var asked = run.AskedList.GroupBy(a => a.Question.CardId).ToDictionary(g => g.Key, g => g.Count());
            foreach (var card in cards.Take(6)) Assert.False(asked.ContainsKey(card.Id), $"mastered {card.Id} asked");
            foreach (var card in cards.Skip(6).Take(6)) Assert.True(asked.GetValueOrDefault(card.Id) == 1, $"{card.Id} asked {asked.GetValueOrDefault(card.Id)}×");
            foreach (var card in cards.Skip(12)) Assert.True(asked.GetValueOrDefault(card.Id) == 2, $"{card.Id} asked {asked.GetValueOrDefault(card.Id)}×");
        }
    }

    /// <summary>
    /// With the options on, a mastered card comes back only as what they promise: a recheck of a card missed in this
    /// session, a repetition question of a card mastered before it.
    /// </summary>
    [Fact]
    public void WithTheOptionsOnACardComesBackOnlyAsTheyPromise()
    {
        var cards = MakeCards(75);
        var start = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        foreach (var card in cards.Take(10)) start[card.Id] = MasteredBefore();
        var before = cards.Take(10).Select(c => c.Id).ToHashSet();
        for (int seed = 1; seed <= 6; seed++)
        {
            var run = Play(cards, start, review: true, recheck: true, seed: seed);
            foreach (var a in run.AskedList)
            {
                var q = a.Question;
                if (a.Streak < Mastery.MASTERY_STREAK) continue;
                if (q.IsReview)
                {
                    Assert.True(before.Contains(q.CardId), $"seed {seed}: repetition question of {q.CardId}");
                }
                else
                {
                    Assert.True(q.IsRecheck, $"seed {seed}: {q.Qid} asked again after two right answers");
                    Assert.True(a.MissedBefore, $"seed {seed}: recheck of {q.CardId}, never missed");
                }
            }
            Assert.True(run.AskedList.Any(a => a.Question.IsRecheck), $"seed {seed}: no recheck at all");
            Assert.Equal(LearnFlow.Phase.Finished, run.State.Phase);
        }
    }
}
