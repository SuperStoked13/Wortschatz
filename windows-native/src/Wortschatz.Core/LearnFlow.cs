using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of LearnFlow.swift: the Learn screen as a pure reducer (spec §6), a port of the screen logic of
// the web app's Learn mode (src/screens/learn.js, learn-answer.js, learn-dialogs.js, learn-keys.js and
// the decisions in learn-mc.js / learn-views.js) on top of LearnEngine. The Avalonia view renders State
// and forwards user input as Events; every side effect (store writes, speech, sounds, screen reader,
// timers, navigation) comes back as an Effect for the app to perform.
//
// Keys (spec §4.3, Windows names; the Mac's in brackets):
// - Multiple choice: ↑↓←→ move the highlight (none at first, the first arrow lands on option 1), Enter
//   chooses the highlighted option, 1–4 choose directly, 0 or Alt+Enter (⌥↩) = "Weiss ich nicht". Typing
//   letters highlights the one option they start ("la vo" → la voiture, TypeAheadOf); Backspace deletes a
//   letter (held: one after another), Ctrl+Backspace (⌥⌫) a word, Esc clears them.
// - Written: Enter submits the answer field (Draft), Alt+Enter = "Weiss ich nicht".
// - Feedback: Enter = Weiter (a correct answer also advances by itself); after multiple choice any key
//   continues, after a correct written answer any key continues and starts typing the next written answer.
//   Ctrl+Enter (⌘↩) = "Ich hatte recht" after a written miss.
// - Copy step (Abtippen, learn.retype): Enter checks the copy field and continues when right; typed out it continues
//   by itself after a short beat (CopyStep).
// - Checkpoint: Enter = Weiter zu Runde N. Finish: Enter = Fertig. Esc leaves (back to the set).
// One key press causes at most one transition: repeats never transition, and presses within
// INPUT_LOCK_MS after a transition are swallowed.
//
// C# shapes as in WriteFlow (see PORTING.md): Phase is a record struct, Prompt/Event/Effect are abstract
// records with one nested record per Swift case, State is a class the Machine clones.

public static partial class LearnFlow
{
    // MARK: - State

    public enum FeedbackKind { Correct, Wrong, DontKnow }

    public enum PhaseKind
    {
        /// <summary>A question: multiple choice tiles or the written answer field.</summary>
        Question,
        /// <summary>The answer's feedback (praise with auto-advance, or "Nicht ganz" / "Kein Problem").</summary>
        Feedback,
        /// <summary>A written miss with the copy step on: the right answer has to be typed once.</summary>
        Copy,
        /// <summary>"Runde N geschafft" after each round.</summary>
        Checkpoint,
        /// <summary>Every card in scope is mastered: celebration and stats.</summary>
        Finished,
        /// <summary>Everything in scope was already mastered at the start.</summary>
        AllMastered,
        /// <summary>Nothing to study (no usable cards, or none in the requested subset).</summary>
        Empty,
    }

    /// <summary>What the screen shows (Swift enum with values: QuestionType for Question, FeedbackKind for Feedback).</summary>
    public readonly record struct Phase(PhaseKind Kind, QuestionType QuestionType = QuestionType.Mc, FeedbackKind FeedbackKind = FeedbackKind.Correct)
    {
        public static Phase QuestionOf(QuestionType type) => new(PhaseKind.Question, QuestionType: type);
        public static Phase FeedbackOf(FeedbackKind kind) => new(PhaseKind.Feedback, FeedbackKind: kind);
        public static readonly Phase Mc = QuestionOf(QuestionType.Mc);
        public static readonly Phase Written = QuestionOf(QuestionType.Written);
        public static readonly Phase Copy = new(PhaseKind.Copy);
        public static readonly Phase Checkpoint = new(PhaseKind.Checkpoint);
        public static readonly Phase Finished = new(PhaseKind.Finished);
        public static readonly Phase AllMastered = new(PhaseKind.AllMastered);
        public static readonly Phase Empty = new(PhaseKind.Empty);

        public bool IsQuestion => Kind == PhaseKind.Question;
        public bool IsFeedback => Kind == PhaseKind.Feedback;

        public override string ToString() => Kind switch
        {
            PhaseKind.Question => $"question({QuestionType})",
            PhaseKind.Feedback => $"feedback({FeedbackKind})",
            _ => Kind.ToString(),
        };
    }

    /// <summary>
    /// The question on screen (<c>questionInfo</c> plus the options). Choices: the options on screen (texts from the
    /// current cards; [] for written); StoredChoices: the options as stored in the session; IsReview: a repetition
    /// question (Wiederholungsfrage) of a card mastered before the session; IsRecheck: a recheck (Nachkontrolle) of a card
    /// missed and then mastered in the session.
    /// </summary>
    public sealed record QuestionInfo(string Qid, string CardId, QuestionType Type, AskSide Ask, string Prompt, string Expected,
        Lang PromptLang, Lang AnswerLang, string PromptLabel, string Placeholder, string PlaceholderShort, bool Starred,
        IReadOnlyList<Choice> Choices, IReadOnlyList<Choice> StoredChoices, bool IsReview = false, bool IsRecheck = false)
    {
        /// <summary>The question for the synonym check (ExtendedSynonyms).</summary>
        public SynonymQuery SynonymQuery => new(Prompt, Expected, PromptLang, AnswerLang);
    }

    /// <summary>
    /// The result of the last answer, as the feedback shows it. Title: praise ("Super!"), "Auch richtig!", "Richtig!",
    /// MISS_TITLE or DONT_KNOW_TITLE. Multiple choice: CorrectIndex and ChosenIndex (null = "Weiss ich nicht").
    /// Written: Given (trimmed; "" for "Weiss ich nicht") and its Result (null for "Weiss ich nicht"); show "Deine
    /// Antwort" with Grading.DiffAnswer(given, expected). ExactLabel: "Genau:" / "Gesucht war:" before
    /// Result.ExpectedDisplay for a correct but not exact answer. Hint: the hint chip after a written miss.
    /// CanOverride: "Ich hatte recht" is offered. EditedCorrect: the edited card now accepts what was typed.
    /// Copy: the copy step is on for this miss. AutoAdvanceMs: the countdown of a correct answer. Demoted: a
    /// repetition question was missed (the card is learned again, "Wieder am Lernen").
    /// </summary>
    public sealed record Feedback(FeedbackKind Kind, string Title = "", int? CorrectIndex = null, int? ChosenIndex = null, string Given = "",
        GradeResult? Result = null, bool Synonym = false, string? ExactLabel = null, string? Hint = null, bool CanOverride = false,
        bool EditedCorrect = false, bool Copy = false, int? AutoAdvanceMs = null, bool Demoted = false);

    /// <summary>
    /// The open "Nicht ganz" screen, stored next to the Learn state (web: <c>feedback</c>) so that a relaunch shows it
    /// again. JSON as in the web app: multiple choice {qid, cardId, type: "mc", ask, choices, chosen} (chosen = card id
    /// or null for "Weiss ich nicht"), written {qid, cardId, type: "written", ask, given, dontKnow}.
    /// </summary>
    public sealed record PendingFeedback(string Qid, string CardId, QuestionType Type, AskSide Ask, IReadOnlyList<Choice>? Choices = null,
        string? Chosen = null, string? Given = null, bool? DontKnow = null) : IJsonEncodable
    {
        public static PendingFeedback Mc(string qid, string cardId, AskSide ask, IReadOnlyList<Choice> choices, string? chosen) =>
            new(qid, cardId, QuestionType.Mc, ask, choices, chosen);

        public static PendingFeedback Written(string qid, string cardId, AskSide ask, string given, bool dontKnow) =>
            new(qid, cardId, QuestionType.Written, ask, Given: given, DontKnow: dontKnow);

        public JSONValue ToJson()
        {
            var map = new JsonObjectMap { ["qid"] = Qid, ["cardId"] = CardId, ["type"] = Type.ToJson(), ["ask"] = Ask.ToJson() };
            if (Type == QuestionType.Mc)
            {
                map["choices"] = (Choices ?? []).ToJsonArray();
                map["chosen"] = Chosen is null ? JSONValue.Null : Chosen;
            }
            else
            {
                map["given"] = Given ?? "";
                map["dontKnow"] = DontKnow ?? false;
            }
            return JSONValue.Object(map);
        }

        public bool Equals(PendingFeedback? o) =>
            o is not null && Qid == o.Qid && CardId == o.CardId && Type == o.Type && Ask == o.Ask && Chosen == o.Chosen && Given == o.Given
            && DontKnow == o.DontKnow && (Choices ?? []).SequenceEqual(o.Choices ?? []);

        public override int GetHashCode() => HashCode.Combine(Qid, CardId, Type, Ask);
    }

    /// <summary>A stored Learn session as the store keeps it (<c>learn:&lt;setId&gt;</c>): the state plus the raw feedback record of an open "Nicht ganz" screen.</summary>
    public sealed record SavedLearn(LearnState State, JSONValue? Feedback)
    {
        public SavedLearn(LearnState state, PendingFeedback? feedback = null) : this(state, feedback?.ToJson()) { }

        /// <summary>A stored JSON object (repaired with LearnEngine.CopyState); null for anything else.</summary>
        public static SavedLearn? FromJson(JSONValue? json) => json is { IsObject: true } ? new SavedLearn(LearnEngine.CopyState(json), json["feedback"]) : null;

        /// <summary>The JSON to store (LibraryStore.SaveLearnJSON): the state with feedback next to it.</summary>
        public JSONValue ToJson()
        {
            var json = State.ToJson();
            if (Feedback is null || Feedback.IsNull) return json;
            var o = new JsonObjectMap();
            foreach (var (k, v) in json.ObjectValue!) o[k] = v;
            o["feedback"] = Feedback;
            return JSONValue.Object(o);
        }

        /// <summary>
        /// The stored session after «Wiederholungsfragen» (review) or «Nachkontrolle nach Fehlern» (recheck) was switched
        /// (null: not switched): they apply at once to every unfinished session (LearnEngine.SetReview/SetRecheck). Null
        /// when nothing changes.
        /// </summary>
        public SavedLearn? Switching(bool? review = null, bool? recheck = null, IReadOnlyDictionary<string, CardProgress>? progress = null, double? now = null)
        {
            var next = State;
            if (review is { } r) next = LearnEngine.SetReview(next, r, progress, now);
            if (recheck is { } c) next = LearnEngine.SetRecheck(next, c, now);
            return ReferenceEquals(next, State) ? null : this with { State = next };
        }
    }

    /// <summary>A confirmation the view shows as an alert (PromptContentOf). Keys are ignored while it is open; answer with Event.PromptAnswered.</summary>
    public abstract record Prompt
    {
        /// <summary>"Neu starten?" (Ctrl+Shift+R in a running session).</summary>
        public sealed record RestartSession : Prompt;
        /// <summary>Options that only apply to a new session were changed.</summary>
        public sealed record RestartForOptions(IReadOnlyList<SettingsChange> Changes) : Prompt
        {
            public bool Equals(RestartForOptions? o) => o is not null && Changes.SequenceEqual(o.Changes);
            public override int GetHashCode() => Changes.Count;
        }
        /// <summary>"Fortschritt zurücksetzen?" before learning these cards again.</summary>
        public sealed record Relearn(IReadOnlyList<string> CardIds) : Prompt
        {
            public bool Equals(Relearn? o) => o is not null && CardIds.SequenceEqual(o.CardIds);
            public override int GetHashCode() => CardIds.Count;
        }
        /// <summary>"Laufende Lerneinheit beenden?" when another subset was asked for.</summary>
        public sealed record ReplaceSession(StudySubset Wanted) : Prompt;
    }

    /// <summary>Title, message and buttons of a prompt. IsDestructive: the cancel button is the default.</summary>
    public sealed record PromptContent(string Title, string Message, string ConfirmLabel, string CancelLabel, bool IsDestructive);

    /// <summary>A sheet or popover over the screen; keys are ignored and the auto-advance pauses while it is open.</summary>
    public enum Overlay
    {
        /// <summary>The Learn options; on dismissal a change that needs a new session asks to restart.</summary>
        Options,
        /// <summary>The card editor (Ctrl+E).</summary>
        Editor,
        Other,
    }

    /// <summary>Where the app should go.</summary>
    public enum Destination
    {
        /// <summary>Back to the set (Esc, "Fertig", "Zurück zum Lernset").</summary>
        Set,
        /// <summary>Write mode with a new session ("Schreiben üben").</summary>
        Write,
        /// <summary>The set editor ("Begriffe hinzufügen").</summary>
        EditSet,
    }

    /// <summary>How a multiple-choice option is drawn. Filtered: the letters typed do not start it.</summary>
    public enum OptionState { Idle, Highlighted, Filtered, Correct, Wrong, Dimmed }

    /// <summary>Everything the Learn screen renders.</summary>
    public sealed class State
    {
        public Phase Phase { get; set; }
        /// <summary>The engine state; null while no session runs (Empty, AllMastered).</summary>
        public LearnState? Session { get; set; }
        public string SetId { get; set; }
        public string SetTitle { get; set; }
        public Lang TermLang { get; set; }
        public Lang DefLang { get; set; }
        /// <summary>The set's current cards.</summary>
        public List<Card> Cards { get; set; }
        /// <summary>The study options in effect (tolerance, audio and the copy step apply at once).</summary>
        public StudyOptions Options { get; set; }
        /// <summary>
        /// Sessions ask repetition questions (Wiederholungsfragen, LearnReview). Switched (Event.ReviewChanged, also in the
        /// options), it applies to the running session at once; a resumed session keeps its own (it may have been started for them).
        /// </summary>
        public bool Review { get; set; }
        /// <summary>
        /// Sessions have rechecks (Nachkontrolle, LearnRecheck). Switched (Event.RecheckChanged, also in the options), it
        /// applies to the running session at once, and a resumed session follows it.
        /// </summary>
        public bool Recheck { get; set; }
        /// <summary>The scope (the session's subset, or the requested one on the message screens).</summary>
        public StudySubset Subset { get; set; }
        /// <summary>AllMastered: the scope's cards (reset by "Fortschritt zurücksetzen und neu lernen").</summary>
        public List<string> ScopeCardIds { get; set; } = [];
        public QuestionInfo? Question { get; set; }
        public Feedback? Feedback { get; set; }
        /// <summary>The highlighted multiple-choice option (0-based), null = none.</summary>
        public int? Highlighted { get; set; }
        /// <summary>The letters typed on a multiple-choice question (TypeAheadOf), "" = none.</summary>
        public string Typed { get; set; } = "";
        /// <summary>The answer field (written question) or the copy field (copy step).</summary>
        public string Draft { get; set; } = "";
        /// <summary>The open "Nicht ganz" record stored next to the session.</summary>
        public PendingFeedback? Pending { get; set; }
        /// <summary>Counts when the round started: the checkpoint bar grows from there (null: no animation).</summary>
        public LearnEngine.Counts? RoundStartCounts { get; set; }
        public Prompt? Prompt { get; set; }
        public Overlay? Overlay { get; set; }
        public StudyOptions? OptionsBeforeOverlay { get; set; }
        /// <summary>The running auto-advance timer (Effect.ScheduleAutoAdvance), null = none.</summary>
        public int? AutoAdvanceToken { get; set; }
        public int LastToken { get; set; }
        /// <summary>An overlay or prompt interrupted the auto-advance; it restarts when they close.</summary>
        public bool AutoAdvancePaused { get; set; }
        public string? LastPraise { get; set; }
        /// <summary>Key presses before this time (epoch ms) are swallowed.</summary>
        public double InputLockedUntil { get; set; }
        /// <summary>Increases when an empty answer or a wrong copy is rejected (shake trigger).</summary>
        public int Rejections { get; set; }
        /// <summary>Increases with every transition (new question, feedback, checkpoint, finish, message).</summary>
        public int Transitions { get; set; }
        /// <summary>«Später» on «Neu starten?» for changed options: the session goes on with its own settings (Windows only).</summary>
        public KeptOptions? Kept { get; set; }

        public State(Phase phase, LearnState? session, string setId, string setTitle, Lang termLang, Lang defLang, IEnumerable<Card> cards,
            StudyOptions options, StudySubset subset, bool review = false, bool recheck = false)
        {
            Phase = phase;
            Session = session;
            SetId = setId;
            SetTitle = setTitle;
            TermLang = termLang;
            DefLang = defLang;
            Cards = cards.ToList();
            Options = options;
            Subset = subset;
            Review = review;
            Recheck = recheck;
        }

        /// <summary>A copy for the next reduction (lists copied; records are immutable).</summary>
        public State Clone()
        {
            var c = (State)MemberwiseClone();
            c.Cards = [.. Cards];
            c.ScopeCardIds = [.. ScopeCardIds];
            return c;
        }

        /// <summary>Neu · Am Lernen · Gemeistert of the session (zeros without one).</summary>
        public LearnEngine.Counts Counts => Session is { } s ? LearnEngine.CountsOf(s) : new LearnEngine.Counts(0, 0, 0, 0, 0);

        /// <summary>The round on screen ("Runde N").</summary>
        public int Round => Session?.Round ?? 1;

        /// <summary>The checkpoint of the current round.</summary>
        public LearnEngine.Checkpoint? Checkpoint => Session is { } s ? LearnEngine.CheckpointOf(s) : null;

        /// <summary>The final statistics (finish screen).</summary>
        public LearnEngine.FinalStats? FinalStats => Session is { } s ? LearnEngine.FinalStatsOf(s) : null;

        /// <summary>Segments of the progress bar.</summary>
        public int Segments => SegmentCount(Counts.Total, Session?.Learn.RoundSize);

        /// <summary>Whether study time counts now (send Event.Tick periodically and on leaving).</summary>
        public bool IsStudying =>
            Session is { FinishedAt: null } && Phase.Kind is PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy or PhaseKind.Checkpoint;

        /// <summary>A question or its feedback is on screen.</summary>
        public bool IsStudyStep => Phase.Kind is PhaseKind.Question or PhaseKind.Feedback or PhaseKind.Copy;

        /// <summary>"Multiple Choice first, written next time" (until dismissed or the first checkpoint): only while both question types are on.</summary>
        public bool ShowsIntroHint
        {
            get
            {
                if (!Phase.IsQuestion || Session is not { } session) return false;
                // A session of repetition questions without new cards has nothing to introduce.
                if (session.Review is not null && Counts.Fresh == 0) return false;
                return session.Learn.Mc && session.Learn.Written && session.Rounds.Count == 0;
            }
        }
    }

    // MARK: - Events and effects

    public abstract record Event
    {
        /// <summary>A key press; repeats never cause a transition.</summary>
        public sealed record Key(KeyInput Input, bool IsRepeat = false) : Event;
        /// <summary>A click on option Index (0-based).</summary>
        public sealed record Choose(int Index) : Event;
        /// <summary>The pointer highlights an option (null = none).</summary>
        public sealed record Highlight(int? Index) : Event;
        /// <summary>The answer or copy field changed.</summary>
        public sealed record DraftChanged(string Text) : Event;
        /// <summary>Enter in the answer or copy field with its text (like Key(Return)).</summary>
        public sealed record Submit(string Text) : Event;
        /// <summary>"Weiss ich nicht?" was clicked.</summary>
        public sealed record DontKnow : Event;
        /// <summary>The screen's primary button was clicked (Weiter, Antworten, Fertig, …).</summary>
        public sealed record Proceed : Event;
        /// <summary>"Ich hatte recht" (Ctrl+Enter or its button).</summary>
        public sealed record Override : Event;
        /// <summary>Vorlesen (Ctrl+R): the prompt.</summary>
        public sealed record SpeakPrompt : Event;
        /// <summary>Markieren (Ctrl+D): star the card on screen.</summary>
        public sealed record ToggleStar : Event;
        /// <summary>The card editor saved this card (Ctrl+E, Bearbeiten).</summary>
        public sealed record EditCard(Card Card) : Event;
        /// <summary>The study options changed (options popover or settings).</summary>
        public sealed record OptionsChanged(StudyOptions Options) : Event;
        /// <summary>"Wiederholungsfragen" was switched (applies at once; see State.Review).</summary>
        public sealed record ReviewChanged(bool Review) : Event;
        /// <summary>"Nachkontrolle" was switched (applies at once; see State.Recheck).</summary>
        public sealed record RecheckChanged(bool Recheck) : Event;
        /// <summary>"Alle wiederholen" on the everything-mastered screen: a session of repetition questions over the scope.</summary>
        public sealed record StartReview : Event;
        /// <summary>The set changed elsewhere (title, languages, cards).</summary>
        public sealed record SetChanged(VocabSet Set) : Event;
        /// <summary>The set's cards changed elsewhere (edited, added, deleted).</summary>
        public sealed record CardsChanged(IReadOnlyList<Card> Cards) : Event;
        /// <summary>The stored progress changed elsewhere (Env.Progress), e.g. in Write mode.</summary>
        public sealed record ProgressChanged : Event;
        public sealed record OverlayPresented(Overlay Overlay) : Event;
        public sealed record OverlayDismissed : Event;
        public sealed record PromptAnswered(bool Confirmed) : Event;
        /// <summary>Neu starten (Ctrl+Shift+R): asks first; on the finish screen it is "Nochmal lernen".</summary>
        public sealed record Restart : Event;
        /// <summary>"Nochmal lernen" / "Fortschritt zurücksetzen und neu lernen" (asks first).</summary>
        public sealed record Relearn : Event;
        /// <summary>"Alle Begriffe üben" on the empty screen.</summary>
        public sealed record StudyAll : Event;
        /// <summary>A ScheduleAutoAdvance timer fired; stale tokens are ignored.</summary>
        public sealed record AutoAdvanceFired(int Token) : Event;
        /// <summary>Periodic clock tick while studying (the web app ticks every 15 s).</summary>
        public sealed record Tick : Event;
        /// <summary>The window is active again after a pause: the time away is not study time.</summary>
        public sealed record Resume : Event;
        /// <summary>Leave the screen (Esc, back button): saves the clock and navigates to the set.</summary>
        public sealed record Exit : Event;

        public static Event KeyOf(KeyPress press) => new Key(press.Key, press.IsRepeat);
    }

    public abstract record Effect
    {
        /// <summary>LibraryStore.RecordAnswer(setId, cardId, correct, at).</summary>
        public sealed record RecordAnswer(string CardId, bool Correct, double At) : Effect;
        /// <summary>LibraryStore.OverrideLastAnswer(setId, cardId).</summary>
        public sealed record OverrideLastAnswer(string CardId) : Effect;
        /// <summary>ResetProgress(setId) (null) or ResetCardProgress(setId, cardIds).</summary>
        public sealed record ResetProgress(IReadOnlyList<string>? CardIds) : Effect
        {
            public bool Equals(ResetProgress? o) => o is not null && (CardIds is null ? o.CardIds is null : o.CardIds is not null && CardIds.SequenceEqual(o.CardIds));
            public override int GetHashCode() => CardIds?.Count ?? -1;
        }
        /// <summary>Store the session: SaveLearnJSON(setId, new SavedLearn(state, feedback).ToJson()).</summary>
        public sealed record SaveLearn(LearnState State, PendingFeedback? Feedback) : Effect;
        public sealed record ClearLearn : Effect;
        public sealed record Speak(string Text, Lang Lang) : Effect;
        public sealed record Haptic(HapticKind Kind) : Effect;
        /// <summary>Send Event.AutoAdvanceFired(token) after ms milliseconds.</summary>
        public sealed record ScheduleAutoAdvance(int Ms, int Token) : Effect;
        /// <summary>A screen-reader announcement.</summary>
        public sealed record Announce(string Text) : Effect;
        public sealed record Toast(string Text, Tone Tone) : Effect;
        /// <summary>LibraryStore.UpdateCard with the edited card.</summary>
        public sealed record UpdateCard(Card Card) : Effect;
        /// <summary>LibraryStore.ToggleStar(setId, cardId).</summary>
        public sealed record ToggleStar(string CardId) : Effect;
        public sealed record Navigate(Destination Destination) : Effect;
        /// <summary>«Später» on «Neu starten?»: store it for the set on this device (Start's kept). Windows only.</summary>
        public sealed record KeepOptions(KeptOptions Kept) : Effect;
    }

    /// <summary>What a reduction may read besides the state: randomness, the time, the stored progress and synonyms found outside the set.</summary>
    public sealed class Env
    {
        public RNG Rng { get; set; }
        /// <summary>Epoch ms.</summary>
        public double Now { get; set; }
        /// <summary>The set's stored progress (after every effect applied so far).</summary>
        public IReadOnlyDictionary<string, CardProgress> Progress { get; set; }
        /// <summary>Words with the same meaning that are not in the set (ExtendedSynonyms; the app: AppModel.ExtraAnswers).</summary>
        public Func<SynonymQuery, IReadOnlyList<string>> ExtraAnswers { get; set; }

        public Env(RNG? rng = null, double? now = null, IReadOnlyDictionary<string, CardProgress>? progress = null,
            Func<SynonymQuery, IReadOnlyList<string>>? extraAnswers = null)
        {
            Rng = rng ?? Rand.SystemRNG();
            Now = now ?? TimeUtil.NowMs();
            Progress = progress ?? new Dictionary<string, CardProgress>();
            ExtraAnswers = extraAnswers ?? (_ => []);
        }
    }

    // MARK: - API

    /// <summary>
    /// Opens the Learn screen for set: resumes saved (with its open "Nicht ganz" screen and the answers given
    /// elsewhere since) unless forceNew, the saved session is finished or a different subset is asked for;
    /// otherwise starts a new session over subset (null = the whole set). A requested subset never silently ends a
    /// session with answers: it asks first. Options that shape a session changed since it started ask «Neu starten?» unless
    /// <paramref name="kept"/> says «Später» was answered for them (Windows only, issue #7).
    /// </summary>
    public static (State State, List<Effect> Effects) Start(VocabSet set, IReadOnlyDictionary<string, CardProgress> progress, StudyOptions options,
        SavedLearn? saved = null, StudySubset? subset = null, bool forceNew = false, bool review = false, RNG? rng = null, double? now = null,
        bool recheck = false, KeptOptions? kept = null)
    {
        var state = new State(Phase.Empty, null, set.Id, set.Title, set.TermLang, set.DefLang, set.Cards, options, subset ?? StudySubset.All, review, recheck)
        {
            Kept = kept,
        };
        var m = new Machine(state, new Env(rng, now, progress));
        m.Boot(saved, subset, forceNew);
        return m.Result();
    }

    /// <summary>One event: the new state and the effects to perform, in order.</summary>
    public static (State State, List<Effect> Effects) Reduce(State state, Event e, Env env)
    {
        var m = new Machine(state, env);
        m.Handle(e);
        return m.Result();
    }

    /// <summary>The label of what Enter does now (for the ↵ hint and the primary button), null when Enter does nothing.</summary>
    public static string? ReturnAction(State state)
    {
        if (state.Prompt is not null || state.Overlay is not null) return null;
        return state.Phase.Kind switch
        {
            PhaseKind.Question => state.Phase.QuestionType == QuestionType.Mc ? (state.Highlighted is null ? null : L("Auswählen")) : L("Antworten"),
            PhaseKind.Feedback or PhaseKind.Copy => L("Weiter"),
            PhaseKind.Checkpoint => L($"Weiter zu Runde {state.Round + 1}"),
            PhaseKind.Finished => L("Fertig"),
            PhaseKind.AllMastered => L("Fortschritt zurücksetzen und neu lernen"),
            _ => state.Subset.Equals(StudySubset.All) ? L("Begriffe hinzufügen") : L("Alle Begriffe üben"),
        };
    }

    /// <summary>The label of the override button: "Ich hatte recht", or "Als richtig zählen" when the edited card now accepts the answer; null when not offered.</summary>
    public static string? OverrideLabel(State state)
    {
        if (state.Feedback is not { CanOverride: true } f || state.Question?.Type != QuestionType.Written) return null;
        return state.Phase == Phase.FeedbackOf(FeedbackKind.Wrong) || state.Phase == Phase.Copy
            ? (f.EditedCorrect ? L("Als richtig zählen") : L("Ich hatte recht"))
            : null;
    }

    /// <summary>How option index of the multiple-choice question is drawn.</summary>
    public static OptionState OptionStateOf(State state, int index)
    {
        switch (state.Phase.Kind)
        {
            case PhaseKind.Question when state.Phase.QuestionType == QuestionType.Mc:
                if (state.Highlighted == index) return OptionState.Highlighted;
                if (state.Typed.Length == 0) return OptionState.Idle;
                var match = TypeAheadOf(state);
                return match.IsActive && match.Matching.Count > 0 && !match.Matching.Contains(index) ? OptionState.Filtered : OptionState.Idle;
            case PhaseKind.Feedback:
                if (state.Feedback is not { } f || state.Question?.Type != QuestionType.Mc) return OptionState.Idle;
                if (index == f.CorrectIndex) return OptionState.Correct;
                return index == f.ChosenIndex ? OptionState.Wrong : OptionState.Dimmed;
            default:
                return OptionState.Idle;
        }
    }

    /// <summary>The type-ahead of the question on screen.</summary>
    public static TypeAhead TypeAheadOf(State state) =>
        state.Phase == Phase.Mc && state.Question is { } q ? TypeAheadOf(state.Typed, q.Choices.Select(c => c.Text).ToList(), q.AnswerLang) : TypeAhead.None;

    /// <summary>Title, message and buttons of the open prompt.</summary>
    public static PromptContent? PromptContentOf(State state) => state.Prompt switch
    {
        null => null,
        Prompt.RestartSession => new(L("Neu starten?"), RestartSessionMessage(state.Session?.Subset ?? state.Subset), L("Neu starten"), L("Abbrechen"), false),
        Prompt.RestartForOptions r => new(L("Neu starten?"), RestartMessage(r.Changes), L("Neu starten"), L("Später"), false),
        Prompt.Relearn r => new(L("Fortschritt zurücksetzen?"),
            r.CardIds.Count == 1
                ? L("Der Lernfortschritt dieses Begriffs wird zurückgesetzt. Danach lernst du ihn von vorne – zuerst mit Multiple Choice.")
                : L($"Der Lernfortschritt dieser {r.CardIds.Count} Begriffe wird zurückgesetzt. Danach lernst du sie von vorne – zuerst mit Multiple Choice."),
            L("Zurücksetzen"), L("Abbrechen"), true),
        Prompt.ReplaceSession r => new(L("Laufende Lerneinheit beenden?"), ReplaceSessionMessage(r.Wanted), L("Neu beginnen"), L("Fortsetzen"), false),
        _ => null,
    };

    /// <summary>"Laufende Lerneinheit beenden?": one whole sentence per subset.</summary>
    static string ReplaceSessionMessage(StudySubset wanted) => wanted.Kind switch
    {
        StudySubsetKind.All => L("Deine gespeicherte Lerneinheit endet, wenn du jetzt alle Begriffe lernst. Dein Lernfortschritt bleibt erhalten."),
        StudySubsetKind.Starred => L("Deine gespeicherte Lerneinheit endet, wenn du jetzt nur die markierten Begriffe lernst. Dein Lernfortschritt bleibt erhalten."),
        StudySubsetKind.Learning => L("Deine gespeicherte Lerneinheit endet, wenn du jetzt nur die nicht gemeisterten Begriffe lernst. Dein Lernfortschritt bleibt erhalten."),
        StudySubsetKind.Missed => L("Deine gespeicherte Lerneinheit endet, wenn du jetzt nur die zuletzt falsch beantworteten Begriffe lernst. Dein Lernfortschritt bleibt erhalten."),
        _ => L("Deine gespeicherte Lerneinheit endet, wenn du jetzt eine neue Auswahl lernst. Dein Lernfortschritt bleibt erhalten."),
    };

    /// <summary>The AllMastered text: one whole sentence per scope.</summary>
    static string AllMasteredText(StudySubset subset, int count)
    {
        if (subset.Equals(StudySubset.Starred))
            return count == 1
                ? L("Du beherrschst bereits den markierten Begriff. Wiederhole sie, um zu prüfen, ob sie noch sitzen, setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe sie schriftlich.")
                : L($"Du beherrschst bereits alle {count} markierten Begriffe. Wiederhole sie, um zu prüfen, ob sie noch sitzen, setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe sie schriftlich.");
        return count == 1
            ? L("Du beherrschst bereits den Begriff. Wiederhole sie, um zu prüfen, ob sie noch sitzen, setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe sie schriftlich.")
            : L($"Du beherrschst bereits alle {count} Begriffe. Wiederhole sie, um zu prüfen, ob sie noch sitzen, setz den Fortschritt zurück, um nochmal von vorne zu lernen, oder übe sie schriftlich.");
    }

    /// <summary>The message screens (Empty, AllMastered). OffersWrite: "Schreiben üben"; OffersReview: "Alle wiederholen" (Event.StartReview).</summary>
    public sealed record MessageContent(string SystemImage, string Title, string Text, string PrimaryLabel, bool OffersWrite, bool OffersReview = false);

    public static MessageContent? MessageOf(State state)
    {
        if (state.Phase == Phase.AllMastered)
            return new("trophy.fill", L("Alles gemeistert!"), AllMasteredText(state.Subset, state.ScopeCardIds.Count),
                L("Fortschritt zurücksetzen und neu lernen"), true, true);
        if (state.Phase != Phase.Empty) return null;
        var all = L("Alle Begriffe üben");
        return state.Subset.Kind switch
        {
            StudySubsetKind.Starred => new("star", L("Keine markierten Begriffe"), L("Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben."), all, false),
            StudySubsetKind.Learning => new("trophy.fill", L("Alles gemeistert!"),
                L("Du beherrschst bereits alle Begriffe in diesem Lernset. Übe trotzdem alle, damit sie frisch bleiben."), all, false),
            StudySubsetKind.Missed or StudySubsetKind.CardIds => new("checkmark.circle", L("Keine falschen Begriffe"), L("Hier gibt es gerade nichts nachzuholen."), all, false),
            _ => new("square.stack.3d.up", L("Noch keine Begriffe zum Üben"),
                L("Füge diesem Lernset Begriffe mit Übersetzung hinzu, dann kann es losgehen."), L("Begriffe hinzufügen"), false),
        };
    }
}
