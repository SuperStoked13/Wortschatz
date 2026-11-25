using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// A row of buttons that picks the first layout that fits (Mac: <c>ViewThatFits</c> over an HStack of large buttons, an
/// HStack of regular ones and a FlowLayout): large buttons in one line, else regular ones in one line, else regular
/// ones wrapped. The natural width of each line is learned the first time it is laid out.
/// </summary>
public sealed class AdaptiveRow : Decorator
{
    public enum Mode { Large, Regular, Wrapped }

    readonly Func<Mode, IEnumerable<Control>> _make;
    readonly double _spacing;
    readonly Dictionary<Mode, double> _naturalWidth = [];
    Mode _mode = Mode.Large;

    public AdaptiveRow(Func<Mode, IEnumerable<Control>> make, double spacing = 10)
    {
        _make = make;
        _spacing = spacing;
        Build();
    }

    void Build()
    {
        Panel panel = _mode == Mode.Wrapped
            ? new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = _spacing - 2, LineSpacing = _spacing - 2 }
            : new StackPanel { Orientation = Orientation.Horizontal, Spacing = _mode == Mode.Large ? _spacing : _spacing - 2 };
        foreach (var c in _make(_mode)) panel.Children.Add(c);
        Child = panel;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Child is StackPanel line)
        {
            line.Measure(new Size(double.PositiveInfinity, availableSize.Height));
            _naturalWidth[_mode] = line.DesiredSize.Width;
        }
        var wanted = Choose(availableSize.Width);
        if (wanted != _mode)
        {
            _mode = wanted;
            Build();
            if (Child is StackPanel next)
            {
                next.Measure(new Size(double.PositiveInfinity, availableSize.Height));
                _naturalWidth[_mode] = next.DesiredSize.Width;
                var again = Choose(availableSize.Width);
                if (again != _mode)
                {
                    _mode = again;
                    Build();
                }
            }
        }
        return base.MeasureOverride(availableSize);
    }

    Mode Choose(double available)
    {
        if (double.IsInfinity(available)) return Mode.Large;
        foreach (var mode in new[] { Mode.Large, Mode.Regular })
        {
            if (!_naturalWidth.TryGetValue(mode, out var width)) return mode;
            if (width <= available + 0.5) return mode;
        }
        return Mode.Wrapped;
    }
}
