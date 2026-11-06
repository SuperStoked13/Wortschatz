using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Study;

/// <summary>Text pieces of the study screens (Mac: StudyDiffText, LearnText, the feedback rows).</summary>
public static class StudyText
{
    static Palette P => WsTheme.P;

    /// <summary>A text in a card's language: right to left for Arabic.</summary>
    public static TextBlock InLang(string text, Lang lang, double size, FontWeight weight = FontWeight.Normal, Color? color = null, FontFamily? font = null)
    {
        var t = Ui.Text(text, size, weight, color, TextWrapping.Wrap, font);
        if (lang.IsRTL())
        {
            t.FlowDirection = FlowDirection.RightToLeft;
            t.TextAlignment = TextAlignment.Start;
        }
        return t;
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

    /// <summary>A labelled block of the miss details ("DEINE ANTWORT", "RICHTIGE ANTWORT").</summary>
    public static Control Row(string title, Control content) => Ui.V(6, Ui.Eyebrow(title), content);

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

    /// <summary>The prompt size: big for words, smaller for long sentences.</summary>
    public static double PromptSize(string prompt) => prompt.Length switch
    {
        <= 24 => 46,
        <= 48 => 36,
        <= 90 => 28,
        _ => 22,
    };
}

/// <summary>Texts of the Write options (Mac: WriteOptionsCopy in WriteOptionsPanel.swift, src/ui/study-options.js in Write mode).</summary>
public static class WriteOptionsCopy
{
    /// <summary>"Du siehst Deutsch und schreibst Französisch." (<c>directionText</c> in Write mode).</summary>
    public static string DirectionText(AnswerWith answerWith, Lang termLang, Lang defLang)
    {
        if (answerWith == AnswerWith.Both) return "Jede Karte wird in beide Richtungen abgefragt.";
        var (term, definition) = SideNames(termLang, defLang);
        var (shown, typed) = answerWith == AnswerWith.Definition ? (term, definition) : (definition, term);
        return $"Du siehst {shown.Seen} und schreibst {typed.Written}.";
    }

    sealed record Side(string Seen, string Written);

    /// <summary><c>sideNames</c> of study-options.js (the parts Write mode's sentence needs).</summary>
    static (Side Term, Side Definition) SideNames(Lang termLang, Lang defLang)
    {
        if (termLang != Lang.Other && termLang == defLang)
            return (new Side("den Begriff", "den Begriff"), new Side("die Definition", "die Definition"));
        static Side Named(Lang lang) => new(Labels.LangName(lang), Labels.LangName(lang));
        return (
            termLang != Lang.Other ? Named(termLang) : new Side("den Begriff in der Lernsprache", "in der Lernsprache"),
            defLang != Lang.Other ? Named(defLang) : new Side("die Übersetzung", "die Übersetzung"));
    }
}

/// <summary>How the study screens name the two sides of a card (Mac: LearnOptionsCopy in LearnOptionsPanel.swift).</summary>
public static class LearnOptionsCopy
{
    public sealed record Side(string Label, string Seen, string Answered);

    /// <summary>How the two sides are called: by language, or Begriff/Definition when both sides share one.</summary>
    public static (Side Term, Side Definition) SideNames(Lang termLang, Lang defLang)
    {
        if (termLang != Lang.Other && termLang == defLang)
            return (new Side("Begriff", "den Begriff", "mit dem Begriff"), new Side("Definition", "die Definition", "mit der Definition"));
        static Side Named(Lang lang)
        {
            var name = Labels.LangName(lang);
            return new Side(name, name, $"auf {name}");
        }
        return (
            termLang != Lang.Other ? Named(termLang) : new Side("Lernsprache", "den Begriff in der Lernsprache", "in der Lernsprache"),
            defLang != Lang.Other ? Named(defLang) : new Side("Übersetzung", "die Übersetzung", "mit der Übersetzung"));
    }

    /// <summary>"Du siehst Deutsch und antwortest auf Französisch." (<c>directionText</c>).</summary>
    public static string DirectionText(AnswerWith answerWith, (Side Term, Side Definition) names) => answerWith switch
    {
        AnswerWith.Both => "Die Richtung wechselt zufällig von Frage zu Frage.",
        AnswerWith.Definition => $"Du siehst {names.Term.Seen} und antwortest {names.Definition.Answered}.",
        _ => $"Du siehst {names.Definition.Seen} und antwortest {names.Term.Answered}.",
    };

    public const string LockHint = "Mindestens ein Fragetyp bleibt aktiv.";

    /// <summary>The round size: after so many questions the checkpoint shows the interim result (since 1.4 a round is questions, not a group of terms).</summary>
    public const string RoundSizeLabel = "Fragen pro Runde";
    public const string RoundSizeNote = "Nach so vielen Fragen siehst du deinen Zwischenstand.";

    /// <summary>The two Learn switches that hold for every set (preferences, not study options).</summary>
    public const string ReviewLabel = "Wiederholungsfragen";
    public const string ReviewNote = "Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen.";
    public const string RecheckLabel = "Nachkontrolle nach Fehlern";
    public const string RecheckNote = "Hattest du einen Begriff einmal falsch, kommt er nach dem Meistern etwa 30 bis 50 Fragen später nochmals. Nur bei Lernsets mit mehr als 60 Begriffen.";
    public const string GlobalSwitchesFooter = "Gilt für alle Lernsets, ab dem nächsten Start.";

    /// <summary>
    /// What a set's options change from the standard (Einstellungen), as short phrases in the order of the options
    /// ("Multiple Choice: aus", "10 Fragen pro Runde"); empty when the set follows the standard.
    /// </summary>
    public static List<string> Deviations(StudyOptions own, StudyOptions standard, (Side Term, Side Definition) names, Lang termLang)
    {
        static string OnOff(bool on) => on ? "an" : "aus";
        var output = new List<string>();
        if (own.AnswerWith != standard.AnswerWith)
            output.Add("Antworten auf " + own.AnswerWith switch { AnswerWith.Term => names.Term.Label, AnswerWith.Definition => names.Definition.Label, _ => "beides" });
        if (own.Learn.Mc != standard.Learn.Mc) output.Add($"Multiple Choice: {OnOff(own.Learn.Mc)}");
        if (own.Learn.Written != standard.Learn.Written) output.Add($"Schriftlich: {OnOff(own.Learn.Written)}");
        if (own.Learn.RoundSize != standard.Learn.RoundSize) output.Add($"{own.Learn.RoundSize} {RoundSizeLabel}");
        if (own.Learn.Retype != standard.Learn.Retype) output.Add($"Abtippen nach Fehler (Lernen): {OnOff(own.Learn.Retype)}");
        if (own.Shuffle != standard.Shuffle) output.Add($"Mischen: {OnOff(own.Shuffle)}");
        if (own.CopyAnswer != standard.CopyAnswer) output.Add($"Abtippen nach Fehler (Schreiben): {OnOff(own.CopyAnswer)}");
        if (own.AutoAdvance != standard.AutoAdvance) output.Add($"Automatisch weiter: {OnOff(own.AutoAdvance)}");
        if (own.Audio != standard.Audio) output.Add($"Vorlesen: {OnOff(own.Audio)}");
        foreach (var item in ToleranceItems(termLang))
            if (item.Get(own.Tolerance) != item.Get(standard.Tolerance)) output.Add($"{item.Label}: {OnOff(item.Get(own.Tolerance))}");
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
        (true, false) => $"Alle Fragen kommen als Multiple Choice. {LockHint}",
        (false, true) => $"Alle Fragen beantwortest du schriftlich. {LockHint}",
        _ => "Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst.",
    };

    /// <summary>A tolerance switch with an example (Mac: ToleranceItem).</summary>
    public sealed record ToleranceItem(string Label, string Example, Func<Tolerance, bool> Get, Func<bool, TolerancePatch> Patch);

    /// <summary>The seven tolerance switches with an example in the set's language (Mac: toleranceItems).</summary>
    public static IReadOnlyList<ToleranceItem> ToleranceItems(Lang termLang)
    {
        var article = termLang switch
        {
            Lang.Fr => "«homme» für «l'homme»",
            Lang.En => "«house» für «the house»",
            Lang.Es or Lang.It => "«casa» für «la casa»",
            _ => "«Herr» für «der Herr»",
        };
        var abbreviation = termLang switch
        {
            Lang.Fr => "«etw.» = «etwas», «qc» = «quelque chose»",
            Lang.En => "«etw.» = «etwas», «sth» = «something»",
            _ => "«etw.» = «etwas», «jdn.» = «jemanden»",
        };
        var accents = termLang switch
        {
            Lang.Fr => "«ecole» = «école», «ahnlich» = «ähnlich»",
            Lang.Es => "«arbol» = «árbol», «ahnlich» = «ähnlich»",
            Lang.It => "«citta» = «città», «ahnlich» = «ähnlich»",
            Lang.Zh => "«ni hao» = «nǐ hǎo», «ahnlich» = «ähnlich»",
            _ => "«ahnlich» = «ähnlich»",
        };
        return
        [
            new("Artikel/Pronomen vergessen erlaubt", $"{article} – ein falscher Artikel bleibt falsch", t => t.Articles, v => new TolerancePatch(Articles: v)),
            new("Abkürzungen gleichwertig", abbreviation, t => t.Abbreviations, v => new TolerancePatch(Abbreviations: v)),
            new("Eine von mehreren Antworten genügt", "«lieb» reicht bei «lieb, nett»", t => t.MultipleAnswers, v => new TolerancePatch(MultipleAnswers: v)),
            new("Klammerinhalt optional", "«freuen» für «(sich) freuen»", t => t.Parentheses, v => new TolerancePatch(Parentheses: v)),
            new("Gross-/Kleinschreibung ignorieren", "«herr» = «Herr»", t => t.IgnoreCase, v => new TolerancePatch(IgnoreCase: v)),
            new("Akzente ignorieren", accents, t => t.IgnoreAccents, v => new TolerancePatch(IgnoreAccents: v)),
            new("Kleine Tippfehler erlauben", "«Mädhcen» statt «Mädchen» – ein Buchstabe daneben", t => t.Typos, v => new TolerancePatch(Typos: v)),
        ];
    }
}
