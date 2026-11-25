using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;


namespace Wortschatz.App.DesignSystem;

/// <summary>
/// A glass statistic tile for the overview and results (Mac: StatTile.swift): a white symbol on a tinted rounded square,
/// the title, a big number with an optional unit and an optional caption.
/// </summary>
public static class StatTile
{
    public static Control Create(string title, string value, IconName icon, Color tint, string? unit = null, string? caption = null)
    {
        var p = WsTheme.P;
        var badge = new Border
        {
            Width = 26,
            Height = 26,
            CornerRadius = new CornerRadius(8),
            Background = ProgressLine.Gradient(tint),
            Child = Icons.Icon(icon, 15, Colors.White, 2.2),
        };
        badge.Child.HorizontalAlignment = HorizontalAlignment.Center;
        badge.Child.VerticalAlignment = VerticalAlignment.Center;
        bool phone = AppDevice.IsPhone;
        // Phone: three tiles share ~360 points: the title under the symbol, wrapped, smaller numbers.
        if (phone) badge.HorizontalAlignment = HorizontalAlignment.Left; // over the title, not centred above left-aligned text
        Control head = phone
            ? Ui.V(6, badge, Ui.Text(title, 12, FontWeight.Medium, p.TextSecondary, TextWrapping.Wrap))
            : Ui.H(8, badge, Ui.Text(title, 14, FontWeight.Medium, p.TextSecondary));
        var number = Ui.Text(value, phone ? 26 : 34, FontWeight.Bold, p.Text, font: WsTheme.Prompt);
        CountTo(title, number, value);
        var valueRow = Ui.H(5, number, unit is null ? null : Ui.Text(unit, phone ? 15 : 19, FontWeight.Medium, p.TextSecondary));
        if (unit is not null) ((TextBlock)valueRow.Children[^1]).VerticalAlignment = VerticalAlignment.Bottom;
        number.VerticalAlignment = VerticalAlignment.Bottom;
        var captionText = caption is null ? null : Ui.Text(caption, phone ? 11 : 12, color: p.TextSecondary, wrap: phone ? TextWrapping.Wrap : TextWrapping.NoWrap);
        Control stack;
        if (!phone) stack = Ui.V(12, head, valueRow, captionText);
        else
        {
            // Phone: a title in two lines («Heute beantwortet») pushed its number below the one beside it; the rows
            // share their heights across the tiles of a Row (shared size groups), so the numbers line up.
            var grid = new Grid { RowSpacing = 6 };
            foreach (var group in new[] { "StatHead", "StatValue", "StatCaption" })
                grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto) { SharedSizeGroup = group });
            grid.Children.Add(head);
            Grid.SetRow(valueRow, 1);
            grid.Children.Add(valueRow);
            if (captionText is not null)
            {
                Grid.SetRow(captionText, 2);
                grid.Children.Add(captionText);
            }
            stack = grid;
        }
        var tile = Ui.Glass(stack, 20, new Thickness(phone ? 12 : 20), shadow: false);
        AutomationProperties.SetName(tile, $"{title}: {string.Join(" ", new[] { value, unit, caption }.Where(s => s is not null))}");
        return tile;
    }

    /// <summary>The number of each tile title that is on screen, to count from when the tile is built anew.</summary>
    static readonly Dictionary<string, WeakReference<TextBlock>> Shown = [];

    /// <summary>
    /// A number that changed while its tile is on screen counts to the new value (Mac: <c>.contentTransition(.numericText())</c>,
    /// e.g. "Heute beantwortet" after an answer). A tile that appears fresh shows its value at once; Reduce Motion too.
    /// </summary>
    static void CountTo(string title, TextBlock number, string value)
    {
        bool onScreen = Shown.TryGetValue(title, out var weak) && weak.TryGetTarget(out var old) && TopLevel.GetTopLevel(old) is not null;
        string? before = onScreen && weak!.TryGetTarget(out var previous) ? previous.Text : null;
        Shown[title] = new WeakReference<TextBlock>(number);
        if (Motion.ReduceMotion || Motion.IsSnapshot || before is null || before == value) return;
        if (!int.TryParse(before, out var from) || !int.TryParse(value, out var to)) return;
        var count = new AnimatedValue(from);
        number.Text = before;
        count.Changed += () => number.Text = ((int)Math.Round(count.Value)).ToString(System.Globalization.CultureInfo.InvariantCulture);
        count.Set(to, Motion.Soft(Math.Min(0.8, 0.35 + 0.05 * Math.Abs(to - from))), () => number.Text = value);
    }

    /// <summary>Tiles side by side, sharing the width equally (Mac: HStack of StatTiles with .infinity widths).</summary>
    public static Grid Row(double spacing, params Control[] tiles)
    {
        // Phone: at most three side by side (four: two by two); more go on a second line, whose tiles share its whole
        // width (five: three and two, without a gap at the end). Six grid columns: a tile spans two, three or six.
        if (AppDevice.IsPhone && tiles.Length > 3)
        {
            int columns = tiles.Length == 4 ? 2 : 3;
            var wrapped = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
            Grid.SetIsSharedSizeScope(wrapped, true);
            for (int c = 0; c < 6; c++) wrapped.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
            int rows = (tiles.Length + columns - 1) / columns;
            for (int r = 0; r < rows; r++) wrapped.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            for (int i = 0; i < tiles.Length; i++)
            {
                int row = i / columns;
                int inRow = row < rows - 1 ? columns : tiles.Length - row * columns;
                int span = 6 / inRow;
                Grid.SetColumn(tiles[i], i % columns * span);
                Grid.SetColumnSpan(tiles[i], span);
                Grid.SetRow(tiles[i], row);
                wrapped.Children.Add(tiles[i]);
            }
            return wrapped;
        }
        var grid = new Grid { ColumnSpacing = AppDevice.IsPhone ? 8 : spacing };
        if (AppDevice.IsPhone) Grid.SetIsSharedSizeScope(grid, true);
        for (int i = 0; i < tiles.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
            Grid.SetColumn(tiles[i], i);
            grid.Children.Add(tiles[i]);
        }
        return grid;
    }
}

/// <summary>
/// A centred empty state (Mac: EmptyStateView.swift): a large accent symbol on a soft glow, a title, an optional message
/// and the actions in a row.
/// </summary>
public static class EmptyStateView
{
    public static Control Create(IconName icon, string title, string? message, params Control[] actions)
    {
        var p = WsTheme.P;
        var glow = new Border
        {
            Width = 140,
            Height = 140,
            CornerRadius = new CornerRadius(70),
            Background = new RadialGradientBrush
            {
                GradientStops = { new GradientStop(Palette.Hex(Ui.Rgb(p.Accent), 0.22), 0.07), new GradientStop(Palette.Hex(Ui.Rgb(p.Accent), 0), 0.5) },
                RadiusX = new RelativeScalar(1, RelativeUnit.Relative),
                RadiusY = new RelativeScalar(1, RelativeUnit.Relative),
            },
        };
        var symbol = new Grid { Height = 112, Width = 140 };
        glow.VerticalAlignment = VerticalAlignment.Center;
        symbol.Children.Add(glow);
        var iconView = Icons.Icon(icon, 54, p.Accent, 1.6);
        iconView.HorizontalAlignment = HorizontalAlignment.Center;
        iconView.VerticalAlignment = VerticalAlignment.Center;
        symbol.Children.Add(iconView);
        symbol.HorizontalAlignment = HorizontalAlignment.Center;
        var titleText = Ui.Text(title, 22, FontWeight.Bold, align: TextAlignment.Center, wrap: TextWrapping.Wrap, font: WsTheme.Prompt);
        titleText.HorizontalAlignment = HorizontalAlignment.Center;
        var texts = Ui.V(8, titleText);
        if (message is not null)
        {
            var m = Ui.Text(message, 15, color: p.TextSecondary, wrap: TextWrapping.Wrap, align: TextAlignment.Center);
            m.MaxWidth = 440;
            m.HorizontalAlignment = HorizontalAlignment.Center;
            texts.Children.Add(m);
        }
        StackPanel row;
        if (AppDevice.IsPhone && actions.Length > 1)
        {
            // Phone: four buttons side by side ran off the screen («Alles gemeistert!» showed two of four, 06.11.2026);
            // one under the other, full width, the main action (the last one) on top.
            row = Ui.V(10, actions.Reverse().ToArray());
            foreach (var a in actions) a.HorizontalAlignment = HorizontalAlignment.Stretch;
            row.HorizontalAlignment = HorizontalAlignment.Stretch;
            row.MaxWidth = 420;
        }
        else
        {
            row = Ui.H(12, actions);
            row.HorizontalAlignment = HorizontalAlignment.Center;
        }
        var stack = Ui.V(20, symbol, texts, row);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        return stack;
    }
}
