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
