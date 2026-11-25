using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>When the copy step ("Richtige Antwort abtippen") moves on by itself (CopyStep.IsTypedOut). Port of CopyStepTests.swift.</summary>
public class CopyStepTests
{
    static bool TypedOut(string value, string expected, Lang lang = Lang.Fr) =>
        CopyStep.IsTypedOut(value, expected, Tolerance.Default, lang);

    [Fact]
    public void ExactlyAsShownOrApartFromCaseAndSpacing()
    {
        Assert.True(TypedOut("le chemin", "le chemin"));
        Assert.True(TypedOut("Le  Chemin ", "le chemin"));
        Assert.True(TypedOut("le/la collègue", "le/la collègue"));
        Assert.True(TypedOut("le cerveau, les cerveaux", "le cerveau, les cerveaux"));
    }

    [Fact]
    public void AcceptedLikeAnAnswerToTheQuestion()
    {
        Assert.True(TypedOut("le collègue", "le/la collègue"));
        Assert.True(TypedOut("la collègue", "le/la collègue"));
        Assert.True(TypedOut("chemin", "le chemin"));
        Assert.True(TypedOut("les cerveaux", "le cerveau, les cerveaux"));
    }

    [Fact]
    public void NotWhileItIsOnlyTheStartOfTheAnswerAsShown()
    {
        Assert.False(TypedOut("le cerveau", "le cerveau, les cerveaux"));
        Assert.False(TypedOut("le cerveau,", "le cerveau, les cerveaux"));
        Assert.False(TypedOut("Aussenminister", "Aussenminister(in)", Lang.De));
        Assert.False(TypedOut("le coeur", "le cœur, les cœurs"));
    }

    [Fact]
    public void NeverWhenWrong()
    {
        Assert.False(TypedOut("", "le chemin"));
        Assert.False(TypedOut("le che", "le chemin"));
        Assert.False(TypedOut("la route", "le chemin"));
    }
}
