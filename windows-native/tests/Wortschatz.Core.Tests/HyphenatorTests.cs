using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Hyphenator (no Mac counterpart): syllables of words too wide for their line on the phone.
public class HyphenatorTests
{
    static string Show(Lang lang, string word)
    {
        var h = Hyphenator.For(lang);
        Assert.NotNull(h);
        var points = h!.Points(word);
        var parts = new List<string>();
        int start = 0;
        foreach (var p in points)
        {
            parts.Add(word[start..p]);
            start = p;
        }
        parts.Add(word[start..]);
        return string.Join("-", parts);
    }

    [Theory]
    [InlineData(Lang.De, "Geschwindigkeitsbegrenzung", "Ge-schwin-dig-keits-be-gren-zung")]
    [InlineData(Lang.De, "Donaudampfschifffahrt", "Do-nau-dampf-schiff-fahrt")]
    [InlineData(Lang.De, "Geschwindigkeitsbegrenzung(en)", "Ge-schwin-dig-keits-be-gren-zung(en)")]
    [InlineData(Lang.Fr, "anticonstitutionnellement", "an-ti-cons-ti-tu-tion-nel-le-ment")]
    [InlineData(Lang.En, "hyphenation", "hy-phen-ation")]
    [InlineData(Lang.En, "project", "project")]
    [InlineData(Lang.Es, "desafortunadamente", "des-afor-tu-na-da-mente")] // the patterns split after the prefix; 3 letters at the end
    [InlineData(Lang.It, "precipitevolissimevolmente", "pre-ci-pi-te-vo-lis-si-me-vol-mente")]
    public void SplitsIntoSyllables(Lang lang, string word, string expected) => Assert.Equal(expected, Show(lang, word));

    [Fact]
    public void ShortWordsAndBracketsStayWhole()
    {
        Assert.Equal("Haus", Show(Lang.De, "Haus"));
        Assert.Equal("(sich)", Show(Lang.De, "(sich)"));
        Assert.Empty(Hyphenator.For(Lang.De)!.Points("123456789"));
    }

    [Fact]
    public void NoPatternsForArabicChineseOther()
    {
        Assert.Null(Hyphenator.For(Lang.Ar));
        Assert.Null(Hyphenator.For(Lang.Zh));
        Assert.Null(Hyphenator.For(Lang.Other));
        Assert.Null(Hyphenator.For(null));
    }
}
