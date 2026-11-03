using Avalonia;
using Avalonia.Controls;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// A grid of equal columns that fills the width (Mac: <c>LazyVGrid(columns: [GridItem(.adaptive(minimum:maximum:))])</c>):
/// as many columns as fit at MinItemWidth, each as wide as the room allows up to MaxItemWidth; the items of a row share
/// the row's height.
/// </summary>
public sealed class AdaptiveGrid : Panel
{
    public double MinItemWidth { get; init; } = 270;
    public double MaxItemWidth { get; init; } = 420;
    public double Spacing { get; init; } = 12;

    (int Columns, double Width) Columns(double available)
    {
        if (double.IsInfinity(available)) available = MaxItemWidth * 3 + Spacing * 2;
        int columns = Math.Max(1, (int)Math.Floor((available + Spacing) / (MinItemWidth + Spacing)));
        double width = Math.Min(MaxItemWidth, (available - Spacing * (columns - 1)) / columns);
        return (columns, Math.Max(0, width));
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var (columns, width) = Columns(availableSize.Width);
        double height = 0, rowHeight = 0;
        for (int i = 0; i < Children.Count; i++)
        {
            Children[i].Measure(new Size(width, double.PositiveInfinity));
            rowHeight = Math.Max(rowHeight, Children[i].DesiredSize.Height);
            if (i % columns == columns - 1 || i == Children.Count - 1)
            {
                height += rowHeight + (height > 0 ? Spacing : 0);
                rowHeight = 0;
            }
        }
        double used = Math.Min(Children.Count, columns) * width + Spacing * (Math.Min(Children.Count, columns) - 1);
        return new Size(double.IsInfinity(availableSize.Width) ? used : availableSize.Width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var (columns, width) = Columns(finalSize.Width);
        double y = 0;
        for (int start = 0; start < Children.Count; start += columns)
        {
            int end = Math.Min(Children.Count, start + columns);
            double rowHeight = 0;
            for (int i = start; i < end; i++) rowHeight = Math.Max(rowHeight, Children[i].DesiredSize.Height);
            for (int i = start; i < end; i++) Children[i].Arrange(new Rect((i - start) * (width + Spacing), y, width, rowHeight));
            y += rowHeight + Spacing;
        }
        return finalSize;
    }
}
