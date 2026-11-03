namespace Wortschatz.Core;

/// <summary>Display data of a language (<c>LANGS</c> entry of src/lib/labels.js).</summary>
public sealed record LangInfo(string Name, string Short, string Bcp47);

/// <summary>Port of Labels.swift (src/lib/labels.js): shared German UI labels (Swiss spelling, "ss").</summary>
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

    public static readonly IReadOnlyDictionary<CardStatus, string> STATUS = new Dictionary<CardStatus, string>
    {
        [CardStatus.New] = "Neu",
        [CardStatus.Learning] = "Am Lernen",
        [CardStatus.Mastered] = "Gemeistert",
    };

    public static readonly IReadOnlyDictionary<GradeNote, string> NOTE_LABELS = new Dictionary<GradeNote, string>
    {
        [GradeNote.Article] = "Artikel fehlte",
        [GradeNote.Pronoun] = "Pronomen fehlte",
        [GradeNote.Abbreviation] = "Abkürzung",
        [GradeNote.Partial] = "Teilantwort",
        [GradeNote.Parentheses] = "Klammerinhalt weggelassen",
        [GradeNote.Pinyin] = "Nur Pinyin",
        [GradeNote.LetterCase] = "Gross-/Kleinschreibung",
        [GradeNote.Accents] = "Akzente",
        [GradeNote.Tones] = "Töne",
        [GradeNote.Variant] = "Schreibvariante",
        [GradeNote.Typo] = "Tippfehler",
        [GradeNote.Order] = "Reihenfolge",
        [GradeNote.Synonym] = "Anderes Wort mit gleicher Bedeutung",
        [GradeNote.ExtendedSynonym] = "Synonym – nicht im Set",
    };

    public static readonly IReadOnlyDictionary<GradeHint, string> HINT_LABELS = new Dictionary<GradeHint, string>
    {
        [GradeHint.WrongArticle] = "Falscher Artikel",
        [GradeHint.MissingArticle] = "Artikel fehlt",
        [GradeHint.AccentsOnly] = "Nur die Akzente stimmen nicht",
        [GradeHint.TonesOnly] = "Nur die Töne fehlen",
        [GradeHint.CaseOnly] = "Nur Gross-/Kleinschreibung falsch",
        [GradeHint.Typo] = "Fast – ein kleiner Tippfehler",
        [GradeHint.Almost] = "Knapp daneben",
    };

    /// <summary><c>Plural(3, "Begriff", "Begriffe")</c> → "3 Begriffe".</summary>
    public static string Plural(int n, string one, string other) => $"{n} {(n == 1 ? one : other)}";

    public static LangInfo Info(Lang? code) => LANGS[code ?? Lang.Other];
    public static LangInfo Info(string? code) => Info(LangExtensions.ParseLang(code));
    public static string LangName(Lang? code) => Info(code).Name;
    public static string LangShort(Lang? code) => Info(code).Short;

    /// <summary>"FR → DE"</summary>
    public static string LangPair(Lang? termLang, Lang? defLang) => $"{LangShort(termLang)} → {LangShort(defLang)}";
}
