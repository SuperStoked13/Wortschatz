using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Learn;
using static Wortschatz.Core.CoreText;

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
        // Phone: the key hints (1–4 wählen, Antwort schreiben) belong to a keyboard; the answer's feedback stays.
        if (AppDevice.IsPhone && status.Kind is StudyStatus.Kinds.Keys or StudyStatus.Kinds.Typing && status.Streak < AnswerStreak.VisibleFrom)
            return new Border();
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
                // Phone: no keys to press – the hint without its key caps read «– wählen  markieren» (06.11.2026).
                if (!AppDevice.ShowsKeyHints) return new Border();
                var keys = Ui.H(16,
                    Ui.H(5, Ui.KeyCap("1"), Ui.Text("–", 13.5, color: P.TextSecondary), Ui.KeyCap($"{Math.Max(1, status.Choices)}"), Ui.Text(L("wählen"), 13.5, color: P.TextSecondary)),
                    Ui.H(6, Ui.KeyCap("↑↓←→"), Ui.Text(L("markieren"), 13.5, color: P.TextSecondary)));
                AutomationProperties.SetName(keys, L($"Tasten 1 bis {status.Choices} wählen eine Antwort, die Pfeiltasten markieren eine."));
                return keys;
            case StudyStatus.Kinds.Typing:
                return Ui.H(8, Icons.Icon(IconName.Keyboard, 17, P.TextSecondary), Ui.Text(L("Antwort schreiben"), 13.5, color: P.TextSecondary));
            default:
                var symbol = FeedbackSymbol(status.Kind, palette!.Fill);
                if (play) Effects.Pop(symbol, 1.22);
                string title = status.IsStreakMilestone ? L($"{status.Streak} richtig in Folge!") : status.Title;
                // The title takes at most two lines (Mac: lineLimit(2)).
                var titleText = Ui.Text(title, 17, FontWeight.SemiBold, palette.Text, TextWrapping.Wrap, WsTheme.UI);
                titleText.MaxLines = 2;
                titleText.TextTrimming = TextTrimming.CharacterEllipsis;
                var texts = Ui.V(1, titleText,
                    status.Message is { } m ? Ui.Text(m, 13.5, color: P.TextSecondary, wrap: TextWrapping.Wrap) : null);
                texts.MaxWidth = 380;
                texts.VerticalAlignment = VerticalAlignment.Center;
                var content = Ui.H(12, symbol, texts);
                string prefix = status.Kind switch { StudyStatus.Kinds.Correct => L("Richtig"), StudyStatus.Kinds.Wrong => L("Falsch"), _ => L("Nicht gewusst") };
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
        ToolTip.SetTip(badge, L($"{count} richtig in Folge"));
        AutomationProperties.SetName(badge, L($"{count} richtig in Folge"));
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
        if (AppDevice.IsPhone) return PhoneBar(status, trailing);
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

    static readonly List<WeakReference<Control>> s_phoneBars = [];

    /// <summary>
    /// Phone: a study screen's action bar, for the toasts to stand right above it (<see cref="ShownPhoneBar"/>). Bars
    /// made but never shown (a ViewThatFits variant) are dropped as newer ones come.
    /// </summary>
    public static void RegisterPhoneBar(Control bar)
    {
        s_phoneBars.RemoveAll(r => !r.TryGetTarget(out _));
        if (s_phoneBars.Count >= 8) s_phoneBars.RemoveAt(0);
        s_phoneBars.Add(new WeakReference<Control>(bar));
    }

    /// <summary>The action bar on screen (phone), null when the screen has none.</summary>
    public static Control? ShownPhoneBar()
    {
        for (int i = s_phoneBars.Count - 1; i >= 0; i--)
            if (s_phoneBars[i].TryGetTarget(out var bar) && bar.IsEffectivelyVisible && TopLevel.GetTopLevel(bar) is not null) return bar;
        return null;
    }

    /// <summary>
    /// Phone: the pill on its own line above the buttons, which share the width (the Enter action, the widest, on the
    /// right); a single button takes the whole width.
    /// </summary>
    static Control PhoneBar(Control? status, IEnumerable<Control?> trailing)
    {
        var buttons = trailing.OfType<Control>().ToList();
        var stack = new StackPanel { Spacing = 8, Margin = new Thickness(12, 8, 12, 12), VerticalAlignment = VerticalAlignment.Bottom };
        RegisterPhoneBar(stack);
        if (status is not null)
        {
            status.HorizontalAlignment = HorizontalAlignment.Stretch;
            stack.Children.Add(status);
        }
        // Three or more: the last (the Enter action) gets a line of its own under the others.
        Control? last = null;
        if (buttons.Count >= 3)
        {
            last = buttons[^1];
            buttons.RemoveAt(buttons.Count - 1);
        }
        if (buttons.Count > 0)
        {
            var row = new Grid { ColumnSpacing = 8 };
            for (int i = 0; i < buttons.Count; i++)
            {
                row.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
                var b = buttons[i];
                b.HorizontalAlignment = HorizontalAlignment.Stretch;
                if (b is WsButton wb)
                {
                    StudyChrome.Floating(wb);
                    wb.Focusable = false;
                    if (wb.Chrome.Child is { } inner) inner.HorizontalAlignment = HorizontalAlignment.Center;
                }
                Grid.SetColumn(b, i);
                row.Children.Add(b);
            }
            stack.Children.Add(row);
        }
        if (last is not null)
        {
            last.HorizontalAlignment = HorizontalAlignment.Stretch;
            if (last is WsButton lb)
            {
                StudyChrome.Floating(lb);
                lb.Focusable = false;
                if (lb.Chrome.Child is { } inner) inner.HorizontalAlignment = HorizontalAlignment.Center;
            }
            stack.Children.Add(last);
        }
        return stack;
    }
}
