namespace Wortschatz.Core;

// Port of WriteSession.swift (src/core/session.js): the Write-mode ("Schreiben") session engine with
// Quizlet "Write" semantics.
//
// Round 1 asks every question once. A missed question is not retried within the same round; the next
// round contains only the questions missed in the previous round. This repeats until every question
// has been answered correctly once.
//
// Every function takes a SessionState and returns a NEW state; inputs are never changed. Each function
// first repairs its input (CopyState) and then mutates that private copy. Randomness comes from an
// injected RNG consumed in exactly the order of the JS (one Fisher–Yates pass when the session is
// created and one per new round), so seeded runs replay the web app's sessions bit for bit.
//
// Differences to Swift: SessionState is a class (treat it as a value, see LearnState); ids compare
// ordinally like JS; counts are int (capped at int.MaxValue instead of 2^53). Without shuffling a new
// round is sorted by `order`; a qid missing from `order` goes last (like Swift).

/// <summary>A Write question (<c>state.questions[qid]</c>). Qid is "&lt;cardId&gt;:t" (ask term) or "&lt;cardId&gt;:d".</summary>
public sealed record SessionQuestion(string Qid, string CardId, AskSide Ask) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("qid", Qid), ("cardId", CardId), ("ask", Ask.ToJson()));
}

/// <summary><c>state.setOptions</c>.</summary>
public sealed record SessionSetOptions(AnswerWith AnswerWith = AnswerWith.Term, bool Shuffle = true) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("answerWith", AnswerWith.ToJson()), ("shuffle", Shuffle));
}

/// <summary>An answer of the current round (<c>state.roundAnswered[]</c>).</summary>
public sealed record SessionAnswer(string Qid, bool Correct) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("qid", Qid), ("correct", Correct));
}

/// <summary>A closed round (<c>state.rounds[]</c>).</summary>
public sealed record SessionRound(int Round, int Total, int Correct, IReadOnlyList<string> IncorrectQids) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("round", Round), ("total", Total), ("correct", Correct), ("incorrectQids", IncorrectQids.ToJsonArray()));
}

/// <summary>
/// The JSON-serialisable Write session (<c>session:&lt;setId&gt;</c> in the web app), key for key.
/// <c>finishedAt</c> is written as explicit null while running. A class (Swift: struct): treat it as a value
/// – engine functions never change their input; change only a <see cref="WriteSession.CopyState(SessionState)"/> result.
/// </summary>
public sealed class SessionState : IJsonEncodable
{
    /// <summary>Schema version (always 1).</summary>
    public int V { get; set; } = 1;
    public SessionSetOptions SetOptions { get; set; } = new();
    public StudySubset Subset { get; set; } = StudySubset.All;
    /// <summary>qid → question.</summary>
    public Dictionary<string, SessionQuestion> Questions { get; set; } = new(StringComparer.Ordinal);
    /// <summary>Every qid in asking order of round 1.</summary>
    public List<string> Order { get; set; } = [];
    public int Round { get; set; } = 1;
    /// <summary>Remaining qids of the current round.</summary>
    public List<string> Queue { get; set; } = [];
    public List<SessionAnswer> RoundAnswered { get; set; } = [];
    public List<SessionRound> Rounds { get; set; } = [];
    /// <summary>qids answered correctly once.</summary>
    public List<string> Done { get; set; } = [];
    public Dictionary<string, int> Attempts { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, int> Misses { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, bool> FirstTry { get; set; } = new(StringComparer.Ordinal);
    /// <summary>Epoch ms.</summary>
    public double StartedAt { get; set; }
    public double UpdatedAt { get; set; }
    public double? FinishedAt { get; set; }
    /// <summary>Active study time (gaps &gt; 5 min are not counted).</summary>
    public double ElapsedMs { get; set; }

    /// <summary>A repaired state from any JSON value (<c>WriteSession.CopyState(json)</c>); never fails.</summary>
    public static SessionState FromJson(JSONValue json) => WriteSession.CopyState(json);

    public JSONValue ToJson() => JSONValue.Obj(
        ("v", V), ("setOptions", SetOptions.ToJson()), ("subset", Subset.ToJson()),
        ("questions", JSONValue.Object(Questions.Select(p => new KeyValuePair<string, JSONValue>(p.Key, p.Value.ToJson())))),
        ("order", Order.ToJsonArray()), ("round", Round), ("queue", Queue.ToJsonArray()), ("roundAnswered", RoundAnswered.ToJsonArray()),
        ("rounds", Rounds.ToJsonArray()), ("done", Done.ToJsonArray()), ("attempts", LearnJson.Map(Attempts, n => n)),
        ("misses", LearnJson.Map(Misses, n => n)), ("firstTry", LearnJson.Map(FirstTry, b => b)), ("startedAt", StartedAt),
        ("updatedAt", UpdatedAt), ("finishedAt", JSONValue.Nullable(FinishedAt)), ("elapsedMs", ElapsedMs));
}

/// <summary>Port of src/core/session.js. Every function takes a state and returns a NEW state.</summary>
public static class WriteSession
{
    /// <summary>Pauses longer than this are not counted as study time (<c>IDLE_GAP_MS</c>).</summary>
    public const double IdleGapMs = 5 * 60 * 1000;

    /// <summary><c>roundSummary(state).items[]</c>.</summary>
    public sealed record RoundSummaryItem(string Qid, string CardId, AskSide Ask, bool Correct) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("qid", Qid), ("cardId", CardId), ("ask", Ask.ToJson()), ("correct", Correct));
    }

    /// <summary><c>roundSummary(state)</c>.</summary>
    public sealed record RoundSummary(int Round, int Total, int Correct, int Incorrect, IReadOnlyList<RoundSummaryItem> Items) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("round", Round), ("total", Total), ("correct", Correct), ("incorrect", Incorrect), ("items", Items.ToJsonArray()));
    }

    /// <summary><c>counters(state)</c> ("Verbleibend / Falsch / Richtig"); Progress = done / total.</summary>
    public sealed record Counters(int Remaining, int Correct, int Incorrect, int Total, int Round, double Progress) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("remaining", Remaining), ("correct", Correct), ("incorrect", Incorrect), ("total", Total),
            ("round", Round), ("progress", Progress));
    }

    /// <summary>
    /// <c>finalStats(state)</c>. Accuracy = firstTryCorrect / total; Hardest: up to 10 cards with the most misses
    /// (both directions together); MissedCardIds: every card with a miss, in order of first appearance.
    /// </summary>
    public sealed record FinalStats(int Total, int FirstTryCorrect, double Accuracy, int Rounds, double ElapsedMs,
        IReadOnlyList<MissedCard> Hardest, IReadOnlyList<string> MissedCardIds) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("total", Total), ("firstTryCorrect", FirstTryCorrect), ("accuracy", Accuracy), ("rounds", Rounds),
            ("elapsedMs", ElapsedMs), ("hardest", Hardest.ToJsonArray()), ("missedCardIds", MissedCardIds.ToJsonArray()));
    }

    // MARK: - Creation

    /// <summary>The question id of a card and side (<c>qidFor</c>): "&lt;cardId&gt;:t" or "&lt;cardId&gt;:d".</summary>
    public static string Qid(string cardId, AskSide ask) => $"{cardId}:{(ask == AskSide.Term ? "t" : "d")}";

    /// <summary>
    /// <c>createSession(cards, { answerWith, shuffle }, { subset, rng, now, progress })</c>. Cards without an id,
    /// repeated ids (the first wins) and cards with an empty side are skipped; progress is only read by the
    /// Learning and Missed subsets. A non-finite now becomes 0.
    /// </summary>
    public static SessionState CreateSession(IReadOnlyList<Card> cards, AnswerWith answerWith, bool shuffle, StudySubset? subset = null,
        RNG? rng = null, double? now = null, IReadOnlyDictionary<string, CardProgress>? progress = null)
    {
        rng ??= Rand.SystemRNG();
        progress ??= new Dictionary<string, CardProgress>();
        double nowMs = now ?? TimeUtil.NowMs();
        var sub = NormalizeSubset(subset ?? StudySubset.All);

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var selected = new List<Card>();
        foreach (var card in cards)
        {
            if (card.Id.Length == 0 || !seen.Add(card.Id)) continue;
            // A card with an empty side cannot be asked meaningfully in either direction.
            if (!HasText(card.Term) || !HasText(card.Definition)) continue;
            if (CardInSubset(card, sub, progress)) selected.Add(card);
        }

        // Unshuffled Both: every term question first, then every definition question, so a card's two
        // directions are never asked back to back.
        AskSide[] sides = answerWith switch
        {
            AnswerWith.Both => [AskSide.Term, AskSide.Definition],
            AnswerWith.Definition => [AskSide.Definition],
            _ => [AskSide.Term],
        };
        var questions = new Dictionary<string, SessionQuestion>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var ask in sides)
        {
            foreach (var card in selected)
            {
                var id = Qid(card.Id, ask);
                questions[id] = new SessionQuestion(id, card.Id, ask);
                order.Add(id);
            }
        }

        double at = double.IsFinite(nowMs) ? nowMs : 0;
        var finalOrder = shuffle ? SeparateSiblings(Shuffled(order, rng), questions) : order;
        var zeros = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var id in finalOrder) zeros[id] = 0;
        return new SessionState
        {
            SetOptions = new SessionSetOptions(answerWith, shuffle), Subset = sub, Questions = questions, Order = finalOrder,
            Queue = [.. finalOrder], Attempts = zeros, Misses = new(zeros, StringComparer.Ordinal), StartedAt = at, UpdatedAt = at,
            FinishedAt = finalOrder.Count == 0 ? at : null,
        };
    }

    /// <summary><c>createSession</c> with full study options (reads AnswerWith and Shuffle).</summary>
    public static SessionState CreateSession(IReadOnlyList<Card> cards, StudyOptions options, StudySubset? subset = null, RNG? rng = null,
        double? now = null, IReadOnlyDictionary<string, CardProgress>? progress = null) =>
        CreateSession(cards, options.AnswerWith, options.Shuffle, subset, rng, now, progress);

    // MARK: - Repair

    /// <summary>
    /// <c>copyState</c> of session.js on raw JSON: a defensive copy that repairs missing fields and drops
    /// references to unknown qids. Accepts any JSON; a non-object gives an empty state (IsFinished).
    /// </summary>
    public static SessionState CopyState(JSONValue json)
    {
        var src = json.ObjectValue ?? new JsonObjectMap();
        JSONValue? Get(string key) => src.TryGetValue(key, out var v) ? v : null;

        var questions = new Dictionary<string, SessionQuestion>(StringComparer.Ordinal);
        foreach (var (key, value) in JsEntries(Get("questions")))
        {
            if (value.ObjectValue is null || value["cardId"] is not { } cardId || cardId.IsNull) continue;
            var ask = value["ask"]?.StringValue == "definition" ? AskSide.Definition : AskSide.Term;
            questions[key] = new SessionQuestion(key, LearnEngine.JsString(cardId), ask);
        }

        string? Known(JSONValue? v) => v?.StringValue is { } qid && questions.ContainsKey(qid) ? qid : null;
        List<string> UniqueQids(JSONValue? v) => Uniqued((v?.ArrayValue ?? []).Select(Known).OfType<string>());
        Dictionary<string, int> CountMap(JSONValue? v)
        {
            var output = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var (key, value) in JsEntries(v))
                if (questions.ContainsKey(key)) output[key] = CountValue(value);
            return output;
        }
        Dictionary<string, bool> BoolMap(JSONValue? v)
        {
            var output = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (var (key, value) in JsEntries(v))
                if (questions.ContainsKey(key) && value.BoolValue is { } b) output[key] = b;
            return output;
        }

        var opts = Get("setOptions");
        var answerWith = EnumRaw.ParseJson<AnswerWith>(opts?["answerWith"]) ?? AnswerWith.Term;
        bool shuffle = opts?["shuffle"]?.BoolValue != false;

        var roundAnswered = new List<SessionAnswer>();
        foreach (var entry in Get("roundAnswered")?.ArrayValue ?? [])
            if (entry.ObjectValue is not null && Known(entry["qid"]) is { } qid)
                roundAnswered.Add(new SessionAnswer(qid, entry["correct"]?.BoolValue == true));

        var rounds = new List<SessionRound>();
        foreach (var entry in Get("rounds")?.ArrayValue ?? [])
        {
            // Arrays pass JS's `typeof r === 'object'` filter and read like an empty object.
            JSONValue? R(string key) => entry.IsObject ? entry[key] : null;
            if (!entry.IsObject && !entry.IsArray) continue;
            rounds.Add(new SessionRound(R("round")?.IntegerValue ?? rounds.Count + 1, CountValue(R("total")), CountValue(R("correct")),
                UniqueQids(R("incorrectQids"))));
        }

        int round = Get("round")?.IntegerValue is { } r0 && r0 > 0 ? r0 : 1;
        double startedAt = Get("startedAt")?.FiniteNumber ?? 0;
        return new SessionState
        {
            SetOptions = new SessionSetOptions(answerWith, shuffle), Subset = StudySubset.FromJson(Get("subset") ?? JSONValue.Null),
            Questions = questions, Order = UniqueQids(Get("order")), Round = round, Queue = UniqueQids(Get("queue")),
            RoundAnswered = roundAnswered, Rounds = rounds, Done = UniqueQids(Get("done")), Attempts = CountMap(Get("attempts")),
            Misses = CountMap(Get("misses")), FirstTry = BoolMap(Get("firstTry")), StartedAt = startedAt,
            UpdatedAt = Get("updatedAt")?.FiniteNumber ?? startedAt, FinishedAt = Get("finishedAt")?.NumberValue,
            ElapsedMs = Math.Max(0, Get("elapsedMs")?.FiniteNumber ?? 0),
        };
    }

    /// <summary>
    /// <c>copyState</c> of session.js on a typed state: questions keyed by their own qid, every qid list keeps
    /// only known qids (each once), counts ≥ 0, round ≥ 1, timestamps finite. Always fresh collections; idempotent.
    /// </summary>
    public static SessionState CopyState(SessionState state)
    {
        var questions = new Dictionary<string, SessionQuestion>(state.Questions.Count, StringComparer.Ordinal);
        foreach (var (key, q) in state.Questions) questions[key] = new SessionQuestion(key, q.CardId, q.Ask);
        List<string> UniqueQids(IEnumerable<string> list) => Uniqued(list.Where(questions.ContainsKey));
        Dictionary<string, int> CountMap(Dictionary<string, int> map)
        {
            var output = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var (key, n) in map)
                if (questions.ContainsKey(key)) output[key] = Math.Max(0, n);
            return output;
        }
        var firstTry = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var (key, b) in state.FirstTry)
            if (questions.ContainsKey(key)) firstTry[key] = b;

        double startedAt = double.IsFinite(state.StartedAt) ? state.StartedAt : 0;
        return new SessionState
        {
            SetOptions = state.SetOptions, Subset = NormalizeSubset(state.Subset), Questions = questions, Order = UniqueQids(state.Order),
            Round = state.Round > 0 ? state.Round : 1, Queue = UniqueQids(state.Queue),
            RoundAnswered = state.RoundAnswered.Where(a => questions.ContainsKey(a.Qid)).ToList(),
            Rounds = state.Rounds.Select(r => new SessionRound(r.Round, Math.Max(0, r.Total), Math.Max(0, r.Correct), UniqueQids(r.IncorrectQids))).ToList(),
            Done = UniqueQids(state.Done), Attempts = CountMap(state.Attempts), Misses = CountMap(state.Misses), FirstTry = firstTry,
            StartedAt = startedAt, UpdatedAt = double.IsFinite(state.UpdatedAt) ? state.UpdatedAt : startedAt, FinishedAt = state.FinishedAt,
            ElapsedMs = double.IsFinite(state.ElapsedMs) ? Math.Max(0, state.ElapsedMs) : 0,
        };
    }

    // MARK: - Asking and answering

    /// <summary>The question to ask now, null when the round is over.</summary>
    public static SessionQuestion? Current(SessionState state)
    {
        var s = CopyState(state);
        return s.Queue.Count > 0 ? s.Questions.GetValueOrDefault(s.Queue[0]) : null;
    }

    /// <summary>Answers the current question (no-op when the round is over).</summary>
    public static SessionState Answer(SessionState state, bool correct, double? now = null)
    {
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (s.Queue.Count == 0) return s;
        var qid = s.Queue[0];
        AdvanceClock(s, nowMs);
        int previous = s.Attempts.GetValueOrDefault(qid);
        s.Attempts[qid] = Inc(previous);
        if (previous == 0) s.FirstTry[qid] = correct;
        if (correct)
        {
            if (!s.Done.Contains(qid)) s.Done.Add(qid);
        }
        else s.Misses[qid] = Inc(s.Misses.GetValueOrDefault(qid));
        s.Queue.RemoveAt(0);
        s.RoundAnswered.Add(new SessionAnswer(qid, correct));
        MarkFinished(s, nowMs);
        return s;
    }

    /// <summary>
    /// "Ich hatte recht": the incorrect answer of <paramref name="qid"/> in the current round becomes correct. Also works
    /// right after NextRound for a miss of the just-closed round, as long as the qid has not been answered in
    /// the new round yet. Idempotent: anything else is a no-op.
    /// </summary>
    public static SessionState Override(SessionState state, string qid, double? now = null)
    {
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (!s.Questions.ContainsKey(qid) || s.Done.Contains(qid)) return s;

        int idx = s.RoundAnswered.FindLastIndex(a => a.Qid == qid);
        if (idx >= 0)
        {
            if (s.RoundAnswered[idx].Correct) return s;
            AdvanceClock(s, nowMs);
            s.RoundAnswered[idx] = new SessionAnswer(qid, true);
            MarkCorrect(s, qid);
            if (RoundIsClosed(s))
            {
                var r = s.Rounds[^1];
                s.Rounds[^1] = r with { IncorrectQids = r.IncorrectQids.Where(x => x != qid).ToList(), Correct = Math.Min(r.Total, r.Correct + 1) };
            }
            MarkFinished(s, nowMs);
            return s;
        }

        if (s.Rounds.Count == 0 || s.Rounds[^1] is not { } lastRound || lastRound.Round != s.Round - 1 || !lastRound.IncorrectQids.Contains(qid))
            return s;
        AdvanceClock(s, nowMs);
        s.Rounds[^1] = lastRound with
        {
            IncorrectQids = lastRound.IncorrectQids.Where(x => x != qid).ToList(),
            Correct = Math.Min(lastRound.Total, lastRound.Correct + 1),
        };
        s.Queue.RemoveAll(x => x == qid);
        MarkCorrect(s, qid);
        // The new round lost its only questions: the session ended with the closed round.
        if (s.Queue.Count == 0 && s.RoundAnswered.Count == 0) s.Round = lastRound.Round;
        MarkFinished(s, nowMs);
        return s;
    }

    // MARK: - Rounds

    public static bool IsRoundOver(SessionState state) => CopyState(state).Queue.Count == 0;

    /// <summary>The current round's answers in order; Total also counts the questions still queued.</summary>
    public static RoundSummary RoundSummaryOf(SessionState state)
    {
        var s = CopyState(state);
        var items = s.RoundAnswered
            .Where(a => s.Questions.ContainsKey(a.Qid))
            .Select(a => { var q = s.Questions[a.Qid]; return new RoundSummaryItem(a.Qid, q.CardId, q.Ask, a.Correct); })
            .ToList();
        int correct = items.Count(i => i.Correct);
        return new RoundSummary(s.Round, items.Count + s.Queue.Count, correct, items.Count - correct, items);
    }

    /// <summary>
    /// Closes the finished round into <c>rounds</c> and starts the next one with the questions missed in it.
    /// When nothing is left the session is finished instead; the closed round's answers stay in
    /// <c>roundAnswered</c> for its summary. No-op while the round is running (and once it is closed).
    /// </summary>
    public static SessionState NextRound(SessionState state, RNG? rng = null, double? now = null)
    {
        rng ??= Rand.SystemRNG();
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (s.Queue.Count > 0 || RoundIsClosed(s)) return s;
        AdvanceClock(s, nowMs);

        var incorrectQids = new List<string>();
        foreach (var a in s.RoundAnswered)
            if (!a.Correct && !incorrectQids.Contains(a.Qid)) incorrectQids.Add(a.Qid);
        bool finished = AllDone(s);
        if (s.RoundAnswered.Count > 0)
        {
            int answered = s.RoundAnswered.Count;
            s.Rounds.Add(new SessionRound(s.Round, answered, answered - s.RoundAnswered.Count(a => !a.Correct), incorrectQids));
        }
        if (finished)
        {
            MarkFinished(s, nowMs);
            return s;
        }

        var done = new HashSet<string>(s.Done, StringComparer.Ordinal);
        var missed = incorrectQids.Where(q => !done.Contains(q)).ToList();
        // Safety net for inconsistent restored states: any other open question joins the next round.
        foreach (var qid in s.Order)
            if (!done.Contains(qid) && !missed.Contains(qid)) missed.Add(qid);
        s.Queue = ArrangeQueue(missed, s, rng);
        // A round without answers (only possible in a repaired state) is refilled, not counted.
        if (s.RoundAnswered.Count > 0) s.Round = Inc(s.Round);
        s.RoundAnswered = [];
        return s;
    }

    /// <summary>Every question has been answered correctly once (also true without questions).</summary>
    public static bool IsFinished(SessionState state) => AllDone(CopyState(state));

    // MARK: - Statistics

    /// <summary>"Verbleibend / Falsch / Richtig": Incorrect counts the current round only, Correct the whole session.</summary>
    public static Counters CountersOf(SessionState state)
    {
        var s = CopyState(state);
        int total = s.Order.Count;
        return new Counters(s.Queue.Count, s.Done.Count, s.RoundAnswered.Count(a => !a.Correct), total, s.Round,
            total == 0 ? 0 : (double)s.Done.Count / total);
    }

    public static FinalStats FinalStatsOf(SessionState state)
    {
        var s = CopyState(state);
        int total = s.Order.Count;
        int firstTryCorrect = s.Order.Count(q => s.FirstTry.GetValueOrDefault(q));

        // Misses per card (both directions together), in order of first appearance.
        var cardOrder = new List<string>();
        var byCard = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var qid in s.Order)
        {
            if (!s.Questions.TryGetValue(qid, out var q)) continue;
            if (!byCard.ContainsKey(q.CardId)) cardOrder.Add(q.CardId);
            byCard[q.CardId] = byCard.GetValueOrDefault(q.CardId) + s.Misses.GetValueOrDefault(qid);
        }
        var missedCards = cardOrder.Where(id => byCard[id] > 0).Select(id => new MissedCard(id, byCard[id])).ToList();
        var hardest = missedCards.Select((c, i) => (c, i)).OrderByDescending(x => x.c.Misses).ThenBy(x => x.i).Take(10).Select(x => x.c).ToList();
        return new FinalStats(total, firstTryCorrect, total == 0 ? 0 : (double)firstTryCorrect / total, total == 0 ? 0 : s.Round, s.ElapsedMs,
            hardest, missedCards.Select(c => c.CardId).ToList());
    }

    // MARK: - Changes

    /// <summary>
    /// Removes every question of a card (deleted mid-session), including its share of the closed rounds'
    /// tallies. Rounds left without any question are dropped. Unknown ids are a no-op.
    /// </summary>
    public static SessionState RemoveCard(SessionState state, string cardId, double? now = null)
    {
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        var gone = new HashSet<string>(s.Questions.Where(p => p.Value.CardId == cardId).Select(p => p.Key), StringComparer.Ordinal);
        if (gone.Count == 0) return s;
        AdvanceClock(s, nowMs);

        // Round 1 asked every question; round n asked exactly the misses of round n - 1.
        var previous = s.Rounds;
        var rounds = previous.Select((r, i) =>
        {
            int total = r.Total, correct = r.Correct;
            foreach (var qid in gone)
            {
                if (i != 0 && !previous[i - 1].IncorrectQids.Contains(qid)) continue;
                total--;
                if (!r.IncorrectQids.Contains(qid)) correct--;
            }
            total = Math.Max(0, total);
            return new SessionRound(r.Round, total, Math.Min(total, Math.Max(0, correct)), r.IncorrectQids.Where(q => !gone.Contains(q)).ToList());
        }).ToList();
        int firstEmpty = rounds.FindIndex(r => r.Total == 0);
        if (firstEmpty >= 0) rounds.RemoveRange(firstEmpty, rounds.Count - firstEmpty);
        s.Rounds = rounds;

        foreach (var qid in gone)
        {
            s.Questions.Remove(qid);
            s.Attempts.Remove(qid);
            s.Misses.Remove(qid);
            s.FirstTry.Remove(qid);
        }
        s.Order.RemoveAll(gone.Contains);
        s.Queue.RemoveAll(gone.Contains);
        s.Done.RemoveAll(gone.Contains);
        s.RoundAnswered.RemoveAll(a => gone.Contains(a.Qid));

        // The current round has nothing left: fall back to the last round that still has content.
        if (s.Queue.Count == 0 && s.RoundAnswered.Count == 0) s.Round = s.Rounds.Count > 0 ? s.Rounds[^1].Round : 1;
        MarkFinished(s, nowMs);
        return s;
    }

    /// <summary>Advances the active-time clock.</summary>
    public static SessionState Tick(SessionState state, double? now = null)
    {
        var s = CopyState(state);
        AdvanceClock(s, now ?? TimeUtil.NowMs());
        return s;
    }

    // MARK: - Internals

    static int Inc(int n) => n == int.MaxValue ? n : n + 1;

    static bool HasText(string s)
    {
        foreach (char c in s)
            if (!JSCompat.IsWhitespace(c)) return true;
        return false;
    }

    /// <summary><c>normalizeSubset</c> for a typed subset: empty card ids are dropped.</summary>
    static StudySubset NormalizeSubset(StudySubset subset) =>
        subset.Kind == StudySubsetKind.CardIds && subset.CardIdList.Any(id => id.Length == 0)
            ? StudySubset.CardIds(subset.CardIdList.Where(id => id.Length > 0))
            : subset;

    static bool CardInSubset(Card card, StudySubset subset, IReadOnlyDictionary<string, CardProgress> progress) => subset.Kind switch
    {
        StudySubsetKind.All => true,
        StudySubsetKind.Starred => card.Starred,
        StudySubsetKind.Learning => Mastery.CardStatusOf(progress.GetValueOrDefault(card.Id)) != CardStatus.Mastered,
        StudySubsetKind.Missed => progress.GetValueOrDefault(card.Id)?.LastResult == AnswerResult.Incorrect,
        _ => subset.CardIdList.Contains(card.Id),
    };

    /// <summary>Fisher–Yates on a copy, consuming the rng like the JS; tolerates values outside [0, 1) or NaN.</summary>
    static List<string> Shuffled(List<string> list, RNG rng)
    {
        var a = list.ToList();
        for (int i = a.Count - 1; i > 0; i--)
        {
            double r = Math.Floor(rng() * (i + 1));
            int j = !(r >= 0) ? 0 : r > i ? i : (int)r;
            (a[i], a[j]) = (a[j], a[i]);
        }
        return a;
    }

    /// <summary>
    /// With Both a card has two questions; avoid asking them back to back, which would give the answer away.
    /// Deterministic: only swaps/moves items, no randomness.
    /// </summary>
    static List<string> SeparateSiblings(List<string> qids, Dictionary<string, SessionQuestion> questions)
    {
        var a = qids.ToList();
        string? Card(int i) => questions.GetValueOrDefault(a[i])?.CardId;
        for (int i = 1; i < a.Count; i++)
        {
            var c = Card(i);
            if (c != Card(i - 1)) continue;
            int j = -1;
            for (int k = i + 1; k < a.Count; k++)
                if (Card(k) != c) { j = k; break; }
            if (j >= 0)
            {
                (a[i], a[j]) = (a[j], a[i]);
                continue;
            }
            // Last position: move the item to an earlier slot whose neighbours belong to other cards.
            for (int p = 0; p < i - 1; p++)
            {
                if ((p == 0 || Card(p - 1) != c) && Card(p) != c)
                {
                    var item = a[i];
                    a.RemoveAt(i);
                    a.Insert(p, item);
                    break;
                }
            }
        }
        return a;
    }

    static List<string> ArrangeQueue(List<string> qids, SessionState s, RNG rng)
    {
        if (!s.SetOptions.Shuffle)
        {
            var rank = new Dictionary<string, int>(StringComparer.Ordinal);
            for (int i = 0; i < s.Order.Count; i++) rank[s.Order[i]] = i;
            return qids.Select((q, i) => (q, i, r: rank.TryGetValue(q, out int x) ? x : int.MaxValue))
                .OrderBy(x => x.r).ThenBy(x => x.i).Select(x => x.q).ToList();
        }
        return SeparateSiblings(Shuffled(qids, rng), s.Questions);
    }

    static bool AllDone(SessionState s)
    {
        var done = new HashSet<string>(s.Done, StringComparer.Ordinal);
        return s.Order.All(done.Contains);
    }

    /// <summary>
    /// Adds active time since the last update; gaps longer than IdleGapMs are not counted. The clock stops once
    /// the session is finished, and a non-finite now leaves it untouched.
    /// </summary>
    static void AdvanceClock(SessionState s, double now)
    {
        if (s.FinishedAt is not null || !double.IsFinite(now)) return;
        double gap = now - s.UpdatedAt;
        if (gap > 0 && gap <= IdleGapMs) s.ElapsedMs += gap;
        s.UpdatedAt = now;
    }

    static void MarkFinished(SessionState s, double now)
    {
        if (s.FinishedAt is null && AllDone(s)) s.FinishedAt = double.IsFinite(now) ? now : s.UpdatedAt;
    }

    static bool RoundIsClosed(SessionState s) => s.Rounds.Count > 0 && s.Rounds[^1].Round == s.Round;

    static void MarkCorrect(SessionState s, string qid)
    {
        if (!s.Done.Contains(qid)) s.Done.Add(qid);
        s.Misses[qid] = Math.Max(0, s.Misses.GetValueOrDefault(qid) - 1);
        if (s.Attempts.GetValueOrDefault(qid) <= 1) s.FirstTry[qid] = true;
    }

    /// <summary>Each element once, first occurrence wins (<c>[...new Set(list)]</c>).</summary>
    static List<string> Uniqued(IEnumerable<string> list)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return list.Where(seen.Add).ToList();
    }

    /// <summary>
    /// <c>Object.keys(v)</c> with values for anything JS treats as an object: an object's entries, an array's
    /// elements keyed "0", "1", …; nothing for other values.
    /// </summary>
    static IEnumerable<KeyValuePair<string, JSONValue>> JsEntries(JSONValue? v)
    {
        if (v?.ObjectValue is { } o) return o;
        if (v?.ArrayValue is { } a) return a.Select((x, i) => new KeyValuePair<string, JSONValue>(i.ToString(System.Globalization.CultureInfo.InvariantCulture), x));
        return [];
    }

    /// <summary><c>Math.max(0, finite(v, 0))</c> as a count (fractional values rounded up).</summary>
    static int CountValue(JSONValue? v) =>
        v?.FiniteNumber is { } n && n > 0 ? (int)Math.Ceiling(Math.Min(n, int.MaxValue)) : 0;
}
