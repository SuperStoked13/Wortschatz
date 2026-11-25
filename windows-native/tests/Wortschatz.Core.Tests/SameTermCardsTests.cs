using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>Two cards for the same word («etw. entführen» / «jmdn. entführen»): the app asks what an answer counts as.</summary>
public class SameTermCardsTests
{
    static readonly Card Hijack = new("h", "to hijack sth", "etw. entführen");
    static readonly Card Kidnap = new("k", "to kidnap sb", "jmdn. entführen");
    static readonly Card Spark = new("s", "to spark sth", "etw. entfachen");
    static readonly Card[] Cards = [Hijack, Kidnap, Spark];

    // The German side is the prompt, the English side the answer.
    static Card? Find(string given, Card card, Card[]? cards = null, Tolerance? tolerance = null) =>
        SameTermCards.AnswerOfOtherCard(given, card, cards ?? Cards, AskSide.Term, tolerance ?? Tolerance.Default, Lang.De, Lang.En);

    [Fact]
    public void TheOtherCardsAnswerForTheSameWordIsFound()
    {
        Assert.Equal(Kidnap, Find("to kidnap sb", Hijack));
        Assert.Equal(Hijack, Find("to hijack sth", Kidnap));
    }

    [Fact]
    public void TheSessionsToleranceDecides()
    {
        Assert.Null(Find("to kidnapp sb", Hijack));
        Assert.Equal(Kidnap, Find("to kidnapp sb", Hijack, tolerance: new Tolerance(Typos: true)));
    }

    [Fact]
    public void AnotherWordOrAnyOtherAnswerIsNotTheSameTerm()
    {
        Assert.Null(Find("to spark sth", Hijack));  // «entfachen» is not «entführen»
        Assert.Null(Find("to steal sth", Hijack));
        Assert.Null(Find("", Hijack));
    }

    [Fact]
    public void BracketsArticlesAndAlternativesDoNotMatter()
    {
        var a = new Card("a", "the weapons", "die Waffen (Pl.)");
        var b = new Card("b", "arms", "Waffen, Rüstung");
        Assert.Equal(b, Find("arms", a, [a, b]));
        Assert.Equal(a, Find("the weapons", b, [a, b]));
    }

    [Fact]
    public void ItWorksTheOtherWayRoundToo()
    {
        // English prompt, German answer.
        var a = new Card("a", "to kidnap sb", "jmdn. entführen");
        var b = new Card("b", "to kidnap sth", "etw. verschleppen");
        Assert.Equal(b, SameTermCards.AnswerOfOtherCard("etw. verschleppen", a, [a, b], AskSide.Definition, Tolerance.Default, Lang.En, Lang.De));
    }

    [Fact]
    public void TheTermKeyLeavesOutPlaceholders()
    {
        // Loose keys: lower case, no accents.
        Assert.Contains("entfuhren", SameTermCards.TermKeys("etw. entführen", Lang.De));
        Assert.Contains("entfuhren", SameTermCards.TermKeys("jmdn. entführen", Lang.De));
        Assert.Contains("kidnap", SameTermCards.TermKeys("to kidnap sb", Lang.En));
    }
}
