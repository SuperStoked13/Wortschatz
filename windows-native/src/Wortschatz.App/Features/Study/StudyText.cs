using System.Text;
using System.Text.RegularExpressions;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.App.Features.Study;

/// <summary>Text pieces of the study screens (Mac: StudyDiffText, LearnText, the feedback rows).</summary>
public static class StudyText
{
    static Palette P => WsTheme.P;

    /// <summary>A text in a card's language: right to left for Arabic.</summary>
    public static TextBlock InLang(string text, Lang lang, double size, FontWeight weight = FontWeight.Normal, Color? color = null, FontFamily? font = null, bool hyphenate = true)
    {
        var t = Ui.Text(text, size, weight, color, TextWrapping.Wrap, font);
        if (lang.IsRTL())
        {
            t.FlowDirection = FlowDirection.RightToLeft;
            t.TextAlignment = TextAlignment.Start;
        }
        // Learn/Write prompts come broken by FitPrompt already (a second pass broke them twice).
        if (hyphenate) HyphenateToWidth(t, text, lang);
        return t;
    }

    /// <summary>
    /// Phone: a word wider than the block's width is broken at a syllable with «-» for the width the block gets (lists,
    /// summaries, the exam). Without it a long word broke anywhere («…gesellschaf|tskapitaen», a lone «)») or was cut
    /// with «…» (Joan's test, 06.11.2026). Recomputed when the width changes; nothing changes for words that fit.
    /// </summary>
    public static void HyphenateToWidth(TextBlock block, string text, Lang lang)
    {
        if (!AppDevice.IsPhone || string.IsNullOrEmpty(text) || Hyphenator.For(lang) is null) return;
        double last = -1;
        block.SizeChanged += (_, e) =>
        {
            double width = e.NewSize.Width;
            // A left-aligned block shrinks to its broken text: a small shrink is that, not a new width (else it would
            // break again and again, a little narrower each time). Turning the phone is a big change.
            if (width < 40 || (width <= last + 1 && width > last - 60)) return;
            last = width;
            var typeface = new Typeface(block.FontFamily, block.FontStyle, block.FontWeight);
            var broken = BreakLongWords(text, lang, typeface, block.FontSize, width);
            if (broken != block.Text) block.Text = broken;
        };
    }

    /// <summary>
    /// "Deine Antwort" with the character diff against the closest accepted variant (WriteFlow.AnswerDiff): typed but
    /// wrong in red and struck through, missing in green and underlined; plain text for a different word altogether.
    /// </summary>
    public static TextBlock Diff(string given, string expected, Lang lang, double size = 18)
    {
        var block = InLang("", lang, size, FontWeight.Medium);
        block.Text = null;
        block.Inlines = new InlineCollection();
        var parts = WriteFlow.AnswerDiff(given, expected, lang);
        if (parts is null)
        {
            block.Inlines.Add(new Run(given) { Foreground = WsTheme.B(P.Failure.Text) });
            return block;
        }
        foreach (var part in parts)
        {
            var run = new Run(part.Text);
            switch (part.Type)
            {
                // On a soft tint of their colour, like the Mac (backgroundColor failure/success .soft).
                case DiffType.Del:
                    run.Foreground = WsTheme.B(P.Failure.Text);
                    run.Background = WsTheme.B(P.Failure.Soft);
                    run.TextDecorations = TextDecorations.Strikethrough;
                    break;
                case DiffType.Add:
                    run.Foreground = WsTheme.B(P.Success.Text);
                    run.Background = WsTheme.B(P.Success.Soft);
                    run.TextDecorations = TextDecorations.Underline;
                    run.FontWeight = FontWeight.Bold;
                    break;
            }
            block.Inlines.Add(run);
        }
        return block;
    }

    /// <summary>
    /// "Antworten" the noun (a stat tile, the group of answer tiles): the Mac's key «Antworten (Mehrzahl)», because
    /// «Antworten» alone is the verb ("Answer") in English.
    /// </summary>
    public static string AnswersNoun => Table?.Lookup("Antworten (Mehrzahl)", null) ?? "Antworten";

    /// <summary>The option text with the typed part underlined (type-ahead ranges are UTF-16 offsets).</summary>
    public static TextBlock Underlined(string text, LearnFlow.TextRange? range, Color color, double size)
    {
        var block = Ui.Text("", size, FontWeight.Medium, color, TextWrapping.Wrap);
        block.Text = null;
        block.Inlines = new InlineCollection();
        if (range is { } r && r.End > r.Start && r.End <= text.Length)
        {
            if (r.Start > 0) block.Inlines.Add(new Run(text[..r.Start]));
            block.Inlines.Add(new Run(text[r.Start..r.End]) { TextDecorations = TextDecorations.Underline, Foreground = WsTheme.B(P.AccentText) });
            if (r.End < text.Length) block.Inlines.Add(new Run(text[r.End..]));
        }
        else block.Inlines.Add(new Run(text));
        return block;
    }

    /// <summary>
    /// Phone: a Learn/Write prompt's size and text for the card's line (see <see cref="FitWords"/>); on a PC as given.
    /// </summary>
    public static (double Size, string Text) FitPrompt(string text, Lang lang, double size, FontWeight weight)
    {
        if (!AppDevice.IsPhone) return (size, text);
        // Page margins and the card's padding on both sides (a little to spare).
        double maxWidth = Math.Min(AppDevice.ViewWidth, 760) - 104;
        return FitWords(text, lang, size, WordFloor(size), weight, maxWidth);
    }

    /// <summary>How small long words may make a prompt: about 70 %, never below 26 (or the size itself when smaller).</summary>
    public static double WordFloor(double size) => Math.Min(size, Math.Max(26, size * 0.7));

    /// <summary>
    /// A word wider than its line was broken somewhere inside (a few letters or a lone «)» on the next line, Joan
    /// 05.11.2026), and only shrinking made long words tiny (Joan 06.11.2026). So: the size goes down to
    /// <paramref name="floor"/> at most until the widest word fits; a word still too wide is broken at a syllable with
    /// «-» (<see cref="BreakLongWords"/>).
    /// </summary>
    public static (double Size, string Text) FitWords(string text, Lang lang, double size, double floor, FontWeight weight, double maxWidth)
    {
        var typeface = new Typeface(WsTheme.Prompt, FontStyle.Normal, weight);
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        double s = size;
        while (s - 2 >= floor && words.Any(w => Width(w, typeface, s) > maxWidth)) s -= 2;
        return (s, BreakLongWords(text, lang, typeface, s, maxWidth));
    }

    /// <summary>
    /// Every word wider than <paramref name="maxWidth"/> broken at syllables (<see cref="Hyphenator"/>, or after a
    /// hyphen it has) with «-» at the end of each full line: «Geschwindigkeits-» «begrenzung». Each piece is as long as
    /// the line allows. Without patterns (Arabic, Chinese) the text stays as it is.
    /// </summary>
    public static string BreakLongWords(string text, Lang lang, Typeface typeface, double size, double maxWidth)
    {
        // A little less than the line: measured and laid-out widths can differ by a pixel.
        double line = maxWidth - 4;
        var sb = new StringBuilder(text.Length + 8);
        foreach (var part in Regex.Split(text, @"(\s+)"))
        {
            if (part.Length == 0 || char.IsWhiteSpace(part[0]) || Width(part, typeface, size) <= maxWidth || Hyphenator.For(lang) is not { } h)
            {
                sb.Append(part);
                continue;
            }
            var points = h.Points(part).ToList();
            for (int i = 0; i < part.Length - 1; i++)
                if (part[i] == '-' && !points.Contains(i + 1)) points.Add(i + 1);
            points.Sort();
            int start = 0;
            while (Width(part[start..], typeface, size) > line)
            {
                int best = -1;
                foreach (var p in points)
                {
                    if (p <= start) continue;
                    if (Width(part[start..p] + "-", typeface, size) <= line) best = p;
                    else break;
                }
                // Even the next syllable is wider than the line: take it anyway (the line breaks it like before).
                if (best < 0) best = points.FirstOrDefault(p => p > start, -1);
                if (best < 0) break;
                sb.Append(part, start, best - start);
                if (part[best - 1] != '-') sb.Append('-');
                start = best;
            }
            sb.Append(part, start, part.Length - start);
        }
        return sb.ToString();
    }

    static double Width(string text, Typeface typeface, double size) =>
        new FormattedText(text, System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface, size, Brushes.Black).Width;

}

/// <summary>Texts of the Write options (Mac: WriteOptionsCopy in WriteOptionsPanel.swift, src/ui/study-options.js in Write mode).</summary>
public static class WriteOptionsCopy
{
    /// <summary>
    /// "Du siehst Deutsch und schreibst Französisch." (<c>directionText</c> in Write mode): one whole sentence per way
    /// the two sides are named (<c>sideNames</c> of study-options.js: by language, Begriff/Definition when both sides
    /// share one, Lernsprache/Übersetzung without one).
    /// </summary>
    public static string DirectionText(AnswerWith answerWith, Lang termLang, Lang defLang)
    {
        if (answerWith == AnswerWith.Both) return L("Jede Karte wird in beide Richtungen abgefragt.");
        if (termLang != Lang.Other && termLang == defLang)
            return answerWith == AnswerWith.Definition
                ? L("Du siehst den Begriff und schreibst die Definition.")
                : L("Du siehst die Definition und schreibst den Begriff.");
        // The sides' language names; null without a language.
        string? termName = termLang != Lang.Other ? Labels.LangName(termLang) : null;
        string? definitionName = defLang != Lang.Other ? Labels.LangName(defLang) : null;
        if (answerWith == AnswerWith.Definition)
            return (termName, definitionName) switch
            {
                ({ } term, { } definition) => L($"Du siehst {term} und schreibst {definition}."),
                ({ } term, null) => L($"Du siehst {term} und schreibst die Übersetzung."),
                (null, { } definition) => L($"Du siehst den Begriff in der Lernsprache und schreibst {definition}."),
                _ => L("Du siehst den Begriff in der Lernsprache und schreibst die Übersetzung."),
            };
        return (definitionName, termName) switch
        {
            ({ } definition, { } term) => L($"Du siehst {definition} und schreibst {term}."),
            ({ } definition, null) => L($"Du siehst {definition} und schreibst in der Lernsprache."),
            (null, { } term) => L($"Du siehst die Übersetzung und schreibst {term}."),
            _ => L("Du siehst die Übersetzung und schreibst in der Lernsprache."),
        };
    }
}

/// <summary>How the study screens name the two sides of a card (Mac: LearnOptionsCopy in LearnOptionsPanel.swift).</summary>
public static class LearnOptionsCopy
{
    /// <summary>
    /// How a side is named: by its language, as Begriff/Definition (both sides share a language) or as
    /// Lernsprache/Übersetzung (no language set). Picks the whole sentence of <see cref="DirectionText"/>.
    /// </summary>
    public enum SideKind { Language, Shared, Unknown }

    public sealed record Side(string Label, SideKind Kind);

    /// <summary>How the two sides are called: by language, or Begriff/Definition when both sides share one.</summary>
    public static (Side Term, Side Definition) SideNames(Lang termLang, Lang defLang)
    {
        if (termLang != Lang.Other && termLang == defLang)
            return (new Side(L("Begriff"), SideKind.Shared), new Side(L("Definition"), SideKind.Shared));
        static Side Named(Lang lang) => new(Labels.LangName(lang), SideKind.Language);
        return (
            termLang != Lang.Other ? Named(termLang) : new Side(L("Lernsprache"), SideKind.Unknown),
            defLang != Lang.Other ? Named(defLang) : new Side(L("Übersetzung"), SideKind.Unknown));
    }

    /// <summary>
    /// "Du siehst Deutsch und antwortest auf Französisch." (<c>directionText</c>): one whole sentence per way the two
    /// sides are named.
    /// </summary>
    public static string DirectionText(AnswerWith answerWith, (Side Term, Side Definition) names)
    {
        var (term, definition) = names;
        return answerWith switch
        {
            AnswerWith.Both => L("Die Richtung wechselt zufällig von Frage zu Frage."),
            // The term is shown, the definition is the answer.
            AnswerWith.Definition => (term.Kind, definition.Kind) switch
            {
                (SideKind.Shared, _) or (_, SideKind.Shared) => L("Du siehst den Begriff und antwortest mit der Definition."),
                (SideKind.Language, SideKind.Language) => L($"Du siehst {term.Label} und antwortest auf {definition.Label}."),
                (SideKind.Language, _) => L($"Du siehst {term.Label} und antwortest mit der Übersetzung."),
                (_, SideKind.Language) => L($"Du siehst den Begriff in der Lernsprache und antwortest auf {definition.Label}."),
                _ => L("Du siehst den Begriff in der Lernsprache und antwortest mit der Übersetzung."),
            },
            // The definition is shown, the term is the answer.
            _ => (definition.Kind, term.Kind) switch
            {
                (SideKind.Shared, _) or (_, SideKind.Shared) => L("Du siehst die Definition und antwortest mit dem Begriff."),
                (SideKind.Language, SideKind.Language) => L($"Du siehst {definition.Label} und antwortest auf {term.Label}."),
                (SideKind.Language, _) => L($"Du siehst {definition.Label} und antwortest in der Lernsprache."),
                (_, SideKind.Language) => L($"Du siehst die Übersetzung und antwortest auf {term.Label}."),
                _ => L("Du siehst die Übersetzung und antwortest in der Lernsprache."),
            },
        };
    }

    // Computed, so the texts follow a change of the app's language.
    public static string LockHint => L("Mindestens ein Fragetyp bleibt aktiv.");

    /// <summary>The round size: after so many questions the checkpoint shows the interim result (since 1.4 a round is questions, not a group of terms).</summary>
    public static string RoundSizeLabel => L("Fragen pro Runde");
    public static string RoundSizeNote => L("Nach so vielen Fragen siehst du deinen Zwischenstand.");

    /// <summary>The two Learn switches that hold for every set (preferences, not study options).</summary>
    public static string ReviewLabel => L("Wiederholungsfragen");
    public static string ReviewNote => L("Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen.");
    public static string RecheckLabel => L("Nachkontrolle nach Fehlern");
    /// <summary>"Soundeffekte" of a set (its options; a preference of this device, Mac: LearnOptionsCopy.soundLabel).</summary>
    public static string SoundLabel => L("Soundeffekte");
    public static string SoundNote => L("Töne bei Antworten und geschafften Runden. Gilt nur für dieses Lernset und nur auf diesem Gerät.");
    public static string SoundOffEverywhere => L("In den Einstellungen sind die Soundeffekte für alle Lernsets ausgeschaltet.");
    /// <summary>Synonyms outside the set of a set (Toleranz; a preference of this device, Mac: LearnOptionsCopy.synonymsLabel).</summary>
    public static string SynonymsLabel => L("Synonyme ausserhalb des Sets erlauben");
    public static string SynonymsNote =>
        L("«Velo» für «Fahrrad», aus den Synonymwörterbüchern der App. Steht ein Synonym als eigene Karte im Lernset, zählt es immer. Gilt nur für dieses Lernset und nur auf diesem Gerät.");
    public static string SynonymsOffEverywhere => L("In den Einstellungen ist «Weitere Synonyme erkennen» für alle Lernsets ausgeschaltet.");
    public static string RecheckNote => L("Hattest du einen Begriff einmal falsch, kommt er nach dem Meistern etwa 30 bis 50 Fragen später nochmals. Nur bei Lernsets mit mehr als 60 Begriffen.");
    public static string GlobalSwitchesFooter => L("Gilt sofort für alle Lernsets, auch beim angefangenen Lernen.");

    /// <summary>
    /// What a set's options change from the standard (Einstellungen), as short phrases in the order of the options
    /// ("Multiple Choice: aus", "10 Fragen pro Runde"); empty when the set follows the standard.
    /// </summary>
    public static List<string> Deviations(StudyOptions own, StudyOptions standard, (Side Term, Side Definition) names, Lang termLang)
    {
        // "Vorlesen: an" / "Vorlesen: aus".
        static string OnOff(string label, bool on) => on ? L($"{label}: an") : L($"{label}: aus");
        var output = new List<string>();
        if (own.AnswerWith != standard.AnswerWith)
            output.Add(own.AnswerWith switch
            {
                AnswerWith.Term => L($"Antworten auf {names.Term.Label}"),
                AnswerWith.Definition => L($"Antworten auf {names.Definition.Label}"),
                _ => L("Antworten auf beides"),
            });
        if (own.Learn.Mc != standard.Learn.Mc) output.Add(OnOff(L("Multiple Choice"), own.Learn.Mc));
        if (own.Learn.Written != standard.Learn.Written) output.Add(OnOff(L("Schriftlich"), own.Learn.Written));
        if (own.Learn.RoundSize != standard.Learn.RoundSize) output.Add(L($"{own.Learn.RoundSize} Fragen pro Runde"));
        if (own.Learn.Retype != standard.Learn.Retype) output.Add(OnOff(L("Abtippen nach Fehler (Lernen)"), own.Learn.Retype));
        if (own.Shuffle != standard.Shuffle) output.Add(OnOff(L("Mischen"), own.Shuffle));
        if (own.CopyAnswer != standard.CopyAnswer) output.Add(OnOff(L("Abtippen nach Fehler (Schreiben)"), own.CopyAnswer));
        if (own.AutoAdvance != standard.AutoAdvance) output.Add(OnOff(L("Automatisch weiter"), own.AutoAdvance));
        if (own.Audio != standard.Audio) output.Add(OnOff(L("Vorlesen"), own.Audio));
        foreach (var item in ToleranceItems(termLang))
            if (item.Get(own.Tolerance) != item.Get(standard.Tolerance)) output.Add(OnOff(item.Label, item.Get(own.Tolerance)));
        return output;
    }

    /// <summary>"Fragen pro Runde" choices; a stored size outside them stays selectable.</summary>
    public static List<int> RoundSizes(int current)
    {
        var sizes = new List<int> { 5, 7, 10, 15 };
        if (current >= 1 && !sizes.Contains(current))
        {
            sizes.Add(current);
            sizes.Sort();
        }
        return sizes;
    }

    public static string QuestionTypesHint(LearnOptions learn) => (learn.Mc, learn.Written) switch
    {
        (true, false) => L("Alle Fragen kommen als Multiple Choice. Mindestens ein Fragetyp bleibt aktiv."),
        (false, true) => L("Alle Fragen beantwortest du schriftlich. Mindestens ein Fragetyp bleibt aktiv."),
        _ => L("Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst."),
    };

    /// <summary>A tolerance switch with an example (Mac: ToleranceItem).</summary>
    public sealed record ToleranceItem(string Label, string Example, Func<Tolerance, bool> Get, Func<bool, TolerancePatch> Patch);

    /// <summary>The seven tolerance switches with an example in the set's language (Mac: toleranceItems).</summary>
    public static IReadOnlyList<ToleranceItem> ToleranceItems(Lang termLang)
    {
        var article = termLang switch
        {
            // The whole example with its remark (one text each, Mac: toleranceItems).
            Lang.Fr => L("«homme» für «l'homme» – ein falscher Artikel bleibt falsch"),
            Lang.En => L("«house» für «the house» – ein falscher Artikel bleibt falsch"),
            Lang.Es or Lang.It => L("«casa» für «la casa» – ein falscher Artikel bleibt falsch"),
            _ => L("«Herr» für «der Herr» – ein falscher Artikel bleibt falsch"),
        };
        var abbreviation = termLang switch
        {
            Lang.Fr => L("«etw.» = «etwas», «qc» = «quelque chose»"),
            Lang.En => L("«etw.» = «etwas», «sth» = «something»"),
            _ => L("«etw.» = «etwas», «jdn.» = «jemanden»"),
        };
        var accents = termLang switch
        {
            Lang.Fr => L("«ecole» = «école», «ahnlich» = «ähnlich»"),
            Lang.Es => L("«arbol» = «árbol», «ahnlich» = «ähnlich»"),
            Lang.It => L("«citta» = «città», «ahnlich» = «ähnlich»"),
            Lang.Zh => L("«ni hao» = «nǐ hǎo», «ahnlich» = «ähnlich»"),
            _ => L("«ahnlich» = «ähnlich»"),
        };
        return
        [
            new(L("Artikel/Pronomen vergessen erlaubt"), article, t => t.Articles, v => new TolerancePatch(Articles: v)),
            new(L("Abkürzungen gleichwertig"), abbreviation, t => t.Abbreviations, v => new TolerancePatch(Abbreviations: v)),
            new(L("Eine von mehreren Antworten genügt"), L("«lieb» reicht bei «lieb, nett»"), t => t.MultipleAnswers, v => new TolerancePatch(MultipleAnswers: v)),
            new(L("Klammerinhalt optional"), L("«freuen» für «(sich) freuen»"), t => t.Parentheses, v => new TolerancePatch(Parentheses: v)),
            new(L("Gross-/Kleinschreibung ignorieren"), L("«herr» = «Herr»"), t => t.IgnoreCase, v => new TolerancePatch(IgnoreCase: v)),
            new(L("Akzente ignorieren"), accents, t => t.IgnoreAccents, v => new TolerancePatch(IgnoreAccents: v)),
            new(L("Kleine Tippfehler erlauben"), L("«Mädhcen» statt «Mädchen» – ein Buchstabe daneben"), t => t.Typos, v => new TolerancePatch(Typos: v)),
        ];
    }
}
