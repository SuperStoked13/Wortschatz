using System.Security.Cryptography;
using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

/// <summary>
/// Looking for an update and loading it (UpdateCheck) with GitHub played by a dictionary, and putting it in place of the
/// exe (UpdateInstaller) in a temporary folder. What only Windows does (renaming the running exe) is tested there.
/// </summary>
public sealed class UpdateDownloadTests : IDisposable
{
    readonly string _dir = Directory.CreateTempSubdirectory("wortschatz-update-test-").FullName;
    readonly UpdateManifestTests.Signer _signer = new();
    static readonly Version Current = new(1, 7, 1);
    const string ListUrl = "https://api.github.com/repos/SuperStoked13/Wortschatz/releases?per_page=30";

    public void Dispose()
    {
        _signer.Dispose();
        try { Directory.Delete(_dir, recursive: true); }
        catch (IOException) { }
    }

    sealed class FakeGitHub : IUpdateTransport
    {
        public readonly Dictionary<string, byte[]> Files = [];
        public readonly List<string> Downloads = [];
        public Exception? Failure;

        public Task<byte[]> GetAsync(string url, int maxBytes, CancellationToken ct)
        {
            if (Failure is not null) throw Failure;
            return Task.FromResult(Files.TryGetValue(url, out var data) ? data : throw new HttpRequestException($"404 {url}"));
        }

        public async Task DownloadAsync(string url, Stream target, long maxBytes, CancellationToken ct)
        {
            Downloads.Add(url);
            var data = await GetAsync(url, int.MaxValue, ct);
            if (data.Length > maxBytes) throw new HttpRequestException("too big");
            await target.WriteAsync(data, ct);
        }
    }

    static string Url(string tag, string name) => $"https://github.com/SuperStoked13/Wortschatz/releases/download/{tag}/{name}";

    /// <summary>A release v{version}-windows with its exe (the given bytes) and a manifest signed by the tests' key.</summary>
    FakeGitHub Release(string version, byte[] exe, string architecture = "x64", byte[]? served = null, string? manifestFile = null)
    {
        var name = $"Wortschatz-{version}-Windows.exe";
        var tag = $"v{version}-windows";
        var gitHub = new FakeGitHub();
        gitHub.Files[ListUrl] = Encoding.UTF8.GetBytes(UpdateFeedTests.Releases((tag, false, false, "2026-11-28T10:00:00Z", [name, "windows.json", UpdateFeed.ManifestName]))
            .Replace("\"size\":100", "\"size\":-1"));
        var manifest = UpdateManifestTests.Signer.Manifest(version, file: manifestFile ?? name, size: exe.Length,
            sha256: Convert.ToHexStringLower(SHA256.HashData(exe)), architecture: architecture, de: ["Neu: Selbst aktualisieren"], en: ["New: Updates itself"]);
        gitHub.Files[Url(tag, UpdateFeed.ManifestName)] = Encoding.UTF8.GetBytes(_signer.File(manifest));
        gitHub.Files[Url(tag, name)] = served ?? exe;
        return gitHub;
    }

    Task<UpdateCheckResult> Check(FakeGitHub gitHub, string architecture = "x64") =>
        UpdateCheck.RunAsync(gitHub, ListUrl, [_signer.PublicKey], Current, architecture, Path.Combine(_dir, "Update"), false, CancellationToken.None);

    static readonly byte[] NewExe = Encoding.UTF8.GetBytes("MZ Wortschatz 1.8");

    [Fact]
    public async Task ANewerVersionIsLoadedAndChecked()
    {
        var result = await Check(Release("1.8", NewExe));
        Assert.Equal(UpdateCheckOutcome.Ready, result.Outcome);
        Assert.Equal(Path.Combine(_dir, "Update", "Wortschatz-1.8-Windows.exe"), result.File);
        Assert.Equal(NewExe, File.ReadAllBytes(result.File!));
        Assert.Equal(["New: Updates itself"], result.Manifest!.ChangesEn);
        Assert.False(File.Exists(result.File + ".part"));
    }

    [Fact]
    public async Task AVersionAlreadyLoadedIsNotLoadedAgain()
    {
        var gitHub = Release("1.8", NewExe);
        await Check(gitHub);
        var again = await Check(gitHub);
        Assert.Equal(UpdateCheckOutcome.Ready, again.Outcome);
        Assert.Single(gitHub.Downloads);
    }

    [Theory]
    [InlineData("1.7.1")]
    [InlineData("1.7")]
    public async Task TheSameOrAnOlderVersionIsNoUpdate(string version)
    {
        var gitHub = Release(version, NewExe);
        Assert.Equal(UpdateCheckOutcome.UpToDate, (await Check(gitHub)).Outcome);
        Assert.Empty(gitHub.Downloads);
    }

    [Fact]
    public async Task OnlyForTheSameProcessor()
    {
        var gitHub = Release("1.8", NewExe, architecture: "arm64");
        Assert.Equal(UpdateCheckOutcome.UpToDate, (await Check(gitHub)).Outcome);
        Assert.Equal(UpdateCheckOutcome.Ready, (await Check(gitHub, "arm64")).Outcome);
    }

    [Fact]
    public async Task NoReleaseWithAManifestMeansUpToDate()
    {
        var gitHub = new FakeGitHub();
        gitHub.Files[ListUrl] = Encoding.UTF8.GetBytes("[]");
        Assert.Equal(UpdateCheckOutcome.UpToDate, (await Check(gitHub)).Outcome);
    }

    [Fact]
    public async Task AnExeThatIsNotTheSignedOneIsThrownAway()
    {
        var gitHub = Release("1.8", NewExe, served: Encoding.UTF8.GetBytes("MZ something else"));
        var result = await Check(gitHub);
        Assert.Equal(UpdateCheckOutcome.Failed, result.Outcome);
        Assert.Contains("does not match", result.Error);
        Assert.Empty(Directory.GetFiles(Path.Combine(_dir, "Update")));
    }

    [Fact]
    public async Task AManifestWithAnotherKeyIsRefused()
    {
        var gitHub = Release("1.8", NewExe);
        using var stranger = new UpdateManifestTests.Signer();
        var result = await UpdateCheck.RunAsync(gitHub, ListUrl, [stranger.PublicKey], Current, "x64", Path.Combine(_dir, "Update"), false, CancellationToken.None);
        Assert.Equal(UpdateCheckOutcome.Failed, result.Outcome);
        Assert.Empty(gitHub.Downloads);
    }

    [Fact]
    public async Task TheExeMustBeAttachedToTheSameRelease()
    {
        var result = await Check(Release("1.8", NewExe, manifestFile: "Wortschatz-1.8.1-Windows.exe"));
        Assert.Equal(UpdateCheckOutcome.Failed, result.Outcome);
        Assert.Contains("not attached", result.Error);
    }

    [Fact]
    public async Task OfflineIsAFailureNotAnUpdate()
    {
        var gitHub = Release("1.8", NewExe);
        gitHub.Failure = new HttpRequestException("No such host is known.");
        var result = await Check(gitHub);
        Assert.Equal(UpdateCheckOutcome.Failed, result.Outcome);
        Assert.Contains("No such host", result.Error);
    }

    // MARK: Giving up

    [Fact]
    public async Task AVersionThatFailedToInstallThreeTimesIsGivenUpAndNotLoadedAgain()
    {
        var gitHub = Release("1.8", NewExe);
        var first = await Check(gitHub);
        var pending = PendingUpdate.Downloaded(first.Manifest!, first.File!, before: null);
        var exe = Path.Combine(Directory.CreateDirectory(Path.Combine(_dir, "Downloads")).FullName, "Wortschatz-1.7.1-Windows.exe");
        File.WriteAllText(exe, "MZ old");

        // Simulated failure: the download is gone each time the app ends (a virus scanner took it, say).
        for (int close = 1; close <= PendingUpdate.MaxFailures; close++)
        {
            File.Delete(pending.File);
            Assert.NotNull(UpdateInstaller.Install(exe, pending.File));
            Assert.Equal("MZ old", File.ReadAllText(exe));
            pending = pending.Failed();
            Assert.Equal(close == PendingUpdate.MaxFailures, pending.GaveUp);
            // The daily look loads it again until it is given up; the count stays with the version.
            if (!pending.GaveUp)
            {
                var again = await Check(gitHub);
                pending = PendingUpdate.Downloaded(again.Manifest!, again.File!, pending);
                Assert.Equal(close, pending.Failures);
            }
        }
        Assert.Equal(PendingUpdate.MaxFailures, gitHub.Downloads.Count);

        // Given up: the same version is not loaded again ...
        var givenUp = await UpdateCheck.RunAsync(gitHub, ListUrl, [_signer.PublicKey], Current, "x64", Path.Combine(_dir, "Update"), false,
            CancellationToken.None, gaveUp: pending.Version);
        Assert.Equal(UpdateCheckOutcome.UpToDate, givenUp.Outcome);
        Assert.Equal(PendingUpdate.MaxFailures, gitHub.Downloads.Count);

        // ... a newer one starts afresh.
        var newer = Release("1.8.1", NewExe);
        var next = await UpdateCheck.RunAsync(newer, ListUrl, [_signer.PublicKey], Current, "x64", Path.Combine(_dir, "Update"), false,
            CancellationToken.None, gaveUp: pending.Version);
        Assert.Equal(UpdateCheckOutcome.Ready, next.Outcome);
        Assert.Equal(0, PendingUpdate.Downloaded(next.Manifest!, next.File!, pending).Failures);
    }

    [Fact]
    public void AWaitingUpdateIsForgottenOnceThatVersionRuns()
    {
        var pending = new PendingUpdate("1.8", "x", 1, new string('a', 64));
        Assert.True(pending.IsNewerThan(Current));
        Assert.False(pending.IsNewerThan(new Version(1, 8, 0)));
        Assert.Equal(pending with { Failures = 2 }, PendingUpdate.FromJson(pending.Failed().Failed().ToJson()));
    }

    // MARK: Installing

    (string Exe, string Download) Files()
    {
        var folder = Directory.CreateDirectory(Path.Combine(_dir, "Downloads")).FullName;
        var exe = Path.Combine(folder, "Wortschatz-1.7.1-Windows.exe");
        File.WriteAllText(exe, "MZ old");
        var download = Path.Combine(Directory.CreateDirectory(Path.Combine(_dir, "Update")).FullName, "Wortschatz-1.8-Windows.exe");
        File.WriteAllText(download, "MZ new");
        return (exe, download);
    }

    [Fact]
    public void TheNewExeTakesTheOldOnesNameAndPlace()
    {
        var (exe, download) = Files();
        Assert.Null(UpdateInstaller.Install(exe, download));
        Assert.Equal("MZ new", File.ReadAllText(exe));
        Assert.Equal("MZ old", File.ReadAllText(UpdateInstaller.AsidePath(exe)));
        Assert.False(File.Exists(download));

        // The next start removes the old one and what is left in the update folder.
        File.WriteAllText(Path.Combine(_dir, "Update", "Wortschatz-1.9-Windows.exe.part"), "half");
        UpdateInstaller.CleanUp(exe, Path.Combine(_dir, "Update"), keep: null);
        Assert.False(File.Exists(UpdateInstaller.AsidePath(exe)));
        Assert.Empty(Directory.GetFiles(Path.Combine(_dir, "Update")));
        Assert.Equal("MZ new", File.ReadAllText(exe));
    }

    [Fact]
    public void AnOldOneLeftFromAnEarlierUpdateMakesRoom()
    {
        var (exe, download) = Files();
        File.WriteAllText(UpdateInstaller.AsidePath(exe), "MZ older");
        Assert.Null(UpdateInstaller.Install(exe, download));
        Assert.Equal("MZ old", File.ReadAllText(UpdateInstaller.AsidePath(exe)));
    }

    [Fact]
    public void WhenTheNewOneCannotComeTheOldOneStays()
    {
        var (exe, download) = Files();
        File.Delete(download);
        Assert.NotNull(UpdateInstaller.Install(exe, download));
        Assert.Equal("MZ old", File.ReadAllText(exe));
        Assert.False(File.Exists(UpdateInstaller.AsidePath(exe)));
    }

    [Fact]
    public void CleaningUpKeepsTheWaitingDownload()
    {
        var (exe, download) = Files();
        File.WriteAllText(download + ".part", "half");
        UpdateInstaller.CleanUp(exe, Path.GetDirectoryName(download)!, keep: download);
        Assert.True(File.Exists(download));
        Assert.False(File.Exists(download + ".part"));
        Assert.True(File.Exists(exe));
    }

    [Fact]
    public void AFolderItMayWriteToCanBeReplaced()
    {
        var (exe, _) = Files();
        Assert.True(UpdateInstaller.CanReplace(exe));
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(exe)!));
        Assert.False(UpdateInstaller.CanReplace(Path.Combine(_dir, "missing", "Wortschatz.exe")));
    }
}
