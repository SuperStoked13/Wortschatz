namespace Wortschatz.Core;

// Port of Models.swift: the data model of the web app (src/store/db.js) with identical JSON keys,
// so backups move between the web, Mac and Windows apps unchanged. Decoding is lenient like the
// web app's sanitisers (FromJson): missing or invalid fields get their defaults. Store-level
// repairs belong to LibraryStore.
//
// Swift structs are value types; here they are records. Never mutate a record or list you got
// from elsewhere: copy with `with { }` / `new List<T>(...)` first (Swift does that implicitly).

/// <summary>Language codes of a set side (<c>LANG_CODES</c> in db.js).</summary>
public enum Lang { Fr, En, Es, It, Ar, Zh, De, Other }

public static class LangExtensions
{
    /// <summary>Written right to left (Arabic).</summary>
    public static bool IsRTL(this Lang lang) => lang == Lang.Ar;

    public static Lang? ParseLang(string? raw) => EnumRaw.Parse<Lang>(raw);
}

public sealed record Card(string Id, string Term, string Definition, bool Starred = false) : IJsonEncodable
{
    /// <summary>Lenient: non-string id → "", term/definition → JS <c>String(v)</c> of primitives; null for non-objects.</summary>
    public static Card? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null) return null;
        return new Card(
            json["id"]?.StringValue ?? "",
            json["term"]?.JsPrimitiveString ?? "",
            json["definition"]?.JsPrimitiveString ?? "",
            json["starred"]?.BoolValue ?? false);
    }

    public JSONValue ToJson() => JSONValue.Obj(("id", Id), ("term", Term), ("definition", Definition), ("starred", Starred));
}

public sealed record VocabSet : IJsonEncodable
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public string Description { get; init; } = "";
    public Lang TermLang { get; init; } = Lang.Fr;
    public Lang DefLang { get; init; } = Lang.De;
    public List<Card> Cards { get; init; } = [];
    /// <summary>The set's own study options (a sanitised partial; null = none).</summary>
    public StudyOptionsPatch? StudyOptions { get; init; }
    /// <summary>Epoch milliseconds.</summary>
    public double CreatedAt { get; init; }
    public double UpdatedAt { get; init; }
    public double? LastStudiedAt { get; init; }

    /// <summary>Lenient like <c>sanitizeSet</c> minus the store repairs.</summary>
    public static VocabSet? FromJson(JSONValue json, double? fallbackNow = null)
    {
        if (json.ObjectValue is null) return null;
        var opts = json["studyOptions"] is { } so ? StudyOptionsPatch.FromJson(so) : null;
        var createdAt = json["createdAt"]?.FiniteNumber ?? fallbackNow ?? TimeUtil.NowMs();
        return new VocabSet
        {
            Id = json["id"]?.StringValue ?? "",
            Title = json["title"]?.JsPrimitiveString ?? "",
            Description = json["description"]?.JsPrimitiveString ?? "",
            TermLang = EnumRaw.ParseJson<Lang>(json["termLang"]) ?? Lang.Fr,
            DefLang = EnumRaw.ParseJson<Lang>(json["defLang"]) ?? Lang.De,
            Cards = (json["cards"]?.ArrayValue ?? []).Select(Card.FromJson).OfType<Card>().ToList(),
            StudyOptions = opts is null || opts.IsEmpty ? null : opts,
            CreatedAt = createdAt,
            UpdatedAt = json["updatedAt"]?.FiniteNumber ?? createdAt,
            LastStudiedAt = json["lastStudiedAt"]?.FiniteNumber,
        };
    }

    public JSONValue ToJson() => ToJson(Cards.ToJsonArray());

    /// <summary>ToJson with <paramref name="cards"/> as the cards (the library file writes its remembered card JSON there).</summary>
    internal JSONValue ToJson(JSONValue cards) => JSONValue.Obj(
        ("id", Id), ("title", Title), ("description", Description), ("termLang", TermLang.ToJson()), ("defLang", DefLang.ToJson()),
        ("cards", cards), ("studyOptions", StudyOptions.ToJsonOrNull()), ("createdAt", CreatedAt),
        ("updatedAt", UpdatedAt), ("lastStudiedAt", JSONValue.Nullable(LastStudiedAt)));

    /// <summary>A copy with its own card list.</summary>
    public VocabSet Copy() => this with { Cards = new List<Card>(Cards) };
}

// MARK: - Study options

public enum AnswerWith { Term, Definition, Both }

public sealed record Tolerance(
    bool Articles = true, bool Abbreviations = true, bool MultipleAnswers = true, bool Parentheses = true,
    bool IgnoreCase = true, bool IgnoreAccents = false, bool Typos = false) : IJsonEncodable
{
    /// <summary><c>DEFAULT_STUDY_OPTIONS.tolerance</c> (= <c>DEFAULT_TOLERANCE</c> of grading.js).</summary>
    public static readonly Tolerance Default = new();

    public static readonly string[] Keys = ["articles", "abbreviations", "multipleAnswers", "parentheses", "ignoreCase", "ignoreAccents", "typos"];

    /// <summary>Every boolean key taken from <paramref name="json"/>, the rest from the defaults.</summary>
    public static Tolerance FromJson(JSONValue? json)
    {
        var d = Default;
        return new Tolerance(
            json?["articles"]?.BoolValue ?? d.Articles,
            json?["abbreviations"]?.BoolValue ?? d.Abbreviations,
            json?["multipleAnswers"]?.BoolValue ?? d.MultipleAnswers,
            json?["parentheses"]?.BoolValue ?? d.Parentheses,
            json?["ignoreCase"]?.BoolValue ?? d.IgnoreCase,
            json?["ignoreAccents"]?.BoolValue ?? d.IgnoreAccents,
            json?["typos"]?.BoolValue ?? d.Typos);
    }

    public JSONValue ToJson() => JSONValue.Obj(
        ("articles", Articles), ("abbreviations", Abbreviations), ("multipleAnswers", MultipleAnswers), ("parentheses", Parentheses),
        ("ignoreCase", IgnoreCase), ("ignoreAccents", IgnoreAccents), ("typos", Typos));
}

/// <summary>Learn-mode options: terms per round, question types and the retype step.</summary>
public sealed record LearnOptions(int RoundSize = 7, bool Mc = true, bool Written = true, bool Retype = false) : IJsonEncodable
{
    public static readonly LearnOptions Default = new();

    public static LearnOptions FromJson(JSONValue? json)
    {
        var d = Default;
        int roundSize = json?["roundSize"]?.FiniteNumber is { } n ? (int)Math.Max(-1e9, Math.Min(1e9, Math.Floor(n))) : d.RoundSize;
        return new LearnOptions(roundSize, json?["mc"]?.BoolValue ?? d.Mc, json?["written"]?.BoolValue ?? d.Written, json?["retype"]?.BoolValue ?? d.Retype);
    }

    public JSONValue ToJson() => JSONValue.Obj(("roundSize", RoundSize), ("mc", Mc), ("written", Written), ("retype", Retype));
}

/// <summary>Full study options (<c>DEFAULT_STUDY_OPTIONS</c> shape).</summary>
public sealed record StudyOptions : IJsonEncodable
{
    public AnswerWith AnswerWith { get; init; } = AnswerWith.Term;
    public bool Shuffle { get; init; } = true;
    public bool CopyAnswer { get; init; } = true;
    public bool AutoAdvance { get; init; } = true;
    public bool Audio { get; init; } = false;
    public Tolerance Tolerance { get; init; } = Tolerance.Default;
    public LearnOptions Learn { get; init; } = LearnOptions.Default;

    /// <summary><c>DEFAULT_STUDY_OPTIONS</c> of db.js.</summary>
    public static readonly StudyOptions Default = new();

    /// <summary>Like the web app reading stored options: defaults ← sanitised json.</summary>
    public static StudyOptions FromJson(JSONValue json) => Full(StudyOptionsPatch.FromJson(json));

    /// <summary>Fills a (merged) patch up with <paramref name="fallback"/> values.</summary>
    public static StudyOptions FromPatch(StudyOptionsPatch patch, StudyOptions? fallback = null)
    {
        var f = fallback ?? Default;
        var t = patch.Tolerance ?? new TolerancePatch();
        var l = patch.Learn ?? new LearnOptionsPatch();
        var ft = f.Tolerance;
        var fl = f.Learn;
        return new StudyOptions
        {
            AnswerWith = patch.AnswerWith ?? f.AnswerWith,
            Shuffle = patch.Shuffle ?? f.Shuffle,
            CopyAnswer = patch.CopyAnswer ?? f.CopyAnswer,
            AutoAdvance = patch.AutoAdvance ?? f.AutoAdvance,
            Audio = patch.Audio ?? f.Audio,
            Tolerance = new Tolerance(
                t.Articles ?? ft.Articles, t.Abbreviations ?? ft.Abbreviations, t.MultipleAnswers ?? ft.MultipleAnswers,
                t.Parentheses ?? ft.Parentheses, t.IgnoreCase ?? ft.IgnoreCase, t.IgnoreAccents ?? ft.IgnoreAccents, t.Typos ?? ft.Typos),
            Learn = new LearnOptions(l.RoundSize ?? fl.RoundSize, l.Mc ?? fl.Mc, l.Written ?? fl.Written, l.Retype ?? fl.Retype),
        };
    }

    /// <summary><c>mergeStudy(this, patch)</c> for full options.</summary>
    public StudyOptions Merging(StudyOptionsPatch? patch) =>
        patch is null ? this : FromPatch(StudyOptionsPatch.FromFull(this).Merging(patch), Default);

    /// <summary><c>fullStudyOptions(...layers)</c>: defaults ← layer 1 ← layer 2 …</summary>
    public static StudyOptions Full(params StudyOptionsPatch?[] layers)
    {
        var output = Default;
        foreach (var layer in layers) output = output.Merging(layer ?? new StudyOptionsPatch());
        return output;
    }

    public JSONValue ToJson() => JSONValue.Obj(
        ("answerWith", AnswerWith.ToJson()), ("shuffle", Shuffle), ("copyAnswer", CopyAnswer), ("autoAdvance", AutoAdvance),
        ("audio", Audio), ("tolerance", Tolerance.ToJson()), ("learn", Learn.ToJson()));
}

public sealed record TolerancePatch(
    bool? Articles = null, bool? Abbreviations = null, bool? MultipleAnswers = null, bool? Parentheses = null,
    bool? IgnoreCase = null, bool? IgnoreAccents = null, bool? Typos = null) : IJsonEncodable
{
    public static TolerancePatch FromFull(Tolerance t) =>
        new(t.Articles, t.Abbreviations, t.MultipleAnswers, t.Parentheses, t.IgnoreCase, t.IgnoreAccents, t.Typos);

    public bool IsEmpty => this == new TolerancePatch();

    /// <summary>Boolean keys only; null when json is not an object.</summary>
    public static TolerancePatch? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null) return null;
        return new TolerancePatch(
            json["articles"]?.BoolValue, json["abbreviations"]?.BoolValue, json["multipleAnswers"]?.BoolValue,
            json["parentheses"]?.BoolValue, json["ignoreCase"]?.BoolValue, json["ignoreAccents"]?.BoolValue, json["typos"]?.BoolValue);
    }

    /// <summary><c>{ ...this, ...patch }</c>.</summary>
    public TolerancePatch OverlaidWith(TolerancePatch? p) => p is null ? this : new TolerancePatch(
        p.Articles ?? Articles, p.Abbreviations ?? Abbreviations, p.MultipleAnswers ?? MultipleAnswers,
        p.Parentheses ?? Parentheses, p.IgnoreCase ?? IgnoreCase, p.IgnoreAccents ?? IgnoreAccents, p.Typos ?? Typos);

    public JSONValue ToJson()
    {
        var map = new JsonObjectMap();
        if (Articles is { } a) map["articles"] = a;
        if (Abbreviations is { } b) map["abbreviations"] = b;
        if (MultipleAnswers is { } m) map["multipleAnswers"] = m;
        if (Parentheses is { } p) map["parentheses"] = p;
        if (IgnoreCase is { } c) map["ignoreCase"] = c;
        if (IgnoreAccents is { } i) map["ignoreAccents"] = i;
        if (Typos is { } t) map["typos"] = t;
        return JSONValue.Object(map);
    }
}

public sealed record LearnOptionsPatch(int? RoundSize = null, bool? Mc = null, bool? Written = null, bool? Retype = null) : IJsonEncodable
{
    /// <summary>Largest valid roundSize (<c>LEARN_ROUND_SIZE_MAX</c>).</summary>
    public const int RoundSizeMax = 50;

    public static LearnOptionsPatch FromFull(LearnOptions l) => new(l.RoundSize, l.Mc, l.Written, l.Retype);

    public bool IsEmpty => this == new LearnOptionsPatch();

    /// <summary><c>sanitizeLearnPatch(json)</c>; null when not an object.</summary>
    public static LearnOptionsPatch? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null) return null;
        int? roundSize = json["roundSize"]?.IntegerValue is { } n && n >= 1 && n <= RoundSizeMax ? n : null;
        return new LearnOptionsPatch(roundSize, json["mc"]?.BoolValue, json["written"]?.BoolValue, json["retype"]?.BoolValue).Sanitized();
    }

    /// <summary>roundSize must be 1…50; both question types off is dropped.</summary>
    public LearnOptionsPatch Sanitized()
    {
        var output = this;
        if (output.RoundSize is { } n && (n < 1 || n > RoundSizeMax)) output = output with { RoundSize = null };
        if (output.Mc == false && output.Written == false) output = output with { Mc = null, Written = null };
        return output;
    }

    /// <summary><c>mergeLearn(this, patch)</c>: never both question types off.</summary>
    public LearnOptionsPatch Merging(LearnOptionsPatch? patch)
    {
        var p = patch ?? new LearnOptionsPatch();
        var output = new LearnOptionsPatch(p.RoundSize ?? RoundSize, p.Mc ?? Mc, p.Written ?? Written, p.Retype ?? Retype);
        if (output.Mc == false && output.Written == false)
        {
            if (p.Mc == false) output = output with { Written = true };
            else if (p.Written == false) output = output with { Mc = true };
            else output = output with { Mc = true, Written = true };
        }
        return output;
    }

    public JSONValue ToJson()
    {
        var map = new JsonObjectMap();
        if (RoundSize is { } r) map["roundSize"] = r;
        if (Mc is { } m) map["mc"] = m;
        if (Written is { } w) map["written"] = w;
        if (Retype is { } t) map["retype"] = t;
        return JSONValue.Object(map);
    }
}

/// <summary>A deep partial StudyOptions (a set's <c>studyOptions</c>, argument of updates). Absent keys are omitted.</summary>
public sealed record StudyOptionsPatch(
    AnswerWith? AnswerWith = null, bool? Shuffle = null, bool? CopyAnswer = null, bool? AutoAdvance = null,
    bool? Audio = null, TolerancePatch? Tolerance = null, LearnOptionsPatch? Learn = null) : IJsonEncodable
{
    public static StudyOptionsPatch FromFull(StudyOptions f) => new(
        f.AnswerWith, f.Shuffle, f.CopyAnswer, f.AutoAdvance, f.Audio, TolerancePatch.FromFull(f.Tolerance), LearnOptionsPatch.FromFull(f.Learn));

    public bool IsEmpty => this == new StudyOptionsPatch();

    /// <summary><c>sanitizeStudyPatch(json)</c>; null when not an object.</summary>
    public static StudyOptionsPatch? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null) return null;
        return new StudyOptionsPatch(
            EnumRaw.ParseJson<AnswerWith>(json["answerWith"]),
            json["shuffle"]?.BoolValue, json["copyAnswer"]?.BoolValue, json["autoAdvance"]?.BoolValue, json["audio"]?.BoolValue,
            json["tolerance"] is { } t ? TolerancePatch.FromJson(t) : null,
            json["learn"] is { } l ? LearnOptionsPatch.FromJson(l) : null).Sanitized();
    }

    /// <summary>Empty tolerance/learn parts are dropped, learn is sanitised.</summary>
    public StudyOptionsPatch Sanitized()
    {
        var output = this;
        if (output.Tolerance is { IsEmpty: true }) output = output with { Tolerance = null };
        if (output.Learn is { } l)
        {
            var s = l.Sanitized();
            output = output with { Learn = s.IsEmpty ? null : s };
        }
        return output;
    }

    /// <summary><c>mergeStudy(this, patch)</c>: deep-merges the sanitised patch.</summary>
    public StudyOptionsPatch Merging(StudyOptionsPatch patch)
    {
        var p = patch.Sanitized();
        var output = this;
        if (p.AnswerWith is { } aw) output = output with { AnswerWith = aw };
        if (p.Shuffle is { } sh) output = output with { Shuffle = sh };
        if (p.CopyAnswer is { } ca) output = output with { CopyAnswer = ca };
        if (p.AutoAdvance is { } ad) output = output with { AutoAdvance = ad };
        if (p.Audio is { } au) output = output with { Audio = au };
        if (Tolerance is not null || p.Tolerance is not null)
            output = output with { Tolerance = (Tolerance ?? new TolerancePatch()).OverlaidWith(p.Tolerance) };
        if (Learn is not null || p.Learn is not null)
        {
            var merged = (Learn ?? new LearnOptionsPatch()).Sanitized().Merging(p.Learn);
            output = output with { Learn = merged.IsEmpty ? null : merged };
        }
        return output;
    }

    /// <summary>
    /// The options of <paramref name="touched"/> that are here the same as in <paramref name="standard"/> dropped: a set's
    /// own option set back to the standard is no longer its own (LibraryStore.UpdateOwnStudyOptions). The values in
    /// effect stay the same.
    /// </summary>
    public StudyOptionsPatch DroppingStandard(StudyOptionsPatch touched, StudyOptions standard)
    {
        static T? Drop<T>(object? touchedValue, T? value, T standardValue) where T : struct =>
            touchedValue is not null && value is { } v && EqualityComparer<T>.Default.Equals(v, standardValue) ? null : value;
        var o = this with
        {
            AnswerWith = Drop(touched.AnswerWith, AnswerWith, standard.AnswerWith),
            Shuffle = Drop(touched.Shuffle, Shuffle, standard.Shuffle),
            CopyAnswer = Drop(touched.CopyAnswer, CopyAnswer, standard.CopyAnswer),
            AutoAdvance = Drop(touched.AutoAdvance, AutoAdvance, standard.AutoAdvance),
            Audio = Drop(touched.Audio, Audio, standard.Audio),
        };
        if (o.Tolerance is { } t && touched.Tolerance is { } tt)
        {
            var s = standard.Tolerance;
            var kept = new TolerancePatch(
                Drop(tt.Articles, t.Articles, s.Articles), Drop(tt.Abbreviations, t.Abbreviations, s.Abbreviations),
                Drop(tt.MultipleAnswers, t.MultipleAnswers, s.MultipleAnswers), Drop(tt.Parentheses, t.Parentheses, s.Parentheses),
                Drop(tt.IgnoreCase, t.IgnoreCase, s.IgnoreCase), Drop(tt.IgnoreAccents, t.IgnoreAccents, s.IgnoreAccents),
                Drop(tt.Typos, t.Typos, s.Typos));
            o = o with { Tolerance = kept.IsEmpty ? null : kept };
        }
        if (o.Learn is { } l && touched.Learn is { } tl)
        {
            var s = standard.Learn;
            var kept = new LearnOptionsPatch(Drop(tl.RoundSize, l.RoundSize, s.RoundSize), Drop(tl.Mc, l.Mc, s.Mc), Drop(tl.Written, l.Written, s.Written),
                Drop(tl.Retype, l.Retype, s.Retype));
            o = o with { Learn = kept.IsEmpty ? null : kept };
        }
        return o;
    }

    public JSONValue ToJson()
    {
        var map = new JsonObjectMap();
        if (AnswerWith is { } aw) map["answerWith"] = aw.ToJson();
        if (Shuffle is { } sh) map["shuffle"] = sh;
        if (CopyAnswer is { } ca) map["copyAnswer"] = ca;
        if (AutoAdvance is { } ad) map["autoAdvance"] = ad;
        if (Audio is { } au) map["audio"] = au;
        if (Tolerance is { } t) map["tolerance"] = t.ToJson();
        if (Learn is { } l) map["learn"] = l.ToJson();
        return JSONValue.Object(map);
    }
}

// MARK: - Settings

public enum ThemeSetting { System, Light, Dark }

public sealed record Settings(ThemeSetting Theme, StudyOptions Study) : IJsonEncodable
{
    /// <summary><c>DEFAULT_SETTINGS</c> of db.js.</summary>
    public static readonly Settings Default = new(ThemeSetting.System, StudyOptions.Default);

    /// <summary>Like <c>mergeSettings(DEFAULT_SETTINGS, json)</c>.</summary>
    public static Settings FromJson(JSONValue json) => Default.Merging(SettingsPatch.FromJson(json));

    /// <summary><c>mergeSettings(this, patch)</c>.</summary>
    public Settings Merging(SettingsPatch? patch)
    {
        var p = patch ?? new SettingsPatch();
        return new Settings(p.Theme ?? Theme, StudyOptions.Full(StudyOptionsPatch.FromFull(Study), p.Study));
    }

    public JSONValue ToJson() => JSONValue.Obj(("theme", Theme.ToJson()), ("study", Study.ToJson()));
}

/// <summary>Argument of <c>updateSettings</c>.</summary>
public sealed record SettingsPatch(ThemeSetting? Theme = null, StudyOptionsPatch? Study = null)
{
    public static SettingsPatch FromJson(JSONValue json) => new(
        EnumRaw.ParseJson<ThemeSetting>(json["theme"]),
        json["study"] is { } s ? StudyOptionsPatch.FromJson(s) : null);
}

// MARK: - Progress

public enum AnswerResult { Correct, Incorrect }

public enum CardStatus { New, Learning, Mastered }

/// <summary>Persistent per-card progress (mastery.js).</summary>
public sealed record CardProgress(
    int Correct = 0, int Incorrect = 0, int Streak = 0, int StreakBefore = 0, AnswerResult? LastResult = null,
    double? LastAnsweredAt = null) : IJsonEncodable
{
    /// <summary>A fresh record (<c>normalizeProgress(undefined)</c>).</summary>
    public static readonly CardProgress Fresh = new();

    /// <summary><c>normalizeProgress(json)</c> for objects (null otherwise).</summary>
    public static CardProgress? FromJson(JSONValue json)
    {
        if (json.ObjectValue is null) return null;
        return new CardProgress(
            json["correct"].JsCount(), json["incorrect"].JsCount(), json["streak"].JsCount(), json["streakBefore"].JsCount(),
            EnumRaw.ParseJson<AnswerResult>(json["lastResult"]), json["lastAnsweredAt"]?.FiniteNumber);
    }

    public JSONValue ToJson() => JSONValue.Obj(
        ("correct", Correct), ("incorrect", Incorrect), ("streak", Streak), ("streakBefore", StreakBefore),
        ("lastResult", LastResult.ToJson()), ("lastAnsweredAt", JSONValue.Nullable(LastAnsweredAt)));
}

// MARK: - Shared study-engine types

/// <summary>The side the learner answers: <c>Term</c> means the prompt is the definition.</summary>
public enum AskSide { Term, Definition }

public enum StudySubsetKind { All, Starred, Learning, Missed, CardIds }

/// <summary>Which cards a session covers: "all" | "starred" | "learning" | "missed" | {cardIds}.</summary>
public sealed record StudySubset(StudySubsetKind Kind, IReadOnlyList<string>? Ids = null) : IJsonEncodable
{
    public static readonly StudySubset All = new(StudySubsetKind.All);
    public static readonly StudySubset Starred = new(StudySubsetKind.Starred);
    public static readonly StudySubset Learning = new(StudySubsetKind.Learning);
    public static readonly StudySubset Missed = new(StudySubsetKind.Missed);
    public static StudySubset CardIds(IEnumerable<string> ids) => new(StudySubsetKind.CardIds, ids.ToList());

    public IReadOnlyList<string> CardIdList => Ids ?? [];

    /// <summary><c>normalizeSubset(json)</c>.</summary>
    public static StudySubset FromJson(JSONValue? json)
    {
        switch (json?.Kind)
        {
            case JSONKind.String:
                return json.StringValue switch
                {
                    "starred" => Starred,
                    "learning" => Learning,
                    "missed" => Missed,
                    _ => All,
                };
            case JSONKind.Object:
                var ids = new List<string>();
                foreach (var v in json["cardIds"]?.ArrayValue ?? [])
                {
                    if (v.IsNull) continue;
                    if (v.StringValue is { } s) { if (s.Length > 0) ids.Add(s); continue; }
                    if (v.JsPrimitiveString is { } p) ids.Add(p);
                }
                return CardIds(ids);
            case JSONKind.Array:
                return CardIds([]);
            default:
                return All;
        }
    }

    public JSONValue ToJson() => Kind switch
    {
        StudySubsetKind.All => "all",
        StudySubsetKind.Starred => "starred",
        StudySubsetKind.Learning => "learning",
        StudySubsetKind.Missed => "missed",
        _ => JSONValue.Obj(("cardIds", CardIdList.ToJsonArray())),
    };

    public bool Equals(StudySubset? other) =>
        other is not null && Kind == other.Kind && CardIdList.SequenceEqual(other.CardIdList, StringComparer.Ordinal);

    public override int GetHashCode() => HashCode.Combine(Kind, CardIdList.Count);
}

/// <summary>A card's number of misses (<c>hardest</c> entries of the final stats).</summary>
public sealed record MissedCard(string CardId, int Misses) : IJsonEncodable
{
    public JSONValue ToJson() => JSONValue.Obj(("cardId", CardId), ("misses", Misses));

    public static MissedCard? FromJson(JSONValue json) =>
        json["cardId"]?.StringValue is { } id ? new MissedCard(id, json["misses"]?.IntegerValue ?? 0) : null;
}
