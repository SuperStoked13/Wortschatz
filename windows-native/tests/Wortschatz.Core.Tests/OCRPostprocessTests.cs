using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of OCRPostprocessTests.swift (the fixGermanUmlauts cases of tests/layout.test.js, plus edge
// cases of the Swift port).
public class OCRPostprocessTests
{
    [Fact]
    public void GermanCellsOnly() => Assert.Equal(
        ["le chat\tdie Katze", "beau\tschön", "le rôle\tdie Rolle", "vert\tgrün", "fatigué\tmüde", "à côté de\tneben", "la porte\tdie Tür"],
        OCRPostprocess.FixGermanUmlauts(["le chat\tdie Katze", "beau\tschôn", "le rôle\tdie Rolle", "vert\tgrûn", "fatigué\tmûde", "à côté de\tneben", "la porte\tdie Tûr"]));

    [Fact]
    public void SingleLines() => Assert.Equal(
        ["tôt", "früh", "le rôle", "die Rolle", "beau", "schön", "la porte", "die Tür", "brûler", "brennen"],
        OCRPostprocess.FixGermanUmlauts(["tôt", "früh", "le rôle", "die Rolle", "beau", "schôn", "la porte", "die Tûr", "brûler", "brennen"]));

    [Fact]
    public void UpperCaseAndFrench()
    {
        Assert.Equal(["LA PORTE\tDIE TÜR", "le chat\tdie Katze", "le chien\tder Hund"],
            OCRPostprocess.FixGermanUmlauts(["LA PORTE\tDIE TÛR", "le chat\tdie Katze", "le chien\tder Hund"]));
        List<string> french = ["le château\tdas Schloss", "le gâteau\tder Kuchen", "âgé\talt"];
        Assert.Equal(french, OCRPostprocess.FixGermanUmlauts(french));
    }

    [Fact]
    public void Unchanged()
    {
        Assert.Empty(OCRPostprocess.FixGermanUmlauts([]));
        Assert.Equal(["", "\t", "die Katze"], OCRPostprocess.FixGermanUmlauts(["", "\t", "die Katze"]));
    }

    [Fact]
    public void Decomposed()
    {
        List<string> lines = ["schôn\tbeau", "die Tûr\tla porte"];
        Assert.Equal(lines, OCRPostprocess.FixGermanUmlauts(lines));
    }

    [Fact]
    public void EmptyCells() => Assert.Equal(
        ["le chat\t\tdie Katze", "beau\t\tschön", "la porte\t\tdie Tür"],
        OCRPostprocess.FixGermanUmlauts(["le chat\t\tdie Katze", "beau\t\tschôn", "la porte\t\tdie Tûr"]));
}
