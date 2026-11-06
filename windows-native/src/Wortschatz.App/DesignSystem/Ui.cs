using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.Core;

namespace Wortschatz.App.DesignSystem;

// Building blocks of the Glas design (Mac: GlassSurfaces.swift, Buttons.swift, Chips.swift, KeyHint.swift,
// ProgressViews.swift). Screens are built in C# with these helpers, the way the Mac views are built from
// SwiftUI modifiers: one Mac view file ↔ one C# screen file.

public enum ButtonKind
{
    /// <summary>Filled accent pill (the primary action, Enter).</summary>
    Primary,
    /// <summary>Translucent white pill with a hairline (secondary actions).</summary>
    Glass,
    /// <summary>No background until hovered (toolbar and row actions).</summary>
    Plain,
    /// <summary>Red text, glass background (delete).</summary>
    Danger,
}

/// <summary>
/// A button with the Glas look. Its chrome is drawn here (no theme template), so hover/pressed colours are exact.
/// The automation name is the label (or the tooltip of an icon button) for screen readers.
/// </summary>
public class WsButton : Button
{
    readonly Border _chrome;
    IBrush _normal = Brushes.Transparent, _hover = Brushes.Transparent, _pressed = Brushes.Transparent;
    IBrush _border = Brushes.Transparent;
    bool _over, _down;

    public WsButton(Control content, ButtonKind kind = ButtonKind.Glass, double height = 38, double? radius = null, Thickness? padding = null)
    {
        var p = WsTheme.P;
        _chrome = new Border
        {
            Height = height,
            CornerRadius = new CornerRadius(radius ?? height / 2),
            Padding = padding ?? new Thickness(16, 0),
            Child = content,
            BorderThickness = new Thickness(1),
        };
        switch (kind)
        {
            case ButtonKind.Primary:
                SetColors(p.Accent, p.AccentHover, p.AccentHover, Colors.Transparent);
                _chrome.BoxShadow = BoxShadows.Parse($"0 8 20 -8 {Hex(p.Accent, 0.55)}");
                break;
            case ButtonKind.Glass:
                SetColors(p.GlassStrong, p.GlassHover, p.Glass, p.GlassBorder);
                break;
            case ButtonKind.Danger:
                SetColors(p.GlassStrong, p.Failure.Soft, p.Failure.Soft, p.GlassBorder);
                break;
            default:
                SetColors(Colors.Transparent, p.Hairline, p.Track, Colors.Transparent);
                break;
        }
        Template = new FuncControlTemplate<WsButton>((_, _) => _chrome);
        Cursor = new Cursor(StandardCursorType.Hand);
        Padding = new Thickness(0);
        Background = Brushes.Transparent;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Center;
        PropertyChanged += (_, e) =>
        {
            if (e.Property == IsFocusedProperty || e.Property == IsEnabledProperty) Refresh();
        };
    }

    public static string Hex(Color c, double alpha) => $"#{(byte)(alpha * 255):X2}{c.R:X2}{c.G:X2}{c.B:X2}";

    public void SetColors(Color normal, Color hover, Color pressed, Color border)
    {
        _normal = WsTheme.B(normal);
        _hover = WsTheme.B(hover);
        _pressed = WsTheme.B(pressed);
        _border = WsTheme.B(border);
        Refresh();
    }

    /// <summary>Exact colours for a selected/checked look (overrides the kind's).</summary>
    public void SetSelected(bool selected)
    {
        if (!selected) return;
        var p = WsTheme.P;
        SetColors(p.AccentSoft, p.AccentSoft, p.AccentSoft, Colors.Transparent);
    }

    public Border Chrome => _chrome;

    void Refresh()
    {
        _chrome.Background = _down ? _pressed : _over ? _hover : _normal;
        bool focusRing = IsFocused && Classes.Contains(":focus-visible");
        _chrome.BorderBrush = focusRing ? WsTheme.B(WsTheme.P.Accent) : _border;
        _chrome.BorderThickness = new Thickness(focusRing ? 2 : 1);
        Opacity = IsEnabled ? 1 : 0.45;
    }

    protected override void OnPointerEntered(PointerEventArgs e)
    {
        base.OnPointerEntered(e);
        _over = true;
        Refresh();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _over = false;
        _down = false;
        Refresh();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        _down = true;
        Refresh();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        _down = false;
        Refresh();
    }

    protected override void OnGotFocus(FocusChangedEventArgs e)
    {
        base.OnGotFocus(e);
        Avalonia.Threading.Dispatcher.UIThread.Post(Refresh);
    }

    protected override void OnLostFocus(FocusChangedEventArgs e)
    {
        base.OnLostFocus(e);
        Refresh();
    }
}

public static class Ui
{
    static Palette P => WsTheme.P;

    // MARK: Text

    public static TextBlock Text(string text, double size = 14, FontWeight weight = FontWeight.Normal, Color? color = null,
        TextWrapping wrap = TextWrapping.NoWrap, FontFamily? font = null, double letterSpacing = 0, TextAlignment align = TextAlignment.Left)
    {
        var t = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight,
            FontFamily = font ?? WsTheme.UI,
            Foreground = WsTheme.B(color ?? P.Text),
            TextWrapping = wrap,
            LetterSpacing = letterSpacing,
            TextAlignment = align,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (wrap == TextWrapping.NoWrap) t.TextTrimming = TextTrimming.CharacterEllipsis;
        return t;
    }

    /// <summary>The small spaced capitals above a section ("WEITERLERNEN").</summary>
    public static TextBlock Eyebrow(string text, Color? color = null) =>
        Text(text.ToUpper(System.Globalization.CultureInfo.GetCultureInfo("de-CH")), 12, FontWeight.SemiBold, color ?? P.TextTertiary, letterSpacing: 1);

    public static TextBlock Title(string text, double size = 32) => Text(text, size, FontWeight.Bold, wrap: TextWrapping.Wrap);

    // MARK: Layout

    public static StackPanel H(double spacing, params Control?[] children)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var c in children) if (c is not null) s.Children.Add(c);
        return s;
    }

    public static StackPanel V(double spacing, params Control?[] children)
    {
        var s = new StackPanel { Orientation = Orientation.Vertical, Spacing = spacing };
        foreach (var c in children) if (c is not null) s.Children.Add(c);
        return s;
    }

    /// <summary>A row with a flexible middle: left items, a stretching spacer, right items.</summary>
    public static Panel Row(Control left, Control? right = null, double spacing = 12)
    {
        // Phone: a wide control (a list, a choice, a field, a row of options) goes under its label; switches, icon
        // buttons and short texts stay beside it.
        if (AppDevice.IsPhone && right is not null && !FitsBeside(right))
        {
            right.HorizontalAlignment = right is WsSegmented ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
            return V(8, left, right);
        }
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = spacing };
        g.Children.Add(left);
        if (right is not null)
        {
            Grid.SetColumn(right, 1);
            g.Children.Add(right);
        }
        return g;
    }

    /// <summary>Whether a control is small enough to stay beside its label on a phone.</summary>
    static bool FitsBeside(Control control) => control switch
    {
        WsSwitch or ToggleSwitch or CheckBox => true,
        TextBlock t => (t.Text?.Length ?? 0) <= 14,
        Border { Child: TextBlock } => true,
        // A few icon buttons (speaker, star, pencil).
        Panel panel => panel.Children.Count <= 4 && panel.Children.All(c => c.Width <= 48 || c is Border { Width: <= 48 } || c is TextBlock { Text.Length: <= 6 }),
        _ => control.Width <= 90,
    };

    public static Control Spacer(double height) => new Border { Height = height };

    // MARK: Surfaces

    /// <summary>A glass panel: translucent fill, white hairline, soft violet shadow.</summary>
    public static Border Glass(Control child, double radius = 22, Thickness? padding = null, bool strong = false, bool shadow = true)
    {
        var b = new Border
        {
            Child = child,
            CornerRadius = new CornerRadius(radius),
            Padding = padding ?? new Thickness(18),
            Background = WsTheme.B(strong ? P.GlassStrong : P.Glass),
            BorderBrush = WsTheme.B(P.GlassBorder),
            BorderThickness = new Thickness(1),
        };
        if (shadow) b.BoxShadow = BoxShadows.Parse($"0 12 32 -14 {WsButton.Hex(P.Shadow, P.Shadow.A / 255.0 * 0.9)}");
        return b;
    }

    /// <summary>The big hero card (question card, "Weiterlernen"): gradient glass, radius 30.</summary>
    public static Border Hero(Control child, Thickness? padding = null, double radius = 30)
    {
        var b = Glass(child, radius, padding ?? new Thickness(30, 26), strong: true);
        b.Background = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(P.Dark ? Palette.Hex(0x30334A, 0.86) : Palette.Hex(0xFFFFFF, 0.76), 0),
                new GradientStop(P.Dark ? Palette.Hex(0x262838, 0.70) : Palette.Hex(0xFFFFFF, 0.46), 1),
            },
        };
        b.BoxShadow = BoxShadows.Parse($"0 24 60 -24 {WsButton.Hex(P.Shadow, Math.Min(1, P.Shadow.A / 255.0 * 1.3))}");
        return b;
    }

    /// <summary>A white card on glass (set tiles, list rows).</summary>
    public static Border Card(Control child, double radius = 22, Thickness? padding = null) => new()
    {
        Child = child,
        CornerRadius = new CornerRadius(radius),
        Padding = padding ?? new Thickness(18),
        Background = WsTheme.B(P.Card),
        BorderBrush = WsTheme.B(P.Hairline),
        BorderThickness = new Thickness(1),
    };

    // MARK: Buttons

    static Control Label(string label, IconName? icon, Color color, string? keyHint, bool onAccent, double size = 14)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (icon is { } i) row.Children.Add(Icons.Icon(i, 17, color, 2));
        row.Children.Add(Text(label, size, FontWeight.SemiBold, color));
        // Phone: no keyboard, no key hints (the button gets shorter, so bars fit the narrow screen).
        if (keyHint is not null && AppDevice.ShowsKeyHints) row.Children.Add(KeyCap(keyHint, onAccent));
        return row;
    }

    public static WsButton Primary(string label, Action onClick, string? keyHint = "↵", IconName? icon = null, double height = 44)
    {
        var b = new WsButton(Label(label, icon, P.OnAccent, keyHint, true, 15), ButtonKind.Primary, height, padding: new Thickness(20, 0));
        b.Click += (_, _) => onClick();
        AutomationProperties.SetName(b, label);
        ShortcutHint(b, keyHint);
        return b;
    }

    public static WsButton Secondary(string label, Action onClick, IconName? icon = null, string? keyHint = null, double height = 38)
    {
        var b = new WsButton(Label(label, icon, P.Text, keyHint, false), ButtonKind.Glass, height);
        b.Click += (_, _) => onClick();
        AutomationProperties.SetName(b, label);
        ShortcutHint(b, keyHint);
        return b;
    }

    public static WsButton PlainButton(string label, Action onClick, IconName? icon = null, Color? color = null, double height = 34)
    {
        var b = new WsButton(Label(label, icon, color ?? P.TextSecondary, null, false, 13.5), ButtonKind.Plain, height, 10, new Thickness(10, 0));
        b.Click += (_, _) => onClick();
        AutomationProperties.SetName(b, label);
        return b;
    }

    public static WsButton Danger(string label, Action onClick, IconName? icon = IconName.Trash)
    {
        var b = new WsButton(Label(label, icon, P.Failure.Text, null, false), ButtonKind.Danger);
        b.Click += (_, _) => onClick();
        AutomationProperties.SetName(b, label);
        return b;
    }

    public static WsButton IconButton(IconName icon, string tooltip, Action onClick, double size = 38, ButtonKind kind = ButtonKind.Glass, Color? color = null)
    {
        var b = new WsButton(new Border { Child = Icons.Icon(icon, 18, color ?? P.TextSecondary), HorizontalAlignment = HorizontalAlignment.Center },
            kind, size, size / 2, new Thickness(0)) { Width = size };
        b.Chrome.Child!.HorizontalAlignment = HorizontalAlignment.Center;
        b.Chrome.Child!.VerticalAlignment = VerticalAlignment.Center;
        b.Click += (_, _) => onClick();
        ToolTip.SetTip(b, tooltip);
        AutomationProperties.SetName(b, tooltip);
        return b;
    }

    // MARK: Chips and key caps

    /// <summary>A key hint ("↵", "Alt ↵", "1").</summary>
    public static Border KeyCap(string text, bool onAccent = false)
    {
        var cap = new Border
        {
            Child = Text(text, 11.5, FontWeight.SemiBold, onAccent ? P.OnAccent : P.TextSecondary),
            Background = WsTheme.B(onAccent ? Palette.Hex(0xFFFFFF, 0.22) : P.KeyCap),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(6, 2),
            VerticalAlignment = VerticalAlignment.Center,
            // Phone: no keyboard to press it on.
            IsVisible = AppDevice.ShowsKeyHints,
        };
        // Screen readers say the key's name, not the glyph (Mac: KeyHint's accessibilityLabel).
        AutomationProperties.SetName(cap, KeyName(text));
        return cap;
    }

    /// <summary>
    /// Tells screen readers which key triggers a control whose key is handled elsewhere (Mac:
    /// shortcutAccessibilityHint, "Kurzbefehl: Eingabetaste"): Narrator reads it as the button's shortcut and help text.
    /// </summary>
    public static void ShortcutHint(Control control, string? keyHint)
    {
        if (string.IsNullOrWhiteSpace(keyHint)) return;
        AutomationProperties.SetAcceleratorKey(control, keyHint.Replace("↵", "Enter").Replace(' ', '+'));
        AutomationProperties.SetHelpText(control, $"Kurzbefehl: {KeyName(keyHint)}");
    }

    /// <summary>
    /// The German name of a key hint for screen readers ("↵" → "Eingabetaste", "Alt ↵" → "Alt-Eingabetaste", "Ctrl E" →
    /// "Steuerung-E", "1" → "Taste 1"; Mac: KeyGlyph.accessibilityName).
    /// </summary>
    public static string KeyName(string hint)
    {
        var parts = hint.Split([' ', '+'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 1 && parts[0].Length == 1 && char.IsDigit(parts[0][0])) return $"Taste {parts[0]}";
        return string.Join("-", parts.Select(part => part switch
        {
            "↵" or "Enter" => "Eingabetaste",
            "Esc" => "Escape-Taste",
            "Ctrl" or "Strg" => "Steuerung",
            "Shift" or "⇧" => "Umschalt",
            "Alt" => "Alt",
            "Tab" or "⇥" => "Tabulatortaste",
            "⌫" => "Rückschritttaste",
            "␣" => "Leertaste",
            "←" => "Pfeil nach links",
            "→" => "Pfeil nach rechts",
            "↑↓←→" or "↑↓" => "Pfeiltasten",
            "Entf" => "Entfernen",
            _ => part.ToUpperInvariant(),
        }));
    }

    /// <summary>A small status chip ("FR → DE", "Gemeistert").</summary>
    public static Border Chip(string text, StatusPalette? palette = null, IconName? icon = null)
    {
        var fg = palette?.Text ?? P.AccentText;
        var content = H(5, icon is { } i ? Icons.Icon(i, 13, fg, 2.2) : null, Text(text, 11.5, FontWeight.Bold, fg));
        var chip = new Border
        {
            Child = content,
            Background = WsTheme.B(palette?.Soft ?? P.AccentSoft),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(9, 3),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(chip, ChipName(text, icon));
        return chip;
    }

    /// <summary>
    /// What a screen reader says for a chip (Mac: Chips.swift): "Status: Gemeistert", "Französisch nach Deutsch" for a
    /// language pair, "Hinweis: …" for a hint, else the text.
    /// </summary>
    public static string ChipName(string text, IconName? icon = null)
    {
        if (Labels.STATUS.Values.Contains(text)) return $"Status: {text}";
        foreach (var a in Enum.GetValues<Lang>())
            foreach (var b in Enum.GetValues<Lang>())
                if (text == Labels.LangPair(a, b) || text == $"{Labels.LangName(a)} → {Labels.LangName(b)}")
                    return $"{Labels.LangName(a)} nach {Labels.LangName(b)}";
        if (icon == IconName.Lightbulb) return $"Hinweis: {text}";
        return text;
    }

    // MARK: Progress

    /// <summary>The mastery bar: green (mastered), amber (learning), grey track.</summary>
    public static Control StatusBar(int mastered, int learning, int total, double height = 7, double? width = null, Color? track = null)
    {
        var g = new Grid { Height = height, ClipToBounds = true };
        if (width is { } w) g.Width = w;
        var border = new Border { CornerRadius = new CornerRadius(height / 2), ClipToBounds = true, Background = WsTheme.B(track ?? P.New.Fill), Child = g, Height = height };
        if (width is { } w2) border.Width = w2;
        double t = Math.Max(1, total);
        double m = mastered / t, l = learning / t;
        g.ColumnDefinitions = new ColumnDefinitions($"{Math.Max(m, 0.0001).ToString(System.Globalization.CultureInfo.InvariantCulture)}*,{Math.Max(l, 0.0001).ToString(System.Globalization.CultureInfo.InvariantCulture)}*,{Math.Max(1 - m - l, 0.0001).ToString(System.Globalization.CultureInfo.InvariantCulture)}*");
        var a = new Border { Background = WsTheme.B(P.Mastered.Fill) };
        var b = new Border { Background = WsTheme.B(P.Learning.Fill) };
        Grid.SetColumn(b, 1);
        g.Children.Add(a);
        g.Children.Add(b);
        if (total == 0) g.Children.Clear();
        return border;
    }

    /// <summary>The round's segment bar ("Runde 3 ▬▬▬▭▭"): filled, half and empty segments.</summary>
    public static Control Segments(IReadOnlyList<LearnFlow.SegmentFill> fills, double width = 26)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        foreach (var f in fills)
        {
            var g = new Grid { Width = width, Height = 5 };
            g.Children.Add(new Border { CornerRadius = new CornerRadius(3), Background = WsTheme.B(P.Track) });
            if (f.Reached > 0)
                g.Children.Add(new Border { CornerRadius = new CornerRadius(3), Background = WsTheme.B(Palette.Hex(Rgb(P.Learning.Fill), 0.9)), Width = width * f.Reached, HorizontalAlignment = HorizontalAlignment.Left });
            if (f.Mastered > 0)
                g.Children.Add(new Border { CornerRadius = new CornerRadius(3), Background = WsTheme.B(P.Mastered.Fill), Width = width * f.Mastered, HorizontalAlignment = HorizontalAlignment.Left });
            row.Children.Add(g);
        }
        return row;
    }

    public static uint Rgb(Color c) => (uint)(c.R << 16 | c.G << 8 | c.B);

    // MARK: Inputs

    /// <summary>A rounded text field in the Glas style.</summary>
    public static TextBox Field(string placeholder, string text = "", double fontSize = 15, double height = 44)
    {
        var box = new TextBox
        {
            Text = text,
            PlaceholderText = placeholder,
            FontSize = fontSize,
            FontFamily = WsTheme.UI,
            MinHeight = height,
            Padding = new Thickness(14, 10),
            CornerRadius = new CornerRadius(14),
            Background = WsTheme.B(P.Field),
            Foreground = WsTheme.B(P.Text),
            BorderBrush = WsTheme.B(P.Hairline),
            BorderThickness = new Thickness(1),
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        box.Classes.Add("ws");
        return box;
    }

    /// <summary>A horizontal hairline.</summary>
    public static Control Divider() => new Border { Height = 1, Background = WsTheme.B(P.Hairline), Margin = new Thickness(0, 4) };

    /// <summary>A vertical scroller without a visible track until hovered.</summary>
    public static ScrollViewer Scroll(Control content)
    {
        if (content.VerticalAlignment == VerticalAlignment.Stretch) content.VerticalAlignment = VerticalAlignment.Top;
        return new ScrollViewer
        {
        Content = content,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    /// <summary>A clickable area (cards, rows) with hover feedback, keyboard focus and Enter/Space activation.</summary>
    public static WsButton Clickable(Control content, Action onClick, string name, double radius = 22, Color? normal = null, Color? hover = null, Thickness? padding = null)
    {
        var b = new WsButton(content, ButtonKind.Plain, double.NaN, radius, padding ?? new Thickness(0))
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        b.Chrome.Height = double.NaN;
        b.SetColors(normal ?? Colors.Transparent, hover ?? P.Hairline, hover ?? P.Track, Colors.Transparent);
        b.Click += (_, _) => onClick();
        AutomationProperties.SetName(b, name);
        return b;
    }
}

/// <summary>
/// An on/off switch in the Glas look (Mac: the SwiftUI Toggle in a grouped form): a capsule track, accent when on, with a
/// white knob that slides across (Motion.snappy). Space/Enter toggle it when it has the focus.
/// </summary>
public sealed class WsSwitch : Button
{
    readonly Border _track;
    readonly Border _knob;
    readonly AnimatedValue _position;
    bool _isOn;

    public event Action<bool>? Toggled;

    public WsSwitch(bool isOn, string name)
    {
        _isOn = isOn;
        _position = new AnimatedValue(isOn ? 1 : 0);
        _knob = new Border
        {
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(10),
            Background = Brushes.White,
            BoxShadow = BoxShadows.Parse("0 1 3 0 #40000000"),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _track = new Border { Width = 40, Height = 24, CornerRadius = new CornerRadius(12), Child = _knob, Padding = new Thickness(2) };
        Template = new FuncControlTemplate<WsSwitch>((_, _) => _track);
        Cursor = new Cursor(StandardCursorType.Hand);
        Background = Brushes.Transparent;
        VerticalAlignment = VerticalAlignment.Center;
        HorizontalAlignment = HorizontalAlignment.Right;
        AutomationProperties.SetName(this, name);
        _position.Changed += Apply;
        Click += (_, _) =>
        {
            IsOn = !_isOn;
            Toggled?.Invoke(_isOn);
        };
        PropertyChanged += (_, e) =>
        {
            if (e.Property == IsEnabledProperty) Opacity = IsEnabled ? 1 : 0.45;
        };
        Apply();
    }

    public bool IsOn
    {
        get => _isOn;
        set
        {
            if (value == _isOn) return;
            _isOn = value;
            _position.Set(value ? 1 : 0, Motion.Animation(Motion.Snappy));
        }
    }

    void Apply()
    {
        var p = WsTheme.P;
        double t = Math.Clamp(_position.Value, 0, 1);
        _knob.RenderTransform = new TranslateTransform(16 * _position.Value, 0);
        var off = p.Dark ? Palette.Hex(0xFFFFFF, 0.16) : Palette.Hex(0x101828, 0.14);
        _track.Background = WsTheme.B(Mix(off, p.Accent, t));
    }

    static Color Mix(Color a, Color b, double t) => Color.FromArgb(
        (byte)Math.Round(a.A + (b.A - a.A) * t), (byte)Math.Round(a.R + (b.R - a.R) * t),
        (byte)Math.Round(a.G + (b.G - a.G) * t), (byte)Math.Round(a.B + (b.B - a.B) * t));
}

/// <summary>
/// A segmented control in the Glas look (Mac: <c>.pickerStyle(.segmented)</c>): the choices in a capsule, the chosen one
/// on a raised white (dark: lighter) pill that slides to the new choice.
/// </summary>
public sealed class WsSegmented : Grid
{
    readonly Border _thumb;
    readonly AnimatedValue _position;
    readonly List<TextBlock> _labels = [];
    readonly List<Border> _hits = [];
    readonly double _naturalSegment;
    double _segment;
    int _selected;

    public event Action<int>? SelectionChanged;

    public WsSegmented(IReadOnlyList<string> items, int selected, double segmentWidth = 120)
    {
        var p = WsTheme.P;
        _selected = selected;
        _position = new AnimatedValue(selected);
        Height = 32;
        _naturalSegment = _segment = segmentWidth;
        // Phone: the segments shrink to the width there is (MeasureOverride); the natural width is the most.
        if (AppDevice.IsPhone) MaxWidth = segmentWidth * items.Count + 4;
        else Width = segmentWidth * items.Count + 4;
        var track = new Border { CornerRadius = new CornerRadius(9), Background = WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.08) : Palette.Hex(0x101828, 0.06)) };
        Children.Add(track);
        _thumb = new Border
        {
            Width = segmentWidth,
            Margin = new Thickness(2),
            CornerRadius = new CornerRadius(7),
            Background = WsTheme.B(p.Dark ? Palette.Hex(0x5A5E72) : Palette.Hex(0xFFFFFF)),
            BoxShadow = BoxShadows.Parse("0 1 3 0 #26000000"),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Children.Add(_thumb);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(2) };
        for (int i = 0; i < items.Count; i++)
        {
            int index = i;
            var label = Ui.Text(items[i], 13, FontWeight.Medium, align: TextAlignment.Center);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            if (AppDevice.IsPhone) label.TextTrimming = TextTrimming.CharacterEllipsis;
            _labels.Add(label);
            var hit = new Border { Width = segmentWidth, Background = Brushes.Transparent, Child = label, Cursor = new Cursor(StandardCursorType.Hand) };
            _hits.Add(hit);
            // Phone: on a tap (finger lifted without moving) – on touch-down a swipe to scroll that began on the bar
            // switched it (the sort order of the overview).
            if (AppDevice.IsPhone) hit.Tapped += (_, e) =>
            {
                e.Handled = true;
                Select(index);
            };
            else hit.PointerPressed += (_, e) =>
            {
                e.Handled = true;
                Select(index);
            };
            AutomationProperties.SetName(hit, items[i]);
            row.Children.Add(hit);
        }
        Children.Add(row);
        _position.Changed += () => _thumb.RenderTransform = new TranslateTransform(_position.Value * _segment, 0);
        _thumb.RenderTransform = new TranslateTransform(selected * _segment, 0);
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Center;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (AppDevice.IsPhone && !double.IsInfinity(availableSize.Width) && _hits.Count > 0)
        {
            double segment = Math.Max(36, Math.Min(_naturalSegment, Math.Floor((availableSize.Width - 4) / _hits.Count)));
            if (Math.Abs(segment - _segment) > 0.5)
            {
                _segment = segment;
                foreach (var hit in _hits) hit.Width = segment;
                _thumb.Width = segment;
                _thumb.RenderTransform = new TranslateTransform(_position.Value * segment, 0);
            }
        }
        return base.MeasureOverride(availableSize);
    }

    public void Select(int index)
    {
        if (index == _selected) return;
        _selected = index;
        _position.Set(index, Motion.Animation(Motion.Snappy));
        SelectionChanged?.Invoke(index);
    }
}

/// <summary>
/// A grouped form (Mac: <c>Form { Section { … } header: footer: }.formStyle(.grouped)</c>): sections with a small header,
/// their rows on a rounded card separated by hairlines, and an optional footer note.
/// </summary>
public static class Form
{
    /// <summary>A row: the title (and a secondary line under it) on the left, the control on the right.</summary>
    public static Control Row(string title, Control? control, string? subtitle = null)
    {
        var p = WsTheme.P;
        var left = Ui.V(2, Ui.Text(title, 14, FontWeight.Medium, wrap: TextWrapping.Wrap),
            subtitle is null ? null : Ui.Text(subtitle, 12.5, color: p.TextSecondary, wrap: TextWrapping.Wrap));
        left.VerticalAlignment = VerticalAlignment.Center;
        // Phone: a wide control (a list, a segmented choice, a field) goes under its title; a switch stays beside it.
        if (AppDevice.IsPhone && control is not null and not WsSwitch and not ToggleSwitch && !(control.Width <= 120))
        {
            control.HorizontalAlignment = HorizontalAlignment.Left;
            var stacked = Ui.V(8, left, control);
            stacked.Margin = new Thickness(14, 10);
            return stacked;
        }
        var row = Ui.Row(left, control, 16);
        row.MinHeight = 40;
        row.Margin = new Thickness(14, 8);
        return row;
    }

    public static Control Section(string? header, IEnumerable<Control> rows, string? footer = null)
    {
        var p = WsTheme.P;
        var list = new StackPanel();
        bool first = true;
        foreach (var r in rows)
        {
            if (!first) list.Children.Add(new Border { Height = 1, Background = WsTheme.B(p.Hairline), Margin = new Thickness(14, 0) });
            list.Children.Add(r);
            first = false;
        }
        var box = new Border
        {
            Child = list,
            CornerRadius = new CornerRadius(12),
            Background = WsTheme.B(p.Dark ? Palette.Hex(0xFFFFFF, 0.05) : Palette.Hex(0xFFFFFF, 0.65)),
            BorderBrush = WsTheme.B(p.Hairline),
            BorderThickness = new Thickness(1),
        };
        var stack = Ui.V(6);
        if (header is not null)
        {
            var h = Ui.Text(header, 12.5, FontWeight.SemiBold, p.TextSecondary);
            h.Margin = new Thickness(14, 0, 0, 0);
            stack.Children.Add(h);
        }
        stack.Children.Add(box);
        if (footer is not null)
        {
            var f = Ui.Text(footer, 12.5, color: p.TextSecondary, wrap: TextWrapping.Wrap);
            f.Margin = new Thickness(14, 2, 14, 0);
            stack.Children.Add(f);
        }
        return stack;
    }
}
