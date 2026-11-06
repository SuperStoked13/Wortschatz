using System.Text.RegularExpressions;

namespace Wortschatz.Core;

/// <summary>
/// Downloads of an older version of this app (1.2 and later) that a newer one removes when it starts, so only the new
/// version is left (Joan, 3.11.2026). Only files named like the website names them – "Wortschatz-1.3-Windows.exe",
/// "Wortschatz-1.3.1-Windows (2).exe" – count; a renamed copy ("Wortschatz.exe", "Wortschatz Kopie.exe") is never touched.
/// Versions 1.0 and 1.1 (the earlier WebView app) are left to <c>EarlierApp</c>, which first takes their data over.
/// </summary>
public static partial class OlderDownloads
{
    /// <summary>The first version of this app (the native one); older downloads belong to the earlier app.</summary>
    public static readonly Version FirstNative = new(1, 2, 0);

    [GeneratedRegex(@"^Wortschatz-(\d{1,4})\.(\d{1,4})(?:\.(\d{1,4}))?-Windows(?: \(\d{1,4}\))?\.exe$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DownloadName();

    /// <summary>The version in a download's file name ("Wortschatz-1.3-Windows.exe" → 1.3.0), null for any other name.</summary>
    public static Version? VersionOf(string fileName)
    {
        var m = DownloadName().Match(fileName);
        if (!m.Success) return null;
        int Part(int i) => m.Groups[i].Success ? int.Parse(m.Groups[i].Value, System.Globalization.CultureInfo.InvariantCulture) : 0;
        return new Version(Part(1), Part(2), Part(3));
    }

    /// <summary>Major.Minor.Build of <paramref name="v"/> (a missing build counts as 0), for comparing.</summary>
    public static Version Normalized(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));

    /// <summary>Whether <paramref name="version"/> is a version of this app (1.2 or later) older than <paramref name="current"/>.</summary>
    public static bool IsOlder(Version version, Version current)
    {
        var v = Normalized(version);
        return v >= FirstNative && v < Normalized(current);
    }

    /// <summary>Whether the file <paramref name="fileName"/> is a download of an older version than <paramref name="current"/>.</summary>
    public static bool IsOlderDownload(string fileName, Version current) => VersionOf(fileName) is { } v && IsOlder(v, current);
}
