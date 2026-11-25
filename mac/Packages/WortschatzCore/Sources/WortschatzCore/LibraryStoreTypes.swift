import Foundation

// Value types of the library store (port of src/store/db.js). The store itself lives in
// LibraryStore.swift, the persistence backends in LibraryStoreBackends.swift.

// MARK: - Errors and messages

/// A store error with the web app's message (`err.code` / `err.message` in db.js; German source,
/// translated by `StoreMessages`).
public struct LibraryStoreError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable {
        /// Storage full (JS 'QUOTA'; on the Mac: the disk is full).
        case quota = "QUOTA"
        case notFound = "NOT_FOUND"
        case invalid = "INVALID"
        case invalidBackup = "INVALID_BACKUP"
        /// Mac only: the library file could not be read or written.
        case io = "IO"
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { "\(code.rawValue): \(message)" }
}

/// Messages of db.js (`MSG`), plus the Mac-only file errors: German (Swiss spelling, no sharp s),
/// in the app's language through `L`.
public enum StoreMessages {
    /// The web app's message for a full browser storage (kept for parity; the Mac uses `diskFull`).
    public static var quota: String {
        L("Der Speicher dieses Browsers ist voll. Exportiere ein Backup und lösche Lernsets, die du nicht mehr brauchst.")
    }
    public static var setNotFound: String { L("Dieses Lernset wurde nicht gefunden.") }
    public static var cardNotFound: String { L("Diese Karte wurde nicht gefunden.") }
    public static var emptyCard: String { L("Begriff und Definition dürfen nicht beide leer sein.") }
    public static var notBackup: String { L("Diese Datei ist kein Wortschatz-Backup.") }
    public static var newerBackup: String {
        L("Dieses Backup stammt aus einer neueren Version von Wortschatz und kann nicht importiert werden.")
    }
    public static var noSets: String { L("Das Backup ist unvollständig: Die Lernsets fehlen.") }
    public static func badSet(_ n: Int) -> String { L("Das Backup ist beschädigt: Lernset Nr. %@ ist ungültig.", "\(n)") }
    public static func badPart(_ name: String) -> String { L("Das Backup ist beschädigt: Der Bereich «%@» ist ungültig.", name) }
    public static var badSnapshot: String { L("Dieses Lernset kann nicht wiederhergestellt werden.") }
    /// Mac only: the library file could not be written.
    public static var io: String { L("Die Daten konnten nicht gespeichert werden.") }
    /// Mac only: the disk is full (code `.quota`).
    public static var diskFull: String {
        L("Die Daten konnten nicht gespeichert werden, weil auf diesem Mac kein Speicherplatz mehr frei ist.")
    }
    /// Mac only: a study state could not be converted to JSON.
    public static var badState: String { L("Der Lernstand konnte nicht gespeichert werden.") }
}

// MARK: - Inputs

/// A card as passed to `createSet` / `updateSet` (the JS loose card objects): `id` is kept when
/// valid and unique (updateSet) or replaced (createSet); `starred` nil keeps the previous value.
/// Texts are trimmed by the store.
public struct CardDraft: Codable, Sendable, Equatable, Hashable {
    public var id: String?
    public var term: String
    public var definition: String
    public var starred: Bool?

    public init(id: String? = nil, term: String, definition: String, starred: Bool? = nil) {
        self.id = id
        self.term = term
        self.definition = definition
        self.starred = starred
    }

    public init(_ card: Card) {
        self.init(id: card.id, term: card.term, definition: card.definition, starred: card.starred)
    }

    /// A loose JS card object: a non-string `id` counts as missing, `term`/`definition` become
    /// JS `String(v)` (null or absent → ""), `starred` must be a boolean. nil for non-objects
    /// (which the store skips, like `buildCards`).
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        id = o["id"]?.stringValue
        term = JSLoose.text(o["term"])
        definition = JSLoose.text(o["definition"])
        starred = o["starred"]?.boolValue
    }
}

/// Argument of `updateSet` (nil = unchanged).
public struct SetPatch: Codable, Sendable, Equatable, Hashable {
    public var title: String?
    public var description: String?
    public var termLang: Lang?
    public var defLang: Lang?
    /// Replaces the set's own options (sanitised); an empty patch clears them (JS `null`).
    public var studyOptions: StudyOptionsPatch?
    /// The new card list: ids are preserved, progress of removed cards is pruned, and adding or
    /// removing cards ends the set's Write and Learn sessions.
    public var cards: [CardDraft]?

    public init(
        title: String? = nil, description: String? = nil, termLang: Lang? = nil, defLang: Lang? = nil,
        studyOptions: StudyOptionsPatch? = nil, cards: [CardDraft]? = nil
    ) {
        self.title = title
        self.description = description
        self.termLang = termLang
        self.defLang = defLang
        self.studyOptions = studyOptions
        self.cards = cards
    }

    /// A loose JS patch object (non-objects give an empty patch): present texts become JS
    /// `String(v)` (null → ""), invalid languages are ignored, any present `studyOptions` value
    /// replaces the set's options (garbage clears them), `cards` must be an array.
    public init(json: JSONValue) {
        let o = json.objectValue ?? [:]
        title = o["title"].map { JSLoose.text($0) }
        description = o["description"].map { JSLoose.text($0) }
        termLang = o["termLang"]?.stringValue.flatMap(Lang.init(rawValue:))
        defLang = o["defLang"]?.stringValue.flatMap(Lang.init(rawValue:))
        studyOptions = o["studyOptions"].map { StudyOptionsPatch(json: $0) ?? StudyOptionsPatch() }
        cards = o["cards"]?.arrayValue?.compactMap(CardDraft.init(json:))
    }
}

/// Argument of `updateCard` (nil = unchanged).
public struct CardChanges: Codable, Sendable, Equatable, Hashable {
    public var term: String?
    public var definition: String?
    public var starred: Bool?

    public init(term: String? = nil, definition: String? = nil, starred: Bool? = nil) {
        self.term = term
        self.definition = definition
        self.starred = starred
    }

    /// A loose JS changes object: present texts become JS `String(v)` (null → ""), `starred`
    /// must be a boolean.
    public init(json: JSONValue) {
        let o = json.objectValue ?? [:]
        term = o["term"].map { JSLoose.text($0) }
        definition = o["definition"].map { JSLoose.text($0) }
        starred = o["starred"]?.boolValue
    }
}

public enum ImportMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Imported sets replace their local counterpart (same id); other local sets stay. Settings
    /// stay local; activity keeps the maximum per day.
    case merge
    /// Everything local is replaced by the backup.
    case replace
}

// MARK: - Outputs

/// `{ setsAdded, setsUpdated }` of `importAll`.
public struct ImportSummary: Codable, Sendable, Equatable, Hashable {
    public var setsAdded: Int
    public var setsUpdated: Int

    public init(setsAdded: Int, setsUpdated: Int) {
        self.setsAdded = setsAdded
        self.setsUpdated = setsUpdated
    }
}

/// The backup format of the web app (`exportAll()`), importable by both apps. Write and Learn
/// sessions are never part of a backup.
public struct BackupDocument: Codable, Sendable, Equatable {
    public var app: String
    public var version: Int
    public var exportedAt: Double
    /// In `listSets()` order.
    public var sets: [VocabSet]
    /// setId → progress (only sets with progress).
    public var progress: [String: ProgressMap]
    public var settings: Settings
    public var activity: Activity

    public init(
        app: String = "wortschatz", version: Int = LibraryStore.SCHEMA_VERSION, exportedAt: Double, sets: [VocabSet],
        progress: [String: ProgressMap], settings: Settings, activity: Activity
    ) {
        self.app = app
        self.version = version
        self.exportedAt = exportedAt
        self.sets = sets
        self.progress = progress
        self.settings = settings
        self.activity = activity
    }
}

/// Everything `deleteSet` removes, for undo (`snapshotSet` / `restoreSet`). The running Write and
/// Learn sessions are kept as the stored JSON so that a restore brings them back verbatim; they
/// are encoded as explicit `null` when there is none (like the web app).
public struct SetSnapshot: Codable, Sendable, Equatable {
    public var set: VocabSet
    public var progress: ProgressMap
    /// The stored Write session state (`session:<setId>`), if any.
    public var session: JSONValue?
    /// The stored Learn session state (`learn:<setId>`), if any.
    public var learn: JSONValue?

    public init(set: VocabSet, progress: ProgressMap, session: JSONValue? = nil, learn: JSONValue? = nil) {
        self.set = set
        self.progress = progress
        self.session = session
        self.learn = learn
    }

    enum CodingKeys: String, CodingKey { case set, progress, session, learn }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(set, forKey: .set)
        try c.encode(progress, forKey: .progress)
        try c.encodeNullable(session, forKey: .session)
        try c.encodeNullable(learn, forKey: .learn)
    }
}

/// A change notification (once per public write operation, like db.js `subscribe`).
public struct StoreChange: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        /// A write of this store instance.
        case local
        /// The library was re-read from its backend (`reload()`).
        case external
    }

    public var kind: Kind
    /// Changed keys in web-app naming: "sets", "settings", "activity", "meta", "progress:<setId>",
    /// "session:<setId>", "learn:<setId>"; nil = everything may have changed.
    public var keys: [String]?

    public init(kind: Kind, keys: [String]?) {
        self.kind = kind
        self.keys = keys
    }

    /// Whether `key` changed (always true when `keys` is nil).
    public func touches(_ key: String) -> Bool {
        keys?.contains(key) ?? true
    }

    /// Whether the stored data of set `setId` besides the set itself may have changed: its
    /// progress, Write session or Learn session (always true when `keys` is nil).
    public func touchesSetData(_ setId: String) -> Bool {
        touches("progress:" + setId) || touches("session:" + setId) || touches("learn:" + setId)
    }
}

/// How the library was loaded.
public enum LoadRecovery: Sendable, Equatable, Hashable {
    /// The primary file was read (or nothing was stored yet).
    case none
    /// The primary file was missing or corrupt; backup number `index` (0 = newest) was used.
    case fromBackup(index: Int)
    /// The primary file was corrupt and no readable backup was found: the library starts empty
    /// (the corrupt file is kept aside by the backend).
    case reset
}

/// The persisted library (`library.json`). Write and Learn sessions are stored as the raw JSON
/// states (like the web app's `session:<setId>` / `learn:<setId>` keys); a key's presence in
/// `progress`, `sessions` or `learns` mirrors the presence of the web app's storage key.
public struct LibraryDocument: Codable, Sendable, Equatable {
    /// `meta.schemaVersion` of the web app (0 = not written yet).
    public var schemaVersion: Int
    public var sets: [VocabSet]
    /// setId → progress.
    public var progress: [String: ProgressMap]
    /// setId → Write session state.
    public var sessions: [String: JSONValue]
    /// setId → Learn session state.
    public var learns: [String: JSONValue]
    public var settings: Settings
    public var activity: Activity

    public init(
        schemaVersion: Int = LibraryStore.SCHEMA_VERSION, sets: [VocabSet] = [], progress: [String: ProgressMap] = [:],
        sessions: [String: JSONValue] = [:], learns: [String: JSONValue] = [:], settings: Settings = .default,
        activity: Activity = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sets = sets
        self.progress = progress
        self.sessions = sessions
        self.learns = learns
        self.settings = settings
        self.activity = activity
    }
}
