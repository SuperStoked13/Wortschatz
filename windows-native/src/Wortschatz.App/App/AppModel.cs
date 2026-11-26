using Avalonia.Threading;
using Wortschatz.App.Services;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App;

// Port of the Mac's AppModel.swift + AppModel+Actions.swift + Routing.swift (the parts the Windows app has so far): the
// library store and its snapshot, the route of the main window, toasts, prompts, and the actions views call. Views
// never change the store directly.

/// <summary>A study screen to open (Mac: StudyRequest). Id tells two requests for the same set apart.</summary>
public sealed record StudyRequest(string SetId, StudyMode Mode, StudySubset? Subset = null, bool ForceNew = false, bool ReviewMastered = false)
{
    public Guid Id { get; init; } = Guid.NewGuid();
}

/// <summary>What the main window shows (Mac: DetailRoute plus the editor sheet and the settings window).</summary>
public abstract record Route
{
    public sealed record Overview : Route;
    public sealed record SetDetail(string SetId) : Route;
    public sealed record Study(StudyRequest Request) : Route;
    /// <summary>
    /// The set editor; SetId null = a new set ("Neues Lernset"). StartWithImport opens the import box, OpenFile the
    /// file chooser right away (Mac: EditorRequest .importList, ⌘O).
    /// </summary>
    /// <remarks>Nonce tells two otherwise equal routes apart (a second share opens a fresh editor).</remarks>
    public sealed record Editor(string? SetId, bool StartWithImport = false, bool OpenFile = false, int Nonce = 0) : Route;
    public sealed record Settings : Route;

    /// <summary>The set the route is about (null for the overview and settings).</summary>
    public string? RouteSetId => this switch
    {
        SetDetail d => d.SetId,
        Study s => s.Request.SetId,
        Editor e => e.SetId,
        _ => null,
    };
}

/// <summary>The kind of a toast (Mac: ToastCenter.Toast.Tone): its symbol and colour.</summary>
public enum ToastTone { Neutral, Success, Warning, Danger, Streak }

/// <summary>
/// A toast at the bottom of the window (Mac: ToastCenter.Toast). Action: an optional button ("Rückgängig"); DurationMs
/// null: it stays until closed (with a close button).
/// </summary>
public sealed record ToastMessage(string Text, ToastTone Tone = ToastTone.Neutral, string? ActionLabel = null, Action? Action = null, int? DurationMs = ToastMessage.DefaultDuration)
{
    /// <summary>Like the web app and the Mac: 3.5 s.</summary>
    public const int DefaultDuration = 3500;
    public Guid Id { get; } = Guid.NewGuid();
    /// <summary>A symbol of its own instead of the tone's (Mac: systemImage, e.g. the waving hand of "Willkommen zurück").</summary>
    public DesignSystem.IconName? Icon { get; init; }
}

/// <summary>
/// A button of a prompt. Default: Enter; Cancel: Esc and a click outside. StaysOpen: the prompt stays after the action
/// (a sheet's "Kopieren"); the action closes it itself when done.
/// </summary>
public sealed record PromptButton(string Label, Action? Action = null, bool IsDefault = false, bool IsCancel = false, bool IsDestructive = false, bool StaysOpen = false);

/// <summary>
/// A question over the window (Mac: alert / confirmationDialog). A sheet (Mac: .sheet, e.g. "Backup importieren") adds
/// Content between the message and the buttons, its own Width and KeyHandler (keys go there first; true = handled).
/// </summary>
public sealed record PromptRequest(string Title, string Message, IReadOnlyList<PromptButton> Buttons)
{
    /// <summary>Controls between the message and the buttons (a sheet: backup import, text export, Tastenkürzel).</summary>
    public Avalonia.Controls.Control? Content { get; init; }
    /// <summary>The card's width (alerts 500; sheets wider, Mac: the sheet's frame width).</summary>
    public double Width { get; init; } = 500;
    public Func<Avalonia.Input.KeyEventArgs, bool>? KeyHandler { get; init; }

    /// <summary>A yes/no question: the confirm button (destructive: red) and "Abbrechen".</summary>
    public static PromptRequest Confirm(string title, string message, string confirmLabel, Action onConfirm, bool destructive = false) =>
        new(title, message, [new PromptButton(confirmLabel, onConfirm, IsDefault: !destructive, IsDestructive: destructive), new PromptButton(L("Abbrechen"), IsCancel: true, IsDefault: destructive)]);
}

/// <summary>
/// What another app shared with Wortschatz or opened in it (Android: "Teilen", "Öffnen mit"): files and/or text for
/// the import, or a backup.
/// </summary>
public sealed record SharedImport(IReadOnlyList<Wortschatz.Core.ImportSource> Sources, string? Text = null);

public sealed class AppModel
{
    public LibraryStore Store { get; }
    public SpeechService Speech { get; }
    public SoundEffects Sounds { get; }
    public AppPreferences Preferences { get; }

    /// <summary>
    /// Synonyms of a written question's answer that are not in the set ("Weitere Synonyme erkennen" and the set's own
    /// switch in its options; Mac: SynonymAssistant.extraAnswers / isActive(forSet:)): from the built-in thesaurus of the
    /// answer language, none when switched off. Read at every answer, so a change applies at once.
    /// </summary>
    public Func<SynonymQuery, IReadOnlyList<string>> ExtraAnswers(string setId) => query =>
        Preferences.ExtendedSynonymsFor(setId) ? Wortschatz.Core.ExtendedSynonyms.ThesaurusAnswers(query) : [];

    /// <summary>
    /// A set's page opened: what its first multiple-choice round needs (the cards' word classes) is worked out in the
    /// background, so «Lernen» starts without waiting for it (LearnEngine.PrepareChoices).
    /// </summary>
    public void PrepareStudy(string setId)
    {
        if (Set(setId) is not { Cards.Count: > 1 } set) return;
        var cards = set.Cards;
        Task.Run(() =>
        {
            try { LearnEngine.PrepareChoices(cards); }
            catch (Exception) { }
        });
    }

    /// <summary>A written session starts: its languages' thesauri load in the background (if synonyms are on for the set).</summary>
    public void PreloadSynonyms(VocabSet? set)
    {
        if (set is null || !Preferences.ExtendedSynonymsFor(set.Id)) return;
        SynonymLexicon.Preload(set.TermLang);
        SynonymLexicon.Preload(set.DefLang);
    }

    /// <summary>The library changed (a hook; nothing to do in this build).</summary>
    void LibraryChangedForSync()
    {
    }
    public Route Route { get; private set; } = new Route.Overview();
    /// <summary>The toasts on screen, oldest first (at most MaxToasts, like the web app's MAX_TOASTS).</summary>
    public List<ToastMessage> Toasts { get; } = [];
    public const int MaxToasts = 4;
    /// <summary>The sidebar's search text.</summary>
    public string Search { get; set; } = "";
    /// <summary>The question on screen (null: none).</summary>
    public PromptRequest? Prompt { get; private set; }

    /// <summary>The route or the data changed: the window renders again.</summary>
    public event Action? Changed;
    /// <summary>Only the route changed (a new screen).</summary>
    public event Action? RouteChanged;
    public event Action<ToastMessage>? ToastShown;
    public event Action<Guid>? ToastDismissed;
    public event Action? PromptChanged;

    LibrarySnapshot? _library;
    readonly Dictionary<Lang, DateTime> _missingVoiceShown = [];

    public AppModel(LibraryStore store, AppPreferences preferences, SpeechService? speech = null)
    {
        Store = store;
        Preferences = preferences;
        // The texts' language before anything shows a text (Mac: AppLanguage.install at launch).
        AppLanguage.Install(preferences.Language);
        Speech = speech ?? SpeechService.Create();
        // A set's own switch (its options) mutes the sounds while it is on screen.
        Sounds = new SoundEffects(() => Preferences.SoundEffectsFor(Route.RouteSetId));
        Speech.MissingVoice += lang => Dispatcher.UIThread.Post(() => ShowMissingVoice(lang));
        Speech.LoadPreferredVoices(Preferences.SpeechVoices);
        Speech.PreferredVoicesChanged += () => Preferences.SpeechVoices = new Dictionary<Lang, string>(Speech.PreferredVoiceIds);
        Store.Subscribe(change =>
        {
            _library = null;
            if (change.Kind == StoreChangeKind.Local) SaveSoon();
            Changed?.Invoke();
            CelebrateDailyStreak();
        });
        ObserveLearnSwitches();
    }

    // MARK: Learn switches (Mac: AppModel+LearnSwitches.swift)

    /// <summary>«Wiederholungsfragen» and «Nachkontrolle nach Fehlern» (the same for every set).</summary>
    public readonly record struct LearnSwitches(bool Review, bool Recheck);

    /// <summary>The two Learn switches as they are now.</summary>
    public LearnSwitches CurrentLearnSwitches => new(Preferences.LearnReview, Preferences.LearnRecheck);

    /// <summary>The switches the stored sessions were last brought in line with.</summary>
    LearnSwitches _learnSwitches;

    /// <summary>
    /// Brings the stored sessions in line with the Nachkontrolle now (sessions stored before the switches applied at once
    /// kept it for days), then watches the two Learn switches wherever they are switched: Einstellungen › Lernen, a set's
    /// options, Lernen's options.
    /// </summary>
    void ObserveLearnSwitches()
    {
        _learnSwitches = CurrentLearnSwitches;
        SwitchStoredSessions(review: null, recheck: _learnSwitches.Recheck);
        // Imported preferences may come from another thread: looked at on the UI thread.
        Preferences.LearnSwitchesChanged += () => Dispatcher.UIThread.Post(LearnSwitchesMayHaveChanged);
    }

    /// <summary>
    /// A switch that changed applies at once to every stored Learn session (since 24.11.2026: before, a long session
    /// kept the rechecks for days after they were switched off). An open Lernen applies it to its own session too
    /// (LearnController.SwitchesMayHaveChanged, from its options or after Changed).
    /// </summary>
    void LearnSwitchesMayHaveChanged()
    {
        var now = CurrentLearnSwitches;
        var before = _learnSwitches;
        if (now == before) return;
        _learnSwitches = now;
        SwitchStoredSessions(now.Review != before.Review ? now.Review : null, now.Recheck != before.Recheck ? now.Recheck : null);
        Changed?.Invoke();
    }

    /// <summary>Every unfinished stored session with the switched option(s) applied (null: not switched), written as one change.</summary>
    void SwitchStoredSessions(bool? review, bool? recheck)
    {
        double time = TimeUtil.NowMs();
        var switched = new List<(string SetId, LearnFlow.SavedLearn Saved)>();
        foreach (var set in Store.ListSets())
        {
            if (LearnFlow.SavedLearn.FromJson(Store.GetLearnJSON(set.Id)) is not { } saved
                || saved.Switching(review, recheck, Store.GetProgress(set.Id), time) is not { } next) continue;
            switched.Add((set.Id, next));
        }
        if (switched.Count == 0) return;
        try
        {
            Store.Batch(() =>
            {
                foreach (var (setId, saved) in switched) Store.SaveLearnJSON(setId, saved.ToJson());
            });
        }
        catch (LibraryStoreError e)
        {
            Report(e);
        }
    }

    // MARK: Saving

    DispatcherTimer? _saveTimer;
    Task _writing = Task.CompletedTask;
    /// <summary>The sticky toast of a failed save (Mac: saveFailureToast); the next successful save removes it.</summary>
    Guid? _saveFailureToast;

    /// <summary>Like the Mac (AppModel.saveDelay): at most this long after the first unsaved change.</summary>
    public static readonly TimeSpan SaveDelay = TimeSpan.FromMilliseconds(300);

    /// <summary>
    /// Saves the library shortly after a change (Mac: scheduleSave): a burst of changes (an answer records the answer
    /// and the session) is written once, at the latest SaveDelay after the first one, so typing without a pause never
    /// postpones the save; the file is written off the UI thread, so answering never waits for the disk.
    /// <see cref="Flush"/> writes at once (closing the window).
    /// </summary>
    public void SaveSoon()
    {
        if (Store.Backend is MemoryBackend) return;
        _saveTimer ??= new DispatcherTimer(SaveDelay, DispatcherPriority.Background, (_, _) =>
        {
            _saveTimer?.Stop();
            SaveInBackground();
        });
        if (_saveTimer.IsEnabled) return;
        _saveTimer.Start();
    }

    void SaveInBackground()
    {
        // A copy of the unsaved library is cheap; encoding it (the whole library as JSON) and writing it run in the
        // background, in order, so the UI thread never waits for either.
        if (Store.PendingSnapshot() is not { } p) return;
        var previous = _writing;
        _writing = Task.Run(async () =>
        {
            await previous;
            Exception? failure = null;
            try { Store.WriteEncoded(LibraryStore.Encode(p.Doc), p.Revision); }
            catch (Exception e) { failure = e; }
            Dispatcher.UIThread.Post(() => SaveFinished(failure));
        });
    }

    /// <summary>
    /// Writes unsaved changes now (Mac: save()); a failure shows the sticky toast instead of throwing (the changes stay
    /// in memory and the next change tries again). For actions that want the file written at once.
    /// </summary>
    public void SaveNow()
    {
        if (Store.Backend is MemoryBackend) return;
        try
        {
            Store.Save();
            SaveFinished(null);
        }
        catch (Exception e) { SaveFinished(e); }
    }

    /// <summary>A failed save shows a toast that stays (once); the next successful save removes it (Mac: saveFinished).</summary>
    void SaveFinished(Exception? error)
    {
        if (error is null)
        {
            if (_saveFailureToast is not { } id) return;
            _saveFailureToast = null;
            DismissToast(id);
            return;
        }
        if (_saveFailureToast is { } shown && Toasts.Any(t => t.Id == shown)) return;
        var toast = new ToastMessage(Message(error), ToastTone.Danger, DurationMs: null);
        _saveFailureToast = toast.Id;
        ShowToast(toast);
    }

    /// <summary>Writes everything now (the window closes). False when the library could not be saved.</summary>
    public bool Flush()
    {
        Preferences.Flush();
        _saveTimer?.Stop();
        try { _writing.Wait(TimeSpan.FromSeconds(5)); }
        catch (AggregateException) { }
        try
        {
            Store.Save();
            SaveFinished(null);
            return true;
        }
        catch (LibraryStoreError)
        {
            return false;
        }
    }

    /// <summary>The text of an error for a toast (Mac: AppModel.message(for:fallback:)); no fallback: «Etwas ist schiefgelaufen …».</summary>
    public static string Message(Exception error, string? fallback = null) =>
        error switch
        {
            LibraryStoreError store => store.Message,
            BackupFileError file => file.Message,
            _ => fallback ?? L("Etwas ist schiefgelaufen. Bitte versuche es nochmal."),
        };

    /// <summary>An error as a red toast (Mac: report(_:fallback:)).</summary>
    public void Report(Exception error, string? fallback = null) =>
        ShowToast(new ToastMessage(Message(error, fallback), ToastTone.Danger, DurationMs: 6000));

    /// <summary>
    /// The library in %LOCALAPPDATA%\Wortschatz\library.json, the earlier WebView app's folder. On the first start this
    /// app takes over everything of the earlier app and then removes it (<see cref="EarlierApp"/>).
    /// Tests on a real PC: WORTSCHATZ_NATIVE_DATA points to another library folder; WORTSCHATZ_LEGACY_DATA to a stand-in
    /// for the earlier app's folder (with WebView2\…\leveldb, exe files are looked for only there). A test library
    /// folder without WORTSCHATZ_LEGACY_DATA never takes over or removes the real earlier app.
    /// </summary>
    public static AppModel OpenDefault()
    {
        var folder = Environment.GetEnvironmentVariable("WORTSCHATZ_NATIVE_DATA");
        // An update test (AppUpdater.TestKey) never touches the real library: it keeps its own next to the test exe.
        if (AppUpdater.TestFolder is { } updateTest) folder = Path.Combine(updateTest, "data");
        string path;
        try
        {
            // Without %LOCALAPPDATA% the default path would be relative (next to wherever the exe was started).
            if (string.IsNullOrWhiteSpace(folder) && string.IsNullOrEmpty(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)))
                return InMemory(null);
            path = Path.GetFullPath(string.IsNullOrWhiteSpace(folder) ? FileBackend.DefaultPath() : Path.Combine(folder, "library.json"));
        }
        catch (Exception e)
        {
            return InMemory(e.Message);
        }
        var backend = new FileBackend(path);
        var testRoot = Environment.GetEnvironmentVariable("WORTSCHATZ_LEGACY_DATA");
        string? legacyRoot = !string.IsNullOrWhiteSpace(testRoot) ? testRoot
            : string.IsNullOrWhiteSpace(folder) ? LegacyWebStorage.DefaultRoot : null;

        bool firstStart = !File.Exists(path) && backend.LoadBackups().Count == 0;
        LegacyTakeover? takeover = null;
        string? failure = null;
        if (firstStart && legacyRoot is not null)
        {
            takeover = LegacyWebStorage.ReadTakeover(LegacyWebStorage.LevelDbFolder(legacyRoot));
            if (takeover is not null)
            {
                // Written as this app's library before it is loaded: loading repairs it like any stored library.
                try { backend.Save(System.Text.Encoding.UTF8.GetBytes(takeover.Library.ToJsonString())); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    failure = e.Message;
                    takeover = null;
                }
            }
        }

        // No autosave: every change schedules a save (SaveSoon), written in the background.
        var store = new LibraryStore(backend, autosave: false);
        var preferences = AppPreferences.Load(Path.Combine(Path.GetDirectoryName(path)!, "preferences.json"));
        if (takeover is not null) preferences.Import(takeover.Preferences);
        // Remove the earlier app once its data are here (or it had none); never after a failed takeover.
        if (firstStart && legacyRoot is not null && failure is null && EarlierApp.HasLeftovers(legacyRoot))
            preferences.EarlierAppRemovePending = true;

        var model = new AppModel(store, preferences);
        model.StartupPrompt = RecoveryPrompt(store);
        // A library repaired while loading is written at once (Mac: AppModel init).
        if (store.HasUnsavedChanges) model.SaveSoon();
        if (takeover is not null)
        {
            int n = store.ListSets().Count;
            model.ShowToast(new ToastMessage(
                n == 1 ? L("1 Lernset aus der bisherigen Windows-App übernommen.") : L($"{n} Lernsets aus der bisherigen Windows-App übernommen."),
                ToastTone.Success, DurationMs: 7000));
        }
        else if (failure is not null)
        {
            model.ShowToast(new ToastMessage(L($"Die Lernsets der bisherigen Windows-App konnten nicht übernommen werden: {failure}"),
                ToastTone.Warning, DurationMs: 9000));
        }

        if (legacyRoot is not null && preferences.EarlierAppRemovePending)
        {
            var root = legacyRoot;
            var exeFolders = !string.IsNullOrWhiteSpace(testRoot) ? [root] : EarlierApp.DefaultExeFolders().ToList();
            // In the background (deleting the browser cache can take a moment); retried on the next start until done.
            Task.Run(() =>
            {
                bool done;
                try { done = EarlierApp.Remove(root, LegacyWebStorage.LevelDbFolder(root), exeFolders); }
                catch (Exception) { done = false; }
                if (done) Dispatcher.UIThread.Post(() => preferences.EarlierAppRemovePending = false);
            });
        }

        // Downloads of older versions of this app go (a new download replaces the old one; both share this data
        // folder). In the background, on every start, also finding the folders (known-folder lookup, disk checks); with
        // a test library (WORTSCHATZ_NATIVE_DATA) only in its folder and next to the exe, never in the real Downloads
        // folder.
        string[]? testFolders = !string.IsNullOrWhiteSpace(folder) ? [folder] : null;
        Task.Run(() =>
        {
            try { OlderVersions.Remove(OlderVersions.Folders(testFolders).ToList()); }
            catch (Exception) { }
        });
        return model;
    }

    /// <summary>
    /// The library of the phone app in <paramref name="folder"/> (Android: the app's private files). Nothing to take
    /// over and no older downloads to remove, unlike <see cref="OpenDefault"/> on Windows; the same repair and recovery.
    /// </summary>
    public static AppModel OpenAt(string folder, SpeechService? speech = null)
    {
        string path;
        try
        {
            Directory.CreateDirectory(folder);
            path = Path.GetFullPath(Path.Combine(folder, "library.json"));
        }
        catch (Exception e)
        {
            return InMemory(e.Message);
        }
        var store = new LibraryStore(new FileBackend(path), autosave: false);
        var preferences = AppPreferences.Load(Path.Combine(folder, "preferences.json"));
        var model = new AppModel(store, preferences, speech);
        model.StartupPrompt = RecoveryPrompt(store);
        if (store.HasUnsavedChanges) model.SaveSoon();
        return model;
    }

    /// <summary>The question after a damaged library was repaired on loading (null: it loaded fine).</summary>
    static PromptRequest? RecoveryPrompt(LibraryStore store) => store.Recovery.Kind switch
    {
        LoadRecoveryKind.FromBackup => new PromptRequest(L("Deine Daten wurden wiederhergestellt"),
            L("Die Datei mit deinen Lernsets war beschädigt oder fehlte. Wortschatz hat die neueste lesbare Sicherung geladen; die letzten Minuten vor dem Problem können fehlen."),
            [new PromptButton("OK", IsDefault: true, IsCancel: true)]),
        LoadRecoveryKind.Reset => new PromptRequest(L("Deine Daten konnten nicht gelesen werden"),
            L("Die Datei mit deinen Lernsets ist beschädigt, und es gibt keine lesbare Sicherung. Wortschatz startet leer; die beschädigte Datei bleibt als «library-corrupt.json» im Speicherort erhalten. Mit einem Backup kannst du deine Lernsets wiederherstellen."),
            [new PromptButton("OK", IsDefault: true, IsCancel: true)]),
        _ => null,
    };

    /// <summary>
    /// The app on an in-memory library when not even the storage location can be found (Mac: AppModel.launch): it works,
    /// and says that changes are lost when it quits. <paramref name="reason"/>: an error's message; null: the folder
    /// «AppData\Local» is missing.
    /// </summary>
    static AppModel InMemory(string? reason)
    {
        var model = new AppModel(new LibraryStore(new MemoryBackend()), AppPreferences.InMemory());
        // The texts after the model: its constructor sets their language.
        string why = reason ?? L("Der Ordner «AppData\\Local» fehlt.");
        model.StartupPrompt = new PromptRequest(L("Die Daten können nicht gespeichert werden"),
            L($"Wortschatz findet seinen Speicherort nicht. Änderungen gehen beim Beenden verloren. ({why})"),
            [new PromptButton("OK", IsDefault: true, IsCancel: true)]);
        return model;
    }

    // MARK: Library

    /// <summary>The library's view data, rebuilt once after each store change (Mac: AppModel.library).</summary>
    public LibrarySnapshot Library => _library ??= LibrarySnapshot.Build(Store);

    /// <summary>
    /// The clock moved on (the overview's minute): the next read builds the snapshot anew with the time now, so «vor
    /// 5 Minuten», «gestern» and today's answers follow the clock, not only the next change of the library.
    /// </summary>
    public void RefreshLibraryTime() => _library = null;

    public List<VocabSet> Sets => Library.Sets.Select(s => s.Set).ToList();

    /// <summary>Sets matching the sidebar search (title, description or a card), as summaries.</summary>
    public IReadOnlyList<SetSummary> FilteredSets
    {
        get
        {
            var q = JSCompat.Trim(Search);
            if (q.Length == 0) return Library.Sets;
            var needle = Fold(q);
            bool Has(string s) => Fold(s).Contains(needle, StringComparison.Ordinal);
            return Library.Sets.Where(s => Has(s.Set.Title) || Has(s.Set.Description) || s.Set.Cards.Any(c => Has(c.Term) || Has(c.Definition))).ToList();
        }
    }

    static string Fold(string s) => string.Join(' ', JSCompat.Lower(TextNormalizer.StripDiacritics(s)).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    public VocabSet? Set(string id) => Store.GetSet(id);

    public SetSummary? Summary(string id) => Library.Summary(id);

    public SetProgress ProgressOf(VocabSet set) => Library.Summary(set.Id)?.Stats ?? Mastery.SetProgressOf(set, Store.GetProgress(set.Id));

    public StudyStreak Streak => Library.Stats.Streak;

    /// <summary>The set the window is about (the set page, a study screen or the editor of a set).</summary>
    public string? CurrentSetId => Route.RouteSetId is { } id && Store.GetSet(id) is not null ? id : null;

    // MARK: Navigation

    /// <summary>
    /// The active screen can hold the learner back before it is left (Mac: StudyLeaveGuard, the editor sheet): an exam
    /// with answers, an editor with unsaved changes. It gets the navigation and returns true when it asked instead; the
    /// navigation then runs only once confirmed. Screens set it in Activate and clear it in Deactivate.
    /// </summary>
    public Func<Action, bool>? LeaveGuard { get; set; }

    /// <summary>A notice for the first moment the window is open (a recovered library).</summary>
    public PromptRequest? StartupPrompt { get; set; }

    public void Navigate(Route route)
    {
        if (route == Route) return;
        if (LeaveGuard is { } guard && guard(() =>
            {
                LeaveGuard = null;
                Navigate(route);
            })) return;
        ClosePrompt();
        Route = route;
        RouteChanged?.Invoke();
    }

    public void ShowOverview() => Navigate(new Route.Overview());

    // MARK: Shared from other apps

    SharedImport? _shared;

    /// <summary>Something was shared with the app (the view takes it with <see cref="TakeShared"/>).</summary>
    public event Action? SharedArrived;

    /// <summary>Hands over what another app shared (any thread is fine: the view picks it up on the UI thread).</summary>
    public void ReceiveShared(SharedImport shared)
    {
        _shared = shared;
        Dispatcher.UIThread.Post(() => SharedArrived?.Invoke());
    }

    /// <summary>The shared content not handled yet (null: none), taken once.</summary>
    public SharedImport? TakeShared()
    {
        var shared = _shared;
        _shared = null;
        return shared;
    }

    /// <summary>Shared content the new set's editor imports when it opens (see SetEditorScreen.TakePendingImport).</summary>
    public SharedImport? PendingImport { get; set; }

    public void OpenSet(string setId) => Navigate(new Route.SetDetail(setId));

    public void Study(string setId, StudyMode mode, StudySubset? subset = null, bool forceNew = false, bool reviewMastered = false)
    {
        if (Store.GetSet(setId) is not { Cards.Count: > 0 }) return;
        Navigate(new Route.Study(new StudyRequest(setId, mode, subset, forceNew, reviewMastered)));
    }

    public void OpenEditor(string? setId = null, bool startWithImport = false, bool openFile = false) =>
        Navigate(new Route.Editor(setId, startWithImport || openFile, openFile));

    /// <summary>Leaves a study screen or the editor: back to the set (or the overview when it is gone).</summary>
    public void BackToSet(string? setId)
    {
        if (setId is not null && Store.GetSet(setId) is not null) OpenSet(setId);
        else ShowOverview();
    }

    // MARK: Prompts

    public void Ask(PromptRequest prompt)
    {
        Prompt = prompt;
        PromptChanged?.Invoke();
    }

    /// <summary>Closes the prompt and runs the button's action.</summary>
    public void Answer(PromptButton button)
    {
        if (!button.StaysOpen) ClosePrompt();
        button.Action?.Invoke();
    }

    public void ClosePrompt()
    {
        if (Prompt is null) return;
        Prompt = null;
        PromptChanged?.Invoke();
    }

    // MARK: Actions

    public VocabSet CreateSet(string title, Lang termLang, Lang defLang, IEnumerable<CardDraft> cards, string description = "")
    {
        var set = Store.CreateSet(title, description, termLang, defLang, cards);
        SaveNow();
        return set;
    }

    /// <summary>"Duplizieren": the copy with a toast that opens it (Mac: duplicateSet).</summary>
    public void DuplicateSet(string setId)
    {
        if (Store.GetSet(setId) is not { } set) return;
        try
        {
            var copy = Store.DuplicateSet(setId);
            SaveNow();
            LibraryChangedForSync();
            // Long enough to read and tap «Öffnen» (3.5 s went by unnoticed on the phone).
            ShowToast(new ToastMessage(L($"Kopie von «{ShortTitle(set.Title)}» erstellt"), ToastTone.Success, L("Öffnen"), () => OpenSet(copy.Id), DurationMs: 6000));
        }
        catch (Exception e)
        {
            Report(e, L("Das Lernset konnte nicht dupliziert werden."));
        }
    }

    /// <summary>"Fortschritt zurücksetzen…" with a question first (Mac: confirmResetProgress).</summary>
    public void ConfirmResetProgress(string setId)
    {
        if (Store.GetSet(setId) is null) return;
        Ask(PromptRequest.Confirm(L("Fortschritt zurücksetzen?"),
            L("Alle Begriffe gelten danach wieder als «Neu», und laufende Runden in Lernen und Schreiben werden beendet. Die Begriffe selbst bleiben erhalten."),
            L("Zurücksetzen"), () =>
            {
                // Like the Mac: the answers and running Lernen/Schreiben rounds go; the flashcard pile stays (the
                // question does not mention it).
                try
                {
                    Store.ResetProgress(setId);
                    SaveNow();
                    LibraryChangedForSync();
                    ShowToast(new ToastMessage(L("Fortschritt zurückgesetzt"), ToastTone.Success));
                }
                catch (Exception e) { Report(e); }
            }, destructive: true));
    }

    /// <summary>
    /// "Löschen" (Ctrl+Entf): deletes at once; Ctrl+Z or the toast's "Rückgängig" puts the set back with its progress and
    /// running sessions, Ctrl+Y deletes it again (Mac: deleteSet with the snapshot and the UndoManager).
    /// </summary>
    public void DeleteSet(string setId)
    {
        var snapshot = Store.SnapshotSet(setId);
        if (snapshot is null) return;
        try { Store.DeleteSet(setId); }
        catch (Exception e)
        {
            Report(e, L("Das Lernset konnte nicht gelöscht werden."));
            return;
        }
        SaveNow();
        LibraryChangedForSync();
        if (Route.RouteSetId == setId) ShowOverview();
        var record = new DeletedSet(snapshot);
        _undo.Add(record);
        _redo.Clear();
        var title = ShortTitle(snapshot.Set.Title);
        ShowToast(new ToastMessage(L($"«{title}» gelöscht"), ActionLabel: L("Rückgängig"), Action: () =>
        {
            // The undo stack must not restore it a second time.
            _undo.Remove(record);
            _redo.Remove(record);
            RestoreDeleted(record);
        }, DurationMs: 7000) { Icon = DesignSystem.IconName.Trash });
        DesignSystem.Announcer.Announce(L($"Lernset «{title}» gelöscht"));
    }

    /// <summary>A deleted set's snapshot, the target of its undo/redo (Mac: DeletedSet).</summary>
    sealed class DeletedSet(SetSnapshot snapshot)
    {
        public SetSnapshot Snapshot = snapshot;
    }

    readonly List<DeletedSet> _undo = [];
    readonly List<DeletedSet> _redo = [];

    /// <summary>"Widerrufen: Lernset löschen" is possible (Ctrl+Z).</summary>
    public bool CanUndo => _undo.Count > 0;
    /// <summary>"Wiederholen: Lernset löschen" is possible (Ctrl+Y).</summary>
    public bool CanRedo => _redo.Count > 0;

    /// <summary>Ctrl+Z: puts the most recently deleted set back (Mac: Bearbeiten › Widerrufen). False: nothing to undo.</summary>
    public bool Undo()
    {
        if (_undo.Count == 0) return false;
        var record = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        if (RestoreDeleted(record)) _redo.Add(record);
        return true;
    }

    /// <summary>Ctrl+Y / Ctrl+Shift+Z: deletes a set put back by Ctrl+Z again (Mac: Bearbeiten › Wiederholen).</summary>
    public bool Redo()
    {
        if (_redo.Count == 0) return false;
        var record = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        var setId = record.Snapshot.Set.Id;
        if (Store.SnapshotSet(setId) is not { } snapshot) return true;
        try { Store.DeleteSet(setId); }
        catch (Exception e)
        {
            Report(e);
            return true;
        }
        SaveNow();
        if (Route.RouteSetId == setId) ShowOverview();
        record.Snapshot = snapshot;
        _undo.Add(record);
        return true;
    }

    /// <summary>Puts a deleted set back; true when it is back (Mac: restoreDeleted).</summary>
    bool RestoreDeleted(DeletedSet record)
    {
        if (Store.GetSet(record.Snapshot.Set.Id) is not null) return false;
        try
        {
            var set = Store.RestoreSet(record.Snapshot);
            SaveNow();
            LibraryChangedForSync();
            ShowToast(new ToastMessage(L($"«{ShortTitle(set.Title)}» wiederhergestellt"), ToastTone.Success));
            if (Route is Route.Overview || Route.RouteSetId is null) OpenSet(set.Id);
            return true;
        }
        catch (Exception e)
        {
            Report(e, L("Das Lernset konnte nicht wiederhergestellt werden."));
            return false;
        }
    }

    /// <summary>
    /// The ★ toggle of a card. Saved like an answer (SaveSoon through the store notification): a star clicked on a long
    /// list no longer waits for the whole library to be encoded and written.
    /// </summary>
    public void ToggleStar(string setId, string cardId)
    {
        try { Store.ToggleStar(setId, cardId); }
        catch (Exception e)
        {
            Report(e);
            return;
        }
        AnnounceStar(setId, cardId);
    }

    /// <summary>"Markiert" / "Markierung entfernt" for screen readers (Mac: AppModel+Actions toggleStar).</summary>
    public void AnnounceStar(string setId, string cardId)
    {
        if (Store.GetSet(setId)?.Cards.FirstOrDefault(c => c.Id == cardId) is { } card)
            DesignSystem.Announcer.Announce(card.Starred ? L("Markiert") : L("Markierung entfernt"));
    }

    VocabSpellChecker? _speller;

    /// <summary>Probable typos in cards (Windows spell checker; Mac: VocabSpellChecker.shared).</summary>
    public VocabSpellChecker Speller => _speller ??= new VocabSpellChecker(WindowsSpellEngine.TryCreate(), Preferences.IgnoredSpellings,
        list => Preferences.IgnoredSpellings = list.ToList());

    /// <summary>A long title shortened for toasts (Mac: shortTitle).</summary>
    public static string ShortTitle(string title) => title.Length > 40 ? title[..39].TrimEnd() + "…" : title;

    // MARK: Toasts

    /// <summary>Shows a toast; the oldest go when there are more than MaxToasts.</summary>
    public void ShowToast(ToastMessage toast)
    {
        // Only errors interrupt the screen reader (Mac: warnings are announced politely).
        DesignSystem.Announcer.Announce(toast.Text, important: toast.Tone is ToastTone.Danger);
        // The same message again (⇆ twice) replaced nothing and the two stood on top of each other over the cards
        // (Joan's phone, 06.11.2026): the older one goes.
        foreach (var same in Toasts.Where(t => t.Text == toast.Text).ToList()) DismissToast(same.Id);
        Toasts.Add(toast);
        ToastShown?.Invoke(toast);
        int max = AppDevice.IsPhone ? 2 : MaxToasts;
        while (Toasts.Count > max) DismissToast(Toasts[0].Id);
    }

    public void DismissToast(Guid id)
    {
        if (Toasts.RemoveAll(t => t.Id == id) == 0) return;
        ToastDismissed?.Invoke(id);
    }

    /// <summary>A text could not be read aloud: says why and where to get a voice (at most every 30 s per language).</summary>
    void ShowMissingVoice(Lang lang)
    {
        if (_missingVoiceShown.TryGetValue(lang, out var last) && DateTime.UtcNow - last < TimeSpan.FromSeconds(30)) return;
        _missingVoiceShown[lang] = DateTime.UtcNow;
        ShowToast(new ToastMessage(
            AppDevice.IsPhone
                ? L($"Keine Stimme für {Labels.LangName(lang)} installiert. Android-Einstellungen › Sprache › Sprachausgabe › Sprachdaten herunterladen.")
                : L($"Keine Stimme für {Labels.LangName(lang)} installiert. Windows-Einstellungen › Zeit und Sprache › Sprachausgabe › Stimmen hinzufügen."),
            ToastTone.Warning, DurationMs: 7000));
    }

    /// <summary>
    /// The first answer of a day keeps the Lernserie going (or starts it): a flame toast and a short fanfare, once per
    /// day, while studying (Mac: celebrateDailyStreak). A moment late, so it does not sound over the answer's chime.
    /// </summary>
    void CelebrateDailyStreak()
    {
        if (Route is not Route.Study) return;
        // Cheap checks first: this runs after every answer (no library snapshot here).
        var today = TimeUtil.DateKey(TimeUtil.NowMs(), Store.TimeZone);
        if (Preferences.CelebratedStreakDay == today) return;
        var activity = Store.GetActivity();
        if (activity.GetValueOrDefault(today) <= 0) return;
        var streak = Mastery.StudyStreakOf(activity.ToDictionary(p => p.Key, p => (double)p.Value), TimeUtil.NowMs());
        if (streak.Today <= 0 || streak.Current <= 0) return;
        Preferences.CelebratedStreakDay = today;
        var message = streak.Current == 1 ? L("Neue Lernserie gestartet – lerne morgen weiter!") : L($"Lernserie: {streak.Current} Tage in Folge!");
        DispatcherTimer.RunOnce(() =>
        {
            ShowToast(new ToastMessage(message, ToastTone.Streak));
            Sounds.Play(SoundEffects.Sound.DailyStreak);
        }, TimeSpan.FromMilliseconds(650));
    }
}
