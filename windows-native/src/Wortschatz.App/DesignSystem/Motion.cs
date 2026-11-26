using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;

namespace Wortschatz.App.DesignSystem;

// Port of the Motion presets in mac/Wortschatz/DesignSystem/Metrics.swift plus the little engine SwiftUI gives the Mac
// for free: timing curves and springs (Curve), values that glide to a new target frame by frame (AnimatedValue) and
// the frame loop that drives them (Motion.Frame). Views compute their transforms from animated values the way the
// Mac's Animatable modifiers do (FaceTurn, GlideEffect …): every frame only recomputes a few transforms, the content
// is built once.
//
// The clock is Motion.Now (seconds). The snapshot tool replaces it to render a frozen moment of an animation.
// Reduce Motion: Windows' "Animationseffekte" (Einstellungen → Barrierefreiheit → Visuelle Effekte); when they are
// off, Motion.ReduceMotion is true and views fade instead of moving, like the Mac under "Bewegung reduzieren".

/// <summary>
/// An animation curve (Mac: SwiftUI.Animation): how far a change has come (0 … 1, a spring may overshoot) after
/// <c>elapsed</c> seconds, including its delay.
/// </summary>
public sealed class Curve
{
    readonly Func<double, double> _ease;

    Curve(double duration, Func<double, double> ease, double delay)
    {
        Duration = duration;
        _ease = ease;
        Delay = delay;
    }

    /// <summary>Seconds from start (after the delay) to rest.</summary>
    public double Duration { get; }
    public double Delay { get; }
    public double Total => Delay + Duration;

    /// <summary>Progress after <paramref name="elapsed"/> seconds since the change (0 during the delay, 1 at rest).</summary>
    public double At(double elapsed)
    {
        double t = elapsed - Delay;
        if (t <= 0) return 0;
        if (t >= Duration) return 1;
        return _ease(t / Duration);
    }

    public Curve Delayed(double delay) => new(Duration, _ease, Delay + delay);

    /// <summary>SwiftUI's <c>.timingCurve(x1, y1, x2, y2, duration:)</c> (a CSS cubic-bezier).</summary>
    public static Curve Bezier(double x1, double y1, double x2, double y2, double duration)
    {
        var bezier = new CubicBezier(x1, y1, x2, y2);
        return new Curve(duration, bezier.Solve, 0);
    }

    public static Curve EaseOut(double duration) => Bezier(0, 0, 0.58, 1, duration);
    public static Curve EaseInOut(double duration) => Bezier(0.42, 0, 0.58, 1, duration);

    /// <summary>
    /// SwiftUI's <c>.spring(response:dampingFraction:)</c>: a damped spring from 0 to 1 (overshoots when the damping is
    /// below 1). The curve ends when the spring is within a thousandth of its target.
    /// </summary>
    public static Curve Spring(double response, double dampingFraction)
    {
        double omega = 2 * Math.PI / Math.Max(0.01, response);
        double zeta = Math.Clamp(dampingFraction, 0.05, 1);
        double settle = Math.Log(1000) / (zeta * omega);
        Func<double, double> position;
        if (zeta >= 0.999)
            position = t => 1 - Math.Exp(-omega * t) * (1 + omega * t);
        else
        {
            double wd = omega * Math.Sqrt(1 - zeta * zeta);
            position = t => 1 - Math.Exp(-zeta * omega * t) * (Math.Cos(wd * t) + zeta * omega / wd * Math.Sin(wd * t));
        }
        return new Curve(settle, u => position(u * settle), 0);
    }

    /// <summary>SwiftUI's <c>.spring(duration:bounce:)</c> (also <c>.smooth</c> = bounce 0, <c>.snappy</c> = 0.15).</summary>
    public static Curve SpringDuration(double duration, double bounce) => Spring(duration, 1 - Math.Clamp(bounce, 0, 0.95));

    /// <summary>Unit cubic Bézier y(x), solved for x with Newton's method and bisection (like WebKit's UnitBezier).</summary>
    sealed class CubicBezier(double x1, double y1, double x2, double y2)
    {
        readonly double _cx = 3 * x1, _bx = 3 * (x2 - x1) - 3 * x1, _cy = 3 * y1, _by = 3 * (y2 - y1) - 3 * y1;
        double Ax => 1 - _cx - _bx;
        double Ay => 1 - _cy - _by;

        double X(double t) => ((Ax * t + _bx) * t + _cx) * t;
        double Y(double t) => ((Ay * t + _by) * t + _cy) * t;
        double DX(double t) => (3 * Ax * t + 2 * _bx) * t + _cx;

        public double Solve(double x)
        {
            double t = x;
            for (int i = 0; i < 8; i++)
            {
                double err = X(t) - x;
                if (Math.Abs(err) < 1e-6) return Y(t);
                double d = DX(t);
                if (Math.Abs(d) < 1e-6) break;
                t -= err / d;
            }
            double lo = 0, hi = 1;
            t = x;
            for (int i = 0; i < 40; i++)
            {
                double v = X(t);
                if (Math.Abs(v - x) < 1e-6) break;
                if (x > v) lo = t; else hi = t;
                t = (lo + hi) / 2;
            }
            return Y(t);
        }
    }
}

/// <summary>The Mac's animation presets (Metrics.swift, enum Motion) and the frame loop.</summary>
public static class Motion
{
    /// <summary>Default UI spring (state changes, selection).</summary>
    public static Curve Spring => Curve.Spring(0.38, 0.82);
    /// <summary>Snappy spring for small elements (badges, chips): <c>.snappy(duration: 0.25)</c>.</summary>
    public static Curve Snappy => Curve.SpringDuration(0.25, 0.15);
    /// <summary>Gentle spring for large surfaces (cards, banners).</summary>
    public static Curve Gentle => Curve.Spring(0.55, 0.86);
    /// <summary>Cross-fade used instead of movement under Reduce Motion.</summary>
    public static Curve Fade => Curve.EaseInOut(0.2);
    /// <summary>Content gliding into place while its screen fades in.</summary>
    public static Curve Glide => Curve.Spring(0.72, 0.9);

    /// <summary>Whole screens fading in or out: a gentle start and a long, soft landing.</summary>
    public static Curve Soft(double duration) => Curve.Bezier(0.4, 0, 0.2, 1, duration);
    /// <summary>Small things arriving (toasts): quick out of the gate, a long soft landing.</summary>
    public static Curve Arrive(double duration) => Curve.Bezier(0.22, 1, 0.36, 1, duration);
    /// <summary>Leaving: gathers pace and is gone (ease-in cubic).</summary>
    public static Curve Depart(double duration) => Curve.Bezier(0.32, 0, 0.67, 0, duration);

    /// <summary><paramref name="base"/>, or a plain cross-fade when Reduce Motion is on.</summary>
    public static Curve Animation(Curve @base) => ReduceMotion ? Fade : @base;

    // MARK: Clock and settings

    static readonly Stopwatch Watch = Stopwatch.StartNew();

    /// <summary>Seconds on the animation clock (the snapshot tool sets its own).</summary>
    public static Func<double> Now { get; set; } = () => Watch.Elapsed.TotalSeconds;

    static bool? _reduceMotion;
    static bool _reduceMotionForced;

    /// <summary>
    /// Windows' "Animationseffekte" are off (read at the start and again by <see cref="RefreshReduceMotion"/> whenever the
    /// window becomes active, so a change in the Windows settings works at once, like the Mac's Reduce Motion; the
    /// snapshot tool can set it).
    /// </summary>
    public static bool ReduceMotion
    {
        get => _reduceMotion ??= ReadReduceMotion();
        set
        {
            _reduceMotion = value;
            _reduceMotionForced = true;
        }
    }

    /// <summary>Reads Windows' animation setting again; true when it changed.</summary>
    public static bool RefreshReduceMotion()
    {
        if (_reduceMotionForced) return false;
        bool now = ReadReduceMotion();
        // Not read yet: nothing was drawn with the old value.
        if (_reduceMotion is null || _reduceMotion == now)
        {
            _reduceMotion = now;
            return false;
        }
        _reduceMotion = now;
        return true;
    }

    /// <summary>The snapshot tool renders frozen frames: decorative time-based animation (confetti) draws a still.</summary>
    public static bool IsSnapshot { get; set; }

    static bool ReadReduceMotion()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            int enabled = 1;
            // SPI_GETCLIENTAREAANIMATION: "Animationen in Windows anzeigen".
            return SystemParametersInfo(0x1042, 0, ref enabled, 0) && enabled == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint winIni);

    // MARK: Frame loop

    static readonly List<Func<double, bool>> Tickers = [];

    /// <summary>How many frame callbacks are waiting (diagnostics, the snapshot tool).</summary>
    public static int ActiveAnimations => Tickers.Count;
    static bool _frameRequested;
    /// <summary>Grows with every frame: a frame callback that arrives after a frame already ran (RunFrame called directly) does nothing.</summary>
    static int _frameSerial;

    /// <summary>The window whose frames drive the animations (MainWindow sets itself).</summary>
    public static TopLevel? Host { get; set; }

    /// <summary>
    /// Calls <paramref name="tick"/> once per frame with Motion.Now until it returns false. Frames come from the host
    /// window's compositor (vsync); without a host, from a 60 Hz dispatcher timer.
    /// </summary>
    public static void OnFrames(Func<double, bool> tick)
    {
        Tickers.Add(tick);
        RequestFrame();
    }

    static DispatcherTimer? _fallback;

    static void RequestFrame()
    {
        if (_frameRequested) return;
        _frameRequested = true;
        int serial = _frameSerial;
        if (Host is { } host) host.RequestAnimationFrame(_ =>
        {
            if (serial == _frameSerial) RunFrame();
        });
        else
        {
            _fallback ??= new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => RunFrame());
            _fallback.Start();
        }
    }

    /// <summary>Runs one frame now (the snapshot tool calls it after moving the clock).</summary>
    public static void RunFrame()
    {
        _frameRequested = false;
        _frameSerial++;
        _fallback?.Stop();
        double now = Now();
        var running = Tickers.ToArray();
        Tickers.Clear();
        foreach (var tick in running)
        {
            bool goOn;
            try
            {
                goOn = tick(now);
            }
            catch (Exception e)
            {
                // An animation that fails stops; the app goes on.
                Trace.WriteLine($"Motion: {e}");
                if (IsSnapshot) Console.Error.WriteLine($"Motion: {e}");
                goOn = false;
            }
            if (goOn) Tickers.Add(tick);
        }
        if (Tickers.Count > 0) RequestFrame();
    }

    /// <summary>Runs <paramref name="action"/> after <paramref name="seconds"/> on the animation clock.</summary>
    public static void After(double seconds, Action action)
    {
        double due = Now() + seconds;
        OnFrames(now =>
        {
            if (now < due) return true;
            action();
            return false;
        });
    }

    // MARK: Small helpers

    public static double Lerp(double a, double b, double t) => a + (b - a) * t;
    public static double Clamp01(double v) => Math.Clamp(v, 0, 1);
}

/// <summary>
/// A number that glides to its target (Mac: an animatable property inside <c>withAnimation</c>): Set starts from
/// where it is now, so a change mid-flight continues smoothly. Changed fires on every frame.
/// </summary>
public sealed class AnimatedValue
{
    double _from, _to, _start;
    Curve? _curve;
    int _serial;
    Action? _completed;

    public AnimatedValue(double value = 0)
    {
        _from = _to = Value = value;
    }

    /// <summary>The value on screen now.</summary>
    public double Value { get; private set; }
    public double Target => _to;

    public event Action? Changed;

    /// <summary>Moves to <paramref name="target"/> along <paramref name="curve"/> (null: at once).</summary>
    public void Set(double target, Curve? curve, Action? completed = null)
    {
        // Already there and at rest: the frames would only repeat the value (a fade-in also "moved" its unchanged
        // position and scale, every render of a study screen "animated" its unchanged progress). A completion still
        // waits for its curve.
        if (curve is not null && completed is null && _curve is null && Value == target) return;
        _serial++;
        _completed = null;
        if (curve is null || curve.Total <= 0)
        {
            _curve = null;
            _from = _to = Value = target;
            Changed?.Invoke();
            completed?.Invoke();
            return;
        }
        _from = Value;
        _to = target;
        _start = Motion.Now();
        _curve = curve;
        _completed = completed;
        int serial = _serial;
        Motion.OnFrames(now =>
        {
            if (serial != _serial) return false;
            double t = now - _start;
            if (t >= curve.Total)
            {
                Value = _to;
                _curve = null;
                Changed?.Invoke();
                var done = _completed;
                _completed = null;
                done?.Invoke();
                return false;
            }
            Value = Motion.Lerp(_from, _to, curve.At(t));
            Changed?.Invoke();
            return true;
        });
    }

    /// <summary>Jumps to <paramref name="value"/> without animation (cancels a running one).</summary>
    public void Jump(double value) => Set(value, null);
}

/// <summary>
/// Matrices for RenderTransform (Avalonia's row-vector convention: point × matrix). The origin is the control's
/// RenderTransformOrigin; Effects set it to the centre unless noted.
/// </summary>
public static class Matrices
{
    /// <summary>Scale, then rotate (degrees, around the origin), then move.</summary>
    public static Matrix Affine(double scale = 1, double rotate = 0, double x = 0, double y = 0, double scaleX = 1)
    {
        double r = rotate * Math.PI / 180;
        double c = Math.Cos(r), s = Math.Sin(r);
        double sx = scale * scaleX, sy = scale;
        return new Matrix(sx * c, sx * s, -sy * s, sy * c, x, y);
    }

    /// <summary>
    /// SwiftUI's <c>rotation3DEffect(angle, axis:, perspective:)</c> on a view of <paramref name="width"/> ×
    /// <paramref name="height"/>, followed by a scale and a move: a rotation around <paramref name="axis"/> (through the
    /// origin, in the view's plane), seen from a distance of max(width, height) / perspective.
    /// </summary>
    public static Matrix Rotate3D(double degrees, (double X, double Y, double Z) axis, double perspective, double width, double height,
        double scale = 1, double x = 0, double y = 0)
    {
        double len = Math.Sqrt(axis.X * axis.X + axis.Y * axis.Y + axis.Z * axis.Z);
        double ux = axis.X / len, uy = axis.Y / len, uz = axis.Z / len;
        double a = degrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a), t = 1 - c;
        // Rodrigues' rotation matrix (column vectors, y pointing down, z toward the viewer).
        double r00 = t * ux * ux + c, r01 = t * ux * uy - s * uz;
        double r10 = t * ux * uy + s * uz, r11 = t * uy * uy + c;
        double r20 = t * ux * uz - s * uy, r21 = t * uy * uz + s * ux;
        double d = Math.Max(width, height) / Math.Max(0.01, perspective);
        // [x y 1] × M = (x', y', w) with w = 1 − z'/d; then scale and move (in screen space, after the division).
        double m13 = -r20 / d, m23 = -r21 / d;
        return new Matrix(
            scale * r00 + x * m13, scale * r10 + y * m13, m13,
            scale * r01 + x * m23, scale * r11 + y * m23, m23,
            x, y, 1);
    }
}
