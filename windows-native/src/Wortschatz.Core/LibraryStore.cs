using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// Port of LibraryStore.swift: the library (sets, progress, sessions, settings, activity) as one
/// JSON document with the semantics of src/store/db.js. Every mutation is atomic (rolled back on
/// failure) and reports the storage keys it changed (<see cref="Subscribe"/>). With
/// <c>autosave</c> each mutation is written at once; otherwise call <see cref="Save"/>.
/// Thread-safe.
/// </summary>
public sealed class LibraryStore
{
    public const int SCHEMA_VERSION = 1;
    /// <summary>The title of a set without one, in the app's language (it becomes the set's stored title; nothing compares it).</summary>
    public static string DEFAULT_TITLE => L("Unbenanntes Lernset");

    public IStorageBackend Backend { get; }
    public bool Autosave { get; }
    public TimeZoneInfo TimeZone { get; }

    readonly Func<double> _now;
    readonly Func<string> _makeID;
    readonly Lock _lock = new();
    readonly Lock _writeLock = new();
    LibraryDocument _doc;
    LoadRecovery _loadRecovery;
    bool _dirty;
    int _revision;
    int _writtenRevision;
    bool _metaChecked;
    int _depth;
    readonly ChangedKeys _changed = new();
    readonly List<(int Token, Action<StoreChange> Notify)> _listeners = [];
    int _lastToken;

    public LibraryStore(IStorageBackend backend, bool autosave = false, Func<double>? now = null, TimeZoneInfo? timeZone = null, Func<string>? makeID = null)
    {
        Backend = backend;
        Autosave = autosave;
        _now = now ?? TimeUtil.NowMs;
        TimeZone = timeZone ?? TimeUtil.Local;
        _makeID = makeID ?? (() => IDGen.Uid());
        (_doc, _loadRecovery) = LoadDocument(backend, _now(), _makeID);
        if (_loadRecovery.Kind == LoadRecoveryKind.FromBackup)
        {
            _dirty = true;
            _revision = 1;
            if (autosave) { try { Save(); } catch (LibraryStoreError) { } }
        }
    }

    public LoadRecovery Recovery { get { lock (_lock) return _loadRecovery; } }
    public bool HasUnsavedChanges { get { lock (_lock) return _dirty; } }

    public void Save()
    {
        LibraryDocument doc;
        int revision;
        lock (_lock)
        {
            if (!_dirty) return;
            doc = _doc;
            revision = _revision;
        }
        Write(doc, revision);
        lock (_lock) if (_revision == revision) _dirty = false;
    }

    public void Reload()
    {
        lock (_lock)
        {
            lock (_writeLock)
            {
                (_doc, _loadRecovery) = LoadDocument(Backend, _now(), _makeID);
                _metaChecked = false;
                _changed.Clear();
                _revision++;
                if (_loadRecovery.Kind == LoadRecoveryKind.FromBackup) _dirty = true;
                else
                {
                    _dirty = false;
                    _writtenRevision = _revision;
                }
            }
        }
        Emit(new StoreChange(StoreChangeKind.External, null));
    }

    // MARK: Sets

    public List<VocabSet> ListSets() { lock (_lock) return SortedSets(); }

    public VocabSet? GetSet(string setId) { lock (_lock) return _doc.Sets.FirstOrDefault(s => s.Id == setId); }

    public VocabSet CreateSet(string title = "", string description = "", Lang termLang = Lang.Fr, Lang defLang = Lang.De, IEnumerable<CardDraft>? cards = null) =>
        Mutate(() =>
        {
            var t = _now();
            var id = NewSetId(_doc.Sets.Select(s => s.Id).ToHashSet(StringComparer.Ordinal));
            var cleanTitle = JSLoose.CleanText(title);
            var set = new VocabSet
            {
                Id = id,
                Title = cleanTitle.Length == 0 ? DEFAULT_TITLE : cleanTitle,
                Description = JSLoose.CleanText(description),
                TermLang = termLang,
                DefLang = defLang,
                Cards = StoreSanitizer.BuildCards(cards ?? [], false, null, _makeID),
                CreatedAt = t,
                UpdatedAt = t,
            };
            _doc.Sets.Insert(0, set);
            Written(Key.Sets);
            return set;
        });

    public VocabSet UpdateSet(string setId, SetPatch patch) => Mutate(() =>
    {
        int index = RequireSet(setId);
        var old = _doc.Sets[index];
        var next = old;
        bool contentChanged = false;
        var removedIds = new List<string>();
        bool structural = false;
        if (patch.Title is { } title)
        {
            var clean = JSLoose.CleanText(title);
            next = next with { Title = clean.Length == 0 ? DEFAULT_TITLE : clean };
            contentChanged = true;
        }
        if (patch.Description is { } description)
        {
            next = next with { Description = JSLoose.CleanText(description) };
            contentChanged = true;
        }
        if (patch.TermLang is { } tl) { next = next with { TermLang = tl }; contentChanged = true; }
        if (patch.DefLang is { } dl) { next = next with { DefLang = dl }; contentChanged = true; }
        if (patch.StudyOptions is { } options)
        {
            var sanitized = options.Sanitized();
            next = next with { StudyOptions = sanitized.IsEmpty ? null : sanitized };
        }
        if (patch.Cards is { } cards)
        {
            var previousById = new Dictionary<string, Card>(StringComparer.Ordinal);
            foreach (var c in old.Cards) previousById[c.Id] = c;
            next = next with { Cards = StoreSanitizer.BuildCards(cards, true, previousById, _makeID) };
            var nextIds = next.Cards.Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
            removedIds = old.Cards.Where(c => !nextIds.Contains(c.Id)).Select(c => c.Id).ToList();
            structural = removedIds.Count > 0 || next.Cards.Any(c => !previousById.ContainsKey(c.Id));
            contentChanged = true;
        }
        if (contentChanged) next = next with { UpdatedAt = _now() };
        _doc.Sets[index] = next;
        Written(Key.Sets);
        if (removedIds.Count > 0 && _doc.Progress.TryGetValue(setId, out var progress))
        {
            var copy = new Dictionary<string, CardProgress>(progress, StringComparer.Ordinal);
            bool pruned = false;
            foreach (var id in removedIds) if (copy.Remove(id)) pruned = true;
            if (pruned)
            {
                _doc.Progress[setId] = copy;
                Written(Key.Progress(setId));
            }
        }
        if (structural && _doc.Sessions.TryGetValue(setId, out var s) && s.IsObject) RemoveSession(setId);
        if (structural && _doc.Learns.TryGetValue(setId, out var l) && l.IsObject) RemoveLearn(setId);
        return next;
    });

    public bool DeleteSet(string setId) => Mutate(() =>
    {
        int index = _doc.Sets.FindIndex(s => s.Id == setId);
        if (index >= 0)
        {
            _doc.Sets.RemoveAt(index);
            Written(Key.Sets);
        }
        RemoveSetData(setId);
        return index >= 0;
    });

    public VocabSet DuplicateSet(string setId) => Mutate(() =>
    {
        var set = _doc.Sets[RequireSet(setId)];
        var t = _now();
        var copy = set with
        {
            Id = NewSetId(_doc.Sets.Select(s => s.Id).ToHashSet(StringComparer.Ordinal)),
            Title = L($"{set.Title} (Kopie)"),
            Cards = StoreSanitizer.BuildCards(set.Cards.Select(CardDraft.FromCard), false, null, _makeID),
            CreatedAt = t,
            UpdatedAt = t,
            LastStudiedAt = null,
        };
        _doc.Sets.Insert(0, copy);
        Written(Key.Sets);
        return copy;
    });

    // MARK: Cards

    public Card UpdateCard(string setId, string cardId, CardChanges changes) => Mutate(() =>
    {
        int index = RequireSet(setId);
        var set = _doc.Sets[index];
        int pos = set.Cards.FindIndex(c => c.Id == cardId);
        if (pos < 0) throw new LibraryStoreError(LibraryStoreErrorCode.NotFound, StoreMessages.CardNotFound);
        var card = set.Cards[pos];
        var term = changes.Term is { } t ? JSLoose.CleanText(t) : card.Term;
        var definition = changes.Definition is { } d ? JSLoose.CleanText(d) : card.Definition;
        if (term.Length == 0 && definition.Length == 0) throw new LibraryStoreError(LibraryStoreErrorCode.Invalid, StoreMessages.EmptyCard);
        var next = new Card(card.Id, term, definition, changes.Starred ?? card.Starred);
        bool textChanged = term != card.Term || definition != card.Definition;
        var cards = new List<Card>(set.Cards) { [pos] = next };
        set = set with { Cards = cards };
        if (textChanged) set = set with { UpdatedAt = _now() };
        _doc.Sets[index] = set;
        Written(Key.Sets);
        return next;
    });

    public bool ToggleStar(string setId, string cardId) => Mutate(() =>
    {
        int index = RequireSet(setId);
        var set = _doc.Sets[index];
        int pos = set.Cards.FindIndex(c => c.Id == cardId);
        if (pos < 0) throw new LibraryStoreError(LibraryStoreErrorCode.NotFound, StoreMessages.CardNotFound);
        var cards = new List<Card>(set.Cards);
        cards[pos] = cards[pos] with { Starred = !cards[pos].Starred };
        _doc.Sets[index] = set with { Cards = cards };
        Written(Key.Sets);
        return cards[pos].Starred;
    });

    // MARK: Progress

    public Dictionary<string, CardProgress> GetProgress(string setId)
    {
        lock (_lock) return _doc.Progress.TryGetValue(setId, out var p) ? new Dictionary<string, CardProgress>(p, StringComparer.Ordinal) : new(StringComparer.Ordinal);
    }

    public CardProgress RecordAnswer(string setId, string cardId, bool correct, double? at = null) => Mutate(() =>
    {
        int index = RequireSet(setId);
        if (!_doc.Sets[index].Cards.Any(c => c.Id == cardId)) throw new LibraryStoreError(LibraryStoreErrorCode.NotFound, StoreMessages.CardNotFound);
        var time = at is { } a && double.IsFinite(a) ? a : _now();
        var progress = _doc.Progress.TryGetValue(setId, out var p) ? new Dictionary<string, CardProgress>(p, StringComparer.Ordinal) : new(StringComparer.Ordinal);
        progress.TryGetValue(cardId, out var prev);
        var entry = Mastery.ApplyAnswer(prev, correct, time);
        progress[cardId] = entry;
        _doc.Progress[setId] = progress;
        Written(Key.Progress(setId));
        var set = _doc.Sets[index];
        _doc.Sets[index] = set with { LastStudiedAt = Math.Max(set.LastStudiedAt ?? 0, time) };
        Written(Key.Sets);
        var day = TimeUtil.DateKey(time, TimeZone);
        _doc.Activity[day] = _doc.Activity.GetValueOrDefault(day) + 1;
        Written(Key.Activity);
        return entry;
    });

    public CardProgress OverrideLastAnswer(string setId, string cardId) => Mutate(() =>
    {
        var progress = _doc.Progress.TryGetValue(setId, out var p) ? new Dictionary<string, CardProgress>(p, StringComparer.Ordinal) : new(StringComparer.Ordinal);
        if (!progress.TryGetValue(cardId, out var prev) || prev.LastResult != AnswerResult.Incorrect)
            return Mastery.NormalizeProgress(progress.GetValueOrDefault(cardId));
        var entry = Mastery.ApplyOverride(prev);
        progress[cardId] = entry;
        _doc.Progress[setId] = progress;
        Written(Key.Progress(setId));
        return entry;
    });

    public void ResetProgress(string setId) => Mutate(() => { RemoveSetData(setId); return 0; });

    public int ResetCardProgress(string setId, IEnumerable<string> cardIds)
    {
        var ids = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in cardIds) if (id.Length > 0 && seen.Add(id)) ids.Add(id);
        if (ids.Count == 0) return 0;
        return Mutate(() =>
        {
            var progress = _doc.Progress.TryGetValue(setId, out var p) ? new Dictionary<string, CardProgress>(p, StringComparer.Ordinal) : new(StringComparer.Ordinal);
            int removed = 0;
            foreach (var id in ids) if (progress.Remove(id)) removed++;
            if (removed > 0)
            {
                if (progress.Count == 0) RemoveProgress(setId);
                else
                {
                    _doc.Progress[setId] = progress;
                    Written(Key.Progress(setId));
                }
            }
            RemoveSession(setId);
            RemoveLearn(setId);
            return removed;
        });
    }

    // MARK: Write and Learn sessions (stored as JSON, typed accessors repair like the engines)

    /// <summary>The stored Write session, repaired like the engine does (<c>WriteSession.CopyState</c>).</summary>
    public SessionState? GetSession(string setId) => GetSessionJSON(setId) is { } json ? WriteSession.CopyState(json) : null;

    /// <summary>Stores the state (null clears it); ignored for unknown sets.</summary>
    public void SaveSession(string setId, SessionState? state) => SaveSessionJSON(setId, state?.ToJson());

    /// <summary>The stored Learn session, repaired like the engine does (<c>LearnEngine.CopyState</c>).</summary>
    public LearnState? GetLearn(string setId) => GetLearnJSON(setId) is { } json ? LearnEngine.CopyState(json) : null;

    /// <summary>Stores the state (null clears it); ignored for unknown sets.</summary>
    public void SaveLearn(string setId, LearnState? state) => SaveLearnJSON(setId, state?.ToJson());

    public JSONValue? GetSessionJSON(string setId) { lock (_lock) return ObjectState(_doc.Sessions.GetValueOrDefault(setId)); }

    public void SaveSessionJSON(string setId, JSONValue? state)
    {
        if (state is null || !state.IsObject) { ClearSession(setId); return; }
        Mutate(() =>
        {
            if (!_doc.Sets.Any(s => s.Id == setId)) return 0;
            _doc.Sessions[setId] = state;
            Written(Key.Session(setId));
            return 0;
        });
    }

    public void ClearSession(string setId) => Mutate(() => { RemoveSession(setId); return 0; });

    public JSONValue? GetLearnJSON(string setId) { lock (_lock) return ObjectState(_doc.Learns.GetValueOrDefault(setId)); }

    public void SaveLearnJSON(string setId, JSONValue? state)
    {
        if (state is null || !state.IsObject) { ClearLearn(setId); return; }
        Mutate(() =>
        {
            if (!_doc.Sets.Any(s => s.Id == setId)) return 0;
            _doc.Learns[setId] = state;
            Written(Key.Learn(setId));
            return 0;
        });
    }

    public void ClearLearn(string setId) => Mutate(() => { RemoveLearn(setId); return 0; });

    // MARK: Settings and study options

    public Settings GetSettings() { lock (_lock) return _doc.Settings; }

    public Settings UpdateSettings(SettingsPatch patch) => Mutate(() =>
    {
        _doc.Settings = _doc.Settings.Merging(patch);
        Written(Key.Settings);
        return _doc.Settings;
    });

    public StudyOptions GetStudyOptions(string setId)
    {
        lock (_lock)
        {
            var own = _doc.Sets.FirstOrDefault(s => s.Id == setId)?.StudyOptions;
            return StudyOptions.Full(StudyOptionsPatch.FromFull(_doc.Settings.Study), own);
        }
    }

    public StudyOptions UpdateStudyOptions(string setId, StudyOptionsPatch patch) => Mutate(() =>
    {
        int index = RequireSet(setId);
        var merged = (_doc.Sets[index].StudyOptions ?? new StudyOptionsPatch()).Merging(patch);
        _doc.Sets[index] = _doc.Sets[index] with { StudyOptions = merged.IsEmpty ? null : merged };
        Written(Key.Sets);
        return GetStudyOptions(setId);
    });

    /// <summary>
    /// A change in a set's options (StudyChrome.OptionsBody): like UpdateStudyOptions, but an option set back to the
    /// standard's value (Einstellungen) is no longer the set's own (issue #8, 24.11.2026). Before, «Vorlesen» on and off
    /// again kept {audio: false}: the options said the set followed the standard, yet it stayed silent once the standard
    /// was switched on. UpdateStudyOptions stays the web app's mergeStudy (parity with store.json).
    /// </summary>
    public StudyOptions UpdateOwnStudyOptions(string setId, StudyOptionsPatch patch) => Mutate(() =>
    {
        int index = RequireSet(setId);
        var merged = (_doc.Sets[index].StudyOptions ?? new StudyOptionsPatch()).Merging(patch).DroppingStandard(patch.Sanitized(), _doc.Settings.Study);
        _doc.Sets[index] = _doc.Sets[index] with { StudyOptions = merged.IsEmpty ? null : merged };
        Written(Key.Sets);
        return GetStudyOptions(setId);
    });

    // MARK: Activity

    public Dictionary<string, int> GetActivity() { lock (_lock) return new Dictionary<string, int>(_doc.Activity, StringComparer.Ordinal); }

    // MARK: Backup

    public BackupDocument ExportAll()
    {
        lock (_lock)
        {
            var sets = SortedSets();
            var progress = new Dictionary<string, Dictionary<string, CardProgress>>(StringComparer.Ordinal);
            foreach (var set in sets)
                if (_doc.Progress.TryGetValue(set.Id, out var map) && map.Count > 0) progress[set.Id] = map;
            return new BackupDocument(_now(), sets, progress, _doc.Settings, new Dictionary<string, int>(_doc.Activity, StringComparer.Ordinal));
        }
    }

    public ImportSummary ImportAll(JSONValue data, ImportMode mode = ImportMode.Merge) => Mutate(() =>
    {
        var backup = ParseBackup(data);
        var existing = _doc.Sets;
        var existingIds = existing.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        var importedIds = backup.Sets.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        int updated = backup.Sets.Count(s => existingIds.Contains(s.Id));
        var summary = new ImportSummary(backup.Sets.Count - updated, updated);
        List<VocabSet> nextSets;
        if (mode == ImportMode.Replace) nextSets = [.. backup.Sets];
        else
        {
            var importedById = new Dictionary<string, VocabSet>(StringComparer.Ordinal);
            foreach (var s in backup.Sets) importedById[s.Id] = s;
            nextSets = existing.Select(s => importedById.GetValueOrDefault(s.Id) ?? s).Concat(backup.Sets.Where(s => !existingIds.Contains(s.Id))).ToList();
        }
        foreach (var set in backup.Sets) RemoveSetData(set.Id);
        if (mode == ImportMode.Replace)
        {
            foreach (var set in existing) RemoveSetData(set.Id);
            RemoveOrphans(importedIds);
        }
        _doc.Sets = nextSets;
        Written(Key.Sets);
        foreach (var set in backup.Sets)
        {
            if (!backup.Progress.TryGetValue(set.Id, out var map)) continue;
            _doc.Progress[set.Id] = map;
            Written(Key.Progress(set.Id));
        }
        if (mode == ImportMode.Replace)
        {
            if (backup.Settings is { } settings)
            {
                _doc.Settings = settings;
                Written(Key.Settings);
            }
            else
            {
                _doc.Settings = Settings.Default;
                Removed(Key.Settings);
            }
            _doc.Activity = backup.Activity;
            Written(Key.Activity);
        }
        else
        {
            foreach (var (day, n) in backup.Activity) _doc.Activity[day] = Math.Max(_doc.Activity.GetValueOrDefault(day), n);
            Written(Key.Activity);
        }
        return summary;
    });

    public ImportSummary ImportAll(BackupDocument backup, ImportMode mode = ImportMode.Merge) => ImportAll(backup.ToJson(), mode);

    /// <summary>The sets a backup would import (validates it like ImportAll).</summary>
    public static List<VocabSet> PreviewImport(JSONValue data)
    {
        var scratch = new LibraryStore(new MemoryBackend());
        scratch.ImportAll(data, ImportMode.Replace);
        return scratch.ListSets();
    }

    public SetSnapshot? SnapshotSet(string setId)
    {
        lock (_lock)
        {
            var set = _doc.Sets.FirstOrDefault(s => s.Id == setId);
            if (set is null) return null;
            return new SetSnapshot(set, GetProgress(setId), GetSessionJSON(setId), GetLearnJSON(setId));
        }
    }

    public VocabSet RestoreSet(SetSnapshot snapshot) => RestoreSet(snapshot.ToJson());

    public VocabSet RestoreSet(JSONValue snapshot) => Mutate(() =>
    {
        var rawSet = snapshot["set"];
        if (rawSet is null || rawSet["cards"]?.IsArray != true || StoreSanitizer.SanitizeSet(rawSet, _now(), _makeID) is not { } set)
            throw new LibraryStoreError(LibraryStoreErrorCode.Invalid, StoreMessages.BadSnapshot);
        var progress = StoreSanitizer.SanitizeProgressMap(snapshot["progress"], set.Cards.Select(c => c.Id).ToHashSet(StringComparer.Ordinal));
        int index = _doc.Sets.FindIndex(s => s.Id == set.Id);
        RemoveSetData(set.Id);
        if (index >= 0) _doc.Sets[index] = set;
        else _doc.Sets.Add(set);
        Written(Key.Sets);
        if (progress.Count > 0)
        {
            _doc.Progress[set.Id] = progress;
            Written(Key.Progress(set.Id));
        }
        if (snapshot["session"] is { IsObject: true } session)
        {
            _doc.Sessions[set.Id] = session;
            Written(Key.Session(set.Id));
        }
        if (snapshot["learn"] is { IsObject: true } learn)
        {
            _doc.Learns[set.Id] = learn;
            Written(Key.Learn(set.Id));
        }
        return set;
    });

    public void ClearAll() => Mutate(() =>
    {
        foreach (var set in _doc.Sets) RemoveSetData(set.Id);
        RemoveOrphans(new HashSet<string>());
        _doc.Sets = [];
        Removed(Key.Sets);
        _doc.Settings = Settings.Default;
        Removed(Key.Settings);
        _doc.Activity = new(StringComparer.Ordinal);
        Removed(Key.Activity);
        return 0;
    });

    // MARK: Change notification

    /// <summary>Calls <paramref name="listener"/> after every change; returns the unsubscribe action.</summary>
    public Action Subscribe(Action<StoreChange> listener)
    {
        int token;
        lock (_lock)
        {
            token = ++_lastToken;
            _listeners.Add((token, listener));
        }
        return () => { lock (_lock) _listeners.RemoveAll(l => l.Token == token); };
    }

    // MARK: - Internals

    public static class Key
    {
        public const string Sets = "sets";
        public const string Settings = "settings";
        public const string Activity = "activity";
        public const string Meta = "meta";
        public static string Progress(string setId) => "progress:" + setId;
        public static string Session(string setId) => "session:" + setId;
        public static string Learn(string setId) => "learn:" + setId;
    }

    sealed class ChangedKeys
    {
        readonly HashSet<string> _seen = new(StringComparer.Ordinal);
        public List<string> Keys { get; } = [];
        public bool IsEmpty => Keys.Count == 0;
        public void Insert(string key) { if (_seen.Add(key)) Keys.Add(key); }
        public void Clear() { Keys.Clear(); _seen.Clear(); }
    }

    sealed record ParsedBackup(List<VocabSet> Sets, Dictionary<string, Dictionary<string, CardProgress>> Progress, Settings? Settings, Dictionary<string, int> Activity);

    static (LibraryDocument, LoadRecovery) LoadDocument(IStorageBackend backend, double fallbackNow, Func<string> makeID)
    {
        bool primaryCorrupt = false;
        try
        {
            if (backend.Load() is { } data)
            {
                if (ParseDocument(data) is { } json) return (StoreSanitizer.Document(json, fallbackNow, makeID), LoadRecovery.None);
                primaryCorrupt = true;
            }
        }
        catch (Exception) { primaryCorrupt = true; }
        // The primary document is missing or unreadable: fall back to the newest readable backup. The backups and
        // setting the damaged file aside are best effort: an error there never keeps the library from opening.
        List<byte[]> backups;
        try { backups = backend.LoadBackups(); }
        catch (Exception) { backups = []; }
        for (int index = 0; index < backups.Count; index++)
        {
            if (ParseDocument(backups[index]) is not { } json) continue;
            if (primaryCorrupt) PreserveCorrupt(backend);
            return (StoreSanitizer.Document(json, fallbackNow, makeID), new LoadRecovery(LoadRecoveryKind.FromBackup, index));
        }
        if (primaryCorrupt)
        {
            PreserveCorrupt(backend);
            return (new LibraryDocument(), LoadRecovery.Reset);
        }
        return (new LibraryDocument(), LoadRecovery.None);
    }

    static void PreserveCorrupt(IStorageBackend backend)
    {
        try { backend.PreserveCorrupt(); }
        catch (Exception) { }
    }

    /// <summary>
    /// Deletes the backups and a set-aside damaged copy (after "Alle Daten löschen", Mac: SettingsWipeSheet). Best effort,
    /// never throws.
    /// </summary>
    public void DiscardBackups()
    {
        try { Backend.DiscardBackups(); }
        catch (Exception) { }
    }

    static JSONValue? ParseDocument(byte[] data)
    {
        try
        {
            var json = JSONValue.Parse(data);
            return json.IsObject ? json : null;
        }
        catch (Exception) { return null; }
    }

    static byte[] EncodeDocument(LibraryDocument doc) => doc.ToFileBytes();

    static JSONValue? ObjectState(JSONValue? value) => value is { IsObject: true } ? value : null;

    /// <summary>The error of a failed backend write: a full disk (or exhausted quota) becomes Quota, anything else Io.</summary>
    internal static LibraryStoreError SaveError(Exception error)
    {
        if (error is LibraryStoreError e) return e;
        if (IsOutOfSpace(error)) return new LibraryStoreError(LibraryStoreErrorCode.Quota, StoreMessages.DiskFull);
        return new LibraryStoreError(LibraryStoreErrorCode.Io, StoreMessages.Io);
    }

    /// <summary>
    /// Whether the disk is full or the user's disk quota is used up, also when the error is wrapped in another one
    /// (InnerException, AggregateException; Mac: isOutOfSpace with NSUnderlyingErrorKey).
    /// </summary>
    public static bool IsOutOfSpace(Exception? error)
    {
        for (var e = error; e is not null; e = e.InnerException)
        {
            if (e is AggregateException aggregate && aggregate.InnerExceptions.Any(IsOutOfSpace)) return true;
            if (e is IOException && IsOutOfSpaceCode(e.HResult)) return true;
        }
        return false;
    }

    static bool IsOutOfSpaceCode(int hresult)
    {
        // Windows: HRESULT_FROM_WIN32 of ERROR_HANDLE_DISK_FULL (39), ERROR_DISK_FULL (112), ERROR_DISK_QUOTA_EXCEEDED
        // (1295) and ERROR_NOT_ENOUGH_QUOTA (1816).
        if ((uint)hresult >> 16 == 0x8007) return (hresult & 0xFFFF) is 0x27 or 0x70 or 0x50F or 0x718;
        // Elsewhere .NET reports the raw errno: ENOSPC (28) and EDQUOT (122 on Linux, 69 on macOS).
        if (OperatingSystem.IsWindows()) return false;
        return hresult == 28 || hresult == (OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() ? 69 : 122);
    }

    /// <summary>
    /// The unsaved library encoded for writing (null: nothing to save). With <see cref="WriteEncoded"/> the app writes the
    /// file off the UI thread: encoding takes a consistent snapshot here, the slow disk write runs elsewhere.
    /// </summary>
    public (byte[] Data, int Revision)? EncodePending() => PendingSnapshot() is { } p ? (Encode(p.Doc), p.Revision) : null;

    /// <summary>
    /// The unsaved library as a copy of its own (null: nothing to save): taken under the lock (a few list and dictionary
    /// copies), so the app encodes it with <see cref="Encode"/> and writes it with <see cref="WriteEncoded"/> off the UI
    /// thread – encoding the whole library took long enough to stutter the next question's animation. Later changes edit
    /// the store's own document, never the copy (records and JSON values are immutable).
    /// </summary>
    public (LibraryDocument Doc, int Revision)? PendingSnapshot()
    {
        lock (_lock)
        {
            if (!_dirty || _revision <= _writtenRevision) return null;
            return (_doc.Clone(), _revision);
        }
    }

    /// <summary>The file's bytes of a document from <see cref="PendingSnapshot"/> (any thread).</summary>
    public static byte[] Encode(LibraryDocument doc)
    {
        try { return EncodeDocument(doc); }
        catch (Exception) { throw new LibraryStoreError(LibraryStoreErrorCode.Io, StoreMessages.Io); }
    }

    /// <summary>Writes what <see cref="EncodePending"/> returned (any thread); an older revision than the file's is skipped.</summary>
    public void WriteEncoded(byte[] data, int revision)
    {
        lock (_writeLock)
        {
            if (revision <= _writtenRevision) return;
            try { Backend.Save(data); }
            catch (Exception ex) { throw SaveError(ex); }
            _writtenRevision = revision;
        }
        lock (_lock) if (_revision == revision) _dirty = false;
    }

    // MARK: Revision

    /// <summary>Counts every change of the library (mutations, reloads, a synced library).</summary>
    public int Revision { get { lock (_lock) return _revision; } }


    void SaveLocked()
    {
        if (!_dirty) return;
        Write(_doc, _revision);
        _dirty = false;
    }

    void Write(LibraryDocument doc, int revision)
    {
        lock (_writeLock)
        {
            if (revision <= _writtenRevision) return;
            byte[] data;
            try { data = EncodeDocument(doc); }
            catch (Exception) { throw new LibraryStoreError(LibraryStoreErrorCode.Io, StoreMessages.Io); }
            try { Backend.Save(data); }
            catch (Exception ex) { throw SaveError(ex); }
            _writtenRevision = revision;
        }
    }

    /// <summary>
    /// Runs several write operations as one: a single change notification (and one autosave) at the end, and when one
    /// of them throws, all of them are undone. A study step writes its answer and its session this way, so the app
    /// reacts once per answer (Mac: LibraryStore.batch, 24.11.2026).
    /// </summary>
    public T Batch<T>(Func<T> body) => Mutate(body);

    /// <summary>Batch without a result.</summary>
    public void Batch(Action body) => Mutate(() =>
    {
        body();
        return 0;
    });

    T Mutate<T>(Func<T> body)
    {
        StoreChange? evt = null;
        Exception? failure = null;
        T result = default!;
        lock (_lock)
        {
            bool outer = _depth == 0;
            var before = outer ? (Doc: _doc.Clone(), MetaChecked: _metaChecked, Dirty: _dirty) : default;
            _depth++;
            try { result = body(); }
            catch (Exception ex) { failure = ex; }
            _depth--;
            if (outer)
            {
                void Rollback()
                {
                    _doc = before.Doc;
                    _metaChecked = before.MetaChecked;
                    _dirty = before.Dirty;
                    _changed.Clear();
                }
                if (failure is not null) Rollback();
                else if (!_changed.IsEmpty)
                {
                    _dirty = true;
                    _revision++;
                    if (Autosave)
                    {
                        try { SaveLocked(); }
                        catch (Exception ex)
                        {
                            Rollback();
                            failure = ex;
                        }
                    }
                }
                if (!_changed.IsEmpty)
                {
                    evt = new StoreChange(StoreChangeKind.Local, [.. _changed.Keys]);
                    _changed.Clear();
                }
            }
        }
        if (evt is not null) Emit(evt);
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        return result;
    }

    void Emit(StoreChange evt)
    {
        List<Action<StoreChange>> targets;
        lock (_lock) targets = _listeners.Select(l => l.Notify).ToList();
        foreach (var notify in targets) notify(evt);
    }

    void Written(string key)
    {
        _changed.Insert(key);
        if (!_metaChecked)
        {
            _metaChecked = true;
            if (_doc.SchemaVersion != SCHEMA_VERSION)
            {
                _doc.SchemaVersion = SCHEMA_VERSION;
                _changed.Insert(Key.Meta);
            }
        }
    }

    void Removed(string key) => _changed.Insert(key);

    void RemoveProgress(string setId) { _doc.Progress.Remove(setId); Removed(Key.Progress(setId)); }
    void RemoveSession(string setId) { _doc.Sessions.Remove(setId); Removed(Key.Session(setId)); }
    void RemoveLearn(string setId) { _doc.Learns.Remove(setId); Removed(Key.Learn(setId)); }

    void RemoveSetData(string setId)
    {
        RemoveProgress(setId);
        RemoveSession(setId);
        RemoveLearn(setId);
    }

    void RemoveOrphans(ISet<string> keep)
    {
        foreach (var id in _doc.Progress.Keys.Where(k => !keep.Contains(k)).OrderBy(k => k, StringComparer.Ordinal).ToList()) RemoveProgress(id);
        foreach (var id in _doc.Sessions.Keys.Where(k => !keep.Contains(k)).OrderBy(k => k, StringComparer.Ordinal).ToList()) RemoveSession(id);
        foreach (var id in _doc.Learns.Keys.Where(k => !keep.Contains(k)).OrderBy(k => k, StringComparer.Ordinal).ToList()) RemoveLearn(id);
    }

    int RequireSet(string setId)
    {
        int index = _doc.Sets.FindIndex(s => s.Id == setId);
        if (index < 0) throw new LibraryStoreError(LibraryStoreErrorCode.NotFound, StoreMessages.SetNotFound);
        return index;
    }

    string NewSetId(ISet<string> taken)
    {
        var id = _makeID();
        while (taken.Contains(id)) id = _makeID();
        return id;
    }

    List<VocabSet> SortedSets()
    {
        static double Recency(VocabSet s) => Math.Max(s.LastStudiedAt ?? 0, s.UpdatedAt);
        return _doc.Sets.Select((s, i) => (s, i))
            .OrderByDescending(x => Recency(x.s)).ThenByDescending(x => x.s.CreatedAt).ThenBy(x => x.i)
            .Select(x => x.s).ToList();
    }

    ParsedBackup ParseBackup(JSONValue data)
    {
        static LibraryStoreError Invalid(string message) => new(LibraryStoreErrorCode.InvalidBackup, message);
        if (data.ObjectValue is null || data["app"]?.StringValue != "wortschatz") throw Invalid(StoreMessages.NotBackup);
        if (data["version"] is { } version)
        {
            if (version.FiniteNumber is not { } n || n < 1) throw Invalid(StoreMessages.NotBackup);
            if (n > SCHEMA_VERSION) throw Invalid(StoreMessages.NewerBackup);
        }
        if (data["sets"]?.ArrayValue is not { } rawSets) throw Invalid(StoreMessages.NoSets);
        foreach (var part in new[] { "progress", "settings", "activity" })
            if (data[part] is { } value && !value.IsNull && !value.IsObject) throw Invalid(StoreMessages.BadPart(part));
        var fallback = _now();
        var rawProgress = data["progress"]?.ObjectValue;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var sets = new List<VocabSet>();
        var progress = new Dictionary<string, Dictionary<string, CardProgress>>(StringComparer.Ordinal);
        for (int i = 0; i < rawSets.Count; i++)
        {
            var raw = rawSets[i];
            if (raw.ObjectValue is not { } entry || raw["cards"]?.IsArray != true) throw Invalid(StoreMessages.BadSet(i + 1));
            if (raw["title"] is { } title && !title.IsNull && title.StringValue is null) throw Invalid(StoreMessages.BadSet(i + 1));
            var originalId = raw["id"]?.StringValue is { Length: > 0 } oid ? oid : null;
            var id = originalId is not null && !ids.Contains(originalId) ? originalId : NewSetId(ids);
            ids.Add(id);
            var copy = new JsonObjectMap();
            foreach (var (k, v) in entry) copy[k] = v;
            copy["id"] = id;
            if (StoreSanitizer.SanitizeSet(JSONValue.Object(copy), fallback, _makeID) is not { } set) throw Invalid(StoreMessages.BadSet(i + 1));
            sets.Add(set);
            if (id == originalId && rawProgress is not null && rawProgress.TryGetValue(id, out var map) && map.IsObject)
            {
                var clean = StoreSanitizer.SanitizeProgressMap(map, set.Cards.Select(c => c.Id).ToHashSet(StringComparer.Ordinal));
                if (clean.Count > 0) progress[id] = clean;
            }
        }
        var settings = data["settings"] is { IsObject: true } s ? Settings.FromJson(s) : null;
        return new ParsedBackup(sets, progress, settings, StoreSanitizer.SanitizeActivity(data["activity"]));
    }
}
