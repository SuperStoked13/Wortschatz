using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// Port of the Mac's LibraryStorePersistenceTests: saving, autosave rollback, recovery from backups and the file backend
/// (atomic write, rotating backups, discarding them), plus the Windows-specific robustness: backups, setting a damaged
/// file aside and discarding never throw, a failing rotation never stops a save, a full disk or exhausted quota is
/// recognised also when wrapped, and every save uses its own temporary file.
/// </summary>
public sealed class LibraryStorePersistenceTests
{
    static readonly CardDraft[] Sample =
    [
        new("le monsieur, messieurs", "der Herr"),
        new("l'homme", "der Mann"),
        new(null, "la femme", "die Frau", true),
    ];

    static readonly JSONValue LearnState = JSONValue.Parse(
        """{"v":1,"round":2,"order":["a","b"],"stage":{"a":1,"b":0},"queue":[{"qid":"2.1:a","cardId":"a","type":"written","ask":"term"}],"finishedAt":null}""");

    static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);

    static string? CodeOf(Action body)
    {
        try { body(); }
        catch (LibraryStoreError e) { return e.Code.Raw(); }
        catch (Exception e) { return "other: " + e.GetType().Name; }
        return null;
    }

    static LibraryStoreError? ErrorOf(Action body)
    {
        try { body(); }
        catch (LibraryStoreError e) { return e; }
        return null;
    }

    /// <summary>A small library with every kind of data.</summary>
    static VocabSet Populate(LibraryStore store)
    {
        var set = store.CreateSet("Personen", "Unité 1", cards: Sample);
        store.CreateSet("Farben", termLang: Lang.En, cards: [new CardDraft("red", "rot")]);
        store.RecordAnswer(set.Id, set.Cards[0].Id, true, 1_791_000_000_000);
        store.RecordAnswer(set.Id, set.Cards[1].Id, false, 1_791_090_000_000);
        store.SaveSessionJSON(set.Id, JSONValue.Parse("""{"v":1,"round":1,"queue":["x"],"finishedAt":null}"""));
        store.SaveLearnJSON(set.Id, LearnState);
        store.UpdateSettings(new SettingsPatch(ThemeSetting.Dark, new StudyOptionsPatch(Learn: new LearnOptionsPatch(RoundSize: 10))));
        store.UpdateStudyOptions(set.Id, new StudyOptionsPatch(AnswerWith: AnswerWith.Both));
        return set;
    }

    static void AssertSameLibrary(LibraryStore a, LibraryStore b)
    {
        Assert.Equal(a.ListSets().Select(s => s.ToJson().ToJsonString(sortedKeys: true)), b.ListSets().Select(s => s.ToJson().ToJsonString(sortedKeys: true)));
        Assert.Equal(a.GetSettings(), b.GetSettings());
        Assert.Equal(a.GetActivity(), b.GetActivity());
        foreach (var set in a.ListSets())
        {
            Assert.Equal(a.GetProgress(set.Id), b.GetProgress(set.Id));
            Assert.Equal(a.GetSessionJSON(set.Id)?.ToString(), b.GetSessionJSON(set.Id)?.ToString());
            Assert.Equal(a.GetLearnJSON(set.Id)?.ToString(), b.GetLearnJSON(set.Id)?.ToString());
            Assert.Equal(a.GetStudyOptions(set.Id), b.GetStudyOptions(set.Id));
        }
    }

    // MARK: Saving

    [Fact]
    public void SavedLibrariesLoadUnchanged()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend);
        var set = Populate(store);
        store.Save();
        var reopened = new LibraryStore(backend);
        AssertSameLibrary(store, reopened);
        Assert.Equal(LearnState.ToString(), reopened.GetLearnJSON(set.Id)?.ToString());
        Assert.Equal(LoadRecovery.None, reopened.Recovery);
    }

    [Fact]
    public void SaveWritesOnlyWhenSomethingChanged()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend);
        Assert.False(store.HasUnsavedChanges);
        store.Save();
        Assert.Equal(0, backend.SaveCount);
        var set = store.CreateSet("A", cards: Sample);
        Assert.True(store.HasUnsavedChanges);
        store.Save();
        Assert.False(store.HasUnsavedChanges);
        Assert.Equal(1, backend.SaveCount);
        store.Save();
        Assert.Equal(1, backend.SaveCount);
        // Failed operations and reads change nothing.
        CodeOf(() => store.UpdateSet("missing", new SetPatch(Title: "x")));
        store.ExportAll();
        Assert.False(store.HasUnsavedChanges);
        store.ToggleStar(set.Id, set.Cards[0].Id);
        Assert.True(store.HasUnsavedChanges);
    }

    [Fact]
    public void AFailedSaveKeepsTheChangesForTheNextSave()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend);
        store.CreateSet("A", cards: Sample);
        backend.FailNextSave = new UnauthorizedAccessException("denied");
        var error = ErrorOf(store.Save);
        Assert.NotNull(error);
        Assert.Equal(LibraryStoreErrorCode.Io, error.Code);
        Assert.Equal(StoreMessages.Io, error.Message);
        Assert.True(store.HasUnsavedChanges);
        Assert.Single(store.ListSets());
        store.Save();
        Assert.False(store.HasUnsavedChanges);
        Assert.Single(new LibraryStore(backend).ListSets());
    }

    [Fact]
    public void AChangeMadeWhileSavingStaysUnsaved()
    {
        // Save writes outside the store's lock (the app saves on a background thread), so the library can change while
        // an older snapshot is being written.
        var backend = new DuringSaveBackend();
        var store = new LibraryStore(backend);
        var set = store.CreateSet("A", cards: Sample);
        backend.DuringSave = () => store.ToggleStar(set.Id, set.Cards[0].Id);
        store.Save();
        Assert.True(store.HasUnsavedChanges);
        Assert.False(new LibraryStore(backend).GetSet(set.Id)!.Cards[0].Starred);
        backend.DuringSave = null;
        store.Save();
        Assert.False(store.HasUnsavedChanges);
        Assert.True(new LibraryStore(backend).GetSet(set.Id)!.Cards[0].Starred);
    }

    static IOException Win32IO(int code) => new("io", unchecked((int)0x80070000) | code);

    [Fact]
    public void AFullDiskSurfacesAsQuotaWithAGermanMessage()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend);
        store.CreateSet("A", cards: Sample);
        backend.FailNextSave = Win32IO(0x70); // ERROR_DISK_FULL
        var error = ErrorOf(store.Save);
        Assert.NotNull(error);
        Assert.Equal(LibraryStoreErrorCode.Quota, error.Code);
        Assert.Contains("Speicherplatz", error.Message);
        Assert.DoesNotContain("ß", error.Message);

        // ERROR_HANDLE_DISK_FULL, the user's disk quota, and the same wrapped in other errors.
        foreach (var failure in new Exception[]
                 {
                     Win32IO(0x27),
                     Win32IO(0x50F), // ERROR_DISK_QUOTA_EXCEEDED
                     Win32IO(0x718), // ERROR_NOT_ENOUGH_QUOTA
                     new InvalidOperationException("write failed", Win32IO(0x70)),
                     new Exception("outer", new Exception("middle", Win32IO(0x27))),
                     new AggregateException(new TimeoutException(), Win32IO(0x70)),
                 })
        {
            backend.FailNextSave = failure;
            Assert.Equal("QUOTA", CodeOf(store.Save));
        }
        if (!OperatingSystem.IsWindows())
        {
            backend.FailNextSave = new IOException("No space left on device", 28); // ENOSPC as .NET reports it on Unix
            Assert.Equal("QUOTA", CodeOf(store.Save));
        }

        // Anything else stays a plain write error.
        foreach (var failure in new Exception[]
                 {
                     Win32IO(0x05), // ERROR_ACCESS_DENIED
                     Win32IO(0x20), // ERROR_SHARING_VIOLATION
                     new UnauthorizedAccessException(),
                     new IOException("io"),
                     new Exception("outer", new UnauthorizedAccessException()),
                 })
        {
            backend.FailNextSave = failure;
            Assert.Equal("IO", CodeOf(store.Save));
        }
        Assert.True(store.HasUnsavedChanges);
        store.Save();
        Assert.False(store.HasUnsavedChanges);
    }

    [Fact]
    public void WriteEncodedReportsAFullDiskToo()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend);
        store.CreateSet("A", cards: Sample);
        var pending = store.EncodePending()!.Value;
        backend.FailNextSave = new Exception("wrapped", Win32IO(0x70));
        Assert.Equal("QUOTA", CodeOf(() => store.WriteEncoded(pending.Data, pending.Revision)));
        Assert.True(store.HasUnsavedChanges);
        store.WriteEncoded(pending.Data, pending.Revision);
        Assert.False(store.HasUnsavedChanges);
    }

    // MARK: Autosave

    [Fact]
    public void AutosaveWritesEveryChange()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend, autosave: true);
        var set = store.CreateSet("A", cards: Sample);
        Assert.Equal(1, backend.SaveCount);
        store.RecordAnswer(set.Id, set.Cards[0].Id, true);
        Assert.Equal(2, backend.SaveCount);
        Assert.False(store.HasUnsavedChanges);
        store.ListSets();
        Assert.Equal(2, backend.SaveCount);
        Assert.Single(new LibraryStore(backend).GetProgress(set.Id));
    }

    [Fact]
    public void AFailedAutosaveUndoesTheWholeOperation()
    {
        // Like a QUOTA error in the web app: nothing of the operation stays, nobody is notified.
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend, autosave: true);
        var set = store.CreateSet("A", cards: Sample);
        int events = 0;
        store.Subscribe(_ => events++);
        backend.FailNextSave = Win32IO(0x70);
        Assert.Equal("QUOTA", CodeOf(() => store.CreateSet("B", cards: Sample)));
        Assert.Equal(new[] { "A" }, store.ListSets().Select(s => s.Title));
        backend.FailNextSave = new UnauthorizedAccessException();
        Assert.Equal("IO", CodeOf(() => store.UpdateSet(set.Id, new SetPatch(Title: "Neu"))));
        Assert.Equal("A", store.GetSet(set.Id)!.Title);
        backend.FailNextSave = new UnauthorizedAccessException();
        Assert.Equal("IO", CodeOf(() => store.RecordAnswer(set.Id, set.Cards[0].Id, true)));
        Assert.Empty(store.GetProgress(set.Id));
        Assert.Empty(store.GetActivity());
        Assert.Equal(0, events);
        Assert.False(store.HasUnsavedChanges);
        Assert.Equal("Neu", store.UpdateSet(set.Id, new SetPatch(Title: "Neu")).Title);
        Assert.Equal(1, events);
    }

    [Fact]
    public void AFailedImportLeavesEverythingAsItWas()
    {
        var backend = new MemoryBackend();
        var store = new LibraryStore(backend, autosave: true);
        store.ImportAll(JSONValue.Parse(
            """{"app":"wortschatz","version":1,"sets":[{"id":"A","title":"Set A","cards":[{"id":"a0","term":"a","definition":"b"}]}],"progress":{"A":{"a0":{"correct":2,"streak":2}}}}"""),
            ImportMode.Replace);
        store.UpdateSettings(new SettingsPatch(ThemeSetting.Dark));
        store.SaveSessionJSON("A", JSONValue.Parse("""{"v":1,"round":2}"""));
        store.SaveLearnJSON("A", LearnState);
        var before = backend.Data!;
        foreach (var mode in new[] { ImportMode.Merge, ImportMode.Replace })
        {
            backend.FailNextSave = Win32IO(0x70);
            var error = ErrorOf(() => store.ImportAll(JSONValue.Parse(
                """{"app":"wortschatz","version":1,"settings":{"theme":"light"},"sets":[{"id":"B","cards":[{"id":"b0","term":"c","definition":"d"}]}]}"""),
                mode));
            Assert.Equal(LibraryStoreErrorCode.Quota, error?.Code);
            Assert.Equal(before, backend.Data);
            foreach (var reader in new[] { store, new LibraryStore(backend) })
            {
                Assert.Equal(new[] { "A" }, reader.ListSets().Select(s => s.Id));
                Assert.Single(reader.GetProgress("A"));
                Assert.Equal("""{"round":2,"v":1}""", reader.GetSessionJSON("A")?.ToString());
                Assert.Equal(LearnState.ToString(), reader.GetLearnJSON("A")?.ToString());
                Assert.Equal(ThemeSetting.Dark, reader.GetSettings().Theme);
            }
        }
        // The store still works normally afterwards.
        Assert.Equal(ThemeSetting.Light, store.UpdateSettings(new SettingsPatch(ThemeSetting.Light)).Theme);
    }

    // MARK: Recovery

    [Fact]
    public void ACorruptLibraryIsRecoveredFromTheNewestReadableBackup()
    {
        var good = Bytes("""{"schemaVersion":1,"sets":[{"id":"s1","title":"Gerettet","cards":[]}]}""");
        var older = Bytes("""{"schemaVersion":1,"sets":[{"id":"s0","title":"Älter","cards":[]}]}""");
        var corrupt = Bytes("""{"sets": [""");
        var backend = new MemoryBackend(corrupt, [Bytes("garbage"), good, older]);
        var store = new LibraryStore(backend);
        Assert.Equal(new LoadRecovery(LoadRecoveryKind.FromBackup, 1), store.Recovery);
        Assert.Equal(new[] { "Gerettet" }, store.ListSets().Select(s => s.Title));
        Assert.Equal(corrupt, backend.Corrupt);
        Assert.Null(backend.Data);
        // The recovered library becomes the primary document with the next save.
        Assert.True(store.HasUnsavedChanges);
        store.Save();
        Assert.Equal(new[] { "Gerettet" }, new LibraryStore(backend).ListSets().Select(s => s.Title));
    }

    [Fact]
    public void AMissingLibraryWithBackupsIsRecovered()
    {
        var good = Bytes("""{"sets":[{"id":"s1","title":"Gerettet","cards":[]}]}""");
        var backend = new MemoryBackend(null, [good]);
        var store = new LibraryStore(backend, autosave: true);
        Assert.Equal(new LoadRecovery(LoadRecoveryKind.FromBackup, 0), store.Recovery);
        Assert.Null(backend.Corrupt);
        // With autosave the recovered library is written right away.
        Assert.NotNull(backend.Data);
        Assert.False(store.HasUnsavedChanges);
    }

    [Fact]
    public void NothingReadableStartsEmpty()
    {
        foreach (var primary in new[] { Bytes("{not json"), Bytes("[]"), Bytes("\"text\""), new byte[] { 0xFF, 0xFE } })
        {
            var backend = new MemoryBackend(primary, [Bytes("{")]);
            var store = new LibraryStore(backend);
            Assert.Equal(LoadRecovery.Reset, store.Recovery);
            Assert.Empty(store.ListSets());
            Assert.Equal(primary, backend.Corrupt);
            Assert.False(store.HasUnsavedChanges);
        }
        Assert.Equal(LoadRecovery.None, new LibraryStore(new MemoryBackend()).Recovery);
    }

    [Fact]
    public void ABackendThatFailsWhileRecoveringNeverKeepsTheLibraryFromOpening()
    {
        // Reading the backups throws: the store opens empty (and says so) instead of failing.
        var store = new LibraryStore(new ThrowingBackend(Bytes("{kaputt")) { FailBackups = true, FailPreserve = true });
        Assert.Equal(LoadRecovery.Reset, store.Recovery);
        Assert.Empty(store.ListSets());

        // Setting the damaged file aside throws: the backup is used anyway.
        var good = Bytes("""{"sets":[{"id":"s1","title":"Gerettet","cards":[]}]}""");
        var backend = new ThrowingBackend(Bytes("{kaputt"), [good]) { FailPreserve = true };
        var recovered = new LibraryStore(backend);
        Assert.Equal(new LoadRecovery(LoadRecoveryKind.FromBackup, 0), recovered.Recovery);
        Assert.Equal(new[] { "Gerettet" }, recovered.ListSets().Select(s => s.Title));
        recovered.Reload();
        Assert.Equal(new[] { "Gerettet" }, recovered.ListSets().Select(s => s.Title));

        // Discarding the backups never throws either.
        backend.FailDiscard = true;
        recovered.DiscardBackups();
    }

    // MARK: FileBackend

    [Fact]
    public void FileBackendStoresTheLibraryAtomically()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath);
        Assert.Null(backend.Load());
        Assert.Empty(backend.LoadBackups());
        backend.Save(Bytes("""{"a":1}"""));
        Assert.Equal(Bytes("""{"a":1}"""), backend.Load());
        Assert.Equal(new[] { "library-backup-1.json", "library-backup-2.json", "library-backup-3.json" }, backend.BackupPaths.Select(Path.GetFileName));
        Assert.Equal("library-corrupt.json", Path.GetFileName(backend.CorruptPath));
        Assert.Empty(new FileBackend(dir.LibraryPath, backupCount: 0).BackupPaths);
        // No temporary file stays behind.
        Assert.Equal(new[] { "library.json" }, Directory.GetFiles(dir.Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void EverySaveUsesItsOwnTemporaryFile()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        // Something left at the old fixed name (a crashed write, another program) does not block saving.
        Directory.CreateDirectory(dir.Folder);
        Directory.CreateDirectory(dir.LibraryPath + ".tmp");
        backend.Save(Bytes("""{"v":1}"""));
        Assert.Equal(Bytes("""{"v":1}"""), backend.Load());

        // Many saves at once from several threads: each one completes, the file is always one whole document.
        var tasks = Enumerable.Range(0, 16).Select(i => Task.Run(() => backend.Save(Bytes($$"""{"v":{{i}}}""")))).ToArray();
        Task.WaitAll(tasks);
        Assert.True(JSONValue.Parse(backend.Load()!).IsObject);
        Assert.DoesNotContain(Directory.GetFiles(dir.Folder), f => f.EndsWith(".tmp", StringComparison.Ordinal));
    }

    [Fact]
    public void AFailedWriteLeavesTheLibraryAndNoTemporaryFile()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupCount: 0);
        backend.Save(Bytes("""{"v":1}"""));
        // The library path becomes a folder: the move fails, the old data are untouched elsewhere and no temp file stays.
        File.Delete(dir.LibraryPath);
        Directory.CreateDirectory(Path.Combine(dir.LibraryPath, "blocker"));
        Assert.ThrowsAny<Exception>(() => backend.Save(Bytes("""{"v":2}""")));
        Assert.DoesNotContain(Directory.GetFiles(dir.Folder), f => f.EndsWith(".tmp", StringComparison.Ordinal));
    }

    [Fact]
    public void FileBackendKeepsThreeRotatingBackups()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        for (int i = 1; i <= 5; i++) backend.Save(Bytes($$"""{"v":{{i}}}"""));
        Assert.Equal(Bytes("""{"v":5}"""), backend.Load());
        Assert.Equal(new[] { 4, 3, 2 }.Select(i => Bytes($$"""{"v":{{i}}}""")), backend.LoadBackups());
    }

    [Fact]
    public void FileBackendRotatesAtMostOncePerInterval()
    {
        using var dir = new TempDir();
        var now = new DateTime(2026, 9, 21, 10, 0, 0, DateTimeKind.Utc);
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.FromSeconds(300), clock: () => now);
        backend.Save(Bytes("""{"v":1}"""));
        backend.Save(Bytes("""{"v":2}""")); // first rotation: no backup yet
        now += TimeSpan.FromSeconds(60);
        backend.Save(Bytes("""{"v":3}""")); // too soon: no new backup
        Assert.Equal(new[] { Bytes("""{"v":1}""") }, backend.LoadBackups());
        now += TimeSpan.FromSeconds(300);
        backend.Save(Bytes("""{"v":4}"""));
        Assert.Equal(new[] { Bytes("""{"v":3}"""), Bytes("""{"v":1}""") }, backend.LoadBackups());
    }

    [Fact]
    public void AFailingRotationNeverStopsTheSave()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        backend.Save(Bytes("""{"v":1}"""));
        // The newest backup's place is taken by a folder: copying the library there fails.
        Directory.CreateDirectory(Path.Combine(backend.BackupPaths[0], "blocker"));
        backend.Save(Bytes("""{"v":2}"""));
        Assert.Equal(Bytes("""{"v":2}"""), backend.Load());
        backend.Save(Bytes("""{"v":3}"""));
        Assert.Equal(Bytes("""{"v":3}"""), backend.Load());
    }

    [Fact]
    public void BackupsThatCannotBeReadAreLeftOut()
    {
        if (OperatingSystem.IsWindows() || Environment.UserName == "root") return;
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        for (int i = 1; i <= 3; i++) backend.Save(Bytes($$"""{"v":{{i}}}"""));
        File.SetUnixFileMode(backend.BackupPaths[0], UnixFileMode.None); // reading throws UnauthorizedAccessException
        Assert.Equal(new[] { Bytes("""{"v":1}""") }, backend.LoadBackups());
        // A store on a damaged library still opens with the readable backup.
        File.WriteAllBytes(dir.LibraryPath, Bytes("{kaputt"));
        var store = new LibraryStore(backend);
        Assert.Equal(new LoadRecovery(LoadRecoveryKind.FromBackup, 0), store.Recovery);
        File.SetUnixFileMode(backend.BackupPaths[0], UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    [Fact]
    public void WithoutPermissionToChangeTheFolderNothingThrows()
    {
        if (OperatingSystem.IsWindows() || Environment.UserName == "root") return;
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        backend.Save(Bytes("""{"v":1}"""));
        backend.Save(Bytes("""{"v":2}"""));
        File.WriteAllBytes(dir.LibraryPath, Bytes("{kaputt"));
        var readOnly = UnixFileMode.UserRead | UnixFileMode.UserExecute;
        File.SetUnixFileMode(dir.Folder, readOnly);
        try
        {
            // Moving the damaged file aside and deleting the backups fail with UnauthorizedAccessException: ignored.
            backend.PreserveCorrupt();
            backend.DiscardBackups();
            var store = new LibraryStore(backend);
            Assert.Equal(new LoadRecovery(LoadRecoveryKind.FromBackup, 0), store.Recovery);
            store.DiscardBackups();
            // Saving itself reports the error as an ordinary store error.
            Assert.Equal("IO", CodeOf(store.Save));
        }
        finally
        {
            File.SetUnixFileMode(dir.Folder, readOnly | UnixFileMode.UserWrite);
        }
    }

    [Fact]
    public void DiscardingBackupsLeavesOnlyTheCurrentLibrary()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        var store = new LibraryStore(backend);
        store.CreateSet("Personen", cards: Sample);
        store.Save();
        store.CreateSet("Farben", cards: Sample);
        store.Save();
        File.WriteAllBytes(backend.CorruptPath, Bytes("""{"sets": ["""));
        Assert.NotEmpty(backend.LoadBackups());

        // "Alle Daten löschen": clear, save, then drop the older copies.
        store.ClearAll();
        store.Save();
        store.DiscardBackups();
        Assert.Empty(backend.LoadBackups());
        Assert.False(File.Exists(backend.CorruptPath));
        var reopened = new LibraryStore(backend);
        Assert.Equal(LoadRecovery.None, reopened.Recovery);
        Assert.Empty(reopened.ListSets());
        // A damaged file afterwards cannot bring the deleted sets back.
        File.WriteAllBytes(dir.LibraryPath, Bytes("""{"sets": ["""));
        Assert.Empty(new LibraryStore(backend).ListSets());

        var memory = new MemoryBackend(Bytes("{}"), [Bytes("""{"v":1}""")]);
        memory.DiscardBackups();
        Assert.Empty(memory.Backups);
        Assert.Equal(Bytes("{}"), memory.Data);
    }

    [Fact]
    public void AStoreOnACorruptFileRecoversAndKeepsTheDamagedCopy()
    {
        using var dir = new TempDir();
        var backend = new FileBackend(dir.LibraryPath, backupInterval: TimeSpan.Zero);
        var store = new LibraryStore(backend);
        store.CreateSet("Erste Fassung", cards: Sample);
        store.Save();
        store.CreateSet("Zweite Fassung", cards: Sample);
        store.Save();
        // The file gets damaged outside the app.
        File.WriteAllBytes(dir.LibraryPath, Bytes("{\"sets\": [{\"id\""));

        var recovered = new LibraryStore(backend);
        Assert.Equal(new LoadRecovery(LoadRecoveryKind.FromBackup, 0), recovered.Recovery);
        Assert.Equal(new[] { "Erste Fassung" }, recovered.ListSets().Select(s => s.Title));
        Assert.True(File.Exists(backend.CorruptPath));
        recovered.Save();
        Assert.Equal(LoadRecovery.None, new LibraryStore(backend).Recovery);
        Assert.Equal(new[] { "Erste Fassung" }, new LibraryStore(backend).ListSets().Select(s => s.Title));
    }

    [Fact]
    public void TheDefaultLocationIsTheWortschatzFolderInLocalAppData()
    {
        var path = FileBackend.DefaultPath();
        Assert.Equal("library.json", Path.GetFileName(path));
        Assert.Equal("Wortschatz", Path.GetFileName(Path.GetDirectoryName(path)));
        Assert.Equal(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Path.GetDirectoryName(Path.GetDirectoryName(path)));
    }

    // MARK: Helpers

    /// <summary>A fresh temporary folder, removed afterwards.</summary>
    sealed class TempDir : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "wortschatz-store-tests-" + Guid.NewGuid().ToString("N"));
        public string Folder => Path.Combine(Root, "Wortschatz");
        public string LibraryPath => Path.Combine(Folder, "library.json");

        public TempDir() => Directory.CreateDirectory(Root);

        public void Dispose()
        {
            try { Directory.Delete(Root, recursive: true); }
            catch (Exception) { }
        }
    }

    /// <summary>An in-memory backend that runs DuringSave while it writes (to change the library mid-save).</summary>
    sealed class DuringSaveBackend : IStorageBackend
    {
        readonly MemoryBackend _stored = new();
        public Action? DuringSave { get; set; }
        public byte[]? Load() => _stored.Load();
        public List<byte[]> LoadBackups() => _stored.LoadBackups();

        public void Save(byte[] data)
        {
            DuringSave?.Invoke();
            _stored.Save(data);
        }
    }

    /// <summary>A backend whose optional parts throw (a third-party or broken backend).</summary>
    sealed class ThrowingBackend(byte[]? data, List<byte[]>? backups = null) : IStorageBackend
    {
        readonly MemoryBackend _stored = new(data, backups);
        public bool FailBackups { get; init; }
        public bool FailPreserve { get; init; }
        public bool FailDiscard { get; set; }
        public byte[]? Load() => _stored.Load();
        public List<byte[]> LoadBackups() => FailBackups ? throw new UnauthorizedAccessException("backups") : _stored.LoadBackups();
        public void Save(byte[] data) => _stored.Save(data);
        public void PreserveCorrupt()
        {
            if (FailPreserve) throw new UnauthorizedAccessException("preserve");
            _stored.PreserveCorrupt();
        }
        public void DiscardBackups()
        {
            if (FailDiscard) throw new IOException("discard");
            _stored.DiscardBackups();
        }
    }
}
