using Avalonia;
using Avalonia.Controls;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// Shows the full form of a view while it fits the width it gets, else its compact form (Mac: <c>ViewThatFits</c> with a
/// regular and a compact bar). <c>make(false)</c> builds the full form, <c>make(true)</c> the compact one; the full form's
/// natural width (measured with unlimited width, margins included) is learned each time it is shown, so the view
/// switches back once the window is wide enough again.
/// </summary>
public sealed class ViewThatFits : Decorator
{
    readonly Func<bool, Control> _make;
    double _fullWidth = double.NaN;

    public ViewThatFits(Func<bool, Control> make)
    {
        _make = make;
        Child = make(false);
    }

    /// <summary>The compact form is shown.</summary>
    public bool IsCompact { get; private set; }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (!double.IsInfinity(availableSize.Width) && Child is { } child)
        {
            if (!IsCompact)
            {
                child.Measure(new Size(double.PositiveInfinity, availableSize.Height));
                _fullWidth = child.DesiredSize.Width;
                if (_fullWidth > availableSize.Width + 0.5)
                {
                    IsCompact = true;
                    Child = _make(true);
                }
            }
            else if (!double.IsNaN(_fullWidth) && _fullWidth <= availableSize.Width + 0.5)
            {
                IsCompact = false;
                Child = _make(false);
            }
        }
        return base.MeasureOverride(availableSize);
    }
}
