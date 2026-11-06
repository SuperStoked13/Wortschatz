namespace Wortschatz.Core;

// Port of LibraryStoreBackends.swift: where the library document lives.

public interface IStorageBackend
{
    /// <summary>The stored document, or null when nothing has been stored yet.</summary>
    byte[]? Load();
    /// <summary>Older copies, newest first (unreadable ones left out). Should never throw (the store guards it anyway).</summary>
    List<byte[]> LoadBackups();
    /// <summary>Atomically replaces the stored document (rotating backups where supported; a failed rotation never fails the save).</summary>
    void Save(byte[] data);
    /// <summary>Moves an unreadable primary document aside (kept for manual recovery). Best effort, should never throw.</summary>
    void PreserveCorrupt() { }
    /// <summary>Deletes every older copy (after "Alle Daten löschen"). Best effort, should never throw.</summary>
    void DiscardBackups() { }
}

/// <summary>In-memory backend for tests and previews.</summary>
public sealed class MemoryBackend(byte[]? data = null, List<byte[]>? backups = null, int backupCount = 3) : IStorageBackend
{
    readonly Lock _lock = new();
    public byte[]? Data { get; set; } = data;
    public List<byte[]> Backups { get; set; } = backups ?? [];
    public byte[]? Corrupt { get; private set; }
    public int SaveCount { get; private set; }
    /// <summary>When set, the next Save throws this error (and clears it).</summary>
    public Exception? FailNextSave { get; set; }
    public int BackupCount { get; } = backupCount;

    public byte[]? Load() { lock (_lock) return Data; }
    public List<byte[]> LoadBackups() { lock (_lock) return [.. Backups]; }

    public void Save(byte[] data)
    {
        lock (_lock)
        {
            if (FailNextSave is { } error)
            {
                FailNextSave = null;
                throw error;
            }
            if (Data is { } old && BackupCount > 0)
            {
                Backups.Insert(0, old);
                if (Backups.Count > BackupCount) Backups.RemoveRange(BackupCount, Backups.Count - BackupCount);
            }
            Data = data;
            SaveCount++;
        }
    }

    public void PreserveCorrupt()
    {
        lock (_lock)
        {
            if (Data is null) return;
            Corrupt = Data;
            Data = null;
        }
    }

    public void DiscardBackups()
    {
        lock (_lock)
        {
            Backups = [];
            Corrupt = null;
        }
    }
}

/// <summary>
/// The library as a JSON file (%LOCALAPPDATA%\Wortschatz\library.json) with rotating backups
/// (library-backup-1.json …, at most one rotation per <c>backupInterval</c>) and an atomic replace.
/// </summary>
public sealed class FileBackend : IStorageBackend
{
    readonly Lock _lock = new();
    readonly Func<DateTime> _clock;

    public string Path { get; }
    public int BackupCount { get; }
    public TimeSpan BackupInterval { get; }

    public FileBackend(string path, int backupCount = 3, TimeSpan? backupInterval = null, Func<DateTime>? clock = null)
    {
        Path = path;
        BackupCount = Math.Max(0, backupCount);
        BackupInterval = backupInterval ?? TimeSpan.FromMinutes(5);
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    /// <summary>
    /// The default location: %LOCALAPPDATA%\Wortschatz\library.json, the folder of the earlier WebView app (whose
    /// localStorage lives in its WebView2 subfolder and is taken over on the first start). Until the native app replaced
    /// it (1.2), the test builds used "Wortschatz Native".
    /// </summary>
    public static string DefaultPath(string folder = "Wortschatz") =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), folder, "library.json");

    public IReadOnlyList<string> BackupPaths => Enumerable.Range(1, BackupCount).Select(i => Sibling($"-backup-{i}")).ToList();
    public string CorruptPath => Sibling("-corrupt");

    public byte[]? Load()
    {
        lock (_lock) return File.Exists(Path) ? File.ReadAllBytes(Path) : null;
    }

    /// <summary>Never throws: a backup that cannot be read (locked, no permission, gone) is left out.</summary>
    public List<byte[]> LoadBackups()
    {
        lock (_lock)
        {
            var list = new List<byte[]>();
            foreach (var p in BackupPaths)
            {
                try { if (File.Exists(p)) list.Add(File.ReadAllBytes(p)); }
                catch (Exception) { }
            }
            return list;
        }
    }

    /// <summary>
    /// Writes a uniquely named temporary file next to the library and moves it over the library (Mac: Data.write with
    /// .atomic). A second writer never shares the temporary file, and a failed write leaves the library untouched.
    /// </summary>
    public void Save(byte[] data)
    {
        lock (_lock)
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            if (BackupCount > 0 && File.Exists(Path) && RotationDue()) RotateBackups();
            var tmp = $"{Path}.{Guid.NewGuid():N}.tmp";
            try
            {
                File.WriteAllBytes(tmp, data);
                File.Move(tmp, Path, overwrite: true);
            }
            catch (Exception)
            {
                try { File.Delete(tmp); }
                catch (Exception) { }
                throw;
            }
        }
    }

    /// <summary>Best effort, never throws.</summary>
    public void PreserveCorrupt()
    {
        lock (_lock)
        {
            try
            {
                if (!File.Exists(Path)) return;
                if (File.Exists(CorruptPath)) File.Delete(CorruptPath);
                File.Move(Path, CorruptPath);
            }
            catch (Exception) { }
        }
    }

    /// <summary>Best effort, never throws: each copy that can be deleted is deleted.</summary>
    public void DiscardBackups()
    {
        lock (_lock)
        {
            foreach (var old in BackupPaths.Append(CorruptPath))
            {
                try { if (File.Exists(old)) File.Delete(old); }
                catch (Exception) { }
            }
        }
    }

    string Sibling(string suffix)
    {
        var dir = System.IO.Path.GetDirectoryName(Path)!;
        var name = System.IO.Path.GetFileNameWithoutExtension(Path);
        var ext = System.IO.Path.GetExtension(Path);
        return System.IO.Path.Combine(dir, name + suffix + ext);
    }

    bool RotationDue()
    {
        var newest = BackupPaths.FirstOrDefault();
        try
        {
            if (newest is null || !File.Exists(newest)) return true;
            return _clock() - File.GetLastWriteTimeUtc(newest) >= BackupInterval;
        }
        catch (Exception) { return true; }
    }

    /// <summary>
    /// Best effort (like the Mac): every step is tried on its own, and no error (a locked or read-only backup, missing
    /// permission) ever prevents the save itself.
    /// </summary>
    void RotateBackups()
    {
        var paths = BackupPaths;
        if (paths.Count == 0) return;
        try { if (File.Exists(paths[^1])) File.Delete(paths[^1]); }
        catch (Exception) { }
        for (int i = paths.Count - 2; i >= 0; i--)
        {
            try { if (File.Exists(paths[i])) File.Move(paths[i], paths[i + 1], overwrite: true); }
            catch (Exception) { }
        }
        try
        {
            File.Copy(Path, paths[0], overwrite: true);
            File.SetLastWriteTimeUtc(paths[0], _clock());
        }
        catch (Exception)
        {
            // Keep saving even without a fresh backup.
        }
    }
}
