using System.Runtime.CompilerServices;
using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Write;

/// <summary>
/// Runs one Write screen (Mac: WriteController.swift): holds the WriteFlow state, reduces events with the stored
/// progress and performs the effects (store writes, speech, toasts, the auto-advance timer, navigation). The study clock
/// pauses after two minutes without input (WriteClock).
/// </summary>
public sealed class WriteController
{
    readonly AppModel _model;
    readonly StudyRequest _request;
    readonly RNG _rng;
    readonly Dictionary<int, DispatcherTimer> _timers = [];
    readonly WriteClock _studyClock;
    DispatcherTimer? _clockTimer;
    List<WriteFlow.Effect> _pendingStart;
    /// <summary>Toasts held back while the screen is still invisible; null when toasts show at once.</summary>
    List<ToastMessage>? _heldToasts;
    bool _active;

    /// <summary>
    /// The finished session each study request showed, so the results come back when the same screen is built again (a
    /// theme change rebuilds the window) instead of a new session starting (Mac: resultsMarkers).
    /// </summary>
    static readonly ConditionalWeakTable<StudyRequest, StrongBox<double>> ResultsMarkers = new();

    public string SetId => _request.SetId;
    public WriteFlow.State State { get; private set; }
    /// <summary>Correct answers in a row while this screen is open (the flame in the status pill).</summary>
    public Learn.AnswerStreak Streak { get; } = new();
    /// <summary>The auto-advance that is running (the line in the status pill); compare its token with State.AutoAdvance.</summary>
    public StudyCountdown? Countdown { get; private set; }

    public event Action? Changed;

    /// <summary>Something is read aloud now (the speaker on the card moves).</summary>
    public event Action? Spoke;

    public WriteController(AppModel model, StudyRequest request, RNG? rng = null)
    {
        _model = model;
        _request = request;
        _rng = rng ?? Rand.SystemRNG();
        _studyClock = new WriteClock(TimeUtil.NowMs());
        var store = model.Store;
        var start = StudySessions.Effective(request);
        double? marker = ResultsMarkers.TryGetValue(request, out var box) ? box.Value : null;
        var (state, effects) = WriteFlow.Start(store.GetSet(request.SetId), store.GetStudyOptions(request.SetId), store.GetSessionJSON(request.SetId), Env(),
            start.Subset, start.ForceNew, marker);
        State = state;
        _pendingStart = effects;
    }

    WriteFlow.Env Env() => new(TimeUtil.NowMs(), _rng, _model.Store.GetProgress(SetId));

    /// <summary>The screen appeared. <paramref name="holdingToasts"/>: its toasts wait for ReleaseToasts.</summary>
    public void Activate(bool holdingToasts = false)
    {
        _active = true;
        if (holdingToasts) _heldToasts = [];
        var effects = _pendingStart;
        _pendingStart = [];
        Perform(effects);
        RememberResults();
        StudySessions.MarkStarted(_request);
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(WriteFlow.ClockTickMs) };
        _clockTimer.Tick += (_, _) =>
        {
            // Saves the clock while studying in the active window; after ClockIdleMs without input it waits (Mac: runClock).
            bool studying = WriteFlow.IsStudying(State);
            if (_studyClock.IsWindowActive && !_studyClock.IsIdle && studying) Send(new WriteFlow.Event.ClockTick());
            _studyClock.Tick(TimeUtil.NowMs());
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

    public void Deactivate()
    {
        if (!_active) return;
        _heldToasts = null;
        if (WriteFlow.IsStudying(State)) Reduce(new WriteFlow.Event.ClockTick());
        _active = false;
        foreach (var t in _timers.Values) t.Stop();
        _timers.Clear();
        _clockTimer?.Stop();
        _model.Speech.Stop();
    }

    /// <summary>The window became active or inactive: time away is not study time.</summary>
    public void WindowActivityChanged(bool active)
    {
        _studyClock.WindowActivityChanged(active, TimeUtil.NowMs());
        if (active) Send(new WriteFlow.Event.ClockResumed());
        else if (WriteFlow.IsStudying(State)) Send(new WriteFlow.Event.ClockTick());
    }

    public void Send(WriteFlow.Event e)
    {
        if (!_active) return;
        // The learner's input keeps the clock running; a paused clock resumes first (Mac: markActive).
        if (WriteClock.IsUserActivity(e) && _studyClock.Activity(TimeUtil.NowMs())) Reduce(new WriteFlow.Event.ClockResumed());
        Reduce(e);
    }

    /// <summary>
    /// A key press from the screen. After a correct answer, a letter typed with an input method continues without
    /// typing it (Mac: WriteController.press, LearnKeyRouter.continuing).
    /// </summary>
    public void Press(KeyInput key, bool isRepeat)
    {
        var input = LearnKeyRouter.Continuing(key, State.Phase == WriteFlow.Phase.FeedbackOf(WriteFlow.FeedbackKind.Correct), StudyInput.IsInputMethodActive);
        Send(new WriteFlow.Event.Key(input, isRepeat));
    }

    void Reduce(WriteFlow.Event e)
    {
        var previous = State.Phase.Kind;
        var (next, effects) = WriteFlow.Reduce(State, e, Env());
        State = next;
        Perform(effects);
        RememberResults();
        PlaySound(effects, previous);
        // Typing shows in the field already; the study clock (every 15 s, and its resuming) changes nothing on screen –
        // a redraw would take the field away for a moment (on a phone the keyboard closes and opens again).
        if (e is not (WriteFlow.Event.InputChanged or WriteFlow.Event.ClockResumed or WriteFlow.Event.ClockTick)) Changed?.Invoke();
    }

    /// <summary>
    /// The library changed (after any store write, also from elsewhere): forwards what differs from the screen's state
    /// (Mac: storeDidChange). Echoes of the screen's own writes match already and send nothing.
    /// </summary>
    public void StoreDidChange()
    {
        if (!_active) return;
        var store = _model.Store;
        if (store.GetSet(SetId) is not { } set)
        {
            if (State.Set is not null) Send(new WriteFlow.Event.SetDeleted());
            return;
        }
        if (State.Set is { } shown && (set.Title != shown.Title || set.TermLang != shown.TermLang || set.DefLang != shown.DefLang || !set.Cards.SequenceEqual(shown.Cards)))
            Send(new WriteFlow.Event.SetChanged(set));
        var options = store.GetStudyOptions(SetId);
        if (options != State.Options) Send(new WriteFlow.Event.OptionsChanged(options));
    }

    /// <summary>The sound of a step (Mac: WriteController.playSound → SoundEffects.playStudyStep).</summary>
    void PlaySound(List<WriteFlow.Effect> effects, WriteFlow.PhaseKind previous)
    {
        Services.SoundEffects.StudyAnswer? answer = null;
        foreach (var effect in effects)
        {
            if (effect is WriteFlow.Effect.RecordAnswer r)
            {
                answer = r.Correct ? Services.SoundEffects.StudyAnswer.Correct
                    : State.Feedback?.DontKnow == true ? Services.SoundEffects.StudyAnswer.DontKnow : Services.SoundEffects.StudyAnswer.Wrong;
                break;
            }
            if (effect is WriteFlow.Effect.OverrideLastAnswer)
            {
                answer = Services.SoundEffects.StudyAnswer.Correct;
                break;
            }
        }
        var phase = State.Phase.Kind;
        _model.Sounds.PlayStudyStep(phase == WriteFlow.PhaseKind.Results && previous != WriteFlow.PhaseKind.Results,
            phase == WriteFlow.PhaseKind.Summary && previous != WriteFlow.PhaseKind.Summary, answer, Streak.ReachedMilestone);
    }

    void Perform(List<WriteFlow.Effect> effects)
    {
        var store = _model.Store;
        foreach (var effect in effects)
        {
            switch (effect)
            {
                case WriteFlow.Effect.RecordAnswer r:
                    Streak.Record(r.Correct);
                    Write(() => store.RecordAnswer(SetId, r.CardId, r.Correct, r.At));
                    break;
                case WriteFlow.Effect.OverrideLastAnswer o:
                    Streak.OverrideMiss();
                    Write(() => store.OverrideLastAnswer(SetId, o.CardId));
                    break;
                case WriteFlow.Effect.SaveSession s:
                    Write(() => store.SaveSessionJSON(SetId, WriteFlow.StoredJSON(s.Session, s.Feedback)));
                    break;
                case WriteFlow.Effect.Haptic h:
                    Services.Haptics.Play(h.Kind);
                    break;
                case WriteFlow.Effect.Speak s:
                    _model.Speech.Speak(s.Text, s.Lang);
                    Spoke?.Invoke();
                    break;
                case WriteFlow.Effect.ScheduleAutoAdvance a:
                    Schedule(a.Ms, a.Token);
                    break;
                case WriteFlow.Effect.UpdateCard u:
                    Write(() => store.UpdateCard(SetId, u.Card.Id, new CardChanges(u.Card.Term, u.Card.Definition)));
                    break;
                case WriteFlow.Effect.ToggleStar t:
                    Write(() =>
                    {
                        store.ToggleStar(SetId, t.CardId);
                        _model.AnnounceStar(SetId, t.CardId);
                    });
                    break;
                case WriteFlow.Effect.Announce a:
                    Announcer.Announce(a.Text, important: State.Phase.IsMiss);
                    break;
                case WriteFlow.Effect.ShowToast t:
                    // Mac: showToast with the toast's own symbol (sparkles for "Willkommen zurück").
                    var toast = new ToastMessage(t.Toast.Message(), t.Toast.IsSuccess() ? ToastTone.Success : ToastTone.Neutral,
                        DurationMs: t.Toast.DurationMs() ?? ToastMessage.DefaultDuration) { Icon = Icons.ForSymbol(t.Toast.SystemImage()) };
                    if (_heldToasts is not null) _heldToasts.Add(toast);
                    else _model.ShowToast(toast);
                    break;
                case WriteFlow.Effect.EditSet:
                    // "Begriffe hinzufügen" on the empty screen: writing starts once the editor closes with cards to ask.
                    bool addingCards = State.Phase == WriteFlow.Phase.Empty && (State.EmptySubset ?? StudySubset.All).Kind == StudySubsetKind.All;
                    Dispatcher.UIThread.Post(() =>
                    {
                        if (addingCards) StudySessions.StudyAfterEditing(_model, SetId, StudyMode.Write, set => set.Cards.Any(WriteFlow.IsUsableCard));
                        _model.Navigate(new Route.Editor(SetId));
                    });
                    break;
                case WriteFlow.Effect.Exit:
                    Dispatcher.UIThread.Post(() => _model.BackToSet(SetId));
                    break;
            }
        }
        _model.SaveSoon();
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

    void RememberResults()
    {
        if (State.Phase == WriteFlow.Phase.Results && State.ResultsMarker is { } marker) ResultsMarkers.AddOrUpdate(_request, new StrongBox<double>(marker));
        else ResultsMarkers.Remove(_request);
    }

    /// <summary>Reads the prompt or the answer aloud (the screen's 🔊 buttons and Ctrl+R).</summary>
    public void Speak(WriteFlow.SpeechTarget target) => Send(new WriteFlow.Event.Speak(target));

    void Schedule(int ms, int token)
    {
        Countdown = new StudyCountdown(token, ms, Motion.Now());
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Math.Max(1, ms)) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            _timers.Remove(token);
            Send(new WriteFlow.Event.AutoAdvanceFired(token));
        };
        _timers[token] = timer;
        timer.Start();
    }
}
