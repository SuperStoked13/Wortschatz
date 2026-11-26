using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App;

// Port of the Mac's LibrarySnapshot.swift: derived, read-only view data of the library, computed in one pass after a
// store change (AppModel.Library). The sidebar, the overview and the set page read it instead of asking the store
// again for every row – one progress map per set instead of one per control.

/// <summary>Everything the sidebar, the overview and the set page show (Mac: LibrarySnapshot).</summary>
public sealed class LibrarySnapshot
{
    /// <summary>Sets in store order: most recently studied or edited first.</summary>
    public IReadOnlyList<SetSummary> Sets { get; }
    /// <summary>Lernserie, Heute beantwortet, Begriffe gemeistert.</summary>
    public OverviewStats Stats { get; }
    /// <summary>"Weiterlernen": the latest unfinished Learn session, else the latest Write session.</summary>
    public ResumeItem? Resume { get; }
    /// <summary>When the snapshot was taken (epoch ms).</summary>
    public double Now { get; }

    readonly Dictionary<string, SetSummary> _byId;

    LibrarySnapshot(IReadOnlyList<SetSummary> sets, OverviewStats stats, ResumeItem? resume, double now)
    {
        Sets = sets;
        Stats = stats;
        Resume = resume;
        Now = now;
        _byId = sets.ToDictionary(s => s.Id, StringComparer.Ordinal);
    }

    public SetSummary? Summary(string? setId) => setId is not null && _byId.TryGetValue(setId, out var s) ? s : null;

    public bool IsEmpty => Sets.Count == 0;

    public static LibrarySnapshot Build(LibraryStore store, double? nowMs = null)
    {
        double now = nowMs ?? TimeUtil.NowMs();
        var activity = store.GetActivity();
        var streak = Mastery.StudyStreakOf(activity.ToDictionary(p => p.Key, p => (double)p.Value), now);
        int mastered = 0, total = 0;
        SetSummary? latestLearn = null, latestWrite = null;
        var summaries = new List<SetSummary>();
        foreach (var set in store.ListSets())
        {
            var summary = new SetSummary(set, store, now);
            mastered += summary.Stats.Mastered;
            total += summary.Stats.Total;
            if (summary.Learn is { } learn && learn.UpdatedAt > (latestLearn?.Learn?.UpdatedAt ?? double.NegativeInfinity)) latestLearn = summary;
            if (summary.Write is { } write && write.UpdatedAt > (latestWrite?.Write?.UpdatedAt ?? double.NegativeInfinity)) latestWrite = summary;
            summaries.Add(summary);
        }
        ResumeItem? resume = latestLearn is not null ? new ResumeItem(latestLearn, StudyMode.Learn)
            : latestWrite is not null ? new ResumeItem(latestWrite, StudyMode.Write) : null;
        return new LibrarySnapshot(summaries, new OverviewStats(streak, WeekTotal(activity, now, store.TimeZone), mastered, total), resume, now);
    }

    /// <summary>Answers over the last seven calendar days including today (<c>weekTotal</c> of dashboard.js).</summary>
    static int WeekTotal(Dictionary<string, int> activity, double now, TimeZoneInfo timeZone)
    {
        if (Mastery.DayNumber(TimeUtil.DateKey(now, timeZone)) is not { } today) return 0;
        int sum = 0;
        for (int offset = 0; offset < 7; offset++)
            if (activity.TryGetValue(TimeUtil.DateKeyOfDay(today - offset), out var n) && n > 0) sum += n;
        return sum;
    }
}

/// <summary>The statistics strip of the overview.</summary>
public sealed record OverviewStats(StudyStreak Streak, int Week, int Mastered, int Total);

/// <summary>"Weiterlernen" on the overview: the set and whether Lernen or Schreiben runs.</summary>
public sealed record ResumeItem(SetSummary Summary, StudyMode Mode);

/// <summary>One set with its progress and running sessions (Mac: SetSummary).</summary>
public sealed class SetSummary
{
    /// <summary>From this many wrong answers (in total) a card counts as difficult.</summary>
    public const int DifficultMistakes = 4;

    public VocabSet Set { get; }
    public string Id => Set.Id;
    /// <summary>Stored progress of the set's cards.</summary>
    public IReadOnlyDictionary<string, CardProgress> Progress { get; }
    public SetProgress Stats { get; }
    public int Starred { get; }
    /// <summary>Cards answered wrong at least DifficultMistakes times, most mistakes first, then in card order.</summary>
    public IReadOnlyList<string> DifficultCardIds { get; }
    public LearnResume? Learn { get; }
    public WriteResume? Write { get; }
    /// <summary>The set's effective study options (settings defaults merged with the set's own).</summary>
    public StudyOptions Options { get; }
    /// <summary>Whether "Fortschritt zurücksetzen" has anything to reset.</summary>
    public bool CanReset { get; }

    public bool IsEmpty => Set.Cards.Count == 0;
    public bool IsAllMastered => Stats.Total > 0 && Stats.Mastered == Stats.Total;

    public SetSummary(VocabSet set, LibraryStore store, double now)
    {
        Set = set;
        var progress = store.GetProgress(set.Id);
        Progress = progress;
        Stats = Mastery.SetProgressOf(set, progress);
        Starred = set.Cards.Count(c => c.Starred);
        DifficultCardIds = set.Cards
            .Select((c, i) => (c.Id, Position: i, Mistakes: progress.TryGetValue(c.Id, out var p) ? p.Incorrect : 0))
            .Where(x => x.Mistakes >= DifficultMistakes)
            .OrderByDescending(x => x.Mistakes).ThenBy(x => x.Position)
            .Select(x => x.Id).ToList();
        Options = store.GetStudyOptions(set.Id);
        var session = store.GetSession(set.Id);
        var learn = store.GetLearn(set.Id);
        CanReset = progress.Count > 0 || session is not null || learn is not null;
        Write = session is null ? null : WriteResume.Of(session);
        Learn = learn is null ? null : LearnResume.Of(learn, progress, now);
    }

    public CardStatus StatusOf(Card card) => Mastery.CardStatusOf(Progress.GetValueOrDefault(card.Id));

    public int MistakesOf(Card card) => Progress.TryGetValue(card.Id, out var p) ? p.Incorrect : 0;
}

/// <summary>A running Learn session (Mac: LearnResume).</summary>
public sealed class LearnResume
{
    public LearnState State { get; }
    public LearnEngine.Counts Counts { get; }
    public int Round { get; }
    /// <summary>The round is over but the checkpoint was not dismissed yet ("Runde 3 geschafft").</summary>
    public bool RoundOver { get; }

    public double UpdatedAt => State.UpdatedAt;
    public StudySubset Subset => State.Subset;
    public bool HasAnswers => State.Rounds.Count > 0 || State.Answered > 0;

    LearnResume(LearnState state, LearnEngine.Counts counts)
    {
        State = state;
        Counts = counts;
        Round = state.Round > 0 ? state.Round : 1;
        RoundOver = LearnEngine.IsRoundOver(state) && LearnEngine.CheckpointOf(state).Answered > 0;
    }

    public static LearnResume? Of(LearnState stored, IReadOnlyDictionary<string, CardProgress> progress, double now)
    {
        if (stored.FinishedAt is not null) return null;
        var state = LearnEngine.SyncProgress(stored, progress, now);
        var counts = LearnEngine.CountsOf(state);
        if (counts.Total <= 0 || LearnEngine.IsFinished(state)) return null;
        return new LearnResume(state, counts);
    }

    /// <summary>"Runde 3" or "Runde 3 geschafft".</summary>
    public string RoundText => RoundOver ? L($"Runde {Round} geschafft") : L($"Runde {Round}");
    /// <summary>"18 von 52 gemeistert".</summary>
    public string MasteredText => L($"{Counts.Mastered} von {Counts.Total} gemeistert");
    /// <summary>"Nur markierte · Runde 3 · 18 von 52 gemeistert".</summary>
    public string Detail => StudyCopy.Join(StudyCopy.SubsetLabel(Subset, L("Ausgewählte Begriffe")), RoundText, MasteredText);

    /// <summary>"Runde 3 · 18/52" or "Runde 3 · 0/3 markierte" (one whole text per subset, Mac: shortDetail).</summary>
    public string ShortDetail
    {
        get
        {
            int mastered = Counts.Mastered, total = Counts.Total;
            string count = Subset.Kind switch
            {
                StudySubsetKind.Starred => L($"{mastered}/{total} markierte"),
                StudySubsetKind.Learning => L($"{mastered}/{total} offene"),
                StudySubsetKind.Missed => L($"{mastered}/{total} falsche"),
                StudySubsetKind.CardIds => L($"{mastered}/{total} ausgewählte"),
                _ => $"{mastered}/{total}",
            };
            return $"{RoundText} · {count}";
        }
    }
    public double ProgressValue => Counts.Progress;
}

/// <summary>A running Write session (Mac: WriteResume).</summary>
public sealed class WriteResume
{
    public SessionState State { get; }
    public WriteSession.Counters Counters { get; }

    public double UpdatedAt => State.UpdatedAt;
    public StudySubset Subset => State.Subset;
    public bool HasAnswers => State.Rounds.Count > 0 || State.RoundAnswered.Count > 0;

    WriteResume(SessionState state, WriteSession.Counters counters)
    {
        State = state;
        Counters = counters;
    }

    public static WriteResume? Of(SessionState state)
    {
        if (state.FinishedAt is not null) return null;
        var counters = WriteSession.CountersOf(state);
        return counters.Total > 0 ? new WriteResume(state, counters) : null;
    }

    /// <summary>"Runde 2 · 5 übrig" or "Runde 2 geschafft".</summary>
    public string RoundText => Counters.Remaining == 0 ? L($"Runde {Counters.Round} geschafft") : L($"Runde {Counters.Round} · {Counters.Remaining} übrig");

    public string Detail
    {
        get
        {
            var parts = new List<string?> { StudyCopy.SubsetLabel(Subset, L("Falsche Begriffe")) };
            if (Counters.Remaining > 0)
            {
                parts.Add(L($"Runde {Counters.Round}"));
                parts.Add(L($"{Counters.Remaining} übrig"));
            }
            else
            {
                parts.Add(L($"Runde {Counters.Round} geschafft"));
                if (Counters.Incorrect > 0) parts.Add(L($"{Counters.Incorrect} zum Wiederholen"));
            }
            return StudyCopy.Join([.. parts]);
        }
    }

    public string ShortDetail => Counters.Remaining > 0 ? L($"{Counters.Remaining} übrig") : L("Runde geschafft");
    public double ProgressValue => Counters.Progress;
}

/// <summary>Copy shared by the overview, the sidebar and the set page, in the app's language (Mac: StudyCopy).</summary>
public static class StudyCopy
{
    public static string? SubsetLabel(StudySubset subset, string objectLabel) => subset.Kind switch
    {
        StudySubsetKind.Starred => L("Nur markierte"),
        StudySubsetKind.Learning => L("Nur nicht gemeisterte"),
        StudySubsetKind.Missed => L("Nur falsche"),
        StudySubsetKind.CardIds => objectLabel,
        _ => null,
    };

    /// <summary>Parts joined by " · "; each part keeps its spaces unbreakable so a line only wraps between parts.</summary>
    public static string Join(params string?[] parts) =>
        string.Join(" · ", parts.Where(p => !string.IsNullOrEmpty(p)).Select(p => p!.Replace(' ', ' ')));

    public static string Terms(int n) => Labels.Plural(n, "Begriff", "Begriffe");

    public static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpper(text[0]) + text[1..];

    /// <summary>
    /// Lower case, no accents, single spaces: the search form of the sidebar and the set page (Mac: StudyCopy.fold),
    /// "Ecole  normale" finds "école normale". Remembered per text: a search folds every title, term and definition on
    /// each key typed into it.
    /// </summary>
    public static string Fold(string text)
    {
        lock (Folded)
            if (Folded.TryGetValue(text, out var known)) return known;
        var result = string.Join(' ', JSCompat.Lower(TextNormalizer.StripDiacritics(text)).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        lock (Folded)
        {
            if (Folded.Count >= 50_000) Folded.Clear();
            Folded[text] = result;
        }
        return result;
    }

    /// <summary>The texts folded so far (Mac: StudyCopy.folded, cleared at 50 000 like there).</summary>
    static readonly Dictionary<string, string> Folded = new(StringComparer.Ordinal);
}
