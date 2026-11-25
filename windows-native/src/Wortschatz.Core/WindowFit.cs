namespace Wortschatz.Core;

/// <summary>A rectangle in screen pixels (left, top, width, height).</summary>
public readonly record struct PixelBox(int X, int Y, int Width, int Height)
{
    public int Right => X + Width;
    public int Bottom => Y + Height;
    public long Area => Width <= 0 || Height <= 0 ? 0 : (long)Width * Height;

    public PixelBox Intersect(PixelBox other)
    {
        int x = Math.Max(X, other.X), y = Math.Max(Y, other.Y);
        int r = Math.Min(Right, other.Right), b = Math.Min(Bottom, other.Bottom);
        return r <= x || b <= y ? default : new PixelBox(x, y, r - x, b - y);
    }

    public bool Contains(PixelBox other) =>
        other.X >= X && other.Y >= Y && other.Right <= Right && other.Bottom <= Bottom;
}

/// <summary>
/// Keeps the main window on screen (Windows app, GitHub issue #5): after a monitor is unplugged or the scaling changes,
/// Windows moves the window and scales its size with the new DPI, so it can end up larger than the remaining screen or
/// partly off it. The window app measures; these pure rules decide where the window goes.
/// </summary>
public static class WindowFit
{
    /// <summary>
    /// Whether every pixel of <paramref name="window"/> lies on some screen's working area. Monitors never overlap, so
    /// the covered parts simply add up; a window spread over two screens counts as covered.
    /// </summary>
    public static bool IsCovered(PixelBox window, IEnumerable<PixelBox> workingAreas)
    {
        if (window.Area == 0) return true;
        long covered = 0;
        foreach (var area in workingAreas) covered += window.Intersect(area).Area;
        return covered >= window.Area;
    }

    /// <summary>
    /// <paramref name="window"/> moved (and shrunk only where it is larger) so it lies wholly in <paramref name="area"/>.
    /// A window that already fits stays where it is.
    /// </summary>
    public static PixelBox FitInto(PixelBox window, PixelBox area)
    {
        int width = Math.Min(window.Width, area.Width);
        int height = Math.Min(window.Height, area.Height);
        int x = Math.Clamp(window.X, area.X, area.Right - width);
        int y = Math.Clamp(window.Y, area.Y, area.Bottom - height);
        return new PixelBox(x, y, width, height);
    }

    /// <summary>
    /// Whether a maximised window has the wrong size for its screen (it was maximised on another monitor and Windows
    /// only scaled it): larger than the monitor by more than the invisible border Windows adds around maximised windows.
    /// </summary>
    public static bool MaximizedOverflows(PixelBox window, PixelBox monitor, int border) =>
        window.Width > monitor.Width + 2 * border || window.Height > monitor.Height + 2 * border;

    /// <summary>
    /// The smallest window size the app allows on a screen whose working area is <paramref name="areaWidth"/> ×
    /// <paramref name="areaHeight"/> (device-independent units): the app's usual minimum, but never more than the
    /// screen, so a window can always be made to fit (a small screen at a high scaling).
    /// </summary>
    public static (double Width, double Height) MinimumSize(double usualWidth, double usualHeight, double areaWidth, double areaHeight) =>
        (Math.Max(200, Math.Min(usualWidth, Math.Floor(areaWidth))), Math.Max(200, Math.Min(usualHeight, Math.Floor(areaHeight))));
}
