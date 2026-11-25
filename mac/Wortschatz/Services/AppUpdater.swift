#if os(macOS)
import AppKit
import Foundation
import Observation
import Sparkle

/// Updates of the download app through Sparkle 2 (Services/README.md › «Updates»). Checks once a
/// day, loads a new version in the background and installs it when Wortschatz quits; the next
/// start says so in the sidebar (`notice`). «Nach Updates suchen…» in the app menu and
/// Einstellungen › Daten › Updates check at once (with Sparkle's window).
///
/// Every update is the DMG of a published GitHub release, signed with Anthony's key
/// (`SUPublicEDKey` in Wortschatz-Info.plist), and so is its appcast (`SURequireSignedFeed`).
/// Which release: right before every check the app asks GitHub for the newest published release
/// with an appcast.xml (`UpdateFeed.appcastURL`). It goes online for nothing else, and not at all
/// while «Automatisch aktualisieren» is off (then only «Nach Updates suchen…» does).
///
/// Only Release builds update themselves. A DEBUG build (Xcode, the unit tests' host) never
/// checks, so nothing replaces it, and it leaves the update keys in the app's defaults alone.
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    /// Whether this build updates itself.
    let isEnabled: Bool
    /// «Nach Updates suchen…» can start (no check or download is running).
    private(set) var canCheck = false
    /// Einstellungen › Daten › «Automatisch aktualisieren»: Sparkle's daily check. Switching it on
    /// also lets found updates install on quit without asking.
    var checksAutomatically = false {
        didSet { if !isSyncing { applyAutomaticChecks() } }
    }
    /// Found updates install on quit without asking (Sparkle's own window can turn this off; then
    /// the daily check asks first).
    private(set) var installsAutomatically = false
    /// When Sparkle last looked for an update.
    private(set) var lastCheck: Date?
    /// «Aktualisiert auf …» in the sidebar after an update (nil once closed).
    private(set) var notice: UpdateNotice?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var isLookingUpFeed = false
    /// When GitHub was last asked (whatever it answered): Sparkle's daily check goes ahead only
    /// right after that.
    @ObservationIgnored private var lastLookup: Date?
    /// The appcast Sparkle reads (`feedURLString(for:)`); nil until GitHub named one, then
    /// Sparkle falls back to `SUFeedURL`.
    @ObservationIgnored private var feedURL: String?
    @ObservationIgnored private let releasesURL: URL?
    @ObservationIgnored private let noticeStore = UpdateNoticeStore(defaults: UserDefaults.standard)

    private static let feedKey = "update.feedURL"
    /// How long a lookup counts as "right before" a check.
    private static let lookupFreshness: TimeInterval = 60
    /// No cookies, no cache on disk.
    private static let session = URLSession(configuration: .ephemeral)

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        // `WortschatzUpdateReleasesURL` only exists in the test copies of an update test
        // (Services/README.md › «Updates»); the app itself names the repository.
        releasesURL =
            (info["WortschatzUpdateReleasesURL"] as? String).flatMap(URL.init(string:))
            ?? (info["WortschatzUpdateRepository"] as? String).flatMap(UpdateFeed.releasesURL(repository:))
        #if DEBUG
        isEnabled = false
        #else
        isEnabled = releasesURL != nil && info["SUPublicEDKey"] != nil
        #endif
        super.init()
        if isEnabled {
            feedURL = UserDefaults.standard.string(forKey: Self.feedKey)
        }
    }

    /// Starts the updater once, at launch: the notice after an update, then Sparkle's schedule.
    /// Nothing goes online here; Sparkle's first check (right away if the last one is a day old)
    /// asks GitHub first (`updater(_:mayPerform:)`).
    func start() {
        guard isEnabled, controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        notice = noticeStore.noticeAtLaunch(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            now: .now)

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncState() }
        }
        controller.startUpdater()
        syncState()
    }

    /// «Nach Updates suchen…»: asks GitHub for the newest Mac release, then lets Sparkle check
    /// with its window (and install on request).
    func checkForUpdates() {
        guard let controller, canCheck else { return }
        isLookingUpFeed = true
        syncState()
        Task {
            let lookup = await lookUpFeed()
            isLookingUpFeed = false
            if lookup == .noRelease {
                // GitHub answered, but no release has an appcast: nothing newer than this app.
                syncState()
                showUpToDate()
                return
            }
            controller.checkForUpdates(nil)
            syncState()
        }
    }

    /// The notice in the sidebar was closed.
    func dismissNotice() {
        noticeStore.dismiss()
        notice = nil
    }

    // MARK: Feed

    private enum FeedLookup {
        case found
        /// GitHub answered: no published release has an appcast.
        case noRelease
        /// Offline, rate limit, GitHub down: the last known appcast stays.
        case failed
    }

    /// Asks GitHub which release has the newest appcast and remembers it.
    @discardableResult
    private func lookUpFeed() async -> FeedLookup {
        defer { lastLookup = .now }
        guard let releasesURL else { return .failed }
        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            guard let url = try UpdateFeed.appcastURL(releasesJSON: data) else {
                // Every Mac release was withdrawn: forget the last one.
                feedURL = nil
                UserDefaults.standard.removeObject(forKey: Self.feedKey)
                return .noRelease
            }
            feedURL = url.absoluteString
            UserDefaults.standard.set(feedURL, forKey: Self.feedKey)
            return .found
        } catch {
            return .failed
        }
    }

    /// Sparkle's daily check, once GitHub said which release is the newest. A release withdrawn
    /// since the last check (deleted or made a pre-release) is not checked any more.
    private func lookUpThenCheckInBackground() async {
        let lookup = await lookUpFeed()
        guard lookup != .noRelease, let updater = controller?.updater, updater.automaticallyChecksForUpdates else { return }
        // The declined check may still be winding down; Sparkle ignores a check during a session.
        var waited = 0
        while updater.sessionInProgress, waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        updater.checkForUpdatesInBackground()
    }

    // MARK: State

    /// Copies Sparkle's state into the observed properties.
    private func syncState() {
        guard let updater = controller?.updater else { return }
        isSyncing = true
        defer { isSyncing = false }
        canCheck = updater.canCheckForUpdates && !isLookingUpFeed
        lastCheck = updater.lastUpdateCheckDate
        installsAutomatically = updater.automaticallyDownloadsUpdates
        if checksAutomatically != updater.automaticallyChecksForUpdates {
            checksAutomatically = updater.automaticallyChecksForUpdates
        }
    }

    /// «Automatisch aktualisieren»: off stops every check of its own; on checks daily and installs
    /// on quit (also after Sparkle's window had turned installing without asking off).
    private func applyAutomaticChecks() {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = checksAutomatically
        if checksAutomatically { updater.automaticallyDownloadsUpdates = true }
        installsAutomatically = updater.automaticallyDownloadsUpdates
    }

    private func showUpToDate() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let alert = NSAlert()
        alert.messageText = String(localized: "Wortschatz ist aktuell")
        alert.informativeText = String(localized: "Version \(version) ist die neueste.")
        alert.runModal()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL
    }

    /// Sparkle's daily check: declined until GitHub was asked which release is the newest, then
    /// started again (`lookUpThenCheckInBackground`). Sparkle schedules the next day as usual.
    /// Checks from «Nach Updates suchen…» asked GitHub already.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        if let lastLookup, Date.now.timeIntervalSince(lastLookup) < Self.lookupFreshness { return }
        Task { await lookUpThenCheckInBackground() }
        throw NSError(
            domain: "app.wortschatz.updates", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Asking GitHub for the newest release first."])
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        noticeStore.remember(
            DownloadedUpdate(
                version: item.displayVersionString, build: item.versionString,
                changes: UpdateFeed.changes(fromDescription: item.itemDescription)))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        syncState()
    }
}
#endif
