using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// The window background of the Glas design: a soft mesh of four radial colour blobs (violet top left, pink top
/// right, blue bottom right, lilac bottom left) on a pale lavender (dark: near-black) base. Mac: AppBackdrop.swift.
/// Like the Mac it drifts slowly (each blob on its own period of half a minute or more, so the motion never visibly
/// loops), pauses while the window is inactive or minimised, and stands still under Reduce Motion and in snapshots.
/// Under a contrast theme or without transparency effects the palette has no blobs: a plain background.
/// </summary>
public sealed class Backdrop : Control
{
    // (centre x, centre y, radius x, radius y) as fractions of the window, like the CSS of the design.
    static readonly (double X, double Y, double Rx, double Ry)[] Blobs =
    [
        (0.12, 0.08, 0.60, 0.55),
        (0.92, 0.18, 0.45, 0.50),
        (0.70, 0.95, 0.55, 0.60),
        (0.25, 0.85, 0.40, 0.45),
    ];

    // Drift of each blob's centre: (period x, phase x, period y, phase y) in seconds, like AppBackdrop.points (a = 0.07).
    static readonly (double Px, double Fx, double Py, double Fy)[] Drift =
    [
        (29, 0, 37, 0.3),
        (31, 0.6, 41, 0.1),
        (33, 0.8, 43, 0.45),
        (39, 0.2, 35, 0.7),
    ];

    const double Amplitude = 0.07;

    /// <summary>Redraws per second while drifting (slow motion needs few; keeps the cost of a redraw low).</summary>
    const int FramesPerSecond = 12;

    DispatcherTimer? _timer;
    TopLevel? _top;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _top = TopLevel.GetTopLevel(this);
        if (_top is WindowBase window)
        {
            window.Activated += OnActivity;
            window.Deactivated += OnActivity;
        }
        UpdateTimer();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        if (_top is WindowBase window)
        {
            window.Activated -= OnActivity;
            window.Deactivated -= OnActivity;
        }
        _top = null;
        _timer?.Stop();
    }

    void OnActivity(object? sender, EventArgs e) => UpdateTimer();

    bool ShouldDrift => !Motion.ReduceMotion && !Motion.IsSnapshot && WsTheme.P.BackdropBlobs.Length > 0
        && _top is Window { IsActive: true, WindowState: not WindowState.Minimized };

    void UpdateTimer()
    {
        if (!ShouldDrift)
        {
            _timer?.Stop();
            return;
        }
        _timer ??= new DispatcherTimer(TimeSpan.FromSeconds(1.0 / FramesPerSecond), DispatcherPriority.Background, (_, _) =>
        {
            if (ShouldDrift) InvalidateVisual();
            else _timer?.Stop();
        });
        _timer.Start();
    }

    public override void Render(DrawingContext context)
    {
        var p = WsTheme.P;
        var rect = new Rect(Bounds.Size);
        context.FillRectangle(WsTheme.B(p.Backdrop), rect);
        double t = ShouldDrift ? Motion.Now() : 0;
        for (int i = 0; i < Blobs.Length && i < p.BackdropBlobs.Length; i++)
        {
            var (x, y, rx, ry) = Blobs[i];
            if (t > 0)
            {
                var (px, fx, py, fy) = Drift[i];
                x += Amplitude * Math.Sin((t / px + fx) * 2 * Math.PI);
                y += Amplitude * Math.Sin((t / py + fy) * 2 * Math.PI);
            }
            var c = p.BackdropBlobs[i];
            var brush = new RadialGradientBrush
            {
                Center = new RelativePoint(x, y, RelativeUnit.Relative),
                GradientOrigin = new RelativePoint(x, y, RelativeUnit.Relative),
                RadiusX = new RelativeScalar(rx, RelativeUnit.Relative),
                RadiusY = new RelativeScalar(ry, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(c, 0),
                    new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 0.7),
                },
            };
            context.FillRectangle(brush, rect);
        }
    }
}
