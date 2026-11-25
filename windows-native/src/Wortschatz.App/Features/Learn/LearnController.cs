using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Learn;

/// <summary>
/// Runs one Learn screen (Mac: LearnController.swift): holds the LearnFlow state, reduces every event with the
/// freshly stored progress and performs the reducer's effects in order (store writes, speech, toasts, the
/// auto-advance timer, navigation). The view only renders State and calls Send.
/// </summary>
public sealed class LearnController
{
    readonly AppModel _model;
    readonly StudyRequest _request;
    readonly RNG _rng;
    readonly Func<double> _clock;
    readonly Dictionary<int, DispatcherTimer> _timers = [];
    DispatcherTimer? _clockTimer;
    List<LearnFlow.Effect> _pendingStart;
    /// <summary>Toasts held back while the screen is still invisible ("Willkommen zurück" must not pop up over an empty backdrop); null when toasts show at once.</summary>
    List<ToastMessage>? _heldToasts;
    /// <summary>Study clock, as in Schreiben: idle after WriteFlow.ClockIdleMs without input, and the window's activity.</summary>
    readonly WriteClock _studyClock;
    bool _active;
    /// <summary>The Learn switches as last seen here (SwitchesMayHaveChanged).</summary>
    AppModel.LearnSwitches _switches;

    public string SetId => _request.SetId;
    public LearnFlow.State State { get; private set; }
    /// <summary>Correct answers in a row while this screen is open (the flame in the action bar).</summary>
    public AnswerStreak Streak { get; } = new();
    public int BestStreak => Streak.Best;
    /// <summary>The auto-advance that is running (the line in the status pill); compare its token with State.AutoAdvanceToken.</summary>
    public StudyCountdown? Countdown { get; private set; }

    /// <summary>The card of the current question (the card editor, Ctrl+E).</summary>
    public Card? CurrentCard => State.Question is { } q ? State.Cards.FirstOrDefault(c => c.Id == q.CardId) : null;

    /// <summary>The state changed (render). Not raised for DraftChanged (the field shows it already).</summary>
    public event Action? Changed;

    /// <summary>Something is read aloud now (the speaker on the card moves).</summary>
    public event Action? Spoke;

    /// <summary>"Optionen" in the hint at the first recheck: opens the options (the screen sets it).</summary>
    public Action? OptionsRequested { get; set; }

    /// <summary>The session (its StartedAt) whose first recheck showed the hint: once per session.</summary>
    double? _recheckHintSession;

    public LearnController(AppModel model, StudyRequest request, RNG? rng = null, Func<double>? clock = null)
    {
        _model = model;
        _request = request;
        _rng = rng ?? Rand.SystemRNG();
        _clock = clock ?? TimeUtil.NowMs;
        _studyClock = new WriteClock(_clock());
        var store = model.Store;
        // Built again for the same route (a theme change): resume what is stored (Mac: StudyRequest.resuming).
        var start = StudySessions.Effective(request);
        var set = store.GetSet(request.SetId) ?? new VocabSet { Id = request.SetId, Title = "" };
        var saved = LearnFlow.SavedLearn.FromJson(store.GetLearnJSON(request.SetId));
        _switches = model.CurrentLearnSwitches;
        var (state, effects) = LearnFlow.Start(set, store.GetProgress(request.SetId), store.GetStudyOptions(request.SetId), saved, start.Subset,
            start.ForceNew, start.ReviewMastered || _switches.Review, _rng, _clock(), recheck: _switches.Recheck,
            kept: model.Preferences.KeptOptionsOf("learn", request.SetId));
        State = state;
        _pendingStart = effects;
        model.PreloadSynonyms(set);
    }

    /// <summary>
    /// The screen appeared: performs the start effects and starts the study clock (a tick every 15 s; after
    /// WriteFlow.ClockIdleMs without input it pauses until the next input, as in Schreiben – before 24.11.2026 it ticked
    /// on forever: a Lernen left open counted the time away as study time and saved the library 4 times a minute).
    /// <paramref name="holdingToasts"/>: its toasts wait for ReleaseToasts (the screen is not visible yet).
    /// </summary>
    public void Activate(bool holdingToasts = false)
    {
        _active = true;
        if (holdingToasts) _heldToasts = [];
        var effects = _pendingStart;
        _pendingStart = [];
        Perform(effects);
        HintRecheck();
        StudySessions.MarkStarted(_request);
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(WriteFlow.ClockTickMs) };
        _clockTimer.Tick += (_, _) =>
        {
            // Saves the clock while studying in the active window; after ClockIdleMs without input it waits (Mac: runClock).
            if (_studyClock.IsWindowActive && !_studyClock.IsIdle && State.IsStudying) Send(new LearnFlow.Event.Tick());
            _studyClock.Tick(_clock());
        };
        _clockTimer.Start();
    }

    /// <summary>The screen is on screen now: the toasts held back by Activate show.</summary>
    public void ReleaseToasts()
    {
        var toasts = _heldToasts ?? [];
        _heldToasts = null;
        foreach (var toast in toasts) _model.ShowToast(toast);
    }

    /// <summary>The screen went away: keeps the study time, stops timers and speech.</summary>
    public void Deactivate()
    {
        if (!_active) return;
        _heldToasts = null;
        // The last tick (idle: the clock was saved when it stopped, the time since is not study time).
        if (State.IsStudying && !_studyClock.IsIdle) Reduce(new LearnFlow.Event.Tick());
        _active = false;
        foreach (var t in _timers.Values) t.Stop();
        _timers.Clear();
        _clockTimer?.Stop();
        _model.Speech.Stop();
    }

    /// <summary>The window became active or inactive: time away is not study time.</summary>
    public void WindowActivityChanged(bool active)
    {
        _studyClock.WindowActivityChanged(active, _clock());
        // Already paused: it was saved when it stopped.
        if (!active && _studyClock.IsIdle) return;
        if (State.IsStudying) Send(active ? new LearnFlow.Event.Resume() : new LearnFlow.Event.Tick());
    }

    public void Send(LearnFlow.Event e)
    {
        if (!_active) return;
        // The learner's input keeps the clock running; a paused clock resumes first, without counting the pause
        // (Mac: markActive).
        if (WriteClock.IsUserActivity(e) && _studyClock.Activity(_clock())) Reduce(new LearnFlow.Event.Resume());
        Reduce(e);
    }

    /// <summary>
    /// A key press from the screen. After an answer, a letter typed with an input method continues without typing it
    /// (Mac: LearnController.press, LearnKeyRouter.continuing).
    /// </summary>
    public void Press(KeyInput key, bool isRepeat)
    {
        var input = LearnKeyRouter.Continuing(key, State.Phase.IsFeedback, StudyInput.IsInputMethodActive);
        Send(new LearnFlow.Event.Key(input, isRepeat));
    }

    /// <summary>Reads a text aloud (🔊 next to the right answer).</summary>
    public void Speak(string text, Lang lang)
    {
        if (!_active) return;
        _model.Speech.Speak(text, lang);
        Spoke?.Invoke();
    }

    void Reduce(LearnFlow.Event e)
    {
        var env = new LearnFlow.Env(_rng, _clock(), _model.Store.GetProgress(SetId), _model.ExtraAnswers(SetId));
        var previous = State.Phase.Kind;
        var (next, effects) = LearnFlow.Reduce(State, e, env);
        State = next;
        Perform(effects);
        StopStaleTimers();
        HintRecheck();
        AskIfSameTerm();
        PlaySound(effects, previous);
        // Typing shows in the field already; the study clock (every 15 s, and its resuming) changes nothing on screen –
        // a redraw would take the field away for a moment (on a phone the keyboard closes and opens again). Unless it
        // moved on – redrawn after the field's own TextChanged. (A typed-out copy no longer moves on here: it starts a
        // short beat, CopyStep, whose timer moves on.)
        bool quiet = e is LearnFlow.Event.DraftChanged or LearnFlow.Event.Tick or LearnFlow.Event.Resume;
        if (!quiet) Changed?.Invoke();
        else if (State.Phase.Kind != previous) Dispatcher.UIThread.Post(() => Changed?.Invoke());
    }

    LearnFlow.Feedback? _sameTermAsked;

    /// <summary>
    /// A wrong written answer that is the answer of another card with the same word: asks what it counts as
    /// (StudyChrome.AskSameTerm), once per answer.
    /// </summary>
    void AskIfSameTerm()
    {
        if (State.Feedback is not { Kind: LearnFlow.FeedbackKind.Wrong, CanOverride: true } feedback || ReferenceEquals(feedback, _sameTermAsked)) return;
        if (State.Question is not { Type: QuestionType.Written } q || State.Cards.FirstOrDefault(c => c.Id == q.CardId) is not { } card) return;
        _sameTermAsked = feedback;
        if (SameTermCards.AnswerOfOtherCard(feedback.Given, card, State.Cards, q.Ask, State.Options.Tolerance, q.PromptLang, q.AnswerLang) is not { } other) return;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            if (_active && ReferenceEquals(State.Feedback, feedback))
                StudyChrome.AskSameTerm(_model, SetId, card, other, q.Ask, q.PromptLang, q.AnswerLang, feedback.Given, () => Send(new LearnFlow.Event.Override()));
        });
    }

    /// <summary>
    /// The library changed (after any store write, also from elsewhere): forwards what differs from the screen's state
    /// (Mac: storeDidChange). Echoes of the screen's own writes match already and send nothing.
    /// </summary>
    public void StoreDidChange()
    {
        if (!_active) return;
        var store = _model.Store;
        if (store.GetSet(SetId) is not { } set) return;
        if (set.Title != State.SetTitle || set.TermLang != State.TermLang || set.DefLang != State.DefLang || !set.Cards.SequenceEqual(State.Cards))
            Send(new LearnFlow.Event.SetChanged(set));
        var options = store.GetStudyOptions(SetId);
        if (options != State.Options) Send(new LearnFlow.Event.OptionsChanged(options));
        if (State.Session is { } session && !LearnEngine.MatchesProgress(session, store.GetProgress(SetId)))
            Send(new LearnFlow.Event.ProgressChanged());
        SwitchesMayHaveChanged();
    }

    /// <summary>
    /// «Wiederholungsfragen» or «Nachkontrolle nach Fehlern» was switched (in the options, or imported): it applies to this
    /// session at once (Mac: setReview/setRecheck/switchesChanged). Only a real change is sent: a session started for its
    /// repetition questions («Alle wiederholen») keeps them while the switch stays off.
    /// </summary>
    public void SwitchesMayHaveChanged()
    {
        var now = _model.CurrentLearnSwitches;
        var old = _switches;
        _switches = now;
        if (now.Review != old.Review) Send(new LearnFlow.Event.ReviewChanged(now.Review));
        if (now.Recheck != old.Recheck) Send(new LearnFlow.Event.RecheckChanged(now.Recheck));
    }

    /// <summary>The sound of a step (Mac: LearnController.playSound → SoundEffects.playStudyStep).</summary>
    void PlaySound(List<LearnFlow.Effect> effects, LearnFlow.PhaseKind previous)
    {
        Services.SoundEffects.StudyAnswer? answer = null;
        foreach (var effect in effects)
        {
            if (effect is LearnFlow.Effect.RecordAnswer r)
            {
                answer = r.Correct ? Services.SoundEffects.StudyAnswer.Correct
                    : State.Feedback?.Kind == LearnFlow.FeedbackKind.DontKnow ? Services.SoundEffects.StudyAnswer.DontKnow : Services.SoundEffects.StudyAnswer.Wrong;
                break;
            }
            if (effect is LearnFlow.Effect.OverrideLastAnswer)
            {
                answer = Services.SoundEffects.StudyAnswer.Correct;
                break;
            }
        }
        var phase = State.Phase.Kind;
        _model.Sounds.PlayStudyStep(phase == LearnFlow.PhaseKind.Finished && previous != LearnFlow.PhaseKind.Finished,
            phase == LearnFlow.PhaseKind.Checkpoint && previous != LearnFlow.PhaseKind.Checkpoint, answer, Streak.ReachedMilestone);
    }

    void Perform(List<LearnFlow.Effect> effects)
    {
        // The step's store writes first, as one change (LibraryStore.Batch): the app reacts once per answer, not once
        // for the answer and once more for the session (Mac: LearnController.perform, 24.11.2026).
        var writes = effects.Where(WritesStore).ToList();
        if (writes.Count > 0)
        {
            var store = _model.Store;
            Write(() => store.Batch(() =>
            {
                foreach (var effect in writes) Apply(effect, store);
            }));
        }
        foreach (var effect in effects)
        {
            switch (effect)
            {
                case LearnFlow.Effect.RecordAnswer r:
                    Streak.Record(r.Correct);
                    break;
                case LearnFlow.Effect.OverrideLastAnswer:
                    Streak.OverrideMiss();
                    break;
                case LearnFlow.Effect.Haptic h:
                    Services.Haptics.Play(h.Kind);
                    break;
                case LearnFlow.Effect.Speak s:
                    _model.Speech.Speak(s.Text, s.Lang);
                    Spoke?.Invoke();
                    break;
                case LearnFlow.Effect.ScheduleAutoAdvance a:
                    Schedule(a.Ms, a.Token);
                    break;
                case LearnFlow.Effect.Toast t:
                    ShowToast(t.Text, t.Tone);
                    break;
                case LearnFlow.Effect.Announce a:
                    Announcer.Announce(a.Text);
                    break;
                case LearnFlow.Effect.Navigate n:
                    Navigate(n.Destination);
                    break;
                case LearnFlow.Effect.KeepOptions k:
                    _model.Preferences.SaveKeptOptions("learn", SetId, k.Kept);
                    break;
            }
        }
        _model.SaveSoon();
    }

    /// <summary>Effects that write to the library store (Apply).</summary>
    static bool WritesStore(LearnFlow.Effect effect) => effect is LearnFlow.Effect.RecordAnswer or LearnFlow.Effect.OverrideLastAnswer
        or LearnFlow.Effect.ResetProgress or LearnFlow.Effect.SaveLearn or LearnFlow.Effect.ClearLearn or LearnFlow.Effect.UpdateCard
        or LearnFlow.Effect.ToggleStar;

    /// <summary>Applies one store effect (WritesStore).</summary>
    void Apply(LearnFlow.Effect effect, LibraryStore store)
    {
        switch (effect)
        {
            case LearnFlow.Effect.RecordAnswer r:
                store.RecordAnswer(SetId, r.CardId, r.Correct, r.At);
                break;
            case LearnFlow.Effect.OverrideLastAnswer o:
                store.OverrideLastAnswer(SetId, o.CardId);
                break;
            case LearnFlow.Effect.ResetProgress reset:
                if (reset.CardIds is { } ids) store.ResetCardProgress(SetId, ids);
                else store.ResetProgress(SetId);
                break;
            case LearnFlow.Effect.SaveLearn save:
                store.SaveLearnJSON(SetId, new LearnFlow.SavedLearn(save.State, save.Feedback).ToJson());
                break;
            case LearnFlow.Effect.ClearLearn:
                store.ClearLearn(SetId);
                break;
            case LearnFlow.Effect.UpdateCard u:
                store.UpdateCard(SetId, u.Card.Id, new CardChanges(u.Card.Term, u.Card.Definition));
                break;
            case LearnFlow.Effect.ToggleStar t:
                store.ToggleStar(SetId, t.CardId);
                _model.AnnounceStar(SetId, t.CardId);
                break;
        }
    }

    /// <summary>A store write; a failure shows as a message instead of ending the app (Mac: write → model.report).</summary>
    void Write(Action change)
    {
        try
        {
            change();
        }
        catch (LibraryStoreError e)
        {
            _model.ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 6000));
        }
    }

    /// <summary>A toast of the flow (Mac: showToast): "Willkommen zurück" with the waving hand for 3.5 s, the others for 2 s.</summary>
    void ShowToast(string text, LearnFlow.Tone tone)
    {
        // The flow's text in the app's language (whether the flow translates it or the constant does).
        bool welcome = text == LearnFlow.WELCOME_BACK || text == L(LearnFlow.WELCOME_BACK);
        var toast = new ToastMessage(text, tone switch { LearnFlow.Tone.Success => ToastTone.Success, LearnFlow.Tone.Warning => ToastTone.Warning, _ => ToastTone.Neutral },
            DurationMs: welcome ? 3500 : 2000) { Icon = welcome ? IconName.Hand : null };
        if (_heldToasts is not null) _heldToasts.Add(toast);
        else _model.ShowToast(toast);
    }

    /// <summary>
    /// The first recheck of a session on screen: a quiet hint that the Nachkontrolle can be switched off, with
    /// "Optionen" (Mac: LearnController.hintRecheck). Once per session.
    /// </summary>
    void HintRecheck()
    {
        if (State.Phase.Kind != LearnFlow.PhaseKind.Question || State.Question is not { IsRecheck: true } || State.Session is not { } session) return;
        if (_recheckHintSession == session.StartedAt) return;
        _recheckHintSession = session.StartedAt;
        var toast = new ToastMessage(LearnFlow.RECHECK_HINT, ActionLabel: L("Optionen"), Action: () => OptionsRequested?.Invoke(),
            DurationMs: LearnFlow.RECHECK_HINT_MS) { Icon = IconName.Info };
        if (_heldToasts is not null) _heldToasts.Add(toast);
        else _model.ShowToast(toast);
    }

    /// <summary>
    /// Auto-advances whose token is no longer the state's (answered by key, paused, a new question) can never move on:
    /// stopped right away instead of firing for nothing (each firing redrew the screen; on a phone the keyboard
    /// closed and opened again).
    /// </summary>
    void StopStaleTimers()
    {
        foreach (var token in _timers.Keys.Where(t => t != State.AutoAdvanceToken).ToList())
        {
            _timers[token].Stop();
            _timers.Remove(token);
        }
    }

    void Schedule(int ms, int token)
    {
        Countdown = new StudyCountdown(token, ms, Motion.Now());
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Math.Max(1, ms)) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            _timers.Remove(token);
            if (Countdown?.Token == token) Countdown = null;
            Send(new LearnFlow.Event.AutoAdvanceFired(token));
        };
        _timers[token] = timer;
        timer.Start();
    }

    void Navigate(LearnFlow.Destination destination)
    {
        // "Begriffe hinzufügen" on the empty screen: learning starts once the editor closes with cards to ask.
        bool addingCards = destination == LearnFlow.Destination.EditSet && State.Phase == LearnFlow.Phase.Empty && State.Subset.Equals(StudySubset.All);
        Dispatcher.UIThread.Post(() =>
        {
            switch (destination)
            {
                case LearnFlow.Destination.Write: _model.Study(SetId, StudyMode.Write, forceNew: true); break;
                case LearnFlow.Destination.EditSet:
                    if (addingCards) StudySessions.StudyAfterEditing(_model, SetId, StudyMode.Learn, set => set.Cards.Any(WriteFlow.IsUsableCard));
                    _model.Navigate(new Route.Editor(SetId));
                    break;
                default: _model.BackToSet(SetId); break;
            }
        });
    }
}
