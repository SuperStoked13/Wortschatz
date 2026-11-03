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

    public LearnController(AppModel model, StudyRequest request, RNG? rng = null, Func<double>? clock = null)
    {
        _model = model;
        _request = request;
        _rng = rng ?? Rand.SystemRNG();
        _clock = clock ?? TimeUtil.NowMs;
        var store = model.Store;
        var set = store.GetSet(request.SetId) ?? new VocabSet { Id = request.SetId, Title = "" };
        var saved = LearnFlow.SavedLearn.FromJson(store.GetLearnJSON(request.SetId));
        var (state, effects) = LearnFlow.Start(set, store.GetProgress(request.SetId), store.GetStudyOptions(request.SetId), saved, request.Subset,
            request.ForceNew, request.ReviewMastered || model.Preferences.LearnReview, _rng, _clock());
        State = state;
        _pendingStart = effects;
    }

    /// <summary>The screen appeared: performs the start effects and starts the study clock (a tick every 15 s).</summary>
    public void Activate()
    {
        _active = true;
        var effects = _pendingStart;
        _pendingStart = [];
        Perform(effects);
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        _clockTimer.Tick += (_, _) =>
        {
            if (_windowActive && State.IsStudying) Send(new LearnFlow.Event.Tick());
        };
        _clockTimer.Start();
    }

    /// <summary>The screen went away: keeps the study time, stops timers and speech.</summary>
    public void Deactivate()
    {
        if (!_active) return;
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

    void Reduce(LearnFlow.Event e)
    {
        var env = new LearnFlow.Env(_rng, _clock(), _model.Store.GetProgress(SetId));
        var previous = State.Phase.Kind;
        var (next, effects) = LearnFlow.Reduce(State, e, env);
        State = next;
        Perform(effects);
        PlaySound(effects, previous);
        if (e is not LearnFlow.Event.DraftChanged) Changed?.Invoke();
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
                    store.RecordAnswer(SetId, r.CardId, r.Correct, r.At);
                    Streak.Record(r.Correct);
                    break;
                case LearnFlow.Effect.OverrideLastAnswer o:
                    store.OverrideLastAnswer(SetId, o.CardId);
                    Streak.OverrideMiss();
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
                case LearnFlow.Effect.Speak s:
                    _model.Speech.Speak(s.Text, s.Lang);
                    break;
                case LearnFlow.Effect.ScheduleAutoAdvance a:
                    Schedule(a.Ms, a.Token);
                    break;
                case LearnFlow.Effect.Toast t:
                    _model.ShowToast(new ToastMessage(t.Text, t.Tone switch { LearnFlow.Tone.Success => ToastTone.Success, LearnFlow.Tone.Warning => ToastTone.Warning, _ => ToastTone.Neutral }));
                    break;
                case LearnFlow.Effect.UpdateCard u:
                    store.UpdateCard(SetId, u.Card.Id, new CardChanges(u.Card.Term, u.Card.Definition));
                    break;
                case LearnFlow.Effect.ToggleStar t:
                    store.ToggleStar(SetId, t.CardId);
                    break;
                case LearnFlow.Effect.Navigate n:
                    Navigate(n.Destination);
                    break;
                // Haptic: the Mac's haptic/sound feedback (SoundEffects) is not ported yet. Announce: screen reader
                // announcements are not wired to Windows UI Automation yet (TODO, see README).
            }
        }
        _model.SaveSoon();
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
        Dispatcher.UIThread.Post(() =>
        {
            switch (destination)
            {
                case LearnFlow.Destination.Write: _model.Study(SetId, StudyMode.Write, forceNew: true); break;
                case LearnFlow.Destination.EditSet: _model.Navigate(new Route.Editor(SetId)); break;
                default: _model.BackToSet(SetId); break;
            }
        });
    }
}
