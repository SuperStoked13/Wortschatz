using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// The earlier Windows app (WebView2 + Website/, versions 1.0 to 1.1): it was one portable exe that kept its data in
/// %LOCALAPPDATA%\Wortschatz (WebView2\ = localStorage and browser cache, App\ = the unpacked web pages). After the first
/// start of this app took its data over (<see cref="AppModel.OpenDefault"/>), it is removed ("uninstalled"):
/// a backup of its sets goes next to the library, then its folders and the downloaded exe files go.
/// </summary>
public static partial class EarlierApp
{
    /// <summary>Preference key: the earlier app still has to be removed (set on the takeover, cleared when done).</summary>
    public const string PendingKey = "earlierApp.removePending";

    /// <summary>The backup of the earlier app's sets, written next to the library before its data go.</summary>
    public const string BackupFileName = "Backup der bisherigen Windows-App.json";

    /// <summary>The earlier app's leftovers in its data folder (the folder this app now shares).</summary>
    public static IEnumerable<string> Folders(string root) => [Path.Combine(root, "WebView2"), Path.Combine(root, "App")];

    public static bool HasLeftovers(string root) => Folders(root).Any(Directory.Exists) || File.Exists(Path.Combine(root, "wortschatz.log"));

    /// <summary>The downloads of the earlier app as the website named them, e.g. "Wortschatz-1.1-Windows (1).exe".</summary>
    [GeneratedRegex(@"^Wortschatz-1\.[01](\.\d+)*-Windows( \(\d+\))?\.exe$", RegexOptions.IgnoreCase)]
    private static partial Regex DownloadName();

    /// <summary>
    /// Removes the earlier app: backup of its sets, its folders, its downloaded exe files in <paramref name="exeFolders"/>.
    /// Returns true when nothing is left to do; false (try again on the next start) while it is still running or a file
    /// is locked. Never touches anything else: not this app, not "Wortschatz.exe" or "Wortschatz Kopie.exe" (names chosen
    /// by hand), not a library.
    /// </summary>
    public static bool Remove(string root, string leveldbFolder, IEnumerable<string> exeFolders)
    {
        if (IsRunning()) return false;
        bool done = true;

        // 1. A backup of its sets (Website backup format, loadable with "Backup laden"), unless one was written already.
        var backupPath = Path.Combine(root, BackupFileName);
        if (!File.Exists(backupPath) && LegacyWebStorage.ReadTakeover(leveldbFolder) is { } takeover)
        {
            try
            {
                Directory.CreateDirectory(root);
                File.WriteAllText(backupPath + ".tmp", takeover.ToBackup(TimeUtil.NowMs()).ToJsonString(indented: true));
                File.Move(backupPath + ".tmp", backupPath, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false; // no backup, no deleting
            }
        }

        // 2. Its folders.
        foreach (var folder in Folders(root))
        {
            try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { done = false; }
        }

        // Its log (windows/host/main.go writes wortschatz.log into the data folder).
        try { File.Delete(Path.Combine(root, "wortschatz.log")); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { done = false; }

        // 3. Its downloaded exe files (only the website's file names, only version 1.0/1.1, never this exe).
        var self = Environment.ProcessPath;
        foreach (var dir in exeFolders.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(dir, "Wortschatz-1.*-Windows*.exe").ToList(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var file in files)
            {
                if (!DownloadName().IsMatch(Path.GetFileName(file))) continue;
                if (self is not null && string.Equals(Path.GetFullPath(file), Path.GetFullPath(self), StringComparison.OrdinalIgnoreCase)) continue;
                if (!IsEarlierVersion(file)) continue;
                try { File.Delete(file); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { done = false; }
            }
        }
        return done;
    }

    /// <summary>An exe of the earlier app: product "Wortschatz", version 1.0 or 1.1 (this app is 1.2 and later).</summary>
    static bool IsEarlierVersion(string file)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(file);
            return info.ProductName == "Wortschatz" && info.FileMajorPart == 1 && info.FileMinorPart <= 1;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FileNotFoundException) { return false; }
    }

    /// <summary>Another Wortschatz process of version 1.1 or older (the earlier app) runs: its files are in use.</summary>
    static bool IsRunning()
    {
        int me = Environment.ProcessId;
        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                if (p.Id == me || !p.ProcessName.StartsWith("Wortschatz", StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    if (p.MainModule?.FileName is { } path && IsEarlierVersion(path)) return true;
                }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException)
                {
                    // Not ours to inspect (or gone already).
                }
            }
        }
        return false;
    }

    /// <summary>Where downloaded exe files usually are: the Downloads folder and the desktop.</summary>
    public static IEnumerable<string> DefaultExeFolders()
    {
        var list = new List<string>();
        if (OperatingSystem.IsWindows() && SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out var p) == 0)
        {
            try { list.Add(Marshal.PtrToStringUni(p)!); }
            finally { Marshal.FreeCoTaskMem(p); }
        }
        list.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));
        list.Add(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        return list.Where(d => !string.IsNullOrEmpty(d));
    }

    [DllImport("shell32.dll")]
    static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint flags, IntPtr token, out IntPtr path);
}
