using System.Diagnostics;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Removes downloads of older versions of this app when a newer one starts (Joan, 3.11.2026: a new download should
/// replace the old one). Looks in the Downloads folder, on the desktop and next to the running exe for files named like
/// the website's downloads (<see cref="OlderDownloads"/>) whose own version info says "Wortschatz", 1.2 or later and older
/// than this app. Never this exe, never a version that is running, never a renamed copy; 1.0/1.1 are left to
/// <see cref="EarlierApp"/>. Both apps share their data folder, so nothing has to be taken over.
/// </summary>
public static class OlderVersions
{
    /// <summary>This app's version (1.4.0 for 1.4).</summary>
    public static Version Current => OlderDownloads.Normalized(typeof(OlderVersions).Assembly.GetName().Version ?? new Version(0, 0, 0));

    /// <summary>Where to look: the usual download places and the running exe's folder (or only the given test folders).</summary>
    public static IEnumerable<string> Folders(IEnumerable<string>? only = null)
    {
        var list = only?.ToList() ?? EarlierApp.DefaultExeFolders().ToList();
        if (Environment.ProcessPath is { } self && Path.GetDirectoryName(self) is { Length: > 0 } dir) list.Add(dir);
        return list.Where(d => !string.IsNullOrEmpty(d) && Directory.Exists(d)).Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Deletes the older downloads in <paramref name="folders"/>; returns the deleted files (for the log and tests).</summary>
    public static List<string> Remove(IEnumerable<string> folders)
    {
        var deleted = new List<string>();
        var current = Current;
        var self = Environment.ProcessPath is { } p ? Path.GetFullPath(p) : null;
        foreach (var dir in folders)
        {
            List<string> files;
            try { files = Directory.EnumerateFiles(dir, "Wortschatz-*-Windows*.exe").ToList(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var file in files)
            {
                if (!OlderDownloads.IsOlderDownload(Path.GetFileName(file), current)) continue;
                if (self is not null && string.Equals(Path.GetFullPath(file), self, StringComparison.OrdinalIgnoreCase)) continue;
                if (!IsOlderApp(file, current) || IsRunning(file)) continue;
                try
                {
                    File.Delete(file);
                    deleted.Add(file);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        return deleted;
    }

    /// <summary>The file's own version info: product "Wortschatz", a version of this app older than <paramref name="current"/>.</summary>
    static bool IsOlderApp(string file, Version current)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(file);
            return info.ProductName == "Wortschatz"
                && OlderDownloads.IsOlder(new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart), current);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FileNotFoundException) { return false; }
    }

    /// <summary>A process runs from <paramref name="file"/> (or one with its name we may not inspect: then it counts as running).</summary>
    static bool IsRunning(string file)
    {
        var name = Path.GetFileNameWithoutExtension(file);
        var full = Path.GetFullPath(file);
        foreach (var p in Process.GetProcessesByName(name))
        {
            using (p)
            {
                try
                {
                    if (p.MainModule?.FileName is not { } path || string.Equals(Path.GetFullPath(path), full, StringComparison.OrdinalIgnoreCase)) return true;
                }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException)
                {
                    return true;
                }
            }
        }
        return false;
    }
}
