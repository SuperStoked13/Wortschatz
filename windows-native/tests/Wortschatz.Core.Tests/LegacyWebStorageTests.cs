using System.Buffers.Binary;
using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// Takeover of the earlier Windows app (WebView2 localStorage in LevelDB): the files are written here by hand in
/// LevelDB's format (log records with write batches, tables with blocks), so the reader is tested without Chromium.
/// </summary>
public sealed class LegacyWebStorageTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "wortschatz-legacy-" + Guid.NewGuid().ToString("N"));

    public LegacyWebStorageTests() => Directory.CreateDirectory(_dir);
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    // MARK: Chromium localStorage keys and values

    static byte[] Key(string name, bool utf16 = false) =>
        [.. Encoding.Latin1.GetBytes("_" + LegacyWebStorage.Origin + "\0"), .. Str(name, utf16)];

    static byte[] Str(string text, bool utf16 = false) =>
        utf16 ? [0, .. Encoding.Unicode.GetBytes(text)] : [1, .. Encoding.Latin1.GetBytes(text)];

    // MARK: LevelDB writers (test only)

    static void Varint(List<byte> o, ulong v)
    {
        while (v >= 0x80) { o.Add((byte)(v | 0x80)); v >>= 7; }
        o.Add((byte)v);
    }

    static byte[] Batch(ulong seq, params (byte[] Key, byte[]? Value)[] ops)
    {
        var o = new List<byte>();
        var head = new byte[12];
        BinaryPrimitives.WriteUInt64LittleEndian(head, seq);
        BinaryPrimitives.WriteUInt32LittleEndian(head.AsSpan(8), (uint)ops.Length);
        o.AddRange(head);
        foreach (var (key, value) in ops)
        {
            o.Add(value is null ? (byte)0 : (byte)1);
            Varint(o, (ulong)key.Length); o.AddRange(key);
            if (value is not null) { Varint(o, (ulong)value.Length); o.AddRange(value); }
        }
        return [.. o];
    }

    /// <summary>A log file: each batch as records (split into first/middle/last across 32 KiB blocks).</summary>
    static byte[] Log(params byte[][] batches)
    {
        const int block = 32768;
        var o = new List<byte>();
        foreach (var batch in batches)
        {
            int pos = 0;
            bool first = true;
            do
            {
                int left = block - o.Count % block;
                if (left < 7) { o.AddRange(new byte[left]); left = block; }
                int n = Math.Min(batch.Length - pos, left - 7);
                bool last = pos + n == batch.Length;
                byte type = first && last ? (byte)1 : first ? (byte)2 : last ? (byte)4 : (byte)3;
                o.AddRange([0, 0, 0, 0, (byte)n, (byte)(n >> 8), type]); // checksum not checked by the reader
                o.AddRange(batch.AsSpan(pos, n).ToArray());
                pos += n;
                first = false;
            } while (pos < batch.Length);
        }
        return [.. o];
    }

    static byte[] InternalKey(byte[] user, ulong seq, bool value)
    {
        var tag = new byte[8];
        BinaryPrimitives.WriteUInt64LittleEndian(tag, seq << 8 | (value ? 1UL : 0UL));
        return [.. user, .. tag];
    }

    /// <summary>A block with prefix-compressed keys and one restart point.</summary>
    static byte[] Block(IEnumerable<(byte[] Key, byte[] Value)> entries)
    {
        var o = new List<byte>();
        byte[] prev = [];
        foreach (var (key, value) in entries)
        {
            int shared = 0;
            while (shared < prev.Length && shared < key.Length && prev[shared] == key[shared]) shared++;
            Varint(o, (ulong)shared); Varint(o, (ulong)(key.Length - shared)); Varint(o, (ulong)value.Length);
            o.AddRange(key.AsSpan(shared).ToArray()); o.AddRange(value);
            prev = key;
        }
        o.AddRange([0, 0, 0, 0, 1, 0, 0, 0]); // restart at 0, one restart
        return [.. o];
    }

    /// <summary>A table: one data block per group, an index block, an empty metaindex and the footer.</summary>
    static byte[] Table(params (byte[] User, ulong Seq, byte[]? Value)[][] groups)
    {
        var file = new List<byte>();
        (ulong, ulong) Append(byte[] block, byte compression = 0, byte[]? stored = null)
        {
            var data = stored ?? block;
            var handle = ((ulong)file.Count, (ulong)data.Length);
            file.AddRange(data);
            file.AddRange([compression, 0, 0, 0, 0]);
            return handle;
        }
        byte[] Handle((ulong Offset, ulong Size) h) { var o = new List<byte>(); Varint(o, h.Offset); Varint(o, h.Size); return [.. o]; }
        var index = new List<(byte[], byte[])>();
        foreach (var group in groups)
        {
            var entries = group.OrderBy(e => e.User, Comparer<byte[]>.Create((a, b) => a.AsSpan().SequenceCompareTo(b)))
                .Select(e => (InternalKey(e.User, e.Seq, e.Value is not null), e.Value ?? [])).ToList();
            var handle = Append(Block(entries));
            index.Add((entries[^1].Item1, Handle(handle)));
        }
        var meta = Append(Block([]));
        var idx = Append(Block(index));
        var footer = new List<byte>();
        footer.AddRange(Handle(meta)); footer.AddRange(Handle(idx));
        footer.AddRange(new byte[40 - footer.Count]);
        var magic = new byte[8];
        BinaryPrimitives.WriteUInt64LittleEndian(magic, 0xdb4775248b80fb57UL);
        footer.AddRange(magic);
        file.AddRange(footer);
        return [.. file];
    }

    // MARK: Tests

    [Fact]
    public void SnappyLiteralsAndOverlappingCopies()
    {
        // "abc" as a literal, then a copy of 9 bytes from 3 back (overlaps itself).
        byte[] compressed = [12, 0x08, (byte)'a', (byte)'b', (byte)'c', 0x15, 0x03];
        Assert.Equal("abcabcabcabc", Encoding.ASCII.GetString(Snappy.Decompress(compressed)));
        // 2-byte offset copy: literal "xy", copy 4 from 2 back.
        byte[] two = [6, 0x04, (byte)'x', (byte)'y', (4 - 1) << 2 | 2, 2, 0];
        Assert.Equal("xyxyxy", Encoding.ASCII.GetString(Snappy.Decompress(two)));
        Assert.Throws<FormatException>(() => Snappy.Decompress(new byte[] { 4, 0x01 << 2 | 1, 9 }));
    }

    [Fact]
    public void LogKeepsNewestValueAndDeletions()
    {
        File.WriteAllBytes(Path.Combine(_dir, "000003.log"), Log(
            Batch(1, (Key("wortschatz:v1:a"), Str("1")), (Key("wortschatz:v1:b"), Str("x"))),
            Batch(3, (Key("wortschatz:v1:a"), Str("2")), (Key("wortschatz:v1:b"), null))));
        var items = LegacyWebStorage.ReadLocalStorage(_dir, LegacyWebStorage.Origin);
        Assert.Equal("2", items["wortschatz:v1:a"]);
        Assert.False(items.ContainsKey("wortschatz:v1:b"));
    }

    [Fact]
    public void LogRecordsSpanningBlocks()
    {
        var big = new string('é', 70000); // > two blocks, Latin-1
        File.WriteAllBytes(Path.Combine(_dir, "000005.log"), Log(
            Batch(1, (Key("wortschatz:v1:pad"), Str(new string('p', 32700)))),
            Batch(2, (Key("wortschatz:v1:big"), Str(big)), (Key("wortschatz:v1:ü", utf16: true), Str("中文", utf16: true)))));
        var items = LegacyWebStorage.ReadLocalStorage(_dir, LegacyWebStorage.Origin);
        Assert.Equal(big, items["wortschatz:v1:big"]);
        Assert.Equal("中文", items["wortschatz:v1:ü"]);
    }

    [Fact]
    public void TablesAndLogsMergeBySequence()
    {
        // The table holds old values; the log (newer sequence numbers) overrides one and deletes another.
        File.WriteAllBytes(Path.Combine(_dir, "000010.ldb"), Table(
            [(Key("wortschatz:v1:a"), 5, Str("alt")), (Key("wortschatz:v1:b"), 6, Str("bleibt"))],
            [(Key("wortschatz:v1:c"), 7, Str("weg")), (Encoding.Latin1.GetBytes("VERSION"), 1, Encoding.Latin1.GetBytes("1"))]));
        File.WriteAllBytes(Path.Combine(_dir, "000011.log"), Log(
            Batch(20, (Key("wortschatz:v1:a"), Str("neu")), (Key("wortschatz:v1:c"), null))));
        // Other origins and other files are ignored.
        File.WriteAllBytes(Path.Combine(_dir, "000012.log"), Log(
            Batch(30, ([.. Encoding.Latin1.GetBytes("_https://other.example\0"), .. Str("wortschatz:v1:a")], Str("fremd")))));
        File.WriteAllText(Path.Combine(_dir, "LOG"), "not a table");
        var items = LegacyWebStorage.ReadLocalStorage(_dir, LegacyWebStorage.Origin);
        Assert.Equal(new Dictionary<string, string> { ["wortschatz:v1:a"] = "neu", ["wortschatz:v1:b"] = "bleibt" }, items);
    }

    [Fact]
    public void DamagedFilesAreSkipped()
    {
        File.WriteAllBytes(Path.Combine(_dir, "000001.ldb"), [1, 2, 3, 4, 5]);
        var log = Log(Batch(1, (Key("wortschatz:v1:a"), Str("1"))));
        File.WriteAllBytes(Path.Combine(_dir, "000002.log"), [.. log, .. log.AsSpan(0, 9).ToArray()]); // cut-off record
        Assert.Equal("1", LegacyWebStorage.ReadLocalStorage(_dir, LegacyWebStorage.Origin)["wortschatz:v1:a"]);
        Assert.Empty(LegacyWebStorage.ReadLocalStorage(Path.Combine(_dir, "fehlt"), LegacyWebStorage.Origin));
        Assert.Null(LegacyWebStorage.ReadTakeover(Path.Combine(_dir, "fehlt")));
    }

    [Fact]
    public void TakesOverEverything()
    {
        const string sets = """
            [{"id":"set1","title":"Unité 1","termLang":"fr","defLang":"de","createdAt":1000,"updatedAt":2000,
              "cards":[{"id":"c1","term":"la maison","definition":"das Haus"},{"id":"c2","term":"le chat","definition":"die Katze"}]},
             {"id":"set2","title":"Vide","cards":[]}]
            """;
        const string deck = """{"round":1,"queue":["c1","c2"],"sorts":[{"cardID":"c1","verdict":"know"}],"knownEarlier":[],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":3000}""";
        File.WriteAllBytes(Path.Combine(_dir, "000003.log"), Log(Batch(1,
            (Key("wortschatz:v1:sets"), Str(sets)),
            (Key("wortschatz:v1:progress:set1"), Str("""{"c1":{"box":2,"seen":3,"correct":2,"wrong":1,"streak":1,"lastSeen":1500}}""")),
            (Key("wortschatz:v1:settings"), Str("""{"theme":"dark"}""")),
            (Key("wortschatz:v1:activity"), Str("""{"2026-10-14":12}""")),
            (Key("wortschatz:v1:session:set1"), Str("""{"round":1}""")),
            (Key("wortschatz:v1:learn:set1"), Str("""{"phase":"question"}""")),
            (Key("wortschatz:v1:flashcards:set1"), Str(deck)),
            (Key("wortschatz:v1:pref:soundEffects"), Str("false")),
            (Key("wortschatz:v1:pref:dailyStreakCelebrated"), Str("\"2026-10-14\"")),
            (Key("wortschatz:v1:pref:exam.settings"), Str("""{"count":5}""")),
            (Key("wortschatz:v1:pref:voices"), Str("{}")),
            (Key("wortschatz:v1:hint:learn"), Str("1")))));
        var takeover = LegacyWebStorage.ReadTakeover(_dir);
        Assert.NotNull(takeover);
        Assert.Equal(2, takeover.SetCount);

        // The library document loads like a stored library.
        var store = new LibraryStore(new MemoryBackend(Encoding.UTF8.GetBytes(takeover.Library.ToJsonString())));
        var set = store.GetSet("set1")!;
        Assert.Equal("Unité 1", set.Title);
        Assert.Equal(2, set.Cards.Count);
        Assert.Equal(2, store.ListSets().Count);
        Assert.Single(store.GetProgress("set1"));
        Assert.Equal(12, store.GetActivity()["2026-10-14"]);
        Assert.Equal("dark", store.GetSettings().ToJson()["theme"]!.StringValue);
        Assert.NotNull(store.GetSessionJSON("set1"));
        Assert.NotNull(store.GetLearnJSON("set1"));

        // Preferences under this app's keys.
        var prefs = takeover.Preferences;
        Assert.Equal(false, prefs["soundEffects"].BoolValue);
        Assert.Equal("2026-10-14", prefs["celebratedStreakDay"].StringValue);
        Assert.Equal(true, prefs["learn.introHintDismissed"].BoolValue);
        Assert.Equal(5, prefs["exam.set1"]["count"]!.NumberValue);
        Assert.Equal(5, prefs["exam.set2"]["count"]!.NumberValue);
        Assert.False(prefs.ContainsKey("voices"));
        var parsed = FlashcardDeck.FromJson(prefs["flashcards.set1"]);
        Assert.NotNull(parsed);
        Assert.Equal(["c1", "c2"], parsed.Queue);
        Assert.True(parsed.IsConsistent);
    }

    [Fact]
    public void NoBackupWithoutSets()
    {
        File.WriteAllBytes(Path.Combine(_dir, "000003.log"), Log(Batch(1,
            (Key("wortschatz:v1:sets"), Str("[]")), (Key("wortschatz:v1:settings"), Str("{}")))));
        Assert.Null(LegacyWebStorage.ReadTakeover(_dir));
    }
}
