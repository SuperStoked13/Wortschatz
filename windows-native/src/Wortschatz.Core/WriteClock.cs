namespace Wortschatz.Core;

/// <summary>
/// The study clock of Schreiben (Mac: WriteController.runClock / markActive / windowActivityChanged; web:
/// write-clock.js): the time counts only while the window is active and the learner did something in the last
/// <see cref="WriteFlow.ClockIdleMs"/>. The controller asks it on every periodic tick whether to send
/// <see cref="WriteFlow.Event.ClockTick"/>, reports every event of the learner (<see cref="Activity"/>: a paused clock
/// resumes with <see cref="WriteFlow.Event.ClockResumed"/>) and the window's activity.
/// </summary>
public sealed class WriteClock
{
    double _lastActivity;

    public WriteClock(double now) => _lastActivity = now;

    /// <summary>No input for longer than ClockIdleMs: the clock waits for the next input.</summary>
    public bool IsIdle { get; private set; }

    public bool IsWindowActive { get; private set; } = true;

    /// <summary>
    /// A periodic tick (every ClockTickMs): true when the study clock is to be saved now. The tick that finds the
    /// learner idle for longer than ClockIdleMs still saves, then the clock pauses (Mac: runClock).
    /// </summary>
    public bool Tick(double now)
    {
        if (!IsWindowActive || IsIdle) return false;
        if (now - _lastActivity > WriteFlow.ClockIdleMs) IsIdle = true;
        return true;
    }

    /// <summary>An event of the learner (Mac: markActive): true when the paused clock resumes now (send ClockResumed).</summary>
    public bool Activity(double now)
    {
        _lastActivity = now;
        if (!IsIdle) return false;
        IsIdle = false;
        return true;
    }

    /// <summary>The window became active (the clock runs again from now) or inactive (no ticks).</summary>
    public void WindowActivityChanged(bool active, double now)
    {
        IsWindowActive = active;
        if (!active) return;
        _lastActivity = now;
        IsIdle = false;
    }

    /// <summary>Events that come from the learner (they keep the study clock running; Mac: Event.isUserActivity).</summary>
    public static bool IsUserActivity(WriteFlow.Event e) => e is not (WriteFlow.Event.AutoAdvanceFired or WriteFlow.Event.SetChanged
        or WriteFlow.Event.CardsChanged or WriteFlow.Event.SetDeleted or WriteFlow.Event.ClockTick or WriteFlow.Event.ClockResumed
        or WriteFlow.Event.OptionsChanged);
}

/// <summary>Key handling shared by the study screens (Mac: LearnKeyRouter.swift, the parts without AppKit).</summary>
public static class LearnKeyRouter
{
    /// <summary>
    /// "Any key continues" after an answer: with an input method active (Pinyin, Zhuyin, Kana …) the letter only begins
    /// a composition, so the key continues like the space bar and its raw letter never lands in the next answer field;
    /// the answer is then typed there with the input method. Every other key, and every key without an input method,
    /// stays (Mac: LearnKeyRouter.continuing).
    /// </summary>
    public static KeyInput Continuing(KeyInput input, bool afterAnswer, Func<bool> inputMethod)
    {
        if (!afterAnswer || input.Kind != KeyKind.Character || input.Text == " " || !inputMethod()) return input;
        return KeyInput.Character(" ");
    }
}
