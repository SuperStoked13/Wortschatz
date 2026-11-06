using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>The tail of a touchpad swipe on a flashcard (Windows): inertia is swallowed, a new gesture is not.</summary>
public class FlashcardScrollTailTests
{
    static FlashcardScrollTail Started(double direction = 1)
    {
        var tail = new FlashcardScrollTail();
        tail.Begin(direction, 10);
        return tail;
    }

    [Fact]
    public void InactiveTailSwallowsNothing()
    {
        var tail = new FlashcardScrollTail();
        Assert.False(tail.Swallows(20, 0, 10, 0.01));
    }

    [Fact]
    public void DecayingInertiaIsSwallowedUntilAPause()
    {
        var tail = Started();
        double t = 10;
        foreach (var dx in new[] { 18.0, 15, 12, 9, 7, 5, 3, 2, 1, 1 })
        {
            t += 0.016;
            Assert.True(tail.Swallows(dx, 0.3, t, 0.016));
        }
        // After a pause the next event is a new gesture.
        Assert.False(tail.Swallows(3, 0, t + FlashcardScrollTail.TailGap, FlashcardScrollTail.TailGap));
        Assert.False(tail.IsActive);
        Assert.False(tail.Swallows(3, 0, t + 0.3, 0.01));
    }

    [Fact]
    public void ATurnEndsTheTail()
    {
        var tail = Started(direction: 1);
        Assert.True(tail.Swallows(10, 0, 10.016, 0.016));
        Assert.False(tail.Swallows(-3, 0, 10.032, 0.016));
        Assert.False(tail.IsActive);
    }

    [Fact]
    public void TheTailOfALeftSwipeGoesLeft()
    {
        var tail = Started(direction: -1);
        Assert.True(tail.Swallows(-10, 0, 10.016, 0.016));
        Assert.True(tail.Swallows(-6, 0, 10.032, 0.016));
        Assert.False(tail.Swallows(4, 0, 10.048, 0.016));
    }

    [Fact]
    public void FingersPushingAgainEndTheTail()
    {
        var tail = Started();
        Assert.True(tail.Swallows(12, 0, 10.016, 0.016));
        Assert.True(tail.Swallows(4, 0, 10.032, 0.016));
        Assert.True(tail.Swallows(2, 0, 10.048, 0.016));
        // Growing again: not inertia.
        Assert.True(tail.Swallows(4, 0, 10.064, 0.016));
        Assert.False(tail.Swallows(6, 0, 10.080, 0.016));
    }

    [Fact]
    public void ScrollingUpOrDownEndsTheTail()
    {
        var tail = Started();
        Assert.True(tail.Swallows(8, 0, 10.016, 0.016));
        Assert.False(tail.Swallows(1, 12, 10.032, 0.016));
    }

    [Fact]
    public void TheTailEndsAfterTailMax()
    {
        var tail = Started();
        double t = 10;
        while (t < 10 + FlashcardScrollTail.TailMax - 0.02)
        {
            t += 0.016;
            Assert.True(tail.Swallows(1, 0, t, 0.016));
        }
        Assert.False(tail.Swallows(1, 0, 10 + FlashcardScrollTail.TailMax, 0.016));
    }

    [Fact]
    public void ClearEndsTheTail()
    {
        var tail = Started();
        tail.Clear();
        Assert.False(tail.Swallows(5, 0, 10.016, 0.016));
    }
}
