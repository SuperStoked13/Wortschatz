using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// A read, validated backup and what importing it would do (Mac: BackupImportPreview in AppModel+Actions.swift,
/// <c>openImportDialog</c> in settings.js): the import sheet shows it and offers "Zusammenführen" or "Alles ersetzen".
/// </summary>
public sealed record BackupImportPreview(string FileName, JSONValue Payload, IReadOnlyList<VocabSet> Sets, IReadOnlyList<VocabSet> Existing, double? ExportedAt)
{
    /// <summary>Reads and validates backup bytes (web, Mac or Windows) without touching the library. Throws
    /// <see cref="BackupFileError"/> or <see cref="LibraryStoreError"/> with a message for the learner.</summary>
    public static BackupImportPreview Read(string fileName, byte[] data, IReadOnlyList<VocabSet> existing)
    {
        var json = Backup.ReadJSON(data);
        var sets = LibraryStore.PreviewImport(json);
        return new BackupImportPreview(fileName, json, sets, existing, json["exportedAt"]?.FiniteNumber);
    }

    public int CardCount => Sets.Sum(s => s.Cards.Count);

    /// <summary>Backup sets whose id is already in the library (merge replaces them).</summary>
    public int Updates
    {
        get
        {
            var ids = Existing.Select(s => s.Id).ToHashSet();
            return Sets.Count(s => ids.Contains(s.Id));
        }
    }

    public int Additions => Sets.Count - Updates;

    /// <summary>Library sets the backup does not contain (replace loses them).</summary>
    public int Lost
    {
        get
        {
            var ids = Sets.Select(s => s.Id).ToHashSet();
            return Existing.Count(s => !ids.Contains(s.Id));
        }
    }

    public bool LibraryIsEmpty => Existing.Count == 0;

    /// <summary>"3 Lernsets · 120 Begriffe · vom 12.10.2026".</summary>
    public string Meta(TimeZoneInfo? timeZone = null)
    {
        var setsText = Labels.Plural(Sets.Count, "Lernset", "Lernsets");
        var cardsText = Labels.Plural(CardCount, "Begriff", "Begriffe");
        if (ExportedAt is { } at)
        {
            var date = TimeUtil.FormatDate(at, timeZone);
            if (date.Length > 0) return L($"{setsText} · {cardsText} · vom {date}");
        }
        return $"{setsText} · {cardsText}";
    }

    public string MergeDetail
    {
        get
        {
            var parts = new List<string>();
            if (Additions > 0) parts.Add(Labels.Plural(Additions, "neues Lernset", "neue Lernsets"));
            if (Updates > 0)
                parts.Add(Updates == 1 ? L("1 wird durch die Backup-Version ersetzt") : L($"{Updates} werden durch die Backup-Version ersetzt"));
            return parts.Count == 0 ? L("Keine Änderungen") : string.Join(" · ", parts);
        }
    }

    public string ReplaceDetail => Lost switch
    {
        0 => L("Alle deine Lernsets sind im Backup enthalten."),
        1 => L("1 Lernset, das nicht im Backup ist, geht verloren."),
        _ => L($"{Lost} Lernsets, die nicht im Backup sind, gehen verloren."),
    };

    /// <summary>The toast after the import (Mac: performBackupImport).</summary>
    public static string ResultMessage(ImportSummary result, ImportMode mode)
    {
        if (mode == ImportMode.Replace) return L($"Backup wiederhergestellt: {Labels.Plural(result.SetsAdded + result.SetsUpdated, "Lernset", "Lernsets")}");
        int updated = result.SetsUpdated;
        // One whole sentence per case (Mac: performBackupImport).
        return (result.SetsAdded > 0, updated > 0) switch
        {
            (true, true) => L($"Backup importiert: {Labels.Plural(result.SetsAdded, "neues Lernset", "neue Lernsets")}, {updated} aktualisiert"),
            (true, false) => L($"Backup importiert: {Labels.Plural(result.SetsAdded, "neues Lernset", "neue Lernsets")}"),
            (false, true) => L($"Backup importiert: {updated} aktualisiert"),
            _ => L("Backup importiert – keine Änderungen"),
        };
    }
}
