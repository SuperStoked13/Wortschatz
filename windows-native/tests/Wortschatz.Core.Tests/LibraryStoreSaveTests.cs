using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// Saving in two steps (the Windows app encodes on the UI thread and writes the file in the background):
/// EncodePending takes the unsaved state, WriteEncoded writes it, an older revision never overwrites a newer file.
/// </summary>
public sealed class LibraryStoreSaveTests
{
    static LibraryStore NewStore(MemoryBackend backend) => new(backend, autosave: false);

    [Fact]
    public void NothingPendingWithoutChanges()
    {
        var store = NewStore(new MemoryBackend());
        Assert.Null(store.EncodePending());
    }

    [Fact]
    public void EncodeThenWriteSavesAndClearsDirty()
    {
        var backend = new MemoryBackend();
        var store = NewStore(backend);
        store.CreateSet("Unité 1", cards: [new CardDraft(null, "la maison", "das Haus", false)]);
        Assert.True(store.HasUnsavedChanges);
        var pending = store.EncodePending();
        Assert.NotNull(pending);
        store.WriteEncoded(pending.Value.Data, pending.Value.Revision);
        Assert.False(store.HasUnsavedChanges);
        Assert.Equal(1, backend.SaveCount);
        var reloaded = NewStore(new MemoryBackend(backend.Data));
        Assert.Equal("Unité 1", Assert.Single(reloaded.ListSets()).Title);
        Assert.Null(store.EncodePending());
    }

    [Fact]
    public void OlderRevisionDoesNotOverwriteNewerOne()
    {
        var backend = new MemoryBackend();
        var store = NewStore(backend);
        store.CreateSet("Erst");
        var first = store.EncodePending()!.Value;
        store.CreateSet("Zweit");
        var second = store.EncodePending()!.Value;
        store.WriteEncoded(second.Data, second.Revision);
        store.WriteEncoded(first.Data, first.Revision);
        Assert.Equal(1, backend.SaveCount);
        Assert.Equal(2, NewStore(new MemoryBackend(backend.Data)).ListSets().Count);
    }

    [Fact]
    public void ChangeDuringWriteStaysDirty()
    {
        var backend = new MemoryBackend();
        var store = NewStore(backend);
        store.CreateSet("Erst");
        var pending = store.EncodePending()!.Value;
        store.CreateSet("Zweit");
        store.WriteEncoded(pending.Data, pending.Revision);
        Assert.True(store.HasUnsavedChanges);
        store.Save();
        Assert.Equal(2, NewStore(new MemoryBackend(backend.Data)).ListSets().Count);
    }
}
