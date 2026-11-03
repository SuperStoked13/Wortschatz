using Avalonia.Threading;
using Wortschatz.App.Services;
using Wortschatz.Core;

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
    public sealed record Editor(string? SetId, bool StartWithImport = false, bool OpenFile = false) : Route;
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
}

/// <summary>A button of a prompt. Default: Enter; Cancel: Esc and a click outside.</summary>
public sealed record PromptButton(string Label, Action? Action = null, bool IsDefault = false, bool IsCancel = false, bool IsDestructive = false);

/// <summary>A question over the window (Mac: alert / confirmationDialog).</summary>
public sealed record PromptRequest(string Title, string Message, IReadOnlyList<PromptButton> Buttons)
{
    /// <summary>A yes/no question: the confirm button (destructive: red) and "Abbrechen".</summary>
    public static PromptRequest Confirm(string title, string message, string confirmLabel, Action onConfirm, bool destructive = false) =>
        new(title, message, [new PromptButton(confirmLabel, onConfirm, IsDefault: !destructive, IsDestructive: destructive), new PromptButton("Abbrechen", IsCancel: true, IsDefault: destructive)]);
}

public sealed class AppModel
{
    public LibraryStore Store { get; }
    public SpeechService Speech { get; }
    public SoundEffects Sounds { get; }
    public AppPreferences Preferences { get; }
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
        Speech = speech ?? SpeechService.Create();
        Sounds = new SoundEffects(() => Preferences.SoundEffects);
        Speech.MissingVoice += lang => Dispatcher.UIThread.Post(() => ShowMissingVoice(lang));
        Store.Subscribe(change =>
        {
            _library = null;
            if (change.Kind == StoreChangeKind.Local) SaveSoon();
            Changed?.Invoke();
            CelebrateDailyStreak();
        });
    }

    // MARK: Saving

    DispatcherTimer? _saveTimer;
    Task _writing = Task.CompletedTask;

    /// <summary>
    /// Saves the library a moment after the last change (Mac: scheduleSave): a burst of changes (an answer records the
    /// answer and the session) is written once, and the file is written off the UI thread, so answering never waits for
    /// the disk. <see cref="Flush"/> writes at once (closing the window).
    /// </summary>
    public void SaveSoon()
    {
        if (Store.Backend is MemoryBackend) return;
        _saveTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(400), DispatcherPriority.Background, (_, _) =>
        {
            _saveTimer?.Stop();
            SaveInBackground();
        });
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    void SaveInBackground()
    {
        (byte[] Data, int Revision)? pending;
        try { pending = Store.EncodePending(); }
        catch (LibraryStoreError e)
        {
            ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 7000));
            return;
        }
        if (pending is not { } p) return;
        var previous = _writing;
        _writing = Task.Run(async () =>
        {
            await previous;
            try { Store.WriteEncoded(p.Data, p.Revision); }
            catch (LibraryStoreError e)
            {
                Dispatcher.UIThread.Post(() => ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 7000)));
            }
        });
    }

    /// <summary>Writes everything now (the window closes).</summary>
    public void Flush()
    {
        _saveTimer?.Stop();
        try { _writing.Wait(TimeSpan.FromSeconds(5)); }
        catch (AggregateException) { }
        try { Store.Save(); }
        catch (LibraryStoreError) { }
    }

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
        var path = string.IsNullOrWhiteSpace(folder) ? FileBackend.DefaultPath() : Path.Combine(folder, "library.json");
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
        if (takeover is not null)
        {
            int n = store.ListSets().Count;
            model.ShowToast(new ToastMessage(
                n == 1 ? "1 Lernset aus der bisherigen Windows-App übernommen." : $"{n} Lernsets aus der bisherigen Windows-App übernommen.",
                ToastTone.Success, DurationMs: 7000));
        }
        else if (failure is not null)
        {
            model.ShowToast(new ToastMessage("Die Lernsets der bisherigen Windows-App konnten nicht übernommen werden: " + failure,
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
        return model;
    }

    /// <summary>Where the library file lives (Einstellungen › Speicherort).</summary>
    public string DataPath => Store.Backend is FileBackend f ? f.Path : "Nur im Arbeitsspeicher";

    // MARK: Library

    /// <summary>The library's view data, rebuilt once after each store change (Mac: AppModel.library).</summary>
    public LibrarySnapshot Library => _library ??= LibrarySnapshot.Build(Store);

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

    /// <summary>Answers given today (the overview's "Heute beantwortet").</summary>
    public int AnsweredToday => Library.Stats.Streak.Today;

    /// <summary>The set the window is about (the set page, a study screen or the editor of a set).</summary>
    public string? CurrentSetId => Route.RouteSetId is { } id && Store.GetSet(id) is not null ? id : null;

    // MARK: Navigation

    public void Navigate(Route route)
    {
        if (route == Route) return;
        ClosePrompt();
        Route = route;
        RouteChanged?.Invoke();
    }

    public void ShowOverview() => Navigate(new Route.Overview());

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
        ClosePrompt();
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
        Store.Save();
        return set;
    }

    /// <summary>"Duplizieren": the copy with a toast that opens it (Mac: duplicateSet).</summary>
    public void DuplicateSet(string setId)
    {
        if (Store.GetSet(setId) is not { } set) return;
        try
        {
            var copy = Store.DuplicateSet(setId);
            Store.Save();
            ShowToast(new ToastMessage($"Kopie von «{ShortTitle(set.Title)}» erstellt", ToastTone.Success, "Öffnen", () => OpenSet(copy.Id)));
        }
        catch (LibraryStoreError e)
        {
            ShowToast(new ToastMessage(e.Message, ToastTone.Danger, DurationMs: 6000));
        }
    }

    /// <summary>"Fortschritt zurücksetzen…" with a question first (Mac: confirmResetProgress).</summary>
    public void ConfirmResetProgress(string setId)
    {
        if (Store.GetSet(setId) is null) return;
        Ask(PromptRequest.Confirm("Fortschritt zurücksetzen?",
            "Alle Begriffe gelten danach wieder als «Neu», und laufende Runden in Lernen und Schreiben werden beendet. Die Begriffe selbst bleiben erhalten.",
            "Zurücksetzen", () =>
            {
                Store.ResetProgress(setId);
                Preferences.SaveDeck(setId, null);
                Store.Save();
                ShowToast(new ToastMessage("Fortschritt zurückgesetzt", ToastTone.Success));
            }, destructive: true));
    }

    /// <summary>Deletes a set; the toast offers "Rückgängig" (Mac: deleteSet with the snapshot).</summary>
    public void DeleteSet(string setId)
    {
        var snapshot = Store.SnapshotSet(setId);
        if (snapshot is null) return;
        var title = ShortTitle(Store.GetSet(setId)?.Title ?? "Lernset");
        Store.DeleteSet(setId);
        Store.Save();
        if (Route.RouteSetId == setId) ShowOverview();
        ShowToast(new ToastMessage($"«{title}» gelöscht", ActionLabel: "Rückgängig", Action: () =>
        {
            Store.RestoreSet(snapshot);
            Store.Save();
            OpenSet(setId);
        }, DurationMs: 7000));
    }

    /// <summary>The ★ toggle of a card.</summary>
    public void ToggleStar(string setId, string cardId)
    {
        Store.ToggleStar(setId, cardId);
        Store.Save();
    }

    /// <summary>A long title shortened for toasts (Mac: shortTitle).</summary>
    public static string ShortTitle(string title) => title.Length > 40 ? title[..39].TrimEnd() + "…" : title;

    // MARK: Toasts

    /// <summary>Shows a toast; the oldest go when there are more than MaxToasts.</summary>
    public void ShowToast(ToastMessage toast)
    {
        Toasts.Add(toast);
        ToastShown?.Invoke(toast);
        while (Toasts.Count > MaxToasts) DismissToast(Toasts[0].Id);
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
            $"Keine Stimme für {Labels.LangName(lang)} installiert. Windows-Einstellungen › Zeit und Sprache › Sprachausgabe › Stimmen hinzufügen.",
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
        var message = streak.Current == 1 ? "Neue Lernserie gestartet – lerne morgen weiter!" : $"Lernserie: {streak.Current} Tage in Folge!";
        DispatcherTimer.RunOnce(() =>
        {
            ShowToast(new ToastMessage(message, ToastTone.Streak));
            Sounds.Play(SoundEffects.Sound.DailyStreak);
        }, TimeSpan.FromMilliseconds(650));
    }
}
