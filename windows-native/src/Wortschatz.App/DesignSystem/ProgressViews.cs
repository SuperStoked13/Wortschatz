using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Wortschatz.App.DesignSystem;

// Port of the animated parts of mac/Wortschatz/DesignSystem/ProgressViews.swift (StatusBar, RoundProgressBar) and of
// WriteProgressLine (WriteScreen.swift): bars that glide to a new value instead of jumping. They are drawn by hand
// (no ProgressBar template), keep their value across updates (SetValue / SetCounts) and animate with the Mac's springs.

/// <summary>A slim capsule bar (Mac: WriteProgressLine, RoundProgressBar's bar): the share filled with a tint gradient.</summary>
public sealed class ProgressLine : Control
{
    readonly AnimatedValue _value;
    Color _tint;

    public ProgressLine(double value, Color tint, double width, double height = 6)
    {
        _value = new AnimatedValue(Motion.Clamp01(value));
        _tint = tint;
        Width = width;
        Height = height;
        IsHitTestVisible = false;
        _value.Changed += InvalidateVisual;
    }

    /// <summary>Glides to <paramref name="value"/> (Mac: Motion.gentle).</summary>
    public void SetValue(double value, Curve? curve = null) => _value.Set(Motion.Clamp01(value), Motion.Animation(curve ?? Motion.Gentle));

    public void SetTint(Color tint)
    {
        _tint = tint;
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var p = WsTheme.P;
        double h = Bounds.Height, w = Bounds.Width;
        context.DrawRectangle(WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.10) : Palette.Hex(0x101828, 0.09)), null, new RoundedRect(new Rect(0, 0, w, h), h / 2));
        double v = _value.Value;
        if (v <= 0.0005) return;
        double fill = Math.Min(w, Math.Max(h, w * Math.Min(1, v)));
        context.DrawRectangle(Gradient(_tint), null, new RoundedRect(new Rect(0, 0, fill, h), h / 2));
    }

    /// <summary>SwiftUI's <c>color.gradient</c>: a touch lighter at the top, the colour at the bottom.</summary>
    public static LinearGradientBrush Gradient(Color c) => new()
    {
        StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
        GradientStops =
        {
            new GradientStop(Color.FromArgb(c.A, (byte)Math.Min(255, c.R + (255 - c.R) * 0.18), (byte)Math.Min(255, c.G + (255 - c.G) * 0.18), (byte)Math.Min(255, c.B + (255 - c.B) * 0.18)), 0),
            new GradientStop(c, 1),
        },
    };
}

/// <summary>
/// A horizontal bar split into Gemeistert (green) · Am Lernen (amber) · Neu (grey), each segment a capsule with a 2 pt
/// gap (Mac: StatusBar). Every visible segment is at least as wide as it is tall; changes glide with Motion.spring.
/// </summary>
public sealed class AnimatedStatusBar : Control
{
    readonly AnimatedValue _mastered, _learning, _fresh;

    public AnimatedStatusBar(int mastered, int learning, int fresh, double width, double height = 8)
    {
        _mastered = new AnimatedValue(mastered);
        _learning = new AnimatedValue(learning);
        _fresh = new AnimatedValue(fresh);
        Width = width;
        Height = height;
        IsHitTestVisible = false;
        foreach (var v in new[] { _mastered, _learning, _fresh }) v.Changed += InvalidateVisual;
    }

    public void SetCounts(int mastered, int learning, int fresh)
    {
        var curve = Motion.Animation(Motion.Spring);
        _mastered.Set(mastered, curve);
        _learning.Set(learning, curve);
        _fresh.Set(fresh, curve);
    }

    public override void Render(DrawingContext context)
    {
        var p = WsTheme.P;
        double w = Bounds.Width, h = Bounds.Height;
        var counts = new[] { (Math.Max(0, _mastered.Value), p.Mastered.Fill), (Math.Max(0, _learning.Value), p.Learning.Fill), (Math.Max(0, _fresh.Value), p.New.Fill) };
        double total = counts.Sum(c => c.Item1);
        using var clip = context.PushClip(new RoundedRect(new Rect(0, 0, w, h), h / 2));
        if (total <= 0.0001)
        {
            context.DrawRectangle(WsTheme.B(p.New.Fill), null, new RoundedRect(new Rect(0, 0, w, h), h / 2));
            return;
        }
        // Segments that are (nearly) gone shrink away; the gap fades with them.
        var segments = counts.Where(c => c.Item1 / total > 0.0005).ToList();
        double gap = segments.Count > 1 ? 2 : 0;
        double available = Math.Max(0, w - gap * (segments.Count - 1));
        double minimum = Math.Min(h, available / Math.Max(1, segments.Count));
        double shared = available - minimum * segments.Count;
        double x = 0;
        foreach (var (count, color) in segments)
        {
            double share = count / total;
            double width = Math.Min(minimum, minimum * share * segments.Count * 4) + shared * share;
            context.DrawRectangle(WsTheme.B(color), null, new RoundedRect(new Rect(x, 0, Math.Max(0, width), h), h / 2));
            x += width + gap;
        }
    }
}

/// <summary>
/// The segmented progress bar of Lernen (Mac: LearnSegmentedBar): one pill per round-sized batch, filled from the left
/// with Gemeistert (green) and Am Lernen (amber). Grow animates it from where the round started (Mac: the checkpoint's
/// bar grows with Motion.gentle after a beat).
/// </summary>
public sealed class SegmentedBar : Control
{
    readonly AnimatedValue _mastered, _learning;
    readonly int _total, _count;

    public SegmentedBar(int mastered, int learning, int total, int count, double height = 10)
    {
        _mastered = new AnimatedValue(mastered);
        _learning = new AnimatedValue(learning);
        _total = total;
        _count = Math.Max(1, count);
        Height = height;
        IsHitTestVisible = false;
        _mastered.Changed += InvalidateVisual;
        _learning.Changed += InvalidateVisual;
    }

    /// <summary>Grows to the given counts (after a beat, on the gentle spring; Reduce Motion: at once).</summary>
    public void Grow(int mastered, int learning)
    {
        var curve = Motion.ReduceMotion ? null : Motion.Gentle.Delayed(0.25);
        _mastered.Set(mastered, curve);
        _learning.Set(learning, curve);
    }

    public override void Render(DrawingContext context)
    {
        var p = WsTheme.P;
        double w = Bounds.Width, h = Bounds.Height, gap = 4;
        double seg = (w - gap * (_count - 1)) / _count;
        double t = Math.Max(0, _total);
        double m = t > 0 ? Math.Max(0, _mastered.Value) / t * _count : 0;
        double r = t > 0 ? Math.Max(0, _mastered.Value + _learning.Value) / t * _count : 0;
        for (int i = 0; i < _count; i++)
        {
            double x = i * (seg + gap);
            var rect = new RoundedRect(new Rect(x, 0, seg, h), h / 2);
            context.DrawRectangle(WsTheme.B(Palette.Hex(Ui.Rgb(p.New.Fill), 0.45)), null, rect);
            using (context.PushClip(rect))
            {
                double reached = Math.Clamp(r - i, 0, 1), mastered = Math.Clamp(m - i, 0, 1);
                if (reached > 0) context.DrawRectangle(WsTheme.B(p.Learning.Fill), null, new RoundedRect(new Rect(x, 0, seg * reached, h), h / 2));
                if (mastered > 0) context.DrawRectangle(WsTheme.B(p.Mastered.Fill), null, new RoundedRect(new Rect(x, 0, seg * mastered, h), h / 2));
            }
        }
    }
}

/// <summary>
/// The learn screen's progress capsule (Mac: ProgressCapsule, .full): the status bar and "12 Neu · 5 Am Lernen ·
/// 3 Gemeistert" with coloured dots. Built once per screen; Update glides the bar and pops a count that changed.
/// </summary>
public sealed class ProgressCapsuleView : StackPanel
{
    readonly AnimatedStatusBar _bar;
    readonly TextBlock[] _counts = new TextBlock[3];
    readonly int[] _values = [-1, -1, -1];
    readonly TextBlock[] _labels = new TextBlock[3];
    readonly StackPanel _legend;
    bool _compact;

    public ProgressCapsuleView(int fresh, int learning, int mastered)
    {
        var p = WsTheme.P;
        Orientation = Avalonia.Layout.Orientation.Horizontal;
        Spacing = 16;
        VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center;
        _bar = new AnimatedStatusBar(mastered, learning, fresh, 120, 7) { VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        Children.Add(_bar);
        var legend = _legend = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 12, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        var items = new[] { (p.New.Fill, "Neu"), (p.Learning.Fill, "Am Lernen"), (p.Mastered.Fill, "Gemeistert") };
        for (int i = 0; i < 3; i++)
        {
            _counts[i] = Ui.Text("", 13.5, FontWeight.Bold);
            _labels[i] = Ui.Text(items[i].Item2, 13.5, color: p.TextSecondary);
            legend.Children.Add(Ui.H(5,
                new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = WsTheme.B(items[i].Item1), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center },
                _counts[i], _labels[i]));
        }
        Children.Add(legend);
        Update(fresh, learning, mastered, animated: false);
    }

    /// <summary>Narrow windows (Mac: ProgressCapsule style .compact): a shorter bar and bare numbers with coloured dots.</summary>
    public bool Compact
    {
        get => _compact;
        set
        {
            if (_compact == value) return;
            _compact = value;
            _bar.Width = value ? 72 : 120;
            Spacing = value ? 8 : 16;
            _legend.Spacing = value ? 6 : 12;
            foreach (var label in _labels) label.IsVisible = !value;
        }
    }

    public void Update(int fresh, int learning, int mastered, bool animated = true)
    {
        int[] values = [fresh, learning, mastered];
        for (int i = 0; i < 3; i++)
        {
            if (values[i] == _values[i]) continue;
            _counts[i].Text = $"{values[i]}";
            if (animated && _values[i] >= 0) Effects.Pop(_counts[i], 1.15);
            _values[i] = values[i];
        }
        if (animated) _bar.SetCounts(mastered, learning, fresh);
        Avalonia.Automation.AutomationProperties.SetName(this, $"Lernfortschritt: {mastered} gemeistert, {learning} am Lernen, {fresh} neu");
        ToolTip.SetTip(this, $"{fresh} Neu · {learning} Am Lernen · {mastered} Gemeistert");
    }
}

/// <summary>
/// The round's ratio as a ring (Mac: WriteRatioRing): a tinted arc on a quiet track with the percentage and "richtig" in
/// the middle. It fills from empty when it appears (Motion.gentle after a beat; Reduce Motion: at once).
/// </summary>
public sealed class RatioRing : Grid
{
    readonly AnimatedValue _shown = new();
    readonly Color _tint;
    readonly RingArc _arc;

    public RatioRing(double value, Color tint, string percentText, bool animate = true, double diameter = 104)
    {
        _tint = tint;
        Width = Height = diameter;
        _arc = new RingArc(this);
        Children.Add(_arc);
        var p = WsTheme.P;
        var center = Ui.V(0, Ui.Text(percentText, 24, FontWeight.Bold, font: WsTheme.Prompt), Ui.Text("richtig", 12, color: p.TextSecondary));
        foreach (var c in center.Children) c.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center;
        center.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center;
        center.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center;
        Children.Add(center);
        _shown.Changed += _arc.InvalidateVisual;
        if (Motion.ReduceMotion || !animate) _shown.Jump(Motion.Clamp01(value));
        else _shown.Set(Motion.Clamp01(value), Motion.Gentle.Delayed(0.15));
    }

    sealed class RingArc(RatioRing ring) : Control
    {
        public override void Render(DrawingContext context)
        {
            const double line = 10;
            var p = WsTheme.P;
            double d = Math.Min(Bounds.Width, Bounds.Height) - line;
            var c = new Point(Bounds.Width / 2, Bounds.Height / 2);
            double r = d / 2;
            context.DrawEllipse(null, new Pen(WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.08) : Palette.Hex(0x101828, 0.08)), line), c, r, r);
            double v = Motion.Clamp01(ring._shown.Value);
            if (v <= 0.001) return;
            var pen = new Pen(ProgressLine.Gradient(ring._tint), line, lineCap: PenLineCap.Round);
            if (v >= 0.999)
            {
                context.DrawEllipse(null, pen, c, r, r);
                return;
            }
            double a = v * 2 * Math.PI;
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                g.BeginFigure(new Point(c.X, c.Y - r), false);
                g.ArcTo(new Point(c.X + r * Math.Sin(a), c.Y - r * Math.Cos(a)), new Size(r, r), 0, v > 0.5, SweepDirection.Clockwise);
                g.EndFigure(false);
            }
            context.DrawGeometry(null, pen, geo);
        }
    }
}
