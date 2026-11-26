using System.Text.RegularExpressions;
using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// Texts and pure helpers of the set editor and its import panel (Mac: SetEditorCopy.swift, ImportSeparator.swift,
/// ImportSpelling.swift and parseOptions of ImportPanelModel.swift = editor-util.js, editor.js, editor-cards.js).
/// German source with Swiss spelling ("ss", never the sharp s), translated with <see cref="CoreText.L(string)"/>.
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

    public static string TitlePlaceholder => L("z. B. Unité 3 – Les personnes");
    public static string DescriptionPlaceholder => L("Optional – z. B. Kapitel, Lehrmittel oder Prüfungsdatum");
    public static string TitleMissing => L("Gib deinem Lernset einen Titel.");
    public static string TitleFromFile => L("Aus dem Dateinamen übernommen – du kannst ihn jederzeit ändern.");
    public static string Detected => L("Automatisch erkannt");
    public static string ListDiverted => L("Liste erkannt – die Paare stehen jetzt in den Karten. Trennung und Seiten passt du oben an.");
    /// <summary>"Automatisch" in the language pickers (a new set's default; Mac: SetEditorCopy.automatic).</summary>
    public static string Automatic => L("Automatisch");
    public static string EmptyLead => L("Tippe deine Vokabeln ein – oder importiere oben eine ganze Liste auf einmal.");
    public static string TermPlaceholder => L("Begriff eingeben");
    public static string DefinitionPlaceholder => L("Definition eingeben");
    public static string ImportPlaceholder => L("Füge deine Vokabelliste hier ein – z. B. aus Word, einer PDF oder Quizlet. Begriff und Übersetzung werden automatisch erkannt.");
    public static string ImportHint => L("Tipp: Funktioniert mit abwechselnden Zeilen, Tabellen (Tab, Komma, Strichpunkt, Bindestrich) und Quizlet-Exporten.");
    /// <summary>The save button: "Lernset erstellen" for a new set, "Sichern" for an existing one.</summary>
    public static string SaveLabel(bool isEditing) => isEditing ? L("Sichern") : L("Lernset erstellen");

    /// <summary>Why saving cannot work yet (<c>readiness</c> in editor.js), null when it can.</summary>
    public static string? Readiness(bool titleIsEmpty, int completeCards)
    {
        if (titleIsEmpty) return L("Titel fehlt");
        if (completeCards == 0) return L("Noch keine vollständige Karte");
        return null;
    }

    /// <summary>The cards section's error after a save attempt (<c>cardsMessage</c> in editor.js).</summary>
    public static string? CardsMessage(int completeCards, int invalidCards)
    {
        if (completeCards == 0) return L("Füge mindestens eine Karte mit Begriff und Definition hinzu.");
        if (invalidCards > 0)
            return L($"{Labels.Plural(invalidCards, "Karte ist", "Karten sind")} unvollständig – ergänze Begriff und Definition oder lösche sie.");
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

    /// <summary>The text of a flag that earns an amber "bitte prüfen" marker (<c>FLAG_TEXT</c>; duplicates are shown separately), else null.</summary>
    static string? FlagText(ParseFlag flag) => flag switch
    {
        ParseFlag.Merged => L("Aus mehreren Zeilen zusammengefügt"),
        ParseFlag.LowConfidence => L("Unsicher erkannt"),
        ParseFlag.LangMismatch => L("Sprache passt nicht zur Spalte"),
        ParseFlag.MissingTerm => L("Begriff fehlt"),
        ParseFlag.MissingDefinition => L("Definition fehlt"),
        _ => null,
    };

    /// <summary>Whether the flags earn a marker (<c>hasMarker</c>).</summary>
    public static bool HasMarker(IEnumerable<ParseFlag> flags) => flags.Any(f => FlagText(f) is not null);

    /// <summary>The marker's tooltip, e.g. "Unsicher erkannt – bitte prüfen" (<c>flagTooltip</c>).</summary>
    public static string? FlagTooltip(IEnumerable<ParseFlag> flags)
    {
        var parts = flags.Select(FlagText).OfType<string>().ToList();
        return parts.Count == 0 ? null : L($"{string.Join(" · ", parts)} – bitte prüfen");
    }

    /// <summary>The flags after swapping term and definition.</summary>
    public static IReadOnlyList<ParseFlag> Swapped(IEnumerable<ParseFlag> flags) => flags.Select(f => f switch
    {
        ParseFlag.MissingTerm => ParseFlag.MissingDefinition,
        ParseFlag.MissingDefinition => ParseFlag.MissingTerm,
        _ => f,
    }).ToList();

    // MARK: Detection

    /// <summary>"Getrennt durch …" per delimiter, each a whole label (translatable as one phrase); null for others.</summary>
    static string? DelimiterLabel(string delimiter) => delimiter switch
    {
        "\t" => L("Getrennt durch Tabulator"),
        "," => L("Getrennt durch Komma"),
        ";" => L("Getrennt durch Strichpunkt"),
        "-" => L("Getrennt durch Bindestrich"),
        "=" => L("Getrennt durch Gleichheitszeichen"),
        ":" => L("Getrennt durch Doppelpunkt"),
        "|" => L("Getrennt durch Senkrechten Strich"),
        "→" => L("Getrennt durch Pfeil"),
        "/" => L("Getrennt durch Schrägstrich"),
        _ => null,
    };

    /// <summary>Short description of the detected layout (<c>formatLabel</c>).</summary>
    public static string? FormatLabel(ParseResult result)
    {
        switch (result.Format)
        {
            case ParseFormat.Blocks or ParseFormat.Alternating:
                return L("Abwechselnde Zeilen");
            case ParseFormat.Columns:
                return L("Zwei Spalten nacheinander");
            case ParseFormat.Delimited:
                var delimiter = result.Delimiter ?? "";
                if (delimiter == "  ") return L("Spalten mit Abstand");
                if (delimiter == " ") return L("Beide Sprachen in einer Zeile");
                var key = delimiter == "\t" ? "\t" : JSCompat.Trim(delimiter);
                if (DelimiterLabel(key) is { } label) return label;
                return key.Length == 0 ? null : L($"Getrennt durch «{key}»");
            default:
                return null;
        }
    }

    /// <summary>Why a line was skipped (<c>SKIP_REASONS</c>).</summary>
    public static string SkipReasonText(SkipReason reason) => reason switch
    {
        SkipReason.Heading => L("Überschrift"),
        SkipReason.PageNumber => L("Seitenzahl"),
        SkipReason.Noise => L("Kein Vokabeltext"),
        _ => L("Ohne Gegenstück"),
    };

    /// <summary>"52 Paare erkannt" / "Noch keine Paare erkannt".</summary>
    public static string PairsDetected(int count) => count > 0 ? L($"{Labels.Plural(count, "Paar", "Paare")} erkannt") : L("Noch keine Paare erkannt");

    /// <summary>
    /// The warnings to show under the detection: file notes, then the parser's (the skipped-lines warning is covered by
    /// the skipped-lines disclosure; compared as a whole, so it works in every language) (Mac: ImportPanelModel.warnings).
    /// </summary>
    public static IReadOnlyList<string> Warnings(ParseResult? result, IReadOnlyList<string> fileNotes)
    {
        if (result is null) return fileNotes;
        var skippedWarning = VocabParser.SkippedLinesWarning(result.Skipped.Count(s => s.Reason != SkipReason.Unpaired));
        return [.. fileNotes, .. result.Warnings.Where(w => w != skippedWarning)];
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
        var words = issues.Select(i => i.Suggestions.Count > 0 ? L($"«{i.Word}» ({i.Suggestions[0]}?)") : L($"«{i.Word}»"));
        var list = string.Join(", ", words);
        return issues.Count == 1 ? L($"Möglicher Tippfehler: {list}") : L($"Mögliche Tippfehler: {list}");
    }

    /// <summary>"1 möglicher Tippfehler" / "3 mögliche Tippfehler".</summary>
    public static string TypoCount(int count) => count == 1 ? L("1 möglicher Tippfehler") : L($"{count} mögliche Tippfehler");
}

/// <summary>The "Trennung" choices of the import panel (Mac: ImportSeparator.swift, <c>SEPARATORS</c> in editor-util.js).</summary>
public enum ImportSeparator { Auto, Tab, Comma, Semicolon, Dash, Lines, Custom }

public static class ImportSeparatorExtensions
{
    public static readonly IReadOnlyList<ImportSeparator> All = Enum.GetValues<ImportSeparator>();

    public static string Label(this ImportSeparator separator) => separator switch
    {
        ImportSeparator.Auto => L("Automatisch"),
        ImportSeparator.Tab => L("Tab"),
        ImportSeparator.Comma => L("Komma"),
        ImportSeparator.Semicolon => L("Strichpunkt"),
        ImportSeparator.Dash => L("Bindestrich"),
        ImportSeparator.Lines => L("Zeilenweise"),
        _ => L("Eigenes…"),
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
