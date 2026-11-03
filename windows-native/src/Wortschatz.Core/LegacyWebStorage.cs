using System.Buffers.Binary;
using System.Text;

namespace Wortschatz.Core;

// Takes over everything of the earlier Windows app (windows/ + Website/, a WebView2 window) on the first start. That app
// kept everything in the page's localStorage, which WebView2 (Chromium) stores as a LevelDB database under
// %LOCALAPPDATA%\Wortschatz\WebView2\EBWebView\Default\Local Storage\leveldb. This file reads that database directly
// (read-only, no packages): the write-ahead logs (*.log) and the tables (*.ldb, blocks Snappy-compressed), keeps the
// newest value of every key, and maps the Website's keys 1:1 onto this app's storage:
//   wortschatz:v1:sets / progress:<id> / session:<id> / learn:<id> / settings / activity → library.json
//   wortschatz:v1:flashcards:<id> (Karteikarten-Stapel), pref:* and hint:learn             → preferences.json
// The formats are the same (LibraryStore and FlashcardDeck are ports of db.js and flashcards.js); loading the library
// repairs anything odd exactly like loading a stored library does.

/// <summary>What the first start takes over from the earlier app: the library document and this app's preferences.</summary>
public sealed record LegacyTakeover(JSONValue Library, JsonObjectMap Preferences, int SetCount)
{
    /// <summary>The sets as a backup in the Website's export format (db.js exportAll), for "Backup laden".</summary>
    public JSONValue ToBackup(double now) => JSONValue.Obj(
        ("app", "wortschatz"), ("version", 1), ("exportedAt", now),
        ("sets", Library["sets"]), ("progress", Library["progress"]),
        ("settings", Library["settings"] is { IsObject: true } s ? s : null), ("activity", Library["activity"]));
}

/// <summary>Everything of the earlier WebView2-based Windows app, read from its localStorage (one-time takeover).</summary>
public static class LegacyWebStorage
{
    /// <summary>The page origin of the earlier app (windows/host/main.go: appHost). WebView2 stores localStorage per origin.</summary>
    public const string Origin = "https://wortschatz.example";

    /// <summary>The Website's storage prefix (Website/src/store/db.js: PREFIX).</summary>
    public const string Prefix = "wortschatz:v1:";

    /// <summary>The earlier app's data folder, %LOCALAPPDATA%\Wortschatz (now also this app's).</summary>
    public static string DefaultRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wortschatz");

    /// <summary>Its localStorage: &lt;root&gt;\WebView2\EBWebView\Default\Local Storage\leveldb</summary>
    public static string LevelDbFolder(string root) =>
        Path.Combine(root, "WebView2", "EBWebView", "Default", "Local Storage", "leveldb");

    /// <summary>Website preference names (src/lib/prefs.js, the Mac names) → this app's preference keys.</summary>
    static readonly Dictionary<string, string> PreferenceKeys = new(StringComparer.Ordinal)
    {
        ["soundEffects"] = "soundEffects",
        ["flashcards.front"] = "flashcards.front",
        ["flashcards.shuffle"] = "flashcards.shuffle",
        ["learn.review"] = "learn.review",
        ["dailyStreakCelebrated"] = "celebratedStreakDay",
    };

    /// <summary>
    /// Everything of the earlier app, or null when there is no database or it holds no sets. Never throws for a missing
    /// or damaged database: unreadable parts are skipped.
    /// </summary>
    public static LegacyTakeover? ReadTakeover(string folder)
    {
        Dictionary<string, string> items;
        try { items = ReadLocalStorage(folder, Origin); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        return BuildTakeover(items);
    }

    /// <summary>Maps the Website's localStorage items (keys without origin) onto this app, or null without sets.</summary>
    public static LegacyTakeover? BuildTakeover(IReadOnlyDictionary<string, string> items)
    {
        var sets = items.TryGetValue(Prefix + "sets", out var rawSets) ? JSONValue.TryParse(rawSets) : null;
        if (sets is not { Kind: JSONKind.Array } || sets.ArrayValue!.Count == 0) return null;

        var progress = new List<KeyValuePair<string, JSONValue>>();
        var sessions = new List<KeyValuePair<string, JSONValue>>();
        var learns = new List<KeyValuePair<string, JSONValue>>();
        var prefs = new JsonObjectMap();
        JSONValue? settings = null, activity = null;
        foreach (var (fullKey, raw) in items.OrderBy(i => i.Key, StringComparer.Ordinal))
        {
            if (!fullKey.StartsWith(Prefix, StringComparison.Ordinal)) continue;
            var key = fullKey[Prefix.Length..];
            if (key == "hint:learn") { if (raw == "1") prefs["learn.introHintDismissed"] = true; continue; }
            if (JSONValue.TryParse(raw) is not { } value) continue;
            int colon = key.IndexOf(':');
            string kind = colon < 0 ? key : key[..colon], rest = colon < 0 ? "" : key[(colon + 1)..];
            switch (kind)
            {
                case "settings": settings = value; break;
                case "activity": activity = value; break;
                case "progress" when rest.Length > 0 && value.IsObject: progress.Add(new(rest, value)); break;
                case "session" when rest.Length > 0 && value.IsObject: sessions.Add(new(rest, value)); break;
                case "learn" when rest.Length > 0 && value.IsObject: learns.Add(new(rest, value)); break;
                case "flashcards" when rest.Length > 0 && value.IsObject: prefs["flashcards." + rest] = value; break;
                case "pref" when PreferenceKeys.TryGetValue(rest, out var mapped): prefs[mapped] = value; break;
                case "pref" when rest == "exam.settings" && value.IsObject:
                    // The Website has one exam setup for all sets, this app one per set.
                    foreach (var set in sets.ArrayValue!)
                        if (set["id"]?.StringValue is { Length: > 0 } id) prefs["exam." + id] = value;
                    break;
            }
        }
        var library = JSONValue.Object(new List<KeyValuePair<string, JSONValue>>
        {
            new("schemaVersion", 1),
            new("sets", sets),
            new("progress", JSONValue.Object(progress)),
            new("sessions", JSONValue.Object(sessions)),
            new("learns", JSONValue.Object(learns)),
            new("settings", settings ?? JSONValue.Null),
            new("activity", activity ?? JSONValue.Object(new JsonObjectMap())),
        });
        return new LegacyTakeover(library, prefs, sets.ArrayValue!.Count);
    }

    /// <summary>
    /// All localStorage items of <paramref name="origin"/> in a Chromium LevelDB folder (newest value per key, deleted keys
    /// left out). Keys look like "_https://host" + optional "/" + "\0" + encoded name; names and values start with a byte
    /// for their encoding (0 = UTF-16LE, 1 = Latin-1).
    /// </summary>
    public static Dictionary<string, string> ReadLocalStorage(string folder, string origin)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!Directory.Exists(folder)) return result;
        var prefixes = new[] { "_" + origin + "\0", "_" + origin + "/\0" }.Select(Encoding.Latin1.GetBytes).ToArray();
        foreach (var (key, value) in LevelDb.ReadAll(folder))
        {
            var prefix = prefixes.FirstOrDefault(p => key.AsSpan().StartsWith(p));
            if (prefix is null || value is null) continue;
            var name = DecodeChromiumString(key.AsSpan(prefix.Length));
            var text = DecodeChromiumString(value);
            if (name is not null && text is not null) result[name] = text;
        }
        return result;
    }

    static string? DecodeChromiumString(ReadOnlySpan<byte> data)
    {
        if (data.IsEmpty) return null;
        return data[0] switch
        {
            0 => Encoding.Unicode.GetString(data[1..]),
            1 => Encoding.Latin1.GetString(data[1..]),
            _ => null,
        };
    }
}

/// <summary>A minimal read-only LevelDB reader (log and table files), enough for Chromium's localStorage.</summary>
public static class LevelDb
{
    /// <summary>
    /// The newest value of every user key in the folder (null = deleted). Reads every *.log and *.ldb/*.sst file and lets
    /// the highest sequence number win, so the order of the files does not matter.
    /// </summary>
    public static Dictionary<byte[], byte[]?> ReadAll(string folder)
    {
        var newest = new Dictionary<byte[], (ulong Seq, byte[]? Value)>(ByteArrayComparer.Instance);
        void Put(byte[] key, ulong seq, byte[]? value)
        {
            if (!newest.TryGetValue(key, out var old) || seq >= old.Seq) newest[key] = (seq, value);
        }
        foreach (var file in Directory.EnumerateFiles(folder))
        {
            var ext = Path.GetExtension(file).ToLowerInvariant();
            if (ext is not (".log" or ".ldb" or ".sst")) continue;
            byte[] data;
            try { data = ReadShared(file); }
            catch (IOException) { continue; }
            try
            {
                if (ext == ".log") ReadLog(data, Put);
                else ReadTable(data, Put);
            }
            catch (Exception e) when (e is FormatException or ArgumentException or IndexOutOfRangeException or OverflowException)
            {
                // A damaged or half-written file: keep what the other files have.
            }
        }
        return newest.ToDictionary(kv => kv.Key, kv => kv.Value.Value, ByteArrayComparer.Instance);
    }

    /// <summary>Reads a file even while the earlier app has the database open.</summary>
    static byte[] ReadShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    // MARK: Log files (write-ahead log: 32 KiB blocks of records that carry write batches)

    const int BlockSize = 32768;

    public static void ReadLog(byte[] data, Action<byte[], ulong, byte[]?> put)
    {
        var batch = new MemoryStream();
        int pos = 0;
        while (pos + 7 <= data.Length)
        {
            int left = BlockSize - pos % BlockSize;
            if (left < 7) { pos += left; continue; }
            int length = data[pos + 4] | data[pos + 5] << 8;
            byte type = data[pos + 6];
            int start = pos + 7;
            if (type == 0 && length == 0) { pos += left; continue; } // zero padding (preallocated file)
            if (start + length > data.Length) break;                   // cut off at the end
            pos = start + length;
            switch (type)
            {
                case 1: // full
                    batch.SetLength(0);
                    ReadBatch(data.AsSpan(start, length), put);
                    break;
                case 2: // first
                    batch.SetLength(0);
                    batch.Write(data, start, length);
                    break;
                case 3: // middle
                    batch.Write(data, start, length);
                    break;
                case 4: // last
                    batch.Write(data, start, length);
                    ReadBatch(batch.ToArray(), put);
                    batch.SetLength(0);
                    break;
                default:
                    batch.SetLength(0);
                    break;
            }
        }
    }

    static void ReadBatch(ReadOnlySpan<byte> batch, Action<byte[], ulong, byte[]?> put)
    {
        if (batch.Length < 12) return;
        ulong seq = BinaryPrimitives.ReadUInt64LittleEndian(batch);
        uint count = BinaryPrimitives.ReadUInt32LittleEndian(batch[8..]);
        int pos = 12;
        for (uint i = 0; i < count && pos < batch.Length; i++)
        {
            byte tag = batch[pos++];
            var key = ReadSlice(batch, ref pos);
            if (tag == 1) put(key, seq + i, ReadSlice(batch, ref pos));
            else if (tag == 0) put(key, seq + i, null);
            else return;
        }
    }

    static byte[] ReadSlice(ReadOnlySpan<byte> data, ref int pos)
    {
        int length = checked((int)ReadVarint(data, ref pos));
        var slice = data.Slice(pos, length).ToArray();
        pos += length;
        return slice;
    }

    // MARK: Table files (sorted blocks; footer → index block → data blocks)

    const ulong TableMagic = 0xdb4775248b80fb57UL;

    public static void ReadTable(byte[] data, Action<byte[], ulong, byte[]?> put)
    {
        if (data.Length < 48) throw new FormatException("table too short");
        var footer = data.AsSpan(data.Length - 48);
        if (BinaryPrimitives.ReadUInt64LittleEndian(footer[40..]) != TableMagic) throw new FormatException("no table magic");
        int pos = 0;
        ReadVarint(footer, ref pos); ReadVarint(footer, ref pos); // metaindex handle (filters, not needed)
        var index = ReadBlock(data, ReadVarint(footer, ref pos), ReadVarint(footer, ref pos));
        foreach (var (_, handle) in BlockEntries(index))
        {
            int p = 0;
            var block = ReadBlock(data, ReadVarint(handle, ref p), ReadVarint(handle, ref p));
            foreach (var (internalKey, value) in BlockEntries(block))
            {
                if (internalKey.Length < 8) continue;
                var userKey = internalKey[..^8];
                ulong tag = BinaryPrimitives.ReadUInt64LittleEndian(internalKey.AsSpan(internalKey.Length - 8));
                ulong seq = tag >> 8;
                byte kind = (byte)(tag & 0xff);
                put(userKey, seq, kind == 1 ? value : null);
            }
        }
    }

    static byte[] ReadBlock(byte[] data, ulong offset, ulong size)
    {
        int start = checked((int)offset), length = checked((int)size);
        if (start + length + 5 > data.Length) throw new FormatException("block outside the file");
        var raw = data.AsSpan(start, length);
        return data[start + length] switch
        {
            0 => raw.ToArray(),
            1 => Snappy.Decompress(raw),
            _ => throw new FormatException("unknown block compression"),
        };
    }

    /// <summary>The entries of a block (keys share prefixes with the previous key; restart array at the end).</summary>
    static IEnumerable<(byte[] Key, byte[] Value)> BlockEntries(byte[] block)
    {
        if (block.Length < 4) yield break;
        int restarts = (int)BinaryPrimitives.ReadUInt32LittleEndian(block.AsSpan(block.Length - 4));
        int end = block.Length - 4 - 4 * restarts;
        if (end < 0) throw new FormatException("bad restart array");
        var key = Array.Empty<byte>();
        int pos = 0;
        while (pos < end)
        {
            int shared = checked((int)ReadVarint(block, ref pos));
            int unshared = checked((int)ReadVarint(block, ref pos));
            int valueLength = checked((int)ReadVarint(block, ref pos));
            if (shared > key.Length || pos + unshared + valueLength > end) throw new FormatException("bad block entry");
            var next = new byte[shared + unshared];
            Array.Copy(key, next, shared);
            Array.Copy(block, pos, next, shared, unshared);
            pos += unshared;
            var value = block.AsSpan(pos, valueLength).ToArray();
            pos += valueLength;
            key = next;
            yield return (key, value);
        }
    }

    internal static ulong ReadVarint(ReadOnlySpan<byte> data, ref int pos)
    {
        ulong result = 0;
        for (int shift = 0; shift < 64; shift += 7)
        {
            byte b = data[pos++];
            result |= (ulong)(b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
        }
        throw new FormatException("varint too long");
    }

    sealed class ByteArrayComparer : IEqualityComparer<byte[]>
    {
        public static readonly ByteArrayComparer Instance = new();
        public bool Equals(byte[]? x, byte[]? y) => x.AsSpan().SequenceEqual(y);
        public int GetHashCode(byte[] obj)
        {
            var hash = new HashCode();
            hash.AddBytes(obj);
            return hash.ToHashCode();
        }
    }
}

/// <summary>Snappy decompression (the raw format LevelDB uses for its blocks).</summary>
public static class Snappy
{
    public static byte[] Decompress(ReadOnlySpan<byte> input)
    {
        int pos = 0;
        int length = checked((int)LevelDb.ReadVarint(input, ref pos));
        var output = new byte[length];
        int op = 0;
        while (pos < input.Length)
        {
            byte tag = input[pos++];
            int len, offset;
            switch (tag & 3)
            {
                case 0: // literal
                    len = tag >> 2;
                    if (len >= 60)
                    {
                        int bytes = len - 59;
                        len = 0;
                        for (int i = 0; i < bytes; i++) len |= input[pos++] << (8 * i);
                    }
                    len += 1;
                    if (op + len > length || pos + len > input.Length) throw new FormatException("snappy literal out of range");
                    input.Slice(pos, len).CopyTo(output.AsSpan(op));
                    pos += len;
                    op += len;
                    continue;
                case 1: // copy, 1-byte offset
                    len = ((tag >> 2) & 7) + 4;
                    offset = (tag >> 5) << 8 | input[pos++];
                    break;
                case 2: // copy, 2-byte offset
                    len = (tag >> 2) + 1;
                    offset = BinaryPrimitives.ReadUInt16LittleEndian(input[pos..]);
                    pos += 2;
                    break;
                default: // copy, 4-byte offset
                    len = (tag >> 2) + 1;
                    offset = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(input[pos..]));
                    pos += 4;
                    break;
            }
            if (offset <= 0 || offset > op || op + len > length) throw new FormatException("snappy copy out of range");
            for (int i = 0; i < len; i++, op++) output[op] = output[op - offset]; // may overlap
        }
        if (op != length) throw new FormatException("snappy length mismatch");
        return output;
    }
}
