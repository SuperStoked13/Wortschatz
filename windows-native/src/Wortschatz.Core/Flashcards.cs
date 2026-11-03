namespace Wortschatz.Core;

// Port of Flashcards.swift. Karteikarten (Quizlet's Flashcards with "Fortschritt verfolgen"): the cards
// of a set one at a time; the learner turns a card over and sorts it into "Weiss ich" (→) or "Lerne ich
// noch" (←). At the end of a round the "Lerne ich noch" cards come again, until every card is known.
// Sorting is self-assessment only: it never touches the mastery progress. The deck is a plain value the
// app stores per set; no UI code lives here.
//
// Swift has a struct with `mutating` methods; here FlashcardDeck is a class whose methods change it in
// place (same names). `Clone()` gives an independent copy (Swift: `let before = self`).

/// <summary>How the learner sorted a card.</summary>
public enum FlashcardVerdict
{
    /// <summary>"Weiss ich" (→).</summary>
    Know,
    /// <summary>"Lerne ich noch" (←).</summary>
    StillLearning,
}

/// <summary>Which side of the cards is up first.</summary>
public enum FlashcardFront
{
    /// <summary>The term (the learnt language, e.g. French).</summary>
    Term,
    /// <summary>The definition (the translation, e.g. German).</summary>
    Definition,
}

public enum FlashcardActionKind { Flip, Sort, Undo, NextRound, Restart, Exit }

/// <summary>What a key does on the flashcards screen; Verdict only for Sort.</summary>
public readonly record struct FlashcardAction(FlashcardActionKind Kind, FlashcardVerdict Verdict = FlashcardVerdict.Know)
{
    public static readonly FlashcardAction Flip = new(FlashcardActionKind.Flip);
    public static FlashcardAction Sort(FlashcardVerdict v) => new(FlashcardActionKind.Sort, v);
    /// <summary>Takes the last sorted card back ("Zurück", Backspace).</summary>
    public static readonly FlashcardAction Undo = new(FlashcardActionKind.Undo);
    /// <summary>"Weiter mit N Karten" after a round.</summary>
    public static readonly FlashcardAction NextRound = new(FlashcardActionKind.NextRound);
    /// <summary>"Nochmal von vorne" once every card is known.</summary>
    public static readonly FlashcardAction Restart = new(FlashcardActionKind.Restart);
    /// <summary>Back to the set (Esc).</summary>
    public static readonly FlashcardAction Exit = new(FlashcardActionKind.Exit);
}

/// <summary>
/// One flashcards session of a set: the cards of the current round in the order they are shown, how the
/// learner sorted the ones before the current card, and the cards known in earlier rounds.
/// </summary>
public sealed class FlashcardDeck : IJsonEncodable
{
    public sealed record SortEntry(string CardID, FlashcardVerdict Verdict) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("cardID", CardID), ("verdict", Verdict.ToJson()));
    }

    public enum DeckPhase
    {
        /// <summary>A card is on screen.</summary>
        Card,
        /// <summary>The round is over and some cards are still being learnt.</summary>
        RoundDone,
        /// <summary>Every card is known.</summary>
        Finished,
        /// <summary>No card to show (the set has no card with text).</summary>
        Empty,
    }

    /// <summary>The round, from 1.</summary>
    public int Round { get; private set; }
    /// <summary>The cards of this round, in the order they are shown.</summary>
    public List<string> Queue { get; private set; }
    /// <summary>This round's sorts, in order: Sorts[i] is the sort of Queue[i].</summary>
    public List<SortEntry> Sorts { get; private set; }
    /// <summary>Cards sorted into "Weiss ich" in earlier rounds.</summary>
    public List<string> KnownEarlier { get; private set; }
    /// <summary>The current card shows its back.</summary>
    public bool IsFlipped { get; set; }
    /// <summary>Only the starred cards (the subset the deck was started with).</summary>
    public bool StarredOnly { get; private set; }
    /// <summary>The cards come in random order (else in the set's order).</summary>
    public bool IsShuffled { get; private set; }
    /// <summary>When the deck last changed (ms since 1970).</summary>
    public double UpdatedAt { get; set; }

    /// <summary>
    /// A new deck over <paramref name="cards"/>: the ones with text on at least one side (only starred ones when
    /// <paramref name="starredOnly"/>), in the set's order or shuffled.
    /// </summary>
    public FlashcardDeck(IReadOnlyList<Card> cards, double now, bool starredOnly = false, bool shuffled = false, RNG? rng = null)
    {
        var ids = EligibleIDs(cards, starredOnly);
        Round = 1;
        Queue = shuffled ? Shuffled(ids, rng ?? Rand.SystemRNG()) : ids;
        Sorts = [];
        KnownEarlier = [];
        StarredOnly = starredOnly;
        IsShuffled = shuffled;
        UpdatedAt = now;
    }

    FlashcardDeck(int round, List<string> queue, List<SortEntry> sorts, List<string> knownEarlier, bool isFlipped, bool starredOnly,
        bool isShuffled, double updatedAt)
    {
        Round = round;
        Queue = queue;
        Sorts = sorts;
        KnownEarlier = knownEarlier;
        IsFlipped = isFlipped;
        StarredOnly = starredOnly;
        IsShuffled = isShuffled;
        UpdatedAt = updatedAt;
    }

    public FlashcardDeck Clone() => new(Round, [.. Queue], [.. Sorts], [.. KnownEarlier], IsFlipped, StarredOnly, IsShuffled, UpdatedAt);

    /// <summary>Same contents (Swift ==).</summary>
    public bool SameAs(FlashcardDeck other) =>
        Round == other.Round && Queue.SequenceEqual(other.Queue) && Sorts.SequenceEqual(other.Sorts) && KnownEarlier.SequenceEqual(other.KnownEarlier)
        && IsFlipped == other.IsFlipped && StarredOnly == other.StarredOnly && IsShuffled == other.IsShuffled && UpdatedAt == other.UpdatedAt;

    /// <summary>Ids of the cards a deck shows, in the set's order.</summary>
    public static List<string> EligibleIDs(IReadOnlyList<Card> cards, bool starredOnly)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return cards.Where(c => HasText(c) && (!starredOnly || c.Starred) && c.Id.Length > 0 && seen.Add(c.Id)).Select(c => c.Id).ToList();
    }

    // MARK: Reading

    public DeckPhase Phase =>
        Queue.Count == 0 && KnownEarlier.Count == 0 ? DeckPhase.Empty
        : Sorts.Count < Queue.Count ? DeckPhase.Card
        : LearningCount > 0 ? DeckPhase.RoundDone
        : DeckPhase.Finished;

    /// <summary>The card on screen (null after the round).</summary>
    public string? CurrentCardID => Sorts.Count < Queue.Count ? Queue[Sorts.Count] : null;

    /// <summary>The cards waiting under the current one, next first.</summary>
    public IReadOnlyList<string> UpcomingCardIDs => Sorts.Count + 1 < Queue.Count ? Queue.Skip(Sorts.Count + 1).ToList() : [];

    /// <summary>All cards of the deck.</summary>
    public int Total => KnownEarlier.Count + Queue.Count;
    /// <summary>Cards of this round.</summary>
    public int RoundSize => Queue.Count;
    /// <summary>Cards already sorted in this round.</summary>
    public int SortedInRound => Sorts.Count;
    /// <summary>Cards of this round still to come, the current one included.</summary>
    public int Remaining => Queue.Count - Sorts.Count;
    /// <summary>"Weiss ich" over all rounds.</summary>
    public int KnownCount => KnownEarlier.Count + Sorts.Count(s => s.Verdict == FlashcardVerdict.Know);
    /// <summary>"Lerne ich noch" in this round.</summary>
    public int LearningCount => Sorts.Count(s => s.Verdict == FlashcardVerdict.StillLearning);
    /// <summary>"Weiss ich" in this round.</summary>
    public int KnownInRound => Sorts.Count - LearningCount;

    /// <summary>The last sort can be taken back.</summary>
    public bool CanUndo => Sorts.Count > 0;
    /// <summary>Starting over would throw sorting away.</summary>
    public bool HasProgress => Sorts.Count > 0 || Round > 1;
    /// <summary>The deck can be resumed (not finished, not empty).</summary>
    public bool IsResumable => Phase is DeckPhase.Card or DeckPhase.RoundDone;
    /// <summary>Share of the deck known (0…1).</summary>
    public double KnownShare => Total > 0 ? (double)KnownCount / Total : 0;

    /// <summary>
    /// Whether a stored deck makes sense: every sort belongs to the card at its place, no card twice. Decks read
    /// back from storage are checked before they are used.
    /// </summary>
    public bool IsConsistent
    {
        get
        {
            if (Round < 1 || Sorts.Count > Queue.Count) return false;
            for (int i = 0; i < Sorts.Count; i++)
                if (Queue[i] != Sorts[i].CardID) return false;
            var all = Queue.Concat(KnownEarlier).ToList();
            return all.Distinct(StringComparer.Ordinal).Count() == all.Count;
        }
    }

    // MARK: Changing

    /// <summary>Turns the current card over.</summary>
    public void Flip(double now)
    {
        if (Phase != DeckPhase.Card) return;
        IsFlipped = !IsFlipped;
        UpdatedAt = now;
    }

    /// <summary>Sorts the current card; the next one comes up front side first. Null when there is no current card.</summary>
    public SortEntry? Sort(FlashcardVerdict verdict, double now)
    {
        if (CurrentCardID is not { } id) return null;
        var sort = new SortEntry(id, verdict);
        Sorts.Add(sort);
        IsFlipped = false;
        UpdatedAt = now;
        return sort;
    }

    /// <summary>Takes the last sort of this round back: that card is current again, front up. Null when nothing was sorted.</summary>
    public SortEntry? Undo(double now)
    {
        if (Sorts.Count == 0) return null;
        var last = Sorts[^1];
        Sorts.RemoveAt(Sorts.Count - 1);
        IsFlipped = false;
        UpdatedAt = now;
        return last;
    }

    /// <summary>
    /// After a round: the "Lerne ich noch" cards again (shuffled, or in the set's order <paramref name="cardOrder"/>; without it
    /// in the order they came), the known ones are put aside.
    /// </summary>
    public void StartNextRound(double now, IReadOnlyList<string>? cardOrder = null, RNG? rng = null)
    {
        if (Phase != DeckPhase.RoundDone) return;
        KnownEarlier.AddRange(Sorts.Where(s => s.Verdict == FlashcardVerdict.Know).Select(s => s.CardID));
        var again = Sorts.Where(s => s.Verdict == FlashcardVerdict.StillLearning).Select(s => s.CardID).ToList();
        Queue = IsShuffled ? Shuffled(again, rng ?? Rand.SystemRNG()) : cardOrder is not null ? Ordered(again, cardOrder) : again;
        Sorts = [];
        Round++;
        IsFlipped = false;
        UpdatedAt = now;
    }

    /// <summary>Shuffles the cards still to come after the current one, or puts them back into the set's order.</summary>
    public void SetShuffled(bool shuffled, IReadOnlyList<string> cardOrder, double now, RNG? rng = null)
    {
        if (shuffled == IsShuffled) return;
        IsShuffled = shuffled;
        UpdatedAt = now;
        int start = Math.Min(Queue.Count, Sorts.Count + 1);
        var rest = Queue.Skip(start).ToList();
        if (rest.Count <= 1) return;
        Queue = [.. Queue.Take(start), .. shuffled ? Shuffled(rest, rng ?? Rand.SystemRNG()) : Ordered(rest, cardOrder)];
    }

    /// <summary>ids in the order of cardOrder (ids it does not know last, as they were).</summary>
    internal static List<string> Ordered(IReadOnlyList<string> ids, IReadOnlyList<string> cardOrder)
    {
        var position = new Dictionary<string, int>(StringComparer.Ordinal);
        for (int i = 0; i < cardOrder.Count; i++) position.TryAdd(cardOrder[i], i);
        return ids.Select((id, i) => (id, i, p: position.TryGetValue(id, out int x) ? x : int.MaxValue))
            .OrderBy(x => x.p).ThenBy(x => x.i).Select(x => x.id).ToList();
    }

    /// <summary>
    /// Follows changes of the set: deleted cards (or cards without text now) leave the deck, new cards join at
    /// the end of this round. A starred-only deck keeps its cards when their star is removed and takes newly
    /// starred cards in. Returns whether the deck changed.
    /// </summary>
    public bool Sync(IReadOnlyList<Card> cards, double now)
    {
        var present = new HashSet<string>(cards.Where(HasText).Select(c => c.Id), StringComparer.Ordinal);
        var before = Clone();
        var currentID = CurrentCardID;

        // Drop what is gone, keeping each sort next to its card.
        var keptQueue = new List<string>();
        var keptSorts = new List<SortEntry>();
        for (int i = 0; i < Queue.Count; i++)
        {
            if (!present.Contains(Queue[i])) continue;
            keptQueue.Add(Queue[i]);
            if (i < Sorts.Count) keptSorts.Add(Sorts[i]);
        }
        // The sorted cards are the queue's head, so they stay its head.
        Queue = keptQueue;
        Sorts = keptSorts;
        KnownEarlier = KnownEarlier.Where(present.Contains).ToList();

        var inDeck = new HashSet<string>(Queue.Concat(KnownEarlier), StringComparer.Ordinal);
        Queue.AddRange(EligibleIDs(cards, StarredOnly).Where(id => !inDeck.Contains(id)));

        if (CurrentCardID != currentID) IsFlipped = false;
        if (SameAs(before)) return false;
        UpdatedAt = now;
        return true;
    }

    // MARK: Keys

    /// <summary>What a key does in <paramref name="phase"/> (null: nothing). Held keys do nothing (one press, one step).</summary>
    public static FlashcardAction? ActionFor(KeyInput key, bool isRepeat, DeckPhase phase)
    {
        if (isRepeat) return null;
        if (key == KeyInput.Escape) return FlashcardAction.Exit;
        switch (phase)
        {
            case DeckPhase.Card:
                if (key == KeyInput.Return || key == KeyInput.Character(" ") || key == KeyInput.Arrow(Direction.Up) || key == KeyInput.Arrow(Direction.Down))
                    return FlashcardAction.Flip;
                if (key == KeyInput.Arrow(Direction.Left)) return FlashcardAction.Sort(FlashcardVerdict.StillLearning);
                if (key == KeyInput.Arrow(Direction.Right)) return FlashcardAction.Sort(FlashcardVerdict.Know);
                if (key == KeyInput.DeleteBackward) return FlashcardAction.Undo;
                return null;
            case DeckPhase.RoundDone:
                if (key == KeyInput.Return) return FlashcardAction.NextRound;
                if (key == KeyInput.DeleteBackward) return FlashcardAction.Undo;
                return null;
            case DeckPhase.Finished:
                if (key == KeyInput.Return) return FlashcardAction.Restart;
                if (key == KeyInput.DeleteBackward) return FlashcardAction.Undo;
                return null;
            default:
                return null;
        }
    }

    // MARK: Storage (keys as the Mac's Codable)

    public JSONValue ToJson() => JSONValue.Obj(
        ("round", Round), ("queue", Queue.ToJsonArray()), ("sorts", Sorts.ToJsonArray()), ("knownEarlier", KnownEarlier.ToJsonArray()),
        ("isFlipped", IsFlipped), ("starredOnly", StarredOnly), ("isShuffled", IsShuffled), ("updatedAt", UpdatedAt));

    /// <summary>A stored deck, or null when it is malformed. Check <see cref="IsConsistent"/> before using it.</summary>
    public static FlashcardDeck? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null || json["round"]?.IntegerValue is not { } round || json["queue"]?.ArrayValue is not { } queue
            || json["sorts"]?.ArrayValue is not { } sorts || json["knownEarlier"]?.ArrayValue is not { } known
            || json["updatedAt"]?.FiniteNumber is not { } updatedAt)
            return null;
        if (queue.Any(v => v.StringValue is null) || known.Any(v => v.StringValue is null)) return null;
        var sortList = new List<SortEntry>();
        foreach (var s in sorts)
        {
            if (s["cardID"]?.StringValue is not { } id || EnumRaw.ParseJson<FlashcardVerdict>(s["verdict"]) is not { } verdict) return null;
            sortList.Add(new SortEntry(id, verdict));
        }
        return new FlashcardDeck(round, queue.Select(v => v.StringValue!).ToList(), sortList, known.Select(v => v.StringValue!).ToList(),
            json["isFlipped"]?.BoolValue ?? false, json["starredOnly"]?.BoolValue ?? false, json["isShuffled"]?.BoolValue ?? false, updatedAt);
    }

    // MARK: Helpers

    internal static bool HasText(Card card) => !string.IsNullOrWhiteSpace(card.Term) || !string.IsNullOrWhiteSpace(card.Definition);

    /// <summary>Fisher–Yates on a copy.</summary>
    internal static List<T> Shuffled<T>(IReadOnlyList<T> list, RNG rng)
    {
        var a = list.ToList();
        for (int i = a.Count - 1; i > 0; i--)
        {
            int r = (int)Math.Floor(rng() * (i + 1));
            int j = Math.Min(Math.Max(r, 0), i);
            (a[i], a[j]) = (a[j], a[i]);
        }
        return a;
    }
}

/// <summary>German texts of the flashcards screen.</summary>
public static class FlashcardCopy
{
    /// <summary>"1 Karte", "12 Karten".</summary>
    public static string Cards(int n) => Labels.Plural(n, "Karte", "Karten");

    /// <summary>The set page's line under a running deck: "Runde 2 · 8 von 12 gewusst".</summary>
    public static string RunningDetail(FlashcardDeck deck)
    {
        var round = deck.Phase == FlashcardDeck.DeckPhase.RoundDone ? $"Runde {deck.Round} geschafft" : $"Runde {deck.Round}";
        var parts = new List<string> { round, $"{deck.KnownCount} von {deck.Total} gewusst" };
        if (deck.StarredOnly) parts.Insert(0, "Nur markierte");
        return string.Join(" · ", parts);
    }

    /// <summary>The Return action after a round: "Weiter mit 4 Karten".</summary>
    public static string NextRoundAction(FlashcardDeck deck) => $"Weiter mit {Cards(deck.LearningCount)}";

    public static string RoundDoneTitle(FlashcardDeck deck) => deck.KnownInRound == 0 ? "Bleib dran!" : "Du machst Fortschritte!";

    /// <summary>"Du kennst 8 von 12 Karten. Die 4 Karten, die du noch lernst, kommen jetzt nochmal."</summary>
    public static string RoundDoneText(FlashcardDeck deck)
    {
        int learning = deck.LearningCount;
        var again = learning == 1
            ? "Die Karte, die du noch lernst, kommt jetzt nochmal."
            : $"Die {learning} Karten, die du noch lernst, kommen jetzt nochmal.";
        return $"Du kennst {deck.KnownCount} von {Cards(deck.Total)}. {again}";
    }

    public static string FinishedTitle(FlashcardDeck deck) =>
        deck.Total == 1 ? "Super, du kennst die Karte!" : $"Super, du kennst alle {deck.Total} Karten!";

    public static string FinishedText(FlashcardDeck deck)
    {
        var rounds = deck.Round == 1 ? "Gleich in der ersten Runde – stark." : $"Geschafft in {deck.Round} Runden.";
        return $"{rounds} Teste dich jetzt in «Lernen», damit sie auch als gemeistert zählen.";
    }

    /// <summary>The confirmation before starting over.</summary>
    public static string RestartMessage(FlashcardDeck deck) =>
        $"Deine Sortierung ({RunningDetail(deck)}) beginnt von vorne. Dein Lernfortschritt bleibt erhalten.";
}
