using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of WriteFlow.swift: Write mode ("Schreiben") as a pure reducer (spec §6), a port of the state
// machine in src/screens/write.js with the keyboard rules of write-keys.js, the card states of
// write-card.js and the round/results logic of write-views.js.
//
// The Avalonia view renders State and forwards events; the app performs the returned effects (store
// writes, speech, sounds, screen reader, timers, navigation). Nothing here touches the store, the clock
// or the system random source directly: Env supplies time, randomness and the current progress.
//
// Phases: question → feedback (correct | wrong | dontKnow) or the copy step → … → round summary → … →
// results. Every session change is persisted with Effect.SaveSession, including the open "Nicht ganz"
// screen (Pending), so leaving and coming back resumes exactly where the learner stopped.
//
// C# shapes of Swift's enums with associated values (same names):
// - Phase: record struct with Kind (+ Feedback for Kind Feedback): `Phase.FeedbackOf(FeedbackKind.Correct)`.
// - Overlay, Prompt, Event, Effect: abstract records with one nested record per Swift case
//   (`new Event.Submit("…")`, `effect is Effect.SaveSession`).
// - State: a class with public getters; the reducer works on a Clone (Swift copies the struct).

public static partial class WriteFlow
{
    // MARK: - Constants

    /// <summary>Auto-advance after an exact correct answer (<c>ADVANCE_MS</c>).</summary>
    public const int AdvanceMs = 900;
    /// <summary>Auto-advance after a tolerated answer, time to read "Genau: …" (<c>ADVANCE_MS_WITH_NOTES</c>).</summary>
    public const int AdvanceMsWithNotes = 1800;
    /// <summary>Return-family keys are ignored this long after a transition (<c>ENTER_LOCK_MS</c>).</summary>
    public const double EnterLockMs = 280;
    /// <summary>After a correct answer, Return within the lock moves on when the lock ends; closer presses count as the answering press.</summary>
    public const double SkipMinGapMs = 50;
    /// <summary>Praise after an exact answer; never the same twice in a row (<c>PRAISE</c>).</summary>
    public static string[] Praise => [L("Richtig!"), L("Super!"), L("Genau!"), L("Stark!")];
    /// <summary>How often the app should send ClockTick while the window is visible (write-clock.js).</summary>
    public const double ClockTickMs = 15_000;
    /// <summary>After this long without input the app stops ticking and sends ClockResumed on the next input.</summary>
    public const double ClockIdleMs = 2 * 60 * 1000;

    // MARK: - Phase

    /// <summary>The kind of feedback after an answer.</summary>
    public enum FeedbackKind
    {
        /// <summary>"Richtig!": the answer was accepted.</summary>
        Correct,
        /// <summary>"Nicht ganz.": a wrong answer.</summary>
        Wrong,
        /// <summary>"Kein Problem – merk dir das:": the learner chose "Weiss ich nicht".</summary>
        DontKnow,
    }

    public enum PhaseKind
    {
        /// <summary>Nothing is shown yet: the start question (Prompt "Laufende Runde beenden?") is open.</summary>
        Starting,
        /// <summary>A written question; the answer field is editable.</summary>
        Question,
        /// <summary>The feedback after an answer, without a copy step.</summary>
        Feedback,
        /// <summary>A miss with the copy step ("Richtige Antwort abtippen").</summary>
        Copy,
        /// <summary>The round summary ("Runde 1 geschafft", "Weiter zu Runde 2").</summary>
        Summary,
        /// <summary>The results of the finished session.</summary>
        Results,
        /// <summary>Nothing to practise in the requested subset (EmptyMessage).</summary>
        Empty,
        /// <summary>The set does not exist (any more).</summary>
        Missing,
    }

    public readonly record struct Phase(PhaseKind Kind, FeedbackKind FeedbackKind = FeedbackKind.Correct)
    {
        public static readonly Phase Starting = new(PhaseKind.Starting);
        public static readonly Phase Question = new(PhaseKind.Question);
        public static readonly Phase Copy = new(PhaseKind.Copy);
        public static readonly Phase Summary = new(PhaseKind.Summary);
        public static readonly Phase Results = new(PhaseKind.Results);
        public static readonly Phase Empty = new(PhaseKind.Empty);
        public static readonly Phase Missing = new(PhaseKind.Missing);
        public static Phase FeedbackOf(FeedbackKind kind) => new(PhaseKind.Feedback, kind);

        /// <summary>Question, feedback or copy step: the question card is shown.</summary>
        public bool IsCard => Kind is PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy;

        /// <summary>A miss is shown (wrong or "Weiss ich nicht", with or without the copy step).</summary>
        public bool IsMiss => Kind == PhaseKind.Copy || (Kind == PhaseKind.Feedback && FeedbackKind != FeedbackKind.Correct);

        public override string ToString() => Kind == PhaseKind.Feedback ? $"feedback({FeedbackKind})" : Kind.ToString();
    }

    // MARK: - State parts

    /// <summary>
    /// The answered question's outcome (<c>last</c> in write.js). Given: what was typed, trimmed ("" for "Weiss ich
    /// nicht"); Result: null for "Weiss ich nicht"; Copy: the copy step is shown; EditedCorrect: the card was edited
    /// during the miss and now accepts what was typed; Synonym: the answer belongs to another card with the same
    /// prompt; Praise: the title of a correct answer.
    /// </summary>
    public sealed record Feedback(string Given, GradeResult? Result, bool DontKnow, bool Copy = false, bool EditedCorrect = false,
        bool Synonym = false, string? Praise = null)
    {
        public bool IsCorrect => Result?.Correct == true;

        /// <summary>"Super!" after a correct answer, "Nicht ganz." after a miss and "Kein Problem – merk dir das:" after "Weiss ich nicht".</summary>
        public string Title => IsCorrect ? Praise ?? L("Richtig!") : DontKnow ? L("Kein Problem – merk dir das:") : L("Nicht ganz.");

        /// <summary>Introduces Result.ExpectedDisplay after a tolerated answer: "Genau:", or "Gesucht war:" for a synonym.</summary>
        public string ExactLabel => Synonym ? L("Gesucht war:") : L("Genau:");

        /// <summary>A tolerated (not exact) correct answer shows the exact answer under ExactLabel.</summary>
        public bool ShowsExact => Result is { } r && IsCorrect && !r.Exact && r.ExpectedDisplay.Length > 0;

        /// <summary>The note chips of a correct answer; synonyms use the accent tone, the rest a warning tone.</summary>
        public IReadOnlyList<NoteLabel> Notes =>
            IsCorrect && Result is { } r
                ? r.Notes.Where(Labels.NOTE_LABELS.ContainsKey).Select(n => new NoteLabel(n, Labels.NOTE_LABELS[n])).ToList()
                : [];

        /// <summary>The hint chip of a miss ("Falscher Artikel", …).</summary>
        public string? HintLabel => Result?.Hint is { } h ? Labels.HINT_LABELS.GetValueOrDefault(h) : null;

        /// <summary>Whether the hint chip is shown (not once an edit made the answer correct).</summary>
        public bool ShowsHint => HintLabel is not null && !EditedCorrect;

        /// <summary>The typed answer is shown under "Deine Antwort" (with AnswerDiff).</summary>
        public bool ShowsGiven => Given.Length > 0 && !DontKnow;

        /// <summary>"Ich hatte recht" is offered (Ctrl+Enter).</summary>
        public bool CanOverride => !DontKnow && HasText(Given);

        /// <summary>"Als richtig zählen" after an edit made the answer correct, else "Ich hatte recht".</summary>
        public string OverrideLabel => EditedCorrect ? L("Als richtig zählen") : L("Ich hatte recht");

        /// <summary>The note under the answers after such an edit.</summary>
        public string? EditedNote => EditedCorrect ? L("Mit deiner Korrektur stimmt deine Antwort jetzt.") : null;
    }

    /// <summary>A note chip after a correct answer.</summary>
    public sealed record NoteLabel(GradeNote Note, string Label)
    {
        /// <summary>Synonym notes are shown in the accent tone, others as a warning.</summary>
        public bool IsSynonym => Note is GradeNote.Synonym or GradeNote.ExtendedSynonym;
    }

    /// <summary>The pending auto-advance after a correct answer. A timer whose token does not match is stale and ignored.</summary>
    public sealed record AutoAdvance(int Token, int Ms);

    /// <summary>
    /// The results of a finished session. RetryCardIds: the missed cards that still exist ("Falsche nochmal üben";
    /// empty hides the button). CardCount: distinct cards; BothDirections: the session asked both directions.
    /// </summary>
    public sealed record Results(WriteSession.FinalStats Stats, IReadOnlyList<string> RetryCardIds, int CardCount, bool BothDirections)
    {
        public bool CanRetry => RetryCardIds.Count > 0;
    }

    /// <summary>The direction, order and copy settings when the options sheet opened.</summary>
    public sealed record OptionsBaseline(AnswerWith AnswerWith, bool Shuffle, bool CopyAnswer)
    {
        internal OptionsBaseline(StudyOptions options) : this(options.AnswerWith, options.Shuffle, options.CopyAnswer) { }
    }

    /// <summary>A sheet the view shows on top of the study card. Keys are ignored while one is open.</summary>
    public abstract record Overlay
    {
        /// <summary>
        /// "Karte bearbeiten" for the question's card; Focus is the side the learner had to type. Answer with
        /// Event.EditCard (save, closes it) or Event.OverlayDismissed (cancel).
        /// </summary>
        public sealed record Editor(SessionQuestion Question, AskSide Focus, bool ResumesTimer) : Overlay;
        /// <summary>The options sheet; changes arrive as Event.OptionsChanged, closing with Event.OverlayDismissed.</summary>
        public sealed record Options(OptionsBaseline Before, bool ResumesTimer) : Overlay;
    }

    /// <summary>A yes/no question the view shows as an alert. Answer with Event.PromptAnswered.</summary>
    public abstract partial record Prompt
    {
        /// <summary>"Neu starten?" (sidebar button, menu or the options sheet's "Neu starten").</summary>
        public sealed record Restart(bool ResumesTimer) : Prompt;
        /// <summary>The direction or order changed in the options and differs from the running session.</summary>
        public sealed record RestartForOptions(bool DirectionChanged, bool ResumesTimer, bool CopyChanged) : Prompt;
        /// <summary>A subset was requested while an answered round of another subset is stored.</summary>
        public sealed record ReplaceRound(StudySubset Wanted, SessionState Saved, PendingFeedback? Feedback) : Prompt;
    }

    /// <summary>A toast the app shows.</summary>
    public enum Toast
    {
        /// <summary>"Willkommen zurück – weiter geht's" after resuming a session with answers.</summary>
        WelcomeBack,
        /// <summary>"Als richtig gezählt" after "Ich hatte recht".</summary>
        CountedAsCorrect,
        /// <summary>"Karte gespeichert" after an edit.</summary>
        CardSaved,
    }

    /// <summary>What Event.Speak reads aloud: the prompt ("Vorlesen", Ctrl+R) or the expected answer ("Antwort vorlesen").</summary>
    public enum SpeechTarget { Prompt, Answer }

    // MARK: - State

    /// <summary>Everything the Write screen renders. Change it only through Reduce.</summary>
    public sealed class State
    {
        public Phase Phase { get; internal set; }
        /// <summary>The set being studied; null when it does not exist.</summary>
        public VocabSet? Set { get; internal set; }
        public StudyOptions Options { get; internal set; }
        public SessionState? Session { get; internal set; }
        /// <summary>The question on the card: the current one, or the answered one during feedback.</summary>
        public Question? Question { get; internal set; }
        /// <summary>The outcome of the answered question (feedback and copy step).</summary>
        public Feedback? Feedback { get; internal set; }
        /// <summary>The open miss, persisted with the session so a relaunch shows it again.</summary>
        public PendingFeedback? Pending { get; internal set; }
        /// <summary>The answer field (question) or the copy field (copy step); Event.InputChanged updates it.</summary>
        public string Input { get; internal set; } = "";
        /// <summary>The copy field holds a rejected attempt (cleared by typing).</summary>
        public bool InputInvalid { get; internal set; }
        /// <summary>Bumps when an empty answer or a wrong copy is rejected (drives the shake).</summary>
        public int Rejections { get; internal set; }
        /// <summary>Bumps for every new question (drives the prompt transition).</summary>
        public int QuestionSerial { get; internal set; }
        /// <summary>The new question replaces another one on the card (animate the swap).</summary>
        public bool AnimatesQuestion { get; internal set; }
        /// <summary>Bumps after a sheet or alert closed: move focus back to the primary control.</summary>
        public int FocusSerial { get; internal set; }
        public WriteSession.RoundSummary? Summary { get; internal set; }
        public Results? Results { get; internal set; }
        /// <summary>The subset that turned out empty (Empty).</summary>
        public StudySubset? EmptySubset { get; internal set; }
        /// <summary>The running auto-advance after a correct answer (drives the countdown bar).</summary>
        public AutoAdvance? AutoAdvance { get; internal set; }
        public Overlay? Overlay { get; internal set; }
        public Prompt? Prompt { get; internal set; }
        /// <summary>Return-family keys are ignored before this time (epoch ms).</summary>
        public double LockUntil { get; internal set; }
        /// <summary>«Später» on «Neu starten?» for changed options: the session goes on with its own settings (Windows only).</summary>
        public KeptOptions? Kept { get; internal set; }
        internal string LastPraise { get; set; } = "";
        internal int NextToken { get; set; }

        internal State(VocabSet? set, StudyOptions options)
        {
            Phase = set is null ? Phase.Missing : Phase.Starting;
            Set = set;
            Options = options;
        }

        internal State Clone() => (State)MemberwiseClone();

        /// <summary>The answer or copy field accepts typing.</summary>
        public bool IsInputEditable => Phase == Phase.Question || Phase == Phase.Copy;

        /// <summary>A sheet or alert is open; keys go to it, not to the flow.</summary>
        public bool IsBlocked => Overlay is not null || Prompt is not null;

        /// <summary>The startedAt of the shown session. Pass it back as resultsMarker to Start to show a finished session's results again.</summary>
        public double? ResultsMarker => Session?.StartedAt;
    }

    // MARK: - Events and effects

    public abstract record Event
    {
        /// <summary>
        /// A key press; IsRepeat for auto-repeat while held (never transitions). The answer field keeps its own typing;
        /// forward Return-family keys, Escape and (in the correct phase) printable keys.
        /// </summary>
        public sealed record Key(KeyInput Input, bool IsRepeat = false) : Event;
        /// <summary>The answer or copy field changed.</summary>
        public sealed record InputChanged(string Text) : Event;
        /// <summary>"Antworten" (question) or "Weiter" of the copy step, with the field's text.</summary>
        public sealed record Submit(string Text) : Event;
        /// <summary>"Weiss ich nicht".</summary>
        public sealed record DontKnow : Event;
        /// <summary>The primary button of the current step was clicked.</summary>
        public sealed record Proceed : Event;
        /// <summary>"Ich hatte recht" / "Als richtig zählen".</summary>
        public sealed record Override : Event;
        /// <summary>A timer from Effect.ScheduleAutoAdvance fired.</summary>
        public sealed record AutoAdvanceFired(int Token) : Event;
        /// <summary>The star of the question's card.</summary>
        public sealed record ToggleStar : Event;
        /// <summary>The speaker buttons ("Vorlesen" Ctrl+R, "Antwort vorlesen").</summary>
        public sealed record Speak(SpeechTarget Target) : Event;
        /// <summary>"Bearbeiten" (Ctrl+E): opens Overlay.Editor for the question's card.</summary>
        public sealed record RequestEdit : Event;
        /// <summary>The editor saved the card (its Term and Definition); closes the editor.</summary>
        public sealed record EditCard(Card Card) : Event;
        /// <summary>"Optionen" (Ctrl+K): opens Overlay.Options.</summary>
        public sealed record RequestOptions : Event;
        /// <summary>The study options changed (live from the options sheet, or anywhere else).</summary>
        public sealed record OptionsChanged(StudyOptions Options) : Event;
        /// <summary>The open sheet closed; RestartRequested when the options sheet's "Neu starten" was used.</summary>
        public sealed record OverlayDismissed(bool RestartRequested = false) : Event;
        /// <summary>The open alert was answered.</summary>
        public sealed record PromptAnswered(bool Confirmed) : Event;
        /// <summary>"Neu starten" (asks first) or, on the results screen, "Nochmal von vorne" (Ctrl+Shift+R).</summary>
        public sealed record Restart : Event;
        /// <summary>"Falsche nochmal üben" on the results screen.</summary>
        public sealed record RetryMissed : Event;
        /// <summary>"Alle Begriffe üben" on the empty screen.</summary>
        public sealed record PracticeAll : Event;
        /// <summary>"Zurück zum Lernset".</summary>
        public sealed record Leave : Event;
        /// <summary>The set changed outside the flow (another window, the editor, a deletion of cards).</summary>
        public sealed record SetChanged(VocabSet Set) : Event;
        /// <summary>Only the cards changed outside the flow.</summary>
        public sealed record CardsChanged(IReadOnlyList<Card> Cards) : Event;
        /// <summary>The set was deleted.</summary>
        public sealed record SetDeleted : Event;
        /// <summary>The periodic study clock (every ClockTickMs while visible and active, and once when the screen goes away).</summary>
        public sealed record ClockTick : Event;
        /// <summary>Study time counts again from now (after the window was hidden or idle).</summary>
        public sealed record ClockResumed : Event;

        /// <summary>Event.Key for a KeyPress of the view layer.</summary>
        public static Event KeyOf(KeyPress press) => new Key(press.Key, press.IsRepeat);
    }

    public abstract record Effect
    {
        /// <summary>LibraryStore.RecordAnswer(setId, cardId, correct, at).</summary>
        public sealed record RecordAnswer(string CardId, bool Correct, double At) : Effect;
        /// <summary>LibraryStore.OverrideLastAnswer(setId, cardId).</summary>
        public sealed record OverrideLastAnswer(string CardId) : Effect;
        /// <summary>Persist the session with the open miss: LibraryStore.SaveSessionJSON(setId, StoredJSON(session, feedback)). At most one per event.</summary>
        public sealed record SaveSession(SessionState Session, PendingFeedback? Feedback) : Effect;
        /// <summary>Read text aloud in lang (cancelling anything still speaking).</summary>
        public sealed record Speak(string Text, Lang Lang) : Effect;
        public sealed record Haptic(HapticKind Kind) : Effect;
        /// <summary>Send Event.AutoAdvanceFired(token) after ms milliseconds.</summary>
        public sealed record ScheduleAutoAdvance(int Ms, int Token) : Effect;
        /// <summary>A screen-reader announcement. At most one per event (the latest).</summary>
        public sealed record Announce(string Text) : Effect;
        /// <summary>LibraryStore.UpdateCard(setId, card.Id, new CardChanges(term, definition)).</summary>
        public sealed record UpdateCard(Card Card) : Effect;
        /// <summary>LibraryStore.ToggleStar(setId, cardId).</summary>
        public sealed record ToggleStar(string CardId) : Effect;
        public sealed record ShowToast(Toast Toast) : Effect;
        /// <summary>Open the set editor ("Begriffe hinzufügen").</summary>
        public sealed record EditSet : Effect;
        /// <summary>Leave Write mode: back to the set, or to the overview when the set is gone.</summary>
        public sealed record Exit : Effect;
        /// <summary>«Später» on «Neu starten?»: store it for the set on this device (Start's kept). Windows only.</summary>
        public sealed record KeepOptions(KeptOptions Kept) : Effect;
    }

    /// <summary>
    /// The world the reducer reads: time, randomness and the set's current progress (read when a session is
    /// created for the "Nicht gemeistert" / "Falsch beantwortet" subsets). ExtraAnswers: words with the same
    /// meaning that are not in the set (the app: AppModel.ExtraAnswers, from the built-in thesauri).
    /// </summary>
    public sealed class Env
    {
        public double Now { get; set; }
        public RNG Rng { get; set; }
        public IReadOnlyDictionary<string, CardProgress> Progress { get; set; }
        public Func<SynonymQuery, IReadOnlyList<string>> ExtraAnswers { get; set; }

        public Env(double? now = null, RNG? rng = null, IReadOnlyDictionary<string, CardProgress>? progress = null,
            Func<SynonymQuery, IReadOnlyList<string>>? extraAnswers = null)
        {
            Now = now ?? TimeUtil.NowMs();
            Rng = rng ?? Rand.SystemRNG();
            Progress = progress ?? new Dictionary<string, CardProgress>();
            ExtraAnswers = extraAnswers ?? (_ => []);
        }
    }

    // MARK: - API

    /// <summary>
    /// Opens Write mode for set (null: the set does not exist). A stored session (saved, with the open miss
    /// savedFeedback) is resumed unless forceNew, it is finished, or another named subset was requested. A
    /// requested subset that would drop an answered round asks first (Prompt.ReplaceRound). A finished session
    /// is shown again when resultsMarker is its startedAt (State.ResultsMarker). A direction or «Mischen» changed since the
    /// session started asks «Neu starten?» unless <paramref name="kept"/> says «Später» was answered for it (Windows, issue #7).
    /// </summary>
    public static (State State, List<Effect> Effects) Start(VocabSet? set, StudyOptions options, SessionState? saved, Env env,
        PendingFeedback? savedFeedback = null, StudySubset? subset = null, bool forceNew = false, double? resultsMarker = null,
        KeptOptions? kept = null)
    {
        var m = new Machine(new State(set, options) { Kept = kept }, env);
        if (set is not null) m.Boot(saved, savedFeedback, subset, forceNew, resultsMarker);
        return m.Finish();
    }

    /// <summary>Start with the stored JSON of LibraryStore.GetSessionJSON (session plus feedback).</summary>
    public static (State State, List<Effect> Effects) Start(VocabSet? set, StudyOptions options, JSONValue? stored, Env env,
        StudySubset? subset = null, bool forceNew = false, double? resultsMarker = null, KeptOptions? kept = null)
    {
        var decoded = DecodeStored(stored);
        return Start(set, options, decoded?.Session, env, decoded?.Feedback, subset, forceNew, resultsMarker, kept);
    }

    /// <summary>Applies one event.</summary>
    public static (State State, List<Effect> Effects) Reduce(State state, Event e, Env env)
    {
        // Typing is by far the most frequent event: keep it cheap.
        if (e is Event.InputChanged changed)
        {
            if (!state.IsInputEditable) return (state, []);
            var s = state.Clone();
            s.Input = changed.Text;
            s.InputInvalid = false;
            // The copy typed out continues by itself after a short beat, like Enter (CopyStep).
            if (s.Phase != Phase.Copy) return (s, []);
            var copy = new Machine(s, env);
            copy.ContinueTypedOutCopy();
            return copy.Finish();
        }
        var m = new Machine(state, env);
        m.Handle(e);
        return m.Finish();
    }

    /// <summary>The label of what Return does now (for the ↵ hint); null when Return does nothing here.</summary>
    public static string? ReturnAction(State state)
    {
        if (state.IsBlocked) return null;
        return state.Phase.Kind switch
        {
            PhaseKind.Starting => null,
            PhaseKind.Question => L("Antworten"),
            PhaseKind.Feedback or PhaseKind.Copy => L("Weiter"),
            PhaseKind.Summary => L($"Weiter zu Runde {(state.Summary?.Round ?? state.Session?.Round ?? 1) + 1}"),
            PhaseKind.Results => state.Results?.CanRetry == true ? L("Falsche nochmal üben") : L("Fertig"),
            PhaseKind.Empty => EmptyMessage(state.EmptySubset ?? StudySubset.All).PrimaryLabel,
            _ => MissingMessage.PrimaryLabel,
        };
    }

    /// <summary>The text next to the ↵ key hint on the card ("zum Antworten", …); null where the button label says it all.</summary>
    public static string? ReturnHint(State state)
    {
        if (state.IsBlocked) return null;
        if (state.Phase == Phase.Question) return L("zum Antworten");
        if (state.Phase == Phase.FeedbackOf(FeedbackKind.Correct)) return state.AutoAdvance is not null ? L("Weiter mit beliebiger Taste") : L("zum Weitermachen");
        if (state.Phase == Phase.Copy) return L("zum Prüfen");
        return null;
    }

    /// <summary>Whether study time counts now (write.js <c>studying</c>): a running session on the card or the round summary.</summary>
    public static bool IsStudying(State state) =>
        state.Session is { FinishedAt: null } && (state.Phase.IsCard || state.Phase == Phase.Summary);

    /// <summary>"Verbleibend / Falsch / Richtig" and the round of the sidebar.</summary>
    public static WriteSession.Counters? CountersOf(State state) => state.Session is { } s ? WriteSession.CountersOf(s) : null;

    /// <summary>The card the editor edits (Overlay.Editor).</summary>
    public static Card? EditorCard(State state) =>
        state.Overlay is Overlay.Editor editor ? state.Set?.Cards.FirstOrDefault(c => c.Id == editor.Question.CardId) : null;
}

/// <summary>Swift <c>WriteFlow.Toast</c> properties (C# enums cannot have members).</summary>
public static class WriteFlowToastExtensions
{
    public static string Message(this WriteFlow.Toast toast) => toast switch
    {
        WriteFlow.Toast.WelcomeBack => L("Willkommen zurück – weiter geht's"),
        WriteFlow.Toast.CountedAsCorrect => L("Als richtig gezählt"),
        _ => L("Karte gespeichert"),
    };

    /// <summary>Success tone (green) instead of the neutral one.</summary>
    public static bool IsSuccess(this WriteFlow.Toast toast) => toast != WriteFlow.Toast.WelcomeBack;

    /// <summary>Display time; null means the app's default.</summary>
    public static int? DurationMs(this WriteFlow.Toast toast) => toast switch
    {
        WriteFlow.Toast.WelcomeBack => null,
        WriteFlow.Toast.CountedAsCorrect => 2000,
        _ => 2200,
    };

    /// <summary>The icon name (Mac: SF Symbol; the Windows app maps it to its own icons).</summary>
    public static string SystemImage(this WriteFlow.Toast toast) => toast == WriteFlow.Toast.WelcomeBack ? "sparkles" : "checkmark.circle.fill";
}
