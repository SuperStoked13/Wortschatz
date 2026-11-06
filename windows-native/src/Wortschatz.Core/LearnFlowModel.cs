namespace Wortschatz.Core;

// Port of LearnFlowModel.swift: pure helpers of the Learn screen, a port of src/screens/learn-model.js
// (praise, resuming a stored session and its open "Nicht ganz" screen, options that need a restart,
// option texts after edits, checkpoint status, the segmented progress bar and the German copy texts) and
// of the parts of src/screens/write-model.js the Learn screen uses. Swiss spelling: "ss", never "ß".

public static partial class LearnFlow
{
    // MARK: - Copy

    /// <summary>Praise after a correct answer, varied (never the same twice in a row).</summary>
    public static readonly string[] PRAISE = ["Super!", "Klasse!", "Genau!", "Weiter so!", "Stark!"];
    /// <summary>Title after a wrong answer.</summary>
    public const string MISS_TITLE = "Nicht ganz – das lernst du noch!";
    /// <summary>Title after "Weiss ich nicht?" (short enough for one line).</summary>
    public const string DONT_KNOW_TITLE = "Kein Problem – merk sie dir!";
    /// <summary>Title of a correct answer that belongs to another card with the same prompt.</summary>
    public const string SYNONYM_TITLE = "Auch richtig!";
    /// <summary>Title of a correct answer that was accepted with a tolerance (not exact).</summary>
    public const string TOLERATED_TITLE = "Richtig!";
    /// <summary>The intro hint shown until the first checkpoint.</summary>
    public const string INTRO_HINT = "Neue Begriffe kommen zuerst als Multiple Choice – beim nächsten Mal schreibst du sie.";
    /// <summary>Shown when the edited card now accepts what was typed.</summary>
    public const string EDITED_CORRECT_TEXT = "Mit deiner Korrektur stimmt deine Antwort jetzt.";
    /// <summary>Toast when a session is resumed with answers.</summary>
    public const string WELCOME_BACK = "Willkommen zurück – weiter geht's";
    /// <summary>The mark of a repetition question (Wiederholungsfrage) of a mastered card.</summary>
    public const string REVIEW_LABEL = "Wiederholung";
    /// <summary>After a missed repetition question: the card is learned again.</summary>
    public const string DEMOTED_TEXT = "Wieder am Lernen";

    /// <summary>Auto-advance after a correct answer, and after one with notes ("Genau: …" needs reading).</summary>
    public const int ADVANCE_MS = 900;
    public const int ADVANCE_MS_WITH_NOTES = 1800;
    /// <summary>Key presses this soon after a transition are swallowed, so one press never skips a step.</summary>
    public const double INPUT_LOCK_MS = 280;
    /// <summary>After a correct answer a press within the lock moves on when it ends; closer presses count as the answering press.</summary>
    public const double SKIP_MIN_GAP_MS = 50;
    /// <summary>The progress bar has one segment per round-sized batch, at most this many.</summary>
    public const int MAX_SEGMENTS = 12;
    /// <summary>A stored written answer is kept up to this many UTF-16 units.</summary>
    public const int MAX_GIVEN = 1000;

    const int DefaultRoundSize = 7;

    /// <summary>A semantic tone (chips, toasts); the design system maps it to colours.</summary>
    public enum Tone { Neutral, Success, Warning }

    /// <summary>
    /// <c>pickPraise(previous, rng, pool)</c>: a uniformly picked entry of pool other than previous (falls back to the
    /// whole pool when nothing else is left). Tolerates an rng returning values outside [0, 1).
    /// </summary>
    public static string PickPraise(string? previous = null, RNG? rng = null, IReadOnlyList<string>? pool = null)
    {
        rng ??= Rand.SystemRNG();
        var list = pool is { Count: > 0 } ? pool : PRAISE;
        var others = list.Where(p => p != previous).ToList();
        var from = others.Count == 0 ? list.ToList() : others;
        double r = Math.Floor(rng() * from.Count);
        if (!(r >= 0)) return from[0];
        return from[r > from.Count - 1 ? from.Count - 1 : (int)r];
    }

    // MARK: - Resuming

    /// <summary>
    /// <c>canResumeLearn</c>: a stored session is resumed unless a fresh one was requested, it is finished or empty, or
    /// a different subset was asked for (null = any).
    /// </summary>
    public static bool CanResumeLearn(LearnState? saved, bool forceNew = false, StudySubset? subset = null)
    {
        if (forceNew || saved is null || saved.FinishedAt is not null || saved.Order.Count == 0 || LearnEngine.IsFinished(saved)) return false;
        return subset is null || saved.Subset.Equals(subset);
    }

    /// <summary>Whether the session has answers (in this round or in earlier ones).</summary>
    public static bool HasLearnAnswers(LearnState? state) =>
        state is not null && (state.Answered > 0 || state.Rounds.Count > 0 || state.RoundLog.Count > 0);

    /// <summary>
    /// <c>pendingLearnFeedback(state, feedback)</c>: the "Nicht ganz" screen that was open when the session was left,
    /// from the feedback record stored next to the state. Valid while it describes the state's last answer and that
    /// answer is still counted as wrong. Returns the cleaned record or null.
    /// </summary>
    public static PendingFeedback? PendingFeedbackOf(LearnState state, JSONValue? feedback)
    {
        if (feedback?.ObjectValue is null || state.Last is not { Correct: false } last) return null;
        var cardId = last.CardId;
        if (feedback["qid"]?.StringValue is not { } qid || qid != last.Qid) return null;
        if (feedback["cardId"] is not { } rawId || rawId.IsNull || LearnEngine.JsString(rawId) != cardId) return null;
        if (!state.Order.Contains(cardId)) return null;
        var type = feedback["type"]?.StringValue == "mc" ? QuestionType.Mc : QuestionType.Written;
        if (type != last.Type) return null;
        if (type == QuestionType.Mc)
        {
            if (CleanChoices(feedback["choices"], cardId) is not { } choices) return null;
            string? chosen = feedback["chosen"] is { IsNull: false } c ? LearnEngine.JsString(c) : null;
            // A chosen option must be one of the wrong ones (null = "Weiss ich nicht").
            if (chosen is not null && (chosen == cardId || !choices.Any(x => x.CardId == chosen))) return null;
            return PendingFeedback.Mc(qid, cardId, last.Ask, choices, chosen);
        }
        var given = feedback["given"]?.StringValue is { } g ? WriteFlow.Utf16Prefix(g, MAX_GIVEN) : "";
        return PendingFeedback.Written(qid, cardId, last.Ask, given, feedback["dontKnow"]?.BoolValue == true || !HasText(given));
    }

    /// <summary><c>pendingFeedback</c> for a typed record (validated the same way).</summary>
    public static PendingFeedback? PendingFeedbackOf(LearnState state, PendingFeedback? feedback) =>
        feedback is null ? null : PendingFeedbackOf(state, feedback.ToJson());

    // MARK: - Options that need a restart

    /// <summary>A setting that shapes a running session: it only applies to a new one.</summary>
    public enum SettingsChange { Direction, Types, RoundSize, Review, Recheck }

    /// <summary>
    /// The options a session was built with (<c>sessionSettings</c>); Review: with repetition questions; Recheck: with
    /// rechecks (Nachkontrolle; only sessions with more than RECHECK_MIN_CARDS cards have them).
    /// </summary>
    public sealed record SessionSettings(AnswerWith AnswerWith, int RoundSize, bool Mc, bool Written, bool Review = false, bool Recheck = false);

    public static SessionSettings SessionSettingsOf(LearnState state) =>
        MakeSettings(state.AnswerWith, state.Learn.RoundSize, state.Learn.Mc, state.Learn.Written, state.Review is not null, state.Recheck is not null);

    /// <summary>
    /// The settings a new session would get (review: the repetition questions are on; recheck: rechecks would apply,
    /// i.e. the option is on and the session has more than RECHECK_MIN_CARDS cards).
    /// </summary>
    public static SessionSettings SessionSettingsOf(StudyOptions options, bool review = false, bool recheck = false) =>
        MakeSettings(options.AnswerWith, options.Learn.RoundSize, options.Learn.Mc, options.Learn.Written, review, recheck);

    static SessionSettings MakeSettings(AnswerWith answerWith, int roundSize, bool mc, bool written, bool review, bool recheck)
    {
        bool both = mc || written;
        return new SessionSettings(answerWith, roundSize >= 1 ? roundSize : DefaultRoundSize, both ? mc : true, both ? written : true, review, recheck);
    }

    /// <summary>Which session-shaping settings differ: direction, question types, round size, repetition questions, rechecks (in this order).</summary>
    public static List<SettingsChange> SettingsChanges(SessionSettings a, SessionSettings b)
    {
        var output = new List<SettingsChange>();
        if (a.AnswerWith != b.AnswerWith) output.Add(SettingsChange.Direction);
        if (a.Mc != b.Mc || a.Written != b.Written) output.Add(SettingsChange.Types);
        if (a.RoundSize != b.RoundSize) output.Add(SettingsChange.RoundSize);
        if (a.Review != b.Review) output.Add(SettingsChange.Review);
        if (a.Recheck != b.Recheck) output.Add(SettingsChange.Recheck);
        return output;
    }

    /// <summary>"Neu starten?" after options that only apply to a new session.</summary>
    public static string RestartMessage(IReadOnlyList<SettingsChange> changes)
    {
        var lead = changes.Count == 1
            ? changes[0] switch
            {
                SettingsChange.Direction => "Die neue Abfragerichtung gilt",
                SettingsChange.Types => "Die neuen Fragetypen gelten",
                SettingsChange.RoundSize => "Die neue Rundengrösse gilt",
                SettingsChange.Recheck => "Die Einstellung für die Nachkontrolle gilt",
                _ => "Die Einstellung für Wiederholungsfragen gilt",
            }
            : "Die neuen Einstellungen gelten";
        return $"{lead} ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.";
    }

    /// <summary>"Neu starten?" in a running session: what the new one covers.</summary>
    public static string RestartSessionMessage(StudySubset? subset = null)
    {
        var what = (subset ?? StudySubset.All).Kind switch
        {
            StudySubsetKind.Starred => "mit allen markierten Begriffen, die noch nicht sitzen",
            StudySubsetKind.Missed => "mit allen zuletzt falsch beantworteten Begriffen",
            StudySubsetKind.CardIds => "mit den ausgewählten Begriffen, die noch nicht sitzen",
            _ => "mit allen Begriffen, die noch nicht sitzen",
        };
        return $"Du beginnst eine neue Lerneinheit {what}. Dein Lernfortschritt bleibt gespeichert.";
    }

    /// <summary>What a new session with a subset asks (for "Laufende Lerneinheit beenden?").</summary>
    public static string SubsetWhat(StudySubset subset) => subset.Kind switch
    {
        StudySubsetKind.All => "alle Begriffe",
        StudySubsetKind.Starred => "nur die markierten Begriffe",
        StudySubsetKind.Learning => "nur die nicht gemeisterten Begriffe",
        StudySubsetKind.Missed => "nur die zuletzt falsch beantworteten Begriffe",
        _ => "eine neue Auswahl",
    };

    // MARK: - Question texts

    /// <summary>The texts of a question's options from the current cards (so edits show at once); the stored text is kept for a gone or empty card.</summary>
    public static List<Choice> ChoiceTexts(IReadOnlyList<Choice> choices, IReadOnlyList<Card> cards, AskSide ask)
    {
        var byId = CardsById(cards);
        return choices.Select(c =>
        {
            var live = byId.TryGetValue(c.CardId, out var card) ? JSCompat.Trim(Synonyms.AnswerSide(card, ask)) : "";
            return new Choice(c.CardId, live.Length == 0 ? c.Text : live);
        }).ToList();
    }

    /// <summary>Everything the question card shows for question q of card (<c>questionInfo</c>). Ask Term: the definition is shown and the term typed.</summary>
    public static QuestionInfo QuestionInfoOf(LearnEngine.Question q, Card card, IReadOnlyList<Card> cards, Lang termLang, Lang defLang)
    {
        bool askTerm = q.Ask == AskSide.Term;
        var promptLang = askTerm ? defLang : termLang;
        var answerLang = askTerm ? termLang : defLang;
        bool sameLang = termLang == defLang;
        IReadOnlyList<Choice> stored = q.Type == QuestionType.Mc ? q.Choices ?? [] : [];
        return new QuestionInfo(q.Qid, card.Id, q.Type, q.Ask, askTerm ? card.Definition : card.Term, askTerm ? card.Term : card.Definition,
            promptLang, answerLang,
            sameLang || promptLang == Lang.Other ? (askTerm ? "Definition" : "Begriff") : Labels.LangName(promptLang),
            sameLang || answerLang == Lang.Other ? "Antwort eingeben" : $"Antwort auf {Labels.LangName(answerLang)} eingeben",
            sameLang || answerLang == Lang.Other ? "Antwort eingeben" : $"Auf {Labels.LangName(answerLang)} …",
            card.Starred, ChoiceTexts(stored, cards, q.Ask), stored, q.IsReview);
    }

    /// <summary>
    /// Grades the written answer of info (<c>gradeQuestion</c>): an answer right for another card with the same prompt
    /// counts too, and so does one of extraAnswers (synonyms that are not in the set).
    /// </summary>
    public static SynonymGradeResult GradeQuestion(QuestionInfo info, string given, IReadOnlyList<Card> cards, Tolerance tolerance, IReadOnlyList<string>? extraAnswers = null)
    {
        var card = cards.FirstOrDefault(c => c.Id == info.CardId);
        if (card is null) return new SynonymGradeResult(Grading.Grade(given, info.Expected, tolerance, info.AnswerLang));
        return Synonyms.GradeWithSynonyms(given, card, cards, info.Ask, tolerance, info.AnswerLang, extraAnswers ?? []);
    }

    /// <summary>The copy step after a miss needs the asked card's answer itself (no synonyms).</summary>
    public static bool CopyAccepted(string value, QuestionInfo info, Tolerance tolerance) =>
        HasText(value) && Grading.Grade(value, info.Expected, tolerance, info.AnswerLang).Correct;

    // MARK: - Checkpoint and finish texts

    /// <summary>The status chip of a card by its stage; SystemImage: the Mac's SF Symbol for the chip, if any.</summary>
    public sealed record StageStatus(CardStatus Status, string Label, Tone Tone, string? SystemImage);

    /// <summary>Gemeistert / Am Lernen / Noch neu.</summary>
    public static StageStatus StageStatusOf(int stage) =>
        stage >= 2 ? new(CardStatus.Mastered, "Gemeistert", Tone.Success, "checkmark")
        : stage == 1 ? new(CardStatus.Learning, "Am Lernen", Tone.Warning, null)
        : new(CardStatus.New, "Noch neu", Tone.Neutral, null);

    /// <summary>The checkpoint chip of a card answered in the round: stage 0 there means "answered wrong" (Am Lernen, not Neu).</summary>
    public static StageStatus CheckpointStatus(int stage) => StageStatusOf(stage >= 1 ? stage : 1);

    /// <summary>"18 von 52 gemeistert"</summary>
    public static string MasteredLine(int mastered, int total) => $"{mastered} von {total} gemeistert";

    /// <summary>The checkpoint title by the round's share of correct answers.</summary>
    public static string CheckpointTitle(double ratio) =>
        ratio >= 0.9 ? "Hervorragend!" : ratio >= 0.7 ? "Gut gemacht!" : ratio >= 0.4 ? "Du machst Fortschritte!" : "Dranbleiben – das wird!";

    /// <summary>What is left after a checkpoint, e.g. "Noch 34 Begriffe, bis alles sitzt."</summary>
    public static string RemainingText(int mastered, int total)
    {
        int left = Math.Max(0, total - mastered);
        return left == 0 ? "Alles sitzt!" : $"Noch {Labels.Plural(left, "Begriff", "Begriffe")}, bis alles sitzt.";
    }

    /// <summary>"5 richtige Antworten von 7 in dieser Runde. Noch 34 Begriffe, bis alles sitzt."</summary>
    public static string CheckpointText(LearnEngine.Checkpoint cp) =>
        $"{Labels.Plural(cp.Correct, "richtige Antwort", "richtige Antworten")} von {cp.Answered} in dieser Runde. "
        + RemainingText(cp.Counts.Mastered, cp.Counts.Total);

    /// <summary>The adjective naming a session's scope ("markierten ", …, with a trailing space; "" for the whole set).</summary>
    static string ScopeAdjective(StudySubset subset) => subset.Kind switch
    {
        StudySubsetKind.CardIds => "ausgewählten ",
        StudySubsetKind.Starred => "markierten ",
        StudySubsetKind.Learning => "offenen ",
        StudySubsetKind.Missed => "falsch beantworteten ",
        _ => "",
    };

    /// <summary>"Du hast alle markierten Begriffe gemeistert!" (the finish screen's title).</summary>
    public static string FinishTitle(StudySubset? subset = null, int total = 2)
    {
        var adj = ScopeAdjective(subset ?? StudySubset.All);
        return total == 1 ? $"Du hast den {adj}Begriff gemeistert!" : $"Du hast alle {adj}Begriffe gemeistert!";
    }

    /// <summary>
    /// "Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!" or "44 Begriffe in 16 Runden gemeistert, 6 sassen
    /// schon vorher – stark!" (cards mastered before the session apart).
    /// </summary>
    public static string FinishSubtitle(int total, int rounds, int alreadyMastered = 0, StudySubset? subset = null)
    {
        var when = rounds > 0 ? $" in {Labels.Plural(rounds, "Runde", "Runden")}" : "";
        int before = Math.Max(0, alreadyMastered);
        int learned = total - before;
        if (before > 0 && learned > 0)
            return $"{Labels.Plural(learned, "Begriff", "Begriffe")}{when} gemeistert, {before} {(before == 1 ? "sass" : "sassen")} schon vorher – stark!";
        var adj = ScopeAdjective(subset ?? StudySubset.All);
        var what = total == 1 ? $"Den {adj}Begriff" : $"Alle {total} {adj}Begriffe";
        return $"{what}{when} gemeistert – stark!";
    }

    public static string FinishSubtitle(LearnEngine.FinalStats stats, StudySubset? subset = null) =>
        FinishSubtitle(stats.Total, stats.Rounds, stats.AlreadyMastered, subset);

    /// <summary>"12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen." (finish screen); null before the first repetition question.</summary>
    public static string? ReviewLine(LearnEngine.ReviewStats stats)
    {
        if (stats.Asked <= 0) return null;
        var asked = Labels.Plural(stats.Asked, "gemeisterten Begriff", "gemeisterte Begriffe");
        int missed = stats.Asked - stats.Kept;
        if (missed == 0) return $"{asked} wiederholt, {(stats.Asked == 1 ? "er sass" : "alle sassen")} noch.";
        return $"{asked} wiederholt, {missed} davon {(missed == 1 ? "ist" : "sind")} wieder am Lernen.";
    }

    /// <summary>How many cards a scope covers, for the "everything mastered" screen.</summary>
    public static string ScopeText(StudySubset subset, int count)
    {
        if (subset.Equals(StudySubset.Starred)) return count == 1 ? "den markierten Begriff" : $"alle {count} markierten Begriffe";
        return count == 1 ? "den Begriff" : $"alle {count} Begriffe";
    }

    /// <summary>"18 von 52 gemeistert, 7 am Lernen, 27 neu"</summary>
    public static string ProgressText(int fresh, int learning, int mastered, int total) => $"{MasteredLine(mastered, total)}, {learning} am Lernen, {fresh} neu";

    public static string ProgressText(LearnEngine.Counts counts) => ProgressText(counts.Fresh, counts.Learning, counts.Mastered, counts.Total);

    // MARK: - Segmented progress bar

    /// <summary>One segment per round-sized batch, at least one, at most MAX_SEGMENTS.</summary>
    public static int SegmentCount(int total, int? roundSize)
    {
        if (total <= 0) return 1;
        int size = (roundSize ?? 0) >= 1 ? roundSize!.Value : DefaultRoundSize;
        return Math.Max(1, Math.Min(MAX_SEGMENTS, (total + size - 1) / size));
    }

    /// <summary>The fill of one bar segment (0…1): mastered (green) and reached = mastered + learning.</summary>
    public sealed record SegmentFill(double Mastered, double Reached);

    /// <summary>Fills the bar from the left: mastered, then learning.</summary>
    public static List<SegmentFill> SegmentFills(int mastered, int learning, int total, int count)
    {
        int n = Math.Max(1, count);
        double t = Math.Max(0, total);
        double Share(int v) => t > 0 ? Math.Max(0, v) / t * n : 0;
        double m = Share(mastered), r = Share(mastered + learning);
        static double Clamp01(double v) => Math.Min(1, Math.Max(0, v));
        return Enumerable.Range(0, n).Select(i => new SegmentFill(Clamp01(m - i), Clamp01(r - i))).ToList();
    }

    // MARK: - Internals

    /// <summary>JS <c>typeof v === 'string' &amp;&amp; v.trim() !== ''</c>.</summary>
    public static bool HasText(string s)
    {
        foreach (char c in s)
            if (!JSCompat.IsWhitespace(c)) return true;
        return false;
    }

    /// <summary>Cards by id; the first card wins for a repeated id (like the engine's card list).</summary>
    public static Dictionary<string, Card> CardsById(IEnumerable<Card> cards)
    {
        var output = new Dictionary<string, Card>(StringComparer.Ordinal);
        foreach (var card in cards) output.TryAdd(card.Id, card);
        return output;
    }

    /// <summary>A card can be asked only when both sides have text.</summary>
    public static bool IsUsable(Card? card) => card is not null && HasText(card.Term) && HasText(card.Definition);

    /// <summary><c>cleanChoices</c>: each card id once; kept only with two or more options including cardId.</summary>
    static List<Choice>? CleanChoices(JSONValue? v, string cardId)
    {
        if (v?.ArrayValue is not { } list) return null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var output = new List<Choice>();
        foreach (var c in list)
        {
            if (c.ObjectValue is null || c["cardId"] is not { } raw || raw.IsNull || raw.StringValue == "") continue;
            var id = LearnEngine.JsString(raw);
            if (!seen.Add(id)) continue;
            output.Add(new Choice(id, c["text"]?.StringValue ?? ""));
        }
        return output.Count >= 2 && seen.Contains(cardId) ? output : null;
    }
}
