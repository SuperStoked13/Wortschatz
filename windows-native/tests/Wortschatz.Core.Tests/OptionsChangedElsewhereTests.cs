using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Windows only so far (24.11.2026; Anthony's issues #7 and #8, found on the Mac).
// #7: options that shape a session (Lernen: direction, question types, round size; Schreiben: direction, «Mischen»)
// changed outside it (Einstellungen, the set's options) used to leave a started session running with the old ones,
// silently. Now resuming asks «Neu starten?»; «Später» is kept (KeptOptions) until the options change again.
// #8: an option of a set set back to the standard used to stay the set's own (LibraryStore.UpdateOwnStudyOptions).
public class OptionsChangedElsewhereTests
{
    const double T0 = 1_760_000_000_000;

    static List<Card> MakeCards(int n) => Enumerable.Range(1, n).Select(i => new Card($"c{i}", $"terme {i}", $"Begriff {i}")).ToList();

    static VocabSet Set(List<Card> cards) => new() { Id = "set1", Title = "Wörter", TermLang = Lang.Fr, DefLang = Lang.De, Cards = cards, CreatedAt = T0 };

    static readonly StudyOptions Standard = StudyOptions.Default;
    static readonly StudyOptions OtherDirection = StudyOptions.Default with { AnswerWith = AnswerWith.Definition };

    // MARK: - Lernen (#7)

    /// <summary>A session with one answer (right), as stored, and the progress after it.</summary>
    static (LearnState Session, Dictionary<string, CardProgress> Progress) StartedSession(List<Card> cards)
    {
        var progress = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        var (state, _) = LearnFlow.Start(Set(cards), progress, Standard, rng: Rand.Mulberry32(2u), now: T0);
        var q = state.Question!;
        LearnFlow.Event answer = state.Phase.QuestionType == QuestionType.Mc
            ? new LearnFlow.Event.Choose(q.Choices.ToList().FindIndex(c => c.CardId == q.CardId))
            : new LearnFlow.Event.Submit(q.Expected);
        var (after, effects) = LearnFlow.Reduce(state, answer, new LearnFlow.Env(Rand.Mulberry32(2u), T0 + 5000, progress));
        foreach (var r in effects.OfType<LearnFlow.Effect.RecordAnswer>()) progress[r.CardId] = Mastery.ApplyAnswer(progress.GetValueOrDefault(r.CardId), r.Correct, r.At);
        Assert.True(LearnFlow.HasLearnAnswers(after.Session));
        return (after.Session!, progress);
    }

    [Fact]
    public void LearnAsksWhenTheDirectionChangedElsewhere()
    {
        var cards = MakeCards(8);
        var (session, progress) = StartedSession(cards);
        var (state, _) = LearnFlow.Start(Set(cards), progress, OtherDirection, new LearnFlow.SavedLearn(session), rng: Rand.Mulberry32(3u), now: T0 + 60_000);
        Assert.Equal(session.StartedAt, state.Session?.StartedAt);
        Assert.Equal(new LearnFlow.Prompt.RestartForOptions([LearnFlow.SettingsChange.Direction]), state.Prompt);
        Assert.Contains("Abfragerichtung", LearnFlow.RunningSettingsNote(state));
        // «Neu starten»: a new session in the new direction.
        var (restarted, _) = LearnFlow.Reduce(state, new LearnFlow.Event.PromptAnswered(true), new LearnFlow.Env(Rand.Mulberry32(3u), T0 + 61_000, progress));
        Assert.Equal(AnswerWith.Definition, restarted.Session?.AnswerWith);
        Assert.NotEqual(session.StartedAt, restarted.Session?.StartedAt);
        Assert.Null(LearnFlow.RunningSettingsNote(restarted));
    }

    [Fact]
    public void LearnLaterIsKeptUntilTheOptionsChangeAgain()
    {
        var cards = MakeCards(8);
        var (session, progress) = StartedSession(cards);
        var (state, _) = LearnFlow.Start(Set(cards), progress, OtherDirection, new LearnFlow.SavedLearn(session), rng: Rand.Mulberry32(3u), now: T0 + 60_000);
        var (later, effects) = LearnFlow.Reduce(state, new LearnFlow.Event.PromptAnswered(false), new LearnFlow.Env(Rand.Mulberry32(3u), T0 + 61_000, progress));
        var kept = Assert.Single(effects.OfType<LearnFlow.Effect.KeepOptions>()).Kept;
        Assert.Equal(session.StartedAt, kept.StartedAt);
        Assert.Equal(AnswerWith.Term, later.Session?.AnswerWith);
        // The note stays: the session runs in the old direction.
        Assert.NotNull(LearnFlow.RunningSettingsNote(later));
        // Opened again: not asked again.
        var (again, _) = LearnFlow.Start(Set(cards), progress, OtherDirection, new LearnFlow.SavedLearn(later.Session!), rng: Rand.Mulberry32(4u),
            now: T0 + 120_000, kept: kept);
        Assert.Null(again.Prompt);
        // Closing the options without a change does not ask either.
        var env = new LearnFlow.Env(Rand.Mulberry32(4u), T0 + 121_000, progress);
        var (open, _) = LearnFlow.Reduce(again, new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options), env);
        (open, _) = LearnFlow.Reduce(open, new LearnFlow.Event.OverlayDismissed(), env);
        Assert.Null(open.Prompt);
        // Changed again (round size too): asked again.
        var bigger = OtherDirection with { Learn = OtherDirection.Learn with { RoundSize = 12 } };
        var (changed, _) = LearnFlow.Start(Set(cards), progress, bigger, new LearnFlow.SavedLearn(later.Session!), rng: Rand.Mulberry32(4u),
            now: T0 + 180_000, kept: kept);
        Assert.Equal(new LearnFlow.Prompt.RestartForOptions([LearnFlow.SettingsChange.Direction, LearnFlow.SettingsChange.RoundSize]), changed.Prompt);
        // Kept for another session: asked.
        var (other, _) = LearnFlow.Start(Set(cards), progress, OtherDirection, new LearnFlow.SavedLearn(later.Session!), rng: Rand.Mulberry32(4u),
            now: T0 + 180_000, kept: kept with { StartedAt = kept.StartedAt + 1 });
        Assert.NotNull(other.Prompt);
    }

    [Fact]
    public void LearnWithoutAnswersStartsAgainWithTheNewOptions()
    {
        var cards = MakeCards(8);
        var (first, _) = LearnFlow.Start(Set(cards), new Dictionary<string, CardProgress>(), Standard, rng: Rand.Mulberry32(2u), now: T0);
        var types = Standard with { Learn = Standard.Learn with { Mc = false } };
        var (state, effects) = LearnFlow.Start(Set(cards), new Dictionary<string, CardProgress>(), types, new LearnFlow.SavedLearn(first.Session!),
            rng: Rand.Mulberry32(3u), now: T0 + 60_000);
        Assert.Null(state.Prompt);
        Assert.False(state.Session?.Learn.Mc);
        Assert.Equal(LearnFlow.Phase.Written, state.Phase);
        Assert.Contains(effects, e => e is LearnFlow.Effect.SaveLearn);
    }

    [Fact]
    public void LearnUnchangedOptionsDoNotAsk()
    {
        var cards = MakeCards(8);
        var (session, progress) = StartedSession(cards);
        // Read-aloud and the tolerance apply at once anyway.
        var audio = Standard with { Audio = true, Tolerance = Standard.Tolerance with { Typos = true } };
        var (state, _) = LearnFlow.Start(Set(cards), progress, audio, new LearnFlow.SavedLearn(session), rng: Rand.Mulberry32(3u), now: T0 + 60_000);
        Assert.Null(state.Prompt);
        Assert.Null(LearnFlow.RunningSettingsNote(state));
    }

    [Fact]
    public void LearnAsksWhenOptionsChangeOutsideWhileItIsOpen()
    {
        var cards = MakeCards(8);
        var (session, progress) = StartedSession(cards);
        var (state, _) = LearnFlow.Start(Set(cards), progress, Standard, new LearnFlow.SavedLearn(session), rng: Rand.Mulberry32(3u), now: T0 + 60_000);
        Assert.Null(state.Prompt);
        var env = new LearnFlow.Env(Rand.Mulberry32(3u), T0 + 61_000, progress);
        var (after, _) = LearnFlow.Reduce(state, new LearnFlow.Event.OptionsChanged(Standard with { Learn = Standard.Learn with { RoundSize = 10 } }), env);
        Assert.Equal(new LearnFlow.Prompt.RestartForOptions([LearnFlow.SettingsChange.RoundSize]), after.Prompt);
        // Read-aloud only: no question.
        var (audio, _) = LearnFlow.Reduce(state, new LearnFlow.Event.OptionsChanged(Standard with { Audio = true }), env);
        Assert.Null(audio.Prompt);
    }

    // MARK: - Schreiben (#7)

    static WriteFlowDriver WriteDriver() => new(WriteFlowSamples.Three(), options: new StudyOptionsPatch(Shuffle: false, AutoAdvance: false));

    [Fact]
    public void WriteAsksWhenTheDirectionChangedElsewhere()
    {
        var d = WriteDriver();
        d.AnswerCorrectly();
        d.Store.UpdateStudyOptions(d.SetId, new StudyOptionsPatch(AnswerWith: AnswerWith.Both));
        var again = d.Reopen();
        Assert.Equal(new WriteFlow.Prompt.RestartForOptions(true, false, false), again.State.Prompt);
        Assert.Contains("Abfragerichtung", WriteFlow.RunningSettingsNote(again.State));
        var later = again.Send(new WriteFlow.Event.PromptAnswered(false));
        var kept = Assert.Single(later.OfType<WriteFlow.Effect.KeepOptions>()).Kept;
        Assert.Equal(AnswerWith.Term, again.Session?.SetOptions.AnswerWith);
        // Opened again: not asked again.
        Assert.Null(again.Reopen(kept: kept).State.Prompt);
        // «Mischen» changed too: asked again.
        d.Store.UpdateStudyOptions(d.SetId, new StudyOptionsPatch(Shuffle: true));
        var third = again.Reopen(kept: kept);
        Assert.Equal(new WriteFlow.Prompt.RestartForOptions(true, false, false), third.State.Prompt);
        third.Send(new WriteFlow.Event.PromptAnswered(true));
        Assert.Equal(new SessionSetOptions(AnswerWith.Both, true), third.Session?.SetOptions);
        Assert.Null(WriteFlow.RunningSettingsNote(third.State));
    }

    [Fact]
    public void WriteOrderOnlyChangedElsewhereAsks()
    {
        var d = WriteDriver();
        d.AnswerCorrectly();
        d.Store.UpdateStudyOptions(d.SetId, new StudyOptionsPatch(Shuffle: true));
        var again = d.Reopen();
        Assert.Equal(new WriteFlow.Prompt.RestartForOptions(false, false, false), again.State.Prompt);
        Assert.StartsWith("Die neue Reihenfolge", again.State.Prompt!.MessageText);
    }

    [Fact]
    public void WriteWithoutAnswersStartsAgainWithTheNewOptions()
    {
        var d = WriteDriver();
        var started = d.Session!.StartedAt;
        d.Store.UpdateStudyOptions(d.SetId, new StudyOptionsPatch(AnswerWith: AnswerWith.Definition));
        var again = d.Reopen();
        Assert.Null(again.State.Prompt);
        Assert.Equal(AnswerWith.Definition, again.Session?.SetOptions.AnswerWith);
        Assert.NotEqual(started, again.Session?.StartedAt);
    }

    [Fact]
    public void WriteAsksWhenOptionsChangeOutsideWhileItIsOpen()
    {
        var d = WriteDriver();
        d.AnswerCorrectly();
        d.Send(new WriteFlow.Event.OptionsChanged(d.State.Options with { CopyAnswer = false }));
        Assert.Null(d.State.Prompt);
        d.Send(new WriteFlow.Event.OptionsChanged(d.State.Options with { AnswerWith = AnswerWith.Definition }));
        Assert.Equal(new WriteFlow.Prompt.RestartForOptions(true, false, false), d.State.Prompt);
    }

    // MARK: - Own options of a set (#8)

    static (LibraryStore Store, string SetId) StoreWithSet()
    {
        var store = new LibraryStore(new MemoryBackend());
        var set = store.CreateSet("Wörter");
        return (store, set.Id);
    }

    [Fact]
    public void AnOptionSetBackToTheStandardIsNoLongerTheSetsOwn()
    {
        var (store, id) = StoreWithSet();
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Audio: true));
        Assert.Equal(new StudyOptionsPatch(Audio: true), store.GetSet(id)!.StudyOptions);
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Audio: false));
        Assert.Null(store.GetSet(id)!.StudyOptions);
        // The standard switched on later: the set follows it.
        store.UpdateSettings(new SettingsPatch(Study: new StudyOptionsPatch(Audio: true)));
        Assert.True(store.GetStudyOptions(id).Audio);
    }

    [Fact]
    public void NestedOptionsSetBackToTheStandardGoToo()
    {
        var (store, id) = StoreWithSet();
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Tolerance: new TolerancePatch(Typos: true), Learn: new LearnOptionsPatch(RoundSize: 12)));
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Learn: new LearnOptionsPatch(Mc: false)));
        Assert.Equal(new StudyOptionsPatch(Tolerance: new TolerancePatch(Typos: true), Learn: new LearnOptionsPatch(RoundSize: 12, Mc: false)),
            store.GetSet(id)!.StudyOptions);
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Tolerance: new TolerancePatch(Typos: false), Learn: new LearnOptionsPatch(RoundSize: 7)));
        Assert.Equal(new StudyOptionsPatch(Learn: new LearnOptionsPatch(Mc: false)), store.GetSet(id)!.StudyOptions);
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Learn: new LearnOptionsPatch(Mc: true)));
        Assert.Null(store.GetSet(id)!.StudyOptions);
    }

    [Fact]
    public void TheValuesInEffectStayAndOtherOwnOptionsAreLeft()
    {
        var (store, id) = StoreWithSet();
        store.UpdateSettings(new SettingsPatch(Study: new StudyOptionsPatch(AnswerWith: AnswerWith.Both)));
        // Stored the old way (the web app's mergeStudy, kept for parity): its own «Antworten auf» equals the standard.
        store.UpdateStudyOptions(id, new StudyOptionsPatch(AnswerWith: AnswerWith.Both, Shuffle: false));
        var before = store.GetStudyOptions(id);
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(Audio: true));
        Assert.Equal(new StudyOptionsPatch(AnswerWith: AnswerWith.Both, Shuffle: false, Audio: true), store.GetSet(id)!.StudyOptions);
        Assert.Equal(before with { Audio = true }, store.GetStudyOptions(id));
        // Set back to the standard: only what was set goes.
        store.UpdateOwnStudyOptions(id, new StudyOptionsPatch(AnswerWith: AnswerWith.Both, Shuffle: true));
        Assert.Equal(new StudyOptionsPatch(Audio: true), store.GetSet(id)!.StudyOptions);
    }
}
