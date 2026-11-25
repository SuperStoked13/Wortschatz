using Wortschatz.Core;
using Xunit;
using Effect = Wortschatz.Core.WriteFlow.Effect;

namespace Wortschatz.Core.Tests;

// Port of WriteFlowTestSupport.swift.

/// <summary>A mutable clock shared by a test driver and its store.</summary>
public sealed class TestClock(double now)
{
    public double Now { get; set; } = now;
}

/// <summary>
/// Drives WriteFlow like the app does: every event goes through Reduce with the current time, a seeded RNG and
/// the store's progress, and the effects are performed on a real LibraryStore (memory backend). Timers are
/// collected and fired on request.
/// </summary>
public sealed class WriteFlowDriver
{
    public const double T0 = 1_760_000_000_000;

    public LibraryStore Store { get; }
    public string SetId { get; }
    public TestClock Clock { get; }
    readonly RNG rng;
    public WriteFlow.State State { get; private set; }
    /// <summary>The effects of the last event.</summary>
    public List<Effect> Effects { get; private set; } = [];
    /// <summary>Every effect so far.</summary>
    public List<Effect> Log { get; } = [];
    /// <summary>Scheduled auto-advance timers (token, due time).</summary>
    public List<(int Token, double Due)> Timers { get; } = [];
    public int Exits { get; private set; }
    public int EditorRequests { get; private set; }

    public double Now => Clock.Now;
    public WriteFlow.Phase Phase => State.Phase;
    public WriteFlow.Question? Question => State.Question;
    public SessionState? Session => State.Session;
    public WriteFlow.Env Env => new(Clock.Now, rng, Store.GetProgress(SetId));

    /// <summary>A set with cards in a fresh store; Write mode opens on it right away (unless open is false).</summary>
    public WriteFlowDriver(IReadOnlyList<Card> cards, Lang termLang = Lang.Fr, Lang defLang = Lang.De, StudyOptionsPatch? options = null,
        uint seed = 1, StudySubset? subset = null, bool open = true)
    {
        Clock = new TestClock(T0);
        var clock = Clock;
        Store = new LibraryStore(new MemoryBackend(), now: () => clock.Now);
        var set = Store.CreateSet("Personen", termLang: termLang, defLang: defLang);
        // UpdateSet keeps the card ids (CreateSet makes new ones).
        Store.UpdateSet(set.Id, new SetPatch(Cards: cards.Select(CardDraft.FromCard).ToList()));
        Store.UpdateStudyOptions(set.Id, options ?? new StudyOptionsPatch(Shuffle: false));
        SetId = set.Id;
        rng = Rand.Mulberry32(seed);
        State = WriteFlow.Start(null, StudyOptions.Default, (SessionState?)null, new WriteFlow.Env(0)).State;
        if (open) Open(subset);
    }

    /// <summary>Another Write screen on the same store (leaving and coming back, or a relaunch).</summary>
    WriteFlowDriver(LibraryStore store, string setId, TestClock clock, uint seed)
    {
        Store = store;
        SetId = setId;
        Clock = clock;
        rng = Rand.Mulberry32(seed);
        State = WriteFlow.Start(null, StudyOptions.Default, (SessionState?)null, new WriteFlow.Env(0)).State;
    }

    /// <summary>Opens Write mode from what the store holds (WriteFlow.Start).</summary>
    public List<Effect> Open(StudySubset? subset = null, bool forceNew = false, double? marker = null, double after = 1000, KeptOptions? kept = null)
    {
        Clock.Now += after;
        var (s, fx) = WriteFlow.Start(Store.GetSet(SetId), Store.GetStudyOptions(SetId), Store.GetSessionJSON(SetId), Env, subset, forceNew, marker, kept);
        State = s;
        Record(fx);
        return fx;
    }

    /// <summary>A new driver on the same store, opened after ms (the old screen is gone).</summary>
    public WriteFlowDriver Reopen(uint seed = 2, StudySubset? subset = null, bool forceNew = false, double? marker = null, double after = 60_000,
        KeptOptions? kept = null)
    {
        var d = new WriteFlowDriver(Store, SetId, Clock, seed);
        d.Open(subset, forceNew, marker, after, kept);
        return d;
    }

    public List<Effect> Send(WriteFlow.Event e, double after = 400)
    {
        Clock.Now += after;
        var (s, fx) = WriteFlow.Reduce(State, e, Env);
        State = s;
        Record(fx);
        return fx;
    }

    public List<Effect> Press(KeyInput key, bool isRepeat = false, double after = 400) => Send(new WriteFlow.Event.Key(key, isRepeat), after);

    public void Type(string text) => Send(new WriteFlow.Event.InputChanged(text), 50);

    /// <summary>Types text and presses Return.</summary>
    public List<Effect> Answer(string text)
    {
        Type(text);
        return Press(KeyInput.Return);
    }

    /// <summary>Types the expected answer and presses Return.</summary>
    public List<Effect> AnswerCorrectly() => Answer(State.Question?.Expected ?? "");

    /// <summary>Fires the latest scheduled auto-advance when it is due.</summary>
    public List<Effect> FireTimer()
    {
        if (Timers.Count == 0) return [];
        var timer = Timers[^1];
        return Send(new WriteFlow.Event.AutoAdvanceFired(timer.Token), Math.Max(0, timer.Due - Clock.Now));
    }

    /// <summary>The stored session and its open miss, as the next screen would read them.</summary>
    public (SessionState Session, WriteFlow.PendingFeedback? Feedback)? Stored => WriteFlow.DecodeStored(Store.GetSessionJSON(SetId));

    public Dictionary<string, CardProgress> Progress => Store.GetProgress(SetId);

    public List<(SessionState Session, WriteFlow.PendingFeedback? Feedback)> Saves(List<Effect>? fx = null) =>
        (fx ?? Effects).OfType<Effect.SaveSession>().Select(e => (e.Session, e.Feedback)).ToList();

    public List<string> Announcements(List<Effect>? fx = null) => (fx ?? Effects).OfType<Effect.Announce>().Select(a => a.Text).ToList();

    void Record(List<Effect> fx)
    {
        Effects = fx;
        Log.AddRange(fx);
        foreach (var effect in fx)
        {
            switch (effect)
            {
                case Effect.RecordAnswer r: Store.RecordAnswer(SetId, r.CardId, r.Correct, r.At); break;
                case Effect.OverrideLastAnswer o: Store.OverrideLastAnswer(SetId, o.CardId); break;
                case Effect.SaveSession s: Store.SaveSessionJSON(SetId, WriteFlow.StoredJSON(s.Session, s.Feedback)); break;
                case Effect.UpdateCard u: Store.UpdateCard(SetId, u.Card.Id, new CardChanges(u.Card.Term, u.Card.Definition)); break;
                case Effect.ToggleStar t: Store.ToggleStar(SetId, t.CardId); break;
                case Effect.ScheduleAutoAdvance a: Timers.Add((a.Token, Clock.Now + a.Ms)); break;
                case Effect.Exit: Exits++; break;
                case Effect.EditSet: EditorRequests++; break;
            }
        }
    }
}

/// <summary>Cards for flow tests.</summary>
public static class WriteFlowSamples
{
    /// <summary>The user's 52 pairs (Website/tests/fixtures/user-example.txt: alternating term and definition lines).</summary>
    public static readonly List<Card> UserCards = LoadUserCards();

    static List<Card> LoadUserCards()
    {
        var path = Path.Combine(Fixtures.Dir, "..", "..", "..", "..", "..", "..", "Website", "tests", "fixtures", "user-example.txt");
        var lines = File.ReadAllText(path).Split('\n', '\r').Select(JSCompat.Trim).Where(l => l.Length > 0).ToList();
        var cards = new List<Card>();
        for (int i = 0; i + 1 < lines.Count; i += 2) cards.Add(new Card($"u{i / 2 + 1}", lines[i], lines[i + 1]));
        return cards;
    }

    /// <summary>Small set with synonyms (write-model.test.js).</summary>
    public static readonly List<Card> Personen =
    [
        new("laid", "laid, laide", "hässlich"),
        new("moche", "moche", "hässlich"),
        new("brave", "brave", "lieb"),
        new("gentil", "gentil, gentille", "lieb, nett"),
        new("chat", "le chat", "die Katze"),
        new("dash", "le pluriel", "-"),
    ];

    public static List<Card> Three() =>
    [
        new("a", "le chat", "die Katze"),
        new("b", "le chien", "der Hund", true),
        new("c", "la maison", "das Haus"),
    ];
}
