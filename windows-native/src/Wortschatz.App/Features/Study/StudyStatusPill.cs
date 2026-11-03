using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Learn;

namespace Wortschatz.App.Features.Study;

// The status pill of the study action bars (Lernen, Schreiben), port of LearnStatus / LearnStatusPill / StreakBadge /
// LearnCountdownLine in mac/Wortschatz/Features/Learn/LearnActionBar.swift: the key hints while a question waits, the
// feedback after an answer (a tinted pill with a bouncing symbol; a wrong answer also shakes), the answer streak's
// flame from three in a row, and the auto-advance countdown along the bottom edge.

/// <summary>A running auto-advance countdown (Mac: StudyCountdown): its token, length and start on the Motion clock.</summary>
public sealed record StudyCountdown(int Token, int Milliseconds, double Start);

/// <summary>What the status pill shows (Mac: LearnStatus).</summary>
public sealed record StudyStatus(StudyStatus.Kinds Kind, string Title = "", string? Message = null, int Choices = 4, int Streak = 0)
{
    public enum Kinds { Keys, Typing, Correct, Wrong, DontKnow }

    /// <summary>A correct answer that reached a streak milestone (5, 10, 15 … in a row).</summary>
    public bool IsStreakMilestone => Kind == Kinds.Correct && AnswerStreak.IsMilestone(Streak);
}

public static class StudyStatusPill
{
    static Palette P => WsTheme.P;

    static StatusPalette? PaletteOf(StudyStatus.Kinds kind) => kind switch
    {
        StudyStatus.Kinds.Correct => P.Success,
        StudyStatus.Kinds.Wrong => P.Failure,
        StudyStatus.Kinds.DontKnow => P.Warning,
        _ => null,
    };

    /// <summary>
    /// The pill for <paramref name="status"/>. <paramref name="play"/>: a new step (the symbol bounces, a wrong answer
    /// shakes); <paramref name="streakGrew"/>: the flame's number pops.
    /// </summary>
    public static Control Create(StudyStatus status, StudyCountdown? countdown, bool play, bool streakGrew)
    {
        var palette = PaletteOf(status.Kind);
        var row = Ui.H(16, Content(status, palette, play));
        if (status.Streak >= AnswerStreak.VisibleFrom) row.Children.Add(StreakBadge(status.Streak, status.IsStreakMilestone, streakGrew));
        row.VerticalAlignment = VerticalAlignment.Center;
        var layer = new Grid { MinHeight = 44 };
        var shape = new CornerRadius(22);
        var glass = Ui.Glass(new Border(), 22, new Thickness(0), strong: true, shadow: false);
        glass.BoxShadow = BoxShadows.Parse($"0 6 18 -8 {WsButton.Hex(P.Shadow, Math.Min(1, P.Shadow.A / 255.0 * 1.1))}");
        layer.Children.Add(glass);
        if (palette is not null)
            layer.Children.Add(new Border { CornerRadius = shape, Background = WsTheme.B(Palette.Hex(Ui.Rgb(palette.Fill), P.Dark ? 0.22 : 0.18)) });
        row.Margin = new Thickness(16, 8, 20, 8);
        layer.Children.Add(row);
        if (countdown is not null) layer.Children.Add(CountdownLine(countdown, palette?.Fill ?? P.Accent));
        layer.HorizontalAlignment = HorizontalAlignment.Left;
        if (play && status.Kind == StudyStatus.Kinds.Wrong) Effects.Shake(layer, 7);
        return layer;
    }

    static Control Content(StudyStatus status, StatusPalette? palette, bool play)
    {
        switch (status.Kind)
        {
            case StudyStatus.Kinds.Keys:
                var keys = Ui.H(16,
                    Ui.H(5, Ui.KeyCap("1"), Ui.Text("–", 13.5, color: P.TextSecondary), Ui.KeyCap($"{Math.Max(1, status.Choices)}"), Ui.Text("wählen", 13.5, color: P.TextSecondary)),
                    Ui.H(6, Ui.KeyCap("↑↓←→"), Ui.Text("markieren", 13.5, color: P.TextSecondary)));
                AutomationProperties.SetName(keys, $"Tasten 1 bis {status.Choices} wählen eine Antwort, die Pfeiltasten markieren eine.");
                return keys;
            case StudyStatus.Kinds.Typing:
                return Ui.H(8, Icons.Icon(IconName.Keyboard, 17, P.TextSecondary), Ui.Text("Antwort schreiben", 13.5, color: P.TextSecondary));
            default:
                var symbol = FeedbackSymbol(status.Kind, palette!.Fill);
                if (play) Effects.Pop(symbol, 1.22);
                string title = status.IsStreakMilestone ? $"{status.Streak} richtig in Folge!" : status.Title;
                var texts = Ui.V(1, Ui.Text(title, 17, FontWeight.SemiBold, palette.Text, TextWrapping.Wrap, WsTheme.UI),
                    status.Message is { } m ? Ui.Text(m, 13.5, color: P.TextSecondary, wrap: TextWrapping.Wrap) : null);
                texts.MaxWidth = 380;
                texts.VerticalAlignment = VerticalAlignment.Center;
                var content = Ui.H(12, symbol, texts);
                string prefix = status.Kind switch { StudyStatus.Kinds.Correct => "Richtig", StudyStatus.Kinds.Wrong => "Falsch", _ => "Nicht gewusst" };
                AutomationProperties.SetName(content, string.Join(". ", new[] { prefix, title, status.Message }.Where(s => s is not null)));
                return content;
        }
    }

    /// <summary>✓ ✗ 💡 in a filled circle (Mac: the palette-rendered "…circle.fill" symbols).</summary>
    public static Control FeedbackSymbol(StudyStatus.Kinds kind, Color fill, double size = 26)
    {
        var icon = kind switch { StudyStatus.Kinds.Wrong => IconName.X, StudyStatus.Kinds.DontKnow => IconName.Lightbulb, _ => IconName.Check };
        var glyph = Icons.Icon(icon, size * 0.6, Colors.White, kind == StudyStatus.Kinds.DontKnow ? 2.4 : 3);
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        return new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = WsTheme.B(fill), Child = glyph, VerticalAlignment = VerticalAlignment.Center };
    }

    /// <summary>The answer streak: a flame and the number of correct answers in a row; it pops when the number grows.</summary>
    static Control StreakBadge(int count, bool milestone, bool grew)
    {
        var badge = new Border
        {
            Child = Ui.H(3, Icons.Icon(IconName.Flame, 15, P.Flame), Ui.Text($"{count}", 13.5, FontWeight.SemiBold, P.Text)),
            Background = WsTheme.B(Palette.Hex(Ui.Rgb(P.Flame), milestone ? 0.22 : 0.13)),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 3),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTip.SetTip(badge, $"{count} richtig in Folge");
        AutomationProperties.SetName(badge, $"{count} richtig in Folge");
        if (grew) Effects.Pop(badge, milestone ? 1.12 : 1.05);
        return badge;
    }

    /// <summary>The auto-advance countdown: a thin line that shrinks to nothing until the next question.</summary>
    static Control CountdownLine(StudyCountdown countdown, Color tint) => new CountdownLineView(countdown, tint)
    {
        Height = 3,
        Margin = new Thickness(20, 0, 20, 5),
        VerticalAlignment = VerticalAlignment.Bottom,
    };

    sealed class CountdownLineView : Control
    {
        readonly StudyCountdown _countdown;
        readonly Color _tint;
        bool _running;

        public CountdownLineView(StudyCountdown countdown, Color tint)
        {
            _countdown = countdown;
            _tint = tint;
            IsHitTestVisible = false;
        }

        double Remaining => Motion.IsSnapshot && !_running
            ? 0.6
            : Math.Max(0, 1 - (Motion.Now() - _countdown.Start) * 1000 / Math.Max(1, _countdown.Milliseconds));

        protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
        {
            base.OnAttachedToVisualTree(e);
            if (Motion.IsSnapshot) return;
            _running = true;
            Motion.OnFrames(_ =>
            {
                if (!_running) return false;
                InvalidateVisual();
                return Remaining > 0;
            });
        }

        protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
        {
            base.OnDetachedFromVisualTree(e);
            _running = false;
        }

        public override void Render(DrawingContext context)
        {
            double w = Bounds.Width * Remaining, h = Bounds.Height;
            if (w <= 0.5) return;
            context.DrawRectangle(WsTheme.B(Palette.Hex(Ui.Rgb(_tint), 0.75)), null, new RoundedRect(new Rect(0, 0, w, h), h / 2));
        }
    }
}

/// <summary>
/// The floating action bar of a study screen (Mac: StudyActionBar): the status pill on the left, the screen's other
/// actions and the Enter action on the right, each its own glass, in the study column.
/// </summary>
public static class StudyActionBarView
{
    public static Control Create(Control? status, IEnumerable<Control?> trailing, double width = 760)
    {
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), MaxWidth = width, Margin = new Thickness(32, 12, 32, 20), ColumnSpacing = 12 };
        if (status is not null) bar.Children.Add(status);
        var right = Ui.H(12, trailing.ToArray());
        right.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(right, 2);
        bar.Children.Add(right);
        foreach (var b in right.Children.OfType<WsButton>())
        {
            StudyChrome.Floating(b);
            b.Focusable = false;
        }
        bar.VerticalAlignment = VerticalAlignment.Bottom;
        return bar;
    }
}
