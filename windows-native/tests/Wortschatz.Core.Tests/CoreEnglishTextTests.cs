using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// The core's texts in English: sentences that used to be glued from pieces are whole texts now, so each finds its
/// English (the German stays word for word, see the other tests).
/// </summary>
[Collection("CoreText")]
public class CoreEnglishTextTests
{
    [Fact]
    public void WholeSentencesAreEnglish()
    {
        try
        {
            CoreText.Table = TextTable.English;
            Assert.Equal("All 3 starred terms mastered in 2 rounds – awesome!", LearnFlow.FinishSubtitle(3, 2, 0, StudySubset.Starred));
            Assert.Equal("5 terms mastered in 2 rounds, 2 were already known – awesome!", LearnFlow.FinishSubtitle(7, 2, 2));
            Assert.Equal("42%", WriteFlow.PercentText(0.42));
            Assert.Equal("2 lines without vocabulary were skipped.", VocabParser.SkippedLinesWarning(2));
            Assert.Equal("Possible typo: “separee” (séparée?)", SetEditorCopy.TypoTooltip([new SpellingIssue("separee", 0, 7, ["séparée"])]));
            Assert.Equal("Answer 2: la voiture. Enter selects it.", CoreText.L($"Antwort {2}: {"la voiture"}. Eingabetaste wählt sie."));
            Assert.Equal("The data couldn’t be saved because this computer is out of storage space.", StoreMessages.DiskFull);
            Assert.Equal("10/12/2026", TimeUtil.FormatDate(Date(2026, 10, 12), TimeZoneInfo.Utc));
        }
        finally
        {
            CoreText.Table = null;
        }
        Assert.Equal("Alle 3 markierten Begriffe in 2 Runden gemeistert – stark!", LearnFlow.FinishSubtitle(3, 2, 0, StudySubset.Starred));
        Assert.Equal("12.10.2026", TimeUtil.FormatDate(Date(2026, 10, 12), TimeZoneInfo.Utc));
    }

    static double Date(int year, int month, int day) => (new DateTime(year, month, day, 12, 0, 0, DateTimeKind.Utc) - DateTime.UnixEpoch).TotalMilliseconds;
}
