using Avalonia.Threading;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Settings of this app that are not part of the library (Mac: UserDefaults): "Wiederholungsfragen", the
/// flashcard decks and exam settings per set, the window size. Stored as preferences.json next to the library.
/// The theme and study options live in the library (LibraryStore.GetSettings), like on the Mac and the web.
/// </summary>
public sealed partial class AppPreferences
{
    const string TimesKey = "sync.times";

    readonly string? _path;
    JsonObjectMap _data;

    AppPreferences(string? path, JsonObjectMap data)
    {
        _path = path;
        _data = data;
    }

    public static AppPreferences InMemory() => new(null, new JsonObjectMap());

    public static AppPreferences Load(string path)
    {
        JsonObjectMap data = new();
        try
        {
            if (File.Exists(path) && JSONValue.TryParse(File.ReadAllText(path))?.ObjectValue is { } o) data = o;
        }
        catch (IOException) { }
        return new AppPreferences(path, data);
    }

    // MARK: Saving

    /// <summary>A burst of changes (a window of settings switched one after the other) is written once.</summary>
    static readonly TimeSpan SaveDelay = TimeSpan.FromMilliseconds(300);
    DispatcherTimer? _saveTimer;
    Task _writing = Task.CompletedTask;
    readonly Lock _fileLock = new(), _encodeLock = new();
    int _version, _writtenVersion;

    /// <summary>
    /// Writes the file shortly after a change, off the UI thread: every sorted flashcard stores its deck, and writing the
    /// whole file at once (temp file, move, the virus scanner looking at both) held up the card's departure. Off the UI
    /// thread (a value imported in the background) it writes at once, as always. <see cref="Flush"/> writes what waits.
    /// </summary>
    void Save()
    {
        if (_path is null) return;
        if (!Dispatcher.UIThread.CheckAccess())
        {
            var (now, nowVersion) = Encoded();
            WriteText(now, nowVersion);
            return;
        }
        _saveTimer ??= new DispatcherTimer(SaveDelay, DispatcherPriority.Background, (_, _) =>
        {
            _saveTimer?.Stop();
            // The text now (the values may change again meanwhile), the disk in the background, in order.
            var (text, version) = Encoded();
            var previous = _writing;
            _writing = Task.Run(async () =>
            {
                await previous;
                WriteText(text, version);
            });
        });
        if (!_saveTimer.IsEnabled) _saveTimer.Start();
    }

    /// <summary>
    /// Writes a change that still waits, now, and lets a write running in the background finish (the window closes,
    /// the phone app goes to the background: the app may end right after).
    /// </summary>
    public void Flush()
    {
        if (_saveTimer is { IsEnabled: true } timer)
        {
            timer.Stop();
            var (text, version) = Encoded();
            WriteText(text, version);
        }
        try { _writing.Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
    }

    /// <summary>The file's text and its version, taken together: a text taken later always has the higher version.</summary>
    (string Text, int Version) Encoded()
    {
        lock (_encodeLock) return (JSONValue.Object(_data).ToJsonString(indented: true), ++_version);
    }

    /// <summary>Writes <paramref name="text"/> unless a newer version is already on disk.</summary>
    void WriteText(string text, int version)
    {
        lock (_fileLock)
        {
            if (version <= _writtenVersion) return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path!)!);
                File.WriteAllText(_path + ".tmp", text);
                File.Move(_path + ".tmp", _path!, overwrite: true);
                _writtenVersion = version;
            }
            catch (IOException) { }
        }
    }

    /// <summary>Takes over preferences of the earlier app (first start), saved once.</summary>
    public void Import(JsonObjectMap values)
    {
        foreach (var (key, value) in values) _data[key] = value;
        Save();
    }

    JSONValue? Get(string key) => _data.TryGetValue(key, out var v) ? v : null;

    /// <summary>
    /// «Wiederholungsfragen» or «Nachkontrolle nach Fehlern» may have changed (set here or imported, then possibly on
    /// another thread): AppModel applies them to every stored Learn session (Mac: UserDefaults.didChangeNotification).
    /// </summary>
    public event Action? LearnSwitchesChanged;

    static bool IsLearnSwitch(string key) => key is "learn.review" or "learn.recheck";

    void Set(string key, JSONValue? value)
    {
        Write(key, value);
        if (IsLearnSwitch(key)) LearnSwitchesChanged?.Invoke();
    }

    void Write(string key, JSONValue? value)
    {
        if (value is null) _data.Remove(key);
        else _data[key] = value;
        Save();
    }


    /// <summary>
    /// Einstellungen › Allgemein › Sprache: «System», Deutsch or English (AppLanguage; this device only). The Mac keeps
    /// the same choice in macOS' own setting for the app (AppleLanguages).
    /// </summary>
    public AppLanguageChoice Language
    {
        get => Get("app.language")?.StringValue switch
        {
            "de" => AppLanguageChoice.De,
            "en" => AppLanguageChoice.En,
            _ => AppLanguageChoice.System,
        };
        set => Set("app.language", value == AppLanguageChoice.System ? null : JSONValue.String(value == AppLanguageChoice.En ? "en" : "de"));
    }

    /// <summary>"Wiederholungsfragen" (Learn options; the same for every set). Mac key: learn.review.</summary>
    public bool LearnReview
    {
        get => Get("learn.review")?.BoolValue ?? false;
        set => Set("learn.review", value);
    }

    /// <summary>"Nachkontrolle nach Fehlern" (Learn options; the same for every set; on by default). Mac key: learn.recheck.</summary>
    public bool LearnRecheck
    {
        get => Get("learn.recheck")?.BoolValue ?? true;
        set => Set("learn.recheck", value);
    }

    /// <summary>
    /// «Später» on «Neu starten?» for options changed since a session started (Core KeptOptions; mode "learn" or "write"):
    /// per set, on this device only, Windows only (issue #7, 24.11.2026).
    /// </summary>
    public KeptOptions? KeptOptionsOf(string mode, string setId) => KeptOptions.FromJson(Get($"keptOptions.{mode}.{setId}"));

    public void SaveKeptOptions(string mode, string setId, KeptOptions kept) => Set($"keptOptions.{mode}.{setId}", kept.ToJson());

    /// <summary>The intro hint of Lernen was closed (Mac key: learn.introHintDismissed).</summary>
    public bool LearnIntroHintDismissed
    {
        get => Get("learn.introHintDismissed")?.BoolValue ?? false;
        set => Set("learn.introHintDismissed", value);
    }

    public FlashcardDeck? Deck(string setId) => Get($"flashcards.{setId}") is { } j && FlashcardDeck.FromJson(j) is { IsConsistent: true } d ? d : null;

    public void SaveDeck(string setId, FlashcardDeck? deck) => Set($"flashcards.{setId}", deck?.ToJson());

    /// <summary>Which side of the flashcards is up first.</summary>
    public FlashcardFront FlashcardFront
    {
        get => EnumRaw.ParseJson<FlashcardFront>(Get("flashcards.front")) ?? FlashcardFront.Term;
        set => Set("flashcards.front", value.ToJson());
    }

    /// <summary>"Mischen" of the flashcards (the same for every set). Mac key: flashcards.shuffle.</summary>
    public bool FlashcardShuffle
    {
        get => Get("flashcards.shuffle")?.BoolValue ?? false;
        set => Set("flashcards.shuffle", value);
    }

    public ExamSettings ExamSettings(string setId) => Get($"exam.{setId}") is { } j ? Core.ExamSettings.FromJson(j) : Core.ExamSettings.Default;

    public void SaveExamSettings(string setId, ExamSettings settings) => Set($"exam.{setId}", settings.ToJson());

    /// <summary>Einstellungen › Allgemein › "Soundeffekte" (on by default). Mac key: soundEffects.</summary>
    public bool SoundEffects
    {
        get => Get("soundEffects")?.BoolValue ?? true;
        set => Set("soundEffects", value);
    }

    /// <summary>
    /// Einstellungen › Allgemein › "Weitere Synonyme erkennen" (on by default): written answers may also be a synonym
    /// of the expected one from the built-in thesauri (Core/SynonymLexicon). Mac key: extendedSynonyms (there with
    /// Apple Intelligence).
    /// </summary>
    public bool ExtendedSynonyms
    {
        get => Get("extendedSynonyms")?.BoolValue ?? true;
        set => Set("extendedSynonyms", value);
    }

    /// <summary>
    /// "Synonyme ausserhalb des Sets erlauben" in a set's options (Toleranz): false = no synonyms outside this set, on
    /// this device; synonym cards of the set count either way. Like SetSoundEffects not a study option, so "Auf Standard
    /// zurücksetzen" leaves it. Not stored while on. Mac key: extendedSynonyms.&lt;setId&gt; (since 18.11.2026).
    /// </summary>
    public bool SetExtendedSynonyms(string setId) => Get($"extendedSynonyms.{setId}")?.BoolValue ?? true;

    public void SaveSetExtendedSynonyms(string setId, bool on) => Set($"extendedSynonyms.{setId}", on ? null : (JSONValue)false);

    /// <summary>Whether synonyms outside the set count for <paramref name="setId"/>: the setting and the set's own switch (null: no set).</summary>
    public bool ExtendedSynonymsFor(string? setId) => ExtendedSynonyms && (setId is null || SetExtendedSynonyms(setId));

    /// <summary>
    /// "Soundeffekte" in a set's options: false mutes this set's sounds on this device (say while listening to music);
    /// the switch in Einstellungen still mutes every set. Not stored while on (the usual case). Mac key: soundEffects.&lt;setId&gt;.
    /// </summary>
    public bool SetSoundEffects(string setId) => Get($"soundEffects.{setId}")?.BoolValue ?? true;

    public void SaveSetSoundEffects(string setId, bool on) => Set($"soundEffects.{setId}", on ? null : (JSONValue)false);

    /// <summary>Whether sounds play while <paramref name="setId"/> is on screen (null: no set).</summary>
    public bool SoundEffectsFor(string? setId) => SoundEffects && (setId is null || SetSoundEffects(setId));

    /// <summary>How the overview orders its set cards: recent, name or newest. Mac key: overview.sort.</summary>
    public string OverviewSort
    {
        get => Get("overview.sort")?.StringValue ?? "recent";
        set => Set("overview.sort", value);
    }

    /// <summary>The term filter of a set page (Mac: rememberTermFilter).</summary>
    public string TermFilter(string setId) => Get($"termFilter.{setId}")?.StringValue ?? "all";

    public void SaveTermFilter(string setId, string filter) => Set($"termFilter.{setId}", filter == "all" ? null : (JSONValue)filter);

    /// <summary>Words the spell checker no longer reports ("fr:kevinou"; Mac key: spellcheck.ignoredWords).</summary>
    public IReadOnlyList<string> IgnoredSpellings
    {
        get => Get("spellcheck.ignoredWords")?.ArrayValue?.Select(v => v.StringValue).OfType<string>().ToList() ?? [];
        set => Set("spellcheck.ignoredWords", value.Count == 0 ? null : JSONValue.Array(value.Select(w => (JSONValue)w)));
    }

    /// <summary>The voice chosen per language in Einstellungen › Allgemein ("fr" → SAPI token id). Mac key: speechVoices.</summary>
    public IReadOnlyDictionary<Lang, string> SpeechVoices
    {
        get
        {
            var result = new Dictionary<Lang, string>();
            if (Get("speechVoices")?.ObjectValue is { } map)
                foreach (var (key, value) in map)
                    if (EnumRaw.Parse<Lang>(key) is { } lang && value.StringValue is { Length: > 0 } id) result[lang] = id;
            return result;
        }
        set
        {
            var map = new JsonObjectMap();
            foreach (var (lang, id) in value) map[lang.Raw()] = id;
            Set("speechVoices", map.Count == 0 ? null : JSONValue.Object(map));
        }
    }

    /// <summary>The open tab of the settings (Mac key: settings.selectedTab).</summary>
    public int SettingsTab
    {
        get => (int)(Get("settings.selectedTab")?.FiniteNumber ?? 0);
        set => Set("settings.selectedTab", value == 0 ? null : (JSONValue)value);
    }

    /// <summary>The earlier WebView app still has to be removed after the takeover (see EarlierApp).</summary>
    public bool EarlierAppRemovePending
    {
        get => Get(EarlierApp.PendingKey)?.BoolValue ?? false;
        set => Set(EarlierApp.PendingKey, value ? JSONValue.True : null);
    }

    /// <summary>The day whose first answer was already celebrated ("Lernserie: 3 Tage in Folge!").</summary>
    public string? CelebratedStreakDay
    {
        get => Get("celebratedStreakDay")?.StringValue;
        set => Set("celebratedStreakDay", value is null ? null : (JSONValue)value);
    }
}
