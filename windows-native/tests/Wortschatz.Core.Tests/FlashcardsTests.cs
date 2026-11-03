using Wortschatz.Core;
using Xunit;
using Phase = Wortschatz.Core.FlashcardDeck.DeckPhase;

namespace Wortschatz.Core.Tests;

// Port of FlashcardsTests.swift. Karteikarten: turning cards over, sorting them into "Weiss ich" /
// "Lerne ich noch", rounds of the cards still being learnt, taking a sort back, following changes of
// the set, the keys.
public class FlashcardsTests
{
    const double T0 = 1_760_000_000_000;

    static Card C(string id, string term = "le mot", string definition = "das Wort", bool starred = false) => new(id, term, definition, starred);

    static readonly List<Card> Cards = [C("a"), C("b"), C("c"), C("d")];

    static FlashcardDeck Deck(IReadOnlyList<Card>? cards = null, bool starredOnly = false) => new(cards ?? Cards, T0, starredOnly);

    [Fact]
    public void NewDeck()
    {
        var deck = Deck([C("a"), C("empty", " ", ""), C("b", "", "nur Deutsch"), C("a")]);
        Assert.Equal(["a", "b"], deck.Queue);
        Assert.Equal("a", deck.CurrentCardID);
        Assert.Equal(Phase.Card, deck.Phase);
        Assert.False(deck.IsFlipped);
        Assert.True(deck.Round == 1 && deck.Total == 2 && deck.Remaining == 2);
        Assert.False(deck.HasProgress || deck.CanUndo);
    }

    [Fact]
    public void StarredOnly()
    {
        Assert.Equal(["b", "c"], Deck([C("a"), C("b", starred: true), C("c", starred: true)], starredOnly: true).Queue);
        Assert.Equal(Phase.Empty, Deck([C("a")], starredOnly: true).Phase);
        Assert.Equal(Phase.Empty, Deck([]).Phase);
    }

    [Fact]
    public void ShuffledDeck()
    {
        var cards = Enumerable.Range(0, 20).Select(i => C($"c{i}")).ToList();
        var one = new FlashcardDeck(cards, T0, shuffled: true, rng: Rand.Mulberry32(7u));
        var two = new FlashcardDeck(cards, T0, shuffled: true, rng: Rand.Mulberry32(7u));
        Assert.Equal(one.Queue, two.Queue);
        Assert.Equal(cards.Select(c => c.Id).Order(), one.Queue.Order());
        Assert.NotEqual(cards.Select(c => c.Id), one.Queue);
        Assert.True(one.IsShuffled);
    }

    [Fact]
    public void FlipAndSort()
    {
        var deck = Deck();
        deck.Flip(T0 + 1);
        Assert.True(deck.IsFlipped);
        deck.Flip(T0 + 2);
        Assert.False(deck.IsFlipped);
        deck.Flip(T0 + 3);
        var sort = deck.Sort(FlashcardVerdict.Know, T0 + 4);
        Assert.Equal(new FlashcardDeck.SortEntry("a", FlashcardVerdict.Know), sort);
        Assert.Equal("b", deck.CurrentCardID);
        Assert.False(deck.IsFlipped);
        Assert.True(deck.KnownCount == 1 && deck.LearningCount == 0 && deck.Remaining == 3);
        Assert.Equal(["c", "d"], deck.UpcomingCardIDs);
        Assert.True(deck.HasProgress && deck.CanUndo);
        Assert.Equal(T0 + 4, deck.UpdatedAt);
    }

    [Fact]
    public void SortWithoutFlip()
    {
        var deck = Deck();
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        Assert.Equal(1, deck.LearningCount);
        Assert.Equal("b", deck.CurrentCardID);
    }

    [Fact]
    public void Undo()
    {
        var deck = Deck([C("a"), C("b")]);
        deck.Sort(FlashcardVerdict.Know, T0);
        deck.Flip(T0);
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        Assert.Equal(Phase.RoundDone, deck.Phase);
        Assert.Equal("b", deck.Undo(T0)?.CardID);
        Assert.True(deck.Phase == Phase.Card && deck.CurrentCardID == "b" && !deck.IsFlipped);
        Assert.True(deck.LearningCount == 0 && deck.KnownCount == 1);
        deck.Undo(T0);
        Assert.Equal("a", deck.CurrentCardID);
        Assert.Null(deck.Undo(T0));
    }

    [Fact]
    public void Rounds()
    {
        var deck = Deck();
        deck.Sort(FlashcardVerdict.Know, T0);
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        deck.Sort(FlashcardVerdict.Know, T0);
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        Assert.Equal(Phase.RoundDone, deck.Phase);
        Assert.Null(deck.CurrentCardID);
        Assert.Equal("Weiter mit 2 Karten", FlashcardCopy.NextRoundAction(deck));
        Assert.Equal("Runde 1 geschafft · 2 von 4 gewusst", FlashcardCopy.RunningDetail(deck));

        deck.StartNextRound(T0);
        Assert.Equal(2, deck.Round);
        Assert.Equal(["b", "d"], deck.Queue);
        Assert.Equal(["a", "c"], deck.KnownEarlier);
        Assert.True(deck.KnownCount == 2 && deck.Total == 4 && deck.Remaining == 2);
        Assert.False(deck.CanUndo);
        Assert.Equal("Runde 2 · 2 von 4 gewusst", FlashcardCopy.RunningDetail(deck));

        deck.Sort(FlashcardVerdict.Know, T0);
        deck.Sort(FlashcardVerdict.Know, T0);
        Assert.Equal(Phase.Finished, deck.Phase);
        Assert.True(deck.KnownCount == 4 && deck.KnownShare == 1);
        Assert.False(deck.IsResumable);
        Assert.Equal("Super, du kennst alle 4 Karten!", FlashcardCopy.FinishedTitle(deck));
        Assert.StartsWith("Geschafft in 2 Runden.", FlashcardCopy.FinishedText(deck));
    }

    [Fact]
    public void FinishedFirstRound()
    {
        var deck = Deck([C("a")]);
        deck.Sort(FlashcardVerdict.Know, T0);
        Assert.Equal(Phase.Finished, deck.Phase);
        Assert.Equal("Super, du kennst die Karte!", FlashcardCopy.FinishedTitle(deck));
        // Nothing happens to a finished deck.
        deck.StartNextRound(T0);
        Assert.Equal(1, deck.Round);
        Assert.Null(deck.Sort(FlashcardVerdict.Know, T0));
    }

    [Fact]
    public void RoundDoneCopy()
    {
        var deck = Deck([C("a"), C("b")]);
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        deck.Sort(FlashcardVerdict.Know, T0);
        Assert.Equal("Du machst Fortschritte!", FlashcardCopy.RoundDoneTitle(deck));
        Assert.Equal("Du kennst 1 von 2 Karten. Die Karte, die du noch lernst, kommt jetzt nochmal.", FlashcardCopy.RoundDoneText(deck));
        Assert.Equal("Weiter mit 1 Karte", FlashcardCopy.NextRoundAction(deck));

        var none = Deck([C("a"), C("b")]);
        none.Sort(FlashcardVerdict.StillLearning, T0);
        none.Sort(FlashcardVerdict.StillLearning, T0);
        Assert.Equal("Bleib dran!", FlashcardCopy.RoundDoneTitle(none));
    }

    [Fact]
    public void ShuffledNextRound()
    {
        var cards = Enumerable.Range(0, 12).Select(i => C($"c{i}")).ToList();
        var deck = new FlashcardDeck(cards, T0, shuffled: true, rng: Rand.Mulberry32(3u));
        var first = deck.Queue.ToList();
        foreach (var _ in first) deck.Sort(FlashcardVerdict.StillLearning, T0);
        deck.StartNextRound(T0, rng: Rand.Mulberry32(99u));
        Assert.Equal(first.Order(), deck.Queue.Order());
        Assert.NotEqual(first, deck.Queue);
    }

    [Fact]
    public void ToggleShuffle()
    {
        var cards = Enumerable.Range(0, 10).Select(i => C($"c{i}")).ToList();
        var order = cards.Select(c => c.Id).ToList();
        var deck = new FlashcardDeck(cards, T0);
        deck.Sort(FlashcardVerdict.Know, T0);
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        deck.SetShuffled(true, order, T0, Rand.Mulberry32(5u));
        Assert.True(deck.IsShuffled);
        Assert.Equal(["c0", "c1", "c2"], deck.Queue.Take(3));
        Assert.Equal(order.Order(), deck.Queue.Order());
        Assert.NotEqual(order, deck.Queue);
        deck.SetShuffled(false, order, T0);
        Assert.Equal(order, deck.Queue);
        Assert.Equal(2, deck.Sorts.Count);
    }

    [Fact]
    public void UnshuffledNextRound()
    {
        var cards = Enumerable.Range(0, 8).Select(i => C($"c{i}")).ToList();
        var order = cards.Select(c => c.Id).ToList();
        var deck = new FlashcardDeck(cards, T0, shuffled: true, rng: Rand.Mulberry32(3u));
        foreach (var _ in order) deck.Sort(FlashcardVerdict.StillLearning, T0);
        Assert.Equal(Phase.RoundDone, deck.Phase);
        deck.SetShuffled(false, order, T0);
        deck.StartNextRound(T0, order);
        Assert.Equal(order, deck.Queue);
    }

    [Fact]
    public void SyncWithSet()
    {
        var deck = Deck();
        deck.Sort(FlashcardVerdict.Know, T0); // a
        deck.Sort(FlashcardVerdict.StillLearning, T0); // b
        deck.Flip(T0); // c is up, back side
        Assert.True(deck.Sync([C("a"), C("c"), C("d"), C("e")], T0 + 9));
        Assert.Equal(["a", "c", "d", "e"], deck.Queue);
        Assert.Equal([new FlashcardDeck.SortEntry("a", FlashcardVerdict.Know)], deck.Sorts);
        Assert.Equal("c", deck.CurrentCardID);
        Assert.True(deck.IsFlipped);
        Assert.True(deck.IsConsistent);
        Assert.Equal(T0 + 9, deck.UpdatedAt);
        Assert.False(deck.Sync([C("a"), C("c"), C("d"), C("e")], T0 + 10));

        // The current card deleted: the next one comes up front side first.
        deck.Sync([C("a"), C("d"), C("e")], T0);
        Assert.Equal("d", deck.CurrentCardID);
        Assert.False(deck.IsFlipped);
    }

    [Fact]
    public void SyncKnownEarlier()
    {
        var deck = Deck([C("a"), C("b")]);
        deck.Sort(FlashcardVerdict.Know, T0);
        deck.Sort(FlashcardVerdict.StillLearning, T0);
        deck.StartNextRound(T0);
        deck.Sync([C("b")], T0);
        Assert.Empty(deck.KnownEarlier);
        Assert.Equal(1, deck.Total);
        deck.Sync([], T0);
        Assert.Equal(Phase.Empty, deck.Phase);
    }

    [Fact]
    public void SyncStarredOnly()
    {
        var deck = Deck([C("a", starred: true), C("b")], starredOnly: true);
        Assert.Equal(["a"], deck.Queue);
        deck.Sync([C("a"), C("b", starred: true)], T0);
        Assert.Equal(["a", "b"], deck.Queue);
    }

    [Fact]
    public void Consistency()
    {
        var deck = Deck();
        deck.Sort(FlashcardVerdict.Know, T0);
        Assert.True(deck.IsConsistent);
        var decoded = FlashcardDeck.FromJson(JSONValue.Parse(deck.ToJson().ToJsonString()));
        Assert.NotNull(decoded);
        Assert.True(decoded.SameAs(deck));

        // A sort that does not belong to its card.
        var bad = FlashcardDeck.FromJson(JSONValue.Parse("""{"round":1,"queue":["a","b"],"sorts":[{"cardID":"b","verdict":"know"}],"knownEarlier":[],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":0}"""));
        Assert.False(bad!.IsConsistent);
        var twice = FlashcardDeck.FromJson(JSONValue.Parse("""{"round":2,"queue":["a"],"sorts":[],"knownEarlier":["a"],"isFlipped":false,"starredOnly":false,"isShuffled":false,"updatedAt":0}"""));
        Assert.False(twice!.IsConsistent);
    }

    [Fact]
    public void KeysOnCard()
    {
        static FlashcardAction? A(KeyInput key, bool isRepeat = false) => FlashcardDeck.ActionFor(key, isRepeat, Phase.Card);
        Assert.Equal(FlashcardAction.Flip, A(KeyInput.Character(" ")));
        Assert.Equal(FlashcardAction.Flip, A(KeyInput.Return));
        Assert.Equal(FlashcardAction.Flip, A(KeyInput.Arrow(Direction.Up)));
        Assert.Equal(FlashcardAction.Flip, A(KeyInput.Arrow(Direction.Down)));
        Assert.Equal(FlashcardAction.Sort(FlashcardVerdict.StillLearning), A(KeyInput.Arrow(Direction.Left)));
        Assert.Equal(FlashcardAction.Sort(FlashcardVerdict.Know), A(KeyInput.Arrow(Direction.Right)));
        Assert.Equal(FlashcardAction.Undo, A(KeyInput.DeleteBackward));
        Assert.Equal(FlashcardAction.Exit, A(KeyInput.Escape));
        Assert.Null(A(KeyInput.Character("x")));
        Assert.Null(A(KeyInput.DigitKey(1)));
        // A held key is one step.
        Assert.Null(A(KeyInput.Arrow(Direction.Right), true));
        Assert.Null(A(KeyInput.Character(" "), true));
    }

    [Fact]
    public void KeysAfterRound()
    {
        Assert.Equal(FlashcardAction.NextRound, FlashcardDeck.ActionFor(KeyInput.Return, false, Phase.RoundDone));
        Assert.Equal(FlashcardAction.Undo, FlashcardDeck.ActionFor(KeyInput.DeleteBackward, false, Phase.RoundDone));
        Assert.Null(FlashcardDeck.ActionFor(KeyInput.Arrow(Direction.Right), false, Phase.RoundDone));
        Assert.Equal(FlashcardAction.Restart, FlashcardDeck.ActionFor(KeyInput.Return, false, Phase.Finished));
        Assert.Null(FlashcardDeck.ActionFor(KeyInput.Character(" "), false, Phase.Finished));
        Assert.Null(FlashcardDeck.ActionFor(KeyInput.Return, false, Phase.Empty));
        Assert.Equal(FlashcardAction.Exit, FlashcardDeck.ActionFor(KeyInput.Escape, false, Phase.Empty));
    }
}
