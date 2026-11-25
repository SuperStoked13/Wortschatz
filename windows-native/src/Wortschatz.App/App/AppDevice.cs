using static Wortschatz.Core.CoreText;

namespace Wortschatz.App;

/// <summary>
/// What kind of device the app runs on. Set once at the start by the host (a phone host sets <see cref="IsPhone"/>;
/// the snapshot tool for its phone pictures). Screens ask it only where a phone needs something else than a PC: a
/// narrower layout, no keyboard hints, touch instead of hover. Everything else is the same code on both.
/// </summary>
public static class AppDevice
{
    /// <summary>A phone (Android): one page at a time, the library as a drawer, the back gesture, no keyboard shortcuts.</summary>
    public static bool IsPhone { get; set; }

    /// <summary>Keyboard hints («↵», «Esc», «Ctrl+N») make sense: a PC has a keyboard, a phone usually not.</summary>
    public static bool ShowsKeyHints => !IsPhone;

    /// <summary>The app's width in points (MainView keeps it current; a phone turned sideways is ~900).</summary>
    public static double ViewWidth { get; set; } = 1240;

    /// <summary>A phone with room for two columns (turned sideways, or a tablet).</summary>
    public static bool IsWide => !IsPhone || ViewWidth >= 600;

    /// <summary>The system's name in texts («Folgt Windows», «Android-Einstellungen»).</summary>
    public static string SystemName => IsPhone ? "Android" : "Windows";

    /// <summary>This device's name as its host gives it (a phone: "Android (Pixel 8)"; null: Windows + PC name).</summary>
    public static string? DeviceName { get; set; }

    /// <summary>Which app this is (Einstellungen › Info).</summary>
    public static string AppLabel => IsPhone ? L("Android-App") : L("Windows-App");

    /// <summary>Photos can be read (text recognition): Windows has it built in; the phone app when its host brings it.</summary>
    public static bool ReadsPhotos => !IsPhone || PhoneReadsPhotos;

    /// <summary>The phone's host has text recognition (on Android: ML Kit).</summary>
    public static bool PhoneReadsPhotos { get; set; }

    /// <summary>Takes a photo with the phone's camera (JPEG bytes; null: cancelled). Null where there is no camera button.</summary>
    public static Func<Task<byte[]?>>? TakePhoto { get; set; }

    /// <summary>Opens the system's voice settings on a phone (set by the phone host); null on Windows (ms-settings).</summary>
    public static Action? OpenSpeechSettings { get; set; }
}
