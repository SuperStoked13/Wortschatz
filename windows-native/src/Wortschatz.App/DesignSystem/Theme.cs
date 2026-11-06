using Avalonia.Media;
using Wortschatz.Core;

namespace Wortschatz.App.DesignSystem;

// Port of mac/Wortschatz/DesignSystem/Theme.swift plus the Glas design of the Windows app (design A, chosen
// by Joan on 2.11.2026: mesh-gradient backdrop, translucent white panels, floating sidebar, accent #5146E5).
// Every colour exists for light and dark mode. Screens read WsTheme.P (the active palette) when they build
// their controls; switching the theme rebuilds the window (MainWindow.Render), so no dynamic resources are
// needed.

/// <summary>Colours of one status: Fill for bars/dots, Text for labels, Soft for chip backgrounds.</summary>
public sealed record StatusPalette(Color Fill, Color Text, Color Soft);

public sealed partial record Palette
{
    public bool Dark { get; init; }

    // Accent
    public Color Accent { get; init; }
    public Color AccentText { get; init; }
    public Color AccentSoft { get; init; }
    public Color AccentHover { get; init; }

    // Text
    public Color Text { get; init; }
    public Color TextSecondary { get; init; }
    public Color TextTertiary { get; init; }
    public Color OnAccent { get; init; }

    // Surfaces (Glas)
    public Color Backdrop { get; init; }
    public Color[] BackdropBlobs { get; init; } = [];
    public Color Glass { get; init; }
    public Color GlassStrong { get; init; }
    public Color GlassBorder { get; init; }
    public Color GlassHover { get; init; }
    public Color Card { get; init; }
    public Color Hairline { get; init; }
    public Color Track { get; init; }
    public Color KeyCap { get; init; }
    public Color Shadow { get; init; }
    public Color Field { get; init; }
    /// <summary>An opaque surface (Mac: Theme.solidSurface): the cards of the flashcard stack.</summary>
    public Color SolidSurface { get; init; }

    // Status and feedback
    public StatusPalette Mastered { get; init; } = null!;
    public StatusPalette Learning { get; init; } = null!;
    public StatusPalette New { get; init; } = null!;
    public StatusPalette Success { get; init; } = null!;
    public StatusPalette Failure { get; init; } = null!;
    public StatusPalette Warning { get; init; } = null!;
    public StatusPalette Info { get; init; } = null!;
    public Color Star { get; init; }
    public Color Flame { get; init; }
    public Color FlameText { get; init; }

    public StatusPalette Status(CardStatus status) => status switch
    {
        CardStatus.Mastered => Mastered,
        CardStatus.Learning => Learning,
        _ => New,
    };

    public static Color Hex(uint rgb, double alpha = 1) =>
        Color.FromArgb((byte)Math.Round(alpha * 255), (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    public static readonly Palette Light = new()
    {
        Dark = false,
        Accent = Hex(0x5146E5),
        AccentText = Hex(0x463BD4),
        AccentSoft = Hex(0x5146E5, 0.12),
        AccentHover = Hex(0x463BD4),
        Text = Hex(0x1C1D26),
        TextSecondary = Hex(0x4A4E5E),
        TextTertiary = Hex(0x5F6679),
        OnAccent = Hex(0xFFFFFF),
        Backdrop = Hex(0xE9EBF6),
        BackdropBlobs = [Hex(0x7B74FF, 0.45), Hex(0xFFA0C8, 0.38), Hex(0x78BEFF, 0.40), Hex(0xAA8CFF, 0.30)],
        Glass = Hex(0xFFFFFF, 0.52),
        GlassStrong = Hex(0xFFFFFF, 0.72),
        GlassBorder = Hex(0xFFFFFF, 0.85),
        GlassHover = Hex(0xFFFFFF, 0.80),
        Card = Hex(0xFFFFFF, 0.78),
        Hairline = Hex(0x101828, 0.08),
        Track = Hex(0x101828, 0.08),
        KeyCap = Hex(0x101828, 0.07),
        Shadow = Hex(0x3C28A0, 0.30),
        Field = Hex(0xFFFFFF, 0.70),
        SolidSurface = Hex(0xFFFFFF),
        Mastered = new(Hex(0x1FA855), Hex(0x0B7A3B), Hex(0x1FA855, 0.14)),
        Learning = new(Hex(0xE8A317), Hex(0x8F5D00), Hex(0xE8A317, 0.16)),
        New = new(Hex(0xC4C9D4), Hex(0x5F6679), Hex(0x8A91A0, 0.14)),
        Success = new(Hex(0x1FA855), Hex(0x0B7A3B), Hex(0x1FA855, 0.14)),
        Failure = new(Hex(0xE5484D), Hex(0xC4282E), Hex(0xE5484D, 0.13)),
        Warning = new(Hex(0xE8A317), Hex(0x8F5D00), Hex(0xE8A317, 0.16)),
        Info = new(Hex(0x2F7DE1), Hex(0x1F63BF), Hex(0x2F7DE1, 0.12)),
        Star = Hex(0xF2AE0C),
        Flame = Hex(0xF26B1D),
        FlameText = Hex(0xB4480C),
    };

    public static readonly Palette DarkPalette = new()
    {
        Dark = true,
        Accent = Hex(0x7B74FF),
        AccentText = Hex(0x9B95FF),
        AccentSoft = Hex(0x7B74FF, 0.22),
        AccentHover = Hex(0x8F89FF),
        Text = Hex(0xECEDF3),
        TextSecondary = Hex(0xC2C6D2),
        TextTertiary = Hex(0x9AA0B0),
        OnAccent = Hex(0xFFFFFF),
        Backdrop = Hex(0x14151C),
        BackdropBlobs = [Hex(0x5B4FE0, 0.40), Hex(0xB0477E, 0.26), Hex(0x2E6FB8, 0.32), Hex(0x6A4FC8, 0.26)],
        Glass = Hex(0x2A2C3A, 0.62),
        GlassStrong = Hex(0x2E3142, 0.80),
        GlassBorder = Hex(0xFFFFFF, 0.12),
        GlassHover = Hex(0x3A3D50, 0.85),
        Card = Hex(0x262836, 0.88),
        Hairline = Hex(0xFFFFFF, 0.10),
        Track = Hex(0xFFFFFF, 0.10),
        KeyCap = Hex(0xFFFFFF, 0.10),
        Shadow = Hex(0x000000, 0.45),
        Field = Hex(0x1C1E28, 0.80),
        SolidSurface = Hex(0x23262F),
        Mastered = new(Hex(0x32D74B), Hex(0x4ADE80), Hex(0x32D74B, 0.20)),
        Learning = new(Hex(0xFFC53D), Hex(0xFFD27A), Hex(0xFFC53D, 0.20)),
        New = new(Hex(0x5C6272), Hex(0xAEB4C2), Hex(0x8A91A0, 0.22)),
        Success = new(Hex(0x30D158), Hex(0x4ADE80), Hex(0x30D158, 0.20)),
        Failure = new(Hex(0xFF5A5F), Hex(0xFF8A8F), Hex(0xFF5A5F, 0.20)),
        Warning = new(Hex(0xFFC53D), Hex(0xFFD27A), Hex(0xFFC53D, 0.20)),
        Info = new(Hex(0x5EA2FF), Hex(0x8FC0FF), Hex(0x5EA2FF, 0.20)),
        Star = Hex(0xF5C344),
        Flame = Hex(0xFF8A3D),
        FlameText = Hex(0xFFA766),
    };
}

/// <summary>The active palette and the fonts.</summary>
public static partial class WsTheme
{
    /// <summary>The palette of the current appearance (MainWindow sets it from the theme setting / system).</summary>
    public static Palette P { get; private set; } = Palette.Light;

    /// <summary>
    /// The palette for light or dark mode, adapted to Windows' accessibility settings like the Mac adapts to "Kontrast
    /// erhöhen" and "Transparenz reduzieren" (Theme.swift, GlassSurfaces.swift, AppBackdrop.swift).
    /// </summary>
    public static void Use(bool dark)
    {
        var palette = dark ? Palette.DarkPalette : Palette.Light;
        if (HighContrast) palette = palette.WithIncreasedContrast();
        if (ReduceTransparency || HighContrast) palette = palette.Opaque();
        P = palette;
    }

    /// <summary>Onest (UI) with Windows fallbacks for Arabic and Chinese (Segoe UI, Microsoft YaHei).</summary>
    public static readonly FontFamily UI = new("avares://Wortschatz/Assets/Fonts#Onest, Segoe UI, Microsoft YaHei UI, Arial");

    /// <summary>Nunito ExtraBold for the prompt of a question (the Mac's rounded SF).</summary>
    public static readonly FontFamily Prompt = new("avares://Wortschatz/Assets/Fonts#Nunito, Segoe UI, Microsoft YaHei UI, Arial");

    public static IBrush B(Color c) => new SolidColorBrush(c);
}
