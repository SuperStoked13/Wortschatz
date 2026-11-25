using Wortschatz.Core;
using Xunit;
using Effect = Wortschatz.Core.LearnFlow.Effect;
using Event = Wortschatz.Core.LearnFlow.Event;
using Flow = Wortschatz.Core.LearnFlow;
using FK = Wortschatz.Core.LearnFlow.FeedbackKind;
using Phase = Wortschatz.Core.LearnFlow.Phase;

namespace Wortschatz.Core.Tests;

// Port of LearnFlowTests.swift: the Learn screen reducer (spec §6): every phase, the Enter-only key map
// of spec §4.3, "one Return = one transition", auto-advance tokens, persistence and resume, subsets, live
// changes of cards, progress and options. The Driver plays the screen like the app does: it applies the
// effects to an in-memory store and hands the stored progress back in Env. (Swift's "theStateIsCodable"
// has no counterpart: the C# state is not serialised.)
public class LearnFlowTests
{
    const double T0 = 1_760_000_000_000;

    static List<Card> MakeCards(int n) => Enumerable.Range(0, n).Select(i => new Card($"c{i + 1}", $"terme {i + 1}", $"Begriff {i + 1}", i % 3 == 0)).ToList();

    static VocabSet MakeSet(IReadOnlyList<Card> cards, Lang termLang = Lang.Fr, Lang defLang = Lang.De) =>
        new() { Id = "set1", Title = "Wörter", TermLang = termLang, DefLang = defLang, Cards = cards.ToList(), CreatedAt = T0 };

    /// <summary>Every card familiar (streak 1): questions are written.</summary>
    static Dictionary<string, CardProgress> Familiar(IEnumerable<Card> cards) =>
        cards.ToDictionary(c => c.Id, _ => new CardProgress(Correct: 1, Streak: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 1000));

    static Dictionary<string, CardProgress> Mastered(IEnumerable<Card> cards) =>
        cards.ToDictionary(c => c.Id, _ => new CardProgress(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0 - 1000));

    static StudyOptions Options(bool retype = false, int roundSize = 7, bool audio = false, AnswerWith answerWith = AnswerWith.Term) =>
        new() { AnswerWith = answerWith, Audio = audio, Learn = new LearnOptions(roundSize, Retype: retype) };

    /// <summary>A comparable snapshot of a state (Swift compares the struct with ==).</summary>
    static string Key(Flow.State s) => JSONValue.Obj(
        ("phase", s.Phase.ToString()), ("session", s.Session?.ToJson() ?? JSONValue.Null), ("setTitle", s.SetTitle),
        ("cards", s.Cards.ToJsonArray()), ("options", s.Options.ToJson()), ("review", s.Review), ("subset", s.Subset.ToJson()),
        ("scope", s.ScopeCardIds.ToJsonArray()),
        ("question", s.Question is { } q ? JSONValue.Obj(("q", q with { Choices = [], StoredChoices = [] } is var bare ? bare.ToString() : ""),
            ("choices", q.Choices.ToJsonArray()), ("stored", q.StoredChoices.ToJsonArray())) : JSONValue.Null),
        ("feedback", s.Feedback is { } f ? JSONValue.Obj(("f", (f with { Result = null }).ToString()), ("r", f.Result?.ToJson() ?? JSONValue.Null)) : JSONValue.Null),
        ("highlighted", JSONValue.Nullable(s.Highlighted)), ("typed", s.Typed), ("draft", s.Draft), ("pending", s.Pending.ToJsonOrNull()),
        ("roundStart", s.RoundStartCounts?.ToString() ?? ""), ("prompt", s.Prompt?.ToString() ?? ""), ("overlay", s.Overlay?.ToString() ?? ""),
        ("optionsBefore", s.OptionsBeforeOverlay?.ToJson() ?? JSONValue.Null), ("recheck", s.Recheck),
        ("token", JSONValue.Nullable(s.AutoAdvanceToken)), ("lastToken", s.LastToken), ("paused", s.AutoAdvancePaused), ("praise", s.LastPraise ?? ""),
        ("lock", s.InputLockedUntil), ("rejections", s.Rejections), ("transitions", s.Transitions)).ToString();

    static string J(LearnState? s) => s?.ToJson().ToString() ?? "null";

    /// <summary>Plays the Learn screen like the app: effects go to an in-memory store, timers fire on request, every event is ms after the previous one.</summary>
    sealed class Driver
    {
        public Flow.State State;
        public readonly List<Effect> Log = [];
        public List<Effect> Last = [];
        public Dictionary<string, CardProgress> Progress;
        public Flow.SavedLearn? Saved;
        public List<Card> Cards;
        public double Now;
        readonly RNG rng;
        public readonly List<(int Token, int Ms)> Timers = [];
        public readonly List<Flow.Destination> Navigated = [];

        public Driver(VocabSet set, Dictionary<string, CardProgress>? progress = null, StudyOptions? options = null, Flow.SavedLearn? saved = null,
            StudySubset? subset = null, bool forceNew = false, uint seed = 1, double now = T0)
        {
            Progress = progress is null ? new(StringComparer.Ordinal) : new(progress, StringComparer.Ordinal);
            Saved = saved;
            Cards = [.. set.Cards];
            Now = now;
            rng = Rand.Mulberry32(seed);
            var (s, effects) = Flow.Start(set, Progress, options ?? StudyOptions.Default, saved, subset, forceNew, rng: rng, now: now);
            State = s;
            Apply(effects);
        }

        public List<Effect> Send(Event e, double after = 1000)
        {
            Now += after;
            var (s, effects) = Flow.Reduce(State, e, new Flow.Env(rng, Now, new Dictionary<string, CardProgress>(Progress, StringComparer.Ordinal)));
            State = s;
            Apply(effects);
            return effects;
        }

        public List<Effect> Press(KeyInput key, bool isRepeat = false, double after = 1000) => Send(new Event.Key(key, isRepeat), after);

        public void Type(string text) => Send(new Event.DraftChanged(text), 100);

        void Apply(List<Effect> effects)
        {
            Last = effects;
            Log.AddRange(effects);
            foreach (var effect in effects)
            {
                switch (effect)
                {
                    case Effect.RecordAnswer r: Progress[r.CardId] = Mastery.ApplyAnswer(Progress.GetValueOrDefault(r.CardId), r.Correct, r.At); break;
                    case Effect.OverrideLastAnswer o:
                        if (Progress.TryGetValue(o.CardId, out var p) && p.LastResult == AnswerResult.Incorrect) Progress[o.CardId] = Mastery.ApplyOverride(p);
                        break;
                    case Effect.ResetProgress reset:
                        if (reset.CardIds is { } ids) foreach (var id in ids) Progress.Remove(id);
                        else Progress.Clear();
                        break;
                    case Effect.SaveLearn save: Saved = new Flow.SavedLearn(save.State, save.Feedback); break;
                    case Effect.ClearLearn: Saved = null; break;
                    case Effect.ScheduleAutoAdvance a: Timers.Add((a.Token, a.Ms)); break;
                    case Effect.UpdateCard u:
                    {
                        int i = Cards.FindIndex(c => c.Id == u.Card.Id);
                        if (i >= 0) Cards[i] = u.Card;
                        break;
                    }
                    case Effect.ToggleStar t:
                    {
                        int i = Cards.FindIndex(c => c.Id == t.CardId);
                        if (i >= 0) Cards[i] = Cards[i] with { Starred = !Cards[i].Starred };
                        break;
                    }
                    case Effect.Navigate n: Navigated.Add(n.Destination); break;
                }
            }
        }

        /// <summary>Fires the most recent auto-advance timer.</summary>
        public List<Effect> FireTimer() => Timers.Count == 0 ? [] : Send(new Event.AutoAdvanceFired(Timers[^1].Token), Timers[^1].Ms);

        public Flow.QuestionInfo? Question => State.Question;
        public int? CorrectIndex => Question is { } q && q.Choices.ToList().FindIndex(c => c.CardId == q.CardId) is var i and >= 0 ? i : null;
        public int? WrongIndex => Question is { } q && q.Choices.ToList().FindIndex(c => c.CardId != q.CardId) is var i and >= 0 ? i : null;

        /// <summary>Answers the question on screen with keys only: a digit for multiple choice, typing and Enter for a written question.</summary>
        public void AnswerByKeys(bool correct)
        {
            if (Question is not { } q) return;
            if (q.Type == QuestionType.Mc) Press(KeyInput.DigitKey((correct ? CorrectIndex!.Value : WrongIndex!.Value) + 1));
            else
            {
                Type(correct ? q.Expected : "ganz falsch");
                Press(KeyInput.Return);
            }
        }

        public JSONValue? SavedFeedback => Saved?.Feedback;
        public bool Announced(string text) => Last.Contains(new Effect.Announce(text));
        public string? LastAnnouncement => Last.OfType<Effect.Announce>().LastOrDefault()?.Text;
        public List<int> Scheduled => Last.OfType<Effect.ScheduleAutoAdvance>().Select(a => a.Token).ToList();
    }

    static readonly Phase Correct = Phase.FeedbackOf(FK.Correct);
    static readonly Phase Wrong = Phase.FeedbackOf(FK.Wrong);
    static readonly Phase DontKnowPhase = Phase.FeedbackOf(FK.DontKnow);

    // MARK: - Start

    [Fact]
    public void StartsANewSessionWithAMultipleChoiceQuestion()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        Assert.Equal(Phase.Mc, d.State.Phase);
        var q = d.Question!;
        Assert.Equal(4, q.Choices.Count);
        Assert.Equal("Deutsch", q.PromptLabel);
        Assert.StartsWith("Begriff ", q.Prompt);
        Assert.Equal(6, d.State.Session?.Order.Count);
        Assert.Equal(J(d.State.Session), J(d.Saved?.State));
        Assert.Equal($"Deutsch: {q.Prompt}. Wähle die richtige Antwort, 1 bis 4.", d.LastAnnouncement);
        Assert.Null(Flow.ReturnAction(d.State)); // nothing highlighted yet
        Assert.Equal(1, d.State.Transitions);
        Assert.True(d.State.ShowsIntroHint);
        Assert.Equal(6, d.State.Counts.Fresh);
        Assert.Equal(1, d.State.Segments);
        Assert.DoesNotContain(d.Log, e => e is Effect.Toast);
    }

    [Fact]
    public void EmptySetsAndEmptySubsets()
    {
        var d = new Driver(MakeSet([]));
        Assert.Equal(Phase.Empty, d.State.Phase);
        Assert.Null(d.State.Session);
        Assert.Equal("Noch keine Begriffe zum Üben", Flow.MessageOf(d.State)?.Title);
        Assert.Equal("Begriffe hinzufügen", Flow.ReturnAction(d.State));
        d.Press(KeyInput.Return);
        Assert.Equal([Flow.Destination.EditSet], d.Navigated);

        var cards = MakeCards(4).Select(c => c with { Starred = false }).ToList();
        var s = new Driver(MakeSet(cards), subset: StudySubset.Starred);
        Assert.Equal(Phase.Empty, s.State.Phase);
        Assert.Equal(StudySubset.Starred, s.State.Subset);
        Assert.Equal("Keine markierten Begriffe", Flow.MessageOf(s.State)?.Title);
        Assert.Equal("Alle Begriffe üben", Flow.ReturnAction(s.State));
        s.Press(KeyInput.Return);
        Assert.Equal(Phase.Mc, s.State.Phase);
        Assert.Equal(StudySubset.All, s.State.Session?.Subset);

        var missed = new Driver(MakeSet(cards), subset: StudySubset.Missed);
        Assert.Equal("Keine falschen Begriffe", Flow.MessageOf(missed.State)?.Title);
        missed.Send(new Event.StudyAll());
        Assert.Equal(Phase.Mc, missed.State.Phase);
    }

    [Fact]
    public void EverythingMasteredAtStartOffersToRelearn()
    {
        var cards = MakeCards(4);
        var d = new Driver(MakeSet(cards), Mastered(cards));
        Assert.Equal(Phase.AllMastered, d.State.Phase);
        Assert.Null(d.State.Session);
        Assert.Null(d.Saved);
        Assert.Contains("alle 4 Begriffe", Flow.MessageOf(d.State)!.Text);
        Assert.Equal("Fortschritt zurücksetzen und neu lernen", Flow.ReturnAction(d.State));
        d.Press(KeyInput.Return);
        Assert.Equal(new Flow.Prompt.Relearn(d.State.ScopeCardIds), d.State.Prompt);
        Assert.True(Flow.PromptContentOf(d.State)?.IsDestructive);
        Assert.Contains("dieser 4 Begriffe", Flow.PromptContentOf(d.State)!.Message);
        // Keys are ignored while the prompt is open.
        d.Press(KeyInput.Return);
        Assert.NotNull(d.State.Prompt);
        d.Send(new Event.PromptAnswered(false));
        Assert.True(d.State.Phase == Phase.AllMastered && d.State.Prompt is null);
        d.Press(KeyInput.Return);
        d.Send(new Event.PromptAnswered(true));
        Assert.Equal(new Effect.ResetProgress(null), d.Last[0]);
        Assert.Empty(d.Progress);
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.Equal(4, d.State.Counts.Fresh);
    }

    [Fact]
    public void RelearnOfASubsetResetsOnlyItsCards()
    {
        var cards = MakeCards(6); // starred: c1, c4
        var d = new Driver(MakeSet(cards), Mastered(cards), subset: StudySubset.Starred);
        Assert.Equal(Phase.AllMastered, d.State.Phase);
        Assert.Contains("alle 2 markierten Begriffe", Flow.MessageOf(d.State)!.Text);
        var ids = d.State.ScopeCardIds.ToList();
        Assert.Equal(["c1", "c4"], ids.Order());
        d.Send(new Event.Relearn());
        d.Send(new Event.PromptAnswered(true));
        Assert.Equal(new Effect.ResetProgress(ids), d.Last[0]);
        Assert.False(d.Progress.ContainsKey("c1") || d.Progress.ContainsKey("c4"));
        Assert.True(d.Progress.ContainsKey("c2"));
        Assert.Equal(["c1", "c4"], d.State.Session!.Order.Order());
        Assert.Equal(StudySubset.Starred, d.State.Session.Subset);
    }

    // MARK: - Multiple choice

    [Fact]
    public void ArrowsMoveTheHighlightAndReturnChoosesIt()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        Assert.Null(d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Down));
        Assert.Equal(0, d.State.Highlighted); // the first press lands on option 1
        Assert.StartsWith("Antwort 1: ", d.LastAnnouncement);
        d.Press(KeyInput.Arrow(Direction.Right));
        Assert.Equal(1, d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Right));
        Assert.Equal(1, d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Down));
        Assert.Equal(3, d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Left));
        Assert.Equal(2, d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Up));
        Assert.Equal(0, d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Up));
        Assert.Equal(0, d.State.Highlighted);
        Assert.Equal(Flow.OptionState.Highlighted, Flow.OptionStateOf(d.State, 0));
        Assert.Equal(Flow.OptionState.Idle, Flow.OptionStateOf(d.State, 1));
        Assert.Equal("Auswählen", Flow.ReturnAction(d.State));
        int target = d.CorrectIndex!.Value;
        if (target % 2 == 1) d.Press(KeyInput.Arrow(Direction.Right));
        if (target >= 2) d.Press(KeyInput.Arrow(Direction.Down));
        Assert.Equal(target, d.State.Highlighted);
        int transitions = d.State.Transitions;
        d.Press(KeyInput.Return);
        Assert.Equal(Correct, d.State.Phase);
        Assert.Equal(target, d.State.Feedback?.ChosenIndex);
        Assert.Equal(transitions + 1, d.State.Transitions);
    }

    [Fact]
    public void ArrowsOnThreeOptionsStayInTheGrid()
    {
        var d = new Driver(MakeSet(MakeCards(3)));
        Assert.Equal(3, d.Question?.Choices.Count);
        d.Press(KeyInput.Arrow(Direction.Right));
        Assert.Equal(0, d.State.Highlighted);
        d.Press(KeyInput.Arrow(Direction.Right));
        d.Press(KeyInput.Arrow(Direction.Down));
        Assert.Equal(2, d.State.Highlighted); // from the top right to the lone tile below
        d.Press(KeyInput.Arrow(Direction.Right));
        Assert.Equal(2, d.State.Highlighted);
        d.Send(new Event.Highlight(1));
        Assert.Equal(1, d.State.Highlighted);
        d.Send(new Event.Highlight(7));
        Assert.Null(d.State.Highlighted);
    }

    [Fact]
    public void ReturnWithoutAHighlightDoesNothing()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        var before = Key(d.State);
        d.Press(KeyInput.Return);
        Assert.Equal(before, Key(d.State));
        Assert.Empty(d.Last);
    }

    [Fact]
    public void DigitsChooseDirectlyZeroAndOptionReturnAreWeissIchNicht()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        var before = Key(d.State);
        d.Press(KeyInput.DigitKey(9));
        Assert.Equal(before, Key(d.State));
        d.Press(KeyInput.DigitKey(5));
        Assert.Equal(before, Key(d.State));
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        Assert.Equal(Correct, d.State.Phase);

        var z = new Driver(MakeSet(MakeCards(6)));
        var q = z.Question!;
        z.Press(KeyInput.DigitKey(0));
        Assert.Equal(DontKnowPhase, z.State.Phase);
        Assert.Equal(Flow.DONT_KNOW_TITLE, z.State.Feedback?.Title);
        Assert.Null(z.State.Feedback?.ChosenIndex);
        Assert.Equal(Flow.PendingFeedback.Mc(q.Qid, q.CardId, q.Ask, q.StoredChoices, null), z.State.Pending);
        Assert.Contains(new Effect.RecordAnswer(q.CardId, false, z.Now), z.Last);
        Assert.DoesNotContain(new Effect.Haptic(HapticKind.Failure), z.Last);
        Assert.True(z.Announced($"Kein Problem. Richtige Antwort: {q.Expected}."));

        var o = new Driver(MakeSet(MakeCards(6)));
        o.Press(KeyInput.OptionReturn);
        Assert.Equal(DontKnowPhase, o.State.Phase);
        var c = new Driver(MakeSet(MakeCards(6)));
        c.Send(new Event.DontKnow());
        Assert.Equal(DontKnowPhase, c.State.Phase);
    }

    [Fact]
    public void ACorrectChoicePraisesAndAdvancesByItself()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        var q = d.Question!;
        int index = d.CorrectIndex!.Value;
        d.Press(KeyInput.DigitKey(index + 1));
        var f = d.State.Feedback!;
        Assert.Equal(Correct, d.State.Phase);
        Assert.Contains(f.Title, Flow.PRAISE);
        Assert.Equal(Flow.ADVANCE_MS, f.AutoAdvanceMs);
        Assert.Contains(new Effect.RecordAnswer(q.CardId, true, d.Now), d.Last);
        Assert.Contains(new Effect.Haptic(HapticKind.Success), d.Last);
        Assert.Contains(new Effect.Announce(f.Title), d.Last);
        Assert.Equal([d.State.AutoAdvanceToken!.Value], d.Scheduled);
        Assert.Null(d.Saved?.Feedback);
        Assert.Equal(Flow.OptionState.Correct, Flow.OptionStateOf(d.State, index));
        Assert.All(Enumerable.Range(0, 4).Where(i => i != index), i => Assert.Equal(Flow.OptionState.Dimmed, Flow.OptionStateOf(d.State, i)));
        Assert.Equal("Weiter", Flow.ReturnAction(d.State));
        Assert.Equal(1, d.Progress[q.CardId].Streak);
        int transitions = d.State.Transitions;
        d.FireTimer();
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.NotEqual(q.Qid, d.Question?.Qid);
        Assert.Equal(transitions + 1, d.State.Transitions);
    }

    [Fact]
    public void AWrongChoiceShowsTheRightOptionAndWaitsForReturn()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        var q = d.Question!;
        int wrong = d.WrongIndex!.Value;
        d.Press(KeyInput.DigitKey(wrong + 1));
        Assert.Equal(Wrong, d.State.Phase);
        Assert.Equal(Flow.MISS_TITLE, d.State.Feedback?.Title);
        Assert.Equal(Flow.OptionState.Correct, Flow.OptionStateOf(d.State, d.CorrectIndex!.Value));
        Assert.Equal(Flow.OptionState.Wrong, Flow.OptionStateOf(d.State, wrong));
        Assert.Contains(new Effect.Haptic(HapticKind.Failure), d.Last);
        Assert.Empty(d.Scheduled);
        Assert.Null(d.State.AutoAdvanceToken);
        // The open miss is stored next to the session (for a relaunch).
        Assert.Equal(q.Choices[wrong].CardId, d.SavedFeedback?["chosen"]?.StringValue);
        // A Return right after the feedback appeared is swallowed.
        d.Press(KeyInput.Return, after: 100);
        Assert.Equal(Wrong, d.State.Phase);
        d.Press(KeyInput.Return, after: 500);
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.NotEqual(q.Qid, d.Question?.Qid);
        Assert.Null(d.Saved?.Feedback);
    }

    [Fact]
    public void AnyKeyContinuesAfterMcFeedbackWithoutPickingInTheNextQuestion()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        d.Press(KeyInput.DigitKey(d.WrongIndex!.Value + 1));
        var answered = d.State.Session?.Answered;
        d.Press(KeyInput.DigitKey(1));
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.Equal(answered, d.State.Session?.Answered);
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        d.Press(KeyInput.Character("x"));
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.Equal("", d.State.Draft);
    }

    [Fact]
    public void KeyRepeatsNeverTransition()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        foreach (var key in new[] { KeyInput.Return, KeyInput.DigitKey(1), KeyInput.DigitKey(0), KeyInput.OptionReturn, KeyInput.Arrow(Direction.Down), KeyInput.Character("a") })
        {
            var before = Key(d.State);
            d.Press(key, isRepeat: true);
            Assert.Equal(before, Key(d.State));
            Assert.Empty(d.Last);
        }
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        var after = Key(d.State);
        d.Press(KeyInput.Return, isRepeat: true);
        Assert.Equal(after, Key(d.State));
    }

    [Fact]
    public void APressWithinTheLockAfterACorrectAnswerMovesOnWhenTheLockEnds()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        Assert.Equal(Correct, d.State.Phase);
        var qid = d.Question?.Qid;
        int first = d.State.AutoAdvanceToken!.Value;
        // The answering press itself (delivered twice) does nothing.
        d.Press(KeyInput.Return, after: 10);
        Assert.Equal(first, d.State.AutoAdvanceToken);
        Assert.Empty(d.Last);
        // A deliberate second press is kept: the advance moves up to the end of the lock.
        d.Press(KeyInput.Return, after: 140);
        Assert.Equal(Correct, d.State.Phase);
        int token = d.State.AutoAdvanceToken!.Value;
        Assert.NotEqual(first, token);
        Assert.Equal([new Effect.ScheduleAutoAdvance(130, token)], d.Last);
        // The original timer is stale now; the new one moves on.
        d.Send(new Event.AutoAdvanceFired(first), after: 0);
        Assert.Equal(Correct, d.State.Phase);
        d.Send(new Event.AutoAdvanceFired(token), after: 130);
        Assert.NotEqual(qid, d.Question?.Qid);
        Assert.NotEqual(Correct, d.State.Phase);

        // A miss stays on screen for the whole lock.
        var w = new Driver(MakeSet(MakeCards(6)));
        w.Press(KeyInput.DigitKey(w.WrongIndex!.Value + 1));
        var before = Key(w.State);
        w.Press(KeyInput.Return, after: 140);
        Assert.Equal(before, Key(w.State));
        Assert.Empty(w.Last);
    }

    [Fact]
    public void ClicksAreNotSwallowedButKeysRightAfterATransitionAre()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        d.Press(KeyInput.DigitKey(d.WrongIndex!.Value + 1));
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Mc, d.State.Phase);
        // A digit within the input lock is swallowed; a click on a tile is not.
        var before = Key(d.State);
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1), after: 100);
        Assert.Equal(before, Key(d.State));
        d.Send(new Event.Choose(d.CorrectIndex!.Value), after: 10);
        Assert.Equal(Correct, d.State.Phase);
        // Clicks on the primary button respect the lock like Return does.
        d.Send(new Event.Proceed(), after: 50);
        Assert.Equal(Correct, d.State.Phase);
        d.Send(new Event.Proceed(), after: 500);
        Assert.Equal(Phase.Mc, d.State.Phase);
        // Clicking an option during feedback does nothing.
        d.Send(new Event.Choose(0));
        Assert.NotNull(d.State.Feedback);
        var feedback = Key(d.State);
        d.Send(new Event.Choose(1));
        Assert.Equal(feedback, Key(d.State));
    }

    // MARK: - Auto-advance

    [Fact]
    public void AutoAdvanceUsesTokensSoAStaleTimerCannotAdvanceTwice()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        int token = d.State.AutoAdvanceToken!.Value;
        // Return before the timer.
        d.Press(KeyInput.Return, after: 400);
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.Null(d.State.AutoAdvanceToken);
        var after = Key(d.State);
        d.Send(new Event.AutoAdvanceFired(token), after: 500);
        Assert.Equal(after, Key(d.State));
        Assert.Empty(d.Last);
        // A new answer gets a new token.
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        Assert.Equal(token + 1, d.State.AutoAdvanceToken);
    }

    [Fact]
    public void OverlaysPauseTheAutoAdvanceAndRestartItWhenClosed()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        int token = d.State.AutoAdvanceToken!.Value;
        d.Send(new Event.OverlayPresented(Flow.Overlay.Editor), after: 200);
        Assert.Null(d.State.AutoAdvanceToken);
        Assert.True(d.State.AutoAdvancePaused);
        d.Send(new Event.AutoAdvanceFired(token));
        Assert.Equal(Correct, d.State.Phase);
        d.Press(KeyInput.Return);
        Assert.Equal(Correct, d.State.Phase);
        Assert.Null(Flow.ReturnAction(d.State));
        d.Send(new Event.OverlayDismissed());
        Assert.Single(d.Scheduled);
        Assert.Equal(d.Scheduled[0], d.State.AutoAdvanceToken);
        d.FireTimer();
        Assert.Equal(Phase.Mc, d.State.Phase);
    }

    // MARK: - Written

    [Fact]
    public void WrittenAnswersAreGradedWithTheTolerance()
    {
        List<Card> cards = [new("a", "la rue", "die Strasse"), new("b", "le chemin", "der Weg")];
        var d = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["a"]));
        Assert.Equal(Phase.Written, d.State.Phase);
        Assert.Equal("Antworten", Flow.ReturnAction(d.State));
        Assert.Equal("Antwort auf Französisch eingeben", d.Question?.Placeholder);
        d.Type("rue");
        d.Press(KeyInput.Return);
        var f = d.State.Feedback!;
        Assert.Equal(Correct, d.State.Phase);
        Assert.Equal(Flow.TOLERATED_TITLE, f.Title);
        Assert.Equal("Genau:", f.ExactLabel);
        Assert.Equal("rue", f.Given);
        Assert.Contains(GradeNote.Article, f.Result!.Notes);
        Assert.Equal(Flow.ADVANCE_MS_WITH_NOTES, f.AutoAdvanceMs);
        Assert.Contains(new Effect.ScheduleAutoAdvance(Flow.ADVANCE_MS_WITH_NOTES, d.State.AutoAdvanceToken!.Value), d.Last);
        Assert.True(d.Announced("Richtig! Genau: la rue"));

        var e = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["a"]));
        e.Send(new Event.Submit("  la rue "));
        Assert.Equal(Correct, e.State.Phase);
        Assert.Contains(e.State.Feedback!.Title, Flow.PRAISE);
        Assert.Null(e.State.Feedback.ExactLabel);
        Assert.Equal("la rue", e.State.Feedback.Given);
    }

    [Fact]
    public void AnEmptyAnswerIsRejectedWithoutATransition()
    {
        var cards = MakeCards(3);
        var d = new Driver(MakeSet(cards), Familiar(cards));
        int rejections = d.State.Rejections, transitions = d.State.Transitions;
        d.Type("   ");
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Written, d.State.Phase);
        Assert.Equal(rejections + 1, d.State.Rejections);
        Assert.Equal(transitions, d.State.Transitions);
        Assert.True(d.Announced("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht?»."));
        Assert.DoesNotContain(d.Last, e => e is Effect.RecordAnswer);
    }

    [Fact]
    public void SynonymsCountAsAuchRichtig()
    {
        List<Card> cards = [new("laid", "laid, laide", "hässlich"), new("moche", "moche", "hässlich"), new("calme", "calme", "ruhig")];
        var d = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["laid"]));
        d.Type("moche");
        d.Press(KeyInput.Return);
        var f = d.State.Feedback!;
        Assert.Equal(Correct, d.State.Phase);
        Assert.True(f.Synonym);
        Assert.Equal(Flow.SYNONYM_TITLE, f.Title);
        Assert.Equal("Gesucht war:", f.ExactLabel);
        Assert.True(d.Announced("Auch richtig! Gesucht war: laid, laide"));
    }

    static List<Card> Words() => [new("a", "le chemin", "der Weg"), new("b", "la rue", "die Strasse")];

    [Fact]
    public void AWrittenMissOffersIchHatteRecht()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        var f = d.State.Feedback!;
        Assert.Equal(Wrong, d.State.Phase);
        Assert.True(f.CanOverride);
        Assert.Equal(Flow.MISS_TITLE, f.Title);
        Assert.Equal("Ich hatte recht", Flow.OverrideLabel(d.State));
        Assert.Contains(new Effect.Haptic(HapticKind.Failure), d.Last);
        Assert.Equal("la route", d.SavedFeedback?["given"]?.StringValue);
        // Characters do not continue after a written miss.
        d.Press(KeyInput.Character("x"));
        Assert.Equal(Wrong, d.State.Phase);
        d.Press(KeyInput.CommandReturn);
        Assert.Contains(new Effect.OverrideLastAnswer("a"), d.Last);
        Assert.Contains(new Effect.Toast("Als richtig gezählt", Flow.Tone.Success), d.Last);
        // The only card was familiar: counted as right it is mastered, which ends the session.
        Assert.Equal(2, d.Progress["a"].Streak);
        Assert.Equal(Phase.Finished, d.State.Phase);
        Assert.Equal(1, d.State.FinalStats?.Mastered);
        Assert.Null(d.Saved?.Feedback);
    }

    [Fact]
    public void WeissIchNichtOnAWrittenQuestion()
    {
        var cards = MakeCards(3);
        var d = new Driver(MakeSet(cards), Familiar(cards));
        var q = d.Question!;
        d.Press(KeyInput.OptionReturn);
        Assert.Equal(DontKnowPhase, d.State.Phase);
        Assert.False(d.State.Feedback?.CanOverride);
        Assert.Null(Flow.OverrideLabel(d.State));
        Assert.Equal("", d.State.Feedback?.Given);
        Assert.Contains(new Effect.RecordAnswer(q.CardId, false, d.Now), d.Last);
        var before = Key(d.State);
        d.Press(KeyInput.CommandReturn);
        Assert.Equal(before, Key(d.State));
        d.Press(KeyInput.Return);
        Assert.True(d.State.Phase == Phase.Written || d.State.Phase == Phase.Mc);
    }

    [Fact]
    public void CharactersAfterACorrectWrittenAnswerStartTheNextAnswer()
    {
        var cards = MakeCards(3);
        var d = new Driver(MakeSet(cards), Familiar(cards));
        d.AnswerByKeys(correct: true);
        Assert.Equal(Correct, d.State.Phase);
        int transitions = d.State.Transitions;
        d.Press(KeyInput.Character("t"), after: 50);
        Assert.Equal(Phase.Written, d.State.Phase);
        Assert.Equal("t", d.State.Draft);
        Assert.Equal(transitions + 1, d.State.Transitions);
        // After a written miss characters do nothing (Return continues).
        d.Type("terme 9");
        d.Press(KeyInput.Return);
        Assert.Equal(Wrong, d.State.Phase);
        d.Press(KeyInput.Character(" "));
        Assert.Equal(Wrong, d.State.Phase);
    }

    [Fact]
    public void ASpaceContinuesWithoutTyping()
    {
        var cards = MakeCards(3);
        var d = new Driver(MakeSet(cards), Familiar(cards));
        d.AnswerByKeys(correct: true);
        d.Press(KeyInput.Character(" "));
        Assert.Equal(Phase.Written, d.State.Phase);
        Assert.Equal("", d.State.Draft);
    }

    // MARK: - Copy step

    [Fact]
    public void TheCopyStepNeedsTheRightAnswerTypedOnce()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Copy, d.State.Phase);
        Assert.Equal("", d.State.Draft);
        Assert.True(d.State.Feedback?.Copy);
        Assert.Equal("Weiter", Flow.ReturnAction(d.State));
        Assert.EndsWith("Tippe die richtige Antwort ab.", d.LastAnnouncement);
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Copy, d.State.Phase);
        Assert.Equal(1, d.State.Rejections);
        d.Type("le chemi");
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Copy, d.State.Phase);
        Assert.Equal(2, d.State.Rejections);
        Assert.True(d.Announced("Noch nicht ganz – tippe die richtige Antwort genau ab."));
        // Accepted without its article, but not typed out as shown: Return continues.
        d.Type("chemin");
        Assert.Equal(Phase.Copy, d.State.Phase);
        d.Press(KeyInput.Return);
        // No retry at the end of the round any more: the only card comes back in the next round (written: it was
        // answered right before, so no multiple choice).
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Written, d.State.Phase);
    }

    [Fact]
    public void TheCopyStepContinuesOnceTheAnswerIsTypedOut()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Copy, d.State.Phase);
        d.Type("le chemi");
        Assert.Equal(Phase.Copy, d.State.Phase);
        Assert.Null(d.State.AutoAdvanceToken);
        var transitions = d.State.Transitions;
        // Upper/lower case and spacing do not matter. The finished word stays a short beat.
        d.Type("Le  Chemin");
        Assert.Equal(Phase.Copy, d.State.Phase);
        Assert.Equal(CopyStep.AdvanceMs, d.Timers[^1].Ms);
        d.FireTimer();
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
        Assert.Equal(transitions + 1, d.State.Transitions);
        // Return out of habit right after it falls into the input lock.
        d.Press(KeyInput.Return, after: 100);
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
    }

    [Fact]
    public void EnterDuringTheBeatContinuesAtOnce()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        d.Send(new Event.DraftChanged("le chemin"), after: 1500);
        var token = d.State.AutoAdvanceToken;
        Assert.NotNull(token);
        d.Press(KeyInput.Return, after: 150);
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
        // The beat's timer is stale now.
        d.Send(new Event.AutoAdvanceFired(token ?? -1), after: 250);
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
    }

    [Fact]
    public void ACopyAcceptedLikeAnAnswerContinuesToo()
    {
        Card[] cards = [new("a", "le/la collègue", "der Arbeitskollege, die Arbeitskollegin"), new("b", "la rue", "die Strasse")];
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Copy, d.State.Phase);
        d.Type("le collègue");
        Assert.NotNull(d.State.AutoAdvanceToken);
        // Typing on so that it is no longer right stops the beat; right again starts it anew.
        d.Type("le collègues x");
        Assert.Null(d.State.AutoAdvanceToken);
        d.Type("la collègue");
        d.FireTimer();
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
    }

    [Fact]
    public void ACopyThatIsOnlyTheStartOfTheAnswerWaitsForReturn()
    {
        Card[] cards = [new("a", "le cerveau, les cerveaux", "das Gehirn"), new("b", "la rue", "die Strasse")];
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Copy, d.State.Phase);
        // One of the two forms: right, but whoever copies both must not be cut off after it.
        d.Type("le cerveau");
        Assert.Equal(Phase.Copy, d.State.Phase);
        Assert.Null(d.State.AutoAdvanceToken);
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
    }

    [Fact]
    public void ATypedOutCopyWaitsWhileTheOptionsAreOpen()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        d.Type("le chemin");
        var token = d.State.AutoAdvanceToken;
        d.Send(new Event.OverlayPresented(Flow.Overlay.Options), after: 100);
        d.Send(new Event.AutoAdvanceFired(token ?? -1), after: 300);
        Assert.Equal(Phase.Copy, d.State.Phase);
        d.Send(new Event.OverlayDismissed());
        Assert.Equal(Phase.Copy, d.State.Phase);
        d.FireTimer();
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
    }

    [Fact]
    public void IchHatteRechtWorksInTheCopyStep()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), Options(retype: true), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        Assert.Equal("Ich hatte recht", Flow.OverrideLabel(d.State));
        d.Send(new Event.Override());
        Assert.Equal(Phase.Finished, d.State.Phase);
    }

    [Fact]
    public void TogglingTheCopyStepSwitchesAnOpenMiss()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        Assert.Equal(Wrong, d.State.Phase);
        int transitions = d.State.Transitions;
        d.Send(new Event.OptionsChanged(Options(retype: true)));
        Assert.Equal(Phase.Copy, d.State.Phase);
        d.Send(new Event.OptionsChanged(Options(retype: false)));
        Assert.Equal(Wrong, d.State.Phase);
        Assert.Equal(transitions, d.State.Transitions);
    }

    // MARK: - Checkpoint and finish

    [Fact]
    public void ACheckpointFollowsEachRound()
    {
        // A round is roundSize questions (3 here: each card once, then the checkpoint).
        var d = new Driver(MakeSet(MakeCards(3)), options: Options(roundSize: 3));
        for (int i = 0; i < 3; i++)
        {
            d.AnswerByKeys(correct: true);
            if (d.State.Phase == Correct && d.State.Session is { } ss && !LearnEngine.IsRoundOver(ss)) d.Press(KeyInput.Return);
        }
        Assert.Equal(Correct, d.State.Phase);
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Checkpoint, d.State.Phase);
        Assert.True(d.Announced("Runde 1 geschafft. 0 von 3 gemeistert."));
        Assert.Equal("Weiter zu Runde 2", Flow.ReturnAction(d.State));
        Assert.Equal(3, d.State.Checkpoint?.Answered);
        Assert.Equal(3, d.State.RoundStartCounts?.Fresh);
        Assert.Equal("3 richtige Antworten von 3 in dieser Runde. Noch 3 Begriffe, bis alles sitzt.", Flow.CheckpointText(d.State.Checkpoint!));
        // Any other key does nothing here.
        var before = Key(d.State);
        d.Press(KeyInput.Character("x"));
        d.Press(KeyInput.DigitKey(1));
        Assert.Equal(before, Key(d.State));
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Written, d.State.Phase);
        Assert.Equal(2, d.State.Round);
        Assert.Equal(2, d.Saved?.State.Round);
        Assert.False(d.State.ShowsIntroHint);
    }

    [Fact]
    public void EscapeLeavesAndKeepsTheStudyTime()
    {
        var d = new Driver(MakeSet(MakeCards(3)));
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        d.Press(KeyInput.Escape, after: 20_000);
        Assert.Equal([Flow.Destination.Set], d.Navigated);
        Assert.Equal(d.Now, d.Saved?.State.UpdatedAt);
        Assert.True((d.Saved?.State.ElapsedMs ?? 0) >= 20_000);
        Assert.Null(d.State.AutoAdvanceToken);
    }

    [Fact]
    public void TheFinishScreenCelebratesAndReturnIsFertig()
    {
        var d = new Driver(MakeSet(MakeCards(2)), options: Options(roundSize: 2));
        int guardCount = 0;
        while (d.State.Phase != Phase.Finished && guardCount++ < 40)
        {
            if (d.State.Phase.IsQuestion) d.AnswerByKeys(correct: true);
            else d.Press(KeyInput.Return);
        }
        Assert.Equal(Phase.Finished, d.State.Phase);
        Assert.Contains(new Effect.Haptic(HapticKind.Success), d.Last);
        Assert.True(d.Announced("Geschafft! Du hast alle Begriffe gemeistert!"));
        var stats = d.State.FinalStats!;
        Assert.True(stats.Total == 2 && stats.Mastered == 2 && stats.Rounds == 2 && stats.Accuracy == 1);
        Assert.NotNull(d.Saved?.State.FinishedAt);
        Assert.Equal(2, d.Saved?.State.Rounds.Count);
        Assert.Equal("Fertig", Flow.ReturnAction(d.State));
        Assert.False(d.State.IsStudying);
        d.Send(new Event.Tick());
        Assert.Empty(d.Last);
        d.Press(KeyInput.Return);
        Assert.Equal([Flow.Destination.Set], d.Navigated);
        // Ctrl+Shift+R: "Nochmal lernen" resets the scope's progress after asking.
        d.Send(new Event.Restart());
        Assert.Equal(new Flow.Prompt.Relearn(d.State.Session!.Order), d.State.Prompt);
        Assert.Equal("Fortschritt zurücksetzen?", Flow.PromptContentOf(d.State)?.Title);
        d.Send(new Event.PromptAnswered(true));
        Assert.Equal(new Effect.ResetProgress(null), d.Last[0]);
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.Null(d.State.Session?.FinishedAt);
    }

    // MARK: - Enter-only operation

    /// <summary>Plays with correct answers (keys only) until done holds.</summary>
    static void Play(Driver d, Func<Phase, bool> done)
    {
        int steps = 0;
        while (!done(d.State.Phase) && steps++ < 100)
        {
            if (d.State.Phase.IsQuestion) d.AnswerByKeys(correct: true);
            else d.Press(KeyInput.Return);
        }
    }

    /// <summary>
    /// Spec §4.3: in every phase Return does the one obvious next step (or nothing, and then ReturnAction is null or
    /// names a confirmation/navigation), and a second Return right after a transition does nothing.
    /// </summary>
    [Fact]
    public void ReturnDoesTheOneObviousNextStepInEveryPhase()
    {
        var six = MakeSet(MakeCards(6));
        var words = Words();
        var wordSet = MakeSet(words);
        Driver Written(bool retype = false) => new(wordSet, Familiar(words), Options(retype: retype), subset: StudySubset.CardIds(["a"]));
        var cases = new (string Name, Func<Driver> Make, string? Label, int Transitions, Func<Driver, bool> After)[]
        {
            ("mc, nothing highlighted", () => new Driver(six), null, 0, d => d.State.Phase == Phase.Mc),
            ("mc, highlighted", () => { var d = new Driver(six); d.Press(KeyInput.Arrow(Direction.Down)); return d; }, "Auswählen", 1, d => d.State.Phase.IsFeedback),
            ("written", () => { var d = Written(); d.Type("le chemin"); return d; }, "Antworten", 1, d => d.State.Phase == Correct),
            ("written, empty", () => Written(), "Antworten", 0, d => d.State.Phase == Phase.Written && d.State.Rejections == 1),
            ("mc correct", () => { var d = new Driver(six); d.AnswerByKeys(true); return d; }, "Weiter", 1, d => d.State.Phase == Phase.Mc),
            ("mc wrong", () => { var d = new Driver(six); d.AnswerByKeys(false); return d; }, "Weiter", 1, d => d.State.Phase == Phase.Mc),
            ("mc don't know", () => { var d = new Driver(six); d.Press(KeyInput.DigitKey(0)); return d; }, "Weiter", 1, d => d.State.Phase == Phase.Mc),
            ("written correct", () => { var d = Written(); d.AnswerByKeys(true); return d; }, "Weiter", 1, d => d.State.Phase == Phase.Finished || d.State.Phase == Phase.Checkpoint),
            // The only card of the subset: a miss comes back in the next round, after the checkpoint.
            ("written wrong", () => { var d = Written(); d.AnswerByKeys(false); return d; }, "Weiter", 1, d => d.State.Phase == Phase.Checkpoint),
            ("copy, empty", () => { var d = Written(true); d.AnswerByKeys(false); return d; }, "Weiter", 0, d => d.State.Phase == Phase.Copy && d.State.Rejections == 1),
            ("copy, typed", () => { var d = Written(true); d.AnswerByKeys(false); d.Type("chemin"); return d; }, "Weiter", 1, d => d.State.Phase == Phase.Checkpoint), // typed out as shown it would continue by itself
            ("checkpoint", () => { var d = new Driver(MakeSet(MakeCards(2)), options: Options(roundSize: 2)); Play(d, p => p == Phase.Checkpoint); return d; }, "Weiter zu Runde 2", 1,
                d => d.State.Phase == Phase.Written),
            ("finished", () => { var d = new Driver(MakeSet(MakeCards(2))); Play(d, p => p == Phase.Finished); return d; }, "Fertig", 0,
                d => d.Navigated.SequenceEqual([Flow.Destination.Set])),
            ("all mastered", () => new Driver(six, Mastered(MakeCards(6))), "Fortschritt zurücksetzen und neu lernen", 0, d => d.State.Prompt is Flow.Prompt.Relearn),
            ("empty set", () => new Driver(MakeSet([])), "Begriffe hinzufügen", 0, d => d.Navigated.SequenceEqual([Flow.Destination.EditSet])),
            ("empty subset", () => new Driver(MakeSet(words), subset: StudySubset.Starred), "Alle Begriffe üben", 1, d => d.State.Phase == Phase.Mc),
        };
        foreach (var c in cases)
        {
            var d = c.Make();
            Assert.True(Flow.ReturnAction(d.State) == c.Label, $"{c.Name}: label {Flow.ReturnAction(d.State)}");
            int before = d.State.Transitions;
            d.Press(KeyInput.Return);
            Assert.True(d.State.Transitions - before == c.Transitions, $"{c.Name}: transitions");
            Assert.True(c.After(d), $"{c.Name}: result {d.State.Phase}");
            // One Return = one transition: a second press right away does nothing.
            int settled = d.State.Transitions;
            d.Press(KeyInput.Return, after: 50);
            Assert.True(d.State.Transitions == settled, $"{c.Name}: second Return");
        }
    }

    /// <summary>Plays whole sessions with keys only and checks every key press causes at most one transition, Return on feedback or a checkpoint exactly one.</summary>
    [Theory]
    [InlineData(1u)]
    [InlineData(2u)]
    [InlineData(3u)]
    [InlineData(4u)]
    [InlineData(5u)]
    [InlineData(6u)]
    public void EnterOnlyPlayOneReturnIsOneTransition(uint seed)
    {
        var cards = MakeCards(5 + (int)seed);
        var options = Options(retype: seed % 2 == 0, roundSize: 3 + (int)(seed % 3), answerWith: seed % 3 == 0 ? AnswerWith.Both : AnswerWith.Term);
        var d = new Driver(MakeSet(cards), options: options, seed: seed);
        var decide = Rand.Mulberry32(seed + 100);
        int steps = 0;
        while (d.State.Phase != Phase.Finished)
        {
            Assert.True(++steps < 600, $"seed {seed}: did not finish");
            int before = d.State.Transitions;
            var phase = d.State.Phase;
            switch (phase.Kind)
            {
                case Flow.PhaseKind.Question:
                    d.AnswerByKeys(decide() < 0.7);
                    Assert.True(d.State.Transitions - before <= 1);
                    break;
                case Flow.PhaseKind.Feedback when phase.FeedbackKind == FK.Wrong && decide() < 0.2 && d.State.Feedback?.CanOverride == true:
                    d.Press(KeyInput.CommandReturn);
                    Assert.Equal(1, d.State.Transitions - before);
                    break;
                case Flow.PhaseKind.Copy:
                    if (decide() < 0.3)
                    {
                        d.Type("nein");
                        d.Press(KeyInput.Return);
                        Assert.Equal(before, d.State.Transitions);
                    }
                    // Typed out, the copy continues by itself after a short beat, or at once with Enter; whichever
                    // comes second does nothing.
                    d.Send(new Event.DraftChanged(d.Question!.Expected), after: 600);
                    var token = d.State.AutoAdvanceToken;
                    Assert.NotNull(token);
                    if (decide() < 0.5)
                    {
                        d.Press(KeyInput.Return, after: 100);
                        d.Send(new Event.AutoAdvanceFired(token!.Value), after: CopyStep.AdvanceMs);
                    }
                    else
                    {
                        d.Send(new Event.AutoAdvanceFired(token!.Value), after: CopyStep.AdvanceMs);
                        d.Press(KeyInput.Return, after: 100);
                    }
                    Assert.Equal(1, d.State.Transitions - before);
                    break;
                case Flow.PhaseKind.Feedback or Flow.PhaseKind.Checkpoint:
                    // A double press: the second one comes within the input lock.
                    d.Press(KeyInput.Return, after: 400);
                    d.Press(KeyInput.Return, after: 100);
                    Assert.True(d.State.Transitions - before == 1, $"phase {phase}");
                    break;
                default:
                    Assert.Fail($"unexpected phase {phase}");
                    return;
            }
        }
        Assert.Equal(cards.Count, d.State.Counts.Mastered);
        Assert.NotNull(d.Saved?.State.FinishedAt);
        Assert.True(LearnEngine.MatchesProgress(d.Saved!.State, d.Progress));
    }

    /// <summary>Random key mashing never causes two transitions for one key, and repeats never change anything.</summary>
    [Theory]
    [InlineData(11u)]
    [InlineData(12u)]
    [InlineData(13u)]
    [InlineData(14u)]
    public void KeyMashingNeverCausesTwoTransitions(uint seed)
    {
        var d = new Driver(MakeSet(MakeCards(6)), options: Options(retype: seed % 2 == 0), seed: seed);
        var r = Rand.Mulberry32(seed);
        KeyInput[] keys =
        [
            KeyInput.Return, KeyInput.Return, KeyInput.Return, KeyInput.OptionReturn, KeyInput.CommandReturn, KeyInput.DigitKey(0), KeyInput.DigitKey(1),
            KeyInput.DigitKey(2), KeyInput.DigitKey(3), KeyInput.DigitKey(4), KeyInput.DigitKey(7), KeyInput.Arrow(Direction.Up), KeyInput.Arrow(Direction.Down),
            KeyInput.Arrow(Direction.Left), KeyInput.Arrow(Direction.Right), KeyInput.Character("a"), KeyInput.Character(" "),
        ];
        double[] gaps = [30, 150, 290, 600, 1200];
        for (int n = 0; n < 400; n++)
        {
            if (r() < 0.1 && d.State.Phase == Phase.Written) d.Type(r() < 0.5 ? d.Question!.Expected : "x");
            if (r() < 0.05 && d.State.Phase == Phase.Copy) d.Type(d.Question!.Expected);
            var key = keys[(int)(r() * keys.Length)];
            bool isRepeat = r() < 0.15;
            double gap = gaps[(int)(r() * 5)];
            var beforeKey = Key(d.State);
            int beforeTransitions = d.State.Transitions;
            double lockedUntil = d.State.InputLockedUntil;
            d.Press(key, isRepeat, gap);
            if (isRepeat)
            {
                Assert.Equal(beforeKey, Key(d.State));
                Assert.Empty(d.Last);
            }
            Assert.True(d.State.Transitions - beforeTransitions <= 1);
            if (d.Now < lockedUntil && (key == KeyInput.Return || key == KeyInput.OptionReturn || key == KeyInput.CommandReturn))
                Assert.Equal(beforeTransitions, d.State.Transitions);
            if (r() < 0.1 && d.State.AutoAdvanceToken is { } token)
            {
                int t = d.State.Transitions;
                d.Send(new Event.AutoAdvanceFired(token), after: 900);
                Assert.True(d.State.Transitions - t <= 1);
            }
            if (d.State.Phase == Phase.Finished) break;
        }
    }

    // MARK: - Resume

    [Fact]
    public void ResumesASavedSessionWhereItStopped()
    {
        var set = MakeSet(MakeCards(6));
        var a = new Driver(set);
        a.Press(KeyInput.DigitKey(a.CorrectIndex!.Value + 1));
        a.Press(KeyInput.Return);
        var qid = a.Question?.Qid;
        var saved = a.Saved!;
        var b = new Driver(set, a.Progress, saved: saved, now: a.Now + 3_600_000);
        Assert.Equal(Phase.Mc, b.State.Phase);
        Assert.Equal(qid, b.Question?.Qid);
        Assert.Equal(a.Question!.Choices, b.Question!.Choices);
        Assert.Contains(new Effect.Toast(Flow.WELCOME_BACK, Flow.Tone.Neutral), b.Log);
        // Time away is not study time.
        Assert.Equal(b.Now, b.State.Session?.UpdatedAt);
        Assert.Equal(a.State.Session?.ElapsedMs, b.State.Session?.ElapsedMs);
    }

    [Fact]
    public void ARelaunchReopensAnOpenMultipleChoiceMiss()
    {
        var set = MakeSet(MakeCards(6));
        var a = new Driver(set);
        int wrong = a.WrongIndex!.Value;
        a.Press(KeyInput.DigitKey(wrong + 1));
        var saved = a.Saved!;
        Assert.NotNull(saved.Feedback);
        var json = JSONValue.Parse(saved.ToJson().ToJsonString());
        var b = new Driver(set, a.Progress, saved: Flow.SavedLearn.FromJson(json));
        Assert.Equal(Wrong, b.State.Phase);
        Assert.Equal(wrong, b.State.Feedback?.ChosenIndex);
        Assert.Equal(a.CorrectIndex, b.State.Feedback?.CorrectIndex);
        Assert.Equal(a.Question?.Qid, b.Question?.Qid);
        Assert.DoesNotContain(new Effect.Haptic(HapticKind.Failure), b.Log);
        b.Press(KeyInput.Return);
        Assert.Equal(Phase.Mc, b.State.Phase);
        Assert.Null(b.Saved?.Feedback);
    }

    [Fact]
    public void ARelaunchReopensAnOpenWrittenMissWithTheCopyStep()
    {
        var cards = Words();
        var set = MakeSet(cards);
        var a = new Driver(set, Familiar(cards), subset: StudySubset.CardIds(["a"]));
        a.Type("la route");
        a.Press(KeyInput.Return);
        var b = new Driver(set, a.Progress, Options(retype: true), a.Saved);
        Assert.Equal(Phase.Copy, b.State.Phase);
        Assert.Equal("la route", b.State.Feedback?.Given);
        Assert.True(b.State.Feedback?.CanOverride);
        b.Press(KeyInput.CommandReturn);
        Assert.Equal(Phase.Finished, b.State.Phase);
    }

    [Fact]
    public void ResumeBringsInAnswersGivenInWriteMode()
    {
        var cards = MakeCards(5);
        var set = MakeSet(cards);
        var a = new Driver(set);
        a.Press(KeyInput.DigitKey(a.CorrectIndex!.Value + 1));
        var progress = new Dictionary<string, CardProgress>(a.Progress);
        var elsewhere = a.State.Session!.Queue[0].CardId;
        progress[elsewhere] = new CardProgress(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0);
        var b = new Driver(set, progress, saved: a.Saved);
        Assert.Equal(2, b.State.Session?.Stage[elsewhere]);
        Assert.DoesNotContain(b.State.Session!.Queue, q => q.CardId == elsewhere);
        Assert.Equal(2, b.Saved?.State.Stage[elsewhere]);
        Assert.True(LearnEngine.MatchesProgress(b.State.Session, progress));
    }

    [Fact]
    public void ResumeDropsCardsDeletedSinceAndFinishedSessionsStartFresh()
    {
        var cards = MakeCards(5);
        var a = new Driver(MakeSet(cards));
        a.Press(KeyInput.DigitKey(a.CorrectIndex!.Value + 1));
        var gone = a.State.Session!.Order[^1];
        var b = new Driver(MakeSet(cards.Where(c => c.Id != gone).ToList()), a.Progress, saved: a.Saved);
        Assert.DoesNotContain(gone, b.State.Session!.Order);
        Assert.Equal(4, b.State.Session.Order.Count);
        Assert.Equal(4, b.Saved?.State.Order.Count);

        var finishedState = LearnEngine.CopyState(a.Saved!.State);
        finishedState.FinishedAt = T0;
        var finished = new Flow.SavedLearn(finishedState, a.Saved.Feedback);
        var c = new Driver(MakeSet(cards), Mastered(cards), saved: finished);
        Assert.Equal(Phase.AllMastered, c.State.Phase);
        var f = new Driver(MakeSet(cards), a.Progress, saved: a.Saved, forceNew: true);
        Assert.Equal(0, f.State.Session?.Answered);
        Assert.DoesNotContain(new Effect.Toast(Flow.WELCOME_BACK, Flow.Tone.Neutral), f.Log);
    }

    [Fact]
    public void ARequestedSubsetAsksBeforeEndingASessionWithAnswers()
    {
        var cards = MakeCards(6); // starred: c1, c4
        var set = MakeSet(cards);
        var a = new Driver(set);
        a.Press(KeyInput.DigitKey(a.CorrectIndex!.Value + 1));
        a.Press(KeyInput.Return);
        var b = new Driver(set, a.Progress, saved: a.Saved, subset: StudySubset.Starred);
        Assert.Equal(new Flow.Prompt.ReplaceSession(StudySubset.Starred), b.State.Prompt);
        Assert.Contains("nur die markierten Begriffe", Flow.PromptContentOf(b.State)!.Message);
        Assert.Equal(Phase.Mc, b.State.Phase);
        Assert.Null(Flow.ReturnAction(b.State));
        var before = Key(b.State);
        b.Press(KeyInput.DigitKey(1));
        Assert.Equal(before, Key(b.State));
        b.Send(new Event.PromptAnswered(false));
        Assert.Null(b.State.Prompt);
        Assert.Contains(new Effect.Toast(Flow.WELCOME_BACK, Flow.Tone.Neutral), b.Last);
        Assert.Equal(StudySubset.All, b.State.Session?.Subset);

        var c = new Driver(set, a.Progress, saved: a.Saved, subset: StudySubset.Starred);
        c.Send(new Event.PromptAnswered(true));
        Assert.Equal(StudySubset.Starred, c.State.Session?.Subset);
        Assert.Equal(["c1", "c4"], c.State.Session!.Order.Order());
        Assert.Equal(StudySubset.Starred, c.Saved?.State.Subset);

        // Without answers there is nothing to lose: no question.
        var fresh = new Driver(set);
        var d = new Driver(set, saved: fresh.Saved, subset: StudySubset.Starred);
        Assert.Null(d.State.Prompt);
        Assert.Equal(StudySubset.Starred, d.State.Session?.Subset);
    }

    // MARK: - Options, restart

    [Fact]
    public void OptionsThatShapeTheSessionAskToRestartWhenThePopoverCloses()
    {
        var d = new Driver(MakeSet(MakeCards(10)));
        d.Send(new Event.OverlayPresented(Flow.Overlay.Options));
        d.Press(KeyInput.Return);
        Assert.Empty(d.Last);
        var changed = StudyOptions.Default with { Learn = StudyOptions.Default.Learn with { RoundSize = 3 } };
        d.Send(new Event.OptionsChanged(changed));
        Assert.Null(d.State.Prompt);
        d.Send(new Event.OverlayDismissed());
        Assert.Equal(new Flow.Prompt.RestartForOptions([Flow.SettingsChange.RoundSize]), d.State.Prompt);
        Assert.Equal("Später", Flow.PromptContentOf(d.State)?.CancelLabel);
        int transitions = d.State.Transitions;
        d.Send(new Event.PromptAnswered(true));
        Assert.Equal(3, d.State.Session?.Learn.RoundSize);
        Assert.Equal(3, d.State.Session?.Queue.Count);
        Assert.Equal(transitions + 1, d.State.Transitions);

        // Direction and question types need a restart too.
        var g = new Driver(MakeSet(MakeCards(10)));
        g.Send(new Event.OverlayPresented(Flow.Overlay.Options));
        var both = StudyOptions.Default with { AnswerWith = AnswerWith.Both, Learn = StudyOptions.Default.Learn with { Written = false } };
        g.Send(new Event.OptionsChanged(both));
        g.Send(new Event.OverlayDismissed());
        Assert.Equal(new Flow.Prompt.RestartForOptions([Flow.SettingsChange.Direction, Flow.SettingsChange.Types]), g.State.Prompt);
        Assert.StartsWith("Die neuen Einstellungen gelten", Flow.PromptContentOf(g.State)!.Message);
        g.Send(new Event.PromptAnswered(true));
        Assert.Equal(AnswerWith.Both, g.State.Session?.AnswerWith);
        Assert.False(g.State.Session?.Learn.Written);

        // "Später": the session goes on; an unrelated change later does not ask again.
        var e = new Driver(MakeSet(MakeCards(10)));
        var session = J(e.State.Session);
        e.Send(new Event.OverlayPresented(Flow.Overlay.Options));
        e.Send(new Event.OptionsChanged(changed));
        e.Send(new Event.OverlayDismissed());
        e.Send(new Event.PromptAnswered(false));
        Assert.Equal(session, J(e.State.Session));
        e.Send(new Event.OverlayPresented(Flow.Overlay.Options));
        var tolerant = changed with { Tolerance = changed.Tolerance with { Typos = true } };
        e.Send(new Event.OptionsChanged(tolerant));
        e.Send(new Event.OverlayDismissed());
        Assert.Null(e.State.Prompt);
        // Changed and changed back: nothing to ask.
        var f = new Driver(MakeSet(MakeCards(10)));
        f.Send(new Event.OverlayPresented(Flow.Overlay.Options));
        f.Send(new Event.OptionsChanged(changed));
        f.Send(new Event.OptionsChanged(StudyOptions.Default));
        f.Send(new Event.OverlayDismissed());
        Assert.Null(f.State.Prompt);
    }

    [Fact]
    public void TheToleranceAppliesAtOnce()
    {
        List<Card> cards = [new("a", "bête", "dumm"), new("b", "calme", "ruhig")];
        var d = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["a"]));
        d.Send(new Event.OptionsChanged(StudyOptions.Default with { Tolerance = StudyOptions.Default.Tolerance with { IgnoreAccents = true } }));
        d.Type("bete");
        d.Press(KeyInput.Return);
        Assert.Equal(Correct, d.State.Phase);
        Assert.Contains(GradeNote.Accents, d.State.Feedback!.Result!.Notes);
    }

    [Fact]
    public void RestartAsksFirstThenStartsANewSession()
    {
        var d = new Driver(MakeSet(MakeCards(6)));
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        d.Send(new Event.Restart());
        Assert.Equal(new Flow.Prompt.RestartSession(), d.State.Prompt);
        Assert.Null(d.State.AutoAdvanceToken);
        Assert.Equal(Flow.RestartSessionMessage(StudySubset.All), Flow.PromptContentOf(d.State)?.Message);
        d.Send(new Event.PromptAnswered(false));
        // The countdown the prompt interrupted starts again.
        Assert.Single(d.Scheduled);
        d.Send(new Event.Restart());
        d.Send(new Event.PromptAnswered(true));
        // The card answered right before (stage 1) comes first, written; the new ones follow as multiple choice.
        Assert.Equal(Phase.Written, d.State.Phase);
        Assert.Equal(0, d.State.Session?.Answered);
        Assert.Equal(d.Now, d.State.Session?.StartedAt);
        Assert.Single(d.Progress); // the progress stays
    }

    // MARK: - Live changes

    [Fact]
    public void DeletingTheCardOnScreenMovesOnToAnotherQuestion()
    {
        var cards = MakeCards(8);
        var d = new Driver(MakeSet(cards));
        var q = d.Question!;
        d.Send(new Event.CardsChanged(cards.Where(c => c.Id != q.CardId).ToList()));
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.NotEqual(q.CardId, d.Question?.CardId);
        Assert.DoesNotContain(q.CardId, d.State.Session!.Order);
        Assert.DoesNotContain(q.CardId, d.Saved!.State.Order);
        // Its options are refilled from the set.
        Assert.Equal(4, d.Question?.Choices.Count);
    }

    [Fact]
    public void EditsElsewhereShowAtOnce()
    {
        var cards = MakeCards(6);
        var d = new Driver(MakeSet(cards));
        var q = d.Question!;
        int i = cards.FindIndex(c => c.Id == q.CardId);
        cards[i] = cards[i] with { Definition = "Neue Definition" };
        var option = q.Choices.First(c => c.CardId != q.CardId);
        int j = cards.FindIndex(c => c.Id == option.CardId);
        cards[j] = cards[j] with { Term = "nouveau terme" };
        d.Send(new Event.CardsChanged(cards));
        Assert.Equal(q.Qid, d.Question?.Qid);
        Assert.Equal("Neue Definition", d.Question?.Prompt);
        Assert.Contains(new Choice(option.CardId, "nouveau terme"), d.Question!.Choices);
        // Renamed set and languages.
        var set = MakeSet(cards, Lang.En, Lang.De) with { Title = "Englisch" };
        d.Send(new Event.SetChanged(set));
        Assert.Equal("Englisch", d.State.SetTitle);
    }

    [Fact]
    public void EmptyingTheSetEndsTheSession()
    {
        var d = new Driver(MakeSet(MakeCards(4)));
        d.Send(new Event.CardsChanged([]));
        Assert.Equal(Phase.Empty, d.State.Phase);
        Assert.Null(d.State.Session);
        Assert.Contains(new Effect.ClearLearn(), d.Last);
        Assert.Null(d.Saved);
    }

    [Fact]
    public void ACardDeletedDuringItsFeedbackKeepsTheFeedback()
    {
        var cards = MakeCards(6);
        var d = new Driver(MakeSet(cards));
        var q = d.Question!;
        d.Press(KeyInput.DigitKey(d.WrongIndex!.Value + 1));
        d.Send(new Event.CardsChanged(cards.Where(c => c.Id != q.CardId).ToList()));
        Assert.Equal(Wrong, d.State.Phase);
        Assert.Equal(q.CardId, d.Question?.CardId);
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Mc, d.State.Phase);
        Assert.DoesNotContain(q.CardId, d.State.Session!.Order);
    }

    [Fact]
    public void AnswersGivenElsewhereMoveTheStages()
    {
        var cards = MakeCards(6);
        var d = new Driver(MakeSet(cards));
        var queued = d.State.Session!.Queue[1].CardId;
        d.Progress[queued] = new CardProgress(Correct: 2, Streak: 2, StreakBefore: 1, LastResult: AnswerResult.Correct, LastAnsweredAt: T0);
        d.Send(new Event.ProgressChanged());
        Assert.Equal(2, d.State.Session?.Stage[queued]);
        Assert.DoesNotContain(d.State.Session!.Queue, q => q.CardId == queued);
        Assert.Equal(2, d.Saved?.State.Stage[queued]);
        Assert.Equal(1, d.State.Counts.Mastered);
    }

    [Fact]
    public void EditingTheCardCanTurnAMissIntoAnAcceptedAnswer()
    {
        var cards = Words();
        var d = new Driver(MakeSet(cards), Familiar(cards), subset: StudySubset.CardIds(["a"]));
        d.Type("la route");
        d.Press(KeyInput.Return);
        d.Send(new Event.OverlayPresented(Flow.Overlay.Editor));
        var edited = new Card("a", "la route", "der Weg");
        d.Send(new Event.EditCard(edited));
        Assert.Contains(new Effect.UpdateCard(edited), d.Last);
        Assert.Contains(new Effect.Toast("Karte gespeichert", Flow.Tone.Success), d.Last);
        Assert.Equal("la route", d.Question?.Expected);
        Assert.True(d.State.Feedback?.EditedCorrect);
        Assert.Equal("Als richtig zählen", Flow.OverrideLabel(d.State));
        d.Send(new Event.OverlayDismissed());
        d.Press(KeyInput.CommandReturn);
        Assert.Equal(Phase.Finished, d.State.Phase);
        Assert.Equal(edited, d.Cards[0]);
    }

    [Fact]
    public void StarringAndReadingAloud()
    {
        var cards = MakeCards(6).Select(c => c with { Starred = false }).ToList();
        var d = new Driver(MakeSet(cards), options: Options(audio: true));
        var q = d.Question!;
        d.Send(new Event.ToggleStar());
        Assert.Equal([new Effect.ToggleStar(q.CardId)], d.Last);
        Assert.True(d.Question?.Starred);
        Assert.True(d.State.Cards.First(c => c.Id == q.CardId).Starred);
        d.Send(new Event.SpeakPrompt());
        Assert.Equal([new Effect.Speak(q.Prompt, Lang.De)], d.Last);
        // Audio: the term is read once the answer is known.
        d.Press(KeyInput.DigitKey(d.CorrectIndex!.Value + 1));
        var term = cards.First(c => c.Id == q.CardId).Term;
        Assert.Contains(new Effect.Speak(term, Lang.Fr), d.Last);

        // Asking the definition, the prompt (the term) is read when the question appears.
        var e = new Driver(MakeSet(cards), options: Options(audio: true, answerWith: AnswerWith.Definition));
        Assert.Contains(new Effect.Speak(e.Question!.Prompt, Lang.Fr), e.Log);
    }

    [Fact]
    public void TheClockTicksResumesAndStopsWhenFinished()
    {
        var d = new Driver(MakeSet(MakeCards(4)));
        d.Send(new Event.Tick(), after: 15_000);
        Assert.Equal(15_000, d.Saved?.State.ElapsedMs);
        d.Send(new Event.Resume(), after: 3_600_000);
        Assert.Equal(d.Now, d.State.Session?.UpdatedAt);
        Assert.Empty(d.Last);
        d.Send(new Event.Tick(), after: 10_000);
        Assert.Equal(25_000, d.Saved?.State.ElapsedMs);
        Assert.True(d.State.IsStudying);
    }

    [Fact]
    public void SavesHappenOncePerEventWithTheFinalState()
    {
        var d = new Driver(MakeSet(MakeCards(4)));
        d.Press(KeyInput.DigitKey(d.WrongIndex!.Value + 1));
        d.Press(KeyInput.Return);
        var saves = d.Last.OfType<Effect.SaveLearn>().ToList();
        Assert.Single(saves);
        Assert.Equal(new Effect.SaveLearn(d.State.Session!, null), saves[^1]);
        Assert.Equal(saves[^1], d.Last[^1]);
    }
}
