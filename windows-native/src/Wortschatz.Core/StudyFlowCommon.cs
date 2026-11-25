namespace Wortschatz.Core;

// Port of StudyFlowCommon.swift: shared vocabulary for the study flow reducers (LearnFlow, WriteFlow).
// Views translate raw key events into KeyPress values; the reducers decide what each key does in the
// current phase (spec §4.3 and §6).
//
// Swift's `enum KeyInput` with associated values is a record struct here: compare with ==
// (`key == KeyInput.Return`, `key == KeyInput.Arrow(Direction.Up)`) or switch on Kind.
// Mac key names map to Windows keys in the app: ⌥↩ = Alt+Enter, ⌘↩ = Ctrl+Enter, ⌫ = Backspace,
// ⌥⌫ = Ctrl+Backspace.

public enum Direction { Up, Down, Left, Right }

public enum KeyKind
{
    Return,
    /// <summary>⌥↩ on the Mac, Alt+Enter on Windows.</summary>
    OptionReturn,
    /// <summary>⌘↩ on the Mac, Ctrl+Enter on Windows.</summary>
    CommandReturn,
    Escape,
    /// <summary>Number keys 0–9 (top row or keypad).</summary>
    Digit,
    Arrow,
    /// <summary>Any other printable key, as typed (e.g. "r", "?").</summary>
    Character,
    /// <summary>Backspace: removes the last letter typed on a multiple-choice question.</summary>
    DeleteBackward,
    /// <summary>⌥⌫ / Ctrl+Backspace: removes the last word typed on a multiple-choice question.</summary>
    DeleteWordBackward,
}

/// <summary>A key (Swift <c>KeyInput</c>). Use the static members and factories, not the constructor.</summary>
public readonly record struct KeyInput(KeyKind Kind, int Digit = 0, Direction Direction = Direction.Up, string? Text = null)
{
    public static readonly KeyInput Return = new(KeyKind.Return);
    public static readonly KeyInput OptionReturn = new(KeyKind.OptionReturn);
    public static readonly KeyInput CommandReturn = new(KeyKind.CommandReturn);
    public static readonly KeyInput Escape = new(KeyKind.Escape);
    public static readonly KeyInput DeleteBackward = new(KeyKind.DeleteBackward);
    public static readonly KeyInput DeleteWordBackward = new(KeyKind.DeleteWordBackward);
    public static KeyInput DigitKey(int n) => new(KeyKind.Digit, Digit: n);
    public static KeyInput Arrow(Direction d) => new(KeyKind.Arrow, Direction: d);
    public static KeyInput Character(string text) => new(KeyKind.Character, Text: text);

    /// <summary>Backspace and Ctrl+Backspace: held down they keep deleting (their repeats count, unlike other keys').</summary>
    public bool IsDeletion => Kind is KeyKind.DeleteBackward or KeyKind.DeleteWordBackward;

    public override string ToString() => Kind switch
    {
        KeyKind.Digit => $"digit({Digit})",
        KeyKind.Arrow => $"arrow({Direction})",
        KeyKind.Character => $"character({Text})",
        _ => Kind.ToString(),
    };
}

/// <summary>A key press; IsRepeat for auto-repeat events while a key is held (repeats never cause a transition).</summary>
public readonly record struct KeyPress(KeyInput Key, bool IsRepeat = false);

/// <summary>
/// Lernen, Schreiben, Karteikarten (flashcards: sorted by the learner, no answers recorded) and Prüfung
/// (exam: marked and graded, no answers recorded either).
/// </summary>
public enum StudyMode { Learn, Write, Flashcards, Exam }

public enum HapticKind { Success, Failure }

/// <summary>
/// The copy step ("Richtige Antwort abtippen", Lernen and Schreiben) continues by itself, after a short beat
/// (AdvanceMs), once the answer is typed out: accepted with the same tolerance as an answer to the question
/// ("le collègue" for "le/la collègue"), unless what is typed is only the start of the answer as shown ("le cerveau"
/// of "le cerveau, les cerveaux", "Aussenminister" of "Aussenminister(in)"). Those wait for Enter, so whoever copies
/// the whole answer is never cut off halfway and the rest of it never lands in the next question. (Port of CopyStep in
/// StudyFlowCommon.swift, Mac 24.11.2026, Windows since 24.11.2026.)
/// </summary>
public static class CopyStep
{
    /// <summary>
    /// The beat between the copy being typed out and the next question: the finished word shows for a moment instead
    /// of vanishing with its last letter. Enter skips it.
    /// </summary>
    public const int AdvanceMs = 400;

    public static bool IsTypedOut(string value, string expected, Tolerance tolerance, Lang? lang)
    {
        var result = Grading.Grade(value, expected, tolerance, lang);
        if (!result.Correct) return false;
        if (result.Exact) return true;
        var typed = Fold(value);
        var shown = Fold(expected);
        return typed == shown || !shown.StartsWith(typed, StringComparison.Ordinal);
    }

    /// <summary>Upper/lower case, spacing, accents and ligatures do not matter ("l'oeil" starts "l'œil").</summary>
    static string Fold(string text) =>
        JSCompat.Lower(TextNormalizer.StripDiacritics(TextNormalizer.FoldScripts(TextNormalizer.NormalizeBasic(text))));
}

/// <summary>
/// «Später» on «Neu starten?» after options that shape a session were changed (Lernen: direction, question types, round
/// size; Schreiben: direction, «Mischen»): the session that started at <see cref="StartedAt"/> keeps running with its own
/// settings while the options are <see cref="Settings"/> (a JSON of those options), and is not asked again until they
/// change. Windows only (issue #7, 24.11.2026): stored per set and mode on this device (AppPreferences.KeptOptions).
/// </summary>
public sealed record KeptOptions(double StartedAt, JSONValue Settings) : IJsonEncodable
{
    /// <summary>Whether this covers the session that started at startedAt with the options now giving settings.</summary>
    public bool Covers(double startedAt, JSONValue settings) =>
        StartedAt == startedAt && Settings.ToJsonString(sortedKeys: true) == settings.ToJsonString(sortedKeys: true);

    public JSONValue ToJson() => JSONValue.Obj(("startedAt", StartedAt), ("settings", Settings));

    public static KeptOptions? FromJson(JSONValue? json) =>
        json?["startedAt"]?.FiniteNumber is { } t && json["settings"] is { IsObject: true } settings ? new KeptOptions(t, settings) : null;
}
