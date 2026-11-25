import Foundation

// Data model of the web app (src/store/db.js), with identical JSON keys so that web backups
// import unchanged and Swift results can be compared JSON-for-JSON with the JS reference.
//
// Decoding is lenient like the web app's sanitisers: missing or invalid fields get their
// defaults instead of failing. Store-level repairs (trimming texts, replacing empty or duplicate
// card ids, dropping empty cards, default titles) belong to LibraryStore, not to decoding.
// Every lenient type also has `init?(json:)` / `init(json:)` for code that works on `JSONValue`.

// MARK: - Languages

/// Language codes of a set side (`LANG_CODES` in db.js). Usable as a dictionary key that encodes
/// as a JSON object key (`[Lang: Double]` → `{"fr": 1.2, ...}`).
public enum Lang: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    case fr, en, es, it, ar, zh, de, other

    /// Written right to left (Arabic; `rtl` of the `LANGS` entry in labels.js).
    public var isRTL: Bool { self == .ar }
}

// MARK: - Cards and sets

public struct Card: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var term: String
    public var definition: String
    public var starred: Bool

    public init(id: String, term: String, definition: String, starred: Bool = false) {
        self.id = id
        self.term = term
        self.definition = definition
        self.starred = starred
    }

    enum CodingKeys: String, CodingKey { case id, term, definition, starred }

    /// Lenient: non-string id → "", term/definition → JS `String(v)` for numbers/booleans,
    /// otherwise ""; starred must be a boolean (else false). nil when `json` is not an object.
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        id = o["id"]?.stringValue ?? ""
        term = o["term"]?.jsPrimitiveString ?? ""
        definition = o["definition"]?.jsPrimitiveString ?? ""
        starred = o["starred"]?.boolValue ?? false
    }

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let card = Card(json: v) else { throw lenientTypeMismatch(Card.self, decoder) }
        self = card
    }
}

public struct VocabSet: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var termLang: Lang
    public var defLang: Lang
    public var cards: [Card]
    /// The set's own study options: a sanitised partial overriding Settings (nil = none).
    public var studyOptions: StudyOptionsPatch?
    /// Epoch milliseconds.
    public var createdAt: Double
    public var updatedAt: Double
    public var lastStudiedAt: Double?

    public init(
        id: String, title: String, description: String = "", termLang: Lang = .fr, defLang: Lang = .de,
        cards: [Card] = [], studyOptions: StudyOptionsPatch? = nil, createdAt: Double, updatedAt: Double? = nil,
        lastStudiedAt: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.termLang = termLang
        self.defLang = defLang
        self.cards = cards
        self.studyOptions = studyOptions
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastStudiedAt = lastStudiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, termLang, defLang, cards, studyOptions, createdAt, updatedAt, lastStudiedAt
    }

    /// Lenient like `sanitizeSet` minus the store repairs: invalid langs → fr/de, non-object
    /// cards skipped, studyOptions sanitised (empty → nil), createdAt → `fallbackNow`,
    /// updatedAt → createdAt, lastStudiedAt → nil when not a finite number.
    public init?(json: JSONValue, fallbackNow: Double = TimeUtil.nowMs()) {
        guard let o = json.objectValue else { return nil }
        id = o["id"]?.stringValue ?? ""
        title = o["title"]?.jsPrimitiveString ?? ""
        description = o["description"]?.jsPrimitiveString ?? ""
        termLang = o["termLang"]?.stringValue.flatMap(Lang.init(rawValue:)) ?? .fr
        defLang = o["defLang"]?.stringValue.flatMap(Lang.init(rawValue:)) ?? .de
        cards = (o["cards"]?.arrayValue ?? []).compactMap { Card(json: $0) }
        let opts = o["studyOptions"].flatMap { StudyOptionsPatch(json: $0) }
        studyOptions = (opts?.isEmpty ?? true) ? nil : opts
        createdAt = o["createdAt"]?.finiteNumber ?? fallbackNow
        updatedAt = o["updatedAt"]?.finiteNumber ?? createdAt
        lastStudiedAt = o["lastStudiedAt"]?.finiteNumber
    }

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let set = VocabSet(json: v) else { throw lenientTypeMismatch(VocabSet.self, decoder) }
        self = set
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(termLang, forKey: .termLang)
        try c.encode(defLang, forKey: .defLang)
        try c.encode(cards, forKey: .cards)
        try c.encodeNullable(studyOptions, forKey: .studyOptions)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeNullable(lastStudiedAt, forKey: .lastStudiedAt)
    }
}

// MARK: - Study options

public enum AnswerWith: String, Codable, Sendable, CaseIterable, Hashable {
    case term, definition, both
}

public struct Tolerance: Codable, Sendable, Equatable, Hashable {
    public var articles: Bool
    public var abbreviations: Bool
    public var multipleAnswers: Bool
    public var parentheses: Bool
    public var ignoreCase: Bool
    public var ignoreAccents: Bool
    public var typos: Bool

    public init(
        articles: Bool = true, abbreviations: Bool = true, multipleAnswers: Bool = true, parentheses: Bool = true,
        ignoreCase: Bool = true, ignoreAccents: Bool = false, typos: Bool = false
    ) {
        self.articles = articles
        self.abbreviations = abbreviations
        self.multipleAnswers = multipleAnswers
        self.parentheses = parentheses
        self.ignoreCase = ignoreCase
        self.ignoreAccents = ignoreAccents
        self.typos = typos
    }

    /// `DEFAULT_STUDY_OPTIONS.tolerance` (= `DEFAULT_TOLERANCE` of grading.js).
    public static let `default` = Tolerance()

    /// Keys in the web app's order (`TOLERANCE_KEYS`).
    public static let keys = ["articles", "abbreviations", "multipleAnswers", "parentheses", "ignoreCase", "ignoreAccents", "typos"]

    /// Every boolean key taken from `json`, the rest from the defaults (like `resolveTolerance`).
    public init(json: JSONValue) {
        let d = Tolerance.default
        let o = json.objectValue ?? [:]
        articles = o["articles"]?.boolValue ?? d.articles
        abbreviations = o["abbreviations"]?.boolValue ?? d.abbreviations
        multipleAnswers = o["multipleAnswers"]?.boolValue ?? d.multipleAnswers
        parentheses = o["parentheses"]?.boolValue ?? d.parentheses
        ignoreCase = o["ignoreCase"]?.boolValue ?? d.ignoreCase
        ignoreAccents = o["ignoreAccents"]?.boolValue ?? d.ignoreAccents
        typos = o["typos"]?.boolValue ?? d.typos
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }
}

/// Learn-mode options ("Lernen"): terms per round, question types (at least one stays on) and
/// whether a missed written answer has to be typed once.
public struct LearnOptions: Codable, Sendable, Equatable, Hashable {
    public var roundSize: Int
    public var mc: Bool
    public var written: Bool
    public var retype: Bool

    public init(roundSize: Int = 7, mc: Bool = true, written: Bool = true, retype: Bool = false) {
        self.roundSize = roundSize
        self.mc = mc
        self.written = written
        self.retype = retype
    }

    /// `DEFAULT_STUDY_OPTIONS.learn` (= `DEFAULT_LEARN` of learn.js).
    public static let `default` = LearnOptions()

    /// Per-field leniency: a finite number for roundSize (floored), booleans for the rest;
    /// anything else takes the default. No range check (the Learn engine normalises).
    public init(json: JSONValue) {
        let d = LearnOptions.default
        let o = json.objectValue ?? [:]
        if let n = o["roundSize"]?.finiteNumber {
            roundSize = Int(max(-1e15, min(1e15, n.rounded(.down))))
        } else {
            roundSize = d.roundSize
        }
        mc = o["mc"]?.boolValue ?? d.mc
        written = o["written"]?.boolValue ?? d.written
        retype = o["retype"]?.boolValue ?? d.retype
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }
}

/// Full study options (`DEFAULT_STUDY_OPTIONS` shape).
public struct StudyOptions: Codable, Sendable, Equatable, Hashable {
    public var answerWith: AnswerWith
    public var shuffle: Bool
    public var copyAnswer: Bool
    public var autoAdvance: Bool
    public var audio: Bool
    public var tolerance: Tolerance
    public var learn: LearnOptions

    public init(
        answerWith: AnswerWith = .term, shuffle: Bool = true, copyAnswer: Bool = true, autoAdvance: Bool = true,
        audio: Bool = false, tolerance: Tolerance = .default, learn: LearnOptions = .default
    ) {
        self.answerWith = answerWith
        self.shuffle = shuffle
        self.copyAnswer = copyAnswer
        self.autoAdvance = autoAdvance
        self.audio = audio
        self.tolerance = tolerance
        self.learn = learn
    }

    /// `DEFAULT_STUDY_OPTIONS` of db.js.
    public static let `default` = StudyOptions()

    /// Like the web app reading stored options: defaults ← sanitised `json`.
    public init(json: JSONValue) {
        self = StudyOptions.full(StudyOptionsPatch(json: json))
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    /// Fills a (merged) patch up with `fallback` values.
    public init(_ patch: StudyOptionsPatch, fallback: StudyOptions = .default) {
        let t = patch.tolerance ?? TolerancePatch()
        let l = patch.learn ?? LearnOptionsPatch()
        let ft = fallback.tolerance
        let fl = fallback.learn
        self.init(
            answerWith: patch.answerWith ?? fallback.answerWith,
            shuffle: patch.shuffle ?? fallback.shuffle,
            copyAnswer: patch.copyAnswer ?? fallback.copyAnswer,
            autoAdvance: patch.autoAdvance ?? fallback.autoAdvance,
            audio: patch.audio ?? fallback.audio,
            tolerance: Tolerance(
                articles: t.articles ?? ft.articles, abbreviations: t.abbreviations ?? ft.abbreviations,
                multipleAnswers: t.multipleAnswers ?? ft.multipleAnswers, parentheses: t.parentheses ?? ft.parentheses,
                ignoreCase: t.ignoreCase ?? ft.ignoreCase, ignoreAccents: t.ignoreAccents ?? ft.ignoreAccents,
                typos: t.typos ?? ft.typos),
            learn: LearnOptions(
                roundSize: l.roundSize ?? fl.roundSize, mc: l.mc ?? fl.mc, written: l.written ?? fl.written,
                retype: l.retype ?? fl.retype))
    }

    /// `mergeStudy(this, patch)` for full options: deep merge of a sanitised patch.
    public func merging(_ patch: StudyOptionsPatch?) -> StudyOptions {
        guard let patch else { return self }
        return StudyOptions(StudyOptionsPatch(self).merging(patch), fallback: .default)
    }

    /// `fullStudyOptions(...layers)` of db.js: defaults ← layer 1 ← layer 2 …
    public static func full(_ layers: StudyOptionsPatch?...) -> StudyOptions {
        full(layers)
    }

    /// `fullStudyOptions(...layers)` with an array of layers.
    public static func full(_ layers: [StudyOptionsPatch?]) -> StudyOptions {
        var out = StudyOptions.default
        for layer in layers { out = out.merging(layer ?? StudyOptionsPatch()) }
        return out
    }
}

/// `DEFAULT_STUDY_OPTIONS` of db.js.
public let DEFAULT_STUDY_OPTIONS = StudyOptions.default

public struct TolerancePatch: Codable, Sendable, Equatable, Hashable {
    public var articles: Bool?
    public var abbreviations: Bool?
    public var multipleAnswers: Bool?
    public var parentheses: Bool?
    public var ignoreCase: Bool?
    public var ignoreAccents: Bool?
    public var typos: Bool?

    public init(
        articles: Bool? = nil, abbreviations: Bool? = nil, multipleAnswers: Bool? = nil, parentheses: Bool? = nil,
        ignoreCase: Bool? = nil, ignoreAccents: Bool? = nil, typos: Bool? = nil
    ) {
        self.articles = articles
        self.abbreviations = abbreviations
        self.multipleAnswers = multipleAnswers
        self.parentheses = parentheses
        self.ignoreCase = ignoreCase
        self.ignoreAccents = ignoreAccents
        self.typos = typos
    }

    public init(_ full: Tolerance) {
        self.init(
            articles: full.articles, abbreviations: full.abbreviations, multipleAnswers: full.multipleAnswers,
            parentheses: full.parentheses, ignoreCase: full.ignoreCase, ignoreAccents: full.ignoreAccents,
            typos: full.typos)
    }

    public var isEmpty: Bool { self == TolerancePatch() }

    /// Boolean keys only; nil when `json` is not an object.
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        articles = o["articles"]?.boolValue
        abbreviations = o["abbreviations"]?.boolValue
        multipleAnswers = o["multipleAnswers"]?.boolValue
        parentheses = o["parentheses"]?.boolValue
        ignoreCase = o["ignoreCase"]?.boolValue
        ignoreAccents = o["ignoreAccents"]?.boolValue
        typos = o["typos"]?.boolValue
    }

    public init(from decoder: any Decoder) throws {
        self = TolerancePatch(json: try JSONValue(from: decoder)) ?? TolerancePatch()
    }

    /// `{ ...self, ...patch }`.
    public func overlaid(with patch: TolerancePatch?) -> TolerancePatch {
        guard let p = patch else { return self }
        return TolerancePatch(
            articles: p.articles ?? articles, abbreviations: p.abbreviations ?? abbreviations,
            multipleAnswers: p.multipleAnswers ?? multipleAnswers, parentheses: p.parentheses ?? parentheses,
            ignoreCase: p.ignoreCase ?? ignoreCase, ignoreAccents: p.ignoreAccents ?? ignoreAccents,
            typos: p.typos ?? typos)
    }
}

public struct LearnOptionsPatch: Codable, Sendable, Equatable, Hashable {
    public var roundSize: Int?
    public var mc: Bool?
    public var written: Bool?
    public var retype: Bool?

    /// Largest valid `roundSize` (`LEARN_ROUND_SIZE_MAX`).
    public static let roundSizeMax = 50

    public init(roundSize: Int? = nil, mc: Bool? = nil, written: Bool? = nil, retype: Bool? = nil) {
        self.roundSize = roundSize
        self.mc = mc
        self.written = written
        self.retype = retype
    }

    public init(_ full: LearnOptions) {
        self.init(roundSize: full.roundSize, mc: full.mc, written: full.written, retype: full.retype)
    }

    public var isEmpty: Bool { self == LearnOptionsPatch() }

    /// `sanitizeLearnPatch(json)`; nil when `json` is not an object.
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        if let n = o["roundSize"]?.integerValue, n >= 1, n <= LearnOptionsPatch.roundSizeMax { roundSize = n }
        mc = o["mc"]?.boolValue
        written = o["written"]?.boolValue
        retype = o["retype"]?.boolValue
        self = sanitized()
    }

    public init(from decoder: any Decoder) throws {
        self = LearnOptionsPatch(json: try JSONValue(from: decoder)) ?? LearnOptionsPatch()
    }

    /// `sanitizeLearnPatch`: roundSize must be 1…50; switching both question types off is not
    /// a valid choice, so that part of the patch is dropped.
    public func sanitized() -> LearnOptionsPatch {
        var out = self
        if let n = out.roundSize, !(1...LearnOptionsPatch.roundSizeMax).contains(n) { out.roundSize = nil }
        if out.mc == false && out.written == false {
            out.mc = nil
            out.written = nil
        }
        return out
    }

    /// `mergeLearn(self, patch)`: when the result would switch off both question types, the
    /// patch's choice wins and the other type is switched back on.
    public func merging(_ patch: LearnOptionsPatch?) -> LearnOptionsPatch {
        let p = patch ?? LearnOptionsPatch()
        var out = LearnOptionsPatch(
            roundSize: p.roundSize ?? roundSize, mc: p.mc ?? mc, written: p.written ?? written,
            retype: p.retype ?? retype)
        if out.mc == false && out.written == false {
            if p.mc == false {
                out.written = true
            } else if p.written == false {
                out.mc = true
            } else {
                out.mc = true
                out.written = true
            }
        }
        return out
    }
}

/// A deep partial `StudyOptions` (what a set stores as `studyOptions`, and the argument of
/// `updateStudyOptions` / `updateSettings`). Absent keys are omitted when encoded.
public struct StudyOptionsPatch: Codable, Sendable, Equatable, Hashable {
    public var answerWith: AnswerWith?
    public var shuffle: Bool?
    public var copyAnswer: Bool?
    public var autoAdvance: Bool?
    public var audio: Bool?
    public var tolerance: TolerancePatch?
    public var learn: LearnOptionsPatch?

    public init(
        answerWith: AnswerWith? = nil, shuffle: Bool? = nil, copyAnswer: Bool? = nil, autoAdvance: Bool? = nil,
        audio: Bool? = nil, tolerance: TolerancePatch? = nil, learn: LearnOptionsPatch? = nil
    ) {
        self.answerWith = answerWith
        self.shuffle = shuffle
        self.copyAnswer = copyAnswer
        self.autoAdvance = autoAdvance
        self.audio = audio
        self.tolerance = tolerance
        self.learn = learn
    }

    /// Every key of `full`.
    public init(_ full: StudyOptions) {
        self.init(
            answerWith: full.answerWith, shuffle: full.shuffle, copyAnswer: full.copyAnswer,
            autoAdvance: full.autoAdvance, audio: full.audio, tolerance: TolerancePatch(full.tolerance),
            learn: LearnOptionsPatch(full.learn))
    }

    /// No key set (`Object.keys(patch).length === 0`).
    public var isEmpty: Bool { self == StudyOptionsPatch() }

    /// `sanitizeStudyPatch(json)`: known keys with valid values only. nil when not an object.
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        answerWith = o["answerWith"]?.stringValue.flatMap(AnswerWith.init(rawValue:))
        shuffle = o["shuffle"]?.boolValue
        copyAnswer = o["copyAnswer"]?.boolValue
        autoAdvance = o["autoAdvance"]?.boolValue
        audio = o["audio"]?.boolValue
        tolerance = o["tolerance"].flatMap { TolerancePatch(json: $0) }
        learn = o["learn"].flatMap { LearnOptionsPatch(json: $0) }
        self = sanitized()
    }

    public init(from decoder: any Decoder) throws {
        self = StudyOptionsPatch(json: try JSONValue(from: decoder)) ?? StudyOptionsPatch()
    }

    /// `sanitizeStudyPatch`: empty tolerance/learn parts are dropped, learn is sanitised.
    public func sanitized() -> StudyOptionsPatch {
        var out = self
        if let t = out.tolerance, t.isEmpty { out.tolerance = nil }
        if let l = out.learn {
            let s = l.sanitized()
            out.learn = s.isEmpty ? nil : s
        }
        return out
    }

    /// `mergeStudy(self, patch)` of db.js: deep-merges the sanitised `patch` into `self`
    /// (a full or partial options object).
    public func merging(_ patch: StudyOptionsPatch) -> StudyOptionsPatch {
        let p = patch.sanitized()
        var out = self
        if let v = p.answerWith { out.answerWith = v }
        if let v = p.shuffle { out.shuffle = v }
        if let v = p.copyAnswer { out.copyAnswer = v }
        if let v = p.autoAdvance { out.autoAdvance = v }
        if let v = p.audio { out.audio = v }
        if tolerance != nil || p.tolerance != nil {
            out.tolerance = (tolerance ?? TolerancePatch()).overlaid(with: p.tolerance)
        }
        if learn != nil || p.learn != nil {
            let merged = (learn ?? LearnOptionsPatch()).sanitized().merging(p.learn)
            out.learn = merged.isEmpty ? nil : merged
        }
        return out
    }

    /// The options `touched` sets that are here the same as in `standard` dropped: a set's own
    /// option set back to the standard is no longer its own (`LibraryStore.updateOwnStudyOptions`,
    /// issue #8). The values in effect stay the same. Port of Windows' `DroppingStandard`.
    public func droppingStandard(_ touched: StudyOptionsPatch, standard: StudyOptions) -> StudyOptionsPatch {
        func drop<T: Equatable>(_ touchedValue: T?, _ value: T?, _ standardValue: T) -> T? {
            touchedValue != nil && value == standardValue ? nil : value
        }
        var out = self
        out.answerWith = drop(touched.answerWith, answerWith, standard.answerWith)
        out.shuffle = drop(touched.shuffle, shuffle, standard.shuffle)
        out.copyAnswer = drop(touched.copyAnswer, copyAnswer, standard.copyAnswer)
        out.autoAdvance = drop(touched.autoAdvance, autoAdvance, standard.autoAdvance)
        out.audio = drop(touched.audio, audio, standard.audio)
        if let t = tolerance, let tt = touched.tolerance {
            let s = standard.tolerance
            let kept = TolerancePatch(
                articles: drop(tt.articles, t.articles, s.articles),
                abbreviations: drop(tt.abbreviations, t.abbreviations, s.abbreviations),
                multipleAnswers: drop(tt.multipleAnswers, t.multipleAnswers, s.multipleAnswers),
                parentheses: drop(tt.parentheses, t.parentheses, s.parentheses),
                ignoreCase: drop(tt.ignoreCase, t.ignoreCase, s.ignoreCase),
                ignoreAccents: drop(tt.ignoreAccents, t.ignoreAccents, s.ignoreAccents),
                typos: drop(tt.typos, t.typos, s.typos))
            out.tolerance = kept.isEmpty ? nil : kept
        }
        if let l = learn, let tl = touched.learn {
            let s = standard.learn
            let kept = LearnOptionsPatch(
                roundSize: drop(tl.roundSize, l.roundSize, s.roundSize), mc: drop(tl.mc, l.mc, s.mc),
                written: drop(tl.written, l.written, s.written), retype: drop(tl.retype, l.retype, s.retype))
            out.learn = kept.isEmpty ? nil : kept
        }
        return out
    }
}

// MARK: - Settings

public enum ThemeSetting: String, Codable, Sendable, CaseIterable, Hashable {
    case system, light, dark
}

public struct Settings: Codable, Sendable, Equatable, Hashable {
    public var theme: ThemeSetting
    public var study: StudyOptions

    public init(theme: ThemeSetting = .system, study: StudyOptions = .default) {
        self.theme = theme
        self.study = study
    }

    /// `DEFAULT_SETTINGS` of db.js.
    public static let `default` = Settings()

    /// Like `mergeSettings(DEFAULT_SETTINGS, json)` (how the web app reads stored settings).
    public init(json: JSONValue) {
        self = Settings.default.merging(SettingsPatch(json: json))
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    /// `mergeSettings(self, patch)`: a valid theme wins; study = defaults ← self.study ← patch.study.
    public func merging(_ patch: SettingsPatch?) -> Settings {
        let p = patch ?? SettingsPatch()
        return Settings(theme: p.theme ?? theme, study: StudyOptions.full(StudyOptionsPatch(study), p.study))
    }
}

/// `DEFAULT_SETTINGS` of db.js.
public let DEFAULT_SETTINGS = Settings.default

/// Argument of `updateSettings`.
public struct SettingsPatch: Codable, Sendable, Equatable, Hashable {
    public var theme: ThemeSetting?
    public var study: StudyOptionsPatch?

    public init(theme: ThemeSetting? = nil, study: StudyOptionsPatch? = nil) {
        self.theme = theme
        self.study = study
    }

    /// Valid theme and sanitised study part; non-objects give an empty patch.
    public init(json: JSONValue) {
        let o = json.objectValue ?? [:]
        theme = o["theme"]?.stringValue.flatMap(ThemeSetting.init(rawValue:))
        study = o["study"].flatMap { StudyOptionsPatch(json: $0) }
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }
}

// MARK: - Progress

public enum AnswerResult: String, Codable, Sendable, CaseIterable, Hashable {
    case correct, incorrect
}

public enum CardStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case new, learning, mastered
}

/// Persistent per-card progress (mastery.js). Encodes `lastResult`/`lastAnsweredAt` as explicit
/// `null` like the web app.
public struct CardProgress: Codable, Sendable, Equatable, Hashable {
    public var correct: Int
    public var incorrect: Int
    public var streak: Int
    public var streakBefore: Int
    public var lastResult: AnswerResult?
    /// Epoch milliseconds.
    public var lastAnsweredAt: Double?

    public init(
        correct: Int = 0, incorrect: Int = 0, streak: Int = 0, streakBefore: Int = 0, lastResult: AnswerResult? = nil,
        lastAnsweredAt: Double? = nil
    ) {
        self.correct = correct
        self.incorrect = incorrect
        self.streak = streak
        self.streakBefore = streakBefore
        self.lastResult = lastResult
        self.lastAnsweredAt = lastAnsweredAt
    }

    /// A fresh record (`normalizeProgress(undefined)`).
    public static let fresh = CardProgress()

    enum CodingKeys: String, CodingKey {
        case correct, incorrect, streak, streakBefore, lastResult, lastAnsweredAt
    }

    /// `normalizeProgress(json)` for objects (nil for anything else).
    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        correct = jsCount(o["correct"])
        incorrect = jsCount(o["incorrect"])
        streak = jsCount(o["streak"])
        streakBefore = jsCount(o["streakBefore"])
        lastResult = o["lastResult"]?.stringValue.flatMap(AnswerResult.init(rawValue:))
        lastAnsweredAt = o["lastAnsweredAt"]?.finiteNumber
    }

    public init(from decoder: any Decoder) throws {
        let v = try JSONValue(from: decoder)
        guard let p = CardProgress(json: v) else { throw lenientTypeMismatch(CardProgress.self, decoder) }
        self = p
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(correct, forKey: .correct)
        try c.encode(incorrect, forKey: .incorrect)
        try c.encode(streak, forKey: .streak)
        try c.encode(streakBefore, forKey: .streakBefore)
        try c.encodeNullable(lastResult, forKey: .lastResult)
        try c.encodeNullable(lastAnsweredAt, forKey: .lastAnsweredAt)
    }
}

/// Progress of a set's cards, keyed by card id (`progress:<setId>` in the web app).
public typealias ProgressMap = [String: CardProgress]

/// Answers per local calendar day: "YYYY-MM-DD" → count.
public typealias Activity = [String: Int]

// MARK: - Shared study-engine types

/// The side the learner answers (`ask` in session.js / learn.js): `.term` means the prompt is
/// the definition and the answer is the term.
public enum AskSide: String, Codable, Sendable, CaseIterable, Hashable {
    case term, definition
}

/// Which cards a Write or Learn session covers. Encodes as the JS value: a string
/// ("all" | "starred" | "learning" | "missed") or `{"cardIds": [...]}`.
public enum StudySubset: Codable, Sendable, Equatable, Hashable {
    case all
    case starred
    case learning
    case missed
    case cardIds([String])

    /// `normalizeSubset(json)`: objects become `.cardIds` (non-empty ids, numbers stringified),
    /// unknown values become `.all`.
    public init(json: JSONValue) {
        switch json {
        case let .string(s):
            switch s {
            case "starred": self = .starred
            case "learning": self = .learning
            case "missed": self = .missed
            default: self = .all
            }
        case let .object(o):
            let ids = (o["cardIds"]?.arrayValue ?? []).compactMap { v -> String? in
                switch v {
                case .null: return nil
                case let .string(s): return s.isEmpty ? nil : s
                default: return v.jsPrimitiveString
                }
            }
            self = .cardIds(ids)
        case .array:
            self = .cardIds([])
        default:
            self = .all
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .all: var c = encoder.singleValueContainer(); try c.encode("all")
        case .starred: var c = encoder.singleValueContainer(); try c.encode("starred")
        case .learning: var c = encoder.singleValueContainer(); try c.encode("learning")
        case .missed: var c = encoder.singleValueContainer(); try c.encode("missed")
        case let .cardIds(ids):
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(ids, forKey: AnyCodingKey("cardIds"))
        }
    }
}

/// A card's number of misses (`hardest` entries of the Write and Learn final stats).
public struct MissedCard: Codable, Sendable, Equatable, Hashable {
    public var cardId: String
    public var misses: Int

    public init(cardId: String, misses: Int) {
        self.cardId = cardId
        self.misses = misses
    }
}

// MARK: - Helpers

/// `count(v)` of mastery.js: a positive finite number, floored; anything else is 0.
func jsCount(_ v: JSONValue?) -> Int {
    guard let n = v?.finiteNumber, n > 0 else { return 0 }
    return Int(min(n, 9_007_199_254_740_992).rounded(.down))
}

func lenientTypeMismatch<T>(_ type: T.Type, _ decoder: any Decoder) -> DecodingError {
    DecodingError.typeMismatch(
        type, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a JSON object"))
}
