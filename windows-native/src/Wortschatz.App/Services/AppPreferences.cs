using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Settings of this app that are not part of the library (Mac: UserDefaults): "Wiederholungsfragen", the
/// flashcard decks and exam settings per set, the window size. Stored as preferences.json next to the library.
/// The theme and study options live in the library (LibraryStore.GetSettings), like on the Mac and the web.
/// </summary>
public sealed class AppPreferences
{
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

    void Save()
    {
        if (_path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path + ".tmp", JSONValue.Object(_data).ToJsonString(indented: true));
            File.Move(_path + ".tmp", _path, overwrite: true);
        }
        catch (IOException) { }
    }

    /// <summary>Takes over preferences of the earlier app (first start), saved once.</summary>
    public void Import(JsonObjectMap values)
    {
        foreach (var (key, value) in values) _data[key] = value;
        Save();
    }

    JSONValue? Get(string key) => _data.TryGetValue(key, out var v) ? v : null;

    void Set(string key, JSONValue? value)
    {
        if (value is null) _data.Remove(key);
        else _data[key] = value;
        Save();
    }

    /// <summary>"Wiederholungsfragen" (Learn options; the same for every set). Mac key: learn.review.</summary>
    public bool LearnReview
    {
        get => Get("learn.review")?.BoolValue ?? false;
        set => Set("learn.review", value);
    }

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

    /// <summary>How the overview orders its set cards: recent, name or newest. Mac key: overview.sort.</summary>
    public string OverviewSort
    {
        get => Get("overview.sort")?.StringValue ?? "recent";
        set => Set("overview.sort", value);
    }

    /// <summary>The term filter of a set page (Mac: rememberTermFilter).</summary>
    public string TermFilter(string setId) => Get($"termFilter.{setId}")?.StringValue ?? "all";

    public void SaveTermFilter(string setId, string filter) => Set($"termFilter.{setId}", filter == "all" ? null : (JSONValue)filter);

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
