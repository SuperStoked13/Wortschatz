using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

public class OlderDownloadsTests
{
    static readonly Version V14 = new(1, 4, 0);

    [Theory]
    [InlineData("Wortschatz-1.3-Windows.exe", 1, 3, 0)]
    [InlineData("wortschatz-1.3-windows.EXE", 1, 3, 0)]
    [InlineData("Wortschatz-1.3.1-Windows.exe", 1, 3, 1)]
    [InlineData("Wortschatz-1.2-Windows (2).exe", 1, 2, 0)]
    [InlineData("Wortschatz-2.10-Windows.exe", 2, 10, 0)]
    public void TheVersionComesFromTheWebsitesFileName(string name, int major, int minor, int build) =>
        Assert.Equal(new Version(major, minor, build), OlderDownloads.VersionOf(name));

    [Theory]
    [InlineData("Wortschatz.exe")]
    [InlineData("Wortschatz Kopie.exe")]
    [InlineData("Wortschatz (nativ).exe")]
    [InlineData("Wortschatz-1.3-Windows.zip")]
    [InlineData("Wortschatz-1.3-macOS.dmg")]
    [InlineData("Wortschatz-1.3-Windows-alt.exe")]
    [InlineData("Wortschatz-1.3-Windows (kopie).exe")]
    [InlineData("Mein Wortschatz-1.3-Windows.exe")]
    [InlineData("Wortschatz-1-Windows.exe")]
    [InlineData("Wortschatz-1.3-arm64-Windows.exe")]
    public void OtherNamesAreNoDownloads(string name) => Assert.Null(OlderDownloads.VersionOf(name));

    [Theory]
    [InlineData("Wortschatz-1.2-Windows.exe", true)]
    [InlineData("Wortschatz-1.3-Windows (1).exe", true)]
    [InlineData("Wortschatz-1.3.9-Windows.exe", true)]
    [InlineData("Wortschatz-1.4-Windows.exe", false)] // the same version
    [InlineData("Wortschatz-1.4-Windows (1).exe", false)]
    [InlineData("Wortschatz-1.4.1-Windows.exe", false)] // newer
    [InlineData("Wortschatz-1.5-Windows.exe", false)]
    [InlineData("Wortschatz-1.1-Windows.exe", false)] // the earlier WebView app: EarlierApp takes its data over first
    [InlineData("Wortschatz-1.0-Windows.exe", false)]
    [InlineData("Wortschatz.exe", false)]
    public void OnlyOlderVersionsOfThisAppGo(string name, bool older) => Assert.Equal(older, OlderDownloads.IsOlderDownload(name, V14));

    [Fact]
    public void VersionsCompareWithoutTheirRevision()
    {
        Assert.True(OlderDownloads.IsOlder(new Version(1, 3), new Version(1, 4, 0, 0)));
        Assert.False(OlderDownloads.IsOlder(new Version(1, 4), new Version(1, 4, 0, 0)));
        Assert.True(OlderDownloads.IsOlder(new Version(1, 4, 0), new Version(1, 5)));
        Assert.False(OlderDownloads.IsOlder(new Version(1, 1, 9), new Version(1, 5)));
    }
}
