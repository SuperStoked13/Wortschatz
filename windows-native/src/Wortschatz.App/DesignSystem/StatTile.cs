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
        var head = Ui.H(8, badge, Ui.Text(title, 14, FontWeight.Medium, p.TextSecondary));
        var number = Ui.Text(value, 34, FontWeight.Bold, p.Text, font: WsTheme.Prompt);
        var valueRow = Ui.H(5, number, unit is null ? null : Ui.Text(unit, 19, FontWeight.Medium, p.TextSecondary));
        if (unit is not null) ((TextBlock)valueRow.Children[^1]).VerticalAlignment = VerticalAlignment.Bottom;
        number.VerticalAlignment = VerticalAlignment.Bottom;
        var stack = Ui.V(12, head, valueRow, caption is null ? null : Ui.Text(caption, 12, color: p.TextSecondary));
        var tile = Ui.Glass(stack, 20, new Thickness(20), shadow: false);
        AutomationProperties.SetName(tile, $"{title}: {string.Join(" ", new[] { value, unit, caption }.Where(s => s is not null))}");
        return tile;
    }

    /// <summary>Tiles side by side, sharing the width equally (Mac: HStack of StatTiles with .infinity widths).</summary>
    public static Grid Row(double spacing, params Control[] tiles)
    {
        var grid = new Grid { ColumnSpacing = spacing };
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
        var row = Ui.H(12, actions);
        row.HorizontalAlignment = HorizontalAlignment.Center;
        var stack = Ui.V(20, symbol, texts, row);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        return stack;
    }
}
