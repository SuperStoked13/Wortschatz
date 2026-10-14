import Foundation

// The stored-data sanitisers of src/store/db.js: corrupt or foreign data never crashes the app.
// Everything here works on `JSONValue` with the JS semantics of the web app (`String(v)`,
// `trim()`, `Number.isFinite`, …), so that web backups and damaged files load exactly as in the
// browser.

/// JS value conversions used by the store's loose inputs.
enum JSLoose {
    /// JS `String(v)` (`undefined` is the caller's business): numbers in JS notation, arrays
    /// joined with "," (null entries empty), objects as "[object Object]".
    static func string(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return JSCompat.numberToString(n)
        case let .string(s): return s
        case let .array(a): return a.map { $0.isNull ? "" : string($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// The text of a loose field before `cleanText`: absent or null → "", else `String(v)`.
    static func text(_ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "" }
        return string(v)
    }

    /// `cleanText` of db.js: CRLF and lone CR become LF, then JS `trim()`.
    static func cleanText(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var afterCR = false
        for u in s.unicodeScalars {
            if u == "\r" {
                out.append("\n")
                afterCR = true
                continue
            }
            if u == "\n" && afterCR {
                afterCR = false
                continue
            }
            afterCR = false
            out.append(u)
        }
        return JSCompat.trim(String(out))
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
}

/// Sanitisers of db.js (`buildCards`, `sanitizeSet`, `sanitizeProgressMap`, `sanitizeActivity`)
/// and the loader of the persisted document.
enum StoreSanitizer {
    /// `buildCards(input, { keepIds, previousById })`: trims texts, drops cards with both sides
    /// empty, keeps valid unique ids (when `keepIds`) and gives every other card a fresh id.
    /// `starred` falls back to the previous card with the same id, else false.
    static func buildCards(
        _ input: [CardDraft], keepIds: Bool, previousById: [String: Card]? = nil, makeID: () -> String
    ) -> [Card] {
        var out: [Card] = []
        var seen = Set<String>()
        for raw in input {
            let term = JSLoose.cleanText(raw.term)
            let definition = JSLoose.cleanText(raw.definition)
            if term.isEmpty && definition.isEmpty { continue }
            var cardId: String
            if keepIds, let candidate = raw.id, !candidate.isEmpty, !seen.contains(candidate) {
                cardId = candidate
            } else {
                repeat { cardId = makeID() } while cardId.isEmpty || seen.contains(cardId)
            }
            seen.insert(cardId)
            let starred = raw.starred ?? previousById?[cardId]?.starred ?? false
            out.append(Card(id: cardId, term: term, definition: definition, starred: starred))
        }
        return out
    }

    /// `buildCards` on raw JSON (non-arrays give no cards, non-objects are skipped).
    static func buildCards(_ input: JSONValue?, keepIds: Bool, makeID: () -> String) -> [Card] {
        buildCards(input?.arrayValue?.compactMap(CardDraft.init(json:)) ?? [], keepIds: keepIds, makeID: makeID)
    }

    /// `sanitizeSet(raw, fallbackNow)`: nil unless `raw` is an object with a non-empty string id.
    static func sanitizeSet(_ raw: JSONValue, fallbackNow: Double, makeID: () -> String) -> VocabSet? {
        guard let o = raw.objectValue, let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        let createdAt = o["createdAt"]?.finiteNumber ?? fallbackNow
        let studyOptions = o["studyOptions"].flatMap { StudyOptionsPatch(json: $0) }
        let title = JSLoose.cleanText(JSLoose.text(o["title"]))
        return VocabSet(
            id: id,
            title: title.isEmpty ? LibraryStore.DEFAULT_TITLE : title,
            description: JSLoose.cleanText(JSLoose.text(o["description"])),
            termLang: o["termLang"]?.stringValue.flatMap(Lang.init(rawValue:)) ?? .fr,
            defLang: o["defLang"]?.stringValue.flatMap(Lang.init(rawValue:)) ?? .de,
            cards: buildCards(o["cards"], keepIds: true, makeID: makeID),
            studyOptions: (studyOptions?.isEmpty ?? true) ? nil : studyOptions,
            createdAt: createdAt,
            updatedAt: o["updatedAt"]?.finiteNumber ?? createdAt,
            lastStudiedAt: o["lastStudiedAt"]?.finiteNumber)
    }

    /// `readSets`: valid sets in stored order, later duplicates of an id dropped. Every entry is
    /// sanitised first (so fresh card ids are drawn in the same order as in the web app).
    static func readSets(_ raw: JSONValue?, fallbackNow: Double, makeID: () -> String) -> [VocabSet] {
        guard let list = raw?.arrayValue else { return [] }
        var out: [VocabSet] = []
        var ids = Set<String>()
        for entry in list {
            guard let sanitized = sanitizeSet(entry, fallbackNow: fallbackNow, makeID: makeID) else { continue }
            if ids.insert(sanitized.id).inserted { out.append(sanitized) }
        }
        return out
    }

    /// `sanitizeProgressMap(raw, validIds)`: object entries become normalised progress records;
    /// with `validIds`, entries of other cards are dropped.
    static func sanitizeProgressMap(_ raw: JSONValue?, validIds: Set<String>? = nil) -> ProgressMap {
        guard let o = raw?.objectValue else { return [:] }
        var out: ProgressMap = [:]
        for (id, value) in o {
            if let validIds, !validIds.contains(id) { continue }
            if let p = CardProgress(json: value) { out[id] = p }
        }
        return out
    }

    /// `sanitizeActivity`: "YYYY-MM-DD" keys with a positive finite count (floored).
    static func sanitizeActivity(_ raw: JSONValue?) -> Activity {
        guard let o = raw?.objectValue else { return [:] }
        var out: Activity = [:]
        for (key, value) in o where isDateKey(key) {
            if let n = value.finiteNumber, n > 0 { out[key] = Int(min(n, 9_007_199_254_740_992).rounded(.down)) }
        }
        return out
    }

    /// `/^\d{4}-\d{2}-\d{2}$/` (ASCII digits, exact length).
    static func isDateKey(_ key: String) -> Bool {
        let units = Array(key.utf16)
        guard units.count == 10 else { return false }
        for (i, u) in units.enumerated() {
            if i == 4 || i == 7 {
                if u != 0x2D { return false }
            } else if !(0x30...0x39).contains(u) {
                return false
            }
        }
        return true
    }

    /// The persisted document from any JSON object, sanitised part by part like the web app
    /// reads its storage keys (garbage parts read as empty or default).
    static func document(_ json: JSONValue, fallbackNow: Double, makeID: () -> String) -> LibraryDocument {
        let o = json.objectValue ?? [:]
        var doc = LibraryDocument(schemaVersion: o["schemaVersion"]?.integerValue ?? 0)
        doc.sets = readSets(o["sets"], fallbackNow: fallbackNow, makeID: makeID)
        for (id, value) in o["progress"]?.objectValue ?? [:] {
            doc.progress[id] = sanitizeProgressMap(value)
        }
        doc.sessions = o["sessions"]?.objectValue ?? [:]
        doc.learns = o["learns"]?.objectValue ?? [:]
        doc.settings = Settings(json: o["settings"] ?? .null)
        doc.activity = sanitizeActivity(o["activity"])
        return doc
    }
}
