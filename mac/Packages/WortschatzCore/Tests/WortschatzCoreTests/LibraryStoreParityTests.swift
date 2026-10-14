import Foundation
import Testing
import WortschatzCore

@Suite("Parity: db.js and backup.js")
struct LibraryStoreParityTests {
    @Test("LibraryStore and Backup match src/store on every fixture case")
    func fixture() throws {
        try runParity("store", maxReported: 15) { c in
            switch c.fn {
            case "scenario":
                return try LibraryStoreScenario.run(c.arg(0))
            case "setToText":
                let cards = c.arg(0)["cards"]?.arrayValue?.compactMap(Card.init(json:)) ?? []
                let options = c.arg(1)
                return .string(
                    Backup.setToText(
                        cards: cards, termSep: options["termSep"]?.stringValue ?? "\t",
                        cardSep: options["cardSep"]?.stringValue ?? "\n"))
            case "readJsonFile":
                do {
                    return try Backup.readJSON(Data(try c.string(0).utf8))
                } catch let error as BackupFileError {
                    return ["throws": .string(error.message)]
                }
            case "jsonText":
                return .string(Backup.jsonText(c.arg(0)))
            case "webBackup":
                let at = try c.double(1)
                let store = LibraryStore(backend: MemoryBackend(), now: { at }, timeZone: zurich)
                try store.importAll(c.arg(0), mode: .replace)
                return try encodeToJSONValue(store.exportAll())
            default:
                return nil
            }
        }
    }
}

/// Replays a `scenario` case of Fixtures/store.json (see mac/Parity/gen-store.js) against a
/// LibraryStore and reports the steps in the generator's format.
enum LibraryStoreScenario {
    final class Clock {
        var now: Double = 0
    }

    /// `uid()` of src/lib/id.js as it runs under jsc (no `crypto`): 16 bytes from Math.random
    /// (here the scenario's mulberry32), the last 6 characters mixed with
    /// `(Date.now() + counter++) >>> 0`.
    final class JSUid {
        private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        private let rng: RNG
        private var counter: Int
        private let clock: Clock

        init(seed: Int, counter: Int, clock: Clock) {
            rng = mulberry32(seed: seed)
            self.counter = counter
            self.clock = clock
        }

        func next() -> String {
            var bytes = (0..<16).map { _ in UInt8(rng() * 256) }
            let stamp = UInt32(truncatingIfNeeded: Int64(clock.now) + Int64(counter))
            counter += 1
            for i in 0..<6 { bytes[15 - i] ^= UInt8((stamp >> UInt32(i * 6)) & 63) }
            return String(bytes.map { Self.alphabet[Int($0 & 63)] })
        }
    }

    final class EventLog {
        var events: [JSONValue] = []
    }

    static func run(_ spec: JSONValue) throws -> JSONValue {
        let clock = Clock()
        clock.now = spec["clock0"]?.numberValue ?? 0
        let uid = JSUid(seed: spec["seed"]?.integerValue ?? 0, counter: spec["idCounter"]?.integerValue ?? 0, clock: clock)
        let backend = MemoryBackend(data: try initialDocument(spec["initial"] ?? .null))
        let log = EventLog()
        func open() -> LibraryStore {
            let store = LibraryStore(backend: backend, now: { clock.now }, timeZone: zurich, makeID: uid.next)
            store.subscribe { change in
                let keys: JSONValue = change.keys.map { keys in
                    .array(keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map(JSONValue.string))
                } ?? .null
                log.events.append(["type": .string(change.kind.rawValue), "keys": keys])
            }
            return store
        }
        var store = open()
        var previous: [String: JSONValue] = [:]
        func delta(_ parts: [String: JSONValue]) -> JSONValue {
            var changed: [String: JSONValue] = [:]
            for (key, value) in parts {
                if let old = previous[key], JSONValue.identical(old, value) { continue }
                changed[key] = value
                previous[key] = value
            }
            return .object(changed)
        }

        var steps: [JSONValue] = [["events": [], "changed": delta(try parts(store, known: spec["known0"]))]]
        for op in spec["ops"]?.arrayValue ?? [] {
            clock.now = op["clock"]?.numberValue ?? clock.now
            log.events = []
            var step: [String: JSONValue] = [:]
            do {
                if op["op"] == "reload" {
                    try store.save()
                    store = open()
                } else if let result = try apply(op, to: store) {
                    step["result"] = result
                }
            } catch let error as LibraryStoreError {
                step["error"] = ["code": .string(error.code.rawValue), "message": .string(error.message)]
            }
            step["events"] = .array(log.events)
            step["changed"] = delta(try parts(store, known: op["known"]))
            steps.append(.object(step))
        }
        return .array(steps)
    }

    /// The Mac library document for the web storage keys of `initial` (see the generator).
    static func initialDocument(_ initial: JSONValue) throws -> Data? {
        guard let keys = initial.objectValue else { return nil }
        var doc: [String: JSONValue] = [:]
        var progress: [String: JSONValue] = [:]
        var sessions: [String: JSONValue] = [:]
        var learns: [String: JSONValue] = [:]
        for (key, value) in keys {
            switch key {
            case "sets", "settings", "activity":
                doc[key] = value
            case "meta":
                if let version = value["schemaVersion"], version.numberValue != nil { doc["schemaVersion"] = version }
            default:
                if key.hasPrefix("progress:") {
                    progress[String(key.dropFirst(9))] = value
                } else if key.hasPrefix("session:") {
                    sessions[String(key.dropFirst(8))] = value
                } else if key.hasPrefix("learn:") {
                    learns[String(key.dropFirst(6))] = value
                }
            }
        }
        doc["progress"] = .object(progress)
        doc["sessions"] = .object(sessions)
        doc["learns"] = .object(learns)
        return try JSONValue.object(doc).jsonData()
    }

    static func parts(_ store: LibraryStore, known: JSONValue?) throws -> [String: JSONValue] {
        let export = try encodeToJSONValue(store.exportAll())
        var progress: [String: JSONValue] = [:]
        var sessions: [String: JSONValue] = [:]
        var learns: [String: JSONValue] = [:]
        var options: [String: JSONValue] = [:]
        for id in known?.arrayValue?.compactMap(\.stringValue) ?? [] {
            let p = store.getProgress(id)
            if !p.isEmpty { progress[id] = try encodeToJSONValue(p) }
            if let s = store.getSessionJSON(id) { sessions[id] = s }
            if let l = store.getLearnJSON(id) { learns[id] = l }
            options[id] = try encodeToJSONValue(store.getStudyOptions(id))
        }
        return [
            "head": ["app": export["app"] ?? .null, "version": export["version"] ?? .null,
                     "exportedAt": export["exportedAt"] ?? .null],
            "sets": export["sets"] ?? .null,
            "exportProgress": export["progress"] ?? .null,
            "settings": export["settings"] ?? .null,
            "activity": export["activity"] ?? .null,
            "progress": .object(progress),
            "sessions": .object(sessions),
            "learns": .object(learns),
            "options": .object(options),
        ]
    }

    /// JS truthiness (`!!v`).
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case let .bool(b)?: return b
        case let .number(n)?: return n != 0 && !n.isNaN
        case let .string(s)?: return !s.isEmpty
        case .array?, .object?: return true
        }
    }

    /// Runs one operation; nil for operations without a result (JS `undefined`).
    static func apply(_ op: JSONValue, to store: LibraryStore) throws -> JSONValue? {
        let setId = op["setId"]?.stringValue ?? ""
        let cardId = op["cardId"]?.stringValue ?? ""
        switch op["op"]?.stringValue {
        case "createSet":
            let a = SetPatch(json: op["args"] ?? .null)
            return try encodeToJSONValue(
                store.createSet(
                    title: a.title ?? "", description: a.description ?? "", termLang: a.termLang ?? .fr,
                    defLang: a.defLang ?? .de, cards: a.cards ?? []))
        case "updateSet":
            return try encodeToJSONValue(store.updateSet(setId, SetPatch(json: op["patch"] ?? .null)))
        case "deleteSet":
            return .bool(try store.deleteSet(setId))
        case "duplicateSet":
            return try encodeToJSONValue(store.duplicateSet(setId))
        case "getSet":
            return try store.getSet(setId).map(encodeToJSONValue) ?? .null
        case "updateCard":
            return try encodeToJSONValue(store.updateCard(setId, cardId, CardChanges(json: op["changes"] ?? .null)))
        case "toggleStar":
            return .bool(try store.toggleStar(setId, cardId))
        case "recordAnswer":
            return try encodeToJSONValue(
                store.recordAnswer(setId, cardId, correct: truthy(op["correct"]), at: op["at"]?.finiteNumber))
        case "overrideLastAnswer":
            return try encodeToJSONValue(store.overrideLastAnswer(setId, cardId))
        case "resetProgress":
            try store.resetProgress(setId)
            return nil
        case "resetCardProgress":
            let ids = op["cardIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .number(Double(try store.resetCardProgress(setId, ids)))
        case "saveSession":
            try store.saveSessionJSON(setId, op["state"])
            return nil
        case "clearSession":
            try store.clearSession(setId)
            return nil
        case "saveLearn":
            try store.saveLearnJSON(setId, op["state"])
            return nil
        case "clearLearn":
            try store.clearLearn(setId)
            return nil
        case "updateSettings":
            return try encodeToJSONValue(store.updateSettings(SettingsPatch(json: op["patch"] ?? .null)))
        case "updateStudyOptions":
            let patch = StudyOptionsPatch(json: op["patch"] ?? .null) ?? StudyOptionsPatch()
            return try encodeToJSONValue(store.updateStudyOptions(setId, patch))
        case "importAll":
            let mode: ImportMode = op["mode"]?.stringValue == "replace" ? .replace : .merge
            return try encodeToJSONValue(store.importAll(op["data"] ?? .null, mode: mode))
        case "snapshotSet":
            return try store.snapshotSet(setId).map(encodeToJSONValue) ?? .null
        case "restoreSet":
            return try encodeToJSONValue(store.restoreSet(json: op["snapshot"] ?? .null))
        case "clearAll":
            try store.clearAll()
            return nil
        default:
            throw LibraryStoreScenarioError.unknownOp(op["op"] ?? .null)
        }
    }

    enum LibraryStoreScenarioError: Error {
        case unknownOp(JSONValue)
    }
}
