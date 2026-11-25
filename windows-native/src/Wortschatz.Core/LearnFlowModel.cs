using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of LearnFlowModel.swift: pure helpers of the Learn screen, a port of src/screens/learn-model.js
// (praise, resuming a stored session and its open "Nicht ganz" screen, options that need a restart,
// option texts after edits, checkpoint status, the segmented progress bar and the copy texts – German source, Swiss
// spelling ("ss", never "ß"), translated with CoreText.L) and of the parts of src/screens/write-model.js the Learn
// screen uses.

public static partial class LearnFlow
{
    // MARK: - Copy

    /// <summary>Praise after a correct answer, varied (never the same twice in a row).</summary>
    public static string[] PRAISE => [L("Super!"), L("Klasse!"), L("Genau!"), L("Weiter so!"), L("Stark!")];
    /// <summary>Title after a wrong answer.</summary>
    public static string MISS_TITLE => L("Nicht ganz – das lernst du noch!");
    /// <summary>Title after "Weiss ich nicht?" (short enough for one line).</summary>
    public static string DONT_KNOW_TITLE => L("Kein Problem – merk sie dir!");
    /// <summary>Title of a correct answer that belongs to another card with the same prompt.</summary>
    public static string SYNONYM_TITLE => L("Auch richtig!");
    /// <summary>Title of a correct answer that was accepted with a tolerance (not exact).</summary>
    public static string TOLERATED_TITLE => L("Richtig!");
    /// <summary>The intro hint shown until the first checkpoint.</summary>
    public static string INTRO_HINT => L("Neue Begriffe kommen zuerst als Multiple Choice – beim nächsten Mal schreibst du sie.");
    /// <summary>Shown when the edited card now accepts what was typed.</summary>
    public static string EDITED_CORRECT_TEXT => L("Mit deiner Korrektur stimmt deine Antwort jetzt.");
    /// <summary>Toast when a session is resumed with answers.</summary>
    public static string WELCOME_BACK => L("Willkommen zurück – weiter geht's");
    /// <summary>The mark of a repetition question (Wiederholungsfrage) of a mastered card.</summary>
    public static string REVIEW_LABEL => L("Wiederholung");
    /// <summary>After a missed repetition question: the card is learned again.</summary>
    public static string DEMOTED_TEXT => L("Wieder am Lernen");
    /// <summary>The mark of a recheck (Nachkontrolle) of a card missed earlier in the session.</summary>
    public static string RECHECK_LABEL => L("Nachkontrolle");
    /// <summary>Its tooltip.</summary>
    public static string RECHECK_HELP => L("Diesen Begriff hattest du vorhin falsch. Er kommt zur Kontrolle nochmals.");
    /// <summary>The hint at the first recheck of a session (a toast with "Optionen", RECHECK_HINT_MS long).</summary>
    public static string RECHECK_HINT => L("Merke: Die Nachkontrolle kannst du in den Optionen ausschalten.");
    public const int RECHECK_HINT_MS = 10_000;

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

    /// <summary>The options a running session is checked against: its own repetition questions and rechecks (they apply at once).</summary>
    public static SessionSettings CurrentSettingsOf(StudyOptions options, LearnState session) =>
        SessionSettingsOf(options, session.Review is not null, session.Recheck is not null);

    /// <summary>The settings «Später» keeps (KeptOptions.Settings): direction, question types, round size.</summary>
    public static JSONValue KeptSettingsJson(SessionSettings s) =>
        JSONValue.Obj(("answerWith", s.AnswerWith.ToJson()), ("roundSize", s.RoundSize), ("mc", s.Mc), ("written", s.Written));

    /// <summary>
    /// The note at the top of Lernen's options while the session runs with other settings than the options show (changed
    /// elsewhere, «Später»; issue #7); null when they match.
    /// </summary>
    public static string? RunningSettingsNote(State s)
    {
        if (s.Session is not { FinishedAt: null } session) return null;
        var changes = SettingsChanges(SessionSettingsOf(session), CurrentSettingsOf(s.Options, session));
        if (changes.Count == 0) return null;
        // One whole sentence per change.
        if (changes.Count > 1) return L("Diese Lerneinheit läuft noch mit den bisherigen Einstellungen. Mit «Neu starten» gelten die Optionen von hier.");
        return changes[0] switch
        {
            SettingsChange.Direction => L("Diese Lerneinheit läuft noch mit der bisherigen Abfragerichtung. Mit «Neu starten» gelten die Optionen von hier."),
            SettingsChange.Types => L("Diese Lerneinheit läuft noch mit den bisherigen Fragetypen. Mit «Neu starten» gelten die Optionen von hier."),
            _ => L("Diese Lerneinheit läuft noch mit der bisherigen Rundengrösse. Mit «Neu starten» gelten die Optionen von hier."),
        };
    }

    /// <summary>"Neu starten?" after options that only apply to a new session.</summary>
    public static string RestartMessage(IReadOnlyList<SettingsChange> changes) => changes.Count == 1
        ? changes[0] switch
        {
            SettingsChange.Direction => L("Die neue Abfragerichtung gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."),
            SettingsChange.Types => L("Die neuen Fragetypen gelten ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."),
            SettingsChange.RoundSize => L("Die neue Rundengrösse gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."),
            SettingsChange.Recheck => L("Die Einstellung für die Nachkontrolle gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."),
            _ => L("Die Einstellung für Wiederholungsfragen gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."),
        }
        : L("Die neuen Einstellungen gelten ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.");

    /// <summary>"Neu starten?" in a running session: what the new one covers.</summary>
    public static string RestartSessionMessage(StudySubset? subset = null) => (subset ?? StudySubset.All).Kind switch
    {
        StudySubsetKind.Starred => L("Du beginnst eine neue Lerneinheit mit allen markierten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert."),
        StudySubsetKind.Missed => L("Du beginnst eine neue Lerneinheit mit allen zuletzt falsch beantworteten Begriffen. Dein Lernfortschritt bleibt gespeichert."),
        StudySubsetKind.CardIds => L("Du beginnst eine neue Lerneinheit mit den ausgewählten Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert."),
        _ => L("Du beginnst eine neue Lerneinheit mit allen Begriffen, die noch nicht sitzen. Dein Lernfortschritt bleibt gespeichert."),
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
            sameLang || promptLang == Lang.Other ? (askTerm ? L("Definition") : L("Begriff")) : Labels.LangName(promptLang),
            sameLang || answerLang == Lang.Other ? L("Antwort eingeben") : L($"Antwort auf {Labels.LangName(answerLang)} eingeben"),
            sameLang || answerLang == Lang.Other ? L("Antwort eingeben") : L($"Auf {Labels.LangName(answerLang)} …"),
            card.Starred, ChoiceTexts(stored, cards, q.Ask), stored, q.IsReview, q.IsRecheck);
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
        stage >= 2 ? new(CardStatus.Mastered, L("Gemeistert"), Tone.Success, "checkmark")
        : stage == 1 ? new(CardStatus.Learning, L("Am Lernen"), Tone.Warning, null)
        : new(CardStatus.New, L("Noch neu"), Tone.Neutral, null);

    /// <summary>The checkpoint chip of a card answered in the round: stage 0 there means "answered wrong" (Am Lernen, not Neu).</summary>
    public static StageStatus CheckpointStatus(int stage) => StageStatusOf(stage >= 1 ? stage : 1);

    /// <summary>"18 von 52 gemeistert"</summary>
    public static string MasteredLine(int mastered, int total) => L($"{mastered} von {total} gemeistert");

    /// <summary>The checkpoint title by the round's share of correct answers.</summary>
    public static string CheckpointTitle(double ratio) =>
        ratio >= 0.9 ? L("Hervorragend!") : ratio >= 0.7 ? L("Gut gemacht!") : ratio >= 0.4 ? L("Du machst Fortschritte!") : L("Dranbleiben – das wird!");

    /// <summary>What is left after a checkpoint, e.g. "Noch 34 Begriffe, bis alles sitzt."</summary>
    public static string RemainingText(int mastered, int total)
    {
        int left = Math.Max(0, total - mastered);
        return left == 0 ? L("Alles sitzt!") : L($"Noch {Labels.Plural(left, "Begriff", "Begriffe")}, bis alles sitzt.");
    }

    /// <summary>"5 richtige Antworten von 7 in dieser Runde. Noch 34 Begriffe, bis alles sitzt."</summary>
    public static string CheckpointText(LearnEngine.Checkpoint cp) =>
        L($"{Labels.Plural(cp.Correct, "richtige Antwort", "richtige Antworten")} von {cp.Answered} in dieser Runde. {RemainingText(cp.Counts.Mastered, cp.Counts.Total)}");

    /// <summary>
    /// "Du hast alle markierten Begriffe gemeistert!" (the finish screen's title). The scope's adjective (ausgewählten,
    /// markierten, offenen, falsch beantworteten; none for the whole set) is part of each whole sentence.
    /// </summary>
    public static string FinishTitle(StudySubset? subset = null, int total = 2)
    {
        bool one = total == 1;
        return (subset ?? StudySubset.All).Kind switch
        {
            StudySubsetKind.CardIds => one ? L("Du hast den ausgewählten Begriff gemeistert!") : L("Du hast alle ausgewählten Begriffe gemeistert!"),
            StudySubsetKind.Starred => one ? L("Du hast den markierten Begriff gemeistert!") : L("Du hast alle markierten Begriffe gemeistert!"),
            StudySubsetKind.Learning => one ? L("Du hast den offenen Begriff gemeistert!") : L("Du hast alle offenen Begriffe gemeistert!"),
            StudySubsetKind.Missed => one ? L("Du hast den falsch beantworteten Begriff gemeistert!") : L("Du hast alle falsch beantworteten Begriffe gemeistert!"),
            _ => one ? L("Du hast den Begriff gemeistert!") : L("Du hast alle Begriffe gemeistert!"),
        };
    }

    /// <summary>
    /// "Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!" or "44 Begriffe in 16 Runden gemeistert, 6 sassen
    /// schon vorher – stark!" (cards mastered before the session apart).
    /// </summary>
    public static string FinishSubtitle(int total, int rounds, int alreadyMastered = 0, StudySubset? subset = null)
    {
        int before = Math.Max(0, alreadyMastered);
        int learned = total - before;
        if (before > 0 && learned > 0)
        {
            var cards = Labels.Plural(learned, "Begriff", "Begriffe");
            if (rounds > 0)
            {
                var inRounds = Labels.Plural(rounds, "Runde", "Runden");
                return before == 1
                    ? L($"{cards} in {inRounds} gemeistert, {before} sass schon vorher – stark!")
                    : L($"{cards} in {inRounds} gemeistert, {before} sassen schon vorher – stark!");
            }
            return before == 1 ? L($"{cards} gemeistert, {before} sass schon vorher – stark!") : L($"{cards} gemeistert, {before} sassen schon vorher – stark!");
        }
        if (rounds > 0) return FinishSubtitleInRounds(subset ?? StudySubset.All, total, Labels.Plural(rounds, "Runde", "Runden"));
        bool one = total == 1;
        return (subset ?? StudySubset.All).Kind switch
        {
            StudySubsetKind.CardIds => one ? L("Den ausgewählten Begriff gemeistert – stark!") : L($"Alle {total} ausgewählten Begriffe gemeistert – stark!"),
            StudySubsetKind.Starred => one ? L("Den markierten Begriff gemeistert – stark!") : L($"Alle {total} markierten Begriffe gemeistert – stark!"),
            StudySubsetKind.Learning => one ? L("Den offenen Begriff gemeistert – stark!") : L($"Alle {total} offenen Begriffe gemeistert – stark!"),
            StudySubsetKind.Missed => one ? L("Den falsch beantworteten Begriff gemeistert – stark!") : L($"Alle {total} falsch beantworteten Begriffe gemeistert – stark!"),
            _ => one ? L("Den Begriff gemeistert – stark!") : L($"Alle {total} Begriffe gemeistert – stark!"),
        };
    }

    /// <summary>FinishSubtitle with rounds ("Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!"); rounds is the plural text ("2 Runden").</summary>
    static string FinishSubtitleInRounds(StudySubset subset, int total, string rounds)
    {
        bool one = total == 1;
        return subset.Kind switch
        {
            StudySubsetKind.CardIds => one ? L($"Den ausgewählten Begriff in {rounds} gemeistert – stark!") : L($"Alle {total} ausgewählten Begriffe in {rounds} gemeistert – stark!"),
            StudySubsetKind.Starred => one ? L($"Den markierten Begriff in {rounds} gemeistert – stark!") : L($"Alle {total} markierten Begriffe in {rounds} gemeistert – stark!"),
            StudySubsetKind.Learning => one ? L($"Den offenen Begriff in {rounds} gemeistert – stark!") : L($"Alle {total} offenen Begriffe in {rounds} gemeistert – stark!"),
            StudySubsetKind.Missed => one
                ? L($"Den falsch beantworteten Begriff in {rounds} gemeistert – stark!")
                : L($"Alle {total} falsch beantworteten Begriffe in {rounds} gemeistert – stark!"),
            _ => one ? L($"Den Begriff in {rounds} gemeistert – stark!") : L($"Alle {total} Begriffe in {rounds} gemeistert – stark!"),
        };
    }

    public static string FinishSubtitle(LearnEngine.FinalStats stats, StudySubset? subset = null) =>
        FinishSubtitle(stats.Total, stats.Rounds, stats.AlreadyMastered, subset);

    /// <summary>"12 gemeisterte Begriffe wiederholt, 2 davon sind wieder am Lernen." (finish screen); null before the first repetition question.</summary>
    public static string? ReviewLine(LearnEngine.ReviewStats stats)
    {
        if (stats.Asked <= 0) return null;
        var asked = Labels.Plural(stats.Asked, "gemeisterten Begriff", "gemeisterte Begriffe");
        int missed = stats.Asked - stats.Kept;
        if (missed == 0) return stats.Asked == 1 ? L($"{asked} wiederholt, er sass noch.") : L($"{asked} wiederholt, alle sassen noch.");
        return missed == 1 ? L($"{asked} wiederholt, {missed} davon ist wieder am Lernen.") : L($"{asked} wiederholt, {missed} davon sind wieder am Lernen.");
    }

    /// <summary>"18 von 52 gemeistert, 7 am Lernen, 27 neu"</summary>
    public static string ProgressText(int fresh, int learning, int mastered, int total) =>
        L($"{mastered} von {total} gemeistert, {learning} am Lernen, {fresh} neu");

    public static string ProgressText(LearnEngine.Counts counts) => ProgressText(counts.Fresh, counts.Learning, counts.Mastered, counts.Total);

    // MARK: - Segmented progress bar

    /// <summary>One segment per round-sized batch, at least one, at most MAX_SEGMENTS.</summary>
    public static int SegmentCount(int total, int? roundSize)
    {
        if (total <= 0) return 1;
        int size = (roundSize ?? 0) >= 1 ? roundSize!.Value : DefaultRoundSize;
        return Math.Max(1, Math.Min(MAX_SEGMENTS, (total + size - 1) / size));
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
