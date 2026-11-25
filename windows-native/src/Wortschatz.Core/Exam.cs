using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of Exam.swift. Prüfungsmodus (exam): a vocabulary test over a set on one page, graded like a test
// at school with a Swiss grade from 1 to 6. Only the Mac app (and this one) has it, not the web app.
//
// Grading reuses the Write and Learn grader (Grading, Synonyms) in two passes: first with only the forms
// that are no mistake at all (one of several answers, optional brackets, abbreviations, capitals outside
// German; a German noun's small first letter is noted as a small mistake), then with the small mistakes
// allowed (a typo, missing accents, a missing article or reflexive pronoun). How much a small mistake
// costs is the exam's tolerance. An exam records nothing: mastery stays with Lernen and Schreiben.

/// <summary>How small mistakes count in an exam (<c>ExamSettings.Tolerance</c>).</summary>
public enum ExamTolerance
{
    /// <summary>Only fully right answers score.</summary>
    Strict,
    /// <summary>A small mistake costs half a point.</summary>
    Half,
    /// <summary>Small mistakes cost nothing.</summary>
    Lenient,
}

public static class ExamToleranceExtensions
{
    /// <summary>The points of an answer with a small mistake.</summary>
    public static double MinorPoints(this ExamTolerance t) => t switch
    {
        ExamTolerance.Strict => 0,
        ExamTolerance.Half => 0.5,
        _ => 1,
    };
}

/// <summary>The settings of an exam ("Prüfung einrichten"); the app keeps them for every set.</summary>
/// <param name="Minutes">Time limit in minutes; 0 = none.</param>
/// <param name="Count">How many words are asked; 0 = all of them.</param>
/// <param name="AnswerWith">The side that is answered (Both: chosen at random for each question).</param>
/// <param name="StarredOnly">Only the starred cards (when the set has any).</param>
public sealed record ExamSettings(int Minutes = 10, int Count = 20, AnswerWith AnswerWith = AnswerWith.Term,
    ExamTolerance Tolerance = ExamTolerance.Half, bool StarredOnly = false) : IJsonEncodable
{
    public static readonly ExamSettings Default = new();

    /// <summary>The time limits offered (minutes, 0 = none).</summary>
    public static readonly int[] MinuteChoices = [0, 5, 10, 15, 20, 30, 45];
    /// <summary>The numbers of words offered (0 = all).</summary>
    public static readonly int[] CountChoices = [10, 15, 20, 30, 0];

    /// <summary>
    /// Lenient: every missing or invalid field takes its default, numbers snap to the nearest choice offered
    /// (so the settings page always has one selected).
    /// </summary>
    public static ExamSettings FromJson(JSONValue? json)
    {
        var d = Default;
        return new ExamSettings(
            json?["minutes"]?.FiniteNumber is { } m ? Nearest(m, MinuteChoices) : d.Minutes,
            json?["count"]?.FiniteNumber is { } c ? Nearest(c, CountChoices) : d.Count,
            EnumRaw.ParseJson<AnswerWith>(json?["answerWith"]) ?? d.AnswerWith,
            EnumRaw.ParseJson<ExamTolerance>(json?["tolerance"]) ?? d.Tolerance,
            json?["starredOnly"]?.BoolValue ?? d.StarredOnly);
    }

    public JSONValue ToJson() => JSONValue.Obj(
        ("minutes", Minutes), ("count", Count), ("answerWith", AnswerWith.ToJson()), ("tolerance", Tolerance.ToJson()), ("starredOnly", StarredOnly));

    /// <summary>The choice nearest to value (the lower one on a tie); 0 ("none", "all") only for 0 or less.</summary>
    internal static int Nearest(double value, int[] choices)
    {
        var positive = choices.Where(c => c > 0).Order().ToList();
        if (!(value > 0) || positive.Count == 0) return 0;
        return positive.Aggregate(positive[0], (best, choice) => Math.Abs(choice - value) < Math.Abs(best - value) ? choice : best);
    }
}

/// <summary>A question on the exam sheet, with the texts it was asked with. Number is 1-based; Ask Term = the definition is shown, the term typed.</summary>
public sealed record ExamQuestion(int Number, string CardId, AskSide Ask, string Prompt, string Expected, Lang PromptLang, Lang AnswerLang) : IJsonEncodable
{
    public int Id => Number;

    /// <summary>The card as it was asked.</summary>
    public Card Card => new(CardId, Ask == AskSide.Term ? Expected : Prompt, Ask == AskSide.Term ? Prompt : Expected);

    public JSONValue ToJson() => JSONValue.Obj(
        ("number", Number), ("cardId", CardId), ("ask", Ask.ToJson()), ("prompt", Prompt), ("expected", Expected),
        ("promptLang", PromptLang.ToJson()), ("answerLang", AnswerLang.ToJson()));
}

/// <summary>How an answer was marked.</summary>
public enum ExamMark
{
    /// <summary>Right (a full point).</summary>
    Correct,
    /// <summary>Right but for a small mistake (as many points as the tolerance gives).</summary>
    Minor,
    Wrong,
    /// <summary>No answer.</summary>
    Blank,
}

/// <summary>
/// One marked answer. Given: what was typed (trimmed). Note: the small mistake ("Tippfehler", "Akzente", …),
/// the hint of a wrong answer ("Falscher Artikel") or why a right answer differs. Synonym: the answer belongs
/// to another card with the same prompt; Matched: that card's answer.
/// </summary>
public sealed record ExamItemResult(ExamQuestion Question, string Given, ExamMark Mark, double Points, string? Note = null,
    bool Synonym = false, string? Matched = null)
{
    public int Id => Question.Number;
}

/// <summary>The marked exam. ElapsedMs: time taken; TimedOut: the time ran out before it was handed in.</summary>
public sealed record ExamResult(IReadOnlyList<ExamItemResult> Items, ExamTolerance Tolerance, double ElapsedMs, bool TimedOut)
{
    public double Points => Items.Sum(i => i.Points);
    public int MaxPoints => Items.Count;
    /// <summary>The Swiss grade (1…6, tenths).</summary>
    public double Grade => Exam.Grade(Points, MaxPoints);

    public int Count(ExamMark mark) => Items.Count(i => i.Mark == mark);

    /// <summary>The cards worth practising: wrong, left blank, or with a small mistake.</summary>
    public IReadOnlyList<string> CardIdsToPractise =>
        Items.Where(i => i.Mark != ExamMark.Correct).Select(i => i.Question.CardId).Distinct(StringComparer.Ordinal).ToList();
}

/// <summary>The exam's logic (see the file header).</summary>
public static class Exam
{
    /// <summary>Notes that count as a small mistake (Tones: the accents of pinyin). A letter Variant and Pinyin-only are no mistake.</summary>
    public static readonly GradeNote[] SmallMistakes = [GradeNote.Article, GradeNote.Pronoun, GradeNote.LetterCase, GradeNote.Accents, GradeNote.Tones, GradeNote.Typo];

    /// <summary>Forms that are no mistake (any capitals are fine outside German).</summary>
    internal static readonly Tolerance AcceptedForms = new(Articles: false, Abbreviations: true, MultipleAnswers: true, Parentheses: true,
        IgnoreCase: true, IgnoreAccents: false, Typos: false);

    /// <summary>The forms that are no mistake plus the small mistakes.</summary>
    internal static readonly Tolerance SmallMistakesAllowed = new(Articles: true, Abbreviations: true, MultipleAnswers: true, Parentheses: true,
        IgnoreCase: true, IgnoreAccents: true, Typos: true);

    // MARK: - The sheet

    /// <summary>
    /// The cards an exam can ask: both sides with text, each id once, in set order; only <paramref name="cardIds"/> when given
    /// (a retake of the wrong ones), else only the starred ones when the settings ask for them and there are any.
    /// </summary>
    public static List<Card> Scope(IReadOnlyList<Card> cards, ExamSettings settings, IReadOnlyList<string>? cardIds = null)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var pool = cards.Where(c => c.Id.Length > 0 && HasText(c.Term) && HasText(c.Definition) && seen.Add(c.Id)).ToList();
        if (cardIds is not null)
        {
            var wanted = new HashSet<string>(cardIds, StringComparer.Ordinal);
            pool = pool.Where(c => wanted.Contains(c.Id)).ToList();
        }
        else if (settings.StarredOnly && pool.Any(c => c.Starred)) pool = pool.Where(c => c.Starred).ToList();
        return pool;
    }

    /// <summary>How many questions an exam over <paramref name="available"/> cards asks.</summary>
    public static int QuestionCount(ExamSettings settings, int available) => settings.Count > 0 ? Math.Min(settings.Count, available) : available;

    /// <summary>The exam sheet: settings.Count cards of the scope (all for 0) in random order, each asked on the side the settings say.</summary>
    public static List<ExamQuestion> MakeQuestions(IReadOnlyList<Card> cards, ExamSettings settings, Lang termLang, Lang defLang,
        IReadOnlyList<string>? cardIds = null, RNG? rng = null)
    {
        rng ??= Rand.SystemRNG();
        var pool = Scope(cards, settings, cardIds);
        var picked = Shuffled(pool, rng).Take(QuestionCount(settings, pool.Count)).ToList();
        var output = new List<ExamQuestion>();
        for (int index = 0; index < picked.Count; index++)
        {
            var card = picked[index];
            var ask = settings.AnswerWith switch
            {
                AnswerWith.Term => AskSide.Term,
                AnswerWith.Definition => AskSide.Definition,
                _ => RandomIndex(rng, 2) == 0 ? AskSide.Term : AskSide.Definition,
            };
            bool askTerm = ask == AskSide.Term;
            output.Add(new ExamQuestion(index + 1, card.Id, ask, JSCompat.Trim(askTerm ? card.Definition : card.Term),
                JSCompat.Trim(askTerm ? card.Term : card.Definition), askTerm ? defLang : termLang, askTerm ? termLang : defLang));
        }
        return output;
    }

    // MARK: - Marking

    /// <summary>Marks one answer. cards: the set's cards (an answer right for another card with the same prompt counts too).</summary>
    public static ExamItemResult Mark(string given, ExamQuestion question, IReadOnlyList<Card> cards, ExamTolerance tolerance)
    {
        var answer = JSCompat.Trim(given);
        var item = new ExamItemResult(question, answer, ExamMark.Blank, 0);
        if (!HasText(answer)) return item;
        var card = question.Card;
        SynonymGradeResult Graded(Tolerance allowed) => Synonyms.GradeWithSynonyms(answer, card, cards, question.Ask, allowed, question.AnswerLang);
        // The answer of the card the typed one matched, when that is another card.
        string? MatchedAnswer(SynonymGradeResult g) =>
            g.MatchedCard is { } m ? JSCompat.Trim(question.Ask == AskSide.Term ? m.Term : m.Definition) : null;

        var first = Graded(AcceptedForms);
        if (first.Result.Correct)
        {
            var small = first.Result.Notes.Where(SmallMistakes.Contains).ToList();
            item = item with { Synonym = first.IsSynonym, Matched = MatchedAnswer(first) };
            return small.Count == 0
                ? item with { Mark = ExamMark.Correct, Points = 1, Note = first.IsSynonym ? Labels.NOTE_LABELS.GetValueOrDefault(GradeNote.Synonym) : null }
                : item with { Mark = ExamMark.Minor, Points = tolerance.MinorPoints(), Note = NoteText(small) };
        }

        var second = Graded(SmallMistakesAllowed);
        if (second.Result.Correct)
            return item with
            {
                Mark = ExamMark.Minor, Points = tolerance.MinorPoints(), Synonym = second.IsSynonym, Matched = MatchedAnswer(second),
                Note = NoteText(second.Result.Notes.Where(SmallMistakes.Contains).ToList()) ?? Labels.NOTE_LABELS.GetValueOrDefault(GradeNote.Typo),
            };
        return item with { Mark = ExamMark.Wrong, Note = second.Result.Hint is { } h ? Labels.HINT_LABELS.GetValueOrDefault(h) : null };
    }

    /// <summary>Marks the whole sheet (answers by question number).</summary>
    public static ExamResult Evaluate(IReadOnlyList<ExamQuestion> questions, IReadOnlyDictionary<int, string> answers, IReadOnlyList<Card> cards,
        ExamTolerance tolerance, double elapsedMs, bool timedOut = false) =>
        new(questions.Select(q => Mark(answers.GetValueOrDefault(q.Number) ?? "", q, cards, tolerance)).ToList(), tolerance,
            Math.Max(0, double.IsFinite(elapsedMs) ? elapsedMs : 0), timedOut);

    // MARK: - The grade

    /// <summary>
    /// The Swiss grade for points of maxPoints: 1 + 5 × points / maximum, rounded to tenths (6 = everything
    /// right, 4 = half the points, the pass mark).
    /// </summary>
    public static double Grade(double points, int maxPoints)
    {
        if (maxPoints <= 0 || !double.IsFinite(points)) return 1;
        double clamped = Math.Min(maxPoints, Math.Max(0, points));
        // In tenths in one step: 34.5 of 50 is exactly 4.45 and must round up to 4.5.
        return Math.Round(10 + 50 * clamped / maxPoints, MidpointRounding.AwayFromZero) / 10;
    }

    /// <summary>"5.3" (Swiss notation, always one decimal).</summary>
    public static string GradeText(double grade)
    {
        int tenths = (int)Math.Round(grade * 10, MidpointRounding.AwayFromZero);
        return $"{tenths / 10}.{Math.Abs(tenths % 10)}";
    }

    /// <summary>"17.5" or "18" (points, halves where there are any).</summary>
    public static string PointsText(double points)
    {
        int halves = (int)Math.Round(points * 2, MidpointRounding.AwayFromZero);
        return halves % 2 == 0 ? $"{halves / 2}" : $"{halves / 2}.5";
    }

    /// <summary>4 and above passes.</summary>
    public static bool Passes(double grade) => grade >= 4;

    /// <summary>The results' title by grade.</summary>
    public static string Verdict(double grade) => grade switch
    {
        >= 6 => L("Perfekt!"),
        >= 5.5 => L("Hervorragend!"),
        >= 5 => L("Sehr gut!"),
        >= 4.5 => L("Gut gemacht!"),
        >= 4 => L("Bestanden!"),
        _ => L("Noch nicht genügend"),
    };

    // MARK: - Internals

    /// <summary>The labels of small mistakes, joined ("Artikel fehlte · Akzente").</summary>
    internal static string? NoteText(IEnumerable<GradeNote> notes)
    {
        var labels = notes.Select(n => Labels.NOTE_LABELS.GetValueOrDefault(n)).OfType<string>().ToList();
        return labels.Count == 0 ? null : string.Join(" · ", labels);
    }

    internal static bool HasText(string s)
    {
        foreach (char c in s)
            if (!JSCompat.IsWhitespace(c)) return true;
        return false;
    }

    /// <summary>Integer in [0, n) from the rng, clamped so a misbehaving rng never breaks an index.</summary>
    internal static int RandomIndex(RNG rng, int n)
    {
        double r = Math.Floor(rng() * n);
        if (!(r >= 0)) return 0;
        if (r > n - 1) return n - 1;
        return (int)r;
    }

    /// <summary>Fisher–Yates on a copy.</summary>
    internal static List<T> Shuffled<T>(IReadOnlyList<T> list, RNG rng)
    {
        var a = list.ToList();
        for (int i = a.Count - 1; i > 0; i--)
        {
            int j = RandomIndex(rng, i + 1);
            (a[i], a[j]) = (a[j], a[i]);
        }
        return a;
    }
}

/// <summary>Texts of the exam settings and results (German source, translated with <see cref="CoreText.L(string)"/>).</summary>
public static class ExamCopy
{
    /// <summary>"Ohne Zeitlimit", "1 Minute", "10 Minuten".</summary>
    public static string Minutes(int minutes) => minutes <= 0 ? L("Ohne Zeitlimit") : Labels.Plural(minutes, "Minute", "Minuten");

    public static string ToleranceTitle(ExamTolerance tolerance) => tolerance switch
    {
        ExamTolerance.Strict => L("Streng"),
        ExamTolerance.Half => L("Halber Punkt"),
        _ => L("Grosszügig"),
    };

    /// <summary>What a small mistake costs.</summary>
    public static string ToleranceText(ExamTolerance tolerance) => tolerance switch
    {
        ExamTolerance.Strict => L("Nur ganz richtige Antworten geben einen Punkt."),
        ExamTolerance.Half => L("Ein kleiner Fehler kostet einen halben Punkt."),
        _ => L("Kleine Fehler kosten nichts."),
    };

    /// <summary>Which mistakes are small.</summary>
    public static string SmallMistakesText =>
        L("Kleine Fehler sind ein Tippfehler, fehlende Akzente, die Grossschreibung deutscher Nomen und ein fehlender Artikel oder ein fehlendes Pronomen. Ein falscher Artikel ist ein Fehler.");

    /// <summary>"17.5 von 20 Punkten".</summary>
    public static string ScoreLine(ExamResult result) => L($"{Exam.PointsText(result.Points)} von {Labels.Plural(result.MaxPoints, "Punkt", "Punkten")}");

    /// <summary>The mark's label in the results ("Richtig", "Halber Punkt", …).</summary>
    public static string MarkLabel(ExamItemResult item) => item.Mark switch
    {
        ExamMark.Correct => L("Richtig"),
        ExamMark.Minor => item.Points switch
        {
            1 => L("Richtig"),
            0.5 => L("Halber Punkt"),
            _ => L("Kleiner Fehler"),
        },
        ExamMark.Wrong => L("Falsch"),
        _ => L("Keine Antwort"),
    };
}
