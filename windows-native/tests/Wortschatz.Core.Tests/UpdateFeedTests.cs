using System.Security.Cryptography;
using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// Updates of the Windows app (UpdateFeed, UpdateManifest, UpdateNoticeStore; port of the Mac's UpdateFeedTests.swift):
/// which release the app reads, whether a manifest is signed with a known key, what the sidebar says afterwards.
/// </summary>
public class UpdateFeedTests
{
    /// <summary>GitHub's release list (fields as GET /repos/{owner}/{repo}/releases returns them, shortened).</summary>
    internal static string Releases(params (string Tag, bool Draft, bool Prerelease, string Published, string[] Assets)[] entries) =>
        JSONValue.Array(entries.Select(e => JSONValue.Obj(
            ("tag_name", e.Tag), ("draft", e.Draft), ("prerelease", e.Prerelease), ("published_at", e.Published), ("body", "…"), ("id", 1),
            ("assets", JSONValue.Array(e.Assets.Select(name => JSONValue.Obj(
                ("name", name), ("size", 100), ("content_type", "application/octet-stream"),
                ("browser_download_url", $"https://github.com/SuperStoked13/Wortschatz/releases/download/{e.Tag}/{name}")))))))).ToJsonString();

    [Fact]
    public void TheNewestPublishedWindowsReleaseEvenIfAMacReleaseCameAfter()
    {
        var json = Releases(
            ("v1.9-mac", false, false, "2026-12-03T10:00:00Z", ["Wortschatz-1.9-macOS.dmg", "mac.json", "appcast.xml"]),
            ("v2.0-windows", true, false, "", ["windows-update.json"]),
            ("v1.9.5-windows", false, true, "2026-12-02T10:00:00Z", ["windows-update.json"]),
            ("v1.8.1-windows", false, false, "2026-12-01T10:00:00Z", ["Wortschatz-1.8.1-Windows.exe", "windows.json", "windows-update.json"]),
            ("v1.8-windows", false, false, "2026-11-28T10:00:00Z", ["Wortschatz-1.8-Windows.exe", "windows.json", "windows-update.json"]));
        var release = UpdateFeed.FindRelease(json)!;
        Assert.Equal("v1.8.1-windows", release.Tag);
        Assert.Equal("https://github.com/SuperStoked13/Wortschatz/releases/download/v1.8.1-windows/windows-update.json", release.ManifestUrl);
        Assert.Equal(100, release.Assets["Wortschatz-1.8.1-Windows.exe"].Size);
    }

    [Fact]
    public void ByDateNotByTheOrderOfTheList()
    {
        var json = Releases(
            ("v1.8-windows", false, false, "2026-11-28T10:00:00Z", ["windows-update.json"]),
            ("v1.8.1-windows", false, false, "2026-12-01T10:00:00Z", ["windows-update.json"]));
        Assert.Equal("v1.8.1-windows", UpdateFeed.FindRelease(json)!.Tag);
    }

    [Fact]
    public void WithoutAReleaseWithAManifestNone()
    {
        Assert.Null(UpdateFeed.FindRelease("[]"));
        Assert.Null(UpdateFeed.FindRelease(Releases(("v1.9", false, false, "2026-12-03T10:00:00Z", ["windows.json", "appcast.xml"]))));
    }

    [Fact]
    public void AnErrorFromGitHubInsteadOfTheListIsAnError() =>
        Assert.Throws<FormatException>(() => UpdateFeed.FindRelease("""{"message": "API rate limit exceeded", "documentation_url": "https://docs.github.com"}"""));

    [Fact]
    public void OnlyHttpsAddressesOutsideAnUpdateTest()
    {
        var json = Releases(("v1.8", false, false, "2026-11-28T10:00:00Z", ["windows-update.json"])).Replace("https://", "http://");
        Assert.Null(UpdateFeed.FindRelease(json));
        Assert.NotNull(UpdateFeed.FindRelease(json, testBase: "http://localhost/releases.json"));
        Assert.True(UpdateFeed.IsAllowedUrl("file:///C:/Test/update-test/releases.json", allowTestSchemes: true));
        Assert.False(UpdateFeed.IsAllowedUrl("file:///C:/Test/update-test/releases.json"));
    }

    [Fact]
    public void AnUpdateTestNamesItsFilesRelativeToItsList()
    {
        var json = """[{"tag_name": "v9.1-test", "published_at": "2026-11-25T10:00:00Z", "assets": [{"name": "windows-update.json", "size": 5, "browser_download_url": "v9.1/windows-update.json"}]}]""";
        Assert.Null(UpdateFeed.FindRelease(json));
        Assert.Equal("file:///C:/Test/update-test/v9.1/windows-update.json", UpdateFeed.FindRelease(json, testBase: "file:///C:/Test/update-test/releases.json")!.ManifestUrl);
    }

    [Theory]
    [InlineData("1.8", 1, 8, 0)]
    [InlineData("1.7.1", 1, 7, 1)]
    [InlineData("2.10", 2, 10, 0)]
    public void Versions(string text, int major, int minor, int build) => Assert.Equal(new Version(major, minor, build), UpdateFeed.ParseVersion(text));

    [Theory]
    [InlineData("1")]
    [InlineData("v1.8")]
    [InlineData("1.8-beta")]
    [InlineData("1.8.1.2")]
    [InlineData("")]
    public void OtherTextsAreNoVersions(string text) => Assert.Null(UpdateFeed.ParseVersion(text));

    [Fact]
    public void NewerComparesNumbers()
    {
        Assert.True(UpdateFeed.IsNewer(new Version(1, 10), new Version(1, 9, 3)));
        Assert.True(UpdateFeed.IsNewer(new Version(1, 7, 2), new Version(1, 7, 1)));
        Assert.False(UpdateFeed.IsNewer(new Version(1, 8), new Version(1, 8, 0)));
        Assert.False(UpdateFeed.IsNewer(new Version(1, 7), new Version(1, 7, 1)));
        Assert.True(UpdateFeed.SameVersion("1.8", new Version(1, 8, 0)));
        Assert.Equal("1.8", UpdateFeed.Display(new Version(1, 8, 0)));
        Assert.Equal("1.7.1", UpdateFeed.Display(new Version(1, 7, 1)));
    }
}

/// <summary>Signed manifests (windows-update.json, written by Downloadseite/tools/windows_update.py).</summary>
public class UpdateManifestTests
{
    /// <summary>
    /// Written by windows_update.py (schreiben, with a throwaway key; its public half is <see cref="PythonKey"/>) for a
    /// 32-byte stand-in exe: a German and an English change with «», “”, ’ and umlauts, a Mac-only entry left out.
    /// </summary>
    const string FromPython = """
        {
          "format": 1,
          "manifest": "{\"app\":\"Wortschatz\",\"platform\":\"windows\",\"version\":\"1.8\",\"file\":\"Wortschatz-1.8-Windows.exe\",\"size\":32,\"sha256\":\"da3ae7974d529cff63c8d4e654175e5f0cb0d898f726f56a208bd573774b4411\",\"architecture\":\"x64\",\"released\":\"2026-11-26\",\"changes\":{\"de\":[\"Neu: Wortschatz aktualisiert sich selbst: Neue Versionen lädt die App im Hintergrund und installiert sie, wenn du sie beendest.\",\"Verbessert: Grössere «Knöpfe» – für alle.\"],\"en\":[\"New: Wortschatz now updates itself: the app downloads new versions in the background and installs them when you quit it.\",\"Improved: Bigger “buttons” – for everyone’s fingers.\"]}}",
          "signature": "MEUCIQD/DAyRQi0XwS6tFm5xD18hhUEjj7Lu6pfFvwd65XIhqgIgO5DiwrT068M6L7ynn4vewivyTyEQ9uqvahmEN7fg+GM="
        }
        """;

    const string PythonKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKT2QQy43FUX8WSy9uw5A5/e9e6YyiVvLUdB7ekUAuxhPiXbRzFfRu9xkzPiUnTrIt1899YyTsd8kgKVC3ZhxOQ==";

    /// <summary>A key of the tests' own, and a manifest file signed with it.</summary>
    internal sealed class Signer : IDisposable
    {
        readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        public string PublicKey => Convert.ToBase64String(_key.ExportSubjectPublicKeyInfo());

        public string File(string manifestText) => JSONValue.Obj(("format", 1), ("manifest", manifestText),
            ("signature", Convert.ToBase64String(_key.SignData(Encoding.UTF8.GetBytes(manifestText), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)))).ToJsonString(indented: true);

        public static string Manifest(string version = "1.8", string? file = null, long size = 32, string? sha256 = null, string architecture = "x64",
            string platform = "windows", string[]? de = null, string[]? en = null) =>
            JSONValue.Obj(("app", "Wortschatz"), ("platform", platform), ("version", version), ("file", file ?? $"Wortschatz-{version}-Windows.exe"),
                ("size", size), ("sha256", sha256 ?? new string('a', 64)), ("architecture", architecture), ("released", "2026-11-26"),
                ("changes", JSONValue.Obj(("de", JSONValue.Array((de ?? ["Neu: A"]).Select(s => (JSONValue)s))), ("en", JSONValue.Array((en ?? ["New: A"]).Select(s => (JSONValue)s)))))).ToJsonString();

        public void Dispose() => _key.Dispose();
    }

    [Fact]
    public void AManifestFromTheReleaseToolIsAccepted()
    {
        var m = UpdateManifest.Verify(FromPython, [PythonKey])!;
        Assert.Equal(new Version(1, 8, 0), m.Version);
        Assert.Equal("Wortschatz-1.8-Windows.exe", m.File);
        Assert.Equal(32, m.Size);
        Assert.Equal("da3ae7974d529cff63c8d4e654175e5f0cb0d898f726f56a208bd573774b4411", m.Sha256);
        Assert.Equal("x64", m.Architecture);
        Assert.Equal(["Neu: Wortschatz aktualisiert sich selbst: Neue Versionen lädt die App im Hintergrund und installiert sie, wenn du sie beendest.",
            "Verbessert: Grössere «Knöpfe» – für alle."], m.ChangesDe);
        Assert.Equal("Improved: Bigger “buttons” – for everyone’s fingers.", m.Changes(english: true)[1]);
    }

    [Fact]
    public void OnlyWithAKeyTheAppKnows()
    {
        using var other = new Signer();
        Assert.Null(UpdateManifest.Verify(FromPython, [other.PublicKey]));
        Assert.NotNull(UpdateManifest.Verify(FromPython, [other.PublicKey, PythonKey]));
        Assert.Null(UpdateManifest.Verify(FromPython, []));
        Assert.Null(UpdateManifest.Verify(FromPython, ["not a key"]));
    }

    [Fact]
    public void AChangedManifestIsNoLongerSigned()
    {
        Assert.Null(UpdateManifest.Verify(FromPython.Replace("\\\"size\\\":32", "\\\"size\\\":33"), [PythonKey]));
        Assert.Null(UpdateManifest.Verify(FromPython.Replace("Grössere", "Grosse"), [PythonKey]));
        Assert.Null(UpdateManifest.Verify(FromPython.Replace("\"format\": 1", "\"format\": 2"), [PythonKey]));
        Assert.Null(UpdateManifest.Verify(FromPython.Replace("MEUCIQD/", "MEUCIQD+"), [PythonKey]));
        Assert.Null(UpdateManifest.Verify("{}", [PythonKey]));
        Assert.Null(UpdateManifest.Verify("not json", [PythonKey]));
    }

    [Theory]
    [InlineData("..\\Wortschatz-1.8-Windows.exe")]
    [InlineData("C:\\Windows\\Wortschatz-1.8-Windows.exe")]
    [InlineData("Wortschatz-1.8-Windows.exe/../evil.exe")]
    [InlineData("evil.exe")]
    [InlineData("Wortschatz-1.8-macOS.dmg")]
    public void EvenSignedOnlyAPlainFileNameOfTheWebsite(string file)
    {
        using var signer = new Signer();
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(file: file)), [signer.PublicKey]));
    }

    [Fact]
    public void EvenSignedNothingIncompleteOrForAnotherApp()
    {
        using var signer = new Signer();
        string[] keys = [signer.PublicKey];
        Assert.NotNull(UpdateManifest.Verify(signer.File(Signer.Manifest()), keys));
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(platform: "mac")), keys));
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(version: "1.8-beta", file: "Wortschatz-1.8-Windows.exe")), keys));
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(sha256: "ABC")), keys));
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(size: 0)), keys));
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(size: UpdateFeed.MaxDownloadBytes + 1)), keys));
        Assert.Null(UpdateManifest.Verify(signer.File(Signer.Manifest(architecture: "x86")), keys));
        Assert.Equal("arm64", UpdateManifest.Verify(signer.File(Signer.Manifest(architecture: "arm64")), keys)!.Architecture);
    }

    [Fact]
    public void WithoutEnglishTheGermanChanges()
    {
        using var signer = new Signer();
        var m = UpdateManifest.Verify(signer.File(Signer.Manifest(de: ["Neu: A", " ", "Behoben: B"], en: [])), [signer.PublicKey])!;
        Assert.Equal(["Neu: A", "Behoben: B"], m.Changes(english: true));
    }
}

/// <summary>«Aktualisiert auf …» in the sidebar (UpdateNoticeStore), on a dictionary instead of preferences.json.</summary>
public class UpdateNoticeStoreTests
{
    sealed class MemoryStorage : IUpdateStorage
    {
        public readonly Dictionary<string, JSONValue> Values = [];
        public JSONValue? GetUpdateValue(string key) => Values.GetValueOrDefault(key);

        public void SetUpdateValue(string key, JSONValue? value)
        {
            if (value is null) Values.Remove(key);
            else Values[key] = value;
        }
    }

    readonly MemoryStorage _storage = new();
    readonly UpdateNoticeStore _store;
    const double Start = 1_795_000_000_000;
    const double Hour = 3_600_000, Day = 24 * Hour;

    public UpdateNoticeStoreTests() => _store = new UpdateNoticeStore(_storage);

    [Fact]
    public void FirstLaunchNoNoticeButTheVersionIsRecorded()
    {
        Assert.Null(_store.NoticeAtLaunch("1.8", Start));
        Assert.Equal("1.8", _storage.GetUpdateValue(UpdateNoticeStore.LastVersionKey)?.StringValue);
    }

    [Fact]
    public void AfterAnUpdateANoticeWithTheDownloadedChanges()
    {
        _store.NoticeAtLaunch("1.8", Start);
        _store.Remember(new DownloadedUpdate("1.9", ["Neu: A", "Behoben: B"], ["New: A", "Fixed: B"]));
        var notice = _store.NoticeAtLaunch("1.9", Start + 60_000);
        Assert.Equal(new UpdateNotice("1.9", ["Neu: A", "Behoben: B"], ["New: A", "Fixed: B"], Start + 60_000), notice);
        Assert.Equal(["New: A", "Fixed: B"], notice!.Changes(english: true));
        Assert.Null(_storage.GetUpdateValue(UpdateNoticeStore.DownloadedKey));
    }

    [Fact]
    public void InstalledByHandOrAnotherVersionDownloadedANoticeWithoutChanges()
    {
        _store.NoticeAtLaunch("1.8", Start);
        _store.Remember(new DownloadedUpdate("2.0", ["Neu: C"], ["New: C"]));
        var notice = _store.NoticeAtLaunch("1.9", Start);
        Assert.Equal("1.9", notice?.Version);
        Assert.Empty(notice!.ChangesDe);
    }

    [Fact]
    public void StaysOnLaterLaunchesUntilClosed()
    {
        _store.NoticeAtLaunch("1.8", Start);
        var first = _store.NoticeAtLaunch("1.9", Start);
        Assert.Equal(first, _store.NoticeAtLaunch("1.9", Start + Hour));
        _store.Dismiss();
        Assert.Null(_store.NoticeAtLaunch("1.9", Start + 2 * Hour));
    }

    [Fact]
    public void GoesByItselfAfterAWeek()
    {
        _store.NoticeAtLaunch("1.8", Start);
        _store.NoticeAtLaunch("1.9", Start);
        Assert.NotNull(_store.NoticeAtLaunch("1.9", Start + 6 * Day));
        Assert.Null(_store.NoticeAtLaunch("1.9", Start + 8 * Day));
    }

    [Fact]
    public void VersionsCountAsNumbersAndAnOlderOneGetsNoNotice()
    {
        _store.NoticeAtLaunch("1.9", Start);
        Assert.Equal("1.10", _store.NoticeAtLaunch("1.10", Start)?.Version);
        Assert.Null(_store.NoticeAtLaunch("1.9", Start));
        Assert.Equal("1.9.1", _store.NoticeAtLaunch("1.9.1", Start)?.Version);
        // "1.8" and "1.8.0" are the same version: no notice.
        _store.NoticeAtLaunch("1.8.0", Start);
        Assert.Null(_store.NoticeAtLaunch("1.8", Start));
    }
}
