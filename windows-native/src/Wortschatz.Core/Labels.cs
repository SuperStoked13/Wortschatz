using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// Display data of a language (<c>LANGS</c> entry of src/lib/labels.js). <c>Name</c> is the German raw data; for display
/// use <see cref="Labels.LangName"/>, which translates it.
/// </summary>
public sealed record LangInfo(string Name, string Short, string Bcp47);

/// <summary>
/// Port of Labels.swift (src/lib/labels.js): shared UI labels, German (Swiss spelling, "ss") through <see cref="CoreText.L(string)"/>.
/// The label tables are computed, so they follow the app's language.
/// </summary>
public static class Labels
{
    public static readonly IReadOnlyDictionary<Lang, LangInfo> LANGS = new Dictionary<Lang, LangInfo>
    {
        [Lang.Fr] = new("Französisch", "FR", "fr-FR"),
        [Lang.En] = new("Englisch", "EN", "en-GB"),
        [Lang.Es] = new("Spanisch", "ES", "es-ES"),
        [Lang.It] = new("Italienisch", "IT", "it-IT"),
        [Lang.Ar] = new("Arabisch", "AR", "ar"),
        [Lang.Zh] = new("Chinesisch", "ZH", "zh-CN"),
        [Lang.De] = new("Deutsch", "DE", "de-CH"),
        [Lang.Other] = new("Andere", "—", ""),
    };

    /// <summary>Display order for language pickers.</summary>
    public static readonly Lang[] LANG_ORDER = [Lang.Fr, Lang.En, Lang.Es, Lang.It, Lang.Ar, Lang.Zh, Lang.De, Lang.Other];

    public static IReadOnlyDictionary<CardStatus, string> STATUS => new Dictionary<CardStatus, string>
    {
        [CardStatus.New] = L("Neu"),
        [CardStatus.Learning] = L("Am Lernen"),
        [CardStatus.Mastered] = L("Gemeistert"),
    };

    public static IReadOnlyDictionary<GradeNote, string> NOTE_LABELS => new Dictionary<GradeNote, string>
    {
        [GradeNote.Article] = L("Artikel fehlte"),
        [GradeNote.Pronoun] = L("Pronomen fehlte"),
        [GradeNote.Abbreviation] = L("Abkürzung"),
        [GradeNote.Partial] = L("Teilantwort"),
        [GradeNote.Parentheses] = L("Klammerinhalt weggelassen"),
        [GradeNote.Pinyin] = L("Nur Pinyin"),
        [GradeNote.LetterCase] = L("Gross-/Kleinschreibung"),
        [GradeNote.Accents] = L("Akzente"),
        [GradeNote.Tones] = L("Töne"),
        [GradeNote.Variant] = L("Schreibvariante"),
        [GradeNote.Typo] = L("Tippfehler"),
        [GradeNote.Order] = L("Reihenfolge"),
        [GradeNote.Synonym] = L("Anderes Wort mit gleicher Bedeutung"),
        [GradeNote.ExtendedSynonym] = L("Synonym – nicht im Set"),
    };

    public static IReadOnlyDictionary<GradeHint, string> HINT_LABELS => new Dictionary<GradeHint, string>
    {
        [GradeHint.WrongArticle] = L("Falscher Artikel"),
        [GradeHint.MissingArticle] = L("Artikel fehlt"),
        [GradeHint.AccentsOnly] = L("Nur die Akzente stimmen nicht"),
        [GradeHint.TonesOnly] = L("Nur die Töne fehlen"),
        [GradeHint.CaseOnly] = L("Nur Gross-/Kleinschreibung falsch"),
        [GradeHint.Typo] = L("Fast – ein kleiner Tippfehler"),
        [GradeHint.Almost] = L("Knapp daneben"),
    };

    /// <summary>
    /// <c>Plural(3, "Begriff", "Begriffe")</c> → "3 Begriffe". Translated as «%@ Begriff» / «%@ Begriffe» (Mac: the same
    /// keys, so a counter's word can differ from the same word as a heading); callers pass literals.
    /// </summary>
    public static string Plural(int n, string one, string other) => L("%@ " + (n == 1 ? one : other), n.ToString());

    public static LangInfo Info(Lang? code) => LANGS[code ?? Lang.Other];
    public static LangInfo Info(string? code) => Info(LangExtensions.ParseLang(code));
    /// <summary>The language's name in the app's language (display only: nothing parses it back).</summary>
    public static string LangName(Lang? code) => (code ?? Lang.Other) switch
    {
        Lang.Fr => L("Französisch"),
        Lang.En => L("Englisch"),
        Lang.Es => L("Spanisch"),
        Lang.It => L("Italienisch"),
        Lang.Ar => L("Arabisch"),
        Lang.Zh => L("Chinesisch"),
        Lang.De => L("Deutsch"),
        _ => L("Andere"),
    };
    public static string LangShort(Lang? code) => Info(code).Short;

    /// <summary>"FR → DE"</summary>
    public static string LangPair(Lang? termLang, Lang? defLang) => $"{LangShort(termLang)} → {LangShort(defLang)}";
}
