import Foundation

/// Port of src/store/db.js: the library (sets, progress, Write and Learn sessions, settings,
/// activity) with the web app's semantics, persisted as one JSON document through a
/// `StorageBackend`. Every method returns copies (value types).
///
/// - Persistence: mutations change the in-memory library and notify subscribers; `save()` writes
///   the document (the app debounces it, ≤ 300 ms, and always saves on quit). With
///   `autosave: true` every mutation saves immediately and is undone when that save fails, so a
///   failed write never leaves half an operation behind.
/// - Loading never fails: corrupt parts read as empty or default (like the web app's
///   sanitisers), and an unreadable file is recovered from the newest readable backup (see
///   `recovery`).
/// - Thread safety: every operation runs under an internal lock; subscribers are called after
///   the operation, outside the lock, on the thread that made the change. `save()` encodes and
///   writes outside that lock, so it can run on a background thread without blocking the others.
/// - Sessions: Write (`session:<setId>`) and Learn (`learn:<setId>`) states are stored as the
///   raw JSON the engines produce; they end with the set, on a progress reset, when cards are
///   added or removed, and on import. They are never exported.
public final class LibraryStore: @unchecked Sendable {
    public static let SCHEMA_VERSION = 1
    /// The title of a set without one, in the app's language (it becomes the set's stored title;
    /// nothing compares it).
    public static var DEFAULT_TITLE: String { L("Unbenanntes Lernset") }

    public let backend: any StorageBackend
    public let autosave: Bool
    /// Time zone of the activity days (`dateKey` of `recordAnswer`).
    public let timeZone: TimeZone
    private let now: () -> Double
    private let makeID: () -> String

    private let lock = NSRecursiveLock()
    /// Serializes writes to the backend. Taken after `lock` (never the other way round).
    private let writeLock = NSLock()
    private var doc: LibraryDocument
    private var loadRecovery: LoadRecovery
    private var dirty = false
    /// Counts the changes that made the document dirty; a save clears `dirty` only when nothing
    /// changed while it was writing.
    private var revision = 0
    /// The newest revision in the backend (guarded by `writeLock`): an older snapshot is never
    /// written over it.
    private var writtenRevision = 0
    /// db.js `metaChecked`: the schema version is written with the first write of an instance.
    private var metaChecked = false
    private var depth = 0
    private var changed = ChangedKeys()
    private var listeners: [(token: Int, notify: (StoreChange) -> Void)] = []
    private var lastToken = 0

    /// Loads the library from `backend` (a corrupt document is recovered from the newest readable
    /// backup; see `recovery`). Never throws.
    ///
    /// - Parameters:
    ///   - now: epoch milliseconds (injectable for tests).
    ///   - makeID: the id generator for new sets and cards (`IDGen.uid()`).
    public init(
        backend: any StorageBackend, autosave: Bool = false, now: @escaping () -> Double = TimeUtil.nowMs,
        timeZone: TimeZone = .current, makeID: @escaping () -> String = { IDGen.uid() }
    ) {
        self.backend = backend
        self.autosave = autosave
        self.now = now
        self.timeZone = timeZone
        self.makeID = makeID
        (doc, loadRecovery) = Self.load(from: backend, fallbackNow: now(), makeID: makeID)
        if case .fromBackup = loadRecovery {
            // Write the recovered library back as the primary document.
            dirty = true
            revision = 1
            if autosave { try? save() }
        }
    }

    /// How the library was loaded.
    public var recovery: LoadRecovery {
        lock.withLock { loadRecovery }
    }

    /// Whether there are changes `save()` has not written yet.
    public var hasUnsavedChanges: Bool {
        lock.withLock { dirty }
    }

    /// Writes the library to the backend if it changed. Throws `.io` (or `.quota` when the disk
    /// is full) on failure; the changes stay in memory and are written by the next successful save.
    ///
    /// Encodes and writes a snapshot outside the store's lock, so it may run on a background
    /// thread while other threads keep reading and changing the library. Saves from several
    /// threads write one after the other, and a snapshot never replaces a newer one.
    public func save() throws {
        let pending: (doc: LibraryDocument, revision: Int)? = lock.withLock { dirty ? (doc, revision) : nil }
        guard let pending else { return }
        try write(pending.doc, revision: pending.revision)
        lock.withLock {
            if revision == pending.revision { dirty = false }
        }
    }

    /// Re-reads the library from the backend (e.g. after the file was replaced outside the app),
    /// discarding unsaved changes, and notifies subscribers with an `.external` change.
    public func reload() {
        lock.withLock {
            writeLock.withLock {
                (doc, loadRecovery) = Self.load(from: backend, fallbackNow: now(), makeID: makeID)
                metaChecked = false
                changed.removeAll()
                revision += 1
                if case .fromBackup = loadRecovery {
                    dirty = true
                } else {
                    dirty = false
                    writtenRevision = revision
                }
            }
        }
        emit(StoreChange(kind: .external, keys: nil))
    }

    // MARK: Sets

    /// Most recently studied/updated first (then newest created, then stored order).
    public func listSets() -> [VocabSet] {
        lock.withLock { sortedSets() }
    }

    public func getSet(_ setId: String) -> VocabSet? {
        lock.withLock { doc.sets.first { $0.id == setId } }
    }

    /// New set at the top (fresh card ids, empty cards dropped, texts trimmed, empty title →
    /// `DEFAULT_TITLE`).
    @discardableResult
    public func createSet(
        title: String = "", description: String = "", termLang: Lang = .fr, defLang: Lang = .de,
        cards: [CardDraft] = []
    ) throws -> VocabSet {
        try mutate {
            let t = now()
            let id = newSetId(taken: Set(doc.sets.map(\.id)))
            let cleanTitle = JSLoose.cleanText(title)
            let set = VocabSet(
                id: id, title: cleanTitle.isEmpty ? Self.DEFAULT_TITLE : cleanTitle,
                description: JSLoose.cleanText(description), termLang: termLang, defLang: defLang,
                cards: StoreSanitizer.buildCards(cards, keepIds: false, makeID: makeID), studyOptions: nil,
                createdAt: t, updatedAt: t, lastStudiedAt: nil)
            doc.sets.insert(set, at: 0)
            written(Key.sets)
            return set
        }
    }

    /// Updates a set (id preservation, progress pruning, session/learn clearing on structural
    /// card changes). Text, language and card changes bump `updatedAt`; options do not.
    /// Throws `.notFound`.
    @discardableResult
    public func updateSet(_ setId: String, _ patch: SetPatch) throws -> VocabSet {
        try mutate {
            let index = try requireSet(setId)
            let old = doc.sets[index]
            var next = old
            var contentChanged = false
            var removedIds: [String] = []
            var structural = false

            if let title = patch.title {
                let clean = JSLoose.cleanText(title)
                next.title = clean.isEmpty ? Self.DEFAULT_TITLE : clean
                contentChanged = true
            }
            if let description = patch.description {
                next.description = JSLoose.cleanText(description)
                contentChanged = true
            }
            if let lang = patch.termLang {
                next.termLang = lang
                contentChanged = true
            }
            if let lang = patch.defLang {
                next.defLang = lang
                contentChanged = true
            }
            if let options = patch.studyOptions {
                let sanitized = options.sanitized()
                next.studyOptions = sanitized.isEmpty ? nil : sanitized
            }
            if let cards = patch.cards {
                let previousById = Dictionary(old.cards.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                next.cards = StoreSanitizer.buildCards(
                    cards, keepIds: true, previousById: previousById, makeID: makeID)
                let nextIds = Set(next.cards.map(\.id))
                removedIds = old.cards.filter { !nextIds.contains($0.id) }.map(\.id)
                structural = !removedIds.isEmpty || next.cards.contains { previousById[$0.id] == nil }
                contentChanged = true
            }
            if contentChanged { next.updatedAt = now() }

            doc.sets[index] = next
            written(Key.sets)
            if !removedIds.isEmpty, var progress = doc.progress[setId] {
                var pruned = false
                for id in removedIds where progress.removeValue(forKey: id) != nil { pruned = true }
                if pruned {
                    doc.progress[setId] = progress
                    written(Key.progress(setId))
                }
            }
            if structural && doc.sessions[setId]?.isObject == true { removeSession(setId) }
            if structural && doc.learns[setId]?.isObject == true { removeLearn(setId) }
            return next
        }
    }

    /// Removes the set with its progress and sessions; false when it did not exist.
    @discardableResult
    public func deleteSet(_ setId: String) throws -> Bool {
        try mutate {
            let index = doc.sets.firstIndex { $0.id == setId }
            if let index {
                doc.sets.remove(at: index)
                written(Key.sets)
            }
            removeSetData(setId)
            return index != nil
        }
    }

    /// A copy named "<title> (Kopie)" at the top, with fresh card ids, the same options and stars,
    /// and no progress or sessions. Throws `.notFound`.
    @discardableResult
    public func duplicateSet(_ setId: String) throws -> VocabSet {
        try mutate {
            let set = doc.sets[try requireSet(setId)]
            let t = now()
            var copy = set
            copy.id = newSetId(taken: Set(doc.sets.map(\.id)))
            copy.title = L("%@ (Kopie)", set.title)
            copy.cards = StoreSanitizer.buildCards(set.cards.map(CardDraft.init), keepIds: false, makeID: makeID)
            copy.createdAt = t
            copy.updatedAt = t
            copy.lastStudiedAt = nil
            doc.sets.insert(copy, at: 0)
            written(Key.sets)
            return copy
        }
    }

    // MARK: Cards

    /// Edits one card (texts trimmed; a text change bumps `updatedAt`). Throws `.notFound` (set
    /// or card) or `.invalid` (both sides empty).
    @discardableResult
    public func updateCard(_ setId: String, _ cardId: String, _ changes: CardChanges) throws -> Card {
        try mutate {
            let index = try requireSet(setId)
            var set = doc.sets[index]
            guard let pos = set.cards.firstIndex(where: { $0.id == cardId }) else {
                throw LibraryStoreError(.notFound, StoreMessages.cardNotFound)
            }
            let card = set.cards[pos]
            let term = changes.term.map(JSLoose.cleanText) ?? card.term
            let definition = changes.definition.map(JSLoose.cleanText) ?? card.definition
            if term.isEmpty && definition.isEmpty { throw LibraryStoreError(.invalid, StoreMessages.emptyCard) }
            let next = Card(id: card.id, term: term, definition: definition, starred: changes.starred ?? card.starred)
            let textChanged = !JSCompat.identical(term, card.term) || !JSCompat.identical(definition, card.definition)
            set.cards[pos] = next
            if textChanged { set.updatedAt = now() }
            doc.sets[index] = set
            written(Key.sets)
            return next
        }
    }

    /// The new starred value (does not change `updatedAt`). Throws `.notFound`.
    @discardableResult
    public func toggleStar(_ setId: String, _ cardId: String) throws -> Bool {
        try mutate {
            let index = try requireSet(setId)
            guard let pos = doc.sets[index].cards.firstIndex(where: { $0.id == cardId }) else {
                throw LibraryStoreError(.notFound, StoreMessages.cardNotFound)
            }
            doc.sets[index].cards[pos].starred.toggle()
            written(Key.sets)
            return doc.sets[index].cards[pos].starred
        }
    }

    // MARK: Progress

    /// The stored progress of the set's cards (empty for unknown sets).
    public func getProgress(_ setId: String) -> ProgressMap {
        lock.withLock { doc.progress[setId] ?? [:] }
    }

    /// Applies an answer to the card's progress, bumps `lastStudiedAt` and the day's activity.
    /// `at` defaults to now (a non-finite value too). Throws `.notFound`.
    @discardableResult
    public func recordAnswer(_ setId: String, _ cardId: String, correct: Bool, at: Double? = nil) throws -> CardProgress {
        try mutate {
            let index = try requireSet(setId)
            guard doc.sets[index].cards.contains(where: { $0.id == cardId }) else {
                throw LibraryStoreError(.notFound, StoreMessages.cardNotFound)
            }
            let time = at.flatMap { $0.isFinite ? $0 : nil } ?? now()
            var progress = doc.progress[setId] ?? [:]
            let entry = Mastery.applyAnswer(progress[cardId], correct: correct, at: time)
            progress[cardId] = entry
            doc.progress[setId] = progress
            written(Key.progress(setId))
            doc.sets[index].lastStudiedAt = max(doc.sets[index].lastStudiedAt ?? 0, time)
            written(Key.sets)
            let day = TimeUtil.dateKey(time, timeZone: timeZone)
            doc.activity[day] = (doc.activity[day] ?? 0) + 1
            written(Key.activity)
            return entry
        }
    }

    /// "Ich hatte recht" on the stored progress: turns the card's last answer into a correct one.
    /// A no-op (returning the normalised progress) unless the last answer was incorrect.
    @discardableResult
    public func overrideLastAnswer(_ setId: String, _ cardId: String) throws -> CardProgress {
        try mutate {
            var progress = doc.progress[setId] ?? [:]
            guard let prev = progress[cardId], prev.lastResult == .incorrect else {
                return Mastery.normalizeProgress(progress[cardId])
            }
            let entry = Mastery.applyOverride(prev)
            progress[cardId] = entry
            doc.progress[setId] = progress
            written(Key.progress(setId))
            return entry
        }
    }

    /// Forgets the set's progress and ends its Write and Learn sessions (the set stays).
    public func resetProgress(_ setId: String) throws {
        try mutate { removeSetData(setId) }
    }

    /// Forgets the progress of just these cards (they count as new again) and ends the set's
    /// Write and Learn sessions, which were built on the old progress. Returns how many entries
    /// were removed; without a valid (non-empty) id nothing changes.
    @discardableResult
    public func resetCardProgress(_ setId: String, _ cardIds: [String]) throws -> Int {
        var ids: [String] = []
        var seen = Set<String>()
        for id in cardIds where !id.isEmpty && seen.insert(id).inserted { ids.append(id) }
        if ids.isEmpty { return 0 }
        return try mutate {
            var progress = doc.progress[setId] ?? [:]
            var removed = 0
            for id in ids where progress.removeValue(forKey: id) != nil { removed += 1 }
            if removed > 0 {
                if progress.isEmpty {
                    removeProgress(setId)
                } else {
                    doc.progress[setId] = progress
                    written(Key.progress(setId))
                }
            }
            removeSession(setId)
            removeLearn(setId)
            return removed
        }
    }

    // MARK: Write sessions

    /// The stored Write session, repaired like the engine does (`WriteSession.copyState`).
    public func getSession(_ setId: String) -> SessionState? {
        getSessionJSON(setId).map { WriteSession.copyState($0) }
    }

    /// Stores the state (nil clears it); ignored for unknown sets.
    public func saveSession(_ setId: String, _ state: SessionState?) throws {
        try saveSessionJSON(setId, try state.map(Self.encodeState))
    }

    /// The stored Write session state as JSON (nil when there is none or it is not an object).
    public func getSessionJSON(_ setId: String) -> JSONValue? {
        lock.withLock { Self.objectState(doc.sessions[setId]) }
    }

    /// Stores a raw Write session state; a non-object (or nil) clears the session. Ignored for
    /// unknown sets.
    public func saveSessionJSON(_ setId: String, _ state: JSONValue?) throws {
        guard let state, state.isObject else { return try clearSession(setId) }
        try mutate {
            guard doc.sets.contains(where: { $0.id == setId }) else { return }
            doc.sessions[setId] = state
            written(Key.session(setId))
        }
    }

    public func clearSession(_ setId: String) throws {
        try mutate { removeSession(setId) }
    }

    // MARK: Learn sessions

    /// The stored Learn session, repaired like the engine does (`LearnEngine.copyState`).
    public func getLearn(_ setId: String) -> LearnState? {
        getLearnJSON(setId).map { LearnEngine.copyState($0) }
    }

    /// Stores the state (nil clears it); ignored for unknown sets.
    public func saveLearn(_ setId: String, _ state: LearnState?) throws {
        try saveLearnJSON(setId, try state.map(Self.encodeState))
    }

    /// The stored Learn session state as JSON (nil when there is none or it is not an object).
    public func getLearnJSON(_ setId: String) -> JSONValue? {
        lock.withLock { Self.objectState(doc.learns[setId]) }
    }

    /// Stores a raw Learn session state; a non-object (or nil) clears the session. Ignored for
    /// unknown sets.
    public func saveLearnJSON(_ setId: String, _ state: JSONValue?) throws {
        guard let state, state.isObject else { return try clearLearn(setId) }
        try mutate {
            guard doc.sets.contains(where: { $0.id == setId }) else { return }
            doc.learns[setId] = state
            written(Key.learn(setId))
        }
    }

    public func clearLearn(_ setId: String) throws {
        try mutate { removeLearn(setId) }
    }

    // MARK: Settings and study options

    public func getSettings() -> Settings {
        lock.withLock { doc.settings }
    }

    /// Deep merge (`mergeSettings`): a valid theme wins; study = defaults ← settings ← patch.
    @discardableResult
    public func updateSettings(_ patch: SettingsPatch) throws -> Settings {
        try mutate {
            doc.settings = doc.settings.merging(patch)
            written(Key.settings)
            return doc.settings
        }
    }

    /// defaults ← settings.study ← set.studyOptions (settings.study for unknown sets).
    public func getStudyOptions(_ setId: String) -> StudyOptions {
        lock.withLock {
            let own = doc.sets.first { $0.id == setId }?.studyOptions
            return StudyOptions.full(StudyOptionsPatch(doc.settings.study), own)
        }
    }

    /// Deep-merges into the set's own options (never switching off both Learn question types);
    /// returns the effective options. Does not change `updatedAt`. Throws `.notFound`.
    @discardableResult
    public func updateStudyOptions(_ setId: String, _ patch: StudyOptionsPatch) throws -> StudyOptions {
        try mutate {
            let index = try requireSet(setId)
            let merged = (doc.sets[index].studyOptions ?? StudyOptionsPatch()).merging(patch)
            doc.sets[index].studyOptions = merged.isEmpty ? nil : merged
            written(Key.sets)
            return getStudyOptions(setId)
        }
    }

    /// A change in a set's options (Lernen's and Schreiben's options, the set's options): like
    /// `updateStudyOptions`, but an option set back to the standard's value (Einstellungen) is no
    /// longer the set's own (issue #8, 25.11.2026). Before, «Vorlesen» on and off again kept
    /// `{audio: false}`: the options said the set followed the standard, yet it stayed silent once
    /// the standard was switched on. `updateStudyOptions` stays the web app's `mergeStudy` (parity
    /// with store.json). Same as Windows' `UpdateOwnStudyOptions`.
    @discardableResult
    public func updateOwnStudyOptions(_ setId: String, _ patch: StudyOptionsPatch) throws -> StudyOptions {
        try mutate {
            let index = try requireSet(setId)
            let merged = (doc.sets[index].studyOptions ?? StudyOptionsPatch()).merging(patch)
                .droppingStandard(patch.sanitized(), standard: doc.settings.study)
            doc.sets[index].studyOptions = merged.isEmpty ? nil : merged
            written(Key.sets)
            return getStudyOptions(setId)
        }
    }

    // MARK: Activity

    /// Answers per local day ("YYYY-MM-DD" → count).
    public func getActivity() -> Activity {
        lock.withLock { doc.activity }
    }

    // MARK: Backup

    /// The web-compatible backup (sessions are never exported).
    public func exportAll() -> BackupDocument {
        lock.withLock {
            let sets = sortedSets()
            var progress: [String: ProgressMap] = [:]
            for set in sets {
                if let map = doc.progress[set.id], !map.isEmpty { progress[set.id] = map }
            }
            return BackupDocument(
                exportedAt: now(), sets: sets, progress: progress, settings: doc.settings, activity: doc.activity)
        }
    }

    /// Imports a web or Mac backup, all or nothing. Imported sets replace their local counterpart
    /// (same id) including its progress, and their sessions end. Throws `.invalidBackup` with a
    /// German message (nothing changes then).
    @discardableResult
    public func importAll(_ data: JSONValue, mode: ImportMode = .merge) throws -> ImportSummary {
        try mutate {
            let backup = try parseBackup(data)
            let existing = doc.sets
            let existingIds = Set(existing.map(\.id))
            let importedIds = Set(backup.sets.map(\.id))
            let updated = backup.sets.filter { existingIds.contains($0.id) }.count
            let summary = ImportSummary(setsAdded: backup.sets.count - updated, setsUpdated: updated)

            let nextSets: [VocabSet]
            if mode == .replace {
                nextSets = backup.sets
            } else {
                let importedById = Dictionary(backup.sets.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                nextSets = existing.map { importedById[$0.id] ?? $0 } + backup.sets.filter { !existingIds.contains($0.id) }
            }

            for set in backup.sets { removeSetData(set.id) }
            if mode == .replace {
                for set in existing { removeSetData(set.id) }
                removeOrphans(keeping: importedIds)
            }

            doc.sets = nextSets
            written(Key.sets)
            for set in backup.sets {
                guard let map = backup.progress[set.id] else { continue }
                doc.progress[set.id] = map
                written(Key.progress(set.id))
            }
            if mode == .replace {
                if let settings = backup.settings {
                    doc.settings = settings
                    written(Key.settings)
                } else {
                    doc.settings = .default
                    removed(Key.settings)
                }
                doc.activity = backup.activity
                written(Key.activity)
            } else {
                // Max per day keeps repeated imports of the same backup idempotent.
                for (day, n) in backup.activity { doc.activity[day] = max(doc.activity[day] ?? 0, n) }
                written(Key.activity)
            }
            return summary
        }
    }

    /// `importAll` for a typed backup (e.g. one exported by this app).
    @discardableResult
    public func importAll(_ backup: BackupDocument, mode: ImportMode = .merge) throws -> ImportSummary {
        let json: JSONValue
        do { json = try JSONValue(encoding: backup) } catch {
            throw LibraryStoreError(.invalidBackup, StoreMessages.notBackup)
        }
        return try importAll(json, mode: mode)
    }

    /// The sets a backup would bring in (validated against a throwaway in-memory store, like the
    /// web app's import preview). Throws `.invalidBackup`.
    public static func previewImport(_ data: JSONValue) throws -> [VocabSet] {
        let scratch = LibraryStore(backend: MemoryBackend())
        try scratch.importAll(data, mode: .replace)
        return scratch.listSets()
    }

    /// Everything `deleteSet` removes (nil for unknown sets).
    public func snapshotSet(_ setId: String) -> SetSnapshot? {
        lock.withLock {
            guard let set = doc.sets.first(where: { $0.id == setId }) else { return nil }
            return SetSnapshot(
                set: set, progress: doc.progress[setId] ?? [:], session: getSessionJSON(setId),
                learn: getLearnJSON(setId))
        }
    }

    /// Undoes a `deleteSet`: puts a snapshot back under the same id, with its progress and its
    /// running Write and Learn sessions, in one write operation. Throws `.invalid`.
    @discardableResult
    public func restoreSet(_ snapshot: SetSnapshot) throws -> VocabSet {
        let json: JSONValue
        do { json = try JSONValue(encoding: snapshot) } catch {
            throw LibraryStoreError(.invalid, StoreMessages.badSnapshot)
        }
        return try restoreSet(json: json)
    }

    /// `restoreSet` for a snapshot as JSON (sanitised like a stored set). Throws `.invalid`.
    @discardableResult
    public func restoreSet(json snapshot: JSONValue) throws -> VocabSet {
        try mutate {
            let snap = snapshot.objectValue ?? [:]
            guard let rawSet = snap["set"], rawSet["cards"]?.isArray == true,
                  let set = StoreSanitizer.sanitizeSet(rawSet, fallbackNow: now(), makeID: makeID)
            else { throw LibraryStoreError(.invalid, StoreMessages.badSnapshot) }
            let progress = StoreSanitizer.sanitizeProgressMap(snap["progress"], validIds: Set(set.cards.map(\.id)))

            let index = doc.sets.firstIndex { $0.id == set.id }
            removeSetData(set.id)
            if let index { doc.sets[index] = set } else { doc.sets.append(set) }
            written(Key.sets)
            if !progress.isEmpty {
                doc.progress[set.id] = progress
                written(Key.progress(set.id))
            }
            if let session = snap["session"], session.isObject {
                doc.sessions[set.id] = session
                written(Key.session(set.id))
            }
            if let learn = snap["learn"], learn.isObject {
                doc.learns[set.id] = learn
                written(Key.learn(set.id))
            }
            return set
        }
    }

    /// Removes every set, progress, session, setting and activity entry.
    public func clearAll() throws {
        try mutate {
            for set in doc.sets { removeSetData(set.id) }
            removeOrphans(keeping: [])
            doc.sets = []
            removed(Key.sets)
            doc.settings = .default
            removed(Key.settings)
            doc.activity = [:]
            removed(Key.activity)
        }
    }

    // MARK: Change notification

    /// Calls `listener` once per public write operation (after it finished, outside the store's
    /// lock); returns the unsubscribe function.
    @discardableResult
    public func subscribe(_ listener: @escaping (StoreChange) -> Void) -> @Sendable () -> Void {
        let token: Int = lock.withLock {
            lastToken += 1
            listeners.append((lastToken, listener))
            return lastToken
        }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.listeners.removeAll { $0.token == token } }
        }
    }

    /// The change notifications as an async stream (ends when the consumer stops iterating).
    public func changes() -> AsyncStream<StoreChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: StoreChange.self)
        let unsubscribe = subscribe { continuation.yield($0) }
        continuation.onTermination = { _ in unsubscribe() }
        return stream
    }

}

// MARK: - Internals

extension LibraryStore {
    /// Storage keys in web-app naming (`StoreChange.keys`).
    enum Key {
        static let sets = "sets"
        static let settings = "settings"
        static let activity = "activity"
        static let meta = "meta"
        static func progress(_ setId: String) -> String { "progress:" + setId }
        static func session(_ setId: String) -> String { "session:" + setId }
        static func learn(_ setId: String) -> String { "learn:" + setId }
    }

    /// The changed keys of one operation, in order of first change.
    struct ChangedKeys {
        private(set) var keys: [String] = []
        private var seen: Set<String> = []

        var isEmpty: Bool { keys.isEmpty }

        mutating func insert(_ key: String) {
            if seen.insert(key).inserted { keys.append(key) }
        }

        mutating func removeAll() {
            keys.removeAll()
            seen.removeAll()
        }
    }

    /// A validated, sanitised backup (`parseBackup`).
    struct ParsedBackup {
        var sets: [VocabSet]
        var progress: [String: ProgressMap]
        var settings: Settings?
        var activity: Activity
    }

    // MARK: Loading and saving

    static func load(
        from backend: any StorageBackend, fallbackNow: Double, makeID: () -> String
    ) -> (LibraryDocument, LoadRecovery) {
        var primaryCorrupt = false
        do {
            if let data = try backend.load() {
                if let json = parseDocument(data) {
                    return (StoreSanitizer.document(json, fallbackNow: fallbackNow, makeID: makeID), .none)
                }
                primaryCorrupt = true
            }
        } catch {
            primaryCorrupt = true
        }
        // The primary document is missing or unreadable: fall back to the newest readable backup.
        for (index, data) in backend.loadBackups().enumerated() {
            guard let json = parseDocument(data) else { continue }
            if primaryCorrupt { backend.preserveCorrupt() }
            return (StoreSanitizer.document(json, fallbackNow: fallbackNow, makeID: makeID), .fromBackup(index: index))
        }
        if primaryCorrupt {
            backend.preserveCorrupt()
            return (LibraryDocument(schemaVersion: 0), .reset)
        }
        return (LibraryDocument(schemaVersion: 0), .none)
    }

    /// A document must at least be a JSON object.
    static func parseDocument(_ data: Data) -> JSONValue? {
        guard let json = try? JSONValue.parse(data), json.isObject else { return nil }
        return json
    }

    static func encodeDocument(_ doc: LibraryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    /// A stored session state, if it is an object (`isObject(v) ? v : null` of db.js).
    static func objectState(_ value: JSONValue?) -> JSONValue? {
        guard let value, value.isObject else { return nil }
        return value
    }

    static func encodeState<T: Encodable>(_ state: T) throws -> JSONValue {
        do { return try JSONValue(encoding: state) } catch { throw LibraryStoreError(.invalid, StoreMessages.badState) }
    }

    /// The error of a failed backend write: a full disk becomes `.quota`, anything else `.io`.
    static func saveError(_ error: any Error) -> LibraryStoreError {
        if let error = error as? LibraryStoreError { return error }
        if isOutOfSpace(error as NSError) { return LibraryStoreError(.quota, StoreMessages.diskFull) }
        return LibraryStoreError(.io, StoreMessages.io)
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOSPC) || error.code == Int(EDQUOT)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    /// `save()` for autosave, under `lock`.
    private func saveLocked() throws {
        guard dirty else { return }
        try write(doc, revision: revision)
        dirty = false
    }

    /// Encodes `doc` and writes it to the backend, unless a newer revision is there already
    /// (two saves on different threads).
    private func write(_ doc: LibraryDocument, revision: Int) throws {
        try writeLock.withLock {
            guard revision > writtenRevision else { return }
            let data: Data
            do { data = try Self.encodeDocument(doc) } catch { throw LibraryStoreError(.io, StoreMessages.io) }
            do { try backend.save(data) } catch { throw Self.saveError(error) }
            writtenRevision = revision
        }
    }

    // MARK: Mutations

    /// Runs several write operations as one: a single change notification (and one autosave) at
    /// the end, and when one of them throws, all of them are undone. A study step writes its
    /// answer and its session this way, so the app rebuilds its derived data once per answer.
    public func batch<T>(_ body: () throws -> T) throws -> T {
        try mutate(body)
    }

    /// Runs one public write operation: groups its changes into a single notification and, at
    /// the outermost level, undoes everything when it throws (or when its autosave fails).
    private func mutate<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        let outer = depth == 0
        let before = outer ? (doc: doc, metaChecked: metaChecked, dirty: dirty) : nil
        depth += 1
        let outcome = Result(catching: body)
        depth -= 1
        var event: StoreChange?
        var failure: (any Error)?
        if let before {
            func rollback() {
                doc = before.doc
                metaChecked = before.metaChecked
                dirty = before.dirty
                changed.removeAll()
            }
            if case let .failure(error) = outcome {
                rollback()
                failure = error
            } else if !changed.isEmpty {
                dirty = true
                revision += 1
                if autosave {
                    do { try saveLocked() } catch {
                        rollback()
                        failure = error
                    }
                }
            }
            if !changed.isEmpty {
                event = StoreChange(kind: .local, keys: changed.keys)
                changed.removeAll()
            }
        }
        lock.unlock()
        if let event { emit(event) }
        if let failure { throw failure }
        return try outcome.get()
    }

    private func emit(_ event: StoreChange) {
        let targets = lock.withLock { listeners.map(\.notify) }
        for notify in targets { notify(event) }
    }

    /// A key was written (db.js `write`): the first write of an instance also stores the schema
    /// version (`meta`) when it is missing or different.
    private func written(_ key: String) {
        changed.insert(key)
        if !metaChecked {
            metaChecked = true
            if doc.schemaVersion != Self.SCHEMA_VERSION {
                doc.schemaVersion = Self.SCHEMA_VERSION
                changed.insert(Key.meta)
            }
        }
    }

    /// A key was removed (db.js `remove`; counts as a change even when it did not exist).
    private func removed(_ key: String) {
        changed.insert(key)
    }

    private func removeProgress(_ setId: String) {
        doc.progress[setId] = nil
        removed(Key.progress(setId))
    }

    private func removeSession(_ setId: String) {
        doc.sessions[setId] = nil
        removed(Key.session(setId))
    }

    private func removeLearn(_ setId: String) {
        doc.learns[setId] = nil
        removed(Key.learn(setId))
    }

    private func removeSetData(_ setId: String) {
        removeProgress(setId)
        removeSession(setId)
        removeLearn(setId)
    }

    /// Removes progress, session and learn entries of sets outside `keep`.
    private func removeOrphans(keeping keep: Set<String>) {
        for id in doc.progress.keys.filter({ !keep.contains($0) }).sorted() { removeProgress(id) }
        for id in doc.sessions.keys.filter({ !keep.contains($0) }).sorted() { removeSession(id) }
        for id in doc.learns.keys.filter({ !keep.contains($0) }).sorted() { removeLearn(id) }
    }

    private func requireSet(_ setId: String) throws -> Int {
        guard let index = doc.sets.firstIndex(where: { $0.id == setId }) else {
            throw LibraryStoreError(.notFound, StoreMessages.setNotFound)
        }
        return index
    }

    private func newSetId(taken: Set<String>) -> String {
        var id = makeID()
        while taken.contains(id) { id = makeID() }
        return id
    }

    /// `listSets` order: recency (max of lastStudiedAt and updatedAt) descending, then createdAt
    /// descending, then stored order.
    private func sortedSets() -> [VocabSet] {
        func recency(_ s: VocabSet) -> Double { max(s.lastStudiedAt ?? 0, s.updatedAt) }
        return doc.sets.enumerated().sorted { a, b in
            let ra = recency(a.element)
            let rb = recency(b.element)
            if ra != rb { return ra > rb }
            if a.element.createdAt != b.element.createdAt { return a.element.createdAt > b.element.createdAt }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `parseBackup`: validates and normalises a backup object; throws a German error if invalid.
    private func parseBackup(_ data: JSONValue) throws -> ParsedBackup {
        func invalid(_ message: String) -> LibraryStoreError { LibraryStoreError(.invalidBackup, message) }
        guard let o = data.objectValue, let app = o["app"]?.stringValue, JSCompat.identical(app, "wortschatz") else {
            throw invalid(StoreMessages.notBackup)
        }
        if let version = o["version"] {
            guard let n = version.finiteNumber, n >= 1 else { throw invalid(StoreMessages.notBackup) }
            if n > Double(Self.SCHEMA_VERSION) { throw invalid(StoreMessages.newerBackup) }
        }
        guard let rawSets = o["sets"]?.arrayValue else { throw invalid(StoreMessages.noSets) }
        for part in ["progress", "settings", "activity"] {
            if let value = o[part], !value.isNull, !value.isObject { throw invalid(StoreMessages.badPart(part)) }
        }
        let fallback = now()
        let rawProgress = o["progress"]?.objectValue
        var ids = Set<String>()
        var sets: [VocabSet] = []
        var progress: [String: ProgressMap] = [:]
        for (i, raw) in rawSets.enumerated() {
            guard var entry = raw.objectValue, entry["cards"]?.isArray == true else {
                throw invalid(StoreMessages.badSet(i + 1))
            }
            if let title = entry["title"], !title.isNull, title.stringValue == nil {
                throw invalid(StoreMessages.badSet(i + 1))
            }
            let originalId = entry["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let id: String
            if let originalId, !ids.contains(originalId) { id = originalId } else { id = newSetId(taken: ids) }
            ids.insert(id)
            entry["id"] = .string(id)
            guard let set = StoreSanitizer.sanitizeSet(.object(entry), fallbackNow: fallback, makeID: makeID) else {
                throw invalid(StoreMessages.badSet(i + 1))
            }
            sets.append(set)
            // Progress can only be matched when the set kept its original id.
            if id == originalId, let map = rawProgress?[id], map.isObject {
                let clean = StoreSanitizer.sanitizeProgressMap(map, validIds: Set(set.cards.map(\.id)))
                if !clean.isEmpty { progress[id] = clean }
            }
        }
        let settings = o["settings"].flatMap { $0.isObject ? Settings(json: $0) : nil }
        return ParsedBackup(
            sets: sets, progress: progress, settings: settings, activity: StoreSanitizer.sanitizeActivity(o["activity"]))
    }
}
