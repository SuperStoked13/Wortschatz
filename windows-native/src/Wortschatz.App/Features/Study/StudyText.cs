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
                case DiffType.Del:
                    run.Foreground = WsTheme.B(P.Failure.Text);
                    run.TextDecorations = TextDecorations.Strikethrough;
                    break;
                case DiffType.Add:
                    run.Foreground = WsTheme.B(P.Success.Text);
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

    /// <summary>"Begriffe pro Runde" choices; a stored size outside them stays selectable.</summary>
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
