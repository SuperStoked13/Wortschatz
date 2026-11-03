using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// A confetti burst for finished rounds and sets (Mac: Celebration.swift, "celebration … particles, Reduce Motion safe").
/// It plays when it is attached (if PlaysOnAttach) and on every Play(). Under Reduce Motion nothing flies: a soft accent
/// glow fades in and out instead. Purely decorative: no hit testing. The snapshot tool draws one representative frame.
/// </summary>
public sealed class CelebrationView : Control
{
    /// <summary>Where the burst starts, in unit coordinates of the view.</summary>
    public Point Origin { get; init; } = new(0.5, 0.42);
    public int ParticleCount { get; init; } = 120;
    public bool PlaysOnAttach { get; init; } = true;

    double _start = double.NaN;
    ulong _seed = 1;
    int _serial;

    public CelebrationView()
    {
        IsHitTestVisible = false;
        ClipToBounds = false;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (PlaysOnAttach) Play(1);
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _serial++;
    }

    /// <summary>Starts a burst (seed: which confetti).</summary>
    public void Play(ulong seed)
    {
        _seed = seed;
        _start = Motion.Now();
        int serial = ++_serial;
        InvalidateVisual();
        if (Motion.IsSnapshot) return;
        Motion.OnFrames(now =>
        {
            if (serial != _serial) return false;
            InvalidateVisual();
            if (now - _start <= Confetti.Duration + 0.1) return true;
            _start = double.NaN;
            InvalidateVisual();
            return false;
        });
    }

    public override void Render(DrawingContext context)
    {
        var size = Bounds.Size;
        if (Motion.IsSnapshot)
        {
            Confetti.Draw(context, size, Origin, 0.55, 7, ParticleCount);
            return;
        }
        if (double.IsNaN(_start)) return;
        double t = Motion.Now() - _start;
        if (Motion.ReduceMotion) Glow(context, size, t);
        else Confetti.Draw(context, size, Origin, t, _seed, ParticleCount);
    }

    /// <summary>Reduce Motion: an opacity-only glow, no movement.</summary>
    void Glow(DrawingContext context, Size size, double t)
    {
        double opacity = t < 0.4 ? t / 0.4 : Math.Max(0, 1 - (t - 0.4) / 1.4);
        if (opacity <= 0) return;
        var p = WsTheme.P;
        var brush = new RadialGradientBrush
        {
            Center = new RelativePoint(Origin.X, Origin.Y, RelativeUnit.Relative),
            GradientOrigin = new RelativePoint(Origin.X, Origin.Y, RelativeUnit.Relative),
            RadiusX = new RelativeScalar(420, RelativeUnit.Absolute),
            RadiusY = new RelativeScalar(420, RelativeUnit.Absolute),
            GradientStops =
            {
                new GradientStop(Palette.Hex(Ui.Rgb(p.Accent), 0.28), 0),
                new GradientStop(Palette.Hex(Ui.Rgb(p.Mastered.Fill), 0.10), 0.5),
                new GradientStop(Colors.Transparent, 1),
            },
        };
        using var _ = context.PushOpacity(opacity);
        context.FillRectangle(brush, new Rect(size));
    }
}

/// <summary>Deterministic confetti physics (closed form, so any frame can be drawn directly). Mac: enum Confetti.</summary>
static class Confetti
{
    public const double Duration = 2.8;
    const double Gravity = 980;
    const double Drag = 1.6;

    enum Shape { Ribbon, Dot, Sparkle }

    readonly record struct Particle(double Angle, double Speed, double Width, double Height, double Spin, double Flip, double Phase, int ColorIndex, Shape Shape);

    static Color[] Colors()
    {
        var p = WsTheme.P;
        return [p.Accent, p.Mastered.Fill, p.Learning.Fill, p.Star, Palette.Hex(0xFF6FA8), Palette.Hex(0x2BB3C0), Palette.Hex(0x9D6BFF)];
    }

    static List<Particle> Particles(ulong seed, int count, int colorCount)
    {
        var rng = new SplitMix64(seed);
        var list = new List<Particle>(count);
        for (int i = 0; i < count; i++)
        {
            double roll = rng.Next();
            var shape = roll < 0.68 ? Shape.Ribbon : roll < 0.9 ? Shape.Dot : Shape.Sparkle;
            double width = shape == Shape.Ribbon ? rng.Next(7, 12) : rng.Next(5, 9);
            // Mostly upwards, fanned out to both sides.
            double angle = -Math.PI / 2 + (rng.Next() - 0.5) * Math.PI * 1.15;
            double speed = rng.Next(420, 980);
            double height = shape == Shape.Ribbon ? width * rng.Next(0.38, 0.6) : width;
            list.Add(new Particle(angle, speed, width, height, rng.Next(-7, 7), rng.Next(5, 11), rng.Next(0, 2 * Math.PI), i % colorCount, shape));
        }
        return list;
    }

    public static void Draw(DrawingContext context, Size size, Point origin, double t, ulong seed, int count)
    {
        if (t < 0 || t > Duration) return;
        var colors = Colors();
        double ox = origin.X * size.Width, oy = origin.Y * size.Height;
        // Integrated velocity with linear drag: v·(1 − e^(−k·t))/k, plus gravity.
        double travel = (1 - Math.Exp(-Drag * t)) / Drag;
        double fade = t > Duration - 0.7 ? Math.Max(0, (Duration - t) / 0.7) : 1;
        using var opacity = context.PushOpacity(fade);
        foreach (var particle in Particles(seed, count, colors.Length))
        {
            double x = ox + Math.Cos(particle.Angle) * particle.Speed * travel;
            double y = oy + Math.Sin(particle.Angle) * particle.Speed * travel + 0.5 * Gravity * t * t * 0.55;
            if (y >= size.Height + 40) continue;
            var brush = new SolidColorBrush(colors[particle.ColorIndex]);
            double rotation = particle.Phase + particle.Spin * t;
            var m = Matrix.CreateRotation(rotation) * Matrix.CreateTranslation(x, y);
            switch (particle.Shape)
            {
                case Shape.Ribbon:
                    // Fake 3-D tumbling by squashing one axis.
                    double squash = Math.Max(0.08, Math.Abs(Math.Cos(particle.Phase + particle.Flip * t)));
                    using (context.PushTransform(Matrix.CreateScale(squash, 1) * m))
                        context.DrawRectangle(brush, null, new RoundedRect(new Rect(-particle.Width / 2, -particle.Height / 2, particle.Width, particle.Height), particle.Height * 0.3));
                    break;
                case Shape.Dot:
                    using (context.PushTransform(m))
                        context.DrawEllipse(brush, null, new Point(0, 0), particle.Width / 2, particle.Width / 2);
                    break;
                default:
                    using (context.PushTransform(m))
                        context.DrawGeometry(brush, null, Sparkle(particle.Width * 0.8));
                    break;
            }
        }
    }

    /// <summary>Four-pointed star.</summary>
    static StreamGeometry Sparkle(double r)
    {
        var geometry = new StreamGeometry();
        using var ctx = geometry.Open();
        double inner = r * 0.32;
        for (int i = 0; i < 8; i++)
        {
            double angle = i * Math.PI / 4 - Math.PI / 2;
            double radius = i % 2 == 0 ? r : inner;
            var point = new Point(Math.Cos(angle) * radius, Math.Sin(angle) * radius);
            if (i == 0) ctx.BeginFigure(point, true);
            else ctx.LineTo(point);
        }
        ctx.EndFigure(true);
        return geometry;
    }

    /// <summary>Small deterministic generator for the confetti (independent of the app's RNG).</summary>
    sealed class SplitMix64(ulong seed)
    {
        ulong _state = seed;

        public double Next()
        {
            unchecked
            {
                _state += 0x9E3779B97F4A7C15;
                ulong z = _state;
                z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
                z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
                z ^= z >> 31;
                return (z >> 11) / (double)(1UL << 53);
            }
        }

        public double Next(double lo, double hi) => lo + Next() * (hi - lo);
    }
}
