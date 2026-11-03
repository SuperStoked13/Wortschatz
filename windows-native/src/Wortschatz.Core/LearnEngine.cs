namespace Wortschatz.Core;

// Port of LearnEngine.swift (src/core/learn.js): the Learn-mode ("Lernen") engine with Quizlet Learn
// semantics.
//
// Every card in scope has a stage derived from its persistent streak: 0 = new or reset (asked as
// multiple choice), 1 = familiar (asked written), 2 = mastered (not asked any more). A correct answer
// moves the card up one stage, a wrong one sends it back to stage 0.
//
// The session works in rounds over an active batch of up to `roundSize` unmastered cards: one question
// per card in shuffled order, plus one retry at the end of the round for a card answered wrong. The next
// round drops the mastered cards from the batch and refills it (stage-1 cards first, then stage-0 cards
// in order) until every card in scope is mastered.
//
// Every function takes a LearnState and returns a NEW state; inputs are never changed. Each function
// first repairs its input (CopyState), which also makes the private copy the function then mutates.
// Randomness comes from an injected RNG consumed in exactly the order of the JS, so seeded runs replay
// the web app's sessions bit for bit (LearnEngineParityTests). Multiple-choice options are generated
// when a question is created and stored in the state, so a resumed session shows identical options.
//
// Differences to Swift: LearnState is a class (Swift: struct); treat it as a value (see LearnState).
// Ids are compared ordinally like JS (Swift: canonical equivalence). Counts are int, capped at
// int.MaxValue (Swift/JS: 2^53) – stored states never come near that.

/// <summary>Question type: multiple choice (stage 0) or written (stage 1).</summary>
public enum QuestionType { Mc, Written }

/// <summary>A multiple-choice option: the answer text of card <c>CardId</c>.</summary>
public sealed record Choice(string CardId, string Text) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("cardId", CardId), ("text", Text));
}

/// <summary>
/// A queued question as stored in the state (<c>state.queue[]</c>). <c>Choices</c> only for Mc;
/// <c>RetryChoices</c> (options for a re-queue after a miss) only when multiple choice is possible.
/// Null lists are omitted in JSON, like JS. Qid: "&lt;round&gt;.1:&lt;cardId&gt;" (main question),
/// ".2:" (retry after a miss), ".3:" (repetition question).
/// </summary>
public sealed record LearnQueueQuestion(
    string Qid, string CardId, QuestionType Type, AskSide Ask, IReadOnlyList<Choice>? Choices = null,
    IReadOnlyList<Choice>? RetryChoices = null) : IJsonEncodable
{
    public JSONValue ToJson()
    {
        var map = new JsonObjectMap
        {
            ["qid"] = Qid, ["cardId"] = CardId, ["type"] = Type.ToJson(), ["ask"] = Ask.ToJson(),
        };
        if (Choices is not null) map["choices"] = Choices.ToJsonArray();
        if (RetryChoices is not null) map["retryChoices"] = RetryChoices.ToJsonArray();
        return JSONValue.Object(map);
    }
}

/// <summary>An answer of the current round (<c>state.roundLog[]</c>). <c>Qid</c> may be absent in old states.</summary>
public sealed record LearnRoundLogEntry(string? Qid, string CardId, QuestionType Type, AskSide Ask, bool Correct, int StageAfter) : IJsonEncodable
{
    public JSONValue ToJson()
    {
        var map = new JsonObjectMap();
        if (Qid is not null) map["qid"] = Qid;
        map["cardId"] = CardId;
        map["type"] = Type.ToJson();
        map["ask"] = Ask.ToJson();
        map["correct"] = Correct;
        map["stageAfter"] = StageAfter;
        return JSONValue.Object(map);
    }
}

/// <summary>A closed round (<c>state.rounds[]</c>); <c>CardIds</c> is the round's batch.</summary>
public sealed record LearnRoundRecord(int Round, int Answered, int Correct, IReadOnlyList<string> CardIds) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("round", Round), ("answered", Answered), ("correct", Correct), ("cardIds", CardIds.ToJsonArray()));
}

/// <summary>The last answer (<c>state.last</c>), for "Ich hatte recht".</summary>
public sealed record LearnLastAnswer(string Qid, string CardId, QuestionType Type, AskSide Ask, bool Correct, int StageBefore) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(
        ("qid", Qid), ("cardId", CardId), ("type", Type.ToJson()), ("ask", Ask.ToJson()), ("correct", Correct), ("stageBefore", StageBefore));
}

/// <summary><c>state.learn</c>: the normalised Learn options of the session (no <c>retype</c>, a UI option).</summary>
public sealed record LearnSessionOptions(int RoundSize = 7, bool Mc = true, bool Written = true) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("roundSize", RoundSize), ("mc", Mc), ("written", Written));
}

/// <summary>
/// <c>state.review</c>: repetition questions (Wiederholungsfragen, a Mac option the web app lacks). The
/// cards mastered when the session started are asked once more, a few per round next to the cards being
/// learned (a whole round once nothing is left to learn), the ones answered longest ago first. A wrong
/// answer sends a card back to stage 0.
/// </summary>
public sealed class LearnReview : IJsonEncodable
{
    /// <summary>Mastered cards still to be asked again, the most overdue first.</summary>
    public List<string> Due { get; set; } = [];
    /// <summary>cardId → whether its repetition question was answered right (the first answer counts).</summary>
    public Dictionary<string, bool> Results { get; set; } = new(StringComparer.Ordinal);

    public LearnReview Clone() => new() { Due = [.. Due], Results = new(Results, StringComparer.Ordinal) };

    public JSONValue ToJson() => JSONValue.Obj(("due", Due.ToJsonArray()), ("results", LearnJson.Map(Results, b => b)));
}

/// <summary>
/// The JSON-serialisable Learn session (<c>learn:&lt;setId&gt;</c> in the web app), key for key. <c>last</c> and
/// <c>finishedAt</c> are written as explicit null; <c>review</c> only when present.
/// <para>
/// A class here (Swift: struct). Treat it as a value: engine functions never change their input and
/// return a new state; do not modify a state you passed to or got from the engine. Build changed states
/// only on a <see cref="LearnEngine.CopyState(LearnState)"/> result (that is what the engine does).
/// </para>
/// Stages: 0 = new/reset (multiple choice), 1 = familiar (written), 2 = mastered.
/// </summary>
public sealed class LearnState : IJsonEncodable
{
    /// <summary>Schema version (always 1).</summary>
    public int V { get; set; } = 1;
    public StudySubset Subset { get; set; } = StudySubset.All;
    public AnswerWith AnswerWith { get; set; } = AnswerWith.Term;
    public LearnSessionOptions Learn { get; set; } = new();
    /// <summary>Card ids in scope, shuffled once at creation.</summary>
    public List<string> Order { get; set; } = [];
    /// <summary>cardId → stage 0…2.</summary>
    public Dictionary<string, int> Stage { get; set; } = new(StringComparer.Ordinal);
    /// <summary>Cards mastered before the session started.</summary>
    public List<string> InitiallyMastered { get; set; } = [];
    /// <summary>cardId → true once answered (ever).</summary>
    public Dictionary<string, bool> Seen { get; set; } = new(StringComparer.Ordinal);
    /// <summary>The current batch (≤ roundSize unmastered cards).</summary>
    public List<string> Active { get; set; } = [];
    public int Round { get; set; } = 1;
    public List<LearnQueueQuestion> Queue { get; set; } = [];
    /// <summary>cardId → true when its retry was queued this round.</summary>
    public Dictionary<string, bool> Retried { get; set; } = new(StringComparer.Ordinal);
    public List<LearnRoundLogEntry> RoundLog { get; set; } = [];
    public List<LearnRoundRecord> Rounds { get; set; } = [];
    public int Answered { get; set; }
    public int Correct { get; set; }
    public Dictionary<string, int> Misses { get; set; } = new(StringComparer.Ordinal);
    public LearnLastAnswer? Last { get; set; }
    /// <summary>Epoch ms.</summary>
    public double StartedAt { get; set; }
    public double UpdatedAt { get; set; }
    public double? FinishedAt { get; set; }
    /// <summary>Active study time (gaps &gt; 5 min are not counted).</summary>
    public double ElapsedMs { get; set; }
    /// <summary>The repetition questions; null without them (always for the web app's states).</summary>
    public LearnReview? Review { get; set; }

    /// <summary>A repaired state from any JSON value (<c>LearnEngine.CopyState(json)</c>); never fails.</summary>
    public static LearnState FromJson(JSONValue json) => LearnEngine.CopyState(json);

    public JSONValue ToJson()
    {
        var map = new JsonObjectMap
        {
            ["v"] = V,
            ["subset"] = Subset.ToJson(),
            ["answerWith"] = AnswerWith.ToJson(),
            ["learn"] = Learn.ToJson(),
            ["order"] = Order.ToJsonArray(),
            ["stage"] = LearnJson.Map(Stage, n => n),
            ["initiallyMastered"] = InitiallyMastered.ToJsonArray(),
            ["seen"] = LearnJson.Map(Seen, b => b),
            ["active"] = Active.ToJsonArray(),
            ["round"] = Round,
            ["queue"] = Queue.ToJsonArray(),
            ["retried"] = LearnJson.Map(Retried, b => b),
            ["roundLog"] = RoundLog.ToJsonArray(),
            ["rounds"] = Rounds.ToJsonArray(),
            ["answered"] = Answered,
            ["correct"] = Correct,
            ["misses"] = LearnJson.Map(Misses, n => n),
            ["last"] = Last.ToJsonOrNull(),
            ["startedAt"] = StartedAt,
            ["updatedAt"] = UpdatedAt,
            ["finishedAt"] = JSONValue.Nullable(FinishedAt),
            ["elapsedMs"] = ElapsedMs,
        };
        if (Review is not null) map["review"] = Review.ToJson();
        return JSONValue.Object(map);
    }
}

internal static class LearnJson
{
    public static JSONValue Map<T>(IEnumerable<KeyValuePair<string, T>> map, Func<T, JSONValue> value) =>
        JSONValue.Object(map.Select(p => new KeyValuePair<string, JSONValue>(p.Key, value(p.Value))));
}

/// <summary>Port of src/core/learn.js. Every function takes a state and returns a NEW state.</summary>
public static class LearnEngine
{
    /// <summary><c>DEFAULT_LEARN</c> (= <c>DEFAULT_STUDY_OPTIONS.learn</c>).</summary>
    public static readonly LearnOptions DEFAULT_LEARN = LearnOptions.Default;
    /// <summary>Number of options of a multiple-choice question.</summary>
    public const int MAX_CHOICES = 4;
    /// <summary>Pauses longer than this are not counted as study time (<c>IDLE_GAP_MS</c>).</summary>
    public const double IdleGapMs = 5 * 60 * 1000;
    /// <summary>The stage of a mastered card (<c>MASTERY_STREAK</c>).</summary>
    public const int MasteredStage = Mastery.MASTERY_STREAK;

    /// <summary>The public view of a question (<c>current(state)</c>): <c>Choices</c> only for Mc.</summary>
    public sealed record Question(string Qid, string CardId, QuestionType Type, AskSide Ask, IReadOnlyList<Choice>? Choices = null) : IJsonEncodable
    {
        /// <summary>A repetition question (Wiederholungsfrage) of a card mastered before the session.</summary>
        public bool IsReview => IsReviewQuestion(Qid);

        public JSONValue ToJson()
        {
            var map = new JsonObjectMap { ["qid"] = Qid, ["cardId"] = CardId, ["type"] = Type.ToJson(), ["ask"] = Ask.ToJson() };
            if (Choices is not null) map["choices"] = Choices.ToJsonArray();
            return JSONValue.Object(map);
        }
    }

    /// <summary><c>counts(state)</c> (progress capsule: Neu · Am Lernen · Gemeistert); Progress = mastered / total.</summary>
    public sealed record Counts(int Fresh, int Learning, int Mastered, int Total, double Progress) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("fresh", Fresh), ("learning", Learning), ("mastered", Mastered), ("total", Total), ("progress", Progress));
    }

    /// <summary><c>checkpoint(state).counts</c> (no <c>progress</c> key).</summary>
    public sealed record CheckpointCounts(int Fresh, int Learning, int Mastered, int Total) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("fresh", Fresh), ("learning", Learning), ("mastered", Mastered), ("total", Total));
    }

    /// <summary>A card of the round in <c>checkpoint(state).items</c>: current stage and the round's answers in order.</summary>
    public sealed record CheckpointItem(string CardId, int Stage, IReadOnlyList<bool> Results) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("cardId", CardId), ("stage", Stage), ("results", JSONValue.Array(Results.Select(JSONValue.Bool))));
    }

    /// <summary><c>checkpoint(state)</c>: summary of the current (just finished) round.</summary>
    public sealed record Checkpoint(int Round, int Answered, int Correct, IReadOnlyList<CheckpointItem> Items, CheckpointCounts Counts) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(
            ("round", Round), ("answered", Answered), ("correct", Correct), ("items", Items.ToJsonArray()), ("counts", Counts.ToJson()));
    }

    /// <summary>
    /// <c>finalStats(state)</c>. AlreadyMastered: cards mastered before the session (and still so);
    /// Accuracy: correct / answered; Hardest: up to 10 cards with the most misses ("Am häufigsten falsch").
    /// </summary>
    public sealed record FinalStats(int Total, int Mastered, int AlreadyMastered, int Rounds, int Answered, double Accuracy,
        double ElapsedMs, IReadOnlyList<MissedCard> Hardest) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(
            ("total", Total), ("mastered", Mastered), ("alreadyMastered", AlreadyMastered), ("rounds", Rounds), ("answered", Answered),
            ("accuracy", Accuracy), ("elapsedMs", ElapsedMs), ("hardest", Hardest.ToJsonArray()));
    }

    /// <summary><c>reviewStats(state)</c>: asked so far, still known (kept), still to come (left).</summary>
    public sealed record ReviewStats(int Asked, int Kept, int Left) : IJsonEncodable
    {
        public JSONValue ToJson() => JSONValue.Obj(("asked", Asked), ("kept", Kept), ("left", Left));
    }

    // MARK: - Multiple-choice options

    /// <summary>
    /// Up to <paramref name="n"/> options for <paramref name="card"/> asked on <paramref name="ask"/>: the correct answer at a
    /// uniformly random position plus distinct wrong answers of other (non-synonym) cards. [] when the card has
    /// no id or no answer text; a non-positive n means MAX_CHOICES.
    /// </summary>
    public static List<Choice> BuildChoices(IReadOnlyList<Card> cards, Card card, AskSide ask, RNG? rng = null, int n = MAX_CHOICES)
    {
        rng ??= Rand.SystemRNG();
        if (card.Id.Length == 0) return [];
        var correctText = JSCompat.Trim(Synonyms.AnswerSide(card, ask));
        if (TextNormalizer.NormalizeBasic(correctText).Length == 0) return [];
        int size = n >= 1 ? n : MAX_CHOICES;
        var correct = new Choice(card.Id, correctText);
        if (size == 1) return [correct];

        var candidates = Distractors(CardList(cards), card, ask);
        var choices = Shuffled(candidates, rng).Take(size - 1).ToList();
        // The correct option's position is uniform over all slots.
        choices.Insert(RandomIndex(rng, choices.Count + 1), correct);
        return choices;
    }

    // MARK: - Creation

    /// <summary>min(streak, 2) of the card's progress.</summary>
    public static int StageFromProgress(CardProgress? progress) => Math.Min(Mastery.NormalizeProgress(progress).Streak, MasteredStage);

    /// <summary>
    /// <c>createLearn(cards, { answerWith, learn }, { subset, progress, rng, now })</c>. Cards without an id,
    /// repeated ids (the first wins) and cards with an empty side are skipped; options come from every
    /// askable card of <paramref name="cards"/>. A non-finite now becomes 0. <paramref name="review"/> (Mac only) adds
    /// repetition questions for the cards mastered already; without it the session is the web app's.
    /// </summary>
    public static LearnState CreateLearn(IReadOnlyList<Card> cards, AnswerWith answerWith, LearnOptions learn, StudySubset? subset = null,
        IReadOnlyDictionary<string, CardProgress>? progress = null, RNG? rng = null, double? now = null, bool review = false)
    {
        rng ??= Rand.SystemRNG();
        progress ??= new Dictionary<string, CardProgress>();
        double nowMs = now ?? TimeUtil.NowMs();
        var sub = NormalizeSubset(subset ?? StudySubset.All);
        var selected = CardList(cards).Where(c => Askable(c) && CardInSubset(c, sub, progress)).ToList();
        var order = Shuffled(selected.Select(c => c.Id).ToList(), rng);

        var stage = new Dictionary<string, int>(StringComparer.Ordinal);
        var seen = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var id in order)
        {
            var p = progress.GetValueOrDefault(id);
            stage[id] = StageFromProgress(p);
            if (Mastery.CardStatusOf(p) != CardStatus.New) seen[id] = true;
        }

        double at = double.IsFinite(nowMs) ? nowMs : 0;
        var mastered = order.Where(id => stage.GetValueOrDefault(id) >= MasteredStage).ToList();
        var s = new LearnState
        {
            Subset = sub, AnswerWith = answerWith, Learn = NormalizeLearn(learn), Order = order, Stage = stage,
            InitiallyMastered = mastered, Seen = seen, StartedAt = at, UpdatedAt = at,
            Review = review ? new LearnReview { Due = MostOverdueFirst(mastered, progress) } : null,
        };
        FillBatch(s);
        var reviews = TakeReviews(s);
        s.Queue = BuildQueue(s, cards, rng, reviews);
        MarkFinished(s, at);
        return s;
    }

    /// <summary><c>createLearn</c> with full study options (reads AnswerWith and Learn).</summary>
    public static LearnState CreateLearn(IReadOnlyList<Card> cards, StudyOptions options, StudySubset? subset = null,
        IReadOnlyDictionary<string, CardProgress>? progress = null, RNG? rng = null, double? now = null, bool review = false) =>
        CreateLearn(cards, options.AnswerWith, options.Learn, subset, progress, rng, now, review);

    // MARK: - Repair

    /// <summary>
    /// <c>copyState</c> of learn.js on raw JSON: a defensive copy that repairs missing fields and drops
    /// references to cards outside <c>order</c>. Accepts any JSON; a non-object gives an empty (finished)
    /// state. Extra keys (like the web app's <c>feedback</c>) are ignored.
    /// </summary>
    public static LearnState CopyState(JSONValue json)
    {
        var src = json.ObjectValue ?? new JsonObjectMap();
        JSONValue? Get(string key) => src.TryGetValue(key, out var v) ? v : null;

        var order = new List<string>();
        var known = new HashSet<string>(StringComparer.Ordinal);
        foreach (var v in Get("order")?.ArrayValue ?? [])
        {
            if (v.IsNull || v.StringValue == "") continue;
            var id = JsString(v);
            if (known.Add(id)) order.Add(id);
        }
        List<string> Ids(JSONValue? v)
        {
            var seenIds = new HashSet<string>(StringComparer.Ordinal);
            var output = new List<string>();
            foreach (var x in v?.ArrayValue ?? [])
            {
                if (x.IsNull) continue;
                var id = JsString(x);
                if (known.Contains(id) && seenIds.Add(id)) output.Add(id);
            }
            return output;
        }
        string? KnownId(JSONValue? v)
        {
            if (v is null || v.IsNull) return null;
            var id = JsString(v);
            return known.Contains(id) ? id : null;
        }
        Dictionary<string, bool> TrueMap(JSONValue? v)
        {
            var output = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (var (k, x) in v?.ObjectValue ?? new JsonObjectMap())
                if (known.Contains(k) && x.BoolValue == true) output[k] = true;
            return output;
        }

        var srcStage = Get("stage")?.ObjectValue ?? new JsonObjectMap();
        var stage = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var id in order) stage[id] = ClampStage(srcStage.TryGetValue(id, out var sv) ? sv : null);
        var misses = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (k, x) in Get("misses")?.ObjectValue ?? new JsonObjectMap())
            if (known.Contains(k)) misses[k] = CountValue(x);

        int round = Get("round")?.IntegerValue is { } r0 && r0 > 0 ? r0 : 1;
        var queue = new List<LearnQueueQuestion>();
        var srcQueue = Get("queue")?.ArrayValue ?? [];
        for (int i = 0; i < srcQueue.Count; i++)
        {
            var q = srcQueue[i];
            if (q.ObjectValue is null || KnownId(q["cardId"]) is not { } cardId) continue;
            var choices = NormChoices(q["choices"], cardId);
            var qid = q["qid"]?.StringValue is { Length: > 0 } given ? given : $"{round}.q{i}:{cardId}";
            var type = q["type"]?.StringValue == "mc" && choices is not null ? QuestionType.Mc : QuestionType.Written;
            queue.Add(new LearnQueueQuestion(qid, cardId, type, AskSideOf(q["ask"]), type == QuestionType.Mc ? choices : null,
                NormChoices(q["retryChoices"], cardId)));
        }

        var roundLog = new List<LearnRoundLogEntry>();
        foreach (var e in Get("roundLog")?.ArrayValue ?? [])
        {
            if (e.ObjectValue is null || KnownId(e["cardId"]) is not { } cardId) continue;
            roundLog.Add(new LearnRoundLogEntry(e["qid"]?.StringValue, cardId, QuestionTypeOf(e["type"]), AskSideOf(e["ask"]),
                e["correct"]?.BoolValue == true, ClampStage(e["stageAfter"])));
        }

        var rounds = new List<LearnRoundRecord>();
        foreach (var r in Get("rounds")?.ArrayValue ?? [])
        {
            if (r.ObjectValue is null) continue;
            int answeredR = CountValue(r["answered"]);
            rounds.Add(new LearnRoundRecord(r["round"]?.IntegerValue ?? rounds.Count + 1, answeredR,
                Math.Min(answeredR, CountValue(r["correct"])), Ids(r["cardIds"])));
        }

        LearnLastAnswer? last = null;
        if (Get("last") is { ObjectValue: not null } l && KnownId(l["cardId"]) is { } lastId)
            last = new LearnLastAnswer(l["qid"]?.StringValue ?? "", lastId, QuestionTypeOf(l["type"]), AskSideOf(l["ask"]),
                l["correct"]?.BoolValue == true, ClampStage(l["stageBefore"]));

        LearnReview? review = null;
        if (Get("review") is { ObjectValue: not null } rv)
        {
            var results = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (var (k, x) in rv["results"]?.ObjectValue ?? new JsonObjectMap())
                if (known.Contains(k) && x.BoolValue is { } ok) results[k] = ok;
            review = new LearnReview { Due = Ids(rv["due"]), Results = results };
        }

        var learnSrc = Get("learn");
        int roundSize = learnSrc?["roundSize"]?.FiniteNumber is { } rs ? (int)Math.Max(-1, Math.Min(Math.Floor(rs), int.MaxValue)) : 0;
        int answered = CountValue(Get("answered"));
        double startedAt = Get("startedAt")?.FiniteNumber ?? 0;
        return new LearnState
        {
            Subset = StudySubset.FromJson(Get("subset") ?? JSONValue.Null),
            AnswerWith = EnumRaw.ParseJson<AnswerWith>(Get("answerWith")) ?? AnswerWith.Term,
            Learn = NormalizeLearn(roundSize, learnSrc?["mc"]?.BoolValue != false, learnSrc?["written"]?.BoolValue != false),
            Order = order, Stage = stage, InitiallyMastered = Ids(Get("initiallyMastered")), Seen = TrueMap(Get("seen")),
            Active = Ids(Get("active")), Round = round, Queue = queue, Retried = TrueMap(Get("retried")),
            RoundLog = roundLog, Rounds = rounds, Answered = answered, Correct = Math.Min(answered, CountValue(Get("correct"))),
            Misses = misses, Last = last, StartedAt = startedAt, UpdatedAt = Get("updatedAt")?.FiniteNumber ?? startedAt,
            FinishedAt = Get("finishedAt")?.NumberValue, ElapsedMs = Math.Max(0, Get("elapsedMs")?.FiniteNumber ?? 0),
            Review = review,
        };
    }

    /// <summary>
    /// <c>copyState</c> of learn.js on a typed state: <c>order</c> keeps each non-empty id once, every other
    /// reference to a card outside <c>order</c> is dropped, stages are clamped to 0…2, counts ≥ 0, round ≥ 1,
    /// options normalised and timestamps finite. Always a fresh object with fresh collections; idempotent.
    /// </summary>
    public static LearnState CopyState(LearnState state)
    {
        var order = new List<string>();
        var known = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in state.Order)
            if (id.Length > 0 && known.Add(id)) order.Add(id);
        List<string> Ids(IEnumerable<string> list)
        {
            var seenIds = new HashSet<string>(StringComparer.Ordinal);
            return list.Where(id => known.Contains(id) && seenIds.Add(id)).ToList();
        }
        Dictionary<string, T> Known<T>(Dictionary<string, T> map, Func<T, bool>? keep = null)
        {
            var output = new Dictionary<string, T>(StringComparer.Ordinal);
            foreach (var (k, v) in map)
                if (known.Contains(k) && (keep is null || keep(v))) output[k] = v;
            return output;
        }

        var stage = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var id in order) stage[id] = ClampStage(state.Stage.GetValueOrDefault(id));
        int round = state.Round > 0 ? state.Round : 1;
        var queue = new List<LearnQueueQuestion>();
        for (int i = 0; i < state.Queue.Count; i++)
        {
            var q = state.Queue[i];
            if (!known.Contains(q.CardId)) continue;
            var choices = NormChoices(q.Choices, q.CardId);
            var type = q.Type == QuestionType.Mc && choices is not null ? QuestionType.Mc : QuestionType.Written;
            queue.Add(new LearnQueueQuestion(q.Qid.Length == 0 ? $"{round}.q{i}:{q.CardId}" : q.Qid, q.CardId, type, q.Ask,
                type == QuestionType.Mc ? choices : null, NormChoices(q.RetryChoices, q.CardId)));
        }
        int answered = ClampCount(state.Answered);
        double startedAt = double.IsFinite(state.StartedAt) ? state.StartedAt : 0;
        var misses = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (k, v) in state.Misses)
            if (known.Contains(k)) misses[k] = ClampCount(v);
        return new LearnState
        {
            Subset = NormalizeSubset(state.Subset), AnswerWith = state.AnswerWith,
            Learn = NormalizeLearn(state.Learn.RoundSize, state.Learn.Mc, state.Learn.Written),
            Order = order, Stage = stage, InitiallyMastered = Ids(state.InitiallyMastered),
            Seen = Known(state.Seen, v => v), Active = Ids(state.Active), Round = round, Queue = queue,
            Retried = Known(state.Retried, v => v),
            RoundLog = state.RoundLog.Where(e => known.Contains(e.CardId)).Select(e => e with { StageAfter = ClampStage(e.StageAfter) }).ToList(),
            Rounds = state.Rounds.Select(r =>
            {
                int a = ClampCount(r.Answered);
                return new LearnRoundRecord(r.Round, a, Math.Min(a, ClampCount(r.Correct)), Ids(r.CardIds));
            }).ToList(),
            Answered = answered, Correct = Math.Min(answered, ClampCount(state.Correct)), Misses = misses,
            Last = state.Last is { } l && known.Contains(l.CardId) ? l with { StageBefore = ClampStage(l.StageBefore) } : null,
            StartedAt = startedAt, UpdatedAt = double.IsFinite(state.UpdatedAt) ? state.UpdatedAt : startedAt,
            FinishedAt = state.FinishedAt, ElapsedMs = double.IsFinite(state.ElapsedMs) ? Math.Max(0, state.ElapsedMs) : 0,
            Review = state.Review is { } rv ? new LearnReview { Due = Ids(rv.Due), Results = Known(rv.Results) } : null,
        };
    }

    // MARK: - Asking and answering

    /// <summary>The question to ask now, null when the round is over.</summary>
    public static Question? Current(LearnState state) =>
        CopyState(state).Queue.FirstOrDefault() is { } q ? PublicQuestion(q) : null;

    /// <summary>
    /// Answers the current question (no-op when the round is over). A miss is asked once more at the end
    /// of the round, as multiple choice when possible.
    /// </summary>
    public static LearnState Answer(LearnState state, bool correct, double? now = null)
    {
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (s.Queue.Count == 0) return s;
        var q = s.Queue[0];
        AdvanceClock(s, nowMs);
        var id = q.CardId;
        int stageBefore = s.Stage.GetValueOrDefault(id);
        int stageAfter = correct ? Math.Min(stageBefore + 1, MasteredStage) : 0;
        s.Stage[id] = stageAfter;
        s.Seen[id] = true;
        s.Answered = Inc(s.Answered);
        if (correct) s.Correct = Inc(s.Correct);
        else s.Misses[id] = Inc(s.Misses.GetValueOrDefault(id));
        s.Queue.RemoveAt(0);
        s.RoundLog.Add(new LearnRoundLogEntry(q.Qid, id, q.Type, q.Ask, correct, stageAfter));
        s.Last = new LearnLastAnswer(q.Qid, id, q.Type, q.Ask, correct, stageBefore);

        if (!correct && !s.Retried.GetValueOrDefault(id))
        {
            s.Retried[id] = true;
            var retry = new LearnQueueQuestion(RetryQid(s.Round, id), id, QuestionType.Written, q.Ask);
            if (s.Learn.Mc && q.RetryChoices is { } options) retry = retry with { Type = QuestionType.Mc, Choices = options };
            s.Queue.Add(retry);
        }
        if (IsReviewQuestion(q.Qid) && s.Review is { } review)
        {
            // The first answer to a mastered card's repetition question counts; a miss means it is learned
            // again (stage 0), so it no longer counts as mastered before the session.
            review.Results.TryAdd(id, correct);
            if (!correct) s.InitiallyMastered.RemoveAll(x => x == id);
        }
        MarkFinished(s, nowMs);
        return s;
    }

    /// <summary>
    /// "Ich hatte recht": the last answer (if it was wrong) becomes correct: the card's stage is
    /// stageBefore + 1 and its retry in this round is dropped. Idempotent; a no-op after NextRound.
    /// </summary>
    public static LearnState Override(LearnState state, double? now = null)
    {
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (s.Last is not { Correct: false } l) return s;
        AdvanceClock(s, nowMs);
        var id = l.CardId;
        int stageAfter = Math.Min(l.StageBefore + 1, MasteredStage);
        s.Stage[id] = stageAfter;
        s.Correct = Math.Min(s.Answered, Inc(s.Correct));
        s.Misses[id] = Math.Max(0, s.Misses.GetValueOrDefault(id) - 1);
        int i = s.RoundLog.FindLastIndex(e => e.CardId == id && (e.Qid is null || e.Qid == l.Qid));
        if (i >= 0) s.RoundLog[i] = s.RoundLog[i] with { Correct = true, StageAfter = stageAfter };
        if (s.Queue.RemoveAll(q => q.CardId == id) > 0) s.Retried.Remove(id);
        s.Last = l with { Correct = true };
        if (IsReviewQuestion(l.Qid) && s.Review is { } review)
        {
            // The repetition question was right after all: the card is still mastered.
            review.Results[id] = true;
            if (stageAfter >= MasteredStage && !s.InitiallyMastered.Contains(id))
            {
                var before = new HashSet<string>(s.InitiallyMastered, StringComparer.Ordinal) { id };
                s.InitiallyMastered = s.Order.Where(before.Contains).ToList();
            }
        }
        MarkFinished(s, nowMs);
        return s;
    }

    // MARK: - Rounds and statistics

    public static bool IsRoundOver(LearnState state) => CopyState(state).Queue.Count == 0;

    /// <summary>Neu (never answered, stage 0) · Am Lernen · Gemeistert (stage 2) over the scope.</summary>
    public static Counts CountsOf(LearnState state) => CountsOfCopy(CopyState(state));

    /// <summary>The current round's answers per card (in asked order) and the counts.</summary>
    public static Checkpoint CheckpointOf(LearnState state)
    {
        var s = CopyState(state);
        var items = new List<(string CardId, List<bool> Results)>();
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var e in s.RoundLog)
        {
            if (!index.TryGetValue(e.CardId, out int at))
            {
                at = index[e.CardId] = items.Count;
                items.Add((e.CardId, []));
            }
            items[at].Results.Add(e.Correct);
        }
        var c = CountsOfCopy(s);
        return new Checkpoint(s.Round, s.RoundLog.Count, s.RoundLog.Count(e => e.Correct),
            items.Select(x => new CheckpointItem(x.CardId, s.Stage.GetValueOrDefault(x.CardId), x.Results)).ToList(),
            new CheckpointCounts(c.Fresh, c.Learning, c.Mastered, c.Total));
    }

    /// <summary>
    /// Closes the finished round into <c>rounds</c>, drops mastered cards from the batch, refills it and
    /// builds the next round's questions. When every card is mastered the final round is closed and the
    /// session stays finished (its roundLog is kept for the checkpoint). No-op mid-round. Scope cards missing
    /// from <paramref name="cards"/> (deleted) are removed; null keeps every card (JS: a non-array) and builds
    /// written questions only.
    /// </summary>
    public static LearnState NextRound(LearnState state, IReadOnlyList<Card>? cards, RNG? rng = null, double? now = null)
    {
        rng ??= Rand.SystemRNG();
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (s.Queue.Count > 0) return s;
        if (cards is not null)
        {
            var present = new HashSet<string>(CardList(cards).Select(c => c.Id), StringComparer.Ordinal);
            foreach (var id in s.Order.ToList())
                if (!present.Contains(id)) DropCard(s, id, null, rng);
        }
        if (IsComplete(s))
        {
            if (s.RoundLog.Count > 0 && !RoundIsClosed(s)) ArchiveRound(s);
            MarkFinished(s, nowMs);
            return s;
        }
        AdvanceClock(s, nowMs);
        // A round without answers (only after removals or in a repaired state) is refilled, not counted.
        if (s.RoundLog.Count > 0)
        {
            if (!RoundIsClosed(s)) ArchiveRound(s);
            s.Round = Inc(s.Round);
        }
        s.RoundLog = [];
        s.Retried = new(StringComparer.Ordinal);
        s.Last = null;
        FillBatch(s);
        var reviews = TakeReviews(s);
        s.Queue = BuildQueue(s, cards ?? [], rng, reviews);
        return s;
    }

    /// <summary>
    /// Every card in scope is mastered (also true without cards) and, with repetition questions, every
    /// card mastered before the session was asked again.
    /// </summary>
    public static bool IsFinished(LearnState state) => IsComplete(CopyState(state));

    public static FinalStats FinalStatsOf(LearnState state)
    {
        var s = CopyState(state);
        int total = s.Order.Count;
        int mastered = s.Order.Count(id => s.Stage.GetValueOrDefault(id) >= MasteredStage);
        int rounds = s.Rounds.Count + (s.RoundLog.Count > 0 && !RoundIsClosed(s) ? 1 : 0);
        var hardest = s.Order
            .Select((cardId, i) => (i, card: new MissedCard(cardId, s.Misses.GetValueOrDefault(cardId))))
            .Where(x => x.card.Misses > 0)
            .OrderByDescending(x => x.card.Misses).ThenBy(x => x.i)
            .Take(10)
            .Select(x => x.card)
            .ToList();
        return new FinalStats(total, mastered, s.InitiallyMastered.Count, rounds, s.Answered,
            s.Answered == 0 ? 0 : (double)s.Correct / s.Answered, s.ElapsedMs, hardest);
    }

    // MARK: - Repetition questions

    /// <summary>Whether question <paramref name="qid"/> is a repetition question ("&lt;round&gt;.3:&lt;cardId&gt;").</summary>
    public static bool IsReviewQuestion(string qid)
    {
        int colon = qid.IndexOf(':');
        if (colon < 0) return false;
        var head = qid[..colon];
        if (!head.EndsWith(".3", StringComparison.Ordinal)) return false;
        var round = head[..^2];
        return round.Length > 0 && round.All(c => c is >= '0' and <= '9');
    }

    /// <summary>How many repetition questions a round asks next to the cards being learned.</summary>
    public static int ReviewsPerRound(int roundSize) => Math.Max(1, roundSize / 3);

    /// <summary>The repetition questions so far; null for a session without them.</summary>
    public static ReviewStats? ReviewStatsOf(LearnState state)
    {
        var s = CopyState(state);
        if (s.Review is not { } review) return null;
        var queued = new HashSet<string>(s.Queue.Where(q => IsReviewQuestion(q.Qid)).Select(q => q.CardId), StringComparer.Ordinal);
        int due = review.Due.Count(id => s.Stage.GetValueOrDefault(id) >= MasteredStage && !queued.Contains(id));
        return new ReviewStats(review.Results.Count, review.Results.Values.Count(v => v), queued.Count + due);
    }

    // MARK: - Changes

    /// <summary>
    /// Removes a card from the session (deleted mid-session): its stage, batch slot, questions, current-round
    /// answers and misses, and its options in other questions. With <paramref name="cards"/> (the set's current cards)
    /// each lost option is replaced by another wrong option where one is left, in the same place. Unknown ids
    /// are a no-op.
    /// </summary>
    public static LearnState RemoveCard(LearnState state, string cardId, double? now = null, IReadOnlyList<Card>? cards = null, RNG? rng = null)
    {
        rng ??= Rand.SystemRNG();
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (!s.Order.Contains(cardId)) return s;
        AdvanceClock(s, nowMs);
        Refill? refill = null;
        if (cards is not null)
        {
            var all = CardList(cards);
            refill = new Refill(all.Where(c => c.Id != cardId && Askable(c)).ToList(), ById(all));
        }
        DropCard(s, cardId, refill, rng);
        FinishEarly(s, nowMs);
        return s;
    }

    /// <summary>Advances the active-time clock.</summary>
    public static LearnState Tick(LearnState state, double? now = null)
    {
        var s = CopyState(state);
        AdvanceClock(s, now ?? TimeUtil.NowMs());
        return s;
    }

    // MARK: - Shared progress
    //
    // Learn and Write record every answer in the same CardProgress, which is the source of truth: a card's
    // stage is min(streak, 2) and it counts as seen once it was ever answered. Answers given elsewhere
    // (Write mode, another window) are brought in with SyncProgress().

    /// <summary>Whether every card's stage and seen flag match <paramref name="progress"/> (always true when finished).</summary>
    public static bool MatchesProgress(LearnState state, IReadOnlyDictionary<string, CardProgress> progress)
    {
        var s = CopyState(state);
        if (s.FinishedAt is not null) return true;
        return s.Order.All(id =>
        {
            var p = progress.GetValueOrDefault(id);
            return s.Stage.TryGetValue(id, out int st) && st == StageFromProgress(p)
                && s.Seen.GetValueOrDefault(id) == (Mastery.CardStatusOf(p) != CardStatus.New);
        });
    }

    /// <summary>
    /// Brings the session in line with <paramref name="progress"/>: every stage becomes min(streak, 2) and seen follows
    /// whether the card was ever answered. A card mastered now leaves the batch and this round's queue; a card
    /// whose stage changed otherwise keeps its queued questions, switched to the type of its new stage; a card
    /// no longer mastered is studied again from the next round on. A finished session is left as it is.
    /// </summary>
    public static LearnState SyncProgress(LearnState state, IReadOnlyDictionary<string, CardProgress> progress, double? now = null)
    {
        double nowMs = now ?? TimeUtil.NowMs();
        var s = CopyState(state);
        if (s.FinishedAt is not null) return s;
        var changed = new List<string>();
        foreach (var id in s.Order)
        {
            var p = progress.GetValueOrDefault(id);
            int stage = StageFromProgress(p);
            if (!s.Stage.TryGetValue(id, out int old) || old != stage)
            {
                s.Stage[id] = stage;
                changed.Add(id);
            }
            if (Mastery.CardStatusOf(p) == CardStatus.New) s.Seen.Remove(id);
            else s.Seen[id] = true;
        }
        foreach (var id in changed)
        {
            if (s.Stage.GetValueOrDefault(id) >= MasteredStage)
            {
                s.Active.RemoveAll(x => x == id);
                s.Queue.RemoveAll(q => q.CardId == id);
            }
            else
            {
                s.InitiallyMastered.RemoveAll(x => x == id);
                s.Queue = s.Queue.Select(q => q.CardId == id ? Retype(s, q) : q).ToList();
            }
        }
        FinishEarly(s, nowMs);
        return s;
    }

    // MARK: - Internals: helpers

    static int ClampCount(int n) => Math.Max(0, n);

    static int Inc(int n) => n == int.MaxValue ? n : n + 1;

    /// <summary><c>Math.max(0, finite(v, 0))</c> as a count: fractional values are rounded up (keeps comparisons with 0 and 1).</summary>
    static int CountValue(JSONValue? v) =>
        v?.FiniteNumber is { } n && n > 0 ? (int)Math.Ceiling(Math.Min(n, int.MaxValue)) : 0;

    /// <summary><c>clampStage</c>: a finite number floored into 0…2, anything else 0.</summary>
    static int ClampStage(JSONValue? v) =>
        v?.FiniteNumber is { } n ? (int)Math.Max(0, Math.Min(MasteredStage, Math.Floor(n))) : 0;

    static int ClampStage(int n) => Math.Max(0, Math.Min(MasteredStage, n));

    static AskSide AskSideOf(JSONValue? v) => v?.StringValue == "definition" ? AskSide.Definition : AskSide.Term;

    static QuestionType QuestionTypeOf(JSONValue? v) => v?.StringValue == "mc" ? QuestionType.Mc : QuestionType.Written;

    /// <summary>JS <c>String(v)</c> for ids read from JSON.</summary>
    internal static string JsString(JSONValue v) => v.Kind switch
    {
        JSONKind.Null => "null",
        JSONKind.Bool => v.BoolValue!.Value ? "true" : "false",
        JSONKind.Number => JSCompat.NumberToString(v.NumberValue!.Value),
        JSONKind.String => v.StringValue!,
        JSONKind.Array => string.Join(",", v.ArrayValue!.Select(x => x.IsNull ? "" : JsString(x))),
        _ => "[object Object]",
    };

    static bool HasText(string s)
    {
        foreach (char c in s)
            if (!JSCompat.IsWhitespace(c)) return true;
        return false;
    }

    /// <summary>A card with an empty side cannot be asked (and is no useful distractor either).</summary>
    static bool Askable(Card card) => HasText(card.Term) && HasText(card.Definition);

    /// <summary>Unique cards by id (the first wins), without empty ids, in the given order (<c>cardList</c>).</summary>
    static List<Card> CardList(IReadOnlyList<Card> cards)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return cards.Where(c => c.Id.Length > 0 && seen.Add(c.Id)).ToList();
    }

    static Dictionary<string, Card> ById(IEnumerable<Card> cards)
    {
        var byId = new Dictionary<string, Card>(StringComparer.Ordinal);
        foreach (var card in cards) byId[card.Id] = card;
        return byId;
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

    /// <summary><c>normalizeLearn</c>: a round size below 1 means the default; at least one question type stays on.</summary>
    static LearnSessionOptions NormalizeLearn(int roundSize, bool mc, bool written)
    {
        bool both = mc || written;
        return new LearnSessionOptions(roundSize >= 1 ? roundSize : DEFAULT_LEARN.RoundSize, both ? mc : DEFAULT_LEARN.Mc,
            both ? written : DEFAULT_LEARN.Written);
    }

    static LearnSessionOptions NormalizeLearn(LearnOptions learn) => NormalizeLearn(learn.RoundSize, learn.Mc, learn.Written);

    /// <summary>Integer in [0, n) from the rng, clamped so a misbehaving rng never breaks an index.</summary>
    static int RandomIndex(RNG rng, int n)
    {
        double r = Math.Floor(rng() * n);
        if (!(r >= 0)) return 0;
        if (r > n - 1) return n - 1;
        return (int)r;
    }

    /// <summary>Fisher–Yates on a copy, consuming the rng like the JS.</summary>
    static List<T> Shuffled<T>(IReadOnlyList<T> list, RNG rng)
    {
        var a = list.ToList();
        for (int i = a.Count - 1; i > 0; i--)
        {
            int j = RandomIndex(rng, i + 1);
            (a[i], a[j]) = (a[j], a[i]);
        }
        return a;
    }

    // MARK: - Internals: options

    // Every question of a round compares its card with every card of the set (Distractors), so the keys
    // of each text are computed once (TextMemo).
    static readonly TextMemo<string> TextKeys = new();
    static readonly TextMemo<HashSet<string>> AnswerKeySets = new();

    /// <summary>Comparison key for answer texts: basic normalisation, script folds, JS lowercase.</summary>
    static string TextKey(string text) =>
        TextKeys.Value(text, t => JSCompat.Lower(TextNormalizer.FoldScripts(TextNormalizer.NormalizeBasic(t))));

    /// <summary>The whole answer and each of its alternatives ("laid, laide" → laid, laide | laid | laide).</summary>
    static HashSet<string> AnswerKeys(string text) => AnswerKeySets.Value(text, t =>
    {
        var keys = new HashSet<string>(StringComparer.Ordinal) { TextKey(t) };
        foreach (var alt in Grading.SplitAlternatives(t)) keys.Add(TextKey(alt));
        keys.Remove("");
        return keys;
    });

    /// <summary>
    /// Possible wrong options for <paramref name="card"/> asked on <paramref name="side"/>, in list order (list: CardList
    /// output): other cards' answer texts that are non-empty, distinct, differ from the correct answer and share
    /// none of its alternatives, from cards that are no synonyms of card. Texts whose key is in takenKeys are
    /// skipped too.
    /// </summary>
    static List<Choice> Distractors(IReadOnlyList<Card> list, Card card, AskSide side, IEnumerable<string>? takenKeys = null)
    {
        var correctText = JSCompat.Trim(Synonyms.AnswerSide(card, side));
        // Synonym cards (same prompt) would make their answer correct too.
        var synonyms = new HashSet<string>(Synonyms.FindSynonymCards(list, card, side).Select(c => c.Id), StringComparer.Ordinal);
        var correctKeys = AnswerKeys(correctText);
        var usedKeys = new HashSet<string>(takenKeys ?? [], StringComparer.Ordinal) { TextKey(correctText) };
        var output = new List<Choice>();
        foreach (var other in list)
        {
            if (other.Id == card.Id || synonyms.Contains(other.Id)) continue;
            var text = JSCompat.Trim(Synonyms.AnswerSide(other, side));
            var key = TextKey(text);
            if (key.Length == 0 || usedKeys.Contains(key)) continue;
            // An option sharing an alternative with the correct answer would be correct as well.
            if (AnswerKeys(text).Overlaps(correctKeys)) continue;
            usedKeys.Add(key);
            output.Add(new Choice(other.Id, text));
        }
        return output;
    }

    /// <summary>A stored option list: each non-empty card id once; kept only with ≥ 2 options including the asked card's.</summary>
    static List<Choice>? NormChoices(JSONValue? v, string cardId)
    {
        if (v?.ArrayValue is not { } list) return null;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var output = new List<Choice>();
        foreach (var c in list)
        {
            if (c.ObjectValue is null || c["cardId"] is not { } raw || raw.IsNull || raw.StringValue == "") continue;
            var id = JsString(raw);
            if (!ids.Add(id)) continue;
            output.Add(new Choice(id, c["text"]?.StringValue ?? ""));
        }
        return output.Count >= 2 && ids.Contains(cardId) ? output : null;
    }

    static List<Choice>? NormChoices(IReadOnlyList<Choice>? list, string cardId)
    {
        if (list is null) return null;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var output = list.Where(c => c.CardId.Length > 0 && ids.Add(c.CardId)).ToList();
        return output.Count >= 2 && ids.Contains(cardId) ? output : null;
    }

    // MARK: - Internals: questions

    static string MainQid(int round, string cardId) => $"{round}.1:{cardId}";
    static string RetryQid(int round, string cardId) => $"{round}.2:{cardId}";
    static string ReviewQid(int round, string cardId) => $"{round}.3:{cardId}";

    static Question PublicQuestion(LearnQueueQuestion q) =>
        new(q.Qid, q.CardId, q.Type, q.Ask, q.Type == QuestionType.Mc ? q.Choices : null);

    static AskSide PickAsk(AnswerWith answerWith, RNG rng) => answerWith switch
    {
        AnswerWith.Term => AskSide.Term,
        AnswerWith.Definition => AskSide.Definition,
        _ => RandomIndex(rng, 2) == 0 ? AskSide.Term : AskSide.Definition,
    };

    /// <summary>
    /// Stage 0 → multiple choice, stage 1 → written; a disabled type falls back to the other one, and multiple
    /// choice needs at least two options. RetryChoices holds the options for a re-queue after a wrong answer,
    /// which is always asked at stage 0.
    /// </summary>
    static LearnQueueQuestion MakeQuestion(LearnState s, Card card, IReadOnlyList<Card> pool, string qid, RNG rng)
    {
        var ask = PickAsk(s.AnswerWith, rng);
        var choices = s.Learn.Mc ? BuildChoices(pool, card, ask, rng) : [];
        bool canMc = choices.Count >= 2;
        var type = s.Stage.GetValueOrDefault(card.Id) == 0
            ? (canMc ? QuestionType.Mc : QuestionType.Written)
            : (s.Learn.Written || !canMc ? QuestionType.Written : QuestionType.Mc);
        return new LearnQueueQuestion(qid, card.Id, type, ask, type == QuestionType.Mc ? choices : null,
            canMc ? BuildChoices(pool, card, ask, rng) : null);
    }

    /// <summary>Keeps the batch's unmastered cards and refills it up to roundSize: stage-1 cards first, then stage-0, each in order.</summary>
    static void FillBatch(LearnState s)
    {
        var inOrder = new HashSet<string>(s.Order, StringComparer.Ordinal);
        s.Active = s.Active.Where(id => inOrder.Contains(id) && s.Stage.GetValueOrDefault(id) < MasteredStage).ToList();
        var inBatch = new HashSet<string>(s.Active, StringComparer.Ordinal);
        foreach (int want in new[] { 1, 0 })
        {
            foreach (var id in s.Order)
            {
                if (s.Active.Count >= s.Learn.RoundSize) return;
                if (!inBatch.Contains(id) && s.Stage.TryGetValue(id, out int st) && st == want)
                {
                    s.Active.Add(id);
                    inBatch.Add(id);
                }
            }
        }
    }

    /// <summary>The round's questions: one per card of the batch in shuffled order, with the repetition questions mixed in.</summary>
    static List<LearnQueueQuestion> BuildQueue(LearnState s, IReadOnlyList<Card> cards, RNG rng, IReadOnlyList<string> reviews)
    {
        var all = CardList(cards);
        var byId = ById(all);
        var pool = all.Where(Askable).ToList();
        LearnQueueQuestion Make(string id, string qid) => MakeQuestion(s, byId.GetValueOrDefault(id) ?? new Card(id, "", ""), pool, qid, rng);
        if (reviews.Count == 0) return Shuffled(s.Active, rng).Select(id => Make(id, MainQid(s.Round, id))).ToList();
        var entries = s.Active.Select(id => (id, isReview: false)).Concat(reviews.Select(id => (id, isReview: true))).ToList();
        return Shuffled(entries, rng).Select(e => Make(e.id, e.isReview ? ReviewQid(s.Round, e.id) : MainQid(s.Round, e.id))).ToList();
    }

    /// <summary>
    /// Takes the next round's repetition questions off review.Due: a few next to the cards being learned
    /// (ReviewsPerRound), a whole round once nothing is left to learn. Cards no longer mastered leave the list.
    /// </summary>
    static List<string> TakeReviews(LearnState s)
    {
        if (s.Review is not { } review) return [];
        var inOrder = new HashSet<string>(s.Order, StringComparer.Ordinal);
        review.Due.RemoveAll(id => !inOrder.Contains(id) || s.Stage.GetValueOrDefault(id) < MasteredStage);
        int count = s.Active.Count == 0 ? s.Learn.RoundSize : ReviewsPerRound(s.Learn.RoundSize);
        var picks = review.Due.Take(count).ToList();
        review.Due.RemoveRange(0, picks.Count);
        return picks;
    }

    /// <summary>Cards by when they were last answered, the longest ago (or never) first; ties keep their order.</summary>
    static List<string> MostOverdueFirst(IReadOnlyList<string> ids, IReadOnlyDictionary<string, CardProgress> progress) =>
        ids.Select((id, i) => (id, i, t: progress.GetValueOrDefault(id)?.LastAnsweredAt ?? double.NegativeInfinity))
            .OrderBy(x => x.t).ThenBy(x => x.i)
            .Select(x => x.id)
            .ToList();

    /// <summary>
    /// The question q asked at its card's current stage (like MakeQuestion), using the options it already
    /// holds. Keeps qid and ask.
    /// </summary>
    static LearnQueueQuestion Retype(LearnState s, LearnQueueQuestion q)
    {
        var options = q.Type == QuestionType.Mc ? q.Choices : q.RetryChoices;
        bool canMc = s.Learn.Mc && (options?.Count ?? 0) >= 2;
        var type = s.Stage.GetValueOrDefault(q.CardId) == 0
            ? (canMc ? QuestionType.Mc : QuestionType.Written)
            : (s.Learn.Written || !canMc ? QuestionType.Written : QuestionType.Mc);
        if (type == q.Type) return q;
        return new LearnQueueQuestion(q.Qid, q.CardId, type, q.Ask, type == QuestionType.Mc ? options : null,
            q.RetryChoices ?? (q.Type == QuestionType.Mc ? q.Choices : null));
    }

    // MARK: - Internals: transitions (on the private copy)

    static Counts CountsOfCopy(LearnState s)
    {
        int fresh = 0, mastered = 0;
        foreach (var id in s.Order)
        {
            int stage = s.Stage.GetValueOrDefault(id);
            if (stage >= MasteredStage) mastered++;
            else if (stage == 0 && !s.Seen.GetValueOrDefault(id)) fresh++;
        }
        int total = s.Order.Count;
        return new Counts(fresh, total - fresh - mastered, mastered, total, total == 0 ? 0 : (double)mastered / total);
    }

    static bool AllMastered(LearnState s) => s.Order.All(id => s.Stage.GetValueOrDefault(id) >= MasteredStage);

    /// <summary>Repetition questions are queued or still to come for cards that are still mastered.</summary>
    static bool ReviewPending(LearnState s) =>
        s.Review is { } review
        && (s.Queue.Any(q => IsReviewQuestion(q.Qid)) || review.Due.Any(id => s.Stage.GetValueOrDefault(id) >= MasteredStage));

    /// <summary>The session's goal is reached: everything mastered, every repetition question asked.</summary>
    static bool IsComplete(LearnState s) => AllMastered(s) && !ReviewPending(s);

    /// <summary>
    /// Adds active time since the last update; gaps longer than IdleGapMs are not counted. The clock stops once
    /// the session is finished, and a non-finite now leaves it untouched.
    /// </summary>
    static void AdvanceClock(LearnState s, double now)
    {
        if (s.FinishedAt is not null || !double.IsFinite(now)) return;
        double gap = now - s.UpdatedAt;
        if (gap > 0 && gap <= IdleGapMs) s.ElapsedMs += gap;
        s.UpdatedAt = now;
    }

    static void MarkFinished(LearnState s, double now)
    {
        if (s.FinishedAt is null && IsComplete(s)) s.FinishedAt = double.IsFinite(now) ? now : s.UpdatedAt;
    }

    /// <summary>
    /// MarkFinished for a change outside of answering (a removed card, progress from elsewhere): when the
    /// current round ends without a single answer, the session ended with the last closed round.
    /// </summary>
    static void FinishEarly(LearnState s, double now)
    {
        MarkFinished(s, now);
        if (s.FinishedAt is not null && s.Queue.Count == 0 && s.RoundLog.Count == 0)
            s.Round = s.Rounds.Count > 0 ? s.Rounds[^1].Round : 1;
    }

    static bool RoundIsClosed(LearnState s) => s.Rounds.Count > 0 && s.Rounds[^1].Round == s.Round;

    static void ArchiveRound(LearnState s) =>
        s.Rounds.Add(new LearnRoundRecord(s.Round, s.RoundLog.Count, s.RoundLog.Count(e => e.Correct), s.Active.ToList()));

    /// <summary>The set's askable cards without the removed one, and every card by id: the source of replacement options.</summary>
    sealed record Refill(IReadOnlyList<Card> Pool, IReadOnlyDictionary<string, Card> ById);

    /// <summary>
    /// The options of question q without card id. With refill its slot gets another valid wrong option when
    /// there is one, so a question keeps its number of options and the other options keep their places.
    /// </summary>
    static List<Choice> WithoutOption(IReadOnlyList<Choice>? list, string id, LearnQueueQuestion q, Refill? refill, RNG rng)
    {
        if (list is null) return [];
        int at = list.ToList().FindIndex(c => c.CardId == id);
        if (at < 0) return list.ToList();
        var rest = list.Where(c => c.CardId != id).ToList();
        if (refill is null || !refill.ById.TryGetValue(q.CardId, out var card)) return rest;
        var present = new HashSet<string>(rest.Select(c => c.CardId), StringComparer.Ordinal);
        // Keys of the remaining options, from the cards' current texts where they still exist.
        var taken = rest.Select(c => TextKey(refill.ById.TryGetValue(c.CardId, out var other) ? Synonyms.AnswerSide(other, q.Ask) : c.Text)).ToList();
        var candidates = Distractors(refill.Pool, card, q.Ask, taken).Where(c => !present.Contains(c.CardId)).ToList();
        if (candidates.Count == 0) return rest;
        rest.Insert(at, candidates[RandomIndex(rng, candidates.Count)]);
        return rest;
    }

    static void DropCard(LearnState s, string id, Refill? refill, RNG rng)
    {
        s.Order.RemoveAll(x => x == id);
        s.Stage.Remove(id);
        s.Seen.Remove(id);
        s.Retried.Remove(id);
        s.Misses.Remove(id);
        s.InitiallyMastered.RemoveAll(x => x == id);
        s.Active.RemoveAll(x => x == id);
        if (s.Review is { } review)
        {
            review.Due.RemoveAll(x => x == id);
            review.Results.Remove(id);
        }
        // Its questions go; other questions lose it as an option (refilled when possible; mc needs two options).
        s.Queue = s.Queue.Where(q => q.CardId != id).Select(q =>
        {
            var choices = WithoutOption(q.Choices, id, q, refill, rng);
            var retryChoices = WithoutOption(q.RetryChoices, id, q, refill, rng);
            var type = q.Type == QuestionType.Mc && choices.Count >= 2 ? QuestionType.Mc : QuestionType.Written;
            return new LearnQueueQuestion(q.Qid, q.CardId, type, q.Ask, type == QuestionType.Mc ? choices : null,
                retryChoices.Count >= 2 ? retryChoices : null);
        }).ToList();
        // The current round forgets its answers (the checkpoint never shows a deleted card); closed rounds keep
        // their tallies as history.
        var removed = s.RoundLog.Where(e => e.CardId == id).ToList();
        s.RoundLog.RemoveAll(e => e.CardId == id);
        s.Answered = Math.Max(0, s.Answered - removed.Count);
        s.Correct = Math.Min(s.Answered, Math.Max(0, s.Correct - removed.Count(e => e.Correct)));
        s.Rounds = s.Rounds.Select(r => r.CardIds.Contains(id) ? r with { CardIds = r.CardIds.Where(x => x != id).ToList() } : r).ToList();
        if (s.Last?.CardId == id) s.Last = null;
    }
}
