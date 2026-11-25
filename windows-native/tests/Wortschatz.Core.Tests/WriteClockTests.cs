using Wortschatz.Core;
using Xunit;
using Event = Wortschatz.Core.WriteFlow.Event;

namespace Wortschatz.Core.Tests;

// The study clock of Schreiben (Mac: WriteController.runClock/markActive) and the input-method rule of "any key
// continues" (Mac: LearnKeyRouter.continuing).
public class WriteClockTests
{
    const double Tick = WriteFlow.ClockTickMs;

    [Fact]
    public void TicksWhileTheLearnerIsActive()
    {
        var clock = new WriteClock(0);
        Assert.True(clock.Tick(Tick));
        Assert.False(clock.Activity(Tick + 1000));
        Assert.True(clock.Tick(2 * Tick));
        Assert.False(clock.IsIdle);
    }

    [Fact]
    public void PausesAfterTwoMinutesWithoutInputUntilTheNextInput()
    {
        var clock = new WriteClock(0);
        double t = 0;
        while (t < WriteFlow.ClockIdleMs)
        {
            t += Tick;
            Assert.True(clock.Tick(t));
        }
        Assert.False(clock.IsIdle);
        // The tick past the limit still saves, then the clock waits.
        t += Tick;
        Assert.True(clock.Tick(t));
        Assert.True(clock.IsIdle);
        Assert.False(clock.Tick(t + Tick));
        Assert.False(clock.Tick(t + 10 * Tick));
        // The next input resumes it (ClockResumed), once.
        Assert.True(clock.Activity(t + 11 * Tick));
        Assert.False(clock.Activity(t + 11 * Tick + 10));
        Assert.True(clock.Tick(t + 12 * Tick));
    }

    [Fact]
    public void NoTicksWhileTheWindowIsInactiveAndActivationResumes()
    {
        var clock = new WriteClock(0);
        clock.WindowActivityChanged(false, 1000);
        Assert.False(clock.Tick(Tick));
        // Away for longer than the idle limit: coming back counts as activity.
        clock.WindowActivityChanged(true, WriteFlow.ClockIdleMs * 3);
        Assert.True(clock.Tick(WriteFlow.ClockIdleMs * 3 + Tick));
        Assert.False(clock.IsIdle);
    }

    [Fact]
    public void UserActivityEvents()
    {
        Assert.True(WriteClock.IsUserActivity(new Event.InputChanged("a")));
        Assert.True(WriteClock.IsUserActivity(new Event.Key(KeyInput.Return)));
        Assert.True(WriteClock.IsUserActivity(new Event.ToggleStar()));
        Assert.False(WriteClock.IsUserActivity(new Event.ClockTick()));
        Assert.False(WriteClock.IsUserActivity(new Event.ClockResumed()));
        Assert.False(WriteClock.IsUserActivity(new Event.AutoAdvanceFired(3)));
        Assert.False(WriteClock.IsUserActivity(new Event.SetDeleted()));
    }

    // Lernen uses the same clock since 24.11.2026 (Mac: LearnController.isUserActivity).
    [Fact]
    public void UserActivityEventsOfLernen()
    {
        Assert.True(WriteClock.IsUserActivity(new LearnFlow.Event.DraftChanged("a")));
        Assert.True(WriteClock.IsUserActivity(new LearnFlow.Event.Key(KeyInput.Return)));
        Assert.True(WriteClock.IsUserActivity(new LearnFlow.Event.Choose(0)));
        Assert.True(WriteClock.IsUserActivity(new LearnFlow.Event.OverlayPresented(LearnFlow.Overlay.Options)));
        Assert.False(WriteClock.IsUserActivity(new LearnFlow.Event.Highlight(1)));
        Assert.False(WriteClock.IsUserActivity(new LearnFlow.Event.Tick()));
        Assert.False(WriteClock.IsUserActivity(new LearnFlow.Event.Resume()));
        Assert.False(WriteClock.IsUserActivity(new LearnFlow.Event.AutoAdvanceFired(3)));
        Assert.False(WriteClock.IsUserActivity(new LearnFlow.Event.ProgressChanged()));
        Assert.False(WriteClock.IsUserActivity(new LearnFlow.Event.OptionsChanged(StudyOptions.Default)));
    }

    [Fact]
    public void ContinuingTurnsALetterIntoSpaceOnlyWithAnInputMethodAfterAnAnswer()
    {
        var n = KeyInput.Character("n");
        Assert.Equal(KeyInput.Character(" "), LearnKeyRouter.Continuing(n, afterAnswer: true, () => true));
        Assert.Equal(n, LearnKeyRouter.Continuing(n, afterAnswer: true, () => false));
        Assert.Equal(n, LearnKeyRouter.Continuing(n, afterAnswer: false, () => true));
        Assert.Equal(KeyInput.DigitKey(2), LearnKeyRouter.Continuing(KeyInput.DigitKey(2), afterAnswer: true, () => true));
        bool asked = false;
        LearnKeyRouter.Continuing(KeyInput.Return, afterAnswer: true, () => asked = true);
        Assert.False(asked);
    }
}
