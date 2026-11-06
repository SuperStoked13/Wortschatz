using Wortschatz.App.DesignSystem;
using Wortschatz.App.Features.Study;
using Wortschatz.Core;
using DeckPhase = Wortschatz.Core.FlashcardDeck.DeckPhase;

namespace Wortschatz.App.Features.Flashcards;

// Port of mac/Wortschatz/Features/Flashcards/FlashcardsController.swift: runs one flashcards screen (Karteikarten),
// holds the deck and performs every action on it, keeps it stored per set (AppPreferences), reads cards aloud, stars
// and edits them. Sorting is self-assessment: nothing here records answers or changes the mastery progress.
// The view only renders the state and calls the actions; Changed tells it to update.

/// <summary>How a card leaves the deck (FlashcardDeckView draws it until its exit is over).</summary>
public abstract record FlashcardDepartureKind
{
    public sealed record Sorted(FlashcardVerdict Verdict) : FlashcardDepartureKind;
    /// <summary>"Zurück" brought the previous card back; the current one goes under the stack again.</summary>
    public sealed record BackToStack : FlashcardDepartureKind;
}

/// <summary>A card on its way out, still drawn over the deck until its exit is over.</summary>
public sealed record FlashcardDeparture(int Id, Card Card, bool ShowsBack, FlashcardDepartureKind Kind, bool Flung = false, double ReleaseOffset = 0, int Generation = 0);

/// <summary>How the current card came on screen (its entrance).</summary>
public abstract record FlashcardArrival
{
    /// <summary>Up from the stack: the next card.</summary>
    public sealed record FromStack : FlashcardArrival;
    /// <summary>Back from the side it was sorted to ("Zurück").</summary>
    public sealed record FromSide(FlashcardVerdict Verdict) : FlashcardArrival;
}

/// <summary>One side of a card as it is shown: the text, its language and the language's name.</summary>
public sealed record FlashcardSide(string Text, Lang Lang, string Label, bool IsBack);

public sealed class FlashcardsController
{
    readonly AppModel _model;
    readonly bool _isLive;
    int _departureSerial;

    public string SetId { get; }
    public VocabSet Set { get; private set; }
    public FlashcardDeck Deck { get; private set; }
    /// <summary>Cards still leaving the screen, oldest first.</summary>
    public List<FlashcardDeparture> Departures { get; } = [];
    /// <summary>How the current card came in.</summary>
    public FlashcardArrival Arrival { get; private set; } = new FlashcardArrival.FromStack();
    /// <summary>Which side is up first (Optionen, the same for every set).</summary>
    public FlashcardFront Front { get; private set; }
    /// <summary>The current card following two fingers on the touchpad or the mouse.</summary>
    public FlashcardSwipe Swipe { get; } = new();
    /// <summary>Grows with every new round and restart: a card that comes up again in the new round is a new view.</summary>
    public int DeckGeneration { get; private set; }
    /// <summary>The current card is being read aloud.</summary>
    public bool IsSpeaking { get; private set; }

    /// <summary>How long a departing card is kept (its exit, at most 0.56 s, is a little shorter).</summary>
    public const double DepartureLifetime = 0.7;

    /// <summary>The deck or the set changed: the screen updates.</summary>
    public event Action? Changed;
    /// <summary>Asks the screen to confirm a restart (title, message, confirm label, then the action).</summary>
    public Action<string, string, string, Action>? Confirm { get; set; }

    public FlashcardsController(AppModel model, StudyRequest request, bool isLive = true)
    {
        _model = model;
        _isLive = isLive;
        SetId = request.SetId;
        Set = model.Set(request.SetId) ?? new VocabSet { Id = request.SetId, Title = "" };
        Front = model.Preferences.FlashcardFront;
        Deck = StartingDeck(Set, request.ForceNew ? null : model.Preferences.Deck(request.SetId), request, model.Preferences.FlashcardShuffle, TimeUtil.NowMs());
    }

    /// <summary>
    /// The stored deck, brought up to date with the set, unless a new one is asked for (or the stored one is finished,
    /// empty or of another subset). A starred-only deck without starred cards becomes one of all cards.
    /// </summary>
    public static FlashcardDeck StartingDeck(VocabSet set, FlashcardDeck? saved, StudyRequest request, bool shuffled, double now)
    {
        bool starredOnly = request.Subset?.Kind == StudySubsetKind.Starred;
        if (!request.ForceNew && saved is not null && (request.Subset is null || saved.StarredOnly == starredOnly))
        {
            saved.Sync(set.Cards, now);
            saved.IsFlipped = false;
            // "Mischen" applies to every set, also to a deck started before it was changed.
            saved.SetShuffled(shuffled, set.Cards.Select(c => c.Id).ToList(), now);
            if (saved.IsResumable) return saved;
        }
        var deck = new FlashcardDeck(set.Cards, now, starredOnly, shuffled);
        if (deck.Phase != DeckPhase.Empty || !starredOnly) return deck;
        return new FlashcardDeck(set.Cards, now, false, shuffled);
    }

    // MARK: Reading

    public DeckPhase Phase => Deck.Phase;

    /// <summary>The card on screen.</summary>
    public Card? CurrentCard => Deck.CurrentCardID is { } id ? CardById(id) : null;

    public Card? CardById(string id) => Set.Cards.FirstOrDefault(c => c.Id == id);

    /// <summary>The starred cards of the set (the "Nur markierte" option).</summary>
    public int StarredCount => Set.Cards.Count(c => c.Starred);

    /// <summary>What <paramref name="card"/> shows face up (showingBack false) or face down.</summary>
    public FlashcardSide SideOf(Card card, bool showingBack)
    {
        bool showsTerm = (Front == FlashcardFront.Term) != showingBack;
        var names = LearnOptionsCopy.SideNames(Set.TermLang, Set.DefLang);
        return new FlashcardSide(
            showsTerm ? card.Term : card.Definition,
            showsTerm ? Set.TermLang : Set.DefLang,
            showsTerm ? names.Term.Label : names.Definition.Label,
            showingBack);
    }

    // MARK: Lifecycle

    /// <summary>The screen went away: the deck stays stored, speech stops.</summary>
    public void Deactivate()
    {
        _model.Speech.Stop();
        Departures.Clear();
        Swipe.Reset();
        Persist();
    }

    // MARK: Keys

    /// <summary>A key press on the screen; returns whether the screen used it (held keys are used but do nothing).</summary>
    public bool Press(KeyInput key, bool isRepeat)
    {
        if (FlashcardDeck.ActionFor(key, false, Phase) is not { } action) return false;
        if (!isRepeat) Perform(action);
        return true;
    }

    public void Perform(FlashcardAction action)
    {
        switch (action.Kind)
        {
            case FlashcardActionKind.Flip: Flip(); break;
            case FlashcardActionKind.Sort: Sort(action.Verdict); break;
            case FlashcardActionKind.Undo: Undo(); break;
            case FlashcardActionKind.NextRound: NextRound(); break;
            case FlashcardActionKind.Restart: Restart(); break;
            case FlashcardActionKind.Exit: Exit(); break;
        }
    }

    // MARK: Actions

    /// <summary>Turns the current card over.</summary>
    public void Flip()
    {
        if (Phase != DeckPhase.Card || CurrentCard is null) return;
        Deck.Flip(TimeUtil.NowMs());
        if (CurrentCard is { } card && SideOf(card, Deck.IsFlipped) is { } side) Announcer.Announce($"{side.Label}: {side.Text}");
        Changed?.Invoke();
    }

    /// <summary>
    /// Sorts the current card: it glides off to its side (flung: a swipe let it go, it flies on from there), the next one
    /// comes up from the stack.
    /// </summary>
    public void Sort(FlashcardVerdict verdict, bool flung = false)
    {
        if (Phase != DeckPhase.Card || CurrentCard is not { } card) return;
        Announcer.Announce(verdict == FlashcardVerdict.Know ? "Weiss ich" : "Lerne ich noch");
        Depart(card, Deck.IsFlipped, new FlashcardDepartureKind.Sorted(verdict), flung, Swipe.OffsetFor(card.Id));
        Arrival = new FlashcardArrival.FromStack();
        // The stack the swipe uncovered goes back under the next card as it rises.
        Swipe.Reset();
        Deck.Sort(verdict, TimeUtil.NowMs());
        StopSpeaking();
        Persist();
        // The round's fanfare replaces the card's own sound, as in Lernen (Mac: FlashcardsController.sort).
        if (_isLive) Services.Haptics.Selection();
        if (_isLive)
            _model.Sounds.Play(Phase switch
            {
                DeckPhase.RoundDone => Services.SoundEffects.Sound.RoundDone,
                DeckPhase.Finished => Services.SoundEffects.Sound.Finished,
                _ => verdict == FlashcardVerdict.Know ? Services.SoundEffects.Sound.Know : Services.SoundEffects.Sound.StillLearning,
            });
        Changed?.Invoke();
    }

    /// <summary>"Zurück" (Rücktaste): the last sorted card comes back from its side; the current one goes back under the stack.</summary>
    public void Undo()
    {
        if (!Deck.CanUndo) return;
        if (CurrentCard is { } card) Depart(card, Deck.IsFlipped, new FlashcardDepartureKind.BackToStack());
        var previous = Deck.Sorts.LastOrDefault();
        Arrival = new FlashcardArrival.FromSide(previous?.Verdict ?? FlashcardVerdict.Know);
        Swipe.Reset();
        Deck.Undo(TimeUtil.NowMs());
        // The card coming back is no longer leaving.
        Departures.RemoveAll(d => d.Card.Id == previous?.CardID);
        StopSpeaking();
        Persist();
        if (_isLive) _model.Sounds.Play(Services.SoundEffects.Sound.Undo);
        Changed?.Invoke();
    }

    /// <summary>"Weiter mit N Karten" after a round.</summary>
    public void NextRound()
    {
        if (Phase != DeckPhase.RoundDone) return;
        DeckGeneration++;
        Arrival = new FlashcardArrival.FromStack();
        Swipe.Reset();
        Deck.StartNextRound(TimeUtil.NowMs(), Set.Cards.Select(c => c.Id).ToList());
        Persist();
        Changed?.Invoke();
    }

    /// <summary>"Neu starten" (Ctrl+Shift+R): asks first when cards were sorted.</summary>
    public void RequestRestart()
    {
        if (Phase == DeckPhase.Empty) return;
        if (!Deck.HasProgress || !Deck.IsResumable || Confirm is null)
        {
            Restart();
            return;
        }
        Confirm("Karteikarten neu starten?", FlashcardCopy.RestartMessage(Deck), "Neu starten", () => Restart());
    }

    /// <summary>A new deck over the same cards (or, with starredOnly, over all or the starred ones).</summary>
    public void Restart(bool? starredOnly = null)
    {
        bool only = starredOnly ?? Deck.StarredOnly;
        double now = TimeUtil.NowMs();
        var fresh = new FlashcardDeck(Set.Cards, now, only, Deck.IsShuffled);
        if (fresh.Phase == DeckPhase.Empty && only) fresh = new FlashcardDeck(Set.Cards, now, false, Deck.IsShuffled);
        // Cards still leaving finish their exit; the new deck's cards are new views.
        DeckGeneration++;
        Arrival = new FlashcardArrival.FromStack();
        Swipe.Reset();
        Deck = fresh;
        StopSpeaking();
        Persist();
        Changed?.Invoke();
    }

    // MARK: Swiping

    /// <summary>Two fingers (or the mouse) start moving the current card; false when there is none.</summary>
    public bool SwipeBegan(double time)
    {
        if (Phase != DeckPhase.Card || Deck.CurrentCardID is not { } id) return false;
        Swipe.Begin(id, time);
        return true;
    }

    /// <summary>Two fingers moved the card by <paramref name="delta"/> points.</summary>
    public void SwipeMoved(double delta, double time)
    {
        if (Swipe.CardID is null || Swipe.CardID != Deck.CurrentCardID) return;
        Swipe.MoveBy(delta, time);
    }

    /// <summary>Let go: past the threshold (or flung) the card is sorted to that side, else it springs back.</summary>
    public void SwipeEnded(double time)
    {
        if (Swipe.CardID is null) return;
        if (Swipe.CardID != Deck.CurrentCardID || Phase != DeckPhase.Card || Swipe.End(time) is not { } verdict)
        {
            Swipe.Settle();
            return;
        }
        Sort(verdict, flung: true);
    }

    /// <summary>The swipe was interrupted (a popover opened): back to the middle.</summary>
    public void SwipeCancelled() => Swipe.Settle();

    /// <summary>The mouse drags the current card (FlashcardView).</summary>
    public void Drag(FlashcardDrag drag)
    {
        switch (drag)
        {
            case FlashcardDrag.Changed changed:
                if (!Swipe.IsTracking || Swipe.CardID != Deck.CurrentCardID)
                {
                    if (!SwipeBegan(changed.At)) return;
                }
                Swipe.MoveTo(changed.Translation, changed.At);
                break;
            case FlashcardDrag.Ended ended:
                SwipeEnded(ended.At);
                break;
        }
    }

    /// <summary>Back to the set (Esc, "Zurück zum Lernset").</summary>
    public void Exit()
    {
        _model.Speech.Stop();
        Persist();
        _model.BackToSet(SetId);
    }

    /// <summary>"Lernen" after the last round: the cards are tested for real there.</summary>
    public void OpenLearn()
    {
        _model.Speech.Stop();
        Persist();
        _model.Study(SetId, StudyMode.Learn);
    }

    /// <summary>"Begriffe hinzufügen" on an empty set.</summary>
    public void AddCards() => _model.Navigate(new Route.Editor(SetId));

    // MARK: Card tools

    /// <summary>🔊 (Ctrl+R): reads the side that is up.</summary>
    public void SpeakVisibleSide()
    {
        if (!_isLive || Phase != DeckPhase.Card || CurrentCard is not { } card) return;
        var side = SideOf(card, Deck.IsFlipped);
        if (string.IsNullOrWhiteSpace(side.Text) || !_model.Speech.CanSpeak(side.Lang)) return;
        _model.Speech.Speak(side.Text, side.Lang);
        IsSpeaking = true;
        Changed?.Invoke();
        // SAPI reports no end here: the speaker glows for about as long as the text takes.
        double seconds = Math.Clamp(0.6 + side.Text.Length * 0.07, 0.8, 4);
        Motion.After(seconds, StopSpeaking);
    }

    void StopSpeaking()
    {
        if (!IsSpeaking) return;
        IsSpeaking = false;
        Changed?.Invoke();
    }

    /// <summary>★ (Ctrl+D) of the current card.</summary>
    public void ToggleStar()
    {
        if (Phase != DeckPhase.Card || CurrentCard is not { } card) return;
        _model.Store.ToggleStar(SetId, card.Id);
        _model.SaveSoon();
    }

    /// <summary>✎ (Ctrl+E): the card editor saved.</summary>
    public void SaveEdit(Card card, string term, string definition)
    {
        try { _model.Store.UpdateCard(SetId, card.Id, new CardChanges(term, definition)); }
        catch (Exception e)
        {
            // Mac: model.report(error, fallback:) – the store's own message (an empty card, a card that is gone), else the fallback.
            _model.ShowToast(new ToastMessage(e is LibraryStoreError ? e.Message : "Die Karte konnte nicht gespeichert werden.", ToastTone.Danger, DurationMs: 6000));
            return;
        }
        _model.SaveSoon();
    }

    // MARK: Options

    public void SetFront(FlashcardFront front)
    {
        if (front == Front) return;
        Front = front;
        _model.Preferences.FlashcardFront = front;
        Changed?.Invoke();
    }

    public void SetShuffled(bool shuffled)
    {
        _model.Preferences.FlashcardShuffle = shuffled;
        Deck.SetShuffled(shuffled, Set.Cards.Select(c => c.Id).ToList(), TimeUtil.NowMs());
        Persist();
        Changed?.Invoke();
    }

    /// <summary>"Nur markierte": starts over with the starred cards (or all again).</summary>
    public void SetStarredOnly(bool starredOnly)
    {
        if (starredOnly == Deck.StarredOnly) return;
        Restart(starredOnly);
    }

    // MARK: Store

    /// <summary>The library changed (star, card editor, set editor): the deck follows.</summary>
    public void StoreDidChange()
    {
        if (_model.Set(SetId) is not { } newSet) return;
        Set = newSet;
        var currentID = Deck.CurrentCardID;
        if (Deck.Sync(newSet.Cards, TimeUtil.NowMs()))
        {
            // The current card was deleted: the next one rises from the stack, and a swipe of the deleted card is over.
            if (Deck.CurrentCardID != currentID)
            {
                Swipe.Reset();
                Arrival = new FlashcardArrival.FromStack();
            }
            Persist();
        }
        Changed?.Invoke();
    }

    // MARK: Helpers

    void Depart(Card card, bool showsBack, FlashcardDepartureKind kind, bool flung = false, double releaseOffset = 0)
    {
        _departureSerial++;
        var departure = new FlashcardDeparture(_departureSerial, card, showsBack, kind, flung, releaseOffset, DeckGeneration);
        // One view per card and round: a card leaving again replaces its earlier exit.
        Departures.RemoveAll(d => d.Card.Id == card.Id && d.Generation == DeckGeneration);
        Departures.Add(departure);
        // Fast sorting: only the last few are still worth drawing.
        if (Departures.Count > 3) Departures.RemoveRange(0, Departures.Count - 3);
        Motion.After(DepartureLifetime, () =>
        {
            if (Departures.RemoveAll(d => d.Id == departure.Id) > 0) Changed?.Invoke();
        });
    }

    void Persist()
    {
        if (_isLive) _model.Preferences.SaveDeck(SetId, Deck);
    }
}
