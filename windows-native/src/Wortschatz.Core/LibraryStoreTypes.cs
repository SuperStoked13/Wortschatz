using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of LibraryStoreTypes.swift: value types of the library store (src/store/db.js).

public enum LibraryStoreErrorCode
{
    [Raw("QUOTA")] Quota,
    [Raw("NOT_FOUND")] NotFound,
    [Raw("INVALID")] Invalid,
    [Raw("INVALID_BACKUP")] InvalidBackup,
    [Raw("IO")] Io,
}

public sealed class LibraryStoreError(LibraryStoreErrorCode code, string message) : Exception(message)
{
    public LibraryStoreErrorCode Code { get; } = code;
    public override string ToString() => $"{Code.Raw()}: {Message}";
}

/// <summary>Messages of db.js (<c>MSG</c>), plus the file errors: German (Swiss spelling, no sharp s), in the app's language through L.</summary>
public static class StoreMessages
{
    public static string Quota => L("Der Speicher dieses Browsers ist voll. Exportiere ein Backup und lösche Lernsets, die du nicht mehr brauchst.");
    public static string SetNotFound => L("Dieses Lernset wurde nicht gefunden.");
    public static string CardNotFound => L("Diese Karte wurde nicht gefunden.");
    public static string EmptyCard => L("Begriff und Definition dürfen nicht beide leer sein.");
    public static string NotBackup => L("Diese Datei ist kein Wortschatz-Backup.");
    public static string NewerBackup => L("Dieses Backup stammt aus einer neueren Version von Wortschatz und kann nicht importiert werden.");
    public static string NoSets => L("Das Backup ist unvollständig: Die Lernsets fehlen.");
    public static string BadSet(int n) => L($"Das Backup ist beschädigt: Lernset Nr. {n} ist ungültig.");
    public static string BadPart(string name) => L($"Das Backup ist beschädigt: Der Bereich «{name}» ist ungültig.");
    public static string BadSnapshot => L("Dieses Lernset kann nicht wiederhergestellt werden.");
    public static string Io => L("Die Daten konnten nicht gespeichert werden.");
    /// <summary>Windows wording of the Mac's "kein Speicherplatz mehr frei".</summary>
    public static string DiskFull => L("Die Daten konnten nicht gespeichert werden, weil auf diesem Computer kein Speicherplatz mehr frei ist.");
    public static string BadState => L("Der Lernstand konnte nicht gespeichert werden.");
}

/// <summary>A card as input (id may be missing; starred null = keep).</summary>
public sealed record CardDraft(string? Id, string Term, string Definition, bool? Starred = null)
{
    public CardDraft(string term, string definition) : this(null, term, definition) { }

    public static CardDraft FromCard(Card c) => new(c.Id, c.Term, c.Definition, c.Starred);

    public static CardDraft? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null) return null;
        return new CardDraft(json["id"]?.StringValue, JSLoose.Text(json["term"]), JSLoose.Text(json["definition"]), json["starred"]?.BoolValue);
    }
}

public sealed record SetPatch(
    string? Title = null, string? Description = null, Lang? TermLang = null, Lang? DefLang = null,
    StudyOptionsPatch? StudyOptions = null, IReadOnlyList<CardDraft>? Cards = null)
{
    public static SetPatch FromJson(JSONValue json) => new(
        json["title"] is { } t ? JSLoose.Text(t) : null,
        json["description"] is { } d ? JSLoose.Text(d) : null,
        EnumRaw.ParseJson<Lang>(json["termLang"]),
        EnumRaw.ParseJson<Lang>(json["defLang"]),
        json["studyOptions"] is { } so ? StudyOptionsPatch.FromJson(so) ?? new StudyOptionsPatch() : null,
        json["cards"]?.ArrayValue?.Select(CardDraft.FromJson).OfType<CardDraft>().ToList());
}

public sealed record CardChanges(string? Term = null, string? Definition = null, bool? Starred = null)
{
    public static CardChanges FromJson(JSONValue json) => new(
        json["term"] is { } t ? JSLoose.Text(t) : null,
        json["definition"] is { } d ? JSLoose.Text(d) : null,
        json["starred"]?.BoolValue);
}

public enum ImportMode { Merge, Replace }

public sealed record ImportSummary(int SetsAdded, int SetsUpdated) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("setsAdded", SetsAdded), ("setsUpdated", SetsUpdated));
}

/// <summary>The backup file (<c>exportAll</c>): identical to the web and Mac apps' backups.</summary>
public sealed record BackupDocument(
    double ExportedAt, IReadOnlyList<VocabSet> Sets, IReadOnlyDictionary<string, Dictionary<string, CardProgress>> Progress,
    Settings Settings, IReadOnlyDictionary<string, int> Activity, string App = "wortschatz", int Version = LibraryStore.SCHEMA_VERSION) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(
        ("app", App), ("version", Version), ("exportedAt", ExportedAt), ("sets", Sets.ToJsonArray()),
        ("progress", JSONValue.Object(Progress.Select(p => new KeyValuePair<string, JSONValue>(p.Key, Mastery.ProgressMapToJson(p.Value))))),
        ("settings", Settings.ToJson()), ("activity", ActivityJson.ToJson(Activity)));
}

/// <summary>A set with everything belonging to it (for "Rückgängig" after deleting).</summary>
public sealed record SetSnapshot(VocabSet Set, Dictionary<string, CardProgress> Progress, JSONValue? Session = null, JSONValue? Learn = null) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("set", Set.ToJson()), ("progress", Mastery.ProgressMapToJson(Progress)),
        ("session", Session ?? JSONValue.Null), ("learn", Learn ?? JSONValue.Null));
}

public enum StoreChangeKind { Local, External }

/// <summary>A change notification: the storage keys that changed (null = everything).</summary>
public sealed record StoreChange(StoreChangeKind Kind, IReadOnlyList<string>? Keys);

public enum LoadRecoveryKind { None, FromBackup, Reset }

public sealed record LoadRecovery(LoadRecoveryKind Kind, int Index = 0)
{
    public static readonly LoadRecovery None = new(LoadRecoveryKind.None);
    public static readonly LoadRecovery Reset = new(LoadRecoveryKind.Reset);
}

/// <summary>The stored library document (one JSON file).</summary>
public sealed class LibraryDocument : IJsonEncodable
{
    public int SchemaVersion;
    public List<VocabSet> Sets = [];
    public Dictionary<string, Dictionary<string, CardProgress>> Progress = new(StringComparer.Ordinal);
    public Dictionary<string, JSONValue> Sessions = new(StringComparer.Ordinal);
    public Dictionary<string, JSONValue> Learns = new(StringComparer.Ordinal);
    public Settings Settings = Settings.Default;
    public Dictionary<string, int> Activity = new(StringComparer.Ordinal);

    /// <summary>A deep enough copy for rollbacks (records and JSON values are immutable).</summary>
    public LibraryDocument Clone() => new()
    {
        SchemaVersion = SchemaVersion,
        Sets = new List<VocabSet>(Sets),
        Progress = Progress.ToDictionary(p => p.Key, p => new Dictionary<string, CardProgress>(p.Value, StringComparer.Ordinal), StringComparer.Ordinal),
        Sessions = new Dictionary<string, JSONValue>(Sessions, StringComparer.Ordinal),
        Learns = new Dictionary<string, JSONValue>(Learns, StringComparer.Ordinal),
        Settings = Settings,
        Activity = new Dictionary<string, int>(Activity, StringComparer.Ordinal),
    };

    /// <summary>
    /// The library file's bytes: ToJson() with sorted keys, written straight to the writer. Cards and progress records
    /// are immutable, so each one's JSON is encoded once and copied into every later save (only what an answer changed
    /// is encoded again): the whole library is saved after every answer, and building its JSON tree each time made most
    /// of the ~12 MB of garbage per answer (Joan's 1705 cards, 26.11.2026). The same bytes as ToJson().ToJsonBytes(sortedKeys: true).
    /// </summary>
    internal byte[] ToFileBytes()
    {
        using var buffer = new PooledByteBuffer();
        using (var w = new System.Text.Json.Utf8JsonWriter(buffer, JSONValue.WriterOptions))
        {
            w.WriteStartObject();
            w.WritePropertyName("activity");
            ActivityJson.ToJson(Activity).Write(w, sortedKeys: true);
            w.WritePropertyName("learns");
            WriteSorted(w, Learns, (w, v) => v.Write(w, sortedKeys: true));
            w.WritePropertyName("progress");
            WriteSorted(w, Progress, (w, map) => WriteSorted(w, map, (w, p) => w.WriteRawValue(Encoded.Of(p), skipInputValidation: true)));
            w.WritePropertyName("schemaVersion");
            JSONValue.Number(SchemaVersion).Write(w, sortedKeys: true);
            w.WritePropertyName("sessions");
            WriteSorted(w, Sessions, (w, v) => v.Write(w, sortedKeys: true));
            w.WritePropertyName("sets");
            w.WriteStartArray();
            foreach (var set in Sets) WriteSet(w, set);
            w.WriteEndArray();
            w.WritePropertyName("settings");
            Settings.ToJson().Write(w, sortedKeys: true);
            w.WriteEndObject();
        }
        return buffer.ToArray();
    }

    /// <summary>A set like set.ToJson() with sorted keys, its cards from their remembered JSON.</summary>
    static void WriteSet(System.Text.Json.Utf8JsonWriter w, VocabSet set)
    {
        var fields = set.ToJson(cards: JSONValue.Null).ObjectValue!;
        var keys = SortedKeys.Rent(fields.Keys);
        try
        {
            w.WriteStartObject();
            foreach (var k in keys.Span)
            {
                w.WritePropertyName(k);
                if (k != "cards") fields[k].Write(w, sortedKeys: true);
                else
                {
                    w.WriteStartArray();
                    foreach (var card in set.Cards) w.WriteRawValue(Encoded.Of(card), skipInputValidation: true);
                    w.WriteEndArray();
                }
            }
            w.WriteEndObject();
        }
        finally { SortedKeys.Return(keys); }
    }

    static void WriteSorted<T>(System.Text.Json.Utf8JsonWriter w, Dictionary<string, T> map, Action<System.Text.Json.Utf8JsonWriter, T> value)
    {
        var keys = SortedKeys.Rent(map.Keys);
        try
        {
            w.WriteStartObject();
            foreach (var k in keys.Span)
            {
                w.WritePropertyName(k);
                value(w, map[k]);
            }
            w.WriteEndObject();
        }
        finally { SortedKeys.Return(keys); }
    }

    /// <summary>The JSON of immutable records (sorted keys), encoded once per instance and forgotten with it.</summary>
    static class Encoded
    {
        static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Card, byte[]> Cards = new();
        static readonly System.Runtime.CompilerServices.ConditionalWeakTable<CardProgress, byte[]> Progress = new();

        public static byte[] Of(Card card) => Cards.GetValue(card, static c => c.ToJson().ToJsonBytes(sortedKeys: true));
        public static byte[] Of(CardProgress progress) => Progress.GetValue(progress, static p => p.ToJson().ToJsonBytes(sortedKeys: true));
    }

    public JSONValue ToJson() => JSONValue.Obj(
        ("activity", ActivityJson.ToJson(Activity)),
        ("learns", JSONValue.Object(Learns.OrderBy(p => p.Key, StringComparer.Ordinal))),
        ("progress", JSONValue.Object(Progress.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => new KeyValuePair<string, JSONValue>(p.Key, Mastery.ProgressMapToJson(p.Value))))),
        ("schemaVersion", SchemaVersion),
        ("sessions", JSONValue.Object(Sessions.OrderBy(p => p.Key, StringComparer.Ordinal))),
        ("sets", Sets.ToJsonArray()),
        ("settings", Settings.ToJson()));
}

public static class ActivityJson
{
    public static JSONValue ToJson(IReadOnlyDictionary<string, int> activity) =>
        JSONValue.Object(activity.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => new KeyValuePair<string, JSONValue>(p.Key, p.Value)));
}
