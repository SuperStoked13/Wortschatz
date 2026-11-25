using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

// Port of WriteFlowText.swift: the texts and pure view logic of Write mode (the DOM-free parts of
// src/screens/write-card.js and write-views.js: answer diff, summary and results texts, empty states,
// dialog texts). German UI copy with Swiss spelling ("ss", never the sharp s), translated with CoreText.L.

public static partial class WriteFlow
{
    // MARK: - Question card

    /// <summary>The label of the answer field: "Deine Antwort", or "Tippe die richtige Antwort ab" in the copy step.</summary>
    public static string FieldLabel(State state) => state.Phase == Phase.Copy ? L("Tippe die richtige Antwort ab") : L("Deine Antwort");

    /// <summary>The placeholder of the answer field (short for narrow layouts).</summary>
    public static string FieldPlaceholder(State state, bool @short = false)
    {
        if (state.Phase == Phase.Copy) return @short ? L("Antwort abtippen") : L("Richtige Antwort abtippen");
        if (state.Question is not { } q) return L("Antwort eingeben");
        return @short ? q.PlaceholderShort : q.Placeholder;
    }

    /// <summary>"Runde 2 · nur die Begriffe, die noch nicht sassen" above the card from round 2 on.</summary>
    public static string? RoundNote(State state) =>
        state.Phase.IsCard && CountersOf(state) is { Round: > 1 } c ? L($"Runde {c.Round} · nur die Begriffe, die noch nicht sassen") : null;

    /// <summary>The screen-reader label of the sidebar counters.</summary>
    public static string CountersAccessibilityLabel(WriteSession.Counters c) =>
        L($"Runde {c.Round}: {c.Remaining} verbleibend, {c.Incorrect} falsch, {c.Correct} von {c.Total} richtig");

    /// <summary>
    /// The answer diff under "Deine Antwort" (write-card.js <c>diffView</c>): segments against the closest accepted
    /// variant, or null when the answer is a different word altogether (less than half of the typed characters
    /// match) and should be shown as plain text. Del is typed but wrong, Add is missing.
    /// </summary>
    public static List<DiffSegment>? AnswerDiff(string given, string expected, Lang? lang)
    {
        var parts = ClosestDiff(given, expected, lang);
        int same = parts.Sum(p => p.Type == DiffType.Same ? NonWhitespaceLength(p.Text) : 0);
        int typed = NonWhitespaceLength(given);
        if (typed == 0 || (double)same / typed < 0.5) return null;
        return parts;
    }

    /// <summary>
    /// The diff against whichever accepted variant is closest to what was typed (write-card.js <c>closestDiff</c>), so
    /// a small slip in "le monsieur" is not drowned by the missing ", messieurs".
    /// </summary>
    public static List<DiffSegment> ClosestDiff(string given, string expected, Lang? lang)
    {
        var candidates = new List<string> { expected };
        foreach (var alt in Grading.SplitAlternatives(expected, lang))
            if (alt.Length > 0 && !candidates.Contains(alt, StringComparer.Ordinal)) candidates.Add(alt);
        List<DiffSegment>? best = null;
        int bestCost = int.MaxValue;
        foreach (var target in candidates)
        {
            var parts = Grading.DiffAnswer(given, target, lang);
            int cost = Grading.DiffCost(parts);
            if (cost < bestCost)
            {
                best = parts;
                bestCost = cost;
            }
        }
        return best ?? [];
    }

    // MARK: - Round summary

    /// <summary>The round summary's rows in answer order (the view groups them into "Noch üben" and "Richtig").</summary>
    public static List<TermRow> SummaryRows(State state) =>
        state.Set is { } set && state.Summary is { } summary
            ? TermRows(set, summary.Items.Select(i => (i.Qid, i.CardId, (bool?)i.Correct, (int?)null)))
            : [];

    /// <summary>The share of right answers in the round (0…1).</summary>
    public static double SummaryRatio(WriteSession.RoundSummary summary) => (double)summary.Correct / Math.Max(1, summary.Total);

    /// <summary>"Hervorragend!", "Gut gemacht!", "Weiter so!" or "Dranbleiben – das wird!".</summary>
    public static string SummaryTitle(double ratio) =>
        ratio >= 0.9 ? L("Hervorragend!") : ratio >= 0.7 ? L("Gut gemacht!") : ratio >= 0.4 ? L("Weiter so!") : L("Dranbleiben – das wird!");

    /// <summary>"Runde 1 geschafft".</summary>
    public static string SummaryEyebrow(WriteSession.RoundSummary summary) => L($"Runde {summary.Round} geschafft");

    /// <summary>"In Runde 2 übst du nur die 3 Begriffe, die noch nicht sassen."</summary>
    public static string SummaryText(WriteSession.RoundSummary summary) => summary.Incorrect == 1
        ? L($"In Runde {summary.Round + 1} übst du nur den Begriff, der noch nicht sass.")
        : L($"In Runde {summary.Round + 1} übst du nur die {summary.Incorrect} Begriffe, die noch nicht sassen.");

    // MARK: - Results

    /// <summary>"Am häufigsten falsch": every card missed at least once, most misses first.</summary>
    public static List<TermRow> HardestRows(State state) =>
        state.Set is { } set && state.Results is { } results
            ? TermRows(set, results.Stats.Hardest.Select(h => (h.CardId, h.CardId, (bool?)null, (int?)h.Misses)))
            : [];

    /// <summary>The line under "Geschafft!".</summary>
    public static string ResultsSubtitle(int cardCount, double accuracy, bool bothDirections)
    {
        if (cardCount == 1)
        {
            if (accuracy >= 1)
                return bothDirections ? L("Beim ersten Versuch richtig in beide Richtungen – perfekt!") : L("Beim ersten Versuch richtig – perfekt!");
            return bothDirections ? L("Du hast den Begriff in beide Richtungen richtig geschrieben.") : L("Du hast den Begriff richtig geschrieben.");
        }
        var what = Labels.Plural(cardCount, "Begriff", "Begriffe");
        if (accuracy >= 1)
            return bothDirections ? L($"Alle {what} in beide Richtungen beim ersten Versuch richtig – perfekt!") : L($"Alle {what} beim ersten Versuch richtig – perfekt!");
        return bothDirections ? L($"Du hast alle {what} in beide Richtungen richtig geschrieben.") : L($"Du hast alle {what} richtig geschrieben.");
    }

    /// <summary>ResultsSubtitle for the results in a state.</summary>
    public static string ResultsSubtitle(Results results) => ResultsSubtitle(results.CardCount, results.Stats.Accuracy, results.BothDirections);

    /// <summary>"42 %" for a share (clamped to 0…1).</summary>
    public static string PercentText(double value)
    {
        double v = double.IsNaN(value) ? 0 : Math.Min(1, Math.Max(0, value));
        return L($"{JSCompat.NumberToString(JSCompat.Round(v * 100))} %");
    }

    /// <summary>"Kein einziger Fehler in dieser Lernrunde." (results without misses).</summary>
    public static string FlawlessText => L("Kein einziger Fehler in dieser Lernrunde.");

    // MARK: - Messages

    /// <summary>
    /// An empty or missing screen. SystemImage: the Mac's SF Symbol name (the Windows app maps it to an icon).
    /// PrimaryLabel: the primary button (Return); PrimaryOpensEditor: it opens the set editor (else it practises
    /// all cards, or leaves).
    /// </summary>
    public sealed record Message(string SystemImage, string Title, string Text, string PrimaryLabel, bool PrimaryOpensEditor);

    /// <summary>The screen when the requested subset has nothing to practise (<c>emptySubsetView</c>).</summary>
    public static Message EmptyMessage(StudySubset subset) => subset.Kind switch
    {
        StudySubsetKind.Starred => new("star", L("Keine markierten Begriffe"),
            L("Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben."), L("Alle Begriffe üben"), false),
        StudySubsetKind.Learning => new("trophy", L("Alles gemeistert!"),
            L("Du beherrschst bereits alle Begriffe in diesem Lernset. Übe trotzdem alle, damit sie frisch bleiben."), L("Alle Begriffe üben"), false),
        StudySubsetKind.Missed or StudySubsetKind.CardIds => new("checkmark.circle", L("Keine falschen Begriffe"),
            L("Hier gibt es gerade nichts nachzuholen."), L("Alle Begriffe üben"), false),
        _ => new("square.stack.3d.up", L("Noch keine Begriffe zum Üben"),
            L("Füge diesem Lernset Begriffe mit Übersetzung hinzu, dann kann es losgehen."), L("Begriffe hinzufügen"), true),
    };

    /// <summary>The screen of a set that does not exist (any more).</summary>
    public static Message MissingMessage => new("magnifyingglass", L("Lernset nicht gefunden"),
        L("Dieses Lernset gibt es nicht mehr. Vielleicht wurde es gelöscht."), L("Zur Übersicht"), false);

    // MARK: - Card editor

    /// <summary>The editor's field labels: "Begriff · Französisch" / "Definition · Deutsch".</summary>
    public static (string Term, string Definition) EditorLabels(Lang termLang, Lang defLang) => (
        termLang == Lang.Other ? L("Begriff") : L($"Begriff · {Labels.LangName(termLang)}"),
        defLang == Lang.Other ? L("Definition") : L($"Definition · {Labels.LangName(defLang)}"));

    // MARK: - Options that need a restart

    /// <summary>The options «Später» keeps (KeptOptions.Settings) and a running session is checked against: direction and «Mischen».</summary>
    public static JSONValue KeptSettingsJson(StudyOptions options) => new SessionSetOptions(options.AnswerWith, options.Shuffle).ToJson();

    /// <summary>
    /// The note at the top of Schreiben's options while the round runs with another direction or order than the options
    /// show (changed elsewhere, «Später»; issue #7); null when they match.
    /// </summary>
    public static string? RunningSettingsNote(State s)
    {
        if (s.Session is not { FinishedAt: null } session) return null;
        bool direction = session.SetOptions.AnswerWith != s.Options.AnswerWith, order = session.SetOptions.Shuffle != s.Options.Shuffle;
        if (!direction && !order) return null;
        // One whole sentence per change.
        if (direction && order) return L("Diese Runde läuft noch mit den bisherigen Einstellungen. Mit «Neu starten» gelten die Optionen von hier.");
        return direction
            ? L("Diese Runde läuft noch mit der bisherigen Abfragerichtung. Mit «Neu starten» gelten die Optionen von hier.")
            : L("Diese Runde läuft noch mit der bisherigen Reihenfolge. Mit «Neu starten» gelten die Optionen von hier.");
    }

    // MARK: - Prompt texts

    public abstract partial record Prompt
    {
        public string Title => this is ReplaceRound ? L("Laufende Runde beenden?") : L("Neu starten?");

        public string MessageText => this switch
        {
            Restart => L("Alle Begriffe dieser Lernrunde werden von vorne abgefragt. Dein Lernfortschritt bleibt gespeichert."),
            RestartForOptions o => o.DirectionChanged
                ? L("Die neue Abfragerichtung gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.")
                : L("Die neue Reihenfolge gilt ab einem Neustart. Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert."),
            ReplaceRound r => ReplaceRoundMessage(r.Wanted),
            _ => "",
        };

        /// <summary>"Laufende Runde beenden?": one whole sentence per subset.</summary>
        static string ReplaceRoundMessage(StudySubset wanted) => wanted.Kind switch
        {
            StudySubsetKind.All => L("Deine gespeicherte Runde endet, wenn du jetzt alle Begriffe übst. Dein Lernfortschritt bleibt erhalten."),
            StudySubsetKind.Starred => L("Deine gespeicherte Runde endet, wenn du jetzt nur die markierten Begriffe übst. Dein Lernfortschritt bleibt erhalten."),
            StudySubsetKind.Learning => L("Deine gespeicherte Runde endet, wenn du jetzt nur die nicht gemeisterten Begriffe übst. Dein Lernfortschritt bleibt erhalten."),
            StudySubsetKind.Missed => L("Deine gespeicherte Runde endet, wenn du jetzt nur die zuletzt falsch beantworteten Begriffe übst. Dein Lernfortschritt bleibt erhalten."),
            _ => L("Deine gespeicherte Runde endet, wenn du jetzt eine neue Runde übst. Dein Lernfortschritt bleibt erhalten."),
        };

        /// <summary>The default button (Return).</summary>
        public string ConfirmLabel => this is ReplaceRound ? L("Neue Runde starten") : L("Neu starten");

        /// <summary>The cancel button (Esc).</summary>
        public string CancelLabel => this switch
        {
            Restart => L("Abbrechen"),
            RestartForOptions => L("Später"),
            _ => L("Runde fortsetzen"),
        };
    }
}
