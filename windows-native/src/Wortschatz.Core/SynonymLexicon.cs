using System.IO.Compression;
using System.Text;

namespace Wortschatz.Core;

/// <summary>A synonym: the word and, for a noun, its gender letters (m, f, n, p; empty when unknown or not a noun).</summary>
public readonly record struct LexiconWord(string Text, string Genders);

/// <summary>
/// The synonyms of one word in one word class: <see cref="Class"/> n (noun), v (verb, English only) or x (anything
/// else); <see cref="HeadClasses"/> are all the classes the word has («bête»: nx), so a card without an article does
/// not get the noun's synonyms of a word that is also an adjective.
/// </summary>
public sealed record LexiconEntry(string Head, char Class, string HeadClasses, IReadOnlyList<LexiconWord> Synonyms);

/// <summary>
/// One language's synonym lists (monolingual: German words for German words), built from free thesauri, wordnets and
/// Wiktionary by tools/synonym-data and tools/Wortschatz.SynonymData (sources, rules and licences:
/// SynonymData/README.md) and embedded Brotli-compressed.
///
/// The data stays in memory as the one byte array it is stored as (about 1–5 MB per language once unpacked); a lookup
/// finds the word's key by binary search and reads its line. A language is only unpacked when first asked for.
///
/// Format (UTF-8): a header line <c>WSSYN2 lang lines</c>, then one line per word and word class, sorted by the
/// key's UTF-8 bytes: <c>key \t head#c/classes \t synonym|genders \t synonym …</c>. The key is <see cref="KeyOf"/>
/// of the head, computed by the packing tool with this very code, so lookups and data cannot disagree.
/// </summary>
public sealed class SynonymLexicon
{
    public Lang Lang { get; }
    readonly byte[] _data;
    readonly int[] _lines;

    SynonymLexicon(Lang lang, byte[] data, int[] lines)
    {
        Lang = lang;
        _data = data;
        _lines = lines;
    }

    public int Count => _lines.Length;
    /// <summary>Bytes the language takes in memory once loaded.</summary>
    public long MemoryBytes => _data.LongLength + 4L * _lines.Length;

    // MARK: Keys

    /// <summary>
    /// Placeholders of vocabulary lists that are not part of the word («etw. verbieten», «to sign sth», «demander qc»):
    /// left out of the key.
    /// </summary>
    static readonly HashSet<string> Placeholders = new(StringComparer.Ordinal)
    {
        "etw", "etwas", "jmdn", "jmdm", "jmds", "jmd", "jdn", "jdm", "jds", "jd", "jemanden", "jemandem", "jemandes",
        "sth", "sb", "smth", "smb", "someone", "something", "somebody", "qc", "qch", "qqch", "qqc", "qn", "qqn",
        "algo", "alguien", "alg", "qlco", "qlcu", "qualcosa", "qualcuno",
    };

    /// <summary>The lookup key of a word: <see cref="ExtendedSynonyms.LooseKey"/> without placeholders.</summary>
    public static string KeyOf(string text, Lang lang)
    {
        // «sb/sth», «jmdn./etw.»: a slash separates words here.
        var key = ExtendedSynonyms.LooseKey(text.Replace('/', ' '), lang);
        if (key.Length == 0) return key;
        var words = key.Split(' ');
        if (!words.Any(Placeholders.Contains)) return key;
        var kept = words.Where(w => !Placeholders.Contains(w)).ToArray();
        return kept.Length == 0 ? key : string.Join(' ', kept);
    }

    // MARK: Loading

    static readonly Dictionary<Lang, Lazy<SynonymLexicon?>> Loaded = [];

    /// <summary>The languages that come with synonym data.</summary>
    public static IReadOnlyList<Lang> Languages { get; } = FindLanguages();

    /// <summary>The language's data (unpacked on first use, then kept), or null when there is none for it.</summary>
    public static SynonymLexicon? For(Lang lang)
    {
        Lazy<SynonymLexicon?> lazy;
        lock (Loaded)
        {
            if (!Loaded.TryGetValue(lang, out lazy!))
                Loaded[lang] = lazy = new Lazy<SynonymLexicon?>(() => Load(lang), LazyThreadSafetyMode.ExecutionAndPublication);
        }
        return lazy.Value;
    }

    /// <summary>Unpacks a language in the background, so the first answer does not wait for it.</summary>
    public static void Preload(Lang lang)
    {
        if (Languages.Contains(lang)) Task.Run(() => For(lang));
    }

    static string ResourceName(Lang lang) => $"Wortschatz.Core.SynonymData.{lang.Raw()}.syn";

    static List<Lang> FindLanguages()
    {
        var names = typeof(SynonymLexicon).Assembly.GetManifestResourceNames();
        return Enum.GetValues<Lang>().Where(l => names.Contains(ResourceName(l))).ToList();
    }

    static SynonymLexicon? Load(Lang lang)
    {
        try
        {
            using var stream = typeof(SynonymLexicon).Assembly.GetManifestResourceStream(ResourceName(lang));
            if (stream is null) return null;
            return Parse(lang, Unpack(stream));
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>The uncompressed bytes of packed data.</summary>
    public static byte[] Unpack(Stream packed)
    {
        using var brotli = new BrotliStream(packed, CompressionMode.Decompress);
        // Room for the data up front (the lists unpack to about 4 times their size): growing from nothing allocated
        // about four times the data, German 21 MB for 4.7 MB (26.11.2026).
        int expected = packed.CanSeek ? (int)Math.Min(packed.Length * 9 / 2, int.MaxValue / 2) : 0;
        using var buffer = new MemoryStream(expected);
        brotli.CopyTo(buffer);
        return buffer.ToArray();
    }

    /// <summary>Reads uncompressed data (tests and the packing tool).</summary>
    public static SynonymLexicon Parse(Lang lang, byte[] data)
    {
        int pos;
        var header = Encoding.UTF8.GetString(data, 0, LineEnd(data, 0)).Split(' ');
        if (header.Length != 3 || header[0] != "WSSYN2" || !int.TryParse(header[2], out int count))
            throw new InvalidDataException("Keine Synonymdaten");
        pos = Next(data, 0);
        var lines = new int[count];
        for (int i = 0; i < count; i++)
        {
            if (pos >= data.Length) throw new InvalidDataException("Synonymdaten unvollständig");
            lines[i] = pos;
            pos = Next(data, pos);
        }
        return new SynonymLexicon(lang, data, lines);
    }

    static int LineEnd(byte[] data, int start)
    {
        int i = Array.IndexOf(data, (byte)'\n', start);
        return i < 0 ? data.Length : i;
    }

    static int Next(byte[] data, int start) => Math.Min(data.Length, LineEnd(data, start) + 1);

    // MARK: Lookup

    /// <summary>The lists of the word with the key of <paramref name="text"/> (several: word classes, «Steuern» and «steuern»).</summary>
    public IReadOnlyList<LexiconEntry> Lookup(string text)
    {
        var key = KeyOf(text, Lang);
        if (key.Length == 0) return [];
        var bytes = Encoding.UTF8.GetBytes(key);
        int lo = 0, hi = _lines.Length - 1, found = -1;
        while (lo <= hi)
        {
            int mid = (lo + hi) >>> 1;
            int cmp = CompareKey(_lines[mid], bytes);
            if (cmp == 0)
            {
                found = mid;
                break;
            }
            if (cmp < 0) lo = mid + 1;
            else hi = mid - 1;
        }
        if (found < 0) return [];
        int first = found, last = found;
        while (first > 0 && CompareKey(_lines[first - 1], bytes) == 0) first--;
        while (last < _lines.Length - 1 && CompareKey(_lines[last + 1], bytes) == 0) last++;
        var entries = new List<LexiconEntry>();
        for (int i = first; i <= last; i++)
            if (ReadEntry(_lines[i]) is { } entry) entries.Add(entry);
        return entries;
    }

    /// <summary>Every list with its stored key (tests: the stored keys must still be what KeyOf computes).</summary>
    internal IEnumerable<(string Key, LexiconEntry Entry)> Entries()
    {
        foreach (var start in _lines)
        {
            int tab = Array.IndexOf(_data, (byte)'\t', start);
            if (tab < 0 || ReadEntry(start) is not { } entry) continue;
            yield return (Encoding.UTF8.GetString(_data, start, tab - start), entry);
        }
    }

    /// <summary>Compares the key at the start of the line at <paramref name="start"/> with <paramref name="key"/>.</summary>
    int CompareKey(int start, byte[] key)
    {
        for (int i = 0; ; i++)
        {
            byte a = start + i < _data.Length ? _data[start + i] : (byte)'\n';
            bool keyEnds = a is (byte)'\t' or (byte)'\n';
            if (i == key.Length) return keyEnds ? 0 : 1;
            if (keyEnds) return -1;
            if (a != key[i]) return a < key[i] ? -1 : 1;
        }
    }

    LexiconEntry? ReadEntry(int start)
    {
        var parts = Encoding.UTF8.GetString(_data, start, LineEnd(_data, start) - start).Split('\t');
        if (parts.Length < 3) return null;
        var head = parts[1];
        int hash = head.LastIndexOf('#');
        if (hash < 0 || hash + 1 >= head.Length) return null;
        int slash = head.IndexOf('/', hash);
        char cls = head[hash + 1];
        string classes = slash < 0 ? cls.ToString() : head[(slash + 1)..];
        var words = new List<LexiconWord>(parts.Length - 2);
        foreach (var item in parts.Skip(2))
        {
            int bar = item.LastIndexOf('|');
            words.Add(bar < 0 ? new LexiconWord(item, "") : new LexiconWord(item[..bar], item[(bar + 1)..]));
        }
        return new LexiconEntry(head[..hash], cls, classes, words);
    }
}
