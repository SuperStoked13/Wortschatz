using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>Where the main window was and how big (Mac: the window frame macOS restores; WortschatzApp.swift).</summary>
public sealed record WindowFrame(int X, int Y, double Width, double Height, bool Maximized);

// The main window's own preferences (the window frame, the sidebar), apart from the study settings in AppPreferences.cs.
public sealed partial class AppPreferences
{
    /// <summary>The main window's position and size when it was last closed (null: never closed yet).</summary>
    public WindowFrame? MainWindowFrame
    {
        get
        {
            if (Get("window.main") is not { } j) return null;
            if (j["x"]?.FiniteNumber is not { } x || j["y"]?.FiniteNumber is not { } y
                || j["width"]?.FiniteNumber is not { } w || j["height"]?.FiniteNumber is not { } h || w < 100 || h < 100) return null;
            return new WindowFrame((int)x, (int)y, w, h, j["maximized"]?.BoolValue ?? false);
        }
        set => Set("window.main", value is null ? null : JSONValue.Obj(("x", value.X), ("y", value.Y),
            ("width", Math.Round(value.Width)), ("height", Math.Round(value.Height)), ("maximized", value.Maximized)));
    }

    /// <summary>The sidebar's width after dragging its edge (Mac: the split view's column width).</summary>
    public double? SidebarWidth
    {
        get => Get("sidebar.width")?.FiniteNumber;
        set => Set("sidebar.width", value is { } w ? (JSONValue)Math.Round(w) : null);
    }
}
