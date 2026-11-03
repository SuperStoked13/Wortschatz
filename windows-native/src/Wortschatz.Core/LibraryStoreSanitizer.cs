using System.Text;

namespace Wortschatz.Core;

// Port of LibraryStoreSanitizer.swift: the stored-data sanitisers of src/store/db.js. Corrupt or
// foreign data never crashes the app; everything works on JSONValue with the JS semantics.

internal static class JSLoose
{
    /// <summary>JS <c>String(v)</c>.</summary>
    public static string String(JSONValue v) => v.Kind switch
    {
        JSONKind.Null => "null",
        JSONKind.Bool => v.BoolValue!.Value ? "true" : "false",
        JSONKind.Number => JSCompat.NumberToString(v.NumberValue!.Value),
        JSONKind.String => v.StringValue!,
        JSONKind.Array => string.Join(",", v.ArrayValue!.Select(x => x.IsNull ? "" : String(x))),
        _ => "[object Object]",
    };

    /// <summary><c>v == null ? '' : String(v)</c></summary>
    public static string Text(JSONValue? v) => v is null || v.IsNull ? "" : String(v);

    /// <summary>CR and CRLF → LF, then JS trim.</summary>
    public static string CleanText(string s)
    {
        var sb = new StringBuilder(s.Length);
        bool afterCR = false;
        foreach (char c in s)
        {
            if (c == '\r') { sb.Append('\n'); afterCR = true; continue; }
            if (c == '\n' && afterCR) { afterCR = false; continue; }
            afterCR = false;
            sb.Append(c);
        }
        return JSCompat.Trim(sb.ToString());
    }

    public static bool Truthy(JSONValue? v) => v?.Kind switch
    {
        null or JSONKind.Null => false,
        JSONKind.Bool => v.BoolValue!.Value,
        JSONKind.Number => v.NumberValue!.Value != 0 && !double.IsNaN(v.NumberValue!.Value),
        JSONKind.String => v.StringValue!.Length > 0,
        _ => true,
    };
}

internal static class StoreSanitizer
{
    public static List<Card> BuildCards(IEnumerable<CardDraft> input, bool keepIds, IReadOnlyDictionary<string, Card>? previousById, Func<string> makeID)
    {
        var output = new List<Card>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in input)
        {
            var term = JSLoose.CleanText(raw.Term);
            var definition = JSLoose.CleanText(raw.Definition);
            if (term.Length == 0 && definition.Length == 0) continue;
            string cardId;
            if (keepIds && raw.Id is { Length: > 0 } candidate && !seen.Contains(candidate)) cardId = candidate;
            else
            {
                do cardId = makeID(); while (cardId.Length == 0 || seen.Contains(cardId));
            }
            seen.Add(cardId);
            Card? prev = null;
            previousById?.TryGetValue(cardId, out prev);
            bool starred = raw.Starred ?? prev?.Starred ?? false;
            output.Add(new Card(cardId, term, definition, starred));
        }
        return output;
    }

    public static List<Card> BuildCards(JSONValue? input, bool keepIds, Func<string> makeID) =>
        BuildCards(input?.ArrayValue?.Select(CardDraft.FromJson).OfType<CardDraft>() ?? [], keepIds, null, makeID);

    public static VocabSet? SanitizeSet(JSONValue raw, double fallbackNow, Func<string> makeID)
    {
        if (raw.ObjectValue is null || raw["id"]?.StringValue is not { Length: > 0 } id) return null;
        var createdAt = raw["createdAt"]?.FiniteNumber ?? fallbackNow;
        var studyOptions = raw["studyOptions"] is { } so ? StudyOptionsPatch.FromJson(so) : null;
        var title = JSLoose.CleanText(JSLoose.Text(raw["title"]));
        return new VocabSet
        {
            Id = id,
            Title = title.Length == 0 ? LibraryStore.DEFAULT_TITLE : title,
            Description = JSLoose.CleanText(JSLoose.Text(raw["description"])),
            TermLang = EnumRaw.ParseJson<Lang>(raw["termLang"]) ?? Lang.Fr,
            DefLang = EnumRaw.ParseJson<Lang>(raw["defLang"]) ?? Lang.De,
            Cards = BuildCards(raw["cards"], true, makeID),
            StudyOptions = studyOptions is null || studyOptions.IsEmpty ? null : studyOptions,
            CreatedAt = createdAt,
            UpdatedAt = raw["updatedAt"]?.FiniteNumber ?? createdAt,
            LastStudiedAt = raw["lastStudiedAt"]?.FiniteNumber,
        };
    }

    public static List<VocabSet> ReadSets(JSONValue? raw, double fallbackNow, Func<string> makeID)
    {
        var output = new List<VocabSet>();
        if (raw?.ArrayValue is not { } list) return output;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in list)
            if (SanitizeSet(entry, fallbackNow, makeID) is { } s && ids.Add(s.Id)) output.Add(s);
        return output;
    }

    public static Dictionary<string, CardProgress> SanitizeProgressMap(JSONValue? raw, ISet<string>? validIds = null)
    {
        var output = new Dictionary<string, CardProgress>(StringComparer.Ordinal);
        if (raw?.ObjectValue is not { } o) return output;
        foreach (var (id, value) in o)
        {
            if (validIds is not null && !validIds.Contains(id)) continue;
            if (CardProgress.FromJson(value) is { } p) output[id] = p;
        }
        return output;
    }

    public static Dictionary<string, int> SanitizeActivity(JSONValue? raw)
    {
        var output = new Dictionary<string, int>(StringComparer.Ordinal);
        if (raw?.ObjectValue is not { } o) return output;
        foreach (var (key, value) in o)
            if (IsDateKey(key) && value.FiniteNumber is { } n && n > 0) output[key] = (int)Math.Floor(Math.Min(n, int.MaxValue));
        return output;
    }

    public static bool IsDateKey(string key)
    {
        if (key.Length != 10) return false;
        for (int i = 0; i < 10; i++)
        {
            if (i is 4 or 7) { if (key[i] != '-') return false; }
            else if (key[i] < '0' || key[i] > '9') return false;
        }
        return true;
    }

    public static LibraryDocument Document(JSONValue json, double fallbackNow, Func<string> makeID)
    {
        var doc = new LibraryDocument
        {
            SchemaVersion = json["schemaVersion"]?.IntegerValue ?? 0,
            Sets = ReadSets(json["sets"], fallbackNow, makeID),
        };
        foreach (var (id, value) in json["progress"]?.ObjectValue ?? new JsonObjectMap()) doc.Progress[id] = SanitizeProgressMap(value);
        foreach (var (id, value) in json["sessions"]?.ObjectValue ?? new JsonObjectMap()) doc.Sessions[id] = value;
        foreach (var (id, value) in json["learns"]?.ObjectValue ?? new JsonObjectMap()) doc.Learns[id] = value;
        doc.Settings = Settings.FromJson(json["settings"] ?? JSONValue.Null);
        doc.Activity = SanitizeActivity(json["activity"]);
        return doc;
    }
}
