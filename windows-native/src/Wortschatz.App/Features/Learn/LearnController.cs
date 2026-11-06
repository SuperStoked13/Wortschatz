using Avalonia.Threading;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;

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
    bool _windowActive = true;
    bool _active;

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

    public LearnController(AppModel model, StudyRequest request, RNG? rng = null, Func<double>? clock = null)
    {
        _model = model;
        _request = request;
        _rng = rng ?? Rand.SystemRNG();
        _clock = clock ?? TimeUtil.NowMs;
        var store = model.Store;
        // Built again for the same route (a theme change): resume what is stored (Mac: StudyRequest.resuming).
        var start = StudySessions.Effective(request);
        var set = store.GetSet(request.SetId) ?? new VocabSet { Id = request.SetId, Title = "" };
        var saved = LearnFlow.SavedLearn.FromJson(store.GetLearnJSON(request.SetId));
        var (state, effects) = LearnFlow.Start(set, store.GetProgress(request.SetId), store.GetStudyOptions(request.SetId), saved, start.Subset,
            start.ForceNew, start.ReviewMastered || model.Preferences.LearnReview, _rng, _clock(), recheck: model.Preferences.LearnRecheck);
        State = state;
        _pendingStart = effects;
    }

    /// <summary>
    /// The screen appeared: performs the start effects and starts the study clock (a tick every 15 s).
    /// <paramref name="holdingToasts"/>: its toasts wait for ReleaseToasts (the screen is not visible yet).
    /// </summary>
    public void Activate(bool holdingToasts = false)
    {
        _active = true;
        if (holdingToasts) _heldToasts = [];
        var effects = _pendingStart;
        _pendingStart = [];
        Perform(effects);
        StudySessions.MarkStarted(_request);
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        _clockTimer.Tick += (_, _) =>
        {
            if (_windowActive && State.IsStudying) Send(new LearnFlow.Event.Tick());
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
        if (State.IsStudying) Reduce(new LearnFlow.Event.Tick());
        _active = false;
        foreach (var t in _timers.Values) t.Stop();
        _timers.Clear();
        _clockTimer?.Stop();
        _model.Speech.Stop();
    }

    public void WindowActivityChanged(bool active)
    {
        _windowActive = active;
        if (State.IsStudying) Send(active ? new LearnFlow.Event.Resume() : new LearnFlow.Event.Tick());
    }

    public void Send(LearnFlow.Event e)
    {
        if (!_active) return;
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
        var env = new LearnFlow.Env(_rng, _clock(), _model.Store.GetProgress(SetId));
        var previous = State.Phase.Kind;
        var (next, effects) = LearnFlow.Reduce(State, e, env);
        State = next;
        Perform(effects);
        PlaySound(effects, previous);
        // Typing shows in the field already; the study clock (every 15 s, and its resuming) changes nothing on screen –
        // a redraw would take the field away for a moment (on a phone the keyboard closes and opens again).
        if (e is not (LearnFlow.Event.DraftChanged or LearnFlow.Event.Tick or LearnFlow.Event.Resume)) Changed?.Invoke();
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
        var store = _model.Store;
        foreach (var effect in effects)
        {
            switch (effect)
            {
                case LearnFlow.Effect.RecordAnswer r:
                    Streak.Record(r.Correct);
                    Write(() => store.RecordAnswer(SetId, r.CardId, r.Correct, r.At));
                    break;
                case LearnFlow.Effect.OverrideLastAnswer o:
                    Streak.OverrideMiss();
                    Write(() => store.OverrideLastAnswer(SetId, o.CardId));
                    break;
                case LearnFlow.Effect.ResetProgress reset:
                    Write(() =>
                    {
                        if (reset.CardIds is { } ids) store.ResetCardProgress(SetId, ids);
                        else store.ResetProgress(SetId);
                    });
                    break;
                case LearnFlow.Effect.SaveLearn save:
                    Write(() => store.SaveLearnJSON(SetId, new LearnFlow.SavedLearn(save.State, save.Feedback).ToJson()));
                    break;
                case LearnFlow.Effect.ClearLearn:
                    Write(() => store.ClearLearn(SetId));
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
                case LearnFlow.Effect.UpdateCard u:
                    Write(() => store.UpdateCard(SetId, u.Card.Id, new CardChanges(u.Card.Term, u.Card.Definition)));
                    break;
                case LearnFlow.Effect.ToggleStar t:
                    Write(() =>
                    {
                        store.ToggleStar(SetId, t.CardId);
                        _model.AnnounceStar(SetId, t.CardId);
                    });
                    break;
                case LearnFlow.Effect.Announce a:
                    Announcer.Announce(a.Text);
                    break;
                case LearnFlow.Effect.Navigate n:
                    Navigate(n.Destination);
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

    /// <summary>A toast of the flow (Mac: showToast): "Willkommen zurück" with the waving hand for 3.5 s, the others for 2 s.</summary>
    void ShowToast(string text, LearnFlow.Tone tone)
    {
        bool welcome = text == LearnFlow.WELCOME_BACK;
        var toast = new ToastMessage(text, tone switch { LearnFlow.Tone.Success => ToastTone.Success, LearnFlow.Tone.Warning => ToastTone.Warning, _ => ToastTone.Neutral },
            DurationMs: welcome ? 3500 : 2000) { Icon = welcome ? IconName.Hand : null };
        if (_heldToasts is not null) _heldToasts.Add(toast);
        else _model.ShowToast(toast);
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
