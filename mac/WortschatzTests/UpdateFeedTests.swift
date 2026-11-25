import Foundation
import Testing

@testable import Wortschatz

/// Updates of the download app without Sparkle (`UpdateFeed`, `UpdateNoticeStore`): which release
/// Sparkle reads, what the sidebar says afterwards.
@Suite("Updates")
struct UpdateFeedTests {
    /// GitHub's release list (fields as `GET /repos/{owner}/{repo}/releases` returns them, shortened).
    private static func releases(_ entries: [(tag: String, draft: Bool, prerelease: Bool, published: String, assets: [String])]) -> Data {
        let list: [[String: Any]] = entries.map { entry in
            [
                "tag_name": entry.tag, "draft": entry.draft, "prerelease": entry.prerelease,
                "published_at": entry.published, "body": "…", "id": 1,
                "assets": entry.assets.map { name in
                    [
                        "name": name, "size": 100, "content_type": "application/octet-stream",
                        "browser_download_url": "https://github.com/SuperStoked13/Wortschatz/releases/download/\(entry.tag)/\(name)",
                    ]
                },
            ]
        }
        return try! JSONSerialization.data(withJSONObject: list)
    }

    @Test("Die neueste veröffentlichte Mac-Version, auch wenn danach ein Windows-Release kam")
    func newestPublishedMacRelease() throws {
        let data = Self.releases([
            ("v1.9", false, false, "2026-12-03T10:00:00Z", ["Wortschatz-1.9-Windows.exe", "windows.json"]),
            ("v2.0-mac", true, false, "", ["appcast.xml"]),
            ("v1.9.5-mac", false, true, "2026-12-02T10:00:00Z", ["appcast.xml"]),
            ("v1.8.1-mac", false, false, "2026-12-01T10:00:00Z", ["Wortschatz-1.8.1-macOS.dmg", "mac.json", "appcast.xml"]),
            ("v1.8-mac", false, false, "2026-11-28T10:00:00Z", ["Wortschatz-1.8-macOS.dmg", "mac.json", "appcast.xml"]),
        ])
        let url = try UpdateFeed.appcastURL(releasesJSON: data)
        #expect(url?.absoluteString == "https://github.com/SuperStoked13/Wortschatz/releases/download/v1.8.1-mac/appcast.xml")
    }

    @Test("Nach Datum, nicht nach der Reihenfolge der Liste")
    func sortedByDate() throws {
        let data = Self.releases([
            ("v1.8-mac", false, false, "2026-11-28T10:00:00Z", ["appcast.xml"]),
            ("v1.8.1-mac", false, false, "2026-12-01T10:00:00Z", ["appcast.xml"]),
        ])
        #expect(try UpdateFeed.appcastURL(releasesJSON: data)?.lastPathComponent == "appcast.xml")
        #expect(try UpdateFeed.appcastURL(releasesJSON: data)?.pathComponents.contains("v1.8.1-mac") == true)
    }

    @Test("Ohne Release mit appcast.xml keine Adresse")
    func noAppcast() throws {
        #expect(try UpdateFeed.appcastURL(releasesJSON: Data("[]".utf8)) == nil)
        let windowsOnly = Self.releases([("v1.9", false, false, "2026-12-03T10:00:00Z", ["windows.json"])])
        #expect(try UpdateFeed.appcastURL(releasesJSON: windowsOnly) == nil)
    }

    @Test("Eine Fehlermeldung von GitHub statt der Liste ist ein Fehler, keine Adresse")
    func gitHubError() {
        let limit = Data(#"{"message": "API rate limit exceeded", "documentation_url": "https://docs.github.com"}"#.utf8)
        #expect(throws: (any Error).self) { try UpdateFeed.appcastURL(releasesJSON: limit) }
    }

    @Test("Neuerungen: eine pro Zeile, ohne Aufzählungszeichen und Leerzeilen")
    func changesFromDescription() {
        let text = "• Neu: Wortschatz aktualisiert sich selbst.\n\n  • Behoben: Karteikarten.  \n- Verbessert: Tippen.\n"
        #expect(
            UpdateFeed.changes(fromDescription: text) == [
                "Neu: Wortschatz aktualisiert sich selbst.", "Behoben: Karteikarten.", "Verbessert: Tippen.",
            ])
        #expect(UpdateFeed.changes(fromDescription: nil).isEmpty)
        #expect(UpdateFeed.changes(fromDescription: "Kleinere Verbesserungen und Fehlerbehebungen.") == ["Kleinere Verbesserungen und Fehlerbehebungen."])
    }
}

/// «Aktualisiert auf …» in the sidebar (`UpdateNoticeStore`), on a dictionary instead of the
/// app's defaults (the test host is the app itself).
@Suite("Hinweis nach einem Update")
struct UpdateNoticeStoreTests {
    private final class MemoryStorage: UpdateNoticeStorage {
        var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
    }

    private let defaults = MemoryStorage()
    private let store: UpdateNoticeStore
    private let start = Date(timeIntervalSinceReferenceDate: 817_000_000)

    init() {
        store = UpdateNoticeStore(defaults: defaults)
    }

    @Test("Erster Start: kein Hinweis, aber die Version wird gemerkt")
    func firstLaunch() {
        #expect(store.noticeAtLaunch(version: "1.8", build: "10", now: start) == nil)
        #expect(defaults.string(forKey: UpdateNoticeStore.lastBuildKey) == "10")
    }

    @Test("Nach einem Update: Hinweis mit den geladenen Neuerungen")
    func afterUpdate() {
        _ = store.noticeAtLaunch(version: "1.8", build: "10", now: start)
        store.remember(DownloadedUpdate(version: "1.9", build: "11", changes: ["Neu: A", "Behoben: B"]))
        let notice = store.noticeAtLaunch(version: "1.9", build: "11", now: start.addingTimeInterval(60))
        #expect(notice == UpdateNotice(version: "1.9", build: "11", changes: ["Neu: A", "Behoben: B"], since: start.addingTimeInterval(60)))
        #expect(defaults.data(forKey: UpdateNoticeStore.downloadedKey) == nil)
    }

    @Test("Von Hand installiert (oder andere Version geladen): Hinweis ohne Neuerungen")
    func manualInstall() {
        _ = store.noticeAtLaunch(version: "1.8", build: "10", now: start)
        store.remember(DownloadedUpdate(version: "2.0", build: "12", changes: ["Neu: C"]))
        let notice = store.noticeAtLaunch(version: "1.9", build: "11", now: start)
        #expect(notice?.version == "1.9")
        #expect(notice?.changes == [])
    }

    @Test("Bleibt bei weiteren Starts, bis er geschlossen wird")
    func staysUntilClosed() {
        _ = store.noticeAtLaunch(version: "1.8", build: "9", now: start)
        let first = store.noticeAtLaunch(version: "1.9", build: "10", now: start)
        #expect(store.noticeAtLaunch(version: "1.9", build: "10", now: start.addingTimeInterval(3600)) == first)
        store.dismiss()
        #expect(store.noticeAtLaunch(version: "1.9", build: "10", now: start.addingTimeInterval(7200)) == nil)
    }

    @Test("Verschwindet nach einer Woche von selbst")
    func expires() {
        _ = store.noticeAtLaunch(version: "1.8", build: "9", now: start)
        _ = store.noticeAtLaunch(version: "1.9", build: "10", now: start)
        #expect(store.noticeAtLaunch(version: "1.9", build: "10", now: start.addingTimeInterval(6 * 24 * 3600)) != nil)
        #expect(store.noticeAtLaunch(version: "1.9", build: "10", now: start.addingTimeInterval(8 * 24 * 3600)) == nil)
    }

    @Test("Builds zählen als Zahlen (10 nach 9), eine ältere Version bekommt keinen Hinweis")
    func numericBuilds() {
        _ = store.noticeAtLaunch(version: "1.7", build: "9", now: start)
        #expect(store.noticeAtLaunch(version: "1.8", build: "10", now: start)?.build == "10")
        #expect(store.noticeAtLaunch(version: "1.7", build: "9", now: start) == nil)
    }
}
