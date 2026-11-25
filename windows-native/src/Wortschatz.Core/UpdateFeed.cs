using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Wortschatz.Core;

// Updates of the Windows app of the download page (README › «Updates»), the parts without network and windows: which
// release has the update, whether its manifest is signed with a key the app knows, what changed, and the notice in
// the sidebar after an update. Port of the Mac's UpdateFeed.swift; what Sparkle does there (signature, download,
// replacing the app) is in UpdateDownload.cs. Tests: UpdateFeedTests.

/// <summary>Where the update is: the newest published GitHub release with a <see cref="ManifestName"/>.</summary>
public static partial class UpdateFeed
{
    /// <summary>The asset of a Windows release that the app reads (Downloadseite/tools/windows_update.py writes it).</summary>
    public const string ManifestName = "windows-update.json";

    /// <summary>Limits of what the app reads from GitHub (the release list, a manifest, the exe).</summary>
    public const int MaxListBytes = 4 * 1024 * 1024;
    public const int MaxManifestBytes = 256 * 1024;
    public const long MaxDownloadBytes = 500L * 1024 * 1024;

    /// <summary>GitHub's list of releases of <paramref name="repository"/> ("owner/name"), newest first.</summary>
    public static string ReleasesUrl(string repository) => $"https://api.github.com/repos/{repository}/releases?per_page=30";

    /// <summary>
    /// The newest published release that has a <see cref="ManifestName"/>, or null if none has. Drafts and pre-releases
    /// never count, so an update goes live exactly when a release does (as on the download site). Mac and Windows come
    /// out in releases of their own, so the newest release may have no manifest; the one before it still does.
    /// Throws <see cref="FormatException"/> when the text is not a release list (GitHub's error answers are objects).
    /// </summary>
    /// <param name="testBase">An update test: http:// and file:// count too, and addresses relative to this one (the
    /// release list's own) are resolved against it.</param>
    public static UpdateRelease? FindRelease(string releasesJson, string? testBase = null)
    {
        bool allowHttp = testBase is not null;
        if (JSONValue.TryParse(releasesJson)?.ArrayValue is not { } list) throw new FormatException("not a release list");
        var releases = list
            .Where(r => r["draft"]?.BoolValue != true && r["prerelease"]?.BoolValue != true)
            // ISO 8601 dates in UTC sort as text; GitHub lists newest first anyway.
            .OrderByDescending(r => r["published_at"]?.StringValue ?? "", StringComparer.Ordinal);
        foreach (var release in releases)
        {
            var assets = new Dictionary<string, ReleaseAsset>(StringComparer.Ordinal);
            foreach (var a in release["assets"]?.ArrayValue ?? [])
            {
                if (a["name"]?.StringValue is not { Length: > 0 } name || a["browser_download_url"]?.StringValue is not { } url) continue;
                if (testBase is not null && !Uri.IsWellFormedUriString(url, UriKind.Absolute) && Uri.TryCreate(new Uri(testBase), url, out var resolved))
                    url = resolved.AbsoluteUri;
                if (!IsAllowedUrl(url, allowHttp)) continue;
                assets[name] = new ReleaseAsset(name, url, (long)(a["size"]?.FiniteNumber ?? -1));
            }
            if (assets.TryGetValue(ManifestName, out var manifest))
                return new UpdateRelease(release["tag_name"]?.StringValue ?? "", manifest.Url, assets);
        }
        return null;
    }

    /// <summary>HTTPS only (a test feed may also use http:// on this computer or file://).</summary>
    public static bool IsAllowedUrl(string url, bool allowTestSchemes = false) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttps || allowTestSchemes && (uri.Scheme == Uri.UriSchemeHttp || uri.IsFile));

    /// <summary>"1.8" or "1.7.1" as a version to compare (a missing part counts as 0); null for anything else.</summary>
    public static Version? ParseVersion(string? text)
    {
        if (text is null || !VersionText().IsMatch(text)) return null;
        var parts = text.Split('.').Select(p => int.Parse(p, CultureInfo.InvariantCulture)).ToArray();
        return new Version(parts[0], parts[1], parts.Length > 2 ? parts[2] : 0);
    }

    /// <summary>Whether <paramref name="version"/> is newer than <paramref name="current"/> (both as major.minor.build).</summary>
    public static bool IsNewer(Version version, Version current) => Normalized(version) > Normalized(current);

    /// <summary>Whether the text <paramref name="version"/> names <paramref name="current"/> ("1.8" and 1.8.0 do).</summary>
    public static bool SameVersion(string? version, Version current) => ParseVersion(version) is { } v && Normalized(v) == Normalized(current);

    /// <summary>"1.7.1" for 1.7.1 and "1.8" for 1.8.0 (how the download site names versions).</summary>
    public static string Display(Version v) => v.Build > 0 ? $"{v.Major}.{v.Minor}.{v.Build}" : $"{v.Major}.{v.Minor}";

    static Version Normalized(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));

    [GeneratedRegex(@"^\d{1,4}\.\d{1,4}(\.\d{1,4})?$", RegexOptions.CultureInvariant)]
    private static partial Regex VersionText();
}

/// <summary>A release with an update: its tag, the manifest's address and every file of the release by name.</summary>
public sealed record UpdateRelease(string Tag, string ManifestUrl, IReadOnlyDictionary<string, ReleaseAsset> Assets);

/// <summary>A file attached to a release (Size: what GitHub says, -1 if it says nothing).</summary>
public sealed record ReleaseAsset(string Name, string Url, long Size);

/// <summary>
/// What a release says about its Windows update (windows-update.json), signed with the publisher's key: the version, the
/// exe of the same release (only its file name: it is always the file next to the manifest), its size and SHA-256, the
/// processor and what changed, in German and English. Verified before anything else is read.
/// </summary>
public sealed partial record UpdateManifest(
    Version Version, string File, long Size, string Sha256, string Architecture, string? Released,
    IReadOnlyList<string> ChangesDe, IReadOnlyList<string> ChangesEn)
{
    /// <summary>The changes in the app's language (English when it runs in English).</summary>
    public IReadOnlyList<string> Changes(bool english) => english && ChangesEn.Count > 0 ? ChangesEn : ChangesDe;

    /// <summary>
    /// The manifest in <paramref name="fileText"/> if it is signed with one of <paramref name="publicKeys"/> (ECDSA P-256 with
    /// SHA-256, keys as base64 SubjectPublicKeyInfo) and complete; null otherwise. The file is
    /// <c>{"format": 1, "manifest": "&lt;JSON text&gt;", "signature": "&lt;base64 DER&gt;"}</c>: the signature covers the exact
    /// UTF-8 bytes of the manifest text, so nothing depends on how JSON is written.
    /// </summary>
    public static UpdateManifest? Verify(string fileText, IEnumerable<string> publicKeys)
    {
        if (JSONValue.TryParse(fileText) is not { ObjectValue: not null } outer) return null;
        if (outer["format"]?.FiniteNumber != 1) return null;
        if (outer["manifest"]?.StringValue is not { Length: > 0 } text || outer["signature"]?.StringValue is not { Length: > 0 } sig) return null;
        byte[] signature;
        try { signature = Convert.FromBase64String(sig); }
        catch (FormatException) { return null; }
        var data = Encoding.UTF8.GetBytes(text);
        if (!publicKeys.Any(key => IsSignedWith(data, signature, key))) return null;
        return Parse(text);
    }

    /// <summary>Whether <paramref name="signature"/> (DER, as openssl writes it) signs <paramref name="data"/> with <paramref name="publicKey"/>.</summary>
    public static bool IsSignedWith(byte[] data, byte[] signature, string publicKey)
    {
        try
        {
            using var ecdsa = ECDsa.Create();
            ecdsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKey), out _);
            if (ecdsa.KeySize != 256) return false;
            return ecdsa.VerifyData(data, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        }
        catch (Exception e) when (e is CryptographicException or FormatException or PlatformNotSupportedException) { return false; }
    }

    /// <summary>The fields of a manifest text (already verified); null when one is missing or not plausible.</summary>
    static UpdateManifest? Parse(string text)
    {
        if (JSONValue.TryParse(text) is not { ObjectValue: not null } m) return null;
        if (m["app"]?.StringValue != "Wortschatz" || m["platform"]?.StringValue != "windows") return null;
        if (UpdateFeed.ParseVersion(m["version"]?.StringValue) is not { } version) return null;
        if (m["file"]?.StringValue is not { } file || !FileName().IsMatch(file)) return null;
        if (m["size"]?.FiniteNumber is not { } size || size <= 0 || size > UpdateFeed.MaxDownloadBytes || size != Math.Floor(size)) return null;
        if (m["sha256"]?.StringValue is not { } sha || !Sha256Text().IsMatch(sha)) return null;
        var arch = m["architecture"]?.StringValue;
        if (arch is not ("x64" or "arm64")) return null;
        var changes = m["changes"];
        return new UpdateManifest(version, file, (long)size, sha, arch, m["released"]?.StringValue,
            ChangeList(changes?["de"]), ChangeList(changes?["en"]));
    }

    static List<string> ChangeList(JSONValue? list) =>
        (list?.ArrayValue ?? []).Select(v => v.StringValue?.Trim()).OfType<string>().Where(s => s.Length is > 0 and <= 2000).Take(50).ToList();

    /// <summary>A plain file name as the website names downloads (no folder, no path).</summary>
    [GeneratedRegex(@"^Wortschatz-[0-9][0-9A-Za-z.+-]{0,40}-Windows\.exe$", RegexOptions.CultureInvariant)]
    private static partial Regex FileName();

    [GeneratedRegex(@"^[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex Sha256Text();
}

/// <summary>An update that was downloaded, with what changed: kept until the app starts in that version.</summary>
public sealed record DownloadedUpdate(string Version, IReadOnlyList<string> ChangesDe, IReadOnlyList<string> ChangesEn)
{
    public JSONValue ToJson() => JSONValue.Obj(("version", Version),
        ("de", JSONValue.Array(ChangesDe.Select(c => (JSONValue)c))), ("en", JSONValue.Array(ChangesEn.Select(c => (JSONValue)c))));

    public static DownloadedUpdate? FromJson(JSONValue? j) => j?["version"]?.StringValue is { } v
        ? new DownloadedUpdate(v, Strings(j["de"]), Strings(j["en"]))
        : null;

    internal static List<string> Strings(JSONValue? list) => (list?.ArrayValue ?? []).Select(s => s.StringValue).OfType<string>().ToList();
}

/// <summary>
/// "Aktualisiert auf 1.8" at the foot of the sidebar, with what changed, until it is closed or a week has passed.
/// Since: the first start in this version (ms since 1970).
/// </summary>
public sealed record UpdateNotice(string Version, IReadOnlyList<string> ChangesDe, IReadOnlyList<string> ChangesEn, double Since)
{
    /// <summary>The changes in the app's language.</summary>
    public IReadOnlyList<string> Changes(bool english) => english && ChangesEn.Count > 0 ? ChangesEn : ChangesDe;

    public JSONValue ToJson() => JSONValue.Obj(("version", Version), ("since", Since),
        ("de", JSONValue.Array(ChangesDe.Select(c => (JSONValue)c))), ("en", JSONValue.Array(ChangesEn.Select(c => (JSONValue)c))));

    public static UpdateNotice? FromJson(JSONValue? j) => j?["version"]?.StringValue is { } v && j["since"]?.FiniteNumber is { } since
        ? new UpdateNotice(v, DownloadedUpdate.Strings(j["de"]), DownloadedUpdate.Strings(j["en"]), since)
        : null;

    public bool Equals(UpdateNotice? other) => other is not null && Version == other.Version && Since == other.Since
        && ChangesDe.SequenceEqual(other.ChangesDe) && ChangesEn.SequenceEqual(other.ChangesEn);

    public override int GetHashCode() => HashCode.Combine(Version, Since);
}

/// <summary>Where <see cref="UpdateNoticeStore"/> keeps its values: the app's preferences.json, in the tests a dictionary.</summary>
public interface IUpdateStorage
{
    JSONValue? GetUpdateValue(string key);
    void SetUpdateValue(string key, JSONValue? value);
}

/// <summary>Remembers updates across launches (port of the Mac's UpdateNoticeStore).</summary>
public sealed class UpdateNoticeStore(IUpdateStorage storage)
{
    public const string LastVersionKey = "update.lastLaunchedVersion";
    public const string DownloadedKey = "update.downloaded";
    public const string NoticeKey = "update.notice";
    /// <summary>How long an unclosed notice stays.</summary>
    public const double LifetimeMs = 7 * 24 * 60 * 60 * 1000.0;

    /// <summary>Keeps the changes of a downloaded update for the notice after it is installed.</summary>
    public void Remember(DownloadedUpdate update) => storage.SetUpdateValue(DownloadedKey, update.ToJson());

    /// <summary>
    /// At launch: records this version and returns the notice to show. A newer version than the last start gets a new
    /// notice (with the changes downloaded for it, if any); otherwise an earlier notice stays until it is closed or
    /// <see cref="LifetimeMs"/> is over. The first start of all (no version recorded yet) has none.
    /// </summary>
    public UpdateNotice? NoticeAtLaunch(string version, double nowMs)
    {
        var last = storage.GetUpdateValue(LastVersionKey)?.StringValue;
        storage.SetUpdateValue(LastVersionKey, version);
        if (UpdateFeed.ParseVersion(version) is { } current && UpdateFeed.ParseVersion(last) is { } previous && UpdateFeed.IsNewer(current, previous))
        {
            var downloaded = DownloadedUpdate.FromJson(storage.GetUpdateValue(DownloadedKey));
            // Only the changes of this very version (another one may have been downloaded meanwhile, or none at all:
            // a download from the website).
            if (downloaded is not null && !UpdateFeed.SameVersion(downloaded.Version, current)) downloaded = null;
            storage.SetUpdateValue(DownloadedKey, null);
            var notice = new UpdateNotice(version, downloaded?.ChangesDe ?? [], downloaded?.ChangesEn ?? [], nowMs);
            storage.SetUpdateValue(NoticeKey, notice.ToJson());
            return notice;
        }
        if (UpdateNotice.FromJson(storage.GetUpdateValue(NoticeKey)) is { } kept && kept.Version == version && nowMs - kept.Since < LifetimeMs)
            return kept;
        storage.SetUpdateValue(NoticeKey, null);
        return null;
    }

    /// <summary>The notice was closed.</summary>
    public void Dismiss() => storage.SetUpdateValue(NoticeKey, null);
}
