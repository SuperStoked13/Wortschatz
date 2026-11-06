using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// The import sheet's preview (Mac: BackupImportPreview in AppModel+Actions.swift): what a backup contains and what
// merging or replacing would do; the result toast.
public class BackupImportPreviewTests
{
    static (LibraryStore Store, byte[] Backup) Library()
    {
        var store = new LibraryStore(new MemoryBackend());
        store.CreateSet("Unité 1", "", Lang.Fr, Lang.De, [new("le chat", "die Katze"), new("le chien", "der Hund")]);
        store.CreateSet("Unit 2", "", Lang.En, Lang.De, [new("the cat", "die Katze")]);
        return (store, Backup.JsonData(store.ExportAll()));
    }

    [Fact]
    public void EmptyLibraryRestoresEverything()
    {
        var (_, data) = Library();
        var preview = BackupImportPreview.Read("wortschatz-backup-2026-11-03.json", data, []);
        Assert.True(preview.LibraryIsEmpty);
        Assert.Equal(2, preview.Sets.Count);
        Assert.Equal(3, preview.CardCount);
        Assert.Equal(2, preview.Additions);
        Assert.Equal(0, preview.Updates);
        Assert.Equal(0, preview.Lost);
        Assert.StartsWith("2 Lernsets · 3 Begriffe · vom ", preview.Meta(Fixtures.Zurich));
    }

    [Fact]
    public void MergeAndReplaceDetails()
    {
        var (source, data) = Library();
        var target = new LibraryStore(new MemoryBackend());
        target.ImportAll(Backup.ReadJSON(data), ImportMode.Replace);
        // One set of the backup is gone here, and one set exists only here.
        target.DeleteSet(source.ListSets()[1].Id);
        target.CreateSet("Nur hier", "", Lang.It, Lang.De, [new("il gatto", "die Katze")]);
        var preview = BackupImportPreview.Read("backup.json", data, target.ListSets());
        Assert.False(preview.LibraryIsEmpty);
        Assert.Equal(1, preview.Additions);
        Assert.Equal(1, preview.Updates);
        Assert.Equal(1, preview.Lost);
        Assert.Equal("1 neues Lernset · 1 wird durch die Backup-Version ersetzt", preview.MergeDetail);
        Assert.Equal("1 Lernset, das nicht im Backup ist, geht verloren.", preview.ReplaceDetail);
    }

    [Fact]
    public void Details()
    {
        var (_, data) = Library();
        var same = BackupImportPreview.Read("b.json", data, BackupImportPreview.Read("b.json", data, []).Sets);
        Assert.Equal("2 werden durch die Backup-Version ersetzt", same.MergeDetail);
        Assert.Equal("Alle deine Lernsets sind im Backup enthalten.", same.ReplaceDetail);
        var empty = new BackupImportPreview("b.json", JSONValue.Obj(), [], [], null);
        Assert.Equal("Keine Änderungen", empty.MergeDetail);
        Assert.Equal("0 Lernsets · 0 Begriffe", empty.Meta());
        var many = new BackupImportPreview("b.json", JSONValue.Obj(), [], same.Sets, null);
        Assert.Equal("2 Lernsets, die nicht im Backup sind, gehen verloren.", many.ReplaceDetail);
    }

    [Fact]
    public void InvalidFiles()
    {
        Assert.Throws<BackupFileError>(() => BackupImportPreview.Read("x.json", "nicht json"u8.ToArray(), []));
        var error = Assert.Throws<LibraryStoreError>(() => BackupImportPreview.Read("x.json", "{\"app\":\"andere\"}"u8.ToArray(), []));
        Assert.Equal(StoreMessages.NotBackup, error.Message);
    }

    [Fact]
    public void ResultMessages()
    {
        Assert.Equal("Backup wiederhergestellt: 3 Lernsets", BackupImportPreview.ResultMessage(new(2, 1), ImportMode.Replace));
        Assert.Equal("Backup importiert: 2 neue Lernsets, 1 aktualisiert", BackupImportPreview.ResultMessage(new(2, 1), ImportMode.Merge));
        Assert.Equal("Backup importiert: 1 neues Lernset", BackupImportPreview.ResultMessage(new(1, 0), ImportMode.Merge));
        Assert.Equal("Backup importiert – keine Änderungen", BackupImportPreview.ResultMessage(new(0, 0), ImportMode.Merge));
    }
}
