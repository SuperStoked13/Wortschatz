using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using Avalonia.Threading;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// Updates of the Windows app of the download page (README › «Updates»; Mac: AppUpdater.swift with Sparkle). Looks once
/// a day for the newest published release of the public repository with a signed windows-update.json, loads its exe in
/// the background and puts it in place of this one when the window closes; the next start says so in the sidebar
/// (<see cref="Notice"/>). Einstellungen › Daten › Updates switches it off or looks at once.
///
/// Every update is signed: the manifest with one of <see cref="PublicKeys"/>, the exe by its SHA-256 in the manifest.
/// Only Release builds of the Windows app update themselves (not a Debug build, the snapshot tool or the phone app).
/// The network part exists only in the Windows build; elsewhere this class only keeps the notice and the settings.
/// </summary>
public sealed class AppUpdater
{
    public static AppUpdater Shared { get; } = new();

    /// <summary>The public repository whose releases bring the updates (the Mac app reads the same).</summary>
    public const string Repository = "SuperStoked13/Wortschatz";

    /// <summary>
    /// The public halves of the keys that sign updates (ECDSA P-256, base64 SubjectPublicKeyInfo). The private halves are
    /// only with whoever publishes the Windows app (VEROEFFENTLICHEN.md › «Updates (Windows)»); Downloadseite/tools/
    /// windows_update.py signs with one and checks that it is listed here. A new key only reaches apps that already
    /// contain it: add it in one release, sign with it from the next.
    /// </summary>
    public static readonly string[] PublicKeys =
    [
        // Joan's key (25.11.2026).
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtCjrpdu7VirqdQoGq3reRnZhN4lMHbYg8XJGA3TsE0AFv/LbR+K1EKL05ffR+hwl1aqmiBVW9gMsqjGkj3cDww==",
    ];

    /// <summary>How often it looks (Sparkle's default: once a day), and how often it asks itself whether a day has passed.</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);
    static readonly TimeSpan FirstLook = TimeSpan.FromSeconds(20);
    static readonly TimeSpan Tick = TimeSpan.FromHours(1);
    /// <summary>A daily look that failed (offline at the start, say) is tried again this much later, at most this often per run.</summary>
    static readonly TimeSpan RetryAfter = TimeSpan.FromHours(3);
    const int MaxRetries = 3;

    AppPreferences? _prefs;
    UpdateNoticeStore? _notices;
    string? _folder;
    string? _exe;
    DispatcherTimer? _timer;
    CancellationTokenSource? _checkCancel;
    bool _restartRequested;
    double? _retryAt;
    int _retries;

    /// <summary>The state changed (Einstellungen › Daten shows it).</summary>
    public event Action? Changed;

    /// <summary>The notice came or went (the sidebar shows it).</summary>
    public event Action? NoticeChanged;

    /// <summary>This app has the updater: the Windows app of the download page (not the phone app or the snapshot tool).</summary>
    public static bool IsCompiledIn =>
#if WINDOWS
        true;
#else
        false;
#endif

    /// <summary>This copy updates itself: a Release build (or an update test) of the Windows app, started from an exe.</summary>
    public bool IsEnabled { get; private set; }

    /// <summary>Einstellungen › Daten shows «Updates» (in a Debug build switched off, like the Mac).</summary>
    public bool ShowsSettings => IsCompiledIn || _preview;

    /// <summary>It is looking right now (on request or on its daily look).</summary>
    public bool IsChecking { get; private set; }

    /// <summary>«Automatisch aktualisieren»: look daily, load in the background, install when the window closes.</summary>
    public bool UpdatesAutomatically
    {
        get => _prefs?.UpdatesAutomatically ?? true;
        set
        {
            if (_prefs is null || _prefs.UpdatesAutomatically == value) return;
            _prefs.UpdatesAutomatically = value;
            // Off: nothing installs unless asked for («Jetzt suchen»); a download waiting goes.
            if (!value) Discard();
            Changed?.Invoke();
        }
    }

    /// <summary>When it last looked (ms since 1970).</summary>
    public double? LastCheck => _prefs?.UpdateLastCheck;

    /// <summary>«Aktualisiert auf …» in the sidebar after an update (null once closed).</summary>
    public UpdateNotice? Notice { get; private set; }

    /// <summary>A downloaded, checked version that installs when the window closes.</summary>
    public PendingUpdate? Ready => _prefs?.PendingUpdate is { GaveUp: false } p && p.IsNewerThan(Current) ? p : null;

    /// <summary>What changed in the version that is <see cref="Ready"/> (from its signed manifest).</summary>
    public IReadOnlyList<string> ReadyChanges(bool english) =>
        Ready is { } ready && _prefs is not null && DownloadedUpdate.FromJson(((IUpdateStorage)_prefs).GetUpdateValue(UpdateNoticeStore.DownloadedKey)) is { } d
            && d.Version == ready.Version
            ? (english && d.ChangesEn.Count > 0 ? d.ChangesEn : d.ChangesDe)
            : [];

    /// <summary>A version that failed to install too often (PendingUpdate.MaxFailures): it is given up, else null.</summary>
    public string? GaveUp => _prefs?.PendingUpdate is { GaveUp: true } p && p.IsNewerThan(Current) ? p.Version : null;

    /// <summary>This copy cannot replace itself (it lies in a folder it may not write to, say Program Files); known after a look.</summary>
    public bool IsReadOnly { get; private set; }

    /// <summary>This app's version (1.7.1).</summary>
    public static Version Current => Normalized(typeof(AppUpdater).Assembly.GetName().Version ?? new Version(0, 0, 0));

    static Version Normalized(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));

    // MARK: Update test

    /// <summary>
    /// The key of an update test (windows-native/tools/update-test.sh builds such copies with -p:UpdateTestKey=…; build.sh
    /// never): the copy trusts only this key, reads its releases from the folder update-test next to it, keeps its
    /// library there (never the real one), and updates in a Debug build too. Null in every real app.
    /// </summary>
    public static string? TestKey { get; } = typeof(AppUpdater).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == "WortschatzUpdateTestKey")?.Value is { Length: > 0 } key ? key : null;

    /// <summary>The update test's folder next to the exe (null: not an update test).</summary>
    public static string? TestFolder => TestKey is not null && Environment.ProcessPath is { } exe && Path.GetDirectoryName(exe) is { Length: > 0 } dir
        ? Path.Combine(dir, "update-test") : null;

    static IReadOnlyList<string> Keys => TestKey is { } key ? [key] : PublicKeys;

    static string ReleasesUrl => TestFolder is { } folder ? new Uri(Path.Combine(folder, "releases.json")).AbsoluteUri : UpdateFeed.ReleasesUrl(Repository);

    // MARK: Start

    /// <summary>
    /// At the start, before the window shows its sidebar: the notice after an update, removing what an update left, and
    /// the daily look (the first one a little after the start, so it never slows it down).
    /// </summary>
    public void Start(AppModel model)
    {
        if (!IsCompiledIn || _prefs is not null) return;
        _prefs = model.Preferences;
        _notices = new UpdateNoticeStore(_prefs);
        _folder = model.Store.Backend is FileBackend f && Path.GetDirectoryName(f.Path) is { Length: > 0 } dir ? Path.Combine(dir, "Update") : null;
        _exe = Environment.ProcessPath;
#if DEBUG
        bool release = TestKey is not null;
#else
        bool release = true;
#endif
        IsEnabled = release && _folder is not null && _exe is not null
            && string.Equals(Path.GetExtension(_exe), ".exe", StringComparison.OrdinalIgnoreCase)
            && Path.GetFileNameWithoutExtension(_exe) is not ("dotnet" or "testhost");
        if (!IsEnabled) return;
        Notice = _notices.NoticeAtLaunch(UpdateFeed.Display(Current), TimeUtil.NowMs());

        var exe = _exe!;
        var folder = _folder!;
        // Installed (this is the new version) or outdated: forgotten, also a version given up.
        if (_prefs.PendingUpdate is { } pending && !pending.IsNewerThan(Current)) _prefs.PendingUpdate = null;
        var keep = Ready?.File;
        Task.Run(() =>
        {
            try { UpdateInstaller.CleanUp(exe, folder, keep); }
            catch (Exception) { }
        });

        _timer = new DispatcherTimer { Interval = FirstLook };
        _timer.Tick += (_, _) =>
        {
            _timer.Interval = Tick;
            if (UpdatesAutomatically && IsDue()) _ = CheckAsync(manual: false);
        };
        _timer.Start();
    }

    bool IsDue()
    {
        var now = TimeUtil.NowMs();
        if (_retryAt is { } retry && now >= retry) return true;
        return LastCheck is not { } last || now - last >= CheckInterval.TotalMilliseconds || now < last;
    }

    // MARK: Looking

    /// <summary>What a look found, for «Jetzt suchen».</summary>
    public enum CheckResult { UpToDate, Ready, Failed, Busy, GaveUp, ReadOnly }

    /// <summary>
    /// Looks for a newer version and, if there is one, loads it (on request also with «Automatisch aktualisieren» off: it
    /// then installs when the window closes, like a manual update on the Mac).
    /// </summary>
    public async Task<CheckResult> CheckAsync(bool manual)
    {
        if (!IsEnabled || _prefs is null || _folder is null) return CheckResult.Failed;
        if (IsChecking) return CheckResult.Busy;
        IsChecking = true;
        Changed?.Invoke();
        // In a folder it may not write to, it could load an update but never install it (asked here, not at every start:
        // it writes a short-lived file next to the exe).
        var exe = _exe!;
        bool readOnly = !await Task.Run(() => UpdateInstaller.CanReplace(exe));
        if (readOnly)
        {
            IsChecking = false;
            IsReadOnly = true;
            Changed?.Invoke();
            return CheckResult.ReadOnly;
        }
        IsReadOnly = false;
        _checkCancel = new CancellationTokenSource(TimeSpan.FromMinutes(20));
        UpdateCheckResult result;
        try
        {
#if WINDOWS
            var arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
            var transport = new HttpUpdateTransport(TestKey is not null);
            var folder = _folder;
            var token = _checkCancel.Token;
            var gaveUp = GaveUp;
            result = await Task.Run(() => UpdateCheck.RunAsync(transport, ReleasesUrl, Keys, Current, arch, folder, TestKey is not null, token, gaveUp));
#else
            await Task.CompletedTask;
            result = new UpdateCheckResult(UpdateCheckOutcome.Failed, Error: "no network part in this build");
#endif
        }
        catch (OperationCanceledException)
        {
            result = new UpdateCheckResult(UpdateCheckOutcome.Failed, Error: "took too long");
        }
        finally
        {
            _checkCancel.Dispose();
            _checkCancel = null;
        }
        IsChecking = false;
        _prefs.UpdateLastCheck = TimeUtil.NowMs();
        _prefs.UpdateError = result.Error;
        // A failed look comes again a few hours later (not only tomorrow), a few times per run at most.
        _retryAt = result.Outcome == UpdateCheckOutcome.Failed && ++_retries <= MaxRetries ? TimeUtil.NowMs() + RetryAfter.TotalMilliseconds : null;
        if (result.Outcome != UpdateCheckOutcome.Failed) _retries = 0;
        CheckResult answer;
        switch (result.Outcome)
        {
            case UpdateCheckOutcome.Ready when result.Manifest is { } m && result.File is { } file:
                var ready = PendingUpdate.Downloaded(m, file, _prefs.PendingUpdate);
                _prefs.PendingUpdate = ready;
                _notices?.Remember(new DownloadedUpdate(ready.Version, m.ChangesDe, m.ChangesEn));
                answer = CheckResult.Ready;
                break;
            case UpdateCheckOutcome.UpToDate:
                // The newest version is the one given up: it stays the answer until a newer one comes.
                answer = GaveUp is { } given && result.Manifest is { } newest && UpdateFeed.SameVersion(given, newest.Version)
                    ? CheckResult.GaveUp : CheckResult.UpToDate;
                // A version loaded earlier whose release is gone or a pre-release now (withdrawn): not installed.
                if (answer == CheckResult.UpToDate && Ready is not null) Discard();
                break;
            default:
                answer = CheckResult.Failed;
                break;
        }
        Changed?.Invoke();
        return answer;
    }

    /// <summary>The notice in the sidebar was closed.</summary>
    public void DismissNotice()
    {
        _notices?.Dismiss();
        Notice = null;
        NoticeChanged?.Invoke();
    }

    /// <summary>Throws a waiting download away («Automatisch aktualisieren» switched off).</summary>
    void Discard()
    {
        if (_prefs?.PendingUpdate is not { } pending) return;
        _prefs.PendingUpdate = null;
        ((IUpdateStorage)_prefs).SetUpdateValue(UpdateNoticeStore.DownloadedKey, null);
        UpdateInstaller.CleanUp(null, Path.GetDirectoryName(pending.File) ?? "", null);
    }

    // MARK: Installing

    /// <summary>«Jetzt neu starten»: the window closes (with the usual questions), the update installs, the new version starts.</summary>
    public void RestartToUpdate(Avalonia.Controls.Window window)
    {
        if (Ready is null) return;
        _restartRequested = true;
        window.Close();
    }

    /// <summary>The window did not close after all (a question was cancelled): no restart later.</summary>
    public bool TakeRestartRequest()
    {
        bool requested = _restartRequested;
        _restartRequested = false;
        return requested;
    }

    /// <summary>
    /// The window closes, everything is saved: puts a waiting update in place of this exe (and starts it when
    /// «Jetzt neu starten» asked for it). Never throws; a failure is counted and tried again next time.
    /// </summary>
    public void InstallOnQuit(bool restart)
    {
        if (!IsEnabled || _prefs is null || _exe is null) return;
        string? installedExe = null;
        if (Ready is { } pending)
        {
            var error = Install(pending);
            if (error is null)
            {
                _prefs.PendingUpdate = null;
                installedExe = _exe;
            }
            else
            {
                // Counted: after PendingUpdate.MaxFailures this version is given up (no endless tries at every close).
                _prefs.PendingUpdate = pending.Failed();
                _prefs.UpdateError = $"install: {error}";
            }
        }
        if (!restart) return;
        try
        {
            // The new version (or this one again, if installing failed): the window was asked to restart.
            Process.Start(new ProcessStartInfo(installedExe ?? _exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(_exe) });
        }
        catch (Exception) { }
    }

    /// <summary>Checks the download once more (it waited in a folder of this user) and replaces the exe; null when done.</summary>
    string? Install(PendingUpdate pending)
    {
        if (!UpdateCheck.Matches(pending.File, pending.Size, pending.Sha256)) return "download changed or missing";
#if WINDOWS
        // The exe's own version info: Wortschatz, the version the signed manifest names.
        try
        {
            var info = FileVersionInfo.GetVersionInfo(pending.File);
            if (info.ProductName != "Wortschatz" || !UpdateFeed.SameVersion(pending.Version, new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart)))
                return $"version info {info.ProductName} {info.FileVersion}";
        }
        catch (Exception e) { return e.Message; }
#endif
        return UpdateInstaller.Install(_exe!, pending.File);
    }

    // MARK: Snapshots

    bool _preview;

    /// <summary>The snapshot tool: Einstellungen › Daten › Updates and the sidebar's notice without a real updater.</summary>
    public void Preview(AppPreferences preferences, UpdateNotice? notice, PendingUpdate? ready = null, double? lastCheck = null)
    {
        _preview = true;
        _prefs = preferences;
        Notice = notice;
        _prefs.PendingUpdate = ready;
        _prefs.UpdateLastCheck = lastCheck;
        Changed?.Invoke();
        NoticeChanged?.Invoke();
    }
}
