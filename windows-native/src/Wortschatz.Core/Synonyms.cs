using System.Text;

namespace Wortschatz.Core;

/// <summary><c>{ result, matchedCard }</c> of <c>gradeWithSynonyms</c>.</summary>
public sealed record SynonymGradeResult(GradeResult Result, Card? MatchedCard = null) : IJsonEncodable
{
    /// <summary>Accepted as another word with the same meaning (synonym card or extended synonym).</summary>
    public bool IsSynonym => MatchedCard is not null || Result.Notes.Contains(GradeNote.ExtendedSynonym);

    public JSONValue ToJson() => JSONValue.Obj(("result", Result.ToJson()), ("matchedCard", MatchedCard.ToJsonOrNull()));
}

/// <summary>
/// Port of Synonyms.swift (src/core/synonyms.js): synonym-aware grading. Cards whose prompts share
/// a meaning look the same to the learner, so an answer that is correct for such a sibling card is
/// accepted with the note Synonym; ExpectedDisplay stays the asked card's answer.
/// </summary>
public static class Synonyms
{
    /// <summary>The side shown as the prompt: ask == Term → the definition.</summary>
    public static string PromptSide(Card card, AskSide ask) => ask == AskSide.Term ? card.Definition : card.Term;

    /// <summary>The side the learner types: ask == Term → the term.</summary>
    public static string AnswerSide(Card card, AskSide ask) => ask == AskSide.Term ? card.Term : card.Definition;

    /// <summary>Other cards with a non-empty answer whose prompt shares an alternative with this card's.</summary>
    public static List<Card> FindSynonymCards(IReadOnlyList<Card> cards, Card card, AskSide ask)
    {
        var keys = PromptKeys(PromptSide(card, ask));
        if (keys.Count == 0) return [];
        return cards.Where(other =>
            !IsSameCard(other, card) && !IsBlank(AnswerSide(other, ask)) && PromptKeys(PromptSide(other, ask)).Overlaps(keys)).ToList();
    }

    /// <summary>
    /// Grades against the asked card, then its synonym cards (best = exact, then fewest notes), then
    /// <paramref name="extraAnswers"/> (words with the same meaning that are not in the set).
    /// </summary>
    public static SynonymGradeResult GradeWithSynonyms(string given, Card card, IReadOnlyList<Card> cards, AskSide ask, Tolerance tolerance,
        Lang? answerLang, IReadOnlyList<string>? extraAnswers = null)
    {
        var result = Grading.Grade(given, AnswerSide(card, ask), tolerance, answerLang);
        if (result.Correct) return new SynonymGradeResult(result);
        (GradeResult R, Card Card)? best = null;
        foreach (var other in FindSynonymCards(cards, card, ask))
        {
            var r = Grading.Grade(given, AnswerSide(other, ask), tolerance, answerLang);
            if (r.Correct && (best is null || Quality(r) < Quality(best.Value.R))) best = (r, other);
        }
        if (best is null) return GradeWithExtraAnswers(given, result, card, cards, ask, tolerance, answerLang, extraAnswers ?? []);
        return new SynonymGradeResult(
            new GradeResult(true, false, [GradeNote.Synonym, .. best.Value.R.Notes.Where(n => !SiblingOnlyNotes.Contains(n))], null, result.ExpectedDisplay),
            best.Value.Card);
    }

    static SynonymGradeResult GradeWithExtraAnswers(string given, GradeResult result, Card card, IReadOnlyList<Card> cards, AskSide ask,
        Tolerance tolerance, Lang? answerLang, IReadOnlyList<string> extraAnswers)
    {
        if (extraAnswers.Count == 0
            || LooseAnswerKeys(PromptSide(card, ask), null).Contains(ExtendedSynonyms.LooseKey(given, null))
            || IsAnswerOfOtherCard(given, card, cards, ask, answerLang))
            return new SynonymGradeResult(result);
        GradeResult? best = null;
        foreach (var extra in extraAnswers)
        {
            var r = Grading.Grade(given, extra, tolerance, answerLang);
            if (r.Correct && (best is null || Quality(r) < Quality(best))) best = r;
        }
        if (best is null) return new SynonymGradeResult(result);
        return new SynonymGradeResult(new GradeResult(true, false,
            [GradeNote.ExtendedSynonym, .. best.Notes.Where(n => !SiblingOnlyNotes.Contains(n))], null, result.ExpectedDisplay));
    }

    /// <summary>Whether <paramref name="given"/> is the answer of another (non-synonym) card: two cards mixed up.</summary>
    public static bool IsAnswerOfOtherCard(string given, Card card, IReadOnlyList<Card> cards, AskSide ask, Lang? lang)
    {
        var key = ExtendedSynonyms.LooseKey(given, lang);
        if (key.Length == 0) return false;
        var keys = PromptKeys(PromptSide(card, ask));
        return cards.Any(other =>
        {
            if (IsSameCard(other, card)) return false;
            if (keys.Count > 0 && PromptKeys(PromptSide(other, ask)).Overlaps(keys)) return false;
            return LooseAnswerKeys(AnswerSide(other, ask), lang).Contains(key);
        });
    }

    static readonly HashSet<GradeNote> SiblingOnlyNotes = [GradeNote.Partial, GradeNote.Order];

    static int Quality(GradeResult r) => r.Exact ? 0 : 1 + r.Notes.Count;

    static bool IsSameCard(Card a, Card b) => a.Id == b.Id;

    /// <summary>Comparison key: case, ß/ss, ligatures, hyphens, punctuation and brackets do not matter.</summary>
    static string KeyOf(string text)
    {
        var folded = JSCompat.Lower(TextNormalizer.FoldScripts(TextNormalizer.NormalizeBasic(text)));
        folded = folded.Replace("ß", "ss").Replace("œ", "oe").Replace("æ", "ae").Replace('-', ' ');
        folded = JsRegex.ReplaceAll(folded, "[.,!?;:\"«»‹›¿¡…~*„“”‚()[\\]{}「」『』《》〈〉]", "");
        return JSCompat.Trim(JsRegex.ReplaceAll(folded, @"\s+", " "));
    }

    static readonly TextMemo<HashSet<string>> PromptKeySets = new();
    static readonly TextMemo<bool> BlankTexts = new();
    static readonly TextMemo<HashSet<string>> LooseKeySets = new();

    static HashSet<string> LooseAnswerKeys(string text, Lang? lang) =>
        LooseKeySets.Value($"{(lang is { } l ? l.Raw() : "")}\u0001{text}", _ => ExtendedSynonyms.AlternativeKeys(text, lang));

    /// <summary>The whole prompt and each of its alternatives ("lieb, nett" → lieb nett | lieb | nett).</summary>
    static HashSet<string> PromptKeys(string text) => PromptKeySets.Value(text, t =>
    {
        var keys = new HashSet<string>(StringComparer.Ordinal) { KeyOf(t) };
        foreach (var alt in Grading.SplitAlternatives(t)) keys.Add(KeyOf(alt));
        keys.Remove("");
        return keys;
    });

    static bool IsBlank(string text) => BlankTexts.Value(text, t => TextNormalizer.NormalizeBasic(t).Length == 0);
}
