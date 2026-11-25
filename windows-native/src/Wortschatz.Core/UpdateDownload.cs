using System.Security.Cryptography;
using System.Text;

namespace Wortschatz.Core;

// Updates of the Windows app (README › «Updates»): looking for a newer version, loading it in the background and
// putting it in place of the running exe when the app ends. What Sparkle does on the Mac. The network comes from the
// app (IUpdateTransport: HttpClient on Windows; tests and the update test bring their own), so all of it runs and is
// tested anywhere. Tests: UpdateDownloadTests.

/// <summary>How the updater reaches GitHub (the app: HTTPS; tests: a dictionary).</summary>
public interface IUpdateTransport
{
    /// <summary>A small file (the release list, a manifest), at most <paramref name="maxBytes"/>; throws when it fails.</summary>
    Task<byte[]> GetAsync(string url, int maxBytes, CancellationToken ct);

    /// <summary>Writes the file at <paramref name="url"/> into <paramref name="target"/>, at most <paramref name="maxBytes"/>; throws when it fails.</summary>
    Task DownloadAsync(string url, Stream target, long maxBytes, CancellationToken ct);
}

/// <summary>What one look for an update found.</summary>
public enum UpdateCheckOutcome
{
    /// <summary>No newer version (or none for this processor).</summary>
    UpToDate,
    /// <summary>A newer version is downloaded and checked: <see cref="UpdateCheckResult.Manifest"/>, <see cref="UpdateCheckResult.File"/>.</summary>
    Ready,
    /// <summary>Offline, GitHub's limit, a file that does not match its signed manifest: nothing changes, the next look tries again (<see cref="UpdateCheckResult.Error"/>: what, in English, for the log).</summary>
    Failed,
}

public sealed record UpdateCheckResult(UpdateCheckOutcome Outcome, UpdateManifest? Manifest = null, string? File = null, string? Error = null);

/// <summary>
/// A downloaded, checked update that installs when the app ends, and how often installing it failed. After
/// <see cref="MaxFailures"/> failures this version is given up: it is neither installed nor downloaded again (a newer
/// version starts afresh; the website's download still works).
/// </summary>
public sealed record PendingUpdate(string Version, string File, long Size, string Sha256, int Failures = 0)
{
    public const int MaxFailures = 3;

    public bool GaveUp => Failures >= MaxFailures;

    /// <summary>Still to do: newer than <paramref name="current"/> (else it is installed already, or outdated).</summary>
    public bool IsNewerThan(Version current) => UpdateFeed.ParseVersion(Version) is { } v && UpdateFeed.IsNewer(v, current);

    /// <summary>A look found <paramref name="manifest"/> ready in <paramref name="file"/>: the same version keeps its failures.</summary>
    public static PendingUpdate Downloaded(UpdateManifest manifest, string file, PendingUpdate? before)
    {
        var version = UpdateFeed.Display(manifest.Version);
        return new PendingUpdate(version, file, manifest.Size, manifest.Sha256, before?.Version == version ? before.Failures : 0);
    }

    /// <summary>Installing failed once more.</summary>
    public PendingUpdate Failed() => this with { Failures = Failures + 1 };

    public JSONValue ToJson() => JSONValue.Obj(("version", Version), ("file", File), ("size", Size), ("sha256", Sha256), ("failures", Failures));

    public static PendingUpdate? FromJson(JSONValue? j) =>
        j?["version"]?.StringValue is { } v && j["file"]?.StringValue is { } f && j["size"]?.FiniteNumber is { } size && j["sha256"]?.StringValue is { } sha
            ? new PendingUpdate(v, f, (long)size, sha, (int)(j["failures"]?.FiniteNumber ?? 0))
            : null;
}

/// <summary>One look for an update: release list, signed manifest, the exe (checked against the manifest).</summary>
public static class UpdateCheck
{
    /// <param name="releasesUrl">GitHub's release list (<see cref="UpdateFeed.ReleasesUrl"/>).</param>
    /// <param name="publicKeys">The keys whose signature the app accepts.</param>
    /// <param name="current">This app's version.</param>
    /// <param name="architecture">"x64" or "arm64": an update is only for the same processor.</param>
    /// <param name="folder">Where downloads go (the update folder next to the library).</param>
    /// <param name="allowTestUrls">An update test: http:// and file:// addresses count too.</param>
    /// <param name="gaveUp">A version that failed to install too often: not downloaded again (UpToDate with its manifest).</param>
    public static async Task<UpdateCheckResult> RunAsync(IUpdateTransport transport, string releasesUrl, IReadOnlyList<string> publicKeys,
        Version current, string architecture, string folder, bool allowTestUrls, CancellationToken ct, string? gaveUp = null)
    {
        UpdateRelease? release;
        try { release = UpdateFeed.FindRelease(Encoding.UTF8.GetString(await transport.GetAsync(releasesUrl, UpdateFeed.MaxListBytes, ct)), allowTestUrls ? releasesUrl : null); }
        catch (Exception e) when (e is not OperationCanceledException) { return Failed(e, "release list"); }
        if (release is null) return new(UpdateCheckOutcome.UpToDate);

        UpdateManifest? manifest;
        try { manifest = UpdateManifest.Verify(Encoding.UTF8.GetString(await transport.GetAsync(release.ManifestUrl, UpdateFeed.MaxManifestBytes, ct)), publicKeys); }
        catch (Exception e) when (e is not OperationCanceledException) { return Failed(e, "manifest"); }
        if (manifest is null) return new(UpdateCheckOutcome.Failed, Error: $"{UpdateFeed.ManifestName} of {release.Tag}: no valid signature");
        if (!UpdateFeed.IsNewer(manifest.Version, current) || manifest.Architecture != architecture) return new(UpdateCheckOutcome.UpToDate, manifest);
        if (gaveUp is not null && UpdateFeed.SameVersion(gaveUp, manifest.Version)) return new(UpdateCheckOutcome.UpToDate, manifest);

        // The exe is the file of the same release that the signed manifest names.
        if (!release.Assets.TryGetValue(manifest.File, out var asset))
            return new(UpdateCheckOutcome.Failed, manifest, Error: $"{manifest.File} is not attached to {release.Tag}");
        if (asset.Size >= 0 && asset.Size != manifest.Size)
            return new(UpdateCheckOutcome.Failed, manifest, Error: $"{manifest.File}: {asset.Size} bytes, the manifest says {manifest.Size}");

        var path = Path.Combine(folder, manifest.File);
        try
        {
            Directory.CreateDirectory(folder);
            if (Matches(path, manifest)) return new(UpdateCheckOutcome.Ready, manifest, path);
            var part = path + ".part";
            await using (var file = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None))
                await transport.DownloadAsync(asset.Url, file, manifest.Size, ct);
            if (!Matches(part, manifest))
            {
                TryDelete(part);
                return new(UpdateCheckOutcome.Failed, manifest, Error: $"{manifest.File} does not match the signed manifest");
            }
            File.Move(part, path, overwrite: true);
            return new(UpdateCheckOutcome.Ready, manifest, path);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            TryDelete(path + ".part");
            return Failed(e, $"download of {manifest.File}");
        }
    }

    /// <summary>Whether <paramref name="path"/> is exactly the file of <paramref name="manifest"/> (size and SHA-256).</summary>
    public static bool Matches(string path, UpdateManifest manifest) => Matches(path, manifest.Size, manifest.Sha256);

    public static bool Matches(string path, long size, string sha256)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length != size) return false;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return Convert.ToHexStringLower(SHA256.HashData(stream)) == sha256;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    static UpdateCheckResult Failed(Exception e, string what) => new(UpdateCheckOutcome.Failed, Error: $"{what}: {e.Message}");

    internal static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>
/// Puts a downloaded, checked update in place of the running exe when the app ends (Sparkle: install on quit). Windows
/// lets a running exe be renamed, not replaced: it moves aside (<see cref="AsidePath"/>), the new exe takes its name and
/// place, so shortcuts, the taskbar and the Start menu open the new version. The next start removes the old one.
/// </summary>
public static class UpdateInstaller
{
    /// <summary>Where the replaced exe waits until the next start removes it ("Wortschatz-1.7-Windows.exe.old").</summary>
    public static string AsidePath(string exe) => exe + ".old";

    /// <summary>
    /// Replaces <paramref name="exe"/> with <paramref name="download"/>. Null when done; otherwise why not, and the exe is
    /// as it was (an exe that could not move aside, or a new one that could not take its place: the old one comes back).
    /// </summary>
    public static string? Install(string exe, string download)
    {
        var aside = AsidePath(exe);
        try
        {
            // An old one left from an earlier update that could not be removed yet (still running then).
            if (File.Exists(aside)) File.Delete(aside);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return e.Message; }
        try { File.Move(exe, aside); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return e.Message; }
        try
        {
            File.Move(download, exe);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            try { File.Move(aside, exe); }
            catch (Exception) { }
            return e.Message;
        }
        try { File.SetAttributes(aside, File.GetAttributes(aside) | FileAttributes.Hidden); }
        catch (Exception) { }
        return null;
    }

    /// <summary>
    /// At the start: removes the exe an update replaced (once it no longer runs) and every file in the update
    /// <paramref name="folder"/> except <paramref name="keep"/> (half downloads, versions that are installed or outdated).
    /// </summary>
    public static void CleanUp(string? exe, string folder, string? keep)
    {
        if (exe is not null && File.Exists(AsidePath(exe))) UpdateCheck.TryDelete(AsidePath(exe));
        if (!Directory.Exists(folder)) return;
        try
        {
            foreach (var file in Directory.EnumerateFiles(folder).ToList())
                if (keep is null || !string.Equals(Path.GetFullPath(file), Path.GetFullPath(keep), StringComparison.OrdinalIgnoreCase))
                    UpdateCheck.TryDelete(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Whether this app can write next to <paramref name="exe"/> (else it cannot replace itself: Program Files, a read-only share).</summary>
    public static bool CanReplace(string exe)
    {
        var dir = Path.GetDirectoryName(exe);
        if (string.IsNullOrEmpty(dir)) return false;
        var probe = Path.Combine(dir, $".wortschatz-update-{Guid.NewGuid():N}.tmp");
        try
        {
            using (File.Create(probe, 1, FileOptions.DeleteOnClose)) { }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        finally { UpdateCheck.TryDelete(probe); }
    }
}
