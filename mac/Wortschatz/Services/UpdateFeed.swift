#if os(macOS)
import Foundation

// Updates of the download app, the parts without Sparkle (Services/README.md › «Updates»):
// which release has the Mac appcast, what changed, and the notice in the sidebar after an update.
// `AppUpdater` puts them together; WortschatzTests/UpdateFeedTests checks them.

/// Where Sparkle finds the appcast.
nonisolated enum UpdateFeed {
    /// The asset of a Mac release that Sparkle reads (`Downloadseite/tools/release-mac.sh` writes it).
    static let appcastName = "appcast.xml"

    /// GitHub's list of releases of `repository` ("owner/name"), newest first.
    static func releasesURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")
    }

    /// The appcast of the newest published release that has one, or nil if none has. Drafts and
    /// pre-releases never count, so an update goes live exactly when a release does (as on the
    /// download site). Mac and Windows come out in releases of their own, so the newest release
    /// may have no appcast; the one before it still does.
    static func appcastURL(releasesJSON data: Data) throws -> URL? {
        try JSONDecoder().decode([Release].self, from: data)
            .filter { $0.draft != true && $0.prerelease != true }
            // ISO 8601 dates in UTC sort as text; GitHub lists newest first anyway.
            .sorted { ($0.published_at ?? "") > ($1.published_at ?? "") }
            .lazy
            .compactMap { release in
                release.assets?.first { $0.name == appcastName }.flatMap { URL(string: $0.browser_download_url) }
            }
            .first { $0.scheme == "https" || $0.scheme == "http" }
    }

    /// The fields of GitHub's release list that matter here.
    private struct Release: Decodable {
        var draft: Bool?
        var prerelease: Bool?
        var published_at: String?
        var assets: [Asset]?
    }

    private struct Asset: Decodable {
        var name: String
        var browser_download_url: String
    }

    /// The changes of an update: one per line of the appcast's description (plain text,
    /// «• Neu: …» in the app's language), without the bullets.
    static func changes(fromDescription text: String?) -> [String] {
        (text ?? "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                if let first = line.first, "•-*".contains(first) { line.removeFirst() }
                return line.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }
}

/// An update Sparkle has downloaded, with what changed: kept until the app starts in that version.
nonisolated struct DownloadedUpdate: Codable, Equatable {
    /// "1.8" (CFBundleShortVersionString).
    var version: String
    /// "10" (CFBundleVersion, what Sparkle compares).
    var build: String
    var changes: [String]
}

/// "Aktualisiert auf 1.8" at the foot of the sidebar, with what changed, until it is closed or a
/// week has passed.
nonisolated struct UpdateNotice: Codable, Equatable {
    var version: String
    var build: String
    var changes: [String]
    /// The first start in this version.
    var since: Date
}

/// Where `UpdateNoticeStore` keeps its values: the app's UserDefaults, in the tests a dictionary.
nonisolated protocol UpdateNoticeStorage: AnyObject {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: UpdateNoticeStorage {}

/// Remembers updates across launches (in the app's UserDefaults).
nonisolated struct UpdateNoticeStore {
    static let lastBuildKey = "update.lastLaunchedBuild"
    static let downloadedKey = "update.downloaded"
    static let noticeKey = "update.notice"
    /// How long an unclosed notice stays.
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    let defaults: any UpdateNoticeStorage

    /// Keeps the changes of a downloaded update for the notice after it is installed.
    func remember(_ update: DownloadedUpdate) {
        defaults.set(try? JSONEncoder().encode(update), forKey: Self.downloadedKey)
    }

    /// At launch: records this build and returns the notice to show. A newer build than the last
    /// start gets a new notice (with the changes Sparkle downloaded for it, if any); otherwise an
    /// earlier notice stays until it is closed or `lifetime` is over.
    func noticeAtLaunch(version: String, build: String, now: Date) -> UpdateNotice? {
        let lastBuild = defaults.string(forKey: Self.lastBuildKey)
        defaults.set(build, forKey: Self.lastBuildKey)

        if let lastBuild, build.compare(lastBuild, options: .numeric) == .orderedDescending {
            let downloaded = decode(DownloadedUpdate.self, Self.downloadedKey).flatMap { $0.build == build ? $0 : nil }
            defaults.removeObject(forKey: Self.downloadedKey)
            let notice = UpdateNotice(version: version, build: build, changes: downloaded?.changes ?? [], since: now)
            defaults.set(try? JSONEncoder().encode(notice), forKey: Self.noticeKey)
            return notice
        }
        guard let notice = decode(UpdateNotice.self, Self.noticeKey), notice.build == build,
            now.timeIntervalSince(notice.since) < Self.lifetime
        else {
            defaults.removeObject(forKey: Self.noticeKey)
            return nil
        }
        return notice
    }

    /// The notice was closed.
    func dismiss() {
        defaults.removeObject(forKey: Self.noticeKey)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
#endif
