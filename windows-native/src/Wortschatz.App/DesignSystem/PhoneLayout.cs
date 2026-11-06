using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// Makes the PC layouts fit a phone without a phone version of every screen (installed by <see cref="MainView"/> when
/// <see cref="AppDevice.IsPhone"/>). The screens give cards and columns fixed widths for a window of 1000+ points (a
/// study column of 760, a sheet of 480 …); on a phone any fixed width above <see cref="MaxFixedWidth"/> becomes a
/// maximum instead: the element takes the screen's width and is never cut off. Small fixed widths (icons, badges,
/// rings) stay. New screens get this for free; only rows that put too much side by side need a phone variant
/// (<see cref="AppDevice.IsPhone"/> in the screen).
/// </summary>
public static class PhoneLayout
{
    /// <summary>Wider than this does not fit next to the margins of a 360-point phone.</summary>
    public const double MaxFixedWidth = 320;

    static bool s_installed;

    /// <summary>Marks an element whose fixed width became a maximum (its alignment stays Stretch).</summary>
    static readonly AttachedProperty<bool> FittedProperty = AvaloniaProperty.RegisterAttached<PhoneLayoutOwner, Control, bool>("Fitted");

    public static void Install()
    {
        if (s_installed) return;
        s_installed = true;
        Layoutable.WidthProperty.Changed.AddClassHandler<Control>((control, e) =>
        {
            if (!AppDevice.IsPhone || e.NewValue is not double width || double.IsNaN(width) || width <= MaxFixedWidth) return;
            control.MaxWidth = Math.Min(control.MaxWidth, width);
            control.SetValue(FittedProperty, true);
            control.Width = double.NaN;
            control.HorizontalAlignment = HorizontalAlignment.Stretch;
        });
        // Centred or left-aligned without its width it would shrink to its content: it stays stretched (centred by its
        // maximum width where the screen is wider).
        Layoutable.HorizontalAlignmentProperty.Changed.AddClassHandler<Control>((control, e) =>
        {
            if (control.GetValue(FittedProperty) && e.NewValue is HorizontalAlignment a && a != HorizontalAlignment.Stretch)
                control.HorizontalAlignment = HorizontalAlignment.Stretch;
        });
        Layoutable.MinWidthProperty.Changed.AddClassHandler<Control>((control, e) =>
        {
            if (!AppDevice.IsPhone || e.NewValue is not double width || width <= MaxFixedWidth) return;
            control.MinWidth = 0;
        });
        InstallScrollBars();
    }

    /// <summary>
    /// Scroll bars as on Android: a thin line over the edge of the content that shows while it scrolls and fades out
    /// after. The PC bar (Simple theme) took 10 points beside every page – the margins were uneven – and stood there
    /// all the time. A finger scrolls the content, so the line takes no touches.
    /// </summary>
    static void InstallScrollBars() =>
        ScrollViewer.ScrollChangedEvent.AddClassHandler<ScrollViewer>((viewer, e) =>
        {
            if (e.OffsetDelta == default) return;
            ShowScrollBars(viewer);
        });

    /// <summary>The styles of the phone's scroll bars (part of <see cref="AppStyles.Create"/> on a phone).</summary>
    public static Styles ScrollBarStyles() => new()
    {
        // The content takes the whole width and height, the bars lie over it.
        new Style(x => x.OfType<ScrollViewer>().Template().OfType<ScrollContentPresenter>().Name("PART_ContentPresenter"))
        {
            Setters = { new Setter(Grid.ColumnSpanProperty, 2), new Setter(Grid.RowSpanProperty, 2) },
        },
        new Style(x => x.OfType<ScrollBar>())
        {
            Setters = { new Setter(Visual.OpacityProperty, 0.0), new Setter(InputElement.IsHitTestVisibleProperty, false) },
        },
        new Style(x => x.OfType<ScrollBar>().Class(":vertical"))
        {
            Setters = { new Setter(Layoutable.WidthProperty, 6.0), new Setter(Layoutable.MinWidthProperty, 6.0) },
        },
        new Style(x => x.OfType<ScrollBar>().Class(":horizontal"))
        {
            Setters = { new Setter(Layoutable.HeightProperty, 6.0), new Setter(Layoutable.MinHeightProperty, 6.0) },
        },
        new Style(x => x.OfType<ScrollBar>().Template().OfType<Thumb>())
        {
            Setters = { new Setter(Layoutable.MarginProperty, new Thickness(1.5)) },
        },
        new Style(x => x.OfType<ScrollBar>().Class(Scrolling))
        {
            Setters = { new Setter(Visual.OpacityProperty, 1.0) },
        },
    };

    const string Scrolling = "ws-scrolling";

    /// <summary>The fade-out timer of each scroll viewer whose bars are showing.</summary>
    static readonly ConditionalWeakTable<ScrollViewer, DispatcherTimer> s_fades = [];

    static void ShowScrollBars(ScrollViewer viewer)
    {
        // The template's own bars only (the root grid's children), not those of a scroll viewer inside the content.
        if (viewer.GetVisualChildren().FirstOrDefault() is not { } root) return;
        var bars = root.GetVisualChildren().OfType<ScrollBar>().Where(b => b.Visibility != ScrollBarVisibility.Hidden && b.IsVisible).ToList();
        if (bars.Count == 0) return;
        foreach (var bar in bars)
        {
            bar.Transitions ??= [new DoubleTransition { Property = Visual.OpacityProperty, Duration = TimeSpan.FromMilliseconds(220) }];
            if (!bar.Classes.Contains(Scrolling)) bar.Classes.Add(Scrolling);
        }
        if (!s_fades.TryGetValue(viewer, out var timer))
        {
            timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(900) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                if (viewer.GetVisualChildren().FirstOrDefault() is { } r)
                    foreach (var bar in r.GetVisualChildren().OfType<ScrollBar>()) bar.Classes.Remove(Scrolling);
            };
            s_fades.Add(viewer, timer);
        }
        timer.Stop();
        timer.Start();
    }
}

/// <summary>Owner type of PhoneLayout's attached property (a static class cannot be one).</summary>
public sealed class PhoneLayoutOwner;
