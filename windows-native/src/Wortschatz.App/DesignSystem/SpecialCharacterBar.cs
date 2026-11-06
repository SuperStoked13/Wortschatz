using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Media;
using Wortschatz.Core;

namespace Wortschatz.App.DesignSystem;

/// <summary>Accent characters per language for written answers (Mac: SpecialCharacters in SpecialCharacterBar.swift).</summary>
public static class SpecialCharacters
{
    public static readonly IReadOnlyDictionary<Lang, string[]> ByLanguage = new Dictionary<Lang, string[]>
    {
        [Lang.Fr] = ["é", "è", "ê", "ë", "à", "â", "ç", "î", "ï", "ô", "û", "ù", "ü", "œ", "æ"],
        [Lang.De] = ["ä", "ö", "ü", "Ä", "Ö", "Ü"],
        [Lang.Es] = ["á", "é", "í", "ó", "ú", "ñ", "ü", "¿", "¡"],
        [Lang.It] = ["à", "è", "é", "ì", "ò", "ù"],
        [Lang.En] = [],
        // Arabic needs an Arabic keyboard (vowel marks never count); pinyin tones can be typed as numbers (ni3), so only ü.
        [Lang.Ar] = [],
        [Lang.Zh] = ["ü"],
        [Lang.Other] = [],
    };

    /// <summary>The characters for a language, empty when it has none.</summary>
    public static string[] For(Lang? lang) => lang is { } l && ByLanguage.TryGetValue(l, out var chars) ? chars : [];

    /// <summary>
    /// Replaces the selection (or inserts at the caret) with <paramref name="insertion"/> and puts the caret behind it
    /// (Mac: SpecialCharacters.insert). The field keeps the focus.
    /// </summary>
    public static void Insert(TextBox box, string insertion)
    {
        var text = box.Text ?? "";
        int start = Math.Clamp(Math.Min(box.SelectionStart, box.SelectionEnd), 0, text.Length);
        int end = Math.Clamp(Math.Max(box.SelectionStart, box.SelectionEnd), 0, text.Length);
        if (!box.IsFocused && start == end && start == 0) start = end = text.Length; // never focused: append
        box.Text = text[..start] + insertion + text[end..];
        int caret = start + insertion.Length;
        box.SelectionStart = box.SelectionEnd = caret;
        box.CaretIndex = caret;
        box.Focus();
    }
}

/// <summary>
/// A row of keycap-like buttons that insert accented characters into an answer field (Mac: SpecialCharacterBar).
/// The buttons never take the focus from the field. Null for languages without special characters.
/// </summary>
public static class SpecialCharacterBar
{
    public static Control? Create(Lang? lang, TextBox target)
    {
        var chars = SpecialCharacters.For(lang);
        if (chars.Length == 0) return null;
        var p = WsTheme.P;
        bool phone = AppDevice.IsPhone;
        // Phone: one line that scrolls sideways (French has 15 – in rows they took three lines of the little room
        // above the on-screen keyboard), with keys big enough for a finger.
        Panel row = phone ? new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 6 } : new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
        AutomationProperties.SetName(row, "Sonderzeichen");
        foreach (var c in chars)
        {
            var label = new TextBlock { Text = c, FontSize = 16, FontWeight = FontWeight.Medium, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            var key = new Border
            {
                MinWidth = phone ? 38 : 32, MinHeight = phone ? 36 : 30, Padding = new Thickness(6, 0), CornerRadius = new CornerRadius(phone ? 9 : 7),
                Background = WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.08) : Palette.Hex(0x101828, 0.05)),
                BorderBrush = WsTheme.B(p.Hairline), BorderThickness = new Thickness(0.5),
                Child = label,
            };
            var button = Ui.Clickable(key, () => SpecialCharacters.Insert(target, c), $"{c} einfügen", 7, Colors.Transparent, Palette.Hex(Ui.Rgb(p.Accent), 0.12), new Thickness(0));
            button.Focusable = false;
            button.PointerEntered += (_, _) => label.Foreground = WsTheme.B(p.Accent);
            button.PointerExited += (_, _) => label.Foreground = WsTheme.B(p.Text);
            row.Children.Add(button);
        }
        if (!phone) return row;
        return new ScrollViewer
        {
            Content = row,
            // Tapping a key must not take the keys from the answer field.
            Focusable = false,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
        };
    }
}
