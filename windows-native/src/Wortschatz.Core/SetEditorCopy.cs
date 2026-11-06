using System.Text.RegularExpressions;

namespace Wortschatz.Core;

/// <summary>
/// Texts and pure helpers of the set editor and its import panel (Mac: SetEditorCopy.swift, ImportSeparator.swift,
/// ImportSpelling.swift and parseOptions of ImportPanelModel.swift = editor-util.js, editor.js, editor-cards.js).
/// Swiss spelling ("ss", never the sharp s).
/// </summary>
public static class SetEditorCopy
{
    // MARK: Limits

    /// <summary>The list never shrinks below this many rows (<c>MIN_ROWS</c> in editor-cards.js).</summary>
    public const int MinimumRows = 2;
    /// <summary><c>maxlength</c> of the title field.</summary>
    public const int TitleLimit = 120;
    /// <summary><c>maxlength</c> of the description field.</summary>
    public const int DescriptionLimit = 600;
    /// <summary>The longest custom separator ("Eigenes…").</summary>
    public const int CustomSeparatorLimit = 8;

    // MARK: Languages

    /// <summary>"Ich lerne": the display order of the language pickers.</summary>
    public static readonly IReadOnlyList<Lang> TermLanguages = Labels.LANG_ORDER;
    /// <summary>"Übersetzung": German first.</summary>
    public static readonly IReadOnlyList<Lang> DefinitionLanguages = [Lang.De, .. Labels.LANG_ORDER.Where(l => l != Lang.De)];

    /// <summary>Whether a detected language may fill a picker (<c>knownLang</c> in editor.js).</summary>
    public static bool IsKnown(Lang lang) => lang != Lang.Other;

    // MARK: Texts

    public const string TitlePlaceholder = "z. B. Unité 3 – Les personnes";
    public const string DescriptionPlaceholder = "Optional – z. B. Kapitel, Lehrmittel oder Prüfungsdatum";
    public const string TitleMissing = "Gib deinem Lernset einen Titel.";
    public const string TitleFromFile = "Aus dem Dateinamen übernommen – du kannst ihn jederzeit ändern.";
    public const string Detected = "Automatisch erkannt";
    public const string ListDiverted = "Liste erkannt – prüfe die Vorschau und übernimm die Karten.";
    public const string EmptyLead = "Tippe deine Vokabeln ein – oder importiere oben eine ganze Liste auf einmal.";
    public const string TermPlaceholder = "Begriff eingeben";
    public const string DefinitionPlaceholder = "Definition eingeben";
    public const string ImportPlaceholder = "Füge deine Vokabelliste hier ein – z. B. aus Word, einer PDF oder Quizlet. Begriff und Übersetzung werden automatisch erkannt.";
    public const string ImportHint = "Tipp: Funktioniert mit abwechselnden Zeilen, Tabellen (Tab, Komma, Strichpunkt, Bindestrich) und Quizlet-Exporten.";
    /// <summary>Rows the import preview shows before it scrolls (<c>PREVIEW_ROWS</c>).</summary>
    public const int PreviewRows = 8;

    /// <summary>The save button: "Erstellen" for a new set, "Sichern" for an existing one.</summary>
    public static string SaveLabel(bool isEditing) => isEditing ? "Sichern" : "Erstellen";

    /// <summary>Why saving cannot work yet (<c>readiness</c> in editor.js), null when it can.</summary>
    public static string? Readiness(bool titleIsEmpty, int completeCards)
    {
        if (titleIsEmpty) return "Titel fehlt";
        if (completeCards == 0) return "Noch keine vollständige Karte";
        return null;
    }

    /// <summary>The cards section's error after a save attempt (<c>cardsMessage</c> in editor.js).</summary>
    public static string? CardsMessage(int completeCards, int invalidCards)
    {
        if (completeCards == 0) return "Füge mindestens eine Karte mit Begriff und Definition hinzu.";
        if (invalidCards > 0)
            return $"{Labels.Plural(invalidCards, "Karte ist", "Karten sind")} unvollständig – ergänze Begriff und Definition oder lösche sie.";
        return null;
    }

    // MARK: Keys

    /// <summary>Case- and whitespace-insensitive key used to find duplicate terms (<c>termKey</c>).</summary>
    public static string TermKey(string term) => JSCompat.Lower(TextNormalizer.NormalizeBasic(term)).TrimEnd('.', '!', '?');

    static readonly Regex Extension = new(@"\.[A-Za-z0-9]{1,5}$", RegexOptions.CultureInvariant);
    static readonly Regex Generic = new(@"^(?:image|img|screenshot|bildschirmfoto|scan|dsc|pxl|photo|foto|untitled|unbenannt)(?:[\s\d._-]|$)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Title suggestion from a file name (<c>titleFromFileName</c>): "Unité_3 - Vocabulaire.pdf" → "Unité 3 - Vocabulaire";
    /// camera and screenshot names give "".
    /// </summary>
    public static string TitleFromFileName(string name)
    {
        var text = Extension.Replace(name, "");
        text = Regex.Replace(text, "_+", " ");
        text = Regex.Replace(text, @"\s+", " ");
        text = JSCompat.Trim(text);
        var elements = System.Globalization.StringInfo.ParseCombiningCharacters(text);
        if (elements.Length < 2) return "";
        if (Generic.IsMatch(text)) return "";
        return elements.Length <= 80 ? text : text[..elements[80]];
    }

    /// <summary>The title as typed or pasted: line breaks become spaces, at most <see cref="TitleLimit"/> characters.</summary>
    public static string CleanTitle(string value)
    {
        var text = Regex.Replace(value, @"[\r\n]+", " ");
        return text.Length <= TitleLimit ? text : text[..TitleLimit];
    }

    /// <summary>The description, at most <see cref="DescriptionLimit"/> characters.</summary>
    public static string CleanDescription(string value) => value.Length <= DescriptionLimit ? value : value[..DescriptionLimit];

    // MARK: Parser flags

    /// <summary>Flags that earn an amber "bitte prüfen" marker (<c>FLAG_TEXT</c>; duplicates are shown separately).</summary>
    static readonly Dictionary<ParseFlag, string> FlagTexts = new()
    {
        [ParseFlag.Merged] = "Aus mehreren Zeilen zusammengefügt",
        [ParseFlag.LowConfidence] = "Unsicher erkannt",
        [ParseFlag.LangMismatch] = "Sprache passt nicht zur Spalte",
        [ParseFlag.MissingTerm] = "Begriff fehlt",
        [ParseFlag.MissingDefinition] = "Definition fehlt",
    };

    /// <summary>Whether the flags earn a marker (<c>hasMarker</c>).</summary>
    public static bool HasMarker(IEnumerable<ParseFlag> flags) => flags.Any(FlagTexts.ContainsKey);

    /// <summary>The marker's tooltip, e.g. "Unsicher erkannt – bitte prüfen" (<c>flagTooltip</c>).</summary>
    public static string? FlagTooltip(IEnumerable<ParseFlag> flags)
    {
        var parts = flags.Where(FlagTexts.ContainsKey).Select(f => FlagTexts[f]).ToList();
        return parts.Count == 0 ? null : $"{string.Join(" · ", parts)} – bitte prüfen";
    }

    /// <summary>The flags after swapping term and definition.</summary>
    public static IReadOnlyList<ParseFlag> Swapped(IEnumerable<ParseFlag> flags) => flags.Select(f => f switch
    {
        ParseFlag.MissingTerm => ParseFlag.MissingDefinition,
        ParseFlag.MissingDefinition => ParseFlag.MissingTerm,
        _ => f,
    }).ToList();

    // MARK: Detection

    static readonly Dictionary<string, string> DelimiterNames = new()
    {
        ["\t"] = "Tabulator",
        [","] = "Komma",
        [";"] = "Strichpunkt",
        ["-"] = "Bindestrich",
        ["="] = "Gleichheitszeichen",
        [":"] = "Doppelpunkt",
        ["|"] = "Senkrechten Strich",
        ["→"] = "Pfeil",
        ["/"] = "Schrägstrich",
    };

    /// <summary>Short German description of the detected layout (<c>formatLabel</c>).</summary>
    public static string? FormatLabel(ParseResult result)
    {
        switch (result.Format)
        {
            case ParseFormat.Blocks or ParseFormat.Alternating:
                return "Abwechselnde Zeilen";
            case ParseFormat.Columns:
                return "Zwei Spalten nacheinander";
            case ParseFormat.Delimited:
                var delimiter = result.Delimiter ?? "";
                if (delimiter == "  ") return "Spalten mit Abstand";
                if (delimiter == " ") return "Beide Sprachen in einer Zeile";
                var key = delimiter == "\t" ? "\t" : JSCompat.Trim(delimiter);
                if (DelimiterNames.TryGetValue(key, out var name)) return $"Getrennt durch {name}";
                return key.Length == 0 ? null : $"Getrennt durch «{key}»";
            default:
                return null;
        }
    }

    /// <summary>Why a line was skipped (<c>SKIP_REASONS</c>).</summary>
    public static string SkipReasonText(SkipReason reason) => reason switch
    {
        SkipReason.Heading => "Überschrift",
        SkipReason.PageNumber => "Seitenzahl",
        SkipReason.Noise => "Kein Vokabeltext",
        _ => "Ohne Gegenstück",
    };

    /// <summary>"52 Paare erkannt" / "Noch keine Paare erkannt".</summary>
    public static string PairsDetected(int count) => count > 0 ? $"{Labels.Plural(count, "Paar", "Paare")} erkannt" : "Noch keine Paare erkannt";

    /// <summary>
    /// The warnings to show under the detection: file notes, then the parser's (the "übersprungen" warning is covered by
    /// the skipped-lines disclosure) (Mac: ImportPanelModel.warnings).
    /// </summary>
    public static IReadOnlyList<string> Warnings(ParseResult? result, IReadOnlyList<string> fileNotes)
    {
        if (result is null) return fileNotes;
        bool skipped = result.Skipped.Count > 0;
        return [.. fileNotes, .. result.Warnings.Where(w => !(skipped && w.Contains("übersprungen", StringComparison.Ordinal)))];
    }

    // MARK: Parse options

    /// <summary>
    /// The options the import panel parses with (Mac: ImportPanelModel.parseOptions): the term language only when the
    /// learner chose it, the definition language when chosen (else German), the separator, and "Seiten tauschen".
    /// </summary>
    public static ParseOptions ParseOptionsFor(ImportSeparator separator, string customSeparator, bool swap,
        Lang termLang, bool termTouched, Lang defLang, bool defTouched)
    {
        var options = new ParseOptions
        {
            Swap = swap,
            TermLang = termTouched && termLang != Lang.Other ? termLang : null,
            DefLang = defTouched ? defLang : Lang.De,
        };
        return separator.Configure(options, customSeparator);
    }

    // MARK: Pasting into fields

    /// <summary>What a paste into a card field (or the title) means.</summary>
    public abstract record PasteShape
    {
        /// <summary>One spreadsheet row ("term⇥definition") pasted into an empty card: fills both fields.</summary>
        public sealed record Pair(string Term, string Definition) : PasteShape;
        /// <summary>A whole list: goes to the import box instead.</summary>
        public sealed record List(string Text) : PasteShape;
    }

    /// <summary>The text an edit inserted: <paramref name="newText"/> without the prefix and suffix it shares with <paramref name="old"/>.</summary>
    public static string InsertedText(string old, string newText)
    {
        int prefix = 0;
        while (prefix < old.Length && prefix < newText.Length && old[prefix] == newText[prefix]) prefix++;
        int suffix = 0;
        while (suffix < old.Length - prefix && suffix < newText.Length - prefix && old[old.Length - 1 - suffix] == newText[newText.Length - 1 - suffix]) suffix++;
        return newText.Substring(prefix, newText.Length - suffix - prefix);
    }

    static readonly char[] Newlines = [(char)0x0A, (char)0x0D, (char)0x0B, (char)0x0C, (char)0x85, (char)0x2028, (char)0x2029];

    static bool IsNewline(char c) => Array.IndexOf(Newlines, c) >= 0;

    /// <summary>
    /// The paste handling of editor-cards.js: a single tab-separated row into an empty card fills it; three or more lines
    /// (or two tab-separated ones) are a list for the import box.
    /// </summary>
    public static PasteShape? PasteShapeOf(string inserted, bool rowIsEmpty)
    {
        if (!inserted.Any(c => IsNewline(c) || c == '\t')) return null;
        var lines = inserted.Split(Newlines)
            .Where(l => JSCompat.Trim(l).Length > 0).ToList();
        if (lines.Count == 1 && rowIsEmpty)
        {
            var cells = lines[0].Split('\t').Select(c => JSCompat.Trim(c)).ToList();
            if (cells.Count == 2 && cells[0].Length > 0 && cells[1].Length > 0) return new PasteShape.Pair(cells[0], cells[1]);
        }
        bool tabbed = lines.Count >= 2 && lines.Count(l => l.Contains('\t')) >= 2;
        if (lines.Count >= 3 || tabbed) return new PasteShape.List(inserted);
        return null;
    }

    // MARK: Spelling (Mac: ImportSpelling)

    /// <summary>"Möglicher Tippfehler: «separee» (séparée?)".</summary>
    public static string? TypoTooltip(IReadOnlyList<SpellingIssue> issues)
    {
        if (issues.Count == 0) return null;
        var words = issues.Select(i => i.Suggestions.Count > 0 ? $"«{i.Word}» ({i.Suggestions[0]}?)" : $"«{i.Word}»");
        return $"{(issues.Count == 1 ? "Möglicher Tippfehler" : "Mögliche Tippfehler")}: {string.Join(", ", words)}";
    }

    /// <summary>"1 möglicher Tippfehler" / "3 mögliche Tippfehler".</summary>
    public static string TypoCount(int count) => count == 1 ? "1 möglicher Tippfehler" : $"{count} mögliche Tippfehler";
}

/// <summary>The "Trennung" choices of the import panel (Mac: ImportSeparator.swift, <c>SEPARATORS</c> in editor-util.js).</summary>
public enum ImportSeparator { Auto, Tab, Comma, Semicolon, Dash, Lines, Custom }

public static class ImportSeparatorExtensions
{
    public static readonly IReadOnlyList<ImportSeparator> All = Enum.GetValues<ImportSeparator>();

    public static string Label(this ImportSeparator separator) => separator switch
    {
        ImportSeparator.Auto => "Automatisch",
        ImportSeparator.Tab => "Tab",
        ImportSeparator.Comma => "Komma",
        ImportSeparator.Semicolon => "Strichpunkt",
        ImportSeparator.Dash => "Bindestrich",
        ImportSeparator.Lines => "Zeilenweise",
        _ => "Eigenes…",
    };

    /// <summary>
    /// Applies the choice to <paramref name="options"/>. An empty custom separator keeps automatic detection (the detection
    /// bar then asks for one); a separator of only spaces is used as typed.
    /// </summary>
    public static ParseOptions Configure(this ImportSeparator separator, ParseOptions options, string custom)
    {
        static ParseOptions Delimit(ParseOptions o, string d) => o with { Mode = ParseMode.Delimiter, Delimiter = d };
        switch (separator)
        {
            case ImportSeparator.Tab: return Delimit(options, "\t");
            case ImportSeparator.Comma: return Delimit(options, ",");
            case ImportSeparator.Semicolon: return Delimit(options, ";");
            case ImportSeparator.Dash: return Delimit(options, "-");
            case ImportSeparator.Lines: return options with { Mode = ParseMode.Lines };
            case ImportSeparator.Custom:
                if (custom.Length == 0) return options;
                var trimmed = JSCompat.Trim(custom);
                return Delimit(options, trimmed.Length == 0 ? custom : trimmed);
            default: return options;
        }
    }
}

/// <summary>
/// Undo and redo of the editor's list changes (Mac: the sheet's UndoManager with SetEditorModel.undoable): each change
/// keeps the state before and after it. Undo gives the state to restore and moves the change to the redo stack; a new
/// change clears the redo stack. <see cref="Revert"/> takes one change back from anywhere (its toast's "Rückgängig").
/// </summary>
public sealed class UndoHistory<TState>
{
    public sealed class Record(string name, TState before, TState after)
    {
        public string Name { get; } = name;
        public TState Before { get; } = before;
        public TState After { get; } = after;
    }

    readonly List<Record> _undo = [], _redo = [];

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    public Record Register(string name, TState before, TState after)
    {
        var record = new Record(name, before, after);
        _undo.Add(record);
        _redo.Clear();
        return record;
    }

    /// <summary>The state before the latest change (null: nothing to undo).</summary>
    public Record? Undo()
    {
        if (_undo.Count == 0) return null;
        var record = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        _redo.Add(record);
        return record;
    }

    /// <summary>The state after the latest undone change (null: nothing to redo).</summary>
    public Record? Redo()
    {
        if (_redo.Count == 0) return null;
        var record = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        _undo.Add(record);
        return record;
    }

    /// <summary>Takes <paramref name="record"/> off both stacks; false when it is gone already (undone or forgotten).</summary>
    public bool Revert(Record record) => _undo.Remove(record) | _redo.Remove(record);

    public void Clear()
    {
        _undo.Clear();
        _redo.Clear();
    }
}
