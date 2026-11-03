namespace Wortschatz.Core;

// Port of WriteFlowText.swift: the texts and pure view logic of Write mode (the DOM-free parts of
// src/screens/write-card.js and write-views.js: answer diff, summary and results texts, empty states,
// dialog texts). German UI copy with Swiss spelling ("ss", never the sharp s).

public static partial class WriteFlow
{
    // MARK: - Question card

    /// <summary>The label of the answer field: "Deine Antwort", or "Tippe die richtige Antwort ab" in the copy step.</summary>
    public static string FieldLabel(State state) => state.Phase == Phase.Copy ? "Tippe die richtige Antwort ab" : "Deine Antwort";

    /// <summary>The placeholder of the answer field (short for narrow layouts).</summary>
    public static string FieldPlaceholder(State state, bool @short = false)
    {
        if (state.Phase == Phase.Copy) return @short ? "Antwort abtippen" : "Richtige Antwort abtippen";
        if (state.Question is not { } q) return "Antwort eingeben";
        return @short ? q.PlaceholderShort : q.Placeholder;
    }

    /// <summary>"Runde 2 · nur die Begriffe, die noch nicht sassen" above the card from round 2 on.</summary>
    public static string? RoundNote(State state) =>
        state.Phase.IsCard && CountersOf(state) is { Round: > 1 } c ? $"Runde {c.Round} · nur die Begriffe, die noch nicht sassen" : null;

    /// <summary>The screen-reader label of the sidebar counters.</summary>
    public static string CountersAccessibilityLabel(WriteSession.Counters c) =>
        $"Runde {c.Round}: {c.Remaining} verbleibend, {c.Incorrect} falsch, {c.Correct} von {c.Total} richtig";

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
        ratio >= 0.9 ? "Hervorragend!" : ratio >= 0.7 ? "Gut gemacht!" : ratio >= 0.4 ? "Weiter so!" : "Dranbleiben – das wird!";

    /// <summary>"Runde 1 geschafft".</summary>
    public static string SummaryEyebrow(WriteSession.RoundSummary summary) => $"Runde {summary.Round} geschafft";

    /// <summary>"In Runde 2 übst du nur die 3 Begriffe, die noch nicht sassen."</summary>
    public static string SummaryText(WriteSession.RoundSummary summary)
    {
        bool one = summary.Incorrect == 1;
        var what = one ? "den Begriff, der" : $"die {summary.Incorrect} Begriffe, die";
        return $"In Runde {summary.Round + 1} übst du nur {what} noch nicht sass{(one ? "" : "en")}.";
    }

    // MARK: - Results

    /// <summary>"Am häufigsten falsch": up to 10 cards with their misses.</summary>
    public static List<TermRow> HardestRows(State state) =>
        state.Set is { } set && state.Results is { } results
            ? TermRows(set, results.Stats.Hardest.Select(h => (h.CardId, h.CardId, (bool?)null, (int?)h.Misses)))
            : [];

    /// <summary>The line under "Geschafft!".</summary>
    public static string ResultsSubtitle(int cardCount, double accuracy, bool bothDirections)
    {
        var dir = bothDirections ? " in beide Richtungen" : "";
        if (cardCount == 1)
            return accuracy >= 1 ? $"Beim ersten Versuch richtig{dir} – perfekt!" : $"Du hast den Begriff{dir} richtig geschrieben.";
        var what = Labels.Plural(cardCount, "Begriff", "Begriffe");
        if (accuracy >= 1) return $"Alle {what}{dir} beim ersten Versuch richtig – perfekt!";
        return $"Du hast alle {what}{dir} richtig geschrieben.";
    }

    /// <summary>ResultsSubtitle for the results in a state.</summary>
    public static string ResultsSubtitle(Results results) => ResultsSubtitle(results.CardCount, results.Stats.Accuracy, results.BothDirections);

    /// <summary>"42 %" for a share (clamped to 0…1).</summary>
    public static string PercentText(double value)
    {
        double v = double.IsNaN(value) ? 0 : Math.Min(1, Math.Max(0, value));
        return $"{JSCompat.NumberToString(JSCompat.Round(v * 100))} %";
    }

    /// <summary>"Kein einziger Fehler in dieser Lernrunde." (results without misses).</summary>
    public const string FlawlessText = "Kein einziger Fehler in dieser Lernrunde.";

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
        StudySubsetKind.Starred => new("star", "Keine markierten Begriffe",
            "Markiere schwierige Begriffe mit dem Stern, um sie gezielt zu üben.", "Alle Begriffe üben", false),
        StudySubsetKind.Learning => new("trophy", "Alles gemeistert!",
            "Du beherrschst bereits alle Begriffe in diesem Lernset. Übe trotzdem alle, damit sie frisch bleiben.", "Alle Begriffe üben", false),
        StudySubsetKind.Missed or StudySubsetKind.CardIds => new("checkmark.circle", "Keine falschen Begriffe",
            "Hier gibt es gerade nichts nachzuholen.", "Alle Begriffe üben", false),
        _ => new("square.stack.3d.up", "Noch keine Begriffe zum Üben",
            "Füge diesem Lernset Begriffe mit Übersetzung hinzu, dann kann es losgehen.", "Begriffe hinzufügen", true),
    };

    /// <summary>The screen of a set that does not exist (any more).</summary>
    public static readonly Message MissingMessage = new("magnifyingglass", "Lernset nicht gefunden",
        "Dieses Lernset gibt es nicht mehr. Vielleicht wurde es gelöscht.", "Zur Übersicht", false);

    /// <summary>What a new round of a named subset asks (<c>SUBSET_WHAT</c>), for "Laufende Runde beenden?".</summary>
    public static string SubsetDescription(StudySubset subset) => subset.Kind switch
    {
        StudySubsetKind.All => "alle Begriffe",
        StudySubsetKind.Starred => "nur die markierten Begriffe",
        StudySubsetKind.Learning => "nur die nicht gemeisterten Begriffe",
        StudySubsetKind.Missed => "nur die zuletzt falsch beantworteten Begriffe",
        _ => "eine neue Runde",
    };

    // MARK: - Card editor

    /// <summary>The editor's field labels: "Begriff · Französisch" / "Definition · Deutsch".</summary>
    public static (string Term, string Definition) EditorLabels(Lang termLang, Lang defLang) => (
        termLang == Lang.Other ? "Begriff" : $"Begriff · {Labels.LangName(termLang)}",
        defLang == Lang.Other ? "Definition" : $"Definition · {Labels.LangName(defLang)}");

    /// <summary>The editor's validation errors for an empty side (null when the side is fine).</summary>
    public static (string? Term, string? Definition) EditorErrors(string term, string definition) => (
        JSCompat.Trim(term).Length == 0 ? "Bitte gib den Begriff ein." : null,
        JSCompat.Trim(definition).Length == 0 ? "Bitte gib die Definition ein." : null);

    // MARK: - Prompt texts

    public abstract partial record Prompt
    {
        public string Title => this is ReplaceRound ? "Laufende Runde beenden?" : "Neu starten?";

        public string MessageText => this switch
        {
            Restart => "Alle Begriffe dieser Lernrunde werden von vorne abgefragt. Dein Lernfortschritt bleibt gespeichert.",
            RestartForOptions o => $"{(o.DirectionChanged ? "Die neue Abfragerichtung" : "Die neue Reihenfolge")} gilt ab einem Neustart. "
                + "Jetzt neu beginnen? Dein Lernfortschritt bleibt gespeichert.",
            ReplaceRound r => $"Deine gespeicherte Runde endet, wenn du jetzt {SubsetDescription(r.Wanted)} übst. Dein Lernfortschritt bleibt erhalten.",
            _ => "",
        };

        /// <summary>The default button (Return).</summary>
        public string ConfirmLabel => this is ReplaceRound ? "Neue Runde starten" : "Neu starten";

        /// <summary>The cancel button (Esc).</summary>
        public string CancelLabel => this switch
        {
            Restart => "Abbrechen",
            RestartForOptions => "Später",
            _ => "Runde fortsetzen",
        };
    }
}
