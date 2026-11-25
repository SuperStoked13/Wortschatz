using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>Issue #5: the window after a monitor is unplugged or the scaling changes.</summary>
public class WindowFitTests
{
    // Laptop 1920 × 1080 at 150 % with the taskbar below; external monitor 2560 × 1440 to its right.
    static readonly PixelBox Laptop = new(0, 0, 1920, 1032);
    static readonly PixelBox External = new(1920, 0, 2560, 1392);

    [Fact]
    public void AWindowWhollyOnOneScreenIsCovered() =>
        Assert.True(WindowFit.IsCovered(new PixelBox(100, 100, 1200, 800), [Laptop, External]));

    [Fact]
    public void AWindowSpreadOverTwoScreensIsCovered() =>
        Assert.True(WindowFit.IsCovered(new PixelBox(1500, 100, 1200, 800), [Laptop, External]));

    [Fact]
    public void AfterUnpluggingTheWindowOnTheGoneScreenIsNotCovered()
    {
        Assert.False(WindowFit.IsCovered(new PixelBox(1500, 100, 1200, 800), [Laptop]));
        Assert.False(WindowFit.IsCovered(new PixelBox(2200, 100, 1200, 800), [Laptop]));
    }

    [Fact]
    public void AWindowScaledLargerThanTheLaptopIsNotCovered() =>
        // 1600 × 1000 at 100 % on the monitor, Windows scales it by 1.5 when it lands on the laptop.
        Assert.False(WindowFit.IsCovered(new PixelBox(0, 0, 2400, 1500), [Laptop]));

    [Fact]
    public void TooLargeIsShrunkToTheWorkingArea() =>
        Assert.Equal(Laptop, WindowFit.FitInto(new PixelBox(-30, 40, 2400, 1500), Laptop));

    [Fact]
    public void PartlyOffIsMovedInWithoutChangingTheSize() =>
        Assert.Equal(new PixelBox(720, 100, 1200, 800), WindowFit.FitInto(new PixelBox(1500, 100, 1200, 800), Laptop));

    [Fact]
    public void AboveTheTopOrLeftOfTheScreenIsMovedDown() =>
        Assert.Equal(new PixelBox(0, 0, 1200, 800), WindowFit.FitInto(new PixelBox(-400, -50, 1200, 800), Laptop));

    [Fact]
    public void AFittingWindowStaysWhereItIs()
    {
        var window = new PixelBox(300, 120, 1200, 800);
        Assert.Equal(window, WindowFit.FitInto(window, Laptop));
    }

    [Fact]
    public void FitsIntoAMonitorThatIsNotAtTheOrigin() =>
        Assert.Equal(new PixelBox(1920, 0, 2560, 1392), WindowFit.FitInto(new PixelBox(1000, -100, 3000, 1600), External));

    [Fact]
    public void AMaximisedWindowOverflowsOnlyBeyondTheBorder()
    {
        var monitor = new PixelBox(0, 0, 1920, 1080);
        Assert.False(WindowFit.MaximizedOverflows(new PixelBox(-12, -12, 1944, 1056), monitor, 24));
        Assert.True(WindowFit.MaximizedOverflows(new PixelBox(-12, -12, 2560, 1392), monitor, 24));
    }

    [Fact]
    public void TheMinimumSizeNeverExceedsTheScreen()
    {
        Assert.Equal((980, 640), WindowFit.MinimumSize(980, 640, 1280, 688));
        // 1920 × 1032 pixels at 175 %.
        Assert.Equal((980, 589), WindowFit.MinimumSize(980, 640, 1097.1, 589.7));
    }
}
