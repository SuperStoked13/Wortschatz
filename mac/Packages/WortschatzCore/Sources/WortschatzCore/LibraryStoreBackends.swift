import Foundation

// MARK: - Storage backends

/// Where the library document lives.
public protocol StorageBackend: AnyObject, Sendable {
    /// The stored document, or nil when nothing has been stored yet.
    func load() throws -> Data?
    /// Older copies of the document, newest first (used when the primary copy is missing or
    /// corrupt). Unreadable copies are left out.
    func loadBackups() -> [Data]
    /// Atomically replaces the stored document (rotating backups where supported).
    func save(_ data: Data) throws
    /// Moves an unreadable primary document aside, so that neither later saves nor the backup
    /// rotation treat it as valid data (it stays available for manual recovery). Best effort;
    /// the default does nothing.
    func preserveCorrupt()
    /// Deletes every older copy of the document (the backups and a set-aside corrupt copy), so
    /// that only the current document remains, e.g. after "Alle Daten löschen". Best effort;
    /// the default does nothing.
    func discardBackups()
}

extension StorageBackend {
    public func preserveCorrupt() {}
    public func discardBackups() {}
}

/// In-memory backend for tests and previews.
public final class MemoryBackend: StorageBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _backups: [Data]
    private var _corrupt: Data?
    private var _saveCount = 0
    private var _failNextSave: (any Error)?
    /// How many backups `save` keeps.
    public let backupCount: Int

    public init(data: Data? = nil, backups: [Data] = [], backupCount: Int = 3) {
        _data = data
        _backups = backups
        self.backupCount = backupCount
    }

    /// The current document.
    public var data: Data? {
        get { lock.withLock { _data } }
        set { lock.withLock { _data = newValue } }
    }

    /// Previous documents, newest first.
    public var backups: [Data] {
        get { lock.withLock { _backups } }
        set { lock.withLock { _backups = newValue } }
    }

    /// The document set aside by `preserveCorrupt()`.
    public var corrupt: Data? { lock.withLock { _corrupt } }

    /// Number of successful saves.
    public var saveCount: Int { lock.withLock { _saveCount } }

    /// When set, the next `save` throws this error (and clears it) without storing anything.
    public var failNextSave: (any Error)? {
        get { lock.withLock { _failNextSave } }
        set { lock.withLock { _failNextSave = newValue } }
    }

    public func load() throws -> Data? { data }

    public func loadBackups() -> [Data] { backups }

    public func save(_ data: Data) throws {
        try lock.withLock {
            if let error = _failNextSave {
                _failNextSave = nil
                throw error
            }
            if let old = _data, backupCount > 0 {
                _backups.insert(old, at: 0)
                if _backups.count > backupCount { _backups.removeLast(_backups.count - backupCount) }
            }
            _data = data
            _saveCount += 1
        }
    }

    public func preserveCorrupt() {
        lock.withLock {
            guard let current = _data else { return }
            _corrupt = current
            _data = nil
        }
    }

    public func discardBackups() {
        lock.withLock {
            _backups = []
            _corrupt = nil
        }
    }
}

/// The library file: atomic writes plus `backupCount` rotating backups next to it
/// (`library-backup-1.json` = newest … `library-backup-3.json` = oldest).
///
/// A save first copies the current file into the backup rotation when the newest backup is at
/// least `backupInterval` old, so the backups reach further back than the last few (debounced)
/// saves. A file that could not be read is moved aside to `library-corrupt.json`.
public final class FileBackend: StorageBackend, @unchecked Sendable {
    public let url: URL
    public let backupCount: Int
    /// Minimum age of the newest backup before the next save rotates (0 = every save).
    public let backupInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

    public init(
        url: URL, backupCount: Int = 3, backupInterval: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.backupCount = max(0, backupCount)
        self.backupInterval = max(0, backupInterval)
        self.clock = clock
    }

    /// `~/Library/Application Support/Wortschatz/library.json` (inside the sandbox container:
    /// `~/Library/Containers/app.wortschatz.mac/Data/Library/Application Support/Wortschatz/`).
    /// The folder is created by the first save.
    public static func defaultURL() throws -> URL {
        URL.applicationSupportDirectory.appending(components: "Wortschatz", "library.json", directoryHint: .notDirectory)
    }

    /// Backup file URLs, newest first.
    public var backupURLs: [URL] {
        (0..<backupCount).map { sibling(suffix: "-backup-\($0 + 1)") }
    }

    /// Where `preserveCorrupt()` puts an unreadable library file.
    public var corruptURL: URL { sibling(suffix: "-corrupt") }

    public func load() throws -> Data? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    public func loadBackups() -> [Data] {
        lock.withLock { backupURLs.compactMap { try? Data(contentsOf: $0) } }
    }

    public func save(_ data: Data) throws {
        try lock.withLock {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if backupCount > 0, fm.fileExists(atPath: url.path(percentEncoded: false)), rotationDue() {
                rotateBackups()
            }
            try data.write(to: url, options: [.atomic])
        }
    }

    public func preserveCorrupt() {
        lock.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
            try? fm.removeItem(at: corruptURL)
            try? fm.moveItem(at: url, to: corruptURL)
        }
    }

    public func discardBackups() {
        lock.withLock {
            let fm = FileManager.default
            for old in backupURLs + [corruptURL] {
                try? fm.removeItem(at: old)
            }
        }
    }

    // MARK: Private

    private func sibling(suffix: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = base + suffix + (ext.isEmpty ? "" : "." + ext)
        return url.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
    }

    private func rotationDue() -> Bool {
        guard let newest = backupURLs.first,
              let attributes = try? FileManager.default.attributesOfItem(atPath: newest.path(percentEncoded: false)),
              let date = attributes[.modificationDate] as? Date
        else { return true }
        return clock().timeIntervalSince(date) >= backupInterval
    }

    /// Best effort: a failed rotation never prevents the save itself.
    private func rotateBackups() {
        let fm = FileManager.default
        let urls = backupURLs
        guard let newest = urls.first, let oldest = urls.last else { return }
        try? fm.removeItem(at: oldest)
        for i in stride(from: urls.count - 2, through: 0, by: -1)
        where fm.fileExists(atPath: urls[i].path(percentEncoded: false)) {
            try? fm.moveItem(at: urls[i], to: urls[i + 1])
        }
        do {
            try fm.copyItem(at: url, to: newest)
            try fm.setAttributes([.modificationDate: clock()], ofItemAtPath: newest.path(percentEncoded: false))
        } catch {
            // Keep saving even without a fresh backup.
        }
    }
}
