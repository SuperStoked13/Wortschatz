import Foundation
import Testing
import WortschatzCore

/// A fresh temporary folder, removed by `cleanup()`.
struct LibraryStoreTempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "wortschatz-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var libraryURL: URL { url.appending(path: "Wortschatz/library.json", directoryHint: .notDirectory) }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A clock for FileBackend's backup rotation.
final class LibraryStoreTestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

@Suite("LibraryStore persistence")
struct LibraryStorePersistenceTests {
    private typealias Kit = LibraryStoreTestKit
    private typealias StoreEnv = LibraryStoreTestEnv

    static func documentData(_ json: JSONValue) throws -> Data { try json.jsonData() }

    /// A small library with every kind of data.
    private static func populate(_ store: LibraryStore) throws -> VocabSet {
        let set = try store.createSet(title: "Personen", description: "Unité 1", cards: Kit.sample)
        try store.createSet(title: "Farben", termLang: .en, cards: [CardDraft(term: "red", definition: "rot")])
        try store.recordAnswer(set.id, set.cards[0].id, correct: true, at: Kit.localMs(2026, 10, 11, 9))
        try store.recordAnswer(set.id, set.cards[1].id, correct: false, at: Kit.localMs(2026, 10, 12, 9))
        try store.saveSessionJSON(set.id, ["v": 1, "round": 1, "queue": ["x"], "finishedAt": nil])
        try store.saveLearnJSON(set.id, Kit.learnState)
        try store.updateSettings(SettingsPatch(theme: .dark, study: StudyOptionsPatch(learn: LearnOptionsPatch(roundSize: 10))))
        try store.updateStudyOptions(set.id, StudyOptionsPatch(answerWith: .both))
        return set
    }

    private static func expectSameLibrary(_ a: LibraryStore, _ b: LibraryStore, ids: [String]) {
        #expect(a.listSets() == b.listSets())
        #expect(a.getSettings() == b.getSettings())
        #expect(a.getActivity() == b.getActivity())
        for id in ids {
            #expect(a.getProgress(id) == b.getProgress(id))
            #expect(a.getSessionJSON(id) == b.getSessionJSON(id))
            #expect(a.getLearnJSON(id) == b.getLearnJSON(id))
            #expect(a.getStudyOptions(id) == b.getStudyOptions(id))
        }
    }

    // MARK: Saving

    @Test func savedLibrariesLoadUnchanged() throws {
        let env = StoreEnv()
        let set = try Self.populate(env.store)
        try env.store.save()
        let reopened = env.makeStore()
        Self.expectSameLibrary(env.store, reopened, ids: env.store.listSets().map(\.id))
        #expect(reopened.getLearnJSON(set.id) == Kit.learnState)
        #expect(reopened.recovery == .none)
        // The first write of the new instance does not write the schema version again.
        var events: [StoreChange] = []
        reopened.subscribe { events.append($0) }
        try reopened.updateSettings(SettingsPatch(theme: .light))
        #expect(events == [StoreChange(kind: .local, keys: ["settings"])])
    }

    @Test func saveWritesOnlyWhenSomethingChanged() throws {
        let env = StoreEnv()
        let store = env.store!
        #expect(!store.hasUnsavedChanges)
        try store.save()
        #expect(env.backend.saveCount == 0)
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(store.hasUnsavedChanges)
        try store.save()
        #expect(!store.hasUnsavedChanges)
        #expect(env.backend.saveCount == 1)
        try store.save()
        #expect(env.backend.saveCount == 1)
        // Failed operations and reads change nothing.
        _ = Kit.codeOf { try store.updateSet("missing", SetPatch(title: "x")) }
        _ = store.exportAll()
        #expect(!store.hasUnsavedChanges)
        try store.toggleStar(set.id, set.cards[0].id)
        #expect(store.hasUnsavedChanges)
    }

    @Test func aFailedSaveKeepsTheChangesForTheNextSave() throws {
        struct Unwritable: Error {}
        let env = StoreEnv()
        let store = env.store!
        try store.createSet(title: "A", cards: Kit.sample)
        env.backend.failNextSave = Unwritable()
        let error = try #require(Kit.errorOf { try store.save() })
        #expect(error.code == .io)
        #expect(error.message == StoreMessages.io)
        #expect(store.hasUnsavedChanges)
        #expect(store.listSets().count == 1)
        try store.save()
        #expect(!store.hasUnsavedChanges)
        #expect(env.makeStore().listSets().count == 1)
    }

    @Test func aChangeMadeWhileSavingStaysUnsaved() throws {
        // `save()` writes outside the store's lock (the app saves on a background thread), so
        // the library can change while an older snapshot is being written.
        let backend = DuringSaveBackend()
        let store = LibraryStore(backend: backend)
        let set = try store.createSet(title: "A", cards: Kit.sample)
        backend.duringSave = { try? store.toggleStar(set.id, set.cards[0].id) }
        try store.save()
        #expect(store.hasUnsavedChanges)
        #expect(LibraryStore(backend: backend).getSet(set.id)?.cards[0].starred == false)
        backend.duringSave = nil
        try store.save()
        #expect(!store.hasUnsavedChanges)
        #expect(LibraryStore(backend: backend).getSet(set.id)?.cards[0].starred == true)
    }

    @Test func aFullDiskSurfacesAsQuotaWithAGermanMessage() throws {
        let env = StoreEnv()
        try env.store.createSet(title: "A", cards: Kit.sample)
        env.backend.failNextSave = CocoaError(.fileWriteOutOfSpace)
        let error = try #require(Kit.errorOf { try env.store.save() })
        #expect(error.code == .quota)
        #expect(error.message.contains("Speicherplatz"))
        #expect(!error.message.contains("ß"))
        env.backend.failNextSave = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        #expect(Kit.errorOf { try env.store.save() }?.code == .quota)
    }

    // MARK: Autosave

    @Test func autosaveWritesEveryChange() throws {
        let env = StoreEnv(autosave: true)
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        #expect(env.backend.saveCount == 1)
        try store.recordAnswer(set.id, set.cards[0].id, correct: true)
        #expect(env.backend.saveCount == 2)
        #expect(!store.hasUnsavedChanges)
        _ = store.listSets()
        #expect(env.backend.saveCount == 2)
        #expect(env.makeStore().getProgress(set.id).count == 1)
    }

    @Test func aFailedAutosaveUndoesTheWholeOperation() throws {
        // Like a QUOTA error in the web app: nothing of the operation stays, nobody is notified.
        let env = StoreEnv(autosave: true)
        let store = env.store!
        let set = try store.createSet(title: "A", cards: Kit.sample)
        var events = 0
        store.subscribe { _ in events += 1 }
        env.backend.failNextSave = CocoaError(.fileWriteOutOfSpace)
        #expect(Kit.codeOf { try store.createSet(title: "B", cards: Kit.sample) } == "QUOTA")
        #expect(store.listSets().map(\.title) == ["A"])
        env.backend.failNextSave = CocoaError(.fileWriteNoPermission)
        #expect(Kit.codeOf { try store.updateSet(set.id, SetPatch(title: "Neu")) } == "IO")
        #expect(store.getSet(set.id)?.title == "A")
        env.backend.failNextSave = CocoaError(.fileWriteNoPermission)
        #expect(Kit.codeOf { try store.recordAnswer(set.id, set.cards[0].id, correct: true) } == "IO")
        #expect(store.getProgress(set.id).isEmpty)
        #expect(store.getActivity().isEmpty)
        #expect(events == 0)
        #expect(!store.hasUnsavedChanges)
        #expect(try store.updateSet(set.id, SetPatch(title: "Neu")).title == "Neu")
        #expect(events == 1)
    }

    @Test func aFailedImportLeavesEverythingAsItWas() throws {
        let env = StoreEnv(autosave: true)
        let store = env.store!
        try store.importAll(
            ["app": "wortschatz", "version": 1,
             "sets": [["id": "A", "title": "Set A", "cards": [["id": "a0", "term": "a", "definition": "b"]]]],
             "progress": ["A": ["a0": ["correct": 2, "streak": 2]]]],
            mode: .replace)
        try store.updateSettings(SettingsPatch(theme: .dark))
        try store.saveSessionJSON("A", ["v": 1, "round": 2])
        try store.saveLearnJSON("A", Kit.learnState)
        let before = try #require(env.backend.data)
        for mode in ImportMode.allCases {
            env.backend.failNextSave = CocoaError(.fileWriteOutOfSpace)
            let error = Kit.errorOf {
                try store.importAll(
                    ["app": "wortschatz", "version": 1, "settings": ["theme": "light"],
                     "sets": [["id": "B", "cards": [["id": "b0", "term": "c", "definition": "d"]]]]],
                    mode: mode)
            }
            #expect(error?.code == .quota)
            #expect(env.backend.data == before)
            for reader in [store, env.makeStore()] {
                #expect(reader.listSets().map(\.id) == ["A"])
                #expect(reader.getProgress("A").count == 1)
                #expect(reader.getSessionJSON("A") == ["v": 1, "round": 2])
                #expect(reader.getLearnJSON("A") == Kit.learnState)
                #expect(reader.getSettings().theme == .dark)
            }
        }
        // The store still works normally afterwards.
        #expect(try store.updateSettings(SettingsPatch(theme: .light)).theme == .light)
    }

    // MARK: Recovery

    @Test func aCorruptLibraryIsRecoveredFromTheNewestReadableBackup() throws {
        let good = try Self.documentData(["schemaVersion": 1, "sets": [["id": "s1", "title": "Gerettet", "cards": []]]])
        let older = try Self.documentData(["schemaVersion": 1, "sets": [["id": "s0", "title": "Älter", "cards": []]]])
        let corrupt = Data("{\"sets\": [".utf8)

        let backend = MemoryBackend(data: corrupt, backups: [Data("garbage".utf8), good, older])
        let store = LibraryStore(backend: backend)
        #expect(store.recovery == .fromBackup(index: 1))
        #expect(store.listSets().map(\.title) == ["Gerettet"])
        #expect(backend.corrupt == corrupt)
        #expect(backend.data == nil)
        // The recovered library becomes the primary document with the next save.
        #expect(store.hasUnsavedChanges)
        try store.save()
        #expect(LibraryStore(backend: backend).listSets().map(\.title) == ["Gerettet"])
    }

    @Test func aMissingLibraryWithBackupsIsRecovered() throws {
        let good = try Self.documentData(["sets": [["id": "s1", "title": "Gerettet", "cards": []]]])
        let backend = MemoryBackend(data: nil, backups: [good])
        let store = LibraryStore(backend: backend, autosave: true)
        #expect(store.recovery == .fromBackup(index: 0))
        #expect(backend.corrupt == nil)
        // With autosave the recovered library is written right away.
        #expect(backend.data != nil)
        #expect(!store.hasUnsavedChanges)
    }

    @Test func nothingReadableStartsEmpty() throws {
        for primary in [Data("{not json".utf8), Data("[]".utf8), Data("\"text\"".utf8), Data([0xFF, 0xFE])] {
            let backend = MemoryBackend(data: primary, backups: [Data("{".utf8)])
            let store = LibraryStore(backend: backend)
            #expect(store.recovery == .reset)
            #expect(store.listSets().isEmpty)
            #expect(backend.corrupt == primary)
            #expect(!store.hasUnsavedChanges)
        }
        let fresh = LibraryStore(backend: MemoryBackend())
        #expect(fresh.recovery == .none)
    }

    // MARK: FileBackend

    @Test func fileBackendStoresTheLibraryAtomically() throws {
        let dir = try LibraryStoreTempDir()
        defer { dir.cleanup() }
        let backend = FileBackend(url: dir.libraryURL)
        #expect(try backend.load() == nil)
        #expect(backend.loadBackups().isEmpty)
        try backend.save(Data("{\"a\":1}".utf8))
        #expect(try backend.load() == Data("{\"a\":1}".utf8))
        #expect(backend.backupURLs.map(\.lastPathComponent) == [
            "library-backup-1.json", "library-backup-2.json", "library-backup-3.json",
        ])
        #expect(backend.corruptURL.lastPathComponent == "library-corrupt.json")
        #expect(FileBackend(url: dir.libraryURL, backupCount: 0).backupURLs.isEmpty)
    }

    @Test func fileBackendKeepsThreeRotatingBackups() throws {
        let dir = try LibraryStoreTempDir()
        defer { dir.cleanup() }
        let backend = FileBackend(url: dir.libraryURL, backupInterval: 0)
        for i in 1...5 { try backend.save(Data("{\"v\":\(i)}".utf8)) }
        #expect(try backend.load() == Data("{\"v\":5}".utf8))
        #expect(backend.loadBackups() == [4, 3, 2].map { Data("{\"v\":\($0)}".utf8) })
    }

    @Test func fileBackendRotatesAtMostOncePerInterval() throws {
        let dir = try LibraryStoreTempDir()
        defer { dir.cleanup() }
        let clock = LibraryStoreTestDateClock()
        let backend = FileBackend(url: dir.libraryURL, backupInterval: 300, clock: { clock.now })
        try backend.save(Data("{\"v\":1}".utf8))
        try backend.save(Data("{\"v\":2}".utf8))  // first rotation: no backup yet
        clock.advance(60)
        try backend.save(Data("{\"v\":3}".utf8))  // too soon: no new backup
        #expect(backend.loadBackups() == [Data("{\"v\":1}".utf8)])
        clock.advance(300)
        try backend.save(Data("{\"v\":4}".utf8))
        #expect(backend.loadBackups() == [Data("{\"v\":3}".utf8), Data("{\"v\":1}".utf8)])
    }

    @Test func discardingBackupsLeavesOnlyTheCurrentLibrary() throws {
        let dir = try LibraryStoreTempDir()
        defer { dir.cleanup() }
        let backend = FileBackend(url: dir.libraryURL, backupInterval: 0)
        let store = LibraryStore(backend: backend)
        try store.createSet(title: "Personen", cards: Kit.sample)
        try store.save()
        try store.createSet(title: "Farben", cards: Kit.sample)
        try store.save()
        try Data("{\"sets\": [".utf8).write(to: backend.corruptURL)
        #expect(!backend.loadBackups().isEmpty)

        // "Alle Daten löschen": clear, save, then drop the older copies.
        try store.clearAll()
        try store.save()
        backend.discardBackups()
        #expect(backend.loadBackups().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backend.corruptURL.path(percentEncoded: false)))
        let reopened = LibraryStore(backend: backend)
        #expect(reopened.recovery == .none)
        #expect(reopened.listSets().isEmpty)
        // A damaged file afterwards cannot bring the deleted sets back.
        try Data("{\"sets\": [".utf8).write(to: dir.libraryURL)
        #expect(LibraryStore(backend: backend).listSets().isEmpty)

        let memory = MemoryBackend(data: Data("{}".utf8), backups: [Data("{\"v\":1}".utf8)])
        memory.discardBackups()
        #expect(memory.backups.isEmpty)
        #expect(memory.data == Data("{}".utf8))
    }

    @Test func aStoreOnACorruptFileRecoversAndKeepsTheDamagedCopy() throws {
        let dir = try LibraryStoreTempDir()
        defer { dir.cleanup() }
        let backend = FileBackend(url: dir.libraryURL, backupInterval: 0)
        let store = LibraryStore(backend: backend)
        try store.createSet(title: "Erste Fassung", cards: Kit.sample)
        try store.save()
        try store.createSet(title: "Zweite Fassung", cards: Kit.sample)
        try store.save()
        // The file gets damaged outside the app.
        try Data("{\"sets\": [{\"id\"".utf8).write(to: dir.libraryURL)

        let recovered = LibraryStore(backend: backend)
        #expect(recovered.recovery == .fromBackup(index: 0))
        #expect(recovered.listSets().map(\.title) == ["Erste Fassung"])
        #expect(FileManager.default.fileExists(atPath: backend.corruptURL.path(percentEncoded: false)))
        try recovered.save()
        #expect(LibraryStore(backend: backend).recovery == .none)
        #expect(LibraryStore(backend: backend).listSets().map(\.title) == ["Erste Fassung"])
    }

    @Test func theDefaultLocationIsInApplicationSupport() throws {
        let url = try FileBackend.defaultURL()
        #expect(url.lastPathComponent == "library.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Wortschatz")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    // MARK: The real web backup

    /// The web backup of Fixtures/store.json: the user's 52 cards, a second set, answers on three
    /// days, settings and set options (exported from the JS store).
    static func webBackup() throws -> JSONValue {
        let fixture = try Fixtures.load("store")
        return try #require(fixture.cases.first { $0.fn == "webBackup" }).arg(0)
    }

    @Test func theWebBackupMovesIntoTheMacLibraryUnchanged() throws {
        let backup = try Self.webBackup()
        let dir = try LibraryStoreTempDir()
        defer { dir.cleanup() }
        let store = LibraryStore(backend: FileBackend(url: dir.libraryURL), now: { 1_791_000_000_000 }, timeZone: zurich)
        #expect(try store.importAll(backup, mode: .replace) == ImportSummary(setsAdded: 2, setsUpdated: 0))
        try store.save()

        let reopened = LibraryStore(backend: FileBackend(url: dir.libraryURL), now: { 1_791_000_000_000 }, timeZone: zurich)
        let sets = reopened.listSets()
        #expect(sets.map(\.cards.count).contains(52))
        var exported = try JSONValue(encoding: reopened.exportAll()).objectValue ?? [:]
        var original = backup.objectValue ?? [:]
        exported["exportedAt"] = nil
        original["exportedAt"] = nil
        #expect(JSONValue.identical(.object(exported), .object(original)))
        // And back: the Mac export is a valid web backup again.
        let data = try Backup.jsonData(reopened.exportAll())
        let again = LibraryStore(backend: MemoryBackend())
        try again.importAll(try Backup.readJSON(data), mode: .replace)
        #expect(again.listSets() == sets)
    }

    /// The raw Write and Learn states the web engines stored in the `web-library` scenario.
    static func webSessionStates() throws -> (sessions: [JSONValue], learns: [JSONValue]) {
        let fixture = try Fixtures.load("store")
        let scenario = try #require(fixture.cases.first { $0.fn == "scenario" && $0.arg(0)["name"] == "web-library" })
        let ops = scenario.arg(0)["ops"]?.arrayValue ?? []
        return (
            ops.filter { $0["op"] == "saveSession" }.compactMap { $0["state"] },
            ops.filter { $0["op"] == "saveLearn" }.compactMap { $0["state"] }
        )
    }

    @Test func storedWebSessionStatesDecodeAsTypedStates() throws {
        let (sessions, learns) = try Self.webSessionStates()
        #expect(!sessions.isEmpty)
        #expect(learns.count == 2)
        let env = StoreEnv()
        let set = try env.store.createSet(title: "A", cards: Kit.sample)
        for json in sessions {
            let state = try json.decode(as: SessionState.self)
            #expect(JSONValue.identical(try JSONValue(encoding: state), json))
            try env.store.saveSession(set.id, state)
            #expect(env.store.getSessionJSON(set.id).map { JSONValue.identical($0, json) } == true)
            #expect(env.store.getSession(set.id) == state)
        }
        // Stored states are repaired on read, like the engine does (`copyState`).
        let partial: JSONValue = ["v": 1, "round": 2, "queue": ["x"], "finishedAt": nil]
        try env.store.saveSessionJSON(set.id, partial)
        #expect(env.store.getSession(set.id) == WriteSession.copyState(partial))
        try env.store.saveSessionJSON(set.id, "kaputt")
        #expect(env.store.getSession(set.id) == nil)
        for json in learns {
            let state = try json.decode(as: LearnState.self)
            #expect(JSONValue.identical(try JSONValue(encoding: state), json))
            try env.store.saveLearn(set.id, state)
            #expect(env.store.getLearnJSON(set.id).map { JSONValue.identical($0, json) } == true)
        }
    }
}

/// An in-memory backend that runs `duringSave` while it writes (to change the library mid-save).
private final class DuringSaveBackend: StorageBackend, @unchecked Sendable {
    let stored = MemoryBackend()
    var duringSave: (() -> Void)?

    func load() throws -> Data? { try stored.load() }

    func loadBackups() -> [Data] { stored.loadBackups() }

    func save(_ data: Data) throws {
        duringSave?()
        try stored.save(data)
    }
}
