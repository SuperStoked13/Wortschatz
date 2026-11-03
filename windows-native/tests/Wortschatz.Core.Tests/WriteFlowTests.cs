using Wortschatz.Core;
using Xunit;
using Effect = Wortschatz.Core.WriteFlow.Effect;
using Event = Wortschatz.Core.WriteFlow.Event;
using FK = Wortschatz.Core.WriteFlow.FeedbackKind;
using Pending = Wortschatz.Core.WriteFlow.PendingFeedback;
using Phase = Wortschatz.Core.WriteFlow.Phase;

namespace Wortschatz.Core.Tests;

// Port of WriteFlowTests.swift: the Write screen's state machine (src/screens/write.js, write-card.js,
// write-keys.js) as a reducer: answering, feedback, the copy step, "Ich hatte recht", rounds, results,
// resuming, dialogs, card edits, live updates and the study clock. (The Swift "codable" test has no
// counterpart: the C# state is not serialised.)
public class WriteFlowTests
{
    static WriteFlowDriver Driver(List<Card>? cards = null, bool copy = false, bool autoAdvance = true, bool audio = false,
        AnswerWith answerWith = AnswerWith.Term, bool shuffle = false, uint seed = 1, Lang termLang = Lang.Fr, Lang defLang = Lang.De) =>
        new(cards ?? WriteFlowSamples.Three(), termLang, defLang,
            new StudyOptionsPatch(AnswerWith: answerWith, Shuffle: shuffle, CopyAnswer: copy, AutoAdvance: autoAdvance, Audio: audio), seed);

    static readonly Phase Correct = Phase.FeedbackOf(FK.Correct);
    static readonly Phase Wrong = Phase.FeedbackOf(FK.Wrong);
    static readonly Phase DontKnowPhase = Phase.FeedbackOf(FK.DontKnow);

    // MARK: - Start

    [Fact]
    public void FreshStart()
    {
        var d = Driver(WriteFlowSamples.UserCards);
        Assert.Equal(Phase.Question, d.Phase);
        var q = d.Question!;
        Assert.Equal("u1", q.CardId);
        Assert.Equal("der Herr", q.Prompt);
        Assert.Equal("le monsieur, messieurs", q.Expected);
        Assert.Equal("Deutsch", q.PromptLabel);
        Assert.Equal("Antwort auf Französisch eingeben", WriteFlow.FieldPlaceholder(d.State));
        Assert.Equal("Deine Antwort", WriteFlow.FieldLabel(d.State));
        // Only the new session is saved: no announcement (focus moves to the field) and no speech.
        Assert.Equal([new Effect.SaveSession(d.Session!, null)], d.Effects);
        Assert.Equal(d.Session!.ToJson().ToString(), d.Stored!.Value.Session.ToJson().ToString());
        Assert.Equal("Antworten", WriteFlow.ReturnAction(d.State));
        Assert.Equal("zum Antworten", WriteFlow.ReturnHint(d.State));
        Assert.True(WriteFlow.IsStudying(d.State));
        Assert.False(d.State.AnimatesQuestion);
        Assert.Equal(52, WriteFlow.CountersOf(d.State)?.Remaining);
        Assert.Null(WriteFlow.RoundNote(d.State));
        Assert.True(d.State.IsInputEditable);
    }

    [Fact]
    public void MissingSet()
    {
        var (state, effects) = WriteFlow.Start(null, StudyOptions.Default, (SessionState?)null, new WriteFlow.Env(1));
        Assert.Equal(Phase.Missing, state.Phase);
        Assert.Empty(effects);
        Assert.Equal("Zur Übersicht", WriteFlow.ReturnAction(state));
        Assert.Equal([new Effect.Exit()], WriteFlow.Reduce(state, new Event.Key(KeyInput.Return), new WriteFlow.Env(2)).Effects);
        Assert.Equal([new Effect.Exit()], WriteFlow.Reduce(state, new Event.Key(KeyInput.Escape), new WriteFlow.Env(2)).Effects);
        Assert.Empty(WriteFlow.Reduce(state, new Event.Restart(), new WriteFlow.Env(2)).Effects);
        Assert.Null(WriteFlow.Reduce(state, new Event.RequestOptions(), new WriteFlow.Env(2)).State.Overlay);
    }

    // MARK: - Answering

    [Fact]
    public void EmptyAnswer()
    {
        var d = Driver();
        Assert.Equal([new Effect.Announce("Gib zuerst eine Antwort ein – oder wähle «Weiss ich nicht».")], d.Press(KeyInput.Return));
        Assert.Equal(1, d.State.Rejections);
        Assert.Equal(Phase.Question, d.Phase);
        d.Type("   ");
        d.Press(KeyInput.Return);
        Assert.Equal(2, d.State.Rejections);
        Assert.Empty(d.Progress);
    }

    [Fact]
    public void CorrectAnswer()
    {
        var d = Driver();
        var fx = d.Answer(" le chat ");
        Assert.Equal(Correct, d.Phase);
        Assert.Equal(new Effect.RecordAnswer("a", true, d.Now), fx[0]);
        Assert.Contains(new Effect.Haptic(HapticKind.Success), fx);
        Assert.Contains(new Effect.ScheduleAutoAdvance(900, 1), fx);
        Assert.Single(d.Saves(fx));
        Assert.Null(d.Saves(fx)[0].Feedback);
        var fb = d.State.Feedback!;
        Assert.Equal("le chat", fb.Given);
        Assert.Contains(fb.Title, WriteFlow.Praise);
        Assert.Equal([fb.Title], d.Announcements(fx));
        Assert.False(fb.ShowsExact);
        // The field keeps what was typed (read-only).
        Assert.Equal(" le chat ", d.State.Input);
        Assert.False(d.State.IsInputEditable);
        Assert.Equal(new WriteFlow.AutoAdvance(1, 900), d.State.AutoAdvance);
        Assert.Equal("Weiter mit beliebiger Taste", WriteFlow.ReturnHint(d.State));
        Assert.Equal("Weiter", WriteFlow.ReturnAction(d.State));
        Assert.Equal(1, d.Progress["a"].Correct);
        Assert.Equal([new SessionAnswer("a:t", true)], d.Stored!.Value.Session.RoundAnswered);
    }

    [Fact]
    public void EnterLock()
    {
        var d = Driver();
        d.AnswerCorrectly();
        // The answering press delivered twice does nothing.
        Assert.Empty(d.Press(KeyInput.Return, after: 10));
        Assert.Equal(Correct, d.Phase);
        // 300 ms after the answer the lock is over; the next prompt is announced (focus stayed in the field).
        Assert.Equal([new Effect.Announce("Deutsch: der Hund")], d.Press(KeyInput.Return, after: 290));
        Assert.Equal("b", d.Question?.CardId);
        Assert.True(d.State.AnimatesQuestion);
        Assert.Null(d.State.AutoAdvance);
    }

    [Fact]
    public void SkipWithinLock()
    {
        var d = Driver();
        d.AnswerCorrectly();
        var fx = d.Press(KeyInput.Return, after: 100);
        Assert.Equal(Correct, d.Phase);
        var advance = d.State.AutoAdvance!;
        Assert.Equal(180, advance.Ms);
        Assert.Equal([new Effect.ScheduleAutoAdvance(180, advance.Token)], fx);
        d.FireTimer();
        Assert.Equal("b", d.Question?.CardId);
        // A miss is never skipped that way.
        d.Answer("falsch");
        Assert.True(d.Phase.IsMiss);
        Assert.Empty(d.Press(KeyInput.Return, after: 100));
        Assert.Null(d.State.AutoAdvance);
    }

    [Fact]
    public void ClockSetBack()
    {
        var d = Driver();
        d.AnswerCorrectly();
        // The system clock jumps back ten minutes right after the answer.
        Assert.Equal([new Effect.Announce("Deutsch: der Hund")], d.Press(KeyInput.Return, after: -600_000));
        Assert.Equal("b", d.Question?.CardId);
    }

    [Fact]
    public void AutoAdvanceTokens()
    {
        var d = Driver();
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        Assert.Equal(2, d.State.AutoAdvance?.Token);
        Assert.Empty(d.Send(new Event.AutoAdvanceFired(1)));
        Assert.Equal(Correct, d.Phase);
        d.FireTimer();
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Equal("c", d.Question?.CardId);
        // The same timer firing again does nothing.
        Assert.Empty(d.Send(new Event.AutoAdvanceFired(2)));
    }

    [Fact]
    public void ToleratedAnswer()
    {
        var d = Driver(WriteFlowSamples.UserCards);
        d.AnswerCorrectly();
        d.FireTimer();
        Assert.Equal("l'homme", d.Question?.Expected);
        var fx = d.Answer("homme");
        var fb = d.State.Feedback!;
        Assert.True(fb.IsCorrect);
        Assert.Equal("Richtig!", fb.Title);
        Assert.True(fb.ShowsExact);
        Assert.Equal("Genau:", fb.ExactLabel);
        Assert.Equal([GradeNote.Article], fb.Notes.Select(n => n.Note));
        Assert.Equal("Artikel fehlte", fb.Notes[0].Label);
        Assert.Equal(["Richtig! Genau: l'homme"], d.Announcements(fx));
        Assert.Contains(new Effect.ScheduleAutoAdvance(1800, 2), fx);
    }

    [Fact]
    public void ManualContinue()
    {
        var d = Driver(autoAdvance: false);
        var fx = d.AnswerCorrectly();
        Assert.DoesNotContain(fx, e => e is Effect.ScheduleAutoAdvance);
        Assert.Equal("zum Weitermachen", WriteFlow.ReturnHint(d.State));
        d.Press(KeyInput.Return);
        Assert.Equal("b", d.Question?.CardId);
    }

    [Fact]
    public void SynonymAnswer()
    {
        var d = Driver(WriteFlowSamples.Personen);
        Assert.Equal("laid", d.Question?.CardId);
        var fx = d.Answer("moche");
        var fb = d.State.Feedback!;
        Assert.True(fb.IsCorrect && fb.Synonym);
        Assert.Equal("Auch richtig!", fb.Title);
        Assert.Equal("Gesucht war:", fb.ExactLabel);
        Assert.True(fb.Notes[0].IsSynonym);
        Assert.Equal(["Auch richtig! Gesucht war: laid, laide"], d.Announcements(fx));
    }

    [Fact]
    public void PraiseVaries()
    {
        var d = Driver(WriteFlowSamples.UserCards, autoAdvance: false, seed: 5);
        var last = "";
        var seen = new HashSet<string>();
        for (int i = 0; i < 20; i++)
        {
            d.AnswerCorrectly();
            var praise = d.State.Feedback?.Praise ?? "";
            Assert.Contains(praise, WriteFlow.Praise);
            Assert.NotEqual(last, praise);
            seen.Add(praise);
            last = praise;
            d.Press(KeyInput.Return);
        }
        Assert.True(seen.Count > 2);
    }

    // MARK: - Misses

    [Fact]
    public void WrongAnswer()
    {
        var d = Driver();
        var fx = d.Answer("  la chatte ");
        Assert.Equal(Wrong, d.Phase);
        Assert.Equal(new Effect.RecordAnswer("a", false, d.Now), fx[0]);
        Assert.Contains(new Effect.Haptic(HapticKind.Failure), fx);
        var pending = new Pending("a:t", "la chatte", false);
        Assert.Equal(pending, d.Saves(fx)[0].Feedback);
        Assert.Equal(pending, d.Stored!.Value.Feedback);
        var fb = d.State.Feedback!;
        Assert.Equal("Nicht ganz.", fb.Title);
        Assert.True(fb.CanOverride && fb.ShowsGiven);
        Assert.Equal("Ich hatte recht", fb.OverrideLabel);
        var hint = fb.HintLabel is { } h ? $" {h}." : "";
        Assert.Equal([$"Nicht ganz. Richtige Antwort: le chat.{hint}"], d.Announcements(fx));
        Assert.Equal("Weiter", WriteFlow.ReturnAction(d.State));
        Assert.Null(WriteFlow.ReturnHint(d.State));
        // Continuing clears the open miss; the next prompt is not announced (focus was on "Weiter").
        var next = d.Press(KeyInput.Return);
        Assert.Equal([new Effect.SaveSession(d.Session!, null)], next);
        Assert.Null(d.Stored!.Value.Feedback);
        Assert.Equal("b", d.Question?.CardId);
    }

    [Fact]
    public void DontKnow()
    {
        var d = Driver();
        var fx = d.Press(KeyInput.OptionReturn);
        Assert.Equal(DontKnowPhase, d.Phase);
        Assert.Equal(new Effect.RecordAnswer("a", false, d.Now), fx[0]);
        Assert.DoesNotContain(fx, e => e is Effect.Haptic);
        Assert.Equal(["Kein Problem. Richtige Antwort: le chat."], d.Announcements(fx));
        var fb = d.State.Feedback!;
        Assert.Equal("Kein Problem – merk dir das:", fb.Title);
        Assert.False(fb.CanOverride || fb.ShowsGiven);
        Assert.Equal(new Pending("a:t", "", true), d.Stored!.Value.Feedback);
        Assert.Empty(d.Press(KeyInput.CommandReturn));
        Assert.Empty(d.Send(new Event.Override()));
        // The button does the same as the key.
        var other = Driver();
        other.Send(new Event.DontKnow());
        Assert.Equal(DontKnowPhase, other.Phase);
    }

    [Fact]
    public void CopyStep()
    {
        var d = Driver(WriteFlowSamples.Personen, copy: true);
        d.Press(KeyInput.Return); // empty: rejected
        Assert.Equal("laid", d.Question?.CardId);
        d.AnswerCorrectly();
        d.Send(new Event.Proceed()); // "Weiter" after a correct answer
        Assert.Equal("moche", d.Question?.CardId);
        var fx = d.Answer("joli");
        Assert.Equal(Phase.Copy, d.Phase);
        Assert.Equal("", d.State.Input);
        Assert.True(d.State.IsInputEditable);
        Assert.Equal("Tippe die richtige Antwort ab", WriteFlow.FieldLabel(d.State));
        Assert.Equal("Richtige Antwort abtippen", WriteFlow.FieldPlaceholder(d.State));
        Assert.Equal("zum Prüfen", WriteFlow.ReturnHint(d.State));
        Assert.EndsWith(" Tippe die richtige Antwort ab.", d.Announcements(fx)[0]);
        // Empty and synonym copies are rejected.
        Assert.Equal([new Effect.Announce("Noch nicht ganz – tippe die richtige Antwort genau ab.")], d.Press(KeyInput.Return));
        Assert.True(d.State.InputInvalid);
        d.Answer("laide");
        Assert.Equal(Phase.Copy, d.Phase);
        Assert.Equal(3, d.State.Rejections);
        d.Type("moch");
        Assert.False(d.State.InputInvalid);
        // The right copy continues (focus stayed in the field: the prompt is announced).
        var next = d.Send(new Event.Submit("moche"));
        Assert.Equal("brave", d.Question?.CardId);
        Assert.Contains(new Effect.SaveSession(d.Session!, null), next);
        Assert.Equal(["Deutsch: lieb"], d.Announcements(next));
    }

    [Fact]
    public void Override()
    {
        var d = Driver();
        d.Answer("la chatte");
        var fx = d.Press(KeyInput.CommandReturn);
        Assert.Equal(new Effect.OverrideLastAnswer("a"), fx[0]);
        Assert.IsType<Effect.SaveSession>(fx[1]);
        Assert.Equal(new Effect.ShowToast(WriteFlow.Toast.CountedAsCorrect), fx[2]);
        Assert.Equal("b", d.Question?.CardId);
        Assert.Equal([new SessionAnswer("a:t", true)], d.Session!.RoundAnswered);
        Assert.Equal(1, d.Progress["a"].Correct);
        Assert.Equal(0, d.Progress["a"].Incorrect);
        Assert.Null(d.Stored!.Value.Feedback);
    }

    [Fact]
    public void OverrideInCopy()
    {
        var d = Driver(copy: true);
        d.Answer("la chatte");
        Assert.Equal(Phase.Copy, d.Phase);
        d.Send(new Event.Override());
        Assert.Equal("b", d.Question?.CardId);
        d.Press(KeyInput.OptionReturn);
        Assert.Equal(Phase.Copy, d.Phase);
        Assert.True(d.State.Feedback?.DontKnow);
        Assert.Empty(d.Press(KeyInput.CommandReturn));
    }

    // MARK: - Rounds and results

    [Fact]
    public void RoundsAndResults()
    {
        var d = Driver(autoAdvance: false);
        d.Answer("falsch");
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        var toSummary = d.Press(KeyInput.Return);
        Assert.Equal(Phase.Summary, d.Phase);
        var summary = d.State.Summary!;
        Assert.Equal((1, 3, 2, 1), (summary.Round, summary.Total, summary.Correct, summary.Incorrect));
        Assert.Equal(["Runde 1 geschafft: 2 von 3 richtig."], d.Announcements(toSummary));
        Assert.Equal("Weiter zu Runde 2", WriteFlow.ReturnAction(d.State));
        Assert.Equal([false, true, true], WriteFlow.SummaryRows(d.State).Select(r => r.Correct ?? false));
        Assert.Equal("le chat", WriteFlow.SummaryRows(d.State)[0].Term);
        Assert.True(WriteFlow.IsStudying(d.State));
        Assert.Empty(d.Press(KeyInput.Return, after: 100)); // locked

        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Equal("a", d.Question?.CardId);
        Assert.False(d.State.AnimatesQuestion);
        Assert.Equal(2, d.Session?.Round);
        d.AnswerCorrectly();
        Assert.Equal("Runde 2 · nur die Begriffe, die noch nicht sassen", WriteFlow.RoundNote(d.State));
        var toResults = d.Press(KeyInput.Return);
        Assert.Equal(Phase.Results, d.Phase);
        var results = d.State.Results!;
        Assert.Equal(3, results.Stats.Total);
        Assert.Equal(2, results.Stats.FirstTryCorrect);
        Assert.Equal(["a"], results.RetryCardIds);
        Assert.Equal(3, results.CardCount);
        Assert.Equal(["Geschafft! 67 Prozent beim ersten Versuch richtig."], d.Announcements(toResults));
        Assert.NotNull(d.Session?.FinishedAt);
        Assert.NotNull(d.Stored!.Value.Session.FinishedAt);
        Assert.False(WriteFlow.IsStudying(d.State));
        Assert.Equal("Falsche nochmal üben", WriteFlow.ReturnAction(d.State));
        Assert.Equal([new WriteFlow.TermRow("a", "a", "le chat", "die Katze", Lang.Fr, Lang.De, Misses: 1)], WriteFlow.HardestRows(d.State));
        Assert.Equal("Du hast alle 3 Begriffe richtig geschrieben.", WriteFlow.ResultsSubtitle(results));

        // "Falsche nochmal üben": a session over the missed card only.
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Equal(StudySubset.CardIds(["a"]), d.Session?.Subset);
        Assert.Equal(["a:t"], d.Session!.Order);
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Results, d.Phase);
        Assert.False(d.State.Results?.CanRetry);
        Assert.Equal("Fertig", WriteFlow.ReturnAction(d.State));
        Assert.Equal([new Effect.Exit()], d.Press(KeyInput.Return));
        Assert.Equal(1, d.Exits);
        // Ctrl+Shift+R "Nochmal von vorne": a card-id session restarts with all cards (write.js).
        d.Send(new Event.Restart());
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Equal(StudySubset.All, d.Session?.Subset);
        Assert.Equal(3, d.Session!.Order.Count);
    }

    [Fact]
    public void LastQuestionPaths()
    {
        var d = Driver([new Card("a", "un", "eins"), new Card("b", "deux", "zwei")]);
        d.Answer("x");
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.FireTimer();
        Assert.Equal(Phase.Summary, d.Phase);
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.Press(KeyInput.Character("q"));
        Assert.Equal(Phase.Results, d.Phase);
        // The key did not land anywhere.
        Assert.Equal("", d.State.Input);
    }

    // MARK: - Resuming

    [Fact]
    public void ResumeMiss()
    {
        var d = Driver(copy: true);
        d.Answer("la chatte");
        var d2 = d.Reopen();
        Assert.Equal(Phase.Copy, d2.Phase);
        Assert.Equal("a", d2.Question?.CardId);
        Assert.Equal("la chatte", d2.State.Feedback?.Given);
        Assert.False(d2.State.Feedback?.Result?.Correct);
        Assert.Contains(new Effect.ShowToast(WriteFlow.Toast.WelcomeBack), d2.Effects);
        Assert.StartsWith("Nicht ganz. Richtige Antwort: le chat.", d2.Announcements()[0]);
        // Time away is not study time.
        Assert.Equal(d2.Now, d2.Session?.UpdatedAt);
        Assert.Equal(d.Session?.ElapsedMs, d2.Session?.ElapsedMs);
        d2.Answer("le chat");
        Assert.Equal("b", d2.Question?.CardId);
        Assert.Null(d2.Stored!.Value.Feedback);
        // A "Weiss ich nicht" comes back as such.
        d2.Press(KeyInput.OptionReturn);
        var d3 = d2.Reopen();
        Assert.Equal(Phase.Copy, d3.Phase);
        Assert.True(d3.State.Feedback?.DontKnow);
        Assert.Null(d3.State.Feedback?.Result);
    }

    [Fact]
    public void ResumeQuestion()
    {
        var d = Driver();
        var fresh = d.Reopen();
        Assert.Equal(Phase.Question, fresh.Phase);
        Assert.Empty(fresh.Effects);
        d.AnswerCorrectly();
        var d2 = d.Reopen();
        Assert.Equal("b", d2.Question?.CardId);
        Assert.Equal([new Effect.ShowToast(WriteFlow.Toast.WelcomeBack)], d2.Effects);
        // forceNew starts over.
        var d3 = d.Reopen(forceNew: true);
        Assert.Equal("a", d3.Question?.CardId);
        Assert.Empty(d3.Session!.RoundAnswered);
    }

    [Fact]
    public void ResumeSummary()
    {
        var d = Driver(autoAdvance: false);
        d.Answer("x");
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Summary, d.Phase);
        var d2 = d.Reopen();
        Assert.Equal(Phase.Summary, d2.Phase);
        Assert.Equal(d.State.Summary!.ToJson().ToString(), d2.State.Summary!.ToJson().ToString());
    }

    [Fact]
    public void ResultsAgain()
    {
        var d = Driver([new Card("a", "un", "eins")]);
        d.AnswerCorrectly();
        // Left during the final "Richtig!": the round is still open.
        var marker = d.State.ResultsMarker;
        var again = d.Reopen(marker: marker);
        Assert.Equal(Phase.Results, again.Phase);
        Assert.Equal(1, again.State.Results?.Stats.Total);
        Assert.Single(again.Stored!.Value.Session.Rounds);
        var fresh = d.Reopen(marker: null);
        Assert.Equal(Phase.Question, fresh.Phase);
        Assert.NotEqual(d.Session?.StartedAt, fresh.Session?.StartedAt);
    }

    [Fact]
    public void ReplaceRoundPrompt()
    {
        var d = Driver();
        d.Answer("x");
        var asked = d.Reopen(subset: StudySubset.Starred);
        Assert.Equal(Phase.Starting, asked.Phase);
        var prompt = asked.State.Prompt!;
        Assert.Equal("Laufende Runde beenden?", prompt.Title);
        Assert.Equal("Neue Runde starten", prompt.ConfirmLabel);
        Assert.Equal("Runde fortsetzen", prompt.CancelLabel);
        Assert.Null(WriteFlow.ReturnAction(asked.State));
        Assert.Empty(asked.Press(KeyInput.Return));
        Assert.Empty(asked.Press(KeyInput.Escape));
        asked.Send(new Event.PromptAnswered(true));
        Assert.Equal(Phase.Question, asked.Phase);
        Assert.Equal(StudySubset.Starred, asked.Session?.Subset);
        Assert.Equal("b", asked.Question?.CardId);

        var d2 = Driver();
        d2.Answer("x");
        var kept = d2.Reopen(subset: StudySubset.Starred);
        kept.Send(new Event.PromptAnswered(false));
        Assert.Equal(Wrong, kept.Phase);
        Assert.Equal(StudySubset.All, kept.Session?.Subset);
        Assert.Contains(new Effect.ShowToast(WriteFlow.Toast.WelcomeBack), kept.Effects);

        // Without answers there is nothing to lose.
        var d3 = Driver();
        var direct = d3.Reopen(subset: StudySubset.Starred);
        Assert.Equal(Phase.Question, direct.Phase);
        Assert.Equal(StudySubset.Starred, direct.Session?.Subset);
    }

    // MARK: - Empty subsets

    [Fact]
    public void EmptySubset()
    {
        var d = new WriteFlowDriver(WriteFlowSamples.Three(), options: new StudyOptionsPatch(Shuffle: false), open: false);
        d.Open(StudySubset.Missed);
        Assert.Equal(Phase.Empty, d.Phase);
        Assert.Equal(StudySubset.Missed, d.State.EmptySubset);
        Assert.Equal("Alle Begriffe üben", WriteFlow.ReturnAction(d.State));
        Assert.Null(d.Session);
        Assert.Empty(d.Send(new Event.RequestOptions()));
        Assert.Null(d.State.Overlay);
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Equal(StudySubset.All, d.Session?.Subset);
        var e = new WriteFlowDriver(WriteFlowSamples.Three(), options: new StudyOptionsPatch(Shuffle: false), open: false);
        e.Open(StudySubset.Learning);
        Assert.Equal(Phase.Question, e.Phase); // nothing mastered yet
        var f = new WriteFlowDriver(WriteFlowSamples.Three(), options: new StudyOptionsPatch(Shuffle: false), open: false);
        f.Open(StudySubset.Missed);
        f.Send(new Event.PracticeAll());
        Assert.Equal(Phase.Question, f.Phase);
    }

    [Fact]
    public void NoCards()
    {
        var d = new WriteFlowDriver([new Card("x", "un", " ")]);
        Assert.Equal(Phase.Empty, d.Phase);
        Assert.Equal(StudySubset.All, d.State.EmptySubset);
        Assert.Equal("Begriffe hinzufügen", WriteFlow.ReturnAction(d.State));
        Assert.Equal([new Effect.EditSet()], d.Press(KeyInput.Return));
        Assert.Equal(1, d.EditorRequests);
        Assert.Equal(Phase.Empty, d.Phase);
    }

    // MARK: - Options and dialogs

    [Fact]
    public void OptionsRestart()
    {
        var d = Driver();
        d.AnswerCorrectly();
        d.Send(new Event.RequestOptions());
        Assert.Null(d.State.AutoAdvance);
        Assert.Equal(new WriteFlow.Overlay.Options(new WriteFlow.OptionsBaseline(AnswerWith.Term, false, false), true), d.State.Overlay);
        Assert.Null(WriteFlow.ReturnAction(d.State));
        Assert.Empty(d.Press(KeyInput.Return));
        Assert.Empty(d.Press(KeyInput.Character("x")));
        Assert.Empty(d.Send(new Event.AutoAdvanceFired(1)));
        var options = d.State.Options with { AnswerWith = AnswerWith.Both };
        d.Send(new Event.OptionsChanged(options));
        d.Send(new Event.OverlayDismissed());
        var prompt = d.State.Prompt!;
        Assert.Equal(new WriteFlow.Prompt.RestartForOptions(true, true, false), prompt);
        Assert.StartsWith("Die neue Abfragerichtung gilt ab einem Neustart.", prompt.MessageText);
        Assert.Equal("Später", prompt.CancelLabel);
        // "Später": the paused timer runs again.
        var later = d.Send(new Event.PromptAnswered(false));
        Assert.Equal(Correct, d.Phase);
        Assert.Contains(new Effect.ScheduleAutoAdvance(900, 2), later);
        Assert.Equal(1, d.State.FocusSerial);
        // Closing the sheet again without a change does not ask again.
        d.Send(new Event.RequestOptions());
        d.Send(new Event.OverlayDismissed());
        Assert.Null(d.State.Prompt);
        // A new order asks too; confirming starts over with the new options.
        d.Send(new Event.RequestOptions());
        options = options with { Shuffle = true };
        d.Send(new Event.OptionsChanged(options));
        d.Send(new Event.OverlayDismissed());
        Assert.Equal(new WriteFlow.Prompt.RestartForOptions(false, true, false), d.State.Prompt);
        Assert.StartsWith("Die neue Reihenfolge", d.State.Prompt!.MessageText);
        d.Send(new Event.PromptAnswered(true));
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Equal(new SessionSetOptions(AnswerWith.Both, true), d.Session?.SetOptions);
        Assert.Equal(6, d.Session!.Order.Count);
    }

    [Fact]
    public void OptionsCopyAndRestart()
    {
        var d = Driver();
        d.Answer("x");
        d.Send(new Event.RequestOptions());
        var options = d.State.Options with { CopyAnswer = true };
        d.Send(new Event.OptionsChanged(options));
        d.Send(new Event.OverlayDismissed());
        Assert.Null(d.State.Prompt);
        Assert.Equal(Phase.Copy, d.Phase);
        // Changing only the tolerance resumes quietly.
        d.Send(new Event.RequestOptions());
        options = options with { Tolerance = options.Tolerance with { Typos = false } };
        d.Send(new Event.OptionsChanged(options));
        d.Send(new Event.OverlayDismissed());
        Assert.Equal(Phase.Copy, d.Phase);
        // "Neu starten" in the sheet asks first.
        d.Send(new Event.RequestOptions());
        d.Send(new Event.OverlayDismissed(RestartRequested: true));
        Assert.Equal(new WriteFlow.Prompt.Restart(false), d.State.Prompt);
        d.Send(new Event.PromptAnswered(true));
        Assert.Equal(Phase.Question, d.Phase);
        Assert.Empty(d.Session!.RoundAnswered);
    }

    [Fact]
    public void RestartPrompt()
    {
        var d = Driver();
        d.AnswerCorrectly();
        d.Send(new Event.Restart());
        Assert.Equal(new WriteFlow.Prompt.Restart(true), d.State.Prompt);
        Assert.Equal("Abbrechen", d.State.Prompt!.CancelLabel);
        var fx = d.Send(new Event.PromptAnswered(false));
        Assert.Contains(new Effect.ScheduleAutoAdvance(900, 2), fx);
        Assert.Equal(Correct, d.Phase);
        // A stray answer without a prompt does nothing.
        Assert.Empty(d.Send(new Event.PromptAnswered(true)));
    }

    // MARK: - Card edits

    [Fact]
    public void EditDuringMiss()
    {
        var d = Driver();
        d.Answer("le chien");
        d.Send(new Event.RequestEdit());
        Assert.Equal(new WriteFlow.Overlay.Editor(new SessionQuestion("a:t", "a", AskSide.Term), AskSide.Term, false), d.State.Overlay);
        Assert.Empty(d.Press(KeyInput.Return));
        var card = WriteFlow.EditorCard(d.State)!;
        Assert.Equal("le chat", card.Term);
        var fx = d.Send(new Event.EditCard(card with { Term = "  le chien " }));
        Assert.Equal(new Effect.UpdateCard(new Card("a", "le chien", "die Katze")), fx[0]);
        Assert.Equal(new Effect.ShowToast(WriteFlow.Toast.CardSaved), fx[^1]);
        Assert.Null(d.State.Overlay);
        Assert.Equal("le chien", d.Store.GetSet(d.SetId)?.Cards[0].Term);
        Assert.Equal("le chien", d.Question?.Expected);
        var fb = d.State.Feedback!;
        Assert.True(fb.EditedCorrect);
        Assert.Equal("Als richtig zählen", fb.OverrideLabel);
        Assert.NotNull(fb.EditedNote);
        Assert.False(fb.ShowsHint);
        d.Press(KeyInput.CommandReturn);
        Assert.Equal("b", d.Question?.CardId);
        Assert.Equal(1, d.Progress["a"].Correct);
    }

    [Fact]
    public void EditDuringCorrect()
    {
        var d = Driver();
        d.AnswerCorrectly();
        d.Send(new Event.RequestEdit());
        Assert.Null(d.State.AutoAdvance);
        var card = WriteFlow.EditorCard(d.State)! with { Definition = "die Hauskatze" };
        var fx = d.Send(new Event.EditCard(card));
        Assert.Contains(new Effect.ScheduleAutoAdvance(900, 2), fx);
        Assert.Equal("die Hauskatze", d.Question?.Prompt);
        d.Send(new Event.RequestEdit());
        var cancel = d.Send(new Event.OverlayDismissed());
        Assert.Contains(new Effect.ScheduleAutoAdvance(900, 3), cancel);
        // Empty sides are never saved.
        d.Send(new Event.RequestEdit());
        card = card with { Term = " " };
        Assert.Empty(d.Send(new Event.EditCard(card)));
        Assert.NotNull(d.State.Overlay);
        // Without the editor open nothing is saved.
        d.Send(new Event.OverlayDismissed());
        Assert.Empty(d.Send(new Event.EditCard(card)));
    }

    [Fact]
    public void EditDuringQuestion()
    {
        var d = Driver();
        d.Type("le ch");
        d.Send(new Event.RequestEdit());
        var card = WriteFlow.EditorCard(d.State)! with { Term = "le matou" };
        d.Send(new Event.EditCard(card));
        Assert.Equal("le matou", d.Question?.Expected);
        Assert.Equal("le ch", d.State.Input);
        Assert.Equal(Phase.Question, d.Phase);
        // No editor outside the card.
        var e = new WriteFlowDriver([new Card("x", "un", " ")]);
        e.Send(new Event.RequestEdit());
        Assert.Null(e.State.Overlay);
    }

    [Fact]
    public void ToggleStar()
    {
        var d = Driver();
        Assert.False(d.Question?.Starred);
        Assert.Equal([new Effect.ToggleStar("a")], d.Send(new Event.ToggleStar()));
        Assert.True(d.Question?.Starred);
        Assert.True(d.Store.GetSet(d.SetId)?.Cards[0].Starred);
        d.AnswerCorrectly();
        d.Send(new Event.ToggleStar());
        Assert.False(d.Question?.Starred);
    }

    [Fact]
    public void SpeakButtons()
    {
        var d = Driver();
        Assert.Equal([new Effect.Speak("die Katze", Lang.De)], d.Send(new Event.Speak(WriteFlow.SpeechTarget.Prompt)));
        Assert.Equal([new Effect.Speak("le chat", Lang.Fr)], d.Send(new Event.Speak(WriteFlow.SpeechTarget.Answer)));
        var other = Driver(termLang: Lang.Other, defLang: Lang.Other);
        Assert.Empty(other.Send(new Event.Speak(WriteFlow.SpeechTarget.Prompt)));
    }

    [Fact]
    public void Audio()
    {
        var d = Driver(audio: true, answerWith: AnswerWith.Definition);
        Assert.Contains(new Effect.Speak("le chat", Lang.Fr), d.Effects);
        Assert.Contains(new Effect.Speak("le chat", Lang.Fr), d.Answer("die Katze"));
        var plain = Driver(audio: true);
        Assert.DoesNotContain(plain.Effects, e => e is Effect.Speak);
        Assert.Contains(new Effect.Speak("le chat", Lang.Fr), plain.Answer("x"));
    }

    // MARK: - Live updates

    [Fact]
    public void LiveUpdates()
    {
        var d = Driver();
        var cards = WriteFlowSamples.Three();
        d.Type("le c");
        var fx = d.Send(new Event.CardsChanged([cards[1], cards[2]]));
        Assert.Single(d.Saves(fx));
        Assert.Equal("b", d.Question?.CardId);
        Assert.Equal("le c", d.State.Input);
        Assert.Equal(["b:t", "c:t"], d.Session!.Order);
        // A changed text updates the card on screen.
        d.Send(new Event.CardsChanged([cards[1] with { Definition = "der Rüde" }, cards[2]]));
        Assert.Equal("der Rüde", d.Question?.Prompt);
        // Nothing usable left: the empty message.
        d.Send(new Event.CardsChanged([]));
        Assert.Equal(Phase.Empty, d.Phase);
        Assert.Equal(StudySubset.All, d.State.EmptySubset);
        d.Send(new Event.SetDeleted());
        Assert.Equal(Phase.Missing, d.Phase);
        Assert.Null(d.Session);
        Assert.Null(d.State.Set);
    }

    [Fact]
    public void LiveUpdatesAfterRounds()
    {
        var d = Driver(autoAdvance: false);
        var cards = WriteFlowSamples.Three();
        d.Answer("x");
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        d.Answer("y");
        d.Press(KeyInput.Return);
        Assert.Equal(2, d.State.Summary?.Incorrect);
        d.Send(new Event.CardsChanged([cards[1], cards[2]]));
        Assert.Equal(Phase.Summary, d.Phase);
        Assert.Equal(2, d.State.Summary?.Total);
        d.Press(KeyInput.Return);
        d.AnswerCorrectly();
        d.Press(KeyInput.Return);
        Assert.Equal(Phase.Results, d.Phase);
        d.Send(new Event.CardsChanged([cards[1]]));
        Assert.Equal(Phase.Results, d.Phase);
        Assert.Equal(1, d.State.Results?.Stats.Total);
        // The card being edited disappears: the editor closes.
        var e = Driver();
        e.Send(new Event.RequestEdit());
        e.Send(new Event.CardsChanged([cards[1], cards[2]]));
        Assert.Null(e.State.Overlay);
        Assert.Equal(1, e.State.FocusSerial);
    }

    // MARK: - Study clock

    [Fact]
    public void Clock()
    {
        var d = Driver();
        double start = d.Session!.ElapsedMs;
        var fx = d.Send(new Event.ClockTick(), after: 15_000);
        Assert.Equal([new Effect.SaveSession(d.Session!, null)], fx);
        Assert.Equal(start + 15_000, d.Session!.ElapsedMs);
        // Hidden or idle: the gap is skipped.
        Assert.Empty(d.Send(new Event.ClockResumed(), after: 600_000));
        Assert.Equal(d.Now, d.Session!.UpdatedAt);
        d.Send(new Event.ClockTick(), after: 1000);
        Assert.Equal(start + 16_000, d.Session!.ElapsedMs);
        // Not while the results are shown.
        var one = Driver([new Card("a", "un", "eins")]);
        one.AnswerCorrectly();
        one.FireTimer();
        Assert.Equal(Phase.Results, one.Phase);
        Assert.Empty(one.Send(new Event.ClockTick()));
        Assert.Empty(one.Send(new Event.ClockResumed()));
    }

    // MARK: - Leaving

    [Fact]
    public void Leaving()
    {
        var d = Driver();
        Assert.Equal([new Effect.Exit()], d.Press(KeyInput.Escape));
        Assert.Empty(d.Press(KeyInput.Escape, isRepeat: true));
        Assert.Equal([new Effect.Exit()], d.Send(new Event.Leave()));
        Assert.Equal(2, d.Exits);
        Assert.Equal(Phase.Question, d.Phase);
    }
}
