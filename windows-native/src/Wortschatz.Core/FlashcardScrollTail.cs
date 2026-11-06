namespace Wortschatz.Core;

/// <summary>
/// The tail of a touchpad gesture the card owned (Windows only, see FlashcardScrollMonitor in
/// the app): decides which of the wheel events that follow are still its inertia. Pure logic, times in seconds, deltas in points.
/// </summary>
public sealed class FlashcardScrollTail
{
    /// <summary>A pause this long ends the tail.</summary>
    public const double TailGap = 0.25;
    /// <summary>The tail is never longer than this (seconds after the gesture ended).</summary>
    public const double TailMax = 2.0;

    bool _active;
    double _started, _direction, _smallest;

    public bool IsActive => _active;

    /// <summary>The card's gesture ended at <paramref name="now"/>; it went toward <paramref name="direction"/> (+1/-1).</summary>
    public void Begin(double direction, double now)
    {
        _active = true;
        _started = now;
        _direction = direction;
        _smallest = double.PositiveInfinity;
    }

    public void Clear() => _active = false;

    /// <summary>
    /// Whether the event (<paramref name="gap"/>: seconds since the previous one) is still the tail and must be swallowed.
    /// The first event that is not ends the tail.
    /// </summary>
    public bool Swallows(double dx, double dy, double now, double gap)
    {
        if (!_active) return false;
        double size = Math.Abs(dx);
        bool reversed = _direction != 0 && size >= 2 && Math.Sign(dx) == -_direction;
        bool vertical = Math.Abs(dy) >= 4 && Math.Abs(dy) > size * 2;
        // Inertia only decays; fingers that push again start small and grow.
        bool grows = !double.IsPositiveInfinity(_smallest) && size > Math.Max(4, _smallest * 2);
        if (gap >= TailGap || now - _started >= TailMax || reversed || vertical || grows)
        {
            _active = false;
            return false;
        }
        if (size >= 0.5) _smallest = Math.Min(_smallest, size);
        return true;
    }
}
