using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Layout;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// Styles for the Simple theme's controls (text fields, tooltips, scroll bars, check boxes, combo boxes) in the
/// Glas look. Built from WsTheme.P; MainWindow rebuilds them when the appearance changes.
/// </summary>
public static class AppStyles
{
    public static Styles Create()
    {
        var p = WsTheme.P;
        var styles = new Styles();

        // Text fields: rounded, accent border when focused.
        styles.Add(new Style(x => x.OfType<TextBox>().Class("ws").Template().OfType<Border>())
        {
            Setters = { new Setter(Border.CornerRadiusProperty, new CornerRadius(14)) },
        });
        styles.Add(new Style(x => x.OfType<TextBox>().Class("ws").Class(":focus").Template().OfType<Border>().Name("border"))
        {
            Setters = { new Setter(Border.BorderBrushProperty, WsTheme.B(p.Accent)), new Setter(Border.BorderThicknessProperty, new Thickness(2)) },
        });
        styles.Add(new Style(x => x.OfType<TextBox>().Class("ws").Class(":pointerover").Template().OfType<Border>().Name("border"))
        {
            Setters = { new Setter(Border.BorderBrushProperty, WsTheme.B(p.Accent)) },
        });
        styles.Add(new Style(x => x.OfType<TextBox>())
        {
            Setters =
            {
                new Setter(TextBox.SelectionBrushProperty, WsTheme.B(Palette.Hex(Ui.Rgb(p.Accent), 0.35))),
                new Setter(TextBox.CaretBrushProperty, WsTheme.B(p.Accent)),
                new Setter(TemplatedControl.FontFamilyProperty, WsTheme.UI),
            },
        });

        // A field inside a box that draws its own frame (the study answer box): no frame, no background in any state.
        foreach (var state in new[] { "", ":pointerover", ":focus" })
        {
            styles.Add(new Style(x => (state.Length == 0 ? x.OfType<TextBox>().Class("bare") : x.OfType<TextBox>().Class("bare").Class(state)).Template().OfType<Border>())
            {
                Setters =
                {
                    new Setter(Border.BackgroundProperty, Brushes.Transparent),
                    new Setter(Border.BorderThicknessProperty, new Thickness(0)),
                },
            });
        }

        // Tooltips: small glass label.
        styles.Add(new Style(x => x.OfType<ToolTip>())
        {
            Setters =
            {
                new Setter(TemplatedControl.BackgroundProperty, WsTheme.B(p.Dark ? Palette.Hex(0x2E3142) : Palette.Hex(0xFFFFFF, 0.96))),
                new Setter(TemplatedControl.ForegroundProperty, WsTheme.B(p.Text)),
                new Setter(TemplatedControl.BorderBrushProperty, WsTheme.B(p.Hairline)),
                new Setter(TemplatedControl.CornerRadiusProperty, new CornerRadius(8)),
                new Setter(TemplatedControl.PaddingProperty, new Thickness(8, 4)),
                new Setter(TemplatedControl.FontFamilyProperty, WsTheme.UI),
                new Setter(TemplatedControl.FontSizeProperty, 12.5),
            },
        });

        // Scroll bars: thin, no arrow buttons, a rounded quiet thumb (Mac: overlay scroll bars).
        styles.Add(new Style(x => x.OfType<ScrollBar>())
        {
            Setters = { new Setter(TemplatedControl.BackgroundProperty, Brushes.Transparent) },
        });
        styles.Add(new Style(x => x.OfType<ScrollBar>().Class(":vertical"))
        {
            Setters = { new Setter(Layoutable.WidthProperty, 10.0), new Setter(Layoutable.MinWidthProperty, 10.0) },
        });
        styles.Add(new Style(x => x.OfType<ScrollBar>().Class(":horizontal"))
        {
            Setters = { new Setter(Layoutable.HeightProperty, 10.0), new Setter(Layoutable.MinHeightProperty, 10.0) },
        });
        styles.Add(new Style(x => x.OfType<ScrollBar>().Template().OfType<Grid>().Child().OfType<RepeatButton>())
        {
            Setters = { new Setter(Visual.IsVisibleProperty, false) },
        });
        styles.Add(new Style(x => x.OfType<ScrollBar>().Template().OfType<Thumb>())
        {
            Setters =
            {
                new Setter(TemplatedControl.BackgroundProperty, WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.28) : Palette.Hex(0x101828, 0.22))),
                new Setter(TemplatedControl.CornerRadiusProperty, new CornerRadius(4)),
                new Setter(Layoutable.MarginProperty, new Thickness(2)),
            },
        });
        styles.Add(new Style(x => x.OfType<ScrollBar>().Template().OfType<Thumb>().Template().OfType<Border>())
        {
            Setters = { new Setter(Border.CornerRadiusProperty, new CornerRadius(4)) },
        });

        // Check boxes, radio buttons and combo boxes take the text colour and the accent.
        foreach (var type in new[] { typeof(CheckBox), typeof(RadioButton), typeof(ComboBox), typeof(ComboBoxItem), typeof(ToggleSwitch) })
        {
            styles.Add(new Style(x => x.OfType(type))
            {
                Setters =
                {
                    new Setter(TemplatedControl.ForegroundProperty, WsTheme.B(p.Text)),
                    new Setter(TemplatedControl.FontFamilyProperty, WsTheme.UI),
                    new Setter(TemplatedControl.FontSizeProperty, 14.0),
                },
            });
        }
        styles.Add(new Style(x => x.OfType<ComboBox>())
        {
            Setters =
            {
                new Setter(TemplatedControl.BackgroundProperty, WsTheme.B(p.Field)),
                new Setter(TemplatedControl.BorderBrushProperty, WsTheme.B(p.Hairline)),
                new Setter(TemplatedControl.CornerRadiusProperty, new CornerRadius(10)),
                new Setter(TemplatedControl.PaddingProperty, new Thickness(10, 6)),
                new Setter(Layoutable.MinHeightProperty, 36.0),
            },
        });
        styles.Add(new Style(x => x.OfType<ComboBoxItem>())
        {
            Setters = { new Setter(TemplatedControl.PaddingProperty, new Thickness(10, 6)) },
        });
        styles.Add(new Style(x => x.OfType<ContextMenu>())
        {
            Setters =
            {
                new Setter(TemplatedControl.BackgroundProperty, WsTheme.B(p.Dark ? Palette.Hex(0x2E3142) : Palette.Hex(0xFFFFFF))),
                new Setter(TemplatedControl.CornerRadiusProperty, new CornerRadius(10)),
            },
        });
        styles.Add(new Style(x => x.OfType<MenuItem>())
        {
            Setters =
            {
                new Setter(TemplatedControl.ForegroundProperty, WsTheme.B(p.Text)),
                new Setter(TemplatedControl.FontFamilyProperty, WsTheme.UI),
            },
        });
        styles.Add(new Style(x => x.OfType<Window>())
        {
            Setters = { new Setter(TemplatedControl.FontFamilyProperty, WsTheme.UI) },
        });
        // Phone: thin scroll bars over the content that only show while scrolling (PhoneLayout).
        if (AppDevice.IsPhone)
        {
            styles.Add(PhoneLayout.ScrollBarStyles());
            // Phone: drop-down lists looked like Windows – the Simple theme's petrol selection, small rows, the list cut
            // at the bottom of the screen (Joan's phone, 06.11.2026). The app's accent, finger-sized rows, a list that
            // scrolls instead of running off the screen, menus with taller items.
            var accent = p.Accent;
            styles.Resources["ThemeAccentBrush"] = new SolidColorBrush(accent);
            styles.Resources["ThemeAccentBrush2"] = new SolidColorBrush(accent, 0.8);
            styles.Resources["ThemeAccentBrush3"] = new SolidColorBrush(accent, 0.45);
            styles.Resources["ThemeAccentBrush4"] = new SolidColorBrush(accent, 0.22);
            styles.Resources["ThemeControlHighlightMidBrush"] = WsTheme.B(p.AccentSoft);
            styles.Add(new Style(x => x.OfType<ComboBoxItem>())
            {
                Setters =
                {
                    new Setter(TemplatedControl.PaddingProperty, new Thickness(16, 12)),
                    new Setter(Layoutable.MinHeightProperty, 46.0),
                    new Setter(TemplatedControl.FontSizeProperty, 15.0),
                },
            });
            styles.Add(new Style(x => x.OfType<ComboBox>())
            {
                Setters =
                {
                    new Setter(ComboBox.MaxDropDownHeightProperty, 300.0),
                    new Setter(Layoutable.MinHeightProperty, 44.0),
                    new Setter(TemplatedControl.CornerRadiusProperty, new CornerRadius(12)),
                },
            });
            // The open list: rounded and in the app's colours like the menus (it was an angular grey box).
            styles.Add(new Style(x => x.OfType<ComboBox>().Template().OfType<Avalonia.Controls.Primitives.Popup>().Name("PART_Popup").Descendant().OfType<Border>())
            {
                Setters =
                {
                    new Setter(Border.CornerRadiusProperty, new CornerRadius(14)),
                    new Setter(Border.BackgroundProperty, WsTheme.B(p.Dark ? Palette.Hex(0x2E3142) : Palette.Hex(0xFFFFFF))),
                    new Setter(Border.BorderBrushProperty, WsTheme.B(p.Hairline)),
                    new Setter(Border.ClipToBoundsProperty, true),
                },
            });
            styles.Add(new Style(x => x.OfType<MenuItem>())
            {
                Setters =
                {
                    new Setter(TemplatedControl.PaddingProperty, new Thickness(14, 12)),
                    new Setter(TemplatedControl.FontSizeProperty, 15.0),
                },
            });
            styles.Add(new Style(x => x.OfType<ContextMenu>())
            {
                Setters = { new Setter(TemplatedControl.CornerRadiusProperty, new CornerRadius(14)) },
            });
        }
        return styles;
    }
}
