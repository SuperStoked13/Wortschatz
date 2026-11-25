using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>The editor's pure helpers (Mac: SetEditorCopy.swift, ImportSeparator.swift, ImportPanelModel.parseOptions).</summary>
public class SetEditorCopyTests
{
    [Theory]
    [InlineData("Unité_3 - Vocabulaire.pdf", "Unité 3 - Vocabulaire")]
    [InlineData("Lektion  4__Familie.txt", "Lektion 4 Familie")]
    [InlineData("IMG_1234.jpg", "")]
    [InlineData("img 1234.heic", "")]
    [InlineData("Screenshot 2026-11-03 at 10.15.png", "")]
    [InlineData("Bildschirmfoto 2026-11-03.png", "")]
    [InlineData("PXL_20261103_101500.jpg", "")]
    [InlineData("Scan.pdf", "")]
    [InlineData("Scanner-Vokabeln.pdf", "Scanner-Vokabeln")]
    [InlineData("a.txt", "")]
    [InlineData("Image", "")]
    [InlineData("Imagerie.txt", "Imagerie")]
    public void TitleFromFileName(string name, string expected) => Assert.Equal(expected, SetEditorCopy.TitleFromFileName(name));

    [Fact]
    public void TitleFromFileNameKeepsAtMost80Characters()
    {
        var title = SetEditorCopy.TitleFromFileName(new string('x', 100) + ".txt");
        Assert.Equal(80, title.Length);
    }

    [Fact]
    public void CleanTitleAndDescription()
    {
        Assert.Equal("Unité 3 Les personnes", SetEditorCopy.CleanTitle("Unité 3\r\nLes personnes"));
        Assert.Equal(SetEditorCopy.TitleLimit, SetEditorCopy.CleanTitle(new string('a', 200)).Length);
        Assert.Equal(SetEditorCopy.DescriptionLimit, SetEditorCopy.CleanDescription(new string('a', 700)).Length);
        Assert.Equal("Zeile 1\nZeile 2", SetEditorCopy.CleanDescription("Zeile 1\nZeile 2"));
    }

    [Fact]
    public void TermKeyIgnoresCaseSpacesAndEndPunctuation()
    {
        Assert.Equal(SetEditorCopy.TermKey("La maison"), SetEditorCopy.TermKey("  la   MAISON!"));
        Assert.Equal(SetEditorCopy.TermKey("Bonjour"), SetEditorCopy.TermKey("bonjour?."));
        Assert.NotEqual(SetEditorCopy.TermKey("la maison"), SetEditorCopy.TermKey("le maison"));
        Assert.Equal("", SetEditorCopy.TermKey("   "));
    }

    [Fact]
    public void ReadinessAndCardsMessage()
    {
        Assert.Equal("Titel fehlt", SetEditorCopy.Readiness(true, 3));
        Assert.Equal("Noch keine vollständige Karte", SetEditorCopy.Readiness(false, 0));
        Assert.Null(SetEditorCopy.Readiness(false, 1));
        Assert.Equal("Füge mindestens eine Karte mit Begriff und Definition hinzu.", SetEditorCopy.CardsMessage(0, 0));
        Assert.Equal("1 Karte ist unvollständig – ergänze Begriff und Definition oder lösche sie.", SetEditorCopy.CardsMessage(2, 1));
        Assert.Equal("2 Karten sind unvollständig – ergänze Begriff und Definition oder lösche sie.", SetEditorCopy.CardsMessage(2, 2));
        Assert.Null(SetEditorCopy.CardsMessage(2, 0));
    }

    [Fact]
    public void FlagsMarkerTooltipAndSwap()
    {
        Assert.False(SetEditorCopy.HasMarker([ParseFlag.Duplicate]));
        Assert.True(SetEditorCopy.HasMarker([ParseFlag.Duplicate, ParseFlag.LowConfidence]));
        Assert.Null(SetEditorCopy.FlagTooltip([ParseFlag.Duplicate]));
        Assert.Equal("Unsicher erkannt · Begriff fehlt – bitte prüfen", SetEditorCopy.FlagTooltip([ParseFlag.LowConfidence, ParseFlag.MissingTerm]));
        Assert.Equal([ParseFlag.MissingDefinition, ParseFlag.Merged, ParseFlag.MissingTerm],
            SetEditorCopy.Swapped([ParseFlag.MissingTerm, ParseFlag.Merged, ParseFlag.MissingDefinition]));
    }

    static ParseResult Result(ParseFormat format, string? delimiter, IReadOnlyList<SkippedLine>? skipped = null, IReadOnlyList<string>? warnings = null) =>
        new([], format, delimiter, Lang.Fr, Lang.De, false, skipped ?? [], warnings ?? []);

    [Fact]
    public void FormatLabel()
    {
        Assert.Equal("Abwechselnde Zeilen", SetEditorCopy.FormatLabel(Result(ParseFormat.Alternating, null)));
        Assert.Equal("Abwechselnde Zeilen", SetEditorCopy.FormatLabel(Result(ParseFormat.Blocks, null)));
        Assert.Equal("Zwei Spalten nacheinander", SetEditorCopy.FormatLabel(Result(ParseFormat.Columns, null)));
        Assert.Equal("Getrennt durch Tabulator", SetEditorCopy.FormatLabel(Result(ParseFormat.Delimited, "\t")));
        Assert.Equal("Getrennt durch Bindestrich", SetEditorCopy.FormatLabel(Result(ParseFormat.Delimited, " - ")));
        Assert.Equal("Spalten mit Abstand", SetEditorCopy.FormatLabel(Result(ParseFormat.Delimited, "  ")));
        Assert.Equal("Beide Sprachen in einer Zeile", SetEditorCopy.FormatLabel(Result(ParseFormat.Delimited, " ")));
        Assert.Equal("Getrennt durch «#»", SetEditorCopy.FormatLabel(Result(ParseFormat.Delimited, "#")));
        Assert.Null(SetEditorCopy.FormatLabel(Result(ParseFormat.Empty, null)));
    }

    [Fact]
    public void WarningsDropTheSkippedWarningWhenTheLinesAreListed()
    {
        // The parser's own warning, compared as a whole (works in every language).
        var skippedWarning = VocabParser.SkippedLinesWarning(1);
        Assert.Equal("1 Zeile ohne Vokabeln wurde übersprungen.", skippedWarning);
        var skipped = new[] { new SkippedLine(1, "Vocabulaire", SkipReason.Heading) };
        var result = Result(ParseFormat.Delimited, "-", skipped, [skippedWarning, "Gemischte Trennzeichen"]);
        Assert.Equal(["Seite 2 fehlt", "Gemischte Trennzeichen"], SetEditorCopy.Warnings(result, ["Seite 2 fehlt"]));
        Assert.Equal([skippedWarning], SetEditorCopy.Warnings(Result(ParseFormat.Delimited, "-", null, [skippedWarning]), []));
        Assert.Equal(["Notiz"], SetEditorCopy.Warnings(null, ["Notiz"]));
    }

    [Fact]
    public void PairsDetectedAndTypoTexts()
    {
        Assert.Equal("52 Paare erkannt", SetEditorCopy.PairsDetected(52));
        Assert.Equal("1 Paar erkannt", SetEditorCopy.PairsDetected(1));
        Assert.Equal("Noch keine Paare erkannt", SetEditorCopy.PairsDetected(0));
        Assert.Equal("1 möglicher Tippfehler", SetEditorCopy.TypoCount(1));
        Assert.Equal("3 mögliche Tippfehler", SetEditorCopy.TypoCount(3));
        Assert.Null(SetEditorCopy.TypoTooltip([]));
        Assert.Equal("Möglicher Tippfehler: «separee» (séparée?)", SetEditorCopy.TypoTooltip([new SpellingIssue("separee", 0, 7, ["séparée"])]));
        Assert.Equal("Mögliche Tippfehler: «a» (b?), «c»",
            SetEditorCopy.TypoTooltip([new SpellingIssue("a", 0, 1, ["b"]), new SpellingIssue("c", 2, 1, [])]));
    }

    [Fact]
    public void InsertedText()
    {
        Assert.Equal("xyz", SetEditorCopy.InsertedText("abc", "abxyzc"));
        Assert.Equal("hello", SetEditorCopy.InsertedText("", "hello"));
        Assert.Equal("", SetEditorCopy.InsertedText("abc", "ac"));
        Assert.Equal("a\nb", SetEditorCopy.InsertedText("[]", "[a\nb]"));
    }

    [Fact]
    public void PasteShapes()
    {
        Assert.Null(SetEditorCopy.PasteShapeOf("maison", rowIsEmpty: true));
        Assert.Equal(new SetEditorCopy.PasteShape.Pair("la maison", "das Haus"), SetEditorCopy.PasteShapeOf("la maison\tdas Haus\n", rowIsEmpty: true));
        // Into a filled row a single pair is no shape (the text stays as typed).
        Assert.Null(SetEditorCopy.PasteShapeOf("la maison\tdas Haus", rowIsEmpty: false));
        Assert.Null(SetEditorCopy.PasteShapeOf("eins\nzwei", rowIsEmpty: true));
        Assert.Equal(new SetEditorCopy.PasteShape.List("a\nb\nc"), SetEditorCopy.PasteShapeOf("a\nb\nc", rowIsEmpty: false));
        Assert.Equal(new SetEditorCopy.PasteShape.List("a\t1\r\nb\t2"), SetEditorCopy.PasteShapeOf("a\t1\r\nb\t2", rowIsEmpty: false));
        Assert.Null(SetEditorCopy.PasteShapeOf("\n", rowIsEmpty: true));
    }

    [Fact]
    public void SeparatorsConfigureTheParser()
    {
        var o = new ParseOptions();
        Assert.Same(o, ImportSeparator.Auto.Configure(o, ""));
        Assert.Equal((ParseMode.Delimiter, "\t"), Pick(ImportSeparator.Tab.Configure(o, "")));
        Assert.Equal((ParseMode.Delimiter, ","), Pick(ImportSeparator.Comma.Configure(o, "")));
        Assert.Equal((ParseMode.Delimiter, ";"), Pick(ImportSeparator.Semicolon.Configure(o, "")));
        Assert.Equal((ParseMode.Delimiter, "-"), Pick(ImportSeparator.Dash.Configure(o, "")));
        Assert.Equal((ParseMode.Lines, null), Pick(ImportSeparator.Lines.Configure(o, "")));
        Assert.Equal((ParseMode.Auto, null), Pick(ImportSeparator.Custom.Configure(o, "")));
        Assert.Equal((ParseMode.Delimiter, "/"), Pick(ImportSeparator.Custom.Configure(o, " / ")));
        Assert.Equal((ParseMode.Delimiter, "  "), Pick(ImportSeparator.Custom.Configure(o, "  ")));
        Assert.Equal(["Automatisch", "Tab", "Komma", "Strichpunkt", "Bindestrich", "Zeilenweise", "Eigenes…"], ImportSeparatorExtensions.All.Select(s => s.Label()));
        static (ParseMode, string?) Pick(ParseOptions p) => (p.Mode, p.Delimiter);
    }

    [Fact]
    public void ParseOptionsUseOnlyChosenLanguages()
    {
        var untouched = SetEditorCopy.ParseOptionsFor(ImportSeparator.Auto, "", false, Lang.Es, false, Lang.En, false);
        Assert.Null(untouched.TermLang);
        Assert.Equal(Lang.De, untouched.DefLang);
        Assert.False(untouched.Swap);
        var chosen = SetEditorCopy.ParseOptionsFor(ImportSeparator.Semicolon, "", true, Lang.Es, true, Lang.En, true);
        Assert.Equal(Lang.Es, chosen.TermLang);
        Assert.Equal(Lang.En, chosen.DefLang);
        Assert.True(chosen.Swap);
        Assert.Equal(";", chosen.Delimiter);
        Assert.Null(SetEditorCopy.ParseOptionsFor(ImportSeparator.Auto, "", false, Lang.Other, true, Lang.De, true).TermLang);
    }

    [Fact]
    public void LanguageOrders()
    {
        Assert.Equal(Labels.LANG_ORDER, SetEditorCopy.TermLanguages);
        Assert.Equal(Lang.De, SetEditorCopy.DefinitionLanguages[0]);
        Assert.Equal(Labels.LANG_ORDER.Length, SetEditorCopy.DefinitionLanguages.Count);
    }

    [Fact]
    public void SwapOptionSwapsTheParsedSides()
    {
        var text = "la maison - das Haus\nle chat - die Katze\nle chien - der Hund";
        var normal = VocabParser.ParseVocab(text);
        var swapped = VocabParser.ParseVocab(text, SetEditorCopy.ParseOptionsFor(ImportSeparator.Auto, "", true, Lang.Fr, false, Lang.De, false));
        Assert.Equal(normal.Cards.Select(c => (c.Definition, c.Term)), swapped.Cards.Select(c => (c.Term, c.Definition)));
    }

    [Fact]
    public void UndoHistory()
    {
        var history = new UndoHistory<int>();
        Assert.False(history.CanUndo);
        var first = history.Register("a", 0, 1);
        history.Register("b", 1, 2);
        Assert.Equal(1, history.Undo()!.Before);
        Assert.True(history.CanRedo);
        Assert.Equal(2, history.Redo()!.After);
        Assert.Equal(1, history.Undo()!.Before);
        // A new change drops what was undone.
        history.Register("c", 1, 5);
        Assert.False(history.CanRedo);
        Assert.True(history.Revert(first));
        Assert.False(history.Revert(first));
        Assert.Equal("c", history.Undo()!.Name);
        Assert.Null(history.Undo());
        history.Clear();
        Assert.False(history.CanRedo);
    }
}
