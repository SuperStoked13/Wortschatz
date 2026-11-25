using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// Cards that ask for the same word (Joan, 10.11.2026): «etw. entführen» → «to hijack sth» and «jmdn. entführen» →
/// «to kidnap sb». Writing «to kidnap sb» for the first is wrong by the card, but it is the right answer to the
/// other card with the same word – the app then asks what it should count as (Windows/Android:
/// StudyChrome.AskSameTerm). Cards whose prompts are exactly the same are synonym cards already and count as right
/// on their own (<see cref="Synonyms.GradeWithSynonyms"/>); this is for prompts that differ only in placeholders,
/// articles or notes in brackets.
/// </summary>
public static class SameTermCards
{
    // MARK: Texts (Windows and Mac say the same)

    public static string Title => L("Andere Karte mit dem gleichen Begriff");

    /// <summary>"«to kidnap sb» ist die richtige Antwort für «jmdn. entführen». Gefragt war aber «etw. entführen»."</summary>
    public static string Message(string given, string askedPrompt, string otherPrompt) =>
        L($"«{JSCompat.Trim(given)}» ist die richtige Antwort für «{otherPrompt}». Gefragt war aber «{askedPrompt}».");

    /// <summary>The three choices, each with what it does (shown above the buttons).</summary>
    public static IReadOnlyList<(string Button, string Explanation)> Choices(string askedPrompt, string otherPrompt) =>
    [
        (L("Als richtig zählen"), L($"«{askedPrompt}» zählt als gewusst – für dich ist es dasselbe.")),
        (L("Für die andere Karte zählen"), L($"«{otherPrompt}» zählt als gewusst. «{askedPrompt}» bleibt falsch und kommt nochmals.")),
        (L("Als falsch zählen"), L("Nichts wird gutgeschrieben, die Antwort bleibt falsch.")),
    ];

    /// <summary>The toast after "Für die andere Karte zählen".</summary>
    public static string CountedForOther(string askedPrompt, string otherPrompt) =>
        L($"«{otherPrompt}» als gewusst gezählt – «{askedPrompt}» bleibt falsch und kommt nochmals.");

    /// <summary>
    /// The other card whose prompt is the same word as <paramref name="card"/>'s and whose answer
    /// <paramref name="given"/> is (graded with the session's tolerance), or null.
    /// </summary>
    public static Card? AnswerOfOtherCard(string given, Card card, IReadOnlyList<Card> cards, AskSide ask, Tolerance tolerance,
        Lang promptLang, Lang answerLang)
    {
        if (JSCompat.Trim(given).Length == 0) return null;
        var keys = TermKeys(Synonyms.PromptSide(card, ask), promptLang);
        if (keys.Count == 0) return null;
        foreach (var other in cards)
        {
            if (other.Id == card.Id) continue;
            var answer = Synonyms.AnswerSide(other, ask);
            if (JSCompat.Trim(answer).Length == 0 || !TermKeys(Synonyms.PromptSide(other, ask), promptLang).Overlaps(keys)) continue;
            if (Grading.Grade(given, answer, tolerance, answerLang).Correct) return other;
        }
        return null;
    }

    /// <summary>
    /// The word a prompt asks for, without placeholders, articles, reflexive pronouns and notes in brackets, for the
    /// prompt and each of its alternatives: «etw. entführen» and «jmdn. entführen» → «entführen». Remembered per text:
    /// a wrong answer looks at every card of the set, again and again during a session (shared: read it only).
    /// </summary>
    public static IReadOnlySet<string> TermKeys(string prompt, Lang lang) =>
        TermKeysMemo.Value($"{lang.Raw()}\u0001{prompt}", _ => BuildTermKeys(prompt, lang));

    static readonly TextMemo<HashSet<string>> TermKeysMemo = new(20_000);

    static HashSet<string> BuildTermKeys(string prompt, Lang lang)
    {
        var keys = new HashSet<string>(StringComparer.Ordinal);
        void Add(string text)
        {
            var key = SynonymLexicon.KeyOf(ExtendedSynonyms.StripBracketed(text), lang);
            if (key.Length > 0) keys.Add(key);
        }
        Add(prompt);
        foreach (var alternative in Grading.SplitAlternatives(prompt, lang)) Add(alternative);
        return keys;
    }
}
