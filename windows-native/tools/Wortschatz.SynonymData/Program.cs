// Packs the synonym lists of tools/synonym-data (syn-<lang>.tsv) into the app's data files
// (src/Wortschatz.Core/SynonymData/<lang>.syn): each line gets its lookup key, computed with the app's own
// SynonymLexicon.KeyOf, the lines are sorted by the key's bytes and the whole is Brotli-compressed.
//
//   dotnet run --project tools/Wortschatz.SynonymData -- <folder with syn-*.tsv> <output folder>
//
// Afterwards it reads every file back like the app does and checks that each word is found under its key.
using System.IO.Compression;
using System.Text;
using Wortschatz.Core;

if (args.Length != 2)
{
    Console.Error.WriteLine("Aufruf: Wortschatz.SynonymData <Ordner mit syn-*.tsv> <Zielordner>");
    return 2;
}
Directory.CreateDirectory(args[1]);
int failures = 0;
foreach (var path in Directory.GetFiles(args[0], "syn-*.tsv").Order(StringComparer.Ordinal))
{
    var code = Path.GetFileNameWithoutExtension(path)["syn-".Length..];
    if (EnumRaw.Parse<Lang>(code) is not { } lang)
    {
        Console.Error.WriteLine($"{path}: unbekannte Sprache «{code}»");
        failures++;
        continue;
    }
    var lines = new List<(byte[] Key, int Order, string Line, string Head)>();
    int order = 0, skipped = 0;
    foreach (var raw in File.ReadLines(path, Encoding.UTF8))
    {
        if (raw.Length == 0) continue;
        var parts = raw.Split('\t');
        int hash = parts[0].LastIndexOf('#');
        var head = hash < 0 ? parts[0] : parts[0][..hash];
        var key = SynonymLexicon.KeyOf(head, lang);
        if (key.Length == 0 || parts.Length < 2 || key.Contains('\t') || key.Contains('\n'))
        {
            skipped++;
            continue;
        }
        lines.Add((Encoding.UTF8.GetBytes(key), order++, $"{key}\t{raw}", head));
    }
    lines.Sort((a, b) =>
    {
        int c = a.Key.AsSpan().SequenceCompareTo(b.Key);
        return c != 0 ? c : a.Order.CompareTo(b.Order);
    });
    var text = new StringBuilder($"WSSYN2 {code} {lines.Count}\n");
    foreach (var l in lines) text.Append(l.Line).Append('\n');
    var bytes = Encoding.UTF8.GetBytes(text.ToString());
    var target = Path.Combine(args[1], $"{code}.syn");
    using (var file = File.Create(target))
    using (var brotli = new BrotliStream(file, new BrotliCompressionOptions { Quality = 11 }))
        brotli.Write(bytes);

    // Read back as the app does: every word must be found under its own key.
    using var packed = File.OpenRead(target);
    var lexicon = SynonymLexicon.Parse(lang, SynonymLexicon.Unpack(packed));
    int missing = lines.Count(l => !lexicon.Lookup(l.Head).Any(e => e.Head == l.Head));
    failures += missing;
    Console.WriteLine($"{code}: {lines.Count} Zeilen ({skipped} ohne Schlüssel), {bytes.Length / 1024} KB entpackt, "
        + $"{new FileInfo(target).Length / 1024} KB gepackt, {lexicon.MemoryBytes / 1024} KB im Speicher, {missing} nicht gefunden");
}
return failures == 0 ? 0 : 1;
