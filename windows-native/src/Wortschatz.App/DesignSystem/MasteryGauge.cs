using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.Core;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// The mastery ring (Mac: MasteryGauge in ProgressViews.swift): learning (amber) up to mastered + learning, mastered
/// (green) on top, on a grey track. Small: sidebar rows (a check when everything is mastered); medium: set cards and the
/// hero (the percentage inside); large: the set page ("60 %" over "gemeistert").
/// </summary>
public sealed class MasteryGauge : Grid
{
    public enum Size { Small, Medium, Large }

    readonly int _mastered, _learning, _total;
    readonly Size _size;

    public MasteryGauge(int mastered, int learning, int total, Size size = Size.Small, double scale = 1)
    {
        _mastered = mastered;
        _learning = learning;
        _total = total;
        _size = size;
        double d = Diameter(size) * scale;
        Width = Height = d;
        Children.Add(new Arcs(this, LineWidth(size) * scale));
        var p = WsTheme.P;
        bool complete = total > 0 && mastered == total;
        int percent = total > 0 ? (int)Math.Round(100.0 * mastered / total) : 0;
        Control? center = size switch
        {
            Size.Small when complete => Icons.Icon(IconName.Check, 9 * scale, p.Mastered.Fill, 3.4),
            Size.Medium when complete => Icons.Icon(IconName.Check, 17 * scale, p.Mastered.Text, 2.6),
            Size.Medium => Ui.Text($"{percent} %", 11.5 * scale, FontWeight.SemiBold),
            Size.Large => Centered(Ui.V(0, Centered(Ui.Text($"{percent} %", 30 * scale, FontWeight.Bold, font: WsTheme.Prompt)),
                Centered(Ui.Text("gemeistert", 12 * scale, color: p.TextSecondary)))),
            _ => null,
        };
        if (center is not null)
        {
            center.HorizontalAlignment = HorizontalAlignment.Center;
            center.VerticalAlignment = VerticalAlignment.Center;
            Children.Add(center);
        }
        IsHitTestVisible = size != Size.Small;
        AutomationProperties.SetName(this, $"Lernstand: {percent} Prozent gemeistert");
        if (size != Size.Small) ToolTip.SetTip(this, $"{mastered} gemeistert · {learning} am Lernen · {total - mastered - learning} neu");
    }

    public MasteryGauge(SetProgress stats, Size size = Size.Small, double scale = 1) : this(stats.Mastered, stats.Learning, stats.Total, size, scale) { }

    static T Centered<T>(T c) where T : Control
    {
        c.HorizontalAlignment = HorizontalAlignment.Center;
        return c;
    }

    public static double Diameter(Size size) => size switch { Size.Small => 18, Size.Medium => 50, _ => 128 };
    static double LineWidth(Size size) => size switch { Size.Small => 3.5, Size.Medium => 5, _ => 12 };

    sealed class Arcs(MasteryGauge gauge, double line) : Control
    {
        public override void Render(DrawingContext context)
        {
            var p = WsTheme.P;
            double d = Math.Min(Bounds.Width, Bounds.Height) - line;
            var c = new Point(Bounds.Width / 2, Bounds.Height / 2);
            double r = d / 2;
            var track = p.New.Fill;
            double trackAlpha = gauge._size == Size.Small ? 0.9 : 0.55;
            context.DrawEllipse(null, new Pen(new SolidColorBrush(track, trackAlpha), line), c, r, r);
            if (gauge._total <= 0) return;
            var cap = gauge._size == Size.Small ? PenLineCap.Flat : PenLineCap.Round;
            double learningEnd = (double)(gauge._mastered + gauge._learning) / gauge._total;
            double masteredEnd = (double)gauge._mastered / gauge._total;
            Arc(context, c, r, learningEnd, new Pen(WsTheme.B(p.Learning.Fill), line, lineCap: cap));
            Arc(context, c, r, masteredEnd, new Pen(WsTheme.B(p.Mastered.Fill), line, lineCap: cap));
        }

        static void Arc(DrawingContext context, Point c, double r, double share, Pen pen)
        {
            if (share <= 0.001) return;
            if (share >= 0.999)
            {
                context.DrawEllipse(null, pen, c, r, r);
                return;
            }
            double a = share * 2 * Math.PI;
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                g.BeginFigure(new Point(c.X, c.Y - r), false);
                g.ArcTo(new Point(c.X + r * Math.Sin(a), c.Y - r * Math.Cos(a)), new Avalonia.Size(r, r), 0, share > 0.5, SweepDirection.Clockwise);
                g.EndFigure(false);
            }
            context.DrawGeometry(null, pen, geo);
        }
    }
}
