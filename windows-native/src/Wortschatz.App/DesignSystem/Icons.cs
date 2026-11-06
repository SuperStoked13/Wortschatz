using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Media;
using Path = Avalonia.Controls.Shapes.Path;

namespace Wortschatz.App.DesignSystem;

// Line icons on a 24×24 grid (the paths of the Glas design, Lucide style). The Mac app uses SF Symbols;
// WriteFlow/LearnFlow name them (e.g. "star", "trophy.fill") and Icons.ForSymbol maps those names.

public enum IconName
{
    App, Minimize, Maximize, Restore, Close, Search, Home, Plus, Flame, Gear, Play, Target, Trophy, ChevronLeft, ChevronRight,
    Speaker, Sliders, Star, StarFilled, Check, CheckCircle, X, Pencil, Trash, Cards, Keyboard, Book, Upload, Download, Copy, Shuffle,
    Undo, Sparkles, Stack, Magnifier, Clock, Moon, Sun, Exam, Info, Repeat, RotateCcw, PartyPopper, Lightbulb, Warning, Octagon, More,
    Hand, EqualCircle, Menu, Camera,
}

public static class Icons
{
    /// <summary>Stroke paths (fill = false) or filled shapes (fill = true).</summary>
    static readonly Dictionary<IconName, (string Data, bool Fill)> Paths = new()
    {
        [IconName.Minimize] = ("M5 12h14", false),
        [IconName.Maximize] = ("M8 5h8a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3H8a3 3 0 0 1-3-3V8a3 3 0 0 1 3-3z", false),
        [IconName.Restore] = ("M8 8h8v8H8zM11 5h8v8", false),
        [IconName.Close] = ("M6 6l12 12M18 6 6 18", false),
        [IconName.Search] = ("M11 4a7 7 0 1 1 0 14a7 7 0 1 1 0-14zM20 20l-3.5-3.5", false),
        [IconName.Home] = ("M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z", false),
        [IconName.Plus] = ("M12 5v14M5 12h14", false),
        // Three lines: the library drawer on a phone.
        [IconName.Menu] = ("M4 6.5h16M4 12h16M4 17.5h16", false),
        // A camera: "Foto aufnehmen" on a phone.
        [IconName.Camera] = ("M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3zM12 10a3 3 0 1 1 0 6a3 3 0 1 1 0-6z", false),
        [IconName.Flame] = ("M12 2.5c1.2 3.2 5.5 5.3 5.5 10.6a5.5 5.5 0 0 1-11 0c0-2.2 1.1-3.8 2.2-4.9.3 1.6 1.1 2.7 2.2 3.3 0-3.3 0-6.3 1.1-9z", true),
        // A cog with teeth (Lucide "settings"); the earlier circle with rays read as a sun.
        [IconName.Gear] = ("M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2zM12 9a3 3 0 1 1 0 6a3 3 0 1 1 0-6z", false),
        [IconName.Play] = ("M8 5v14l11-7z", true),
        [IconName.Target] = ("M12 3.5a8.5 8.5 0 1 1 0 17a8.5 8.5 0 1 1 0-17zM12 7.5a4.5 4.5 0 1 1 0 9a4.5 4.5 0 1 1 0-9z", false),
        [IconName.Trophy] = ("M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0zM17 5h3v2a3 3 0 0 1-3 3M7 5H4v2a3 3 0 0 0 3 3", false),
        [IconName.ChevronLeft] = ("m15 18-6-6 6-6", false),
        [IconName.ChevronRight] = ("m9 18 6-6-6-6", false),
        [IconName.Speaker] = ("M11 5 6 9H3v6h3l5 4zM15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13", false),
        [IconName.Sliders] = ("M4 7h9M17 7h3M4 17h3M11 17h9M15 5a2 2 0 1 1 0 4a2 2 0 1 1 0-4zM9 15a2 2 0 1 1 0 4a2 2 0 1 1 0-4z", false),
        [IconName.Star] = ("m12 3 2.7 5.6 6.1.8-4.5 4.2 1.1 6.1L12 16.8l-5.4 2.9 1.1-6.1-4.5-4.2 6.1-.8z", false),
        [IconName.StarFilled] = ("m12 3 2.7 5.6 6.1.8-4.5 4.2 1.1 6.1L12 16.8l-5.4 2.9 1.1-6.1-4.5-4.2 6.1-.8z", true),
        [IconName.Check] = ("M5 12.5l4.5 4.5L19 7.5", false),
        [IconName.CheckCircle] = ("M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18zM8 12.5l3 3 5-6", false),
        [IconName.X] = ("M6 6l12 12M18 6 6 18", false),
        [IconName.Pencil] = ("M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16zM13.5 6.5l4 4", false),
        [IconName.Trash] = ("M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3", false),
        [IconName.Cards] = ("M7 4h10a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM9 1.8h8a3 3 0 0 1 3 3", false),
        [IconName.Keyboard] = ("M4 6h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1zM7 10h.01M11 10h.01M15 10h.01M8 14h8", false),
        [IconName.Book] = ("M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2zM4 5v16M8 7h7", false),
        [IconName.Upload] = ("M12 16V4M7 9l5-5 5 5M5 20h14", false),
        [IconName.Download] = ("M12 4v12M7 11l5 5 5-5M5 20h14", false),
        [IconName.Copy] = ("M9 9h10v11H9zM5 15V4h10", false),
        [IconName.Shuffle] = ("M3 7h4l10 10h4M3 17h4l3-3M14 10l3-3h4M18 4l3 3-3 3M18 14l3 3-3 3", false),
        [IconName.Undo] = ("M9 14 4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3", false),
        [IconName.Sparkles] = ("M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8zM19 15l.8 2.2 2.2.8-2.2.8L19 21l-.8-2.2-2.2-.8 2.2-.8z", false),
        [IconName.Stack] = ("M12 3 3 8l9 5 9-5zM3 13l9 5 9-5", false),
        [IconName.Magnifier] = ("M11 4a7 7 0 1 1 0 14a7 7 0 1 1 0-14zM20 20l-3.5-3.5", false),
        [IconName.Clock] = ("M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18zM12 7v5l3 2", false),
        [IconName.Moon] = ("M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z", false),
        [IconName.Sun] = ("M12 8a4 4 0 1 1 0 8a4 4 0 1 1 0-8zM12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4", false),
        [IconName.Exam] = ("M7 3h10a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM9 8h6M9 12h6M9 16h3", false),
        [IconName.Repeat] = ("M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8M21 3v5h-5M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16M8 16H3v5", false),
        [IconName.RotateCcw] = ("M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8M3 3v5h5", false),
        [IconName.PartyPopper] = ("M5.8 11.3 2 22l10.7-3.79M4 3h.01M22 8h.01M15 2h.01M22 20h.01M22 2l-2.24.75a2.9 2.9 0 0 0-1.96 3.12c.1.86-.57 1.63-1.45 1.63h-.38c-.86 0-1.6.6-1.76 1.44L14 10M22 13l-.82-.33c-.86-.34-1.82.2-1.98 1.11c-.11.7-.72 1.22-1.43 1.22H17M11 2l.33.82c.34.86-.2 1.82-1.11 1.98C9.52 4.9 9 5.52 9 6.23V7M11 13c1.93 1.93 2.83 4.17 2 5-.83.83-3.07-.07-5-2-1.93-1.93-2.83-4.17-2-5 .83-.83 3.07.07 5 2Z", false),
        [IconName.Lightbulb] = ("M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5M9 18h6M10 22h4", false),
        [IconName.Warning] = ("m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3M12 9v4M12 17h.01", false),
        [IconName.Octagon] = ("M12 16h.01M12 8v4M15.312 2a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586l-4.688-4.688A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2z", false),
        [IconName.More] = ("M5 12h.01M12 12h.01M19 12h.01", false),
        [IconName.Hand] = ("M18 11V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2M14 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2M10 10.5V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2v8M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15", false),
        [IconName.EqualCircle] = ("M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18zM8.5 10h7M8.5 14h7", false),
        [IconName.Info] = ("M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18zM12 11v5M12 8h.01", false),
    };

    /// <summary>An icon of <paramref name="size"/> px in <paramref name="color"/>.</summary>
    public static Control Icon(IconName name, double size = 18, Color? color = null, double stroke = 1.8)
    {
        var brush = WsTheme.B(color ?? WsTheme.P.TextSecondary);
        var canvas = new Canvas { Width = 24, Height = 24 };
        if (name == IconName.App)
        {
            canvas.Children.Add(new Rectangle { Width = 20, Height = 20, RadiusX = 6, RadiusY = 6, Fill = WsTheme.B(WsTheme.P.Accent), [Canvas.LeftProperty] = 2.0, [Canvas.TopProperty] = 2.0 });
            canvas.Children.Add(new Path
            {
                Data = Geometry.Parse("M7.5 12.5l3 3 6-7"), Stroke = Brushes.White, StrokeThickness = 2.4,
                StrokeLineCap = PenLineCap.Round, StrokeJoin = PenLineJoin.Round,
            });
        }
        else
        {
            var (data, fill) = Paths[name];
            var path = new Path { Data = Geometry.Parse(data) };
            if (fill) path.Fill = brush;
            else
            {
                path.Stroke = brush;
                path.StrokeThickness = stroke;
                path.StrokeLineCap = PenLineCap.Round;
                path.StrokeJoin = PenLineJoin.Round;
            }
            canvas.Children.Add(path);
        }
        return new Viewbox { Width = size, Height = size, Child = canvas, IsHitTestVisible = false };
    }

    /// <summary>The Mac's SF Symbol names used by the flows' message screens.</summary>
    public static IconName ForSymbol(string symbol) => symbol switch
    {
        "star" => IconName.Star,
        "trophy" or "trophy.fill" => IconName.Trophy,
        "checkmark.circle" => IconName.CheckCircle,
        "magnifyingglass" => IconName.Magnifier,
        "sparkles" => IconName.Sparkles,
        "checkmark.circle.fill" or "checkmark" => IconName.CheckCircle,
        "arrow.circlepath" or "arrow.trianglehead.2.clockwise" => IconName.Repeat,
        "arrow.counterclockwise" => IconName.RotateCcw,
        "hands.clap.fill" or "party.popper" => IconName.PartyPopper,
        _ => IconName.Stack,
    };

    /// <summary>A small ring gauge (sidebar): share 0…1 of the circumference in <paramref name="color"/>.</summary>
    public static Control Ring(double share, Color color, double size = 20)
    {
        var canvas = new Canvas { Width = 20, Height = 20 };
        canvas.Children.Add(new Ellipse { Width = 14, Height = 14, Stroke = WsTheme.B(WsTheme.P.Track), StrokeThickness = 3, [Canvas.LeftProperty] = 3.0, [Canvas.TopProperty] = 3.0 });
        double s = Math.Clamp(share, 0, 1);
        if (s > 0.001)
        {
            if (s >= 0.999)
                canvas.Children.Add(new Ellipse { Width = 14, Height = 14, Stroke = WsTheme.B(color), StrokeThickness = 3, [Canvas.LeftProperty] = 3.0, [Canvas.TopProperty] = 3.0 });
            else
            {
                double angle = s * 2 * Math.PI;
                var end = new Point(10 + 7 * Math.Sin(angle), 10 - 7 * Math.Cos(angle));
                var geo = new StreamGeometry();
                using (var ctx = geo.Open())
                {
                    ctx.BeginFigure(new Point(10, 3), false);
                    ctx.ArcTo(end, new Size(7, 7), 0, s > 0.5, SweepDirection.Clockwise);
                    ctx.EndFigure(false);
                }
                canvas.Children.Add(new Path { Data = geo, Stroke = WsTheme.B(color), StrokeThickness = 3, StrokeLineCap = PenLineCap.Round });
            }
        }
        return new Viewbox { Width = size, Height = size, Child = canvas, IsHitTestVisible = false };
    }
}
