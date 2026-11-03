using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LibraryStoreParityTests.swift: scenarios of store operations (results, events, changed
// parts after each step), backups, the text export and backup files, against db.js/backup.js.
public class LibraryStoreParityTests
{
    [Fact]
    public void Fixture() => ParityRunner.Run("store", c =>
    {
        switch (c.Fn)
        {
            case "scenario":
                return LibraryStoreScenario.Run(c.Arg(0));
            case "setToText":
                var cards = c.Arg(0)["cards"]?.ArrayValue?.Select(Card.FromJson).OfType<Card>().ToList() ?? [];
                var options = c.Arg(1);
                return Backup.SetToText(cards, options["termSep"]?.StringValue ?? "\t", options["cardSep"]?.StringValue ?? "\n");
            case "readJsonFile":
                try { return Backup.ReadJSON(Encoding.UTF8.GetBytes(c.Str(0))); }
                catch (BackupFileError e) { return JSONValue.Obj(("throws", e.Message)); }
            case "jsonText":
                return Backup.JsonText(c.Arg(0));
            case "webBackup":
                var at = c.Num(1);
                var store = new LibraryStore(new MemoryBackend(), now: () => at, timeZone: Fixtures.Zurich);
                store.ImportAll(c.Arg(0), ImportMode.Replace);
                return store.ExportAll().ToJson();
            default:
                return null;
        }
    }, maxReported: 15);
}

static class LibraryStoreScenario
{
    sealed class Clock { public double Now; }

    /// <summary>The JS test uid: mulberry32 bytes mixed with a clock stamp.</summary>
    sealed class JSUid(int seed, int counter, Clock clock)
    {
        const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
        readonly RNG _rng = Rand.Mulberry32(seed);
        int _counter = counter;

        public string Next()
        {
            var bytes = Enumerable.Range(0, 16).Select(_ => (byte)(int)(_rng() * 256)).ToArray();
            uint stamp = unchecked((uint)((long)clock.Now + _counter));
            _counter++;
            for (int i = 0; i < 6; i++) bytes[15 - i] ^= (byte)((stamp >> (i * 6)) & 63);
            return new string(bytes.Select(b => Alphabet[b & 63]).ToArray());
        }
    }

    public static JSONValue Run(JSONValue spec)
    {
        var clock = new Clock { Now = spec["clock0"]?.NumberValue ?? 0 };
        var uid = new JSUid(spec["seed"]?.IntegerValue ?? 0, spec["idCounter"]?.IntegerValue ?? 0, clock);
        var backend = new MemoryBackend(InitialDocument(spec["initial"] ?? JSONValue.Null));
        var events = new List<JSONValue>();
        LibraryStore Open()
        {
            var store = new LibraryStore(backend, now: () => clock.Now, timeZone: Fixtures.Zurich, makeID: uid.Next);
            store.Subscribe(change =>
            {
                var keys = change.Keys is { } ks
                    ? JSONValue.Array(ks.OrderBy(k => k, StringComparer.Ordinal).Select(JSONValue.String))
                    : JSONValue.Null;
                events.Add(JSONValue.Obj(("type", change.Kind == StoreChangeKind.Local ? "local" : "external"), ("keys", keys)));
            });
            return store;
        }
        var store = Open();
        var previous = new Dictionary<string, JSONValue>(StringComparer.Ordinal);
        JSONValue Delta(Dictionary<string, JSONValue> parts)
        {
            var changed = new JsonObjectMap();
            foreach (var (key, value) in parts)
            {
                if (previous.TryGetValue(key, out var old) && JSONValue.Identical(old, value)) continue;
                changed[key] = value;
                previous[key] = value;
            }
            return JSONValue.Object(changed);
        }
        var steps = new List<JSONValue> { JSONValue.Obj(("events", JSONValue.Array()), ("changed", Delta(Parts(store, spec["known0"])))) };
        foreach (var op in spec["ops"]?.ArrayValue ?? [])
        {
            clock.Now = op["clock"]?.NumberValue ?? clock.Now;
            events.Clear();
            var step = new JsonObjectMap();
            try
            {
                if (op["op"]?.StringValue == "reload")
                {
                    store.Save();
                    store = Open();
                }
                else if (Apply(op, store) is { } result) step["result"] = result;
            }
            catch (LibraryStoreError e)
            {
                step["error"] = JSONValue.Obj(("code", e.Code.Raw()), ("message", e.Message));
            }
            step["events"] = JSONValue.Array(events);
            step["changed"] = Delta(Parts(store, op["known"]));
            steps.Add(JSONValue.Object(step));
        }
        return JSONValue.Array(steps);
    }

    static byte[]? InitialDocument(JSONValue initial)
    {
        if (initial.ObjectValue is not { } keys) return null;
        var doc = new JsonObjectMap();
        var progress = new JsonObjectMap();
        var sessions = new JsonObjectMap();
        var learns = new JsonObjectMap();
        foreach (var (key, value) in keys)
        {
            switch (key)
            {
                case "sets" or "settings" or "activity": doc[key] = value; break;
                case "meta":
                    if (value["schemaVersion"] is { } v && v.NumberValue is not null) doc["schemaVersion"] = v;
                    break;
                default:
                    if (key.StartsWith("progress:", StringComparison.Ordinal)) progress[key[9..]] = value;
                    else if (key.StartsWith("session:", StringComparison.Ordinal)) sessions[key[8..]] = value;
                    else if (key.StartsWith("learn:", StringComparison.Ordinal)) learns[key[6..]] = value;
                    break;
            }
        }
        doc["progress"] = JSONValue.Object(progress);
        doc["sessions"] = JSONValue.Object(sessions);
        doc["learns"] = JSONValue.Object(learns);
        return Encoding.UTF8.GetBytes(JSONValue.Object(doc).ToJsonString());
    }

    static Dictionary<string, JSONValue> Parts(LibraryStore store, JSONValue? known)
    {
        var export = store.ExportAll().ToJson();
        var progress = new JsonObjectMap();
        var sessions = new JsonObjectMap();
        var learns = new JsonObjectMap();
        var options = new JsonObjectMap();
        foreach (var id in known?.ArrayValue?.Select(v => v.StringValue).OfType<string>() ?? [])
        {
            var p = store.GetProgress(id);
            if (p.Count > 0) progress[id] = Mastery.ProgressMapToJson(p);
            if (store.GetSessionJSON(id) is { } s) sessions[id] = s;
            if (store.GetLearnJSON(id) is { } l) learns[id] = l;
            options[id] = store.GetStudyOptions(id).ToJson();
        }
        return new Dictionary<string, JSONValue>(StringComparer.Ordinal)
        {
            ["head"] = JSONValue.Obj(("app", export["app"]), ("version", export["version"]), ("exportedAt", export["exportedAt"])),
            ["sets"] = export["sets"]!,
            ["exportProgress"] = export["progress"]!,
            ["settings"] = export["settings"]!,
            ["activity"] = export["activity"]!,
            ["progress"] = JSONValue.Object(progress),
            ["sessions"] = JSONValue.Object(sessions),
            ["learns"] = JSONValue.Object(learns),
            ["options"] = JSONValue.Object(options),
        };
    }

    static bool Truthy(JSONValue? v) => v?.Kind switch
    {
        null or JSONKind.Null => false,
        JSONKind.Bool => v.BoolValue!.Value,
        JSONKind.Number => v.NumberValue!.Value != 0 && !double.IsNaN(v.NumberValue!.Value),
        JSONKind.String => v.StringValue!.Length > 0,
        _ => true,
    };

    static JSONValue? Apply(JSONValue op, LibraryStore store)
    {
        var setId = op["setId"]?.StringValue ?? "";
        var cardId = op["cardId"]?.StringValue ?? "";
        switch (op["op"]?.StringValue)
        {
            case "createSet":
                var a = SetPatch.FromJson(op["args"] ?? JSONValue.Null);
                return store.CreateSet(a.Title ?? "", a.Description ?? "", a.TermLang ?? Lang.Fr, a.DefLang ?? Lang.De, a.Cards ?? []).ToJson();
            case "updateSet": return store.UpdateSet(setId, SetPatch.FromJson(op["patch"] ?? JSONValue.Null)).ToJson();
            case "deleteSet": return store.DeleteSet(setId);
            case "duplicateSet": return store.DuplicateSet(setId).ToJson();
            case "getSet": return store.GetSet(setId)?.ToJson() ?? JSONValue.Null;
            case "updateCard": return store.UpdateCard(setId, cardId, CardChanges.FromJson(op["changes"] ?? JSONValue.Null)).ToJson();
            case "toggleStar": return store.ToggleStar(setId, cardId);
            case "recordAnswer": return store.RecordAnswer(setId, cardId, Truthy(op["correct"]), op["at"]?.FiniteNumber).ToJson();
            case "overrideLastAnswer": return store.OverrideLastAnswer(setId, cardId).ToJson();
            case "resetProgress": store.ResetProgress(setId); return null;
            case "resetCardProgress":
                return store.ResetCardProgress(setId, op["cardIds"]?.ArrayValue?.Select(v => v.StringValue).OfType<string>() ?? []);
            case "saveSession": store.SaveSessionJSON(setId, op["state"]); return null;
            case "clearSession": store.ClearSession(setId); return null;
            case "saveLearn": store.SaveLearnJSON(setId, op["state"]); return null;
            case "clearLearn": store.ClearLearn(setId); return null;
            case "updateSettings": return store.UpdateSettings(SettingsPatch.FromJson(op["patch"] ?? JSONValue.Null)).ToJson();
            case "updateStudyOptions":
                return store.UpdateStudyOptions(setId, StudyOptionsPatch.FromJson(op["patch"] ?? JSONValue.Null) ?? new StudyOptionsPatch()).ToJson();
            case "importAll":
                return store.ImportAll(op["data"] ?? JSONValue.Null, op["mode"]?.StringValue == "replace" ? ImportMode.Replace : ImportMode.Merge).ToJson();
            case "snapshotSet": return store.SnapshotSet(setId)?.ToJson() ?? JSONValue.Null;
            case "restoreSet": return store.RestoreSet(op["snapshot"] ?? JSONValue.Null).ToJson();
            case "clearAll": store.ClearAll(); return null;
            default: throw new InvalidOperationException($"unknown op {op["op"]}");
        }
    }
}
