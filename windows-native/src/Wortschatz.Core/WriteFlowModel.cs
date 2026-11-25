using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of WriteFlowModel.swift (src/screens/write-model.js): the pure helpers of Write mode. They build
// the question texts per direction, grade the main answer (synonym aware) and the copy step, decide
// whether a stored session is resumed (including a pending "Nicht ganz" screen) or its results are shown
// again, and format the results tile. The reducer in WriteFlow.cs / WriteFlowMachine.cs is built on them.

public static partial class WriteFlow
{
    // MARK: - Question

    /// <summary>
    /// Everything the question card shows for one question (<c>questionInfo</c>). Ask Term: the definition is
    /// shown and the term typed (and vice versa). PromptLabel: the prompt's language ("Französisch"), or
    /// "Definition"/"Begriff" when both sides share a language or it is unknown. Placeholder: "Antwort auf
    /// Französisch eingeben"; PlaceholderShort: "Auf Französisch …".
    /// </summary>
    public sealed record Question(string Qid, string CardId, AskSide Ask, string Prompt, string Expected, Lang PromptLang, Lang AnswerLang,
        string PromptLabel, string Placeholder, string PlaceholderShort, bool Starred)
    {
        /// <summary>The question for the synonym check (ExtendedSynonyms).</summary>
        public SynonymQuery SynonymQuery => new(Prompt, Expected, PromptLang, AnswerLang);

        /// <summary>The engine question this info was built from.</summary>
        public SessionQuestion SessionQuestion => new(Qid, CardId, Ask);
    }

    /// <summary><c>hasText</c>: a string with at least one non-whitespace character (JS trim).</summary>
    public static bool HasText(string? value)
    {
        if (value is null) return false;
        foreach (char c in value)
            if (!JSCompat.IsWhitespace(c)) return true;
        return false;
    }

    /// <summary><c>isUsableCard</c>: a card can be asked only when both sides have text.</summary>
    public static bool IsUsableCard(Card? card) => card is not null && HasText(card.Term) && HasText(card.Definition);

    /// <summary><c>questionInfo(set, card, q)</c>.</summary>
    public static Question QuestionInfo(VocabSet set, Card card, SessionQuestion q) => QuestionInfo(set.TermLang, set.DefLang, card, q);

    /// <summary><c>questionInfo</c> for a set given by its languages.</summary>
    public static Question QuestionInfo(Lang termLang, Lang defLang, Card card, SessionQuestion q)
    {
        bool askTerm = q.Ask == AskSide.Term;
        var promptLang = askTerm ? defLang : termLang;
        var answerLang = askTerm ? termLang : defLang;
        bool sameLang = termLang == defLang;
        bool plainAnswer = sameLang || answerLang == Lang.Other;
        return new Question(
            q.Qid, card.Id, askTerm ? AskSide.Term : AskSide.Definition,
            askTerm ? card.Definition : card.Term,
            askTerm ? card.Term : card.Definition,
            promptLang, answerLang,
            sameLang || promptLang == Lang.Other ? (askTerm ? L("Definition") : L("Begriff")) : Labels.LangName(promptLang),
            plainAnswer ? L("Antwort eingeben") : L($"Antwort auf {Labels.LangName(answerLang)} eingeben"),
            plainAnswer ? L("Antwort eingeben") : L($"Auf {Labels.LangName(answerLang)} …"),
            card.Starred);
    }

    // MARK: - Grading

    /// <summary>
    /// <c>gradeQuestion(set, info, given, tolerance)</c>: grades the main answer. An answer right for another
    /// card with the same prompt counts too. Falls back to plain grading against question.Expected when the
    /// card is not in the set. extraAnswers: synonyms that are not in the set (ExtendedSynonyms).
    /// </summary>
    public static SynonymGradeResult GradeQuestion(VocabSet? set, Question question, string given, Tolerance tolerance, IReadOnlyList<string>? extraAnswers = null)
    {
        var cards = set?.Cards ?? [];
        var card = cards.FirstOrDefault(c => c.Id == question.CardId);
        if (card is null) return new SynonymGradeResult(Grading.Grade(given, question.Expected, tolerance, question.AnswerLang));
        return Synonyms.GradeWithSynonyms(given, card, cards, question.Ask, tolerance, question.AnswerLang, extraAnswers ?? []);
    }

    /// <summary><c>copyAccepted</c>: the copy step after a miss needs the asked card's own answer (no synonyms) and a non-empty field.</summary>
    public static bool CopyAccepted(string? value, Question? question, Tolerance tolerance) =>
        question is not null && value is not null && HasText(value)
        && Grading.Grade(value, question.Expected, tolerance, question.AnswerLang).Correct;

    // MARK: - Pending "Nicht ganz" screen

    /// <summary>The "Nicht ganz" screen that was open when Write mode was left (<c>feedback</c>, stored next to the session).</summary>
    public sealed record PendingFeedback(string Qid, string Given = "", bool DontKnow = false) : IJsonEncodable
    {
        /// <summary>Lenient like write-model.js: null unless an object with a string qid; non-string given → "", dontKnow must be true.</summary>
        public static PendingFeedback? FromJson(JSONValue? json) =>
            json?.ObjectValue is not null && json["qid"]?.StringValue is { } qid
                ? new PendingFeedback(qid, json["given"]?.StringValue ?? "", json["dontKnow"]?.BoolValue == true)
                : null;

        public JSONValue ToJson() => JSONValue.Obj(("qid", Qid), ("given", Given), ("dontKnow", DontKnow));
    }

    /// <summary><c>MAX_GIVEN</c>: longer stored answers are cut (UTF-16 code units).</summary>
    public const int MaxGivenLength = 1000;

    /// <summary>
    /// <c>pendingFeedback(session, feedback)</c>: the stored record is valid while its question was missed in the
    /// running round and not counted as correct since. Returns the cleaned record (answer capped) or null.
    /// </summary>
    public static PendingFeedback? PendingFeedbackOf(SessionState? session, PendingFeedback? feedback)
    {
        if (session is null || feedback is null) return null;
        var qid = feedback.Qid;
        if (!session.Questions.ContainsKey(qid)) return null;
        if (session.Done.Contains(qid) || session.Queue.Contains(qid)) return null;
        var last = session.RoundAnswered.LastOrDefault(a => a.Qid == qid);
        if (last is null || last.Correct) return null;
        return new PendingFeedback(qid, Utf16Prefix(feedback.Given, MaxGivenLength), feedback.DontKnow);
    }

    /// <summary><c>pendingFeedback</c> for a raw stored record.</summary>
    public static PendingFeedback? PendingFeedbackOf(SessionState? session, JSONValue? feedback) => PendingFeedbackOf(session, PendingFeedback.FromJson(feedback));

    // MARK: - Resuming

    /// <summary>
    /// Whether a requested subset matches the stored session's: no request matches anything, named subsets match
    /// by value. A card-id list never matches (JS compares it by identity).
    /// </summary>
    internal static bool SubsetMatches(StudySubset stored, StudySubset? wanted)
    {
        if (wanted is null) return true;
        if (wanted.Kind == StudySubsetKind.CardIds) return false;
        return stored.Equals(wanted);
    }

    /// <summary>
    /// <c>canResume(saved, { forceNew, subset })</c>: a stored session is resumed unless a fresh one was requested,
    /// it is finished or empty, or a different named subset was asked for.
    /// </summary>
    public static bool CanResume(SessionState? saved, bool forceNew = false, StudySubset? subset = null) =>
        !forceNew && saved is not null && saved.FinishedAt is null && saved.Order.Count > 0 && !WriteSession.IsFinished(saved)
        && SubsetMatches(saved.Subset, subset);

    /// <summary>
    /// <c>canShowResults(saved, { forceNew, subset, marker })</c>: a finished session is shown again when the
    /// screen that ran it comes back; marker is the startedAt of the session that screen showed.
    /// </summary>
    public static bool CanShowResults(SessionState? saved, bool forceNew = false, StudySubset? subset = null, double? marker = null) =>
        !forceNew && saved is not null && marker is { } m && saved.FinishedAt is not null && saved.Order.Count > 0 && m == saved.StartedAt
        && SubsetMatches(saved.Subset, subset);

    /// <summary><c>hasAnswers(session)</c>: something was answered already (a closed round or the current one).</summary>
    public static bool HasAnswers(SessionState session) => session.Rounds.Count > 0 || session.RoundAnswered.Count > 0;

    // MARK: - Stored form

    /// <summary>
    /// The stored form of write.js: the session's JSON plus the open "Nicht ganz" screen under <c>feedback</c>.
    /// Save it with LibraryStore.SaveSessionJSON.
    /// </summary>
    public static JSONValue StoredJSON(SessionState session, PendingFeedback? feedback)
    {
        var json = session.ToJson();
        if (feedback is null) return json;
        var o = new JsonObjectMap();
        foreach (var (k, v) in json.ObjectValue!) o[k] = v;
        o["feedback"] = feedback.ToJson();
        return JSONValue.Object(o);
    }

    /// <summary>Splits a stored Write session (LibraryStore.GetSessionJSON) into the repaired session and its raw feedback record.</summary>
    public static (SessionState Session, PendingFeedback? Feedback)? DecodeStored(JSONValue? json) =>
        json is { IsObject: true } ? (WriteSession.CopyState(json), PendingFeedback.FromJson(json["feedback"])) : null;

    // MARK: - Results tile, special-character rows

    /// <summary>A study time short enough for one line: "42 Sek.", "2:47" (minutes) or "1:02:47" (hours); Label names the unit.</summary>
    public sealed record CompactDuration(string Value, string Label);

    /// <summary><c>compactDuration(ms)</c>. NaN, negative and infinite values give "0 Sek.".</summary>
    public static CompactDuration CompactDurationOf(double ms)
    {
        double seconds = double.IsFinite(ms) ? Math.Max(0, JSCompat.Round(ms / 1000)) : 0;
        long total = (long)Math.Min(seconds, 9_007_199_254_740_992);
        long h = total / 3600, m = total % 3600 / 60;
        var ss = TwoDigits(total % 60);
        if (h > 0) return new CompactDuration($"{h}:{TwoDigits(m)}:{ss}", L("Zeit (Std.)"));
        if (m > 0) return new CompactDuration($"{m}:{ss}", L("Zeit (Min.)"));
        return new CompactDuration(L($"{total} Sek."), L("Zeit"));
    }

    /// <summary>
    /// <c>charColumns(count, perRow)</c>: the column count for special-character keys laid out in the fewest
    /// balanced rows of at most perRow keys. Non-finite input counts as 0.
    /// </summary>
    public static int CharColumns(double count, double perRow)
    {
        double n = double.IsFinite(count) ? Math.Max(0, Math.Floor(count)) : 0;
        double most = Math.Max(1, double.IsFinite(perRow) ? Math.Floor(perRow) : 0);
        if (n == 0) return 1;
        return (int)Math.Ceiling(n / Math.Ceiling(n / most));
    }

    // MARK: - Term rows (summary, results)

    /// <summary>
    /// A row of the round summary or the "Am häufigsten falsch" list (<c>termRows</c>). Id: the question id
    /// (summary) or the card id (results). Correct: summary rows; Misses: results rows.
    /// </summary>
    public sealed record TermRow(string Id, string CardId, string Term, string Definition, Lang TermLang, Lang DefLang, bool? Correct = null, int? Misses = null)
    {
        /// <summary>"2× falsch" (results rows).</summary>
        public string? MissesLabel => Misses is { } m ? L($"{m}× falsch") : null;
    }

    /// <summary>The card of each id like the JS Map of write.js (the last card with an id wins).</summary>
    internal static Dictionary<string, Card> CardIndex(IEnumerable<Card> cards)
    {
        var index = new Dictionary<string, Card>(StringComparer.Ordinal);
        foreach (var card in cards) index[card.Id] = card;
        return index;
    }

    internal static List<TermRow> TermRows(VocabSet set, IEnumerable<(string Id, string CardId, bool? Correct, int? Misses)> items)
    {
        var cards = CardIndex(set.Cards);
        return items.Where(i => cards.ContainsKey(i.CardId))
            .Select(i => { var c = cards[i.CardId]; return new TermRow(i.Id, i.CardId, c.Term, c.Definition, set.TermLang, set.DefLang, i.Correct, i.Misses); })
            .ToList();
    }

    // MARK: - Internals

    static string TwoDigits(long n) => n < 10 ? $"0{n}" : $"{n}";

    /// <summary>JS <c>s.slice(0, n)</c> on UTF-16 code units. A surrogate pair cut in half is dropped (like Swift).</summary>
    internal static string Utf16Prefix(string s, int n)
    {
        if (s.Length <= n) return s;
        int end = n;
        if (end > 0 && char.IsHighSurrogate(s[end - 1]) && char.IsLowSurrogate(s[end])) end--;
        return s[..end];
    }

    /// <summary>The number of UTF-16 code units outside JS whitespace (<c>s.replace(/\s/g, '').length</c>).</summary>
    internal static int NonWhitespaceLength(string s) => s.Count(c => !JSCompat.IsWhitespace(c));
}
