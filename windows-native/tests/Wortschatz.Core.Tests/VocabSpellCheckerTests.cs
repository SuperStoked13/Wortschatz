using System.Text.RegularExpressions;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// Port of VocabSpellCheckerTests.swift for the platform-independent part: a small fake dictionary stands in for the
/// system spell checker (Windows: ISpellCheckerFactory, tested on Windows itself).
/// </summary>
public sealed partial class VocabSpellCheckerTests
{
    sealed partial class FakeEngine : ISpellEngine
    {
        public readonly HashSet<string> Known = new(StringComparer.Ordinal)
        {
            "séparé", "séparée", "die", "Hausnummer", "Straße", "heißen", "groß", "der", "Fußball", "schließen", "das", "Schloss",
            "Schlussstrich", "an", "denken", "geben", "ein", "Buch", "penser", "à", "to", "think", "of", "le", "la", "juillet", "étage",
            "Haus", "eisen", "weisen",
        };
        public readonly Dictionary<string, string[]> Guesses = new(StringComparer.Ordinal)
        {
            ["separee"] = ["sépare", "séparée"],
            ["Hausnumer"] = ["Hausnummer", "Hausnummern"],
            ["heisen"] = ["eisen", "weisen", "heißen"],
            ["Strase"] = ["Straße", "Strasse", "Stase"],
        };
        public string? Language(IReadOnlyList<string> candidates) => candidates.FirstOrDefault(c => c.StartsWith("fr") || c.StartsWith("de") || c.StartsWith("en"));

        public IReadOnlyList<(int Start, int Length)> Check(string text, string language) =>
            Word().Matches(text).Where(m => !Known.Contains(m.Value)).Select(m => (m.Index, m.Length)).ToList();

        public IReadOnlyList<string> Suggest(string word, string language) => Guesses.TryGetValue(word, out var g) ? g : [];

        [GeneratedRegex(@"[\p{L}\p{M}\d]+")]
        private static partial Regex Word();
    }

    static List<string> Words(IReadOnlyList<SpellingIssue> issues) => issues.Select(i => i.Word).ToList();

    [Fact]
    public void TyposAreFoundWithTheRightSuggestionFirst()
    {
        var checker = new VocabSpellChecker(new FakeEngine());
        var separee = checker.Issues("séparé, separee", Lang.Fr);
        Assert.Equal(["separee"], Words(separee));
        Assert.Equal("séparée", separee[0].Suggestions[0]);
        Assert.Equal((8, 7), (separee[0].Start, separee[0].Length));
        Assert.Equal("Hausnummer", checker.Issues("die Hausnumer", Lang.De)[0].Suggestions[0]);
        Assert.Equal("heissen", checker.Issues("heisen", Lang.De)[0].Suggestions[0]); // Swiss spelling, closest first
    }

    [Fact]
    public void SwissSpellingSsIsRightAndSuggestionsNeverUseTheSharpS()
    {
        var checker = new VocabSpellChecker(new FakeEngine());
        foreach (var word in new[] { "die Strasse", "heissen", "gross", "der Fussball", "schliessen", "das Schloss", "der Schlussstrich" })
            Assert.True(checker.Issues(word, Lang.De).Count == 0, word);
        var strase = checker.Issues("die Strase", Lang.De);
        Assert.NotEmpty(strase);
        Assert.All(strase, i => Assert.DoesNotContain("ß", string.Concat(i.Suggestions)));
        Assert.Contains("Strasse", strase[0].Suggestions);
        Assert.Equal(strase[0].Suggestions.Count, strase[0].Suggestions.Distinct().Count());
    }

    [Fact]
    public void VocabAbbreviationsAcronymsAndNumbersAreNotTypos()
    {
        var checker = new VocabSpellChecker(new FakeEngine());
        Assert.Empty(checker.Issues("an jdn./etw. denken", Lang.De));
        Assert.Empty(checker.Issues("jdm. etw. geben, z.B. ein Buch", Lang.De));
        Assert.Empty(checker.Issues("penser à qn/qc", Lang.Fr));
        Assert.Empty(checker.Issues("to think of sb/sth", Lang.En));
        Assert.Empty(checker.Issues("le TGV, la SNCF", Lang.Fr));
        Assert.Empty(checker.Issues("le 14 juillet, 3e étage", Lang.Fr));
    }

    [Fact]
    public void IgnoredWordsStayIgnoredPerLanguageAndAreSaved()
    {
        IReadOnlyCollection<string>? saved = null;
        var checker = new VocabSpellChecker(new FakeEngine(), saveIgnored: list => saved = list);
        Assert.NotEmpty(checker.Issues("Kevinou", Lang.Fr));
        checker.Ignore("Kevinou", Lang.Fr);
        Assert.Empty(checker.Issues("Kevinou", Lang.Fr));
        Assert.True(checker.IsIgnored("kevinou", Lang.Fr));
        Assert.False(checker.IsIgnored("Kevinou", Lang.De));
        Assert.Equal(["fr:kevinou"], saved);
        var again = new VocabSpellChecker(new FakeEngine(), saved);
        Assert.Empty(again.Issues("Kevinou", Lang.Fr));
        checker.ResetIgnored();
        Assert.NotEmpty(checker.Issues("Kevinou", Lang.Fr));
    }

    [Fact]
    public void OtherLanguagesEmptyTextAndNoEngineAreSkipped()
    {
        var checker = new VocabSpellChecker(new FakeEngine());
        Assert.Null(checker.Language(Lang.Other));
        Assert.Null(checker.Language(Lang.Zh));
        Assert.Empty(checker.Issues("xqzt", Lang.Other));
        Assert.Empty(checker.Issues("   ", Lang.Fr));
        Assert.Empty(new VocabSpellChecker(null).Issues("xqzt", Lang.Fr));
    }

    [Fact]
    public void AtMostSixIssuesPerField()
    {
        var checker = new VocabSpellChecker(new FakeEngine());
        Assert.Equal(VocabSpellChecker.MaxIssuesPerText, checker.Issues("aaa bbb ccc ddd eee fff ggg hhh", Lang.Fr).Count);
    }

    [Fact]
    public void RankingPrefersTheClosestWordWithTheSameFirstLetterAndCase()
    {
        Assert.Equal(["heissen", "eisen", "weisen"], VocabSpellChecker.Ranked(["eisen", "weisen", "heissen"], "heisen"));
        Assert.Equal("séparée", VocabSpellChecker.Ranked(["sépare", "séparée"], "separee")[0]);
        Assert.Equal("Mason", VocabSpellChecker.Ranked(["Mason", "maçon", "maison"], "mason")[^1]);
        Assert.Equal(1, VocabSpellChecker.EditDistance("ab", "ba"));
        Assert.Equal(3, VocabSpellChecker.EditDistance("", "abc"));
    }
}
