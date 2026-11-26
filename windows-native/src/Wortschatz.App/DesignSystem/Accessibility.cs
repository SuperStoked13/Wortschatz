using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Platform;

namespace Wortschatz.App.DesignSystem;

// Windows' display accessibility settings, the counterparts of the Mac's "Kontrast erhöhen" (colorSchemeContrast) and
// "Transparenz reduzieren" (accessibilityReduceTransparency):
// - A Windows contrast theme (Einstellungen › Barrierefreiheit › Kontrastdesigns) → HighContrast: the Mac's
//   increased-contrast colours (Theme.swift lightHC/darkHC), stronger hairlines, every glass surface with a visible
//   border, a plain backdrop.
// - "Transparenzeffekte" off (Einstellungen › Barrierefreiheit › Visuelle Effekte) → ReduceTransparency: opaque
//   surfaces with a hairline and a plain backdrop instead of the mesh (GlassSurfaces.swift, AppBackdrop.swift).
// Both are read when the window is built and again whenever it becomes active (MainWindow.RefreshSystemLook), so a
// change in the Windows settings shows as soon as one comes back to the app.

public static partial class WsTheme
{
    /// <summary>A Windows contrast theme is on (Mac: increased contrast).</summary>
    public static bool HighContrast { get; private set; }

    /// <summary>Windows' transparency effects are off (Mac: Reduce Transparency).</summary>
    public static bool ReduceTransparency { get; private set; }

    static bool _forced;

    /// <summary>Fixes both settings, ignoring Windows (the snapshot tool).</summary>
    public static void ForceAccessibility(bool highContrast, bool reduceTransparency)
    {
        _forced = true;
        HighContrast = highContrast;
        ReduceTransparency = reduceTransparency;
    }

    /// <summary>Reads both settings from Windows; true when one of them changed (the window then rebuilds).</summary>
    public static bool ReadAccessibility()
    {
        if (_forced) return false;
        bool contrast = ReadHighContrast(), solid = ReadReduceTransparency();
        if (contrast == HighContrast && solid == ReduceTransparency) return false;
        HighContrast = contrast;
        ReduceTransparency = solid;
        return true;
    }

    static bool ReadHighContrast()
    {
        try
        {
            if (Application.Current?.PlatformSettings?.GetColorValues() is { ContrastPreference: ColorContrastPreference.High }) return true;
        }
        catch (Exception) { }
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            var hc = new HIGHCONTRAST { cbSize = (uint)Marshal.SizeOf<HIGHCONTRAST>() };
            // SPI_GETHIGHCONTRAST; HCF_HIGHCONTRASTON = 1.
            return SystemParametersInfo(0x0042, hc.cbSize, ref hc, 0) && (hc.dwFlags & 1) != 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    static bool ReadReduceTransparency()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("EnableTransparency") is int enabled && enabled == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIGHCONTRAST
    {
        public uint cbSize;
        public uint dwFlags;
        public IntPtr lpszDefaultScheme;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, ref HIGHCONTRAST value, uint winIni);
}

public sealed partial record Palette
{
    /// <summary>
    /// The Mac's increased-contrast colours (Theme.swift: the lightHC/darkHC values): deeper text and status colours,
    /// hairlines at 45 %, glass with a visible border.
    /// </summary>
    public Palette WithIncreasedContrast()
    {
        var hairline = Dark ? Hex(0xFFFFFF, 0.45) : Hex(0x101828, 0.45);
        StatusPalette S(StatusPalette basis, uint lightFill, uint lightText, uint darkFill, uint darkText) =>
            basis with { Fill = Hex(Dark ? darkFill : lightFill), Text = Hex(Dark ? darkText : lightText) };
        return this with
        {
            AccentText = Dark ? Hex(0xB9B5FF) : Hex(0x3A30B5),
            TextSecondary = Dark ? Hex(0xE0E3EA) : Hex(0x2F3240),
            TextTertiary = Dark ? Hex(0xC8CCD6) : Hex(0x3E4454),
            Hairline = hairline,
            GlassBorder = hairline,
            Track = Dark ? Hex(0xFFFFFF, 0.22) : Hex(0x101828, 0.18),
            Mastered = S(Mastered, 0x0B7A3B, 0x075C2C, 0x5BE57A, 0x86EFAC),
            Learning = S(Learning, 0xB37A00, 0x6E4700, 0xFFD66B, 0xFFE2A8),
            New = S(New, 0x8A91A0, 0x3E4454, 0x8A91A0, 0xD0D4DD),
            Success = S(Success, 0x0B7A3B, 0x075C2C, 0x5BE57A, 0x86EFAC),
            Failure = S(Failure, 0xB52A30, 0x9A1D22, 0xFF8A8F, 0xFFB3B6),
            Warning = S(Warning, 0xB37A00, 0x6E4700, 0xFFD66B, 0xFFE2A8),
            Info = S(Info, 0x1A5DB5, 0x154C93, 0x8FC0FF, 0xB5D5FF),
            Star = Dark ? Hex(0xFFD66B) : Hex(0xB98200),
            Flame = Dark ? Hex(0xFFA766) : Hex(0xC2500E),
            SolidSurface = Dark ? Hex(0x1B1D24) : Hex(0xFFFFFF),
            Backdrop = Dark ? Hex(0x000000) : Hex(0xE6E6EB),
        };
    }

    /// <summary>
    /// Opaque surfaces (Mac under Reduce Transparency: glass becomes Theme.solidSurface with a hairline border, the
    /// backdrop a plain Theme.solidBackdrop).
    /// </summary>
    public Palette Opaque()
    {
        bool contrast = GlassBorder == Hairline;
        var surface = SolidSurface;
        var raised = Dark ? Hex(0x2E3142) : Hex(0xF4F4F8);
        return this with
        {
            Glass = surface,
            GlassStrong = surface,
            GlassHover = raised,
            Card = surface,
            Field = surface,
            GlassBorder = contrast ? GlassBorder : Hairline,
            Backdrop = contrast ? Backdrop : Dark ? Hex(0x111217) : Hex(0xEFEFF4),
            BackdropBlobs = [],
        };
    }
}
