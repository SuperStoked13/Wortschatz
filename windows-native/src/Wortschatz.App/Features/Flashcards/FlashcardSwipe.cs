using Avalonia;
using Avalonia.Input;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Flashcards;

// Swiping a flashcard (Karteikarten), port of mac/Wortschatz/Features/Flashcards/FlashcardSwipe.swift: the current card
// follows two fingers on the touchpad (horizontal scrolling) or a drag with the mouse, leaning a little and taking on
// the colour of the side it is heading for. Past FlashcardSwipe.Threshold the verdict settles on it (a seal) and
// letting go sorts it to that side, where it flies off from where it is; a quick flick sorts it too. Anything else
// springs it back.
//
// Windows: a precision touchpad sends horizontal wheel events without the Mac's gesture phases, so
// FlashcardScrollMonitor decides the axis from the first few events (like the Mac) and ends the gesture when no event
// came for a moment (EndDelay).

/// <summary>A mouse drag on the current card: where it has moved the card (from where it started), and when the button was let go.</summary>
public abstract record FlashcardDrag
{
    public sealed record Changed(double Translation, double At) : FlashcardDrag;
    public sealed record Ended(double At) : FlashcardDrag;
}

/// <summary>The current card following a swipe. FlashcardsController owns it; FlashcardView reads it for the current card only.</summary>
public sealed class FlashcardSwipe
{
    /// <summary>The card the swipe belongs to (null: none since the last card change).</summary>
    public string? CardID { get; private set; }
    /// <summary>How far the fingers (or the mouse) have moved the card, + to the right, before the rubber band (Offset).</summary>
    public double Travel => _travel.Value;
    /// <summary>From the first movement until the card lies still again.</summary>
    public bool IsEngaged { get; private set; }
    /// <summary>The fingers (or the mouse button) are down.</summary>
    public bool IsTracking { get; private set; }

    /// <summary>Past this distance letting go sorts the card.</summary>
    public const double Threshold = 110;
    /// <summary>Beyond this the card follows more and more reluctantly.</summary>
    public const double FreeTravel = 170;
    /// <summary>A flick: where the card would be this many seconds after letting go decides.</summary>
    public const double Projection = 0.14;

    readonly AnimatedValue _travel = new();
    readonly List<(double Time, double Travel)> _samples = [];

    /// <summary>The card moved (every frame of a swipe or of its spring back).</summary>
    public event Action? Moved;
    /// <summary>The verdict a let-go would give changed (the seal comes or goes).</summary>
    public event Action? ArmedChanged;

    FlashcardVerdict? _lastArmed;

    public FlashcardSwipe() => _travel.Changed += () =>
    {
        Moved?.Invoke();
        // Every change of the travel (fingers, mouse, the spring back) can arm or disarm the verdict.
        if (Armed == _lastArmed) return;
        _lastArmed = Armed;
        ArmedChanged?.Invoke();
    };

    // MARK: Reading

    /// <summary>Where the card is drawn (+ to the right), with the rubber band past FreeTravel.</summary>
    public double Offset
    {
        get
        {
            double travel = Travel, distance = Math.Abs(travel);
            if (distance <= FreeTravel) return travel;
            double extra = distance - FreeTravel;
            return (travel < 0 ? -1 : 1) * (FreeTravel + extra * 0.4);
        }
    }

    /// <summary>The side the card would be sorted to if let go now (null: it would spring back).</summary>
    public FlashcardVerdict? Armed => Math.Abs(Offset) >= Threshold ? VerdictFor(Offset) : null;

    /// <summary>How far toward the threshold, -1 (Lerne ich noch) … 1 (Weiss ich).</summary>
    public double Lean => Math.Clamp(Offset / Threshold, -1, 1);

    /// <summary>The swipe of <paramref name="card"/> (0 for any other card).</summary>
    public double OffsetFor(string card) => CardID == card ? Offset : 0;

    public static FlashcardVerdict VerdictFor(double offset) => offset >= 0 ? FlashcardVerdict.Know : FlashcardVerdict.StillLearning;

    // MARK: Moving

    /// <summary>The fingers (or the mouse) start moving the card <paramref name="cardID"/>.</summary>
    public void Begin(string cardID, double time)
    {
        if (CardID != cardID) _travel.Jump(0);
        CardID = cardID;
        IsTracking = true;
        IsEngaged = true;
        _samples.Clear();
        _samples.Add((time, Travel));
    }

    /// <summary>Moves the card by <paramref name="delta"/> (touchpad scroll events).</summary>
    public void MoveBy(double delta, double time)
    {
        if (!IsTracking) return;
        Update(Travel + delta, time);
    }

    /// <summary>Moves the card to <paramref name="translation"/> (a mouse drag from where it started).</summary>
    public void MoveTo(double translation, double time)
    {
        if (!IsTracking) return;
        Update(translation, time);
    }

    /// <summary>The fingers lifted: the side to sort the card to, or null (then it springs back: Settle).</summary>
    public FlashcardVerdict? End(double time)
    {
        if (!IsTracking) return null;
        IsTracking = false;
        double projected = Travel + Velocity(time) * Projection;
        if (Math.Abs(Offset) >= Threshold) return VerdictFor(Offset);
        if (Math.Abs(projected) >= Threshold * 1.2 && Math.Abs(Travel) >= 16 && (projected < 0) == (Travel < 0)) return VerdictFor(projected);
        return null;
    }

    /// <summary>The card springs back to the middle.</summary>
    public void Settle()
    {
        IsTracking = false;
        if (CardID is null) return;
        var id = CardID;
        _travel.Set(0, Motion.ReduceMotion ? Motion.Fade : FlashcardMotion.SnapBack, () =>
        {
            if (CardID == id && !IsTracking) IsEngaged = false;
        });
    }

    /// <summary>Forgets the swipe (the card was sorted, or another card came).</summary>
    public void Reset()
    {
        if (CardID is null && Travel == 0 && !IsEngaged && !IsTracking) return;
        CardID = null;
        _travel.Jump(0);
        IsTracking = false;
        IsEngaged = false;
        _samples.Clear();
    }

    // MARK: Internals

    void Update(double travel, double time)
    {
        _travel.Jump(travel);
        _samples.Add((time, travel));
        _samples.RemoveAll(s => time - s.Time > 0.12);
    }

    /// <summary>Points per second over the last moments.</summary>
    double Velocity(double time)
    {
        if (_samples.Count == 0) return 0;
        var first = _samples[0];
        var last = _samples[^1];
        if (time - last.Time >= 0.08) return 0;
        double span = last.Time - first.Time;
        if (span <= 0.004) return 0;
        return (last.Travel - first.Travel) / span;
    }
}

/// <summary>
/// Two-finger swipes left and right on the touchpad move the current flashcard (Mac: FlashcardScrollMonitor). A gesture
/// that starts mostly sideways belongs to the card until the fingers lift; any other one scrolls as usual.
/// </summary>
public sealed class FlashcardScrollMonitor(FlashcardsController controller)
{
    enum Axis { Undecided, Horizontal, Vertical }

    /// <summary>A pause this long ends the gesture (Windows sends no "fingers lifted").</summary>
    const double EndDelay = 0.12;
    /// <summary>Points per wheel unit (Avalonia: 1 = one notch; touchpads send fractions).</summary>
    const double PointsPerUnit = 50;

    Axis _axis = Axis.Undecided;
    Vector _pending;
    double _lastEvent;
    int _serial;

    public bool IsEnabled { get; set; }

    /// <summary>Whether the wheel event moved the card (and must not scroll anything).</summary>
    public bool Handle(PointerWheelEventArgs e)
    {
        double now = Motion.Now();
        if (now - _lastEvent > EndDelay * 2 && _axis != Axis.Horizontal)
        {
            _axis = Axis.Undecided;
            _pending = default;
        }
        _lastEvent = now;
        // Avalonia: +X moves the content to the right (the fingers' way), so the card goes where scrolled content would.
        double dx = e.Delta.X * PointsPerUnit, dy = e.Delta.Y * PointsPerUnit;
        switch (_axis)
        {
            case Axis.Vertical:
                return false;
            case Axis.Horizontal:
                controller.SwipeMoved(dx, now);
                ScheduleEnd();
                return true;
            default:
                _pending += new Vector(dx, dy);
                if (Math.Abs(_pending.X) + Math.Abs(_pending.Y) < 6) return Math.Abs(_pending.X) > Math.Abs(_pending.Y);
                if (!IsEnabled || Math.Abs(_pending.X) <= Math.Abs(_pending.Y) * 1.2 || !controller.SwipeBegan(now))
                {
                    _axis = Axis.Vertical;
                    return false;
                }
                _axis = Axis.Horizontal;
                controller.SwipeMoved(_pending.X, now);
                ScheduleEnd();
                return true;
        }
    }

    /// <summary>Gives the card back (a popover opened mid-swipe, the screen went away).</summary>
    public void Cancel()
    {
        _serial++;
        if (_axis == Axis.Horizontal) controller.SwipeCancelled();
        _axis = Axis.Undecided;
        _pending = default;
    }

    void ScheduleEnd()
    {
        int serial = ++_serial;
        Motion.OnFrames(now =>
        {
            if (serial != _serial) return false;
            if (now - _lastEvent < EndDelay) return true;
            _axis = Axis.Undecided;
            _pending = default;
            controller.SwipeEnded(now);
            return false;
        });
    }
}
