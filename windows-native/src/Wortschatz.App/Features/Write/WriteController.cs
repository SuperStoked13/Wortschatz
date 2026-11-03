using Avalonia.Threading;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Write;

/// <summary>
/// Runs one Write screen (Mac: WriteController.swift): holds the WriteFlow state, reduces events with the stored
/// progress and performs the effects (store writes, speech, toasts, the auto-advance timer, navigation).
/// </summary>
public sealed class WriteController
{
    readonly AppModel _model;
    readonly StudyRequest _request;
    readonly RNG _rng;
    readonly Dictionary<int, DispatcherTimer> _timers = [];
    DispatcherTimer? _clockTimer;
    List<WriteFlow.Effect> _pendingStart;
    bool _active, _windowActive = true;

    public string SetId => _request.SetId;
    public WriteFlow.State State { get; private set; }
    /// <summary>Correct answers in a row while this screen is open (the flame in the status pill).</summary>
    public Learn.AnswerStreak Streak { get; } = new();
    /// <summary>The auto-advance that is running (the line in the status pill); compare its token with State.AutoAdvance.</summary>
    public Study.StudyCountdown? Countdown { get; private set; }

    public event Action? Changed;

    public WriteController(AppModel model, StudyRequest request, RNG? rng = null)
    {
        _model = model;
        _request = request;
        _rng = rng ?? Rand.SystemRNG();
        var store = model.Store;
        var (state, effects) = WriteFlow.Start(store.GetSet(request.SetId), store.GetStudyOptions(request.SetId), store.GetSessionJSON(request.SetId), Env(),
            request.Subset, request.ForceNew);
        State = state;
        _pendingStart = effects;
    }

    WriteFlow.Env Env() => new(TimeUtil.NowMs(), _rng, _model.Store.GetProgress(SetId));

    public void Activate()
    {
        _active = true;
        var effects = _pendingStart;
        _pendingStart = [];
        Perform(effects);
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(WriteFlow.ClockTickMs) };
        _clockTimer.Tick += (_, _) =>
        {
            if (_windowActive && WriteFlow.IsStudying(State)) Send(new WriteFlow.Event.ClockTick());
        };
        _clockTimer.Start();
    }

    public void Deactivate()
    {
        if (!_active) return;
        if (WriteFlow.IsStudying(State)) Reduce(new WriteFlow.Event.ClockTick());
        _active = false;
        foreach (var t in _timers.Values) t.Stop();
        _timers.Clear();
        _clockTimer?.Stop();
        _model.Speech.Stop();
    }

    public void WindowActivityChanged(bool active)
    {
        _windowActive = active;
        if (WriteFlow.IsStudying(State)) Send(active ? new WriteFlow.Event.ClockResumed() : new WriteFlow.Event.ClockTick());
    }

    public void Send(WriteFlow.Event e)
    {
        if (_active) Reduce(e);
    }

    void Reduce(WriteFlow.Event e)
    {
        var previous = State.Phase.Kind;
        var (next, effects) = WriteFlow.Reduce(State, e, Env());
        State = next;
        Perform(effects);
        PlaySound(effects, previous);
        if (e is not WriteFlow.Event.InputChanged) Changed?.Invoke();
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
                    store.RecordAnswer(SetId, r.CardId, r.Correct, r.At);
                    Streak.Record(r.Correct);
                    break;
                case WriteFlow.Effect.OverrideLastAnswer o:
                    store.OverrideLastAnswer(SetId, o.CardId);
                    Streak.OverrideMiss();
                    break;
                case WriteFlow.Effect.SaveSession s:
                    store.SaveSessionJSON(SetId, WriteFlow.StoredJSON(s.Session, s.Feedback));
                    break;
                case WriteFlow.Effect.Speak s:
                    _model.Speech.Speak(s.Text, s.Lang);
                    break;
                case WriteFlow.Effect.ScheduleAutoAdvance a:
                    Schedule(a.Ms, a.Token);
                    break;
                case WriteFlow.Effect.UpdateCard u:
                    store.UpdateCard(SetId, u.Card.Id, new CardChanges(u.Card.Term, u.Card.Definition));
                    break;
                case WriteFlow.Effect.ToggleStar t:
                    store.ToggleStar(SetId, t.CardId);
                    break;
                case WriteFlow.Effect.ShowToast t:
                    _model.ShowToast(new ToastMessage(t.Toast.Message(), t.Toast.IsSuccess() ? ToastTone.Success : ToastTone.Neutral, DurationMs: t.Toast.DurationMs() ?? ToastMessage.DefaultDuration));
                    break;
                case WriteFlow.Effect.EditSet:
                    Dispatcher.UIThread.Post(() => _model.Navigate(new Route.Editor(SetId)));
                    break;
                case WriteFlow.Effect.Exit:
                    Dispatcher.UIThread.Post(() => _model.BackToSet(SetId));
                    break;
            }
        }
        _model.SaveSoon();
    }

    void Schedule(int ms, int token)
    {
        Countdown = new Study.StudyCountdown(token, ms, DesignSystem.Motion.Now());
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
