import Foundation
import FoundationModels
import OSLog
import WortschatzCore

/// Recognises written answers that are not in the set but mean the same – "ensemble" for
/// "gemeinsam" → "en commun" – with Apple's on-device language model (Apple Intelligence), so
/// they count as right, marked "Synonym – nicht im Set" (`ExtendedSynonyms`,
/// `GradeNote.extendedSynonym`).
///
/// The model only lists dictionary translations; it never judges an answer (asked directly it
/// accepts almost anything). Two lists decide:
/// - the prompt's translations into the answer language, fetched in the background as soon as a
///   written question shows (`prefetch`), so an answer among them is graded right at once;
/// - the learner's answer translated back, only after an otherwise wrong answer (`check`): it
///   counts when that gives the prompt again.
/// Lists are kept in the Caches folder, so each text is looked up once.
@MainActor
final class SynonymAssistant {
    static let shared = SynonymAssistant()

    /// Einstellungen › Allgemein › "Weitere Synonyme erkennen" (on by default).
    static let defaultsKey = "extendedSynonyms"
    /// The longest an answer waits for the model before it is graded without it.
    static let timeout: Duration = .seconds(3)
    /// The cache forgets everything beyond this many lists.
    private static let maxLists = 5000

    /// Translation lists by `listKey` ("de>fr|gemeinsam").
    private var lists: [String: [String]] = [:]
    /// Answers confirmed by translating them back, by `questionKey`.
    private var confirmed: [String: [String]] = [:]
    private var running: [String: Task<[String], Never>] = [:]
    /// Whether the model speaks a language whose support depends on the model (`modelSpeaks`).
    private var speaks: [Lang: Bool] = [:]
    private var isLoaded = false
    private var saveTask: Task<Void, Never>?
    private var warmSession: LanguageModelSession?

    nonisolated private static let log = Logger(subsystem: "Wortschatz", category: "Synonyms")

    private init() {}

    // MARK: Availability

    /// The setting is on.
    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }

    /// Apple Intelligence can run on this Mac now.
    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    var isActive: Bool { isEnabled && isAvailable }

    /// On for this set: the setting, Apple Intelligence and the set's own switch (Toleranz in its
    /// Lernen and Schreiben options). Synonym cards of the set count either way
    /// (`Synonyms.gradeWithSynonyms`); this only decides about words outside the set.
    func isActive(forSet setID: String) -> Bool { isActive && Self.isOn(forSet: setID) }

    /// `UserDefaults` key of a set's own switch (false = no synonyms outside this set, on this Mac).
    static func setKey(_ setID: String) -> String { "\(defaultsKey).\(setID)" }

    /// Whether the set's own switch is on (it is unless switched off).
    static func isOn(forSet setID: String) -> Bool {
        UserDefaults.standard.object(forKey: setKey(setID)) as? Bool ?? true
    }

    /// Whether the model is asked about `query`: `ExtendedSynonyms.supports` it and the model
    /// speaks both languages. Chinese depends on the model (`supportsLocale`); Arabic is not
    /// supported by the model (measured 2026-10-15) and has no model name, so it stays off.
    func supports(_ query: SynonymQuery) -> Bool {
        Self.supports(query) { modelSpeaks($0) }
    }

    /// `supports(_:)` with the model's languages given.
    static func supports(_ query: SynonymQuery, modelSpeaks: (Lang) -> Bool) -> Bool {
        ExtendedSynonyms.supports(query) && modelSpeaks(query.promptLang) && modelSpeaks(query.answerLang)
    }

    /// The locales the model is asked about: languages of `ExtendedSynonyms.modelLanguageNames`
    /// that not every model version speaks.
    static let checkedLocales: [Lang: String] = [.zh: "zh-Hans-CN"]

    /// Whether the on-device model speaks `lang` (asked once per language).
    private func modelSpeaks(_ lang: Lang) -> Bool {
        guard let identifier = Self.checkedLocales[lang] else { return true }
        if let known = speaks[lang] { return known }
        let known = SystemLanguageModel.default.supportsLocale(Locale(identifier: identifier))
        speaks[lang] = known
        return known
    }

    /// Why the model cannot run, for the settings (nil when it can).
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Schalte Apple Intelligence in den Systemeinstellungen ein, um diese Funktion zu nutzen.")
        case .unavailable(.deviceNotEligible):
            return String(localized: "Dieser Mac unterstützt Apple Intelligence nicht.")
        case .unavailable(.modelNotReady):
            return String(localized: "Apple Intelligence wird noch geladen – versuch es später nochmals.")
        default:
            return String(localized: "Apple Intelligence ist gerade nicht verfügbar.")
        }
    }

    // MARK: Grading

    /// The words outside the set that count for this question: the prompt's translations found
    /// so far and the answers confirmed by translating them back.
    func extraAnswers(for query: SynonymQuery) -> [String] {
        guard isActive, supports(query) else { return [] }
        loadIfNeeded()
        return (lists[Self.listKey(query.prompt, from: query.promptLang, to: query.answerLang)] ?? [])
            + (confirmed[Self.questionKey(query)] ?? [])
    }

    /// A written question is on screen: its prompt's translations are fetched in the background.
    func prefetch(_ query: SynonymQuery) {
        guard isActive, supports(query) else { return }
        loadIfNeeded()
        prewarm()
        _ = translations(of: query.prompt, from: query.promptLang, to: query.answerLang)
    }

    /// Looks up an otherwise wrong answer: is it among the prompt's translations, or does it
    /// translate back to the prompt? Afterwards `extraAnswers(for:)` lets it count. Gives up
    /// after `timeout` (the lookup still finishes and helps next time).
    @discardableResult
    func check(_ given: String, for query: SynonymQuery, tolerance: Tolerance) async -> Bool {
        guard isActive, supports(query) else { return false }
        loadIfNeeded()
        let forward = translations(of: query.prompt, from: query.promptLang, to: query.answerLang)
        let back = translations(of: given, from: query.answerLang, to: query.promptLang)
        let work = Task { [weak self] () -> Bool in
            let list = await forward.value
            if ExtendedSynonyms.matchingTranslation(given, in: list, tolerance: tolerance, lang: query.answerLang) != nil {
                return true
            }
            guard ExtendedSynonyms.confirmsPrompt(await back.value, prompt: query.prompt, lang: query.promptLang) else {
                return false
            }
            self?.confirm(given, for: query)
            return true
        }
        return await Self.value(of: work, timeout: Self.timeout) ?? false
    }

    // MARK: Model

    /// The cached list, or the running (or a new) model request for it.
    private func translations(of text: String, from: Lang, to: Lang) -> Task<[String], Never> {
        let key = Self.listKey(text, from: from, to: to)
        if let list = lists[key] { return Task { list } }
        if let task = running[key] { return task }
        let task = Task { [weak self] () -> [String] in
            let raw = await Self.askModel(text, from: from, to: to)
            let list = ExtendedSynonyms.cleanTranslations(raw ?? [], lang: to)
            self?.finish(key, list: list, keep: raw != nil)
            return list
        }
        running[key] = task
        return task
    }

    private func finish(_ key: String, list: [String], keep: Bool) {
        running[key] = nil
        guard keep else { return }
        if lists.count >= Self.maxLists { lists.removeAll() }
        lists[key] = list
        scheduleSave()
    }

    private func confirm(_ given: String, for query: SynonymQuery) {
        let key = Self.questionKey(query)
        let answer = JSCompat.trim(given)
        guard !(confirmed[key] ?? []).contains(answer) else { return }
        confirmed[key, default: []].append(answer)
        scheduleSave()
    }

    /// The model's translations of `text`; nil when it failed (not cached, so it is asked again).
    nonisolated private static func askModel(_ text: String, from: Lang, to: Lang) async -> [String]? {
        guard let request = ExtendedSynonyms.translationRequest(text, from: from, to: to) else { return [] }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: request, generating: TranslationList.self, options: GenerationOptions(samplingMode: .greedy))
            return response.content.translations
        } catch {
            log.error("Translation lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated private static let instructions = "You are a bilingual dictionary. Answer only with dictionary translations."

    /// Loads the model before the first lookup, so the first answer does not wait for it.
    private func prewarm() {
        guard warmSession == nil else { return }
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        warmSession = session
    }

    /// `task`'s value, or nil when it takes longer than `timeout`.
    private static func value<T: Sendable>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await task.value
                if once.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: Keys

    private static func listKey(_ text: String, from: Lang, to: Lang) -> String {
        "\(from.rawValue)>\(to.rawValue)|\(TextNormalizer.normalizeBasic(text))"
    }

    private static func questionKey(_ query: SynonymQuery) -> String {
        "\(query.promptLang.rawValue)>\(query.answerLang.rawValue)|\(TextNormalizer.normalizeBasic(query.prompt))"
            + "|\(TextNormalizer.normalizeBasic(query.expected))"
    }

    // MARK: Storage

    nonisolated private struct Stored: Codable, Sendable {
        var lists: [String: [String]]
        var confirmed: [String: [String]]
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Wortschatz", isDirectory: true)
            .appendingPathComponent("synonyms.json")
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        lists = stored.lists
        confirmed = stored.confirmed
    }

    /// Writes the cache a moment after the last change; encoded off the main thread (up to 5000
    /// lists, during Schreiben about once per question).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let url = Self.fileURL else { return }
            let stored = Stored(lists: lists, confirmed: confirmed)
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(stored) else { return }
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Self.log.error("Saving the synonym cache failed: \(String(describing: error), privacy: .public)")
                }
            }.value
        }
    }
}

/// The model's answer: a translation list.
@Generable
private struct TranslationList {
    @Guide(
        description: "Common translations, most common first, each a single dictionary entry without explanations",
        .maximumCount(6))
    var translations: [String]
}

/// Lets exactly one of two racing tasks resume a continuation.
@MainActor
private final class ResumeOnce {
    private var claimed = false

    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}
