using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.DesignSystem;

/// <summary>Visual state of a multiple-choice tile (Mac: ChoiceTileState).</summary>
public enum ChoiceTileState
{
    /// <summary>Waiting for an answer.</summary>
    Idle,
    /// <summary>The keyboard highlight (arrows, or the letters typed): Enter chooses this tile.</summary>
    Highlighted,
    /// <summary>Waiting, but the letters typed so far do not start this answer.</summary>
    Filtered,
    /// <summary>The right answer (after answering).</summary>
    Correct,
    /// <summary>The answer the learner chose, and it was wrong.</summary>
    Wrong,
    /// <summary>Any other tile after answering.</summary>
    Dimmed,
}

/// <summary>
/// A multiple-choice answer on glass with its number badge (1-4), port of mac/Wortschatz/DesignSystem/ChoiceTile.swift.
/// Each tile is its own glass below the prompt card; ChoiceGrid lays them out 2×2. When a tile turns correct or wrong
/// its badge bounces, a wrong one also shakes.
/// </summary>
public static class ChoiceTile
{
    static Palette P => WsTheme.P;

    public static ChoiceTileState From(LearnFlow.OptionState option) => option switch
    {
        LearnFlow.OptionState.Highlighted => ChoiceTileState.Highlighted,
        LearnFlow.OptionState.Filtered => ChoiceTileState.Filtered,
        LearnFlow.OptionState.Correct => ChoiceTileState.Correct,
        LearnFlow.OptionState.Wrong => ChoiceTileState.Wrong,
        LearnFlow.OptionState.Dimmed => ChoiceTileState.Dimmed,
        _ => ChoiceTileState.Idle,
    };

    static bool IsAnswered(ChoiceTileState s) => s is ChoiceTileState.Correct or ChoiceTileState.Wrong or ChoiceTileState.Dimmed;

    /// <param name="previous">The tile's state before this render (its change plays the bounce/shake).</param>
    public static Control Create(int number, string text, ChoiceTileState state, LearnFlow.TextRange? emphasis, Lang lang,
        Action onChoose, Action? onHover = null, ChoiceTileState? previous = null)
    {
        var (tint, ring) = state switch
        {
            ChoiceTileState.Highlighted => ((Color?)Palette.Hex(Ui.Rgb(P.Accent), 0.14), (Color?)P.Accent),
            ChoiceTileState.Correct => (Palette.Hex(Ui.Rgb(P.Success.Fill), 0.28), P.Success.Fill),
            ChoiceTileState.Wrong => (Palette.Hex(Ui.Rgb(P.Failure.Fill), 0.26), P.Failure.Fill),
            _ => (null, null),
        };
        var badge = Badge(number, state);
        var label = StudyText.Underlined(text, emphasis, P.Text, 18);
        label.MaxLines = 3;
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        if (lang.IsRTL())
        {
            // Arabic starts at the right edge (Mac: cardTextLine); Ui.Text pins the alignment to the left otherwise.
            label.FlowDirection = FlowDirection.RightToLeft;
            label.TextAlignment = TextAlignment.Start;
        }
        var row = new Avalonia.Controls.Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 16, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(badge);
        Avalonia.Controls.Grid.SetColumn(label, 1);
        row.Children.Add(label);
        row.Opacity = state == ChoiceTileState.Dimmed ? 0.4 : state == ChoiceTileState.Filtered ? 0.5 : 1;

        var tile = new WsButton(row, ButtonKind.Glass, double.NaN, 20, new Thickness(20, 16))
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            Focusable = false,
        };
        tile.Chrome.MinHeight = 84;
        tile.Chrome.Height = double.NaN;
        var glass = P.GlassStrong;
        var normal = tint is { } t ? Blend(glass, t) : glass;
        tile.SetColors(normal, IsAnswered(state) ? normal : Blend(normal, P.Dark ? Palette.Hex(0xFFFFFF, 0.06) : Palette.Hex(0xFFFFFF, 0.5)), normal, ring ?? P.GlassBorder);
        tile.Chrome.BorderThickness = new Thickness(ring is null ? 1 : 2);
        tile.Chrome.BoxShadow = BoxShadows.Parse($"0 8 20 -12 {WsButton.Hex(P.Shadow, P.Shadow.A / 255.0 * 0.9)}");
        if (!IsAnswered(state)) tile.Click += (_, _) => onChoose();
        // A moving pointer marks the tile, not one resting where the next question's tiles appear: Avalonia reports the
        // new tile under a still pointer as entered, and the mark rebuilt the screen ~40 ms into the new question's
        // entrance, cutting it short (half the questions answered with the mouse, laptop 26.11.2026).
        if (onHover is not null) tile.PointerMoved += (_, _) => onHover();
        AutomationProperties.SetName(tile, text);
        AutomationProperties.SetHelpText(tile, state switch
        {
            ChoiceTileState.Correct => L("Richtige Antwort"),
            ChoiceTileState.Wrong => L("Deine Antwort, falsch"),
            ChoiceTileState.Dimmed => "",
            _ => L($"Antwort {number}, Taste {number}"),
        });
        if (previous is { } before && before != state && state is ChoiceTileState.Correct or ChoiceTileState.Wrong)
        {
            Effects.Pop(badge, 1.25);
            if (state == ChoiceTileState.Wrong) Effects.Shake(tile, 7);
        }
        return tile;
    }

    static Control Badge(int number, ChoiceTileState state)
    {
        switch (state)
        {
            case ChoiceTileState.Correct:
                return StudyStatusPill.FeedbackSymbol(StudyStatus.Kinds.Correct, P.Success.Fill, 28);
            case ChoiceTileState.Wrong:
                return StudyStatusPill.FeedbackSymbol(StudyStatus.Kinds.Wrong, P.Failure.Fill, 28);
            case var _ when !AppDevice.ShowsKeyHints:
                // Phone: no keys 1–4 to press – an empty round mark to tap (like a radio button), which the answer
                // turns into the round ✓ or ✗ in the same place.
                return new Border
                {
                    Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Margin = new Thickness(1),
                    BorderBrush = WsTheme.B(state == ChoiceTileState.Highlighted ? P.Accent : P.TextTertiary), BorderThickness = new Thickness(1.6),
                    Opacity = state == ChoiceTileState.Highlighted ? 1 : 0.7,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            case ChoiceTileState.Highlighted:
                return new Border
                {
                    Width = 28, Height = 28, CornerRadius = new CornerRadius(8), Background = WsTheme.B(P.Accent),
                    Child = new TextBlock { Text = $"{number}", FontFamily = WsTheme.Prompt, FontSize = 14, FontWeight = FontWeight.Bold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                    VerticalAlignment = VerticalAlignment.Center,
                };
            default:
                return new Border
                {
                    Width = 28, Height = 28, CornerRadius = new CornerRadius(8), Background = WsTheme.B(P.KeyCap),
                    BorderBrush = WsTheme.B(P.Hairline), BorderThickness = new Thickness(0.5),
                    Child = new TextBlock { Text = $"{number}", FontFamily = WsTheme.Prompt, FontSize = 14, FontWeight = FontWeight.Bold, Foreground = WsTheme.B(P.TextSecondary), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                    VerticalAlignment = VerticalAlignment.Center,
                };
        }
    }

    /// <summary>A colour over another (source-over), for tinted glass in one brush.</summary>
    public static Color Blend(Color under, Color over)
    {
        double a = over.A / 255.0, b = under.A / 255.0;
        double outA = a + b * (1 - a);
        if (outA <= 0) return Colors.Transparent;
        byte Mix(byte o, byte u) => (byte)Math.Round((o * a + u * b * (1 - a)) / outA);
        return Color.FromArgb((byte)Math.Round(outA * 255), Mix(over.R, under.R), Mix(over.G, under.G), Mix(over.B, under.B));
    }

    /// <summary>The 2×2 grid (Mac: ChoiceGrid): tiles numbered 1…n, rows of equal height, 14 points apart.</summary>
    public static Avalonia.Controls.Grid Grid(IReadOnlyList<Control> tiles)
    {
        // Phone upright: one column (two would leave each answer a word wide); sideways two again.
        int columns = AppDevice.IsWide ? 2 : 1;
        var grid = new Avalonia.Controls.Grid { ColumnDefinitions = new ColumnDefinitions(columns == 1 ? "*" : "*,*"), ColumnSpacing = 14, RowSpacing = columns == 1 ? 10 : 14 };
        int rows = (tiles.Count + columns - 1) / columns;
        for (int r = 0; r < rows; r++) grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        for (int i = 0; i < tiles.Count; i++)
        {
            Avalonia.Controls.Grid.SetRow(tiles[i], i / columns);
            Avalonia.Controls.Grid.SetColumn(tiles[i], i % columns);
            grid.Children.Add(tiles[i]);
        }
        return grid;
    }
}
