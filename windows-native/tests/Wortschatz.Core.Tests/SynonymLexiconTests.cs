using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>"Weitere Synonyme erkennen" on Windows/Android: the built-in thesauri (GitHub issue #4).</summary>
public class SynonymLexiconTests
{
    static SynonymLexicon Synthetic(Lang lang, params string[] lines)
    {
        var rows = lines.Select(l =>
        {
            var head = l.Split('\t')[0];
            return (Key: SynonymLexicon.KeyOf(head[..head.LastIndexOf('#')], lang), Line: l);
        }).OrderBy(r => Encoding.UTF8.GetBytes(r.Key), Comparer<byte[]>.Create((a, b) => a.AsSpan().SequenceCompareTo(b))).ToList();
        var text = $"WSSYN2 {lang.Raw()} {rows.Count}\n" + string.Concat(rows.Select(r => $"{r.Key}\t{r.Line}\n"));
        return SynonymLexicon.Parse(lang, Encoding.UTF8.GetBytes(text));
    }

    // MARK: Format and keys

    [Fact]
    public void FindsAWordUnderItsLooseKey()
    {
        var lex = Synthetic(Lang.De, "Fahrrad#n/n\tVelo|n\tRad|n", "beginnen#x/x\tanfangen");
        var entry = Assert.Single(lex.Lookup("das Fahrrad"));
        Assert.Equal("Fahrrad", entry.Head);
        Assert.Equal('n', entry.Class);
        Assert.Equal([new LexiconWord("Velo", "n"), new LexiconWord("Rad", "n")], entry.Synonyms);
        Assert.Equal("anfangen", Assert.Single(Assert.Single(lex.Lookup("beginnen")).Synonyms).Text);
        Assert.Empty(lex.Lookup("Auto"));
    }

    [Fact]
    public void WordsWithTheSameKeyAreAllFound()
    {
        var lex = Synthetic(Lang.De, "Steuern#n/n\tAbgaben|p", "steuern#x/x\tnavigieren", "Zug#n/n\tBahn|f");
        Assert.Equal(["Steuern", "steuern"], lex.Lookup("steuern").Select(e => e.Head).Order(StringComparer.Ordinal));
    }

    [Fact]
    public void PlaceholdersAreNotPartOfTheKey()
    {
        Assert.Equal("verbieten", SynonymLexicon.KeyOf("etw. verbieten", Lang.De));
        Assert.Equal("sign", SynonymLexicon.KeyOf("to sign sth", Lang.En));
        Assert.Equal("affect", SynonymLexicon.KeyOf("to affect sb/sth", Lang.En));
        Assert.Equal("freuen", SynonymLexicon.KeyOf("sich freuen", Lang.De));
        // A placeholder alone stays: «etwas» is a word too.
        Assert.Equal("etwas", SynonymLexicon.KeyOf("etwas", Lang.De));
    }

    [Fact]
    public void BrokenDataIsRefused() =>
        Assert.Throws<InvalidDataException>(() => SynonymLexicon.Parse(Lang.De, Encoding.UTF8.GetBytes("WSSYN2 de 3\nfahrrad\tFahrrad#n/n\tVelo\n")));

    // MARK: Extra answers

    [Fact]
    public void ANounCardWithAnArticleGetsTheSynonymsWithTheirOwnArticle()
    {
        var lex = Synthetic(Lang.De, "Fahrrad#n/n\tVelo|n\tDrahtwagen\tTretmühle|f");
        var extra = ExtendedSynonyms.ThesaurusAnswers("das Fahrrad", lex);
        Assert.Contains("das Velo", extra);
        Assert.Contains("ein Velo", extra);
        Assert.Contains("die Tretmühle", extra);
        Assert.DoesNotContain("der Velo", extra);
        // Without a known gender the synonym is left out rather than accepted with any article.
        Assert.DoesNotContain(extra, x => x.Contains("Drahtwagen"));
        // Without an article on the card: the bare words.
        Assert.Equal(["Velo", "Drahtwagen", "Tretmühle"], ExtendedSynonyms.ThesaurusAnswers("Fahrrad", lex));
    }

    [Fact]
    public void GermanNounsAndOtherWordsStayApart()
    {
        var lex = Synthetic(Lang.De, "Steuern#n/n\tAbgaben|p", "steuern#x/x\tnavigieren");
        Assert.Equal(["navigieren"], ExtendedSynonyms.ThesaurusAnswers("steuern", lex));
        Assert.Equal(["Abgaben"], ExtendedSynonyms.ThesaurusAnswers("Steuern", lex));
    }

    [Fact]
    public void EnglishVerbsAreTheOnesWithTo()
    {
        var lex = Synthetic(Lang.En, "spy#n/nv\tundercover agent", "spy#v/nv\tespy");
        Assert.Equal(["espy"], ExtendedSynonyms.ThesaurusAnswers("to spy", lex));
        Assert.Equal(["undercover agent"], ExtendedSynonyms.ThesaurusAnswers("spy", lex));
    }

    [Fact]
    public void WithoutAnArticleAWordThatIsAlsoAnAdjectiveGetsNoNounSynonyms()
    {
        var lex = Synthetic(Lang.Fr, "bête#n/nx\tanimal|m", "vélo#n/n\tbicyclette|f");
        Assert.Empty(ExtendedSynonyms.ThesaurusAnswers("bête", lex));
        Assert.Equal(["la bicyclette", "une bicyclette"], ExtendedSynonyms.ThesaurusAnswers("le vélo", lex));
        Assert.Equal(["l'animal", "le animal", "un animal"], ExtendedSynonyms.ThesaurusAnswers("la bête", lex));
        // Only a noun: its synonyms also without an article.
        Assert.Equal(["bicyclette"], ExtendedSynonyms.ThesaurusAnswers("vélo", lex));
    }

    [Fact]
    public void PlaceholdersOfTheCardComeAlong()
    {
        var lex = Synthetic(Lang.De, "verbieten#x/x\tuntersagen");
        Assert.Equal(["untersagen", "etw. untersagen"], ExtendedSynonyms.ThesaurusAnswers("etw. verbieten", lex));
        var en = Synthetic(Lang.En, "sign#v/nv\tsubscribe");
        Assert.Equal(["subscribe", "subscribe sth"], ExtendedSynonyms.ThesaurusAnswers("to sign sth", en));
    }

    [Fact]
    public void EachAlternativeIsLookedUpAndTheCardsOwnWordsAreNoExtra()
    {
        var lex = Synthetic(Lang.De, "lieb#x/x\tnett\tfreundlich", "nett#x/x\tlieb\tsympathisch");
        Assert.Equal(["freundlich", "sympathisch"], ExtendedSynonyms.ThesaurusAnswers("lieb, nett", lex));
    }

    // MARK: The built-in data

    [Fact]
    public void FiveLanguagesComeWithTheApp() =>
        Assert.Equal([Lang.Fr, Lang.De, Lang.En, Lang.Es, Lang.It], SynonymLexicon.Languages.OrderBy(l => Array.IndexOf(new[] { Lang.Fr, Lang.De, Lang.En, Lang.Es, Lang.It }, l)));

    [Theory]
    [InlineData("de")]
    [InlineData("en")]
    [InlineData("fr")]
    [InlineData("es")]
    [InlineData("it")]
    public void EveryStoredKeyIsStillTheKeyTheAppComputes(string code)
    {
        // The packing tool stores KeyOf(head); if LooseKey changes, the data must be packed again.
        var lang = EnumRaw.Parse<Lang>(code)!.Value;
        var lex = SynonymLexicon.For(lang)!;
        var wrong = lex.Entries().Where(e => SynonymLexicon.KeyOf(e.Entry.Head, lang) != e.Key).Take(5).Select(e => e.Entry.Head).ToList();
        Assert.Empty(wrong);
        Assert.True(lex.Count > 20_000);
    }

    static SynonymGradeResult Grade(string given, string prompt, string expected, Lang promptLang, Lang answerLang)
    {
        var card = new Card("c1", prompt, expected);
        var extra = ExtendedSynonyms.ThesaurusAnswers(new SynonymQuery(prompt, expected, promptLang, answerLang));
        return Synonyms.GradeWithSynonyms(given, card, [card], AskSide.Definition, Tolerance.Default, answerLang, extra);
    }

    [Theory]
    // German
    [InlineData("bike", "das Fahrrad", "das Velo", true)]
    [InlineData("bike", "das Fahrrad", "der Velo", false)]
    [InlineData("to forbid", "etw. verbieten", "untersagen", true)]
    [InlineData("to sign", "unterschreiben", "unterzeichnen", true)]
    [InlineData("immigration", "Einwanderung", "Zuwanderung", true)]
    [InlineData("ceasefire", "Waffenstillstand", "Waffenruhe", true)]
    [InlineData("to begin", "beginnen", "anfangen", true)]
    [InlineData("kind", "nett", "freundlich", true)]
    [InlineData("to steer", "steuern", "Abgaben", false)]
    [InlineData("economy", "Wirtschaft", "Gasthaus", false)]
    [InlineData("economic", "wirtschaftlich", "sparsam", false)]
    [InlineData("attempt", "Versuch", "Experiment", false)]
    [InlineData("deliberately", "absichtlich", "Absicht", false)]
    [InlineData("bike", "Fahrrad", "Hirsch", false)]
    public void GermanAnswers(string prompt, string expected, string given, bool correct)
    {
        var r = Grade(given, prompt, expected, Lang.En, Lang.De);
        Assert.Equal(correct, r.Result.Correct);
        if (correct) Assert.Contains(GradeNote.ExtendedSynonym, r.Result.Notes);
    }

    [Theory]
    [InlineData("einsperren", "to imprison sb", "to jail", true)]
    [InlineData("Waffenstillstand", "truce", "armistice", true)]
    [InlineData("Küste", "coast", "seacoast", true)]
    [InlineData("Wache", "guard", "crossguard", false)]
    [InlineData("Gerechtigkeit", "justice", "judge", false)]
    [InlineData("Spion", "spy", "espy", false)]
    public void EnglishAnswers(string prompt, string expected, string given, bool correct) =>
        Assert.Equal(correct, Grade(given, prompt, expected, Lang.De, Lang.En).Result.Correct);

    [Theory]
    [InlineData(Lang.Fr, "le vélo", "la bicyclette", true)]
    [InlineData(Lang.Fr, "le vélo", "le bicyclette", false)]
    [InlineData(Lang.Fr, "la peur", "la crainte", true)]
    [InlineData(Lang.Fr, "bête", "animal", false)]
    [InlineData(Lang.Es, "el coche", "el automóvil", true)]
    [InlineData(Lang.Es, "el coche", "el cerdo", false)]
    [InlineData(Lang.Es, "empezar", "comenzar", true)]
    [InlineData(Lang.It, "veloce", "rapido", true)]
    [InlineData(Lang.It, "la casa", "la ditta", false)]
    public void OtherLanguages(Lang lang, string expected, string given, bool correct) =>
        Assert.Equal(correct, Grade(given, "x", expected, Lang.De, lang).Result.Correct);

    [Fact]
    public void ThePromptAndOtherCardsAnswersStillDoNotCount()
    {
        var bike = new Card("c1", "bike", "das Fahrrad");
        var other = new Card("c2", "two-wheeler", "das Zweirad");
        var extra = ExtendedSynonyms.ThesaurusAnswers(new SynonymQuery("bike", "das Fahrrad", Lang.En, Lang.De));
        Assert.Contains("das Zweirad", extra);
        // «Zweirad» is another card's answer: the two were mixed up.
        Assert.False(Synonyms.GradeWithSynonyms("das Zweirad", bike, [bike, other], AskSide.Definition, Tolerance.Default, Lang.De, extra).Result.Correct);
    }
}
