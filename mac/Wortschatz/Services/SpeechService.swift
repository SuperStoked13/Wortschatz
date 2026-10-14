import AVFoundation
import Foundation
import Observation
import WortschatzCore

/// Read-aloud (🔊, ⌘R) with `AVSpeechSynthesizer`, a port of src/lib/speech.js: the best installed
/// voice per language (fr-FR, de-CH falling back to de-DE, en-GB, es-ES, it-IT), vocabulary
/// notation made speakable ("beau/belle" → "beau, belle"), a slightly slower rate, and every new
/// utterance cancels the previous one.
///
/// The app has one instance, `AppModel.speech`, shared by every screen:
/// ```swift
/// model.speech.speak(card.term, lang: set.termLang)
/// model.speech.stop()                                // when leaving a study screen
/// ```
/// Settings › Allgemein › Stimme: `voices(for:)` lists the choices, `setPreferredVoice(_:for:)`
/// stores one (nil = automatic).
@Observable
final class SpeechService {
    /// One installed voice, for the voice picker.
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        /// BCP 47 tag of the voice, e.g. "de-CH".
        let language: String
        let quality: Quality

        enum Quality: Int, Comparable, Hashable {
            case standard, enhanced, premium

            static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }

            /// German label for the voice picker.
            var label: String? {
                switch self {
                case .standard: nil
                case .enhanced: "Erweitert"
                case .premium: "Premium"
                }
            }
        }

        /// "Anna (Deutsch, Schweiz) – Premium"
        var displayName: String {
            let region = Locale(identifier: "de-CH").localizedString(forIdentifier: language) ?? language
            let base = "\(name) (\(region))"
            return quality.label.map { "\(base) – \($0)" } ?? base
        }
    }

    /// Like the web app (0.92 × the normal rate): vocabulary is easier to follow a little slower.
    static let rateFactor: Float = 0.92

    /// Whether an utterance is being spoken (for the 🔊 button state).
    private(set) var isSpeaking = false

    /// The voice chosen per language in the settings (voice identifiers); missing = automatic.
    private(set) var preferredVoiceIDs: [Lang: String]

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var voiceCache: [Lang: AVSpeechSynthesisVoice?] = [:]
    @ObservationIgnored private var voicesObserver: (any NSObjectProtocol)?

    private static let defaultsKey = "speechVoices"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        preferredVoiceIDs = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Lang(rawValue: key).map { ($0, value) }
        })
        let delegate = Delegate { [weak self] speaking in self?.isSpeaking = speaking }
        synthesizer.delegate = delegate
        self.delegate = delegate
        // Voices can be installed or removed while the app runs (System Settings › Accessibility).
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.voiceCache.removeAll() }
        }
    }

    isolated deinit {
        if let voicesObserver { NotificationCenter.default.removeObserver(voicesObserver) }
    }

    // MARK: - Speaking

    /// Speaks `text` in the language of `lang`, cancelling anything still speaking. Blank text is
    /// ignored.
    func speak(_ text: String, lang: Lang) {
        let spoken = Self.speakable(text)
        guard !spoken.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: spoken)
        if let voice = voice(for: lang) {
            utterance.voice = voice
        } else if let tag = Self.languageTag(for: lang) {
            utterance.voice = AVSpeechSynthesisVoice(language: tag)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.rateFactor
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
    }

    /// Stops speaking right away.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Voices

    /// The voice used for `lang`: the one chosen in the settings if it is still installed, else the
    /// best match. nil for `.other` (the system voice speaks).
    func voice(for lang: Lang) -> AVSpeechSynthesisVoice? {
        if let id = preferredVoiceIDs[lang], let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        if let cached = voiceCache[lang] { return cached }
        let best = Self.languageTag(for: lang).flatMap { Self.bestVoice(for: $0, among: AVSpeechSynthesisVoice.speechVoices()) }
        voiceCache[lang] = best
        return best
    }

    /// The installed voices that fit `lang`, best first.
    func voices(for lang: Lang) -> [Voice] {
        guard let tag = Self.languageTag(for: lang) else { return [] }
        let scored: [(voice: AVSpeechSynthesisVoice, score: Int)] = AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            let score = Self.score(voice, wanted: tag)
            return score >= 0 ? (voice, score) : nil
        }
        let ranked = scored.sorted { a, b in a.score != b.score ? a.score > b.score : a.voice.name < b.voice.name }
        return ranked.map { entry in
            Voice(id: entry.voice.identifier, name: entry.voice.name, language: entry.voice.language, quality: Self.quality(entry.voice))
        }
    }

    /// Stores the voice for `lang` (nil = automatic).
    func setPreferredVoice(_ id: String?, for lang: Lang) {
        preferredVoiceIDs[lang] = id
        defaults.set(Dictionary(uniqueKeysWithValues: preferredVoiceIDs.map { ($0.key.rawValue, $0.value) }), forKey: Self.defaultsKey)
    }

    // MARK: - Pure helpers

    /// The language to speak in (`LANGS[lang].bcp47`): fr-FR, de-CH, en-GB, es-ES, it-IT; nil for `.other`.
    static func languageTag(for lang: Lang) -> String? {
        guard let tag = Labels.LANGS[lang]?.bcp47, !tag.isEmpty else { return nil }
        return tag
    }

    /// Vocabulary notation read naturally: brackets dropped, "/" and ";" become pauses
    /// ("beau/belle" → "beau, belle"), whitespace collapsed.
    static func speakable(_ text: String) -> String {
        text.replacing(/[()\[\]{}]/, with: " ")
            .replacing(/\s*\/\s*/, with: ", ")
            .replacing(/\s*;\s*/, with: ", ")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The best voice for a BCP 47 tag, nil when no installed voice speaks the language.
    static func bestVoice(for wanted: String, among voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        var best: (voice: AVSpeechSynthesisVoice, score: Int)?
        for voice in voices {
            let score = score(voice, wanted: wanted)
            guard score >= 0 else { continue }
            // Ties go to the alphabetically first identifier, so the choice is stable.
            if let current = best, current.score > score || (current.score == score && current.voice.identifier <= voice.identifier) {
                continue
            }
            best = (voice, score)
        }
        return best?.voice
    }

    /// Port of `scoreVoice`: the exact language beats the same language from another region
    /// (Swiss German is rare, so Germany German gets a bonus for de-CH); premium and enhanced voices
    /// beat compact ones, compact ones super-compact ones; novelty and Eloquence voices come last;
    /// personal voices are never used.
    /// Negative: the voice does not speak the language.
    static func score(_ voice: AVSpeechSynthesisVoice, wanted: String) -> Int {
        let wantedTag = normalized(wanted)
        let tag = normalized(voice.language)
        let primary = wantedTag.split(separator: "-").first.map(String.init) ?? wantedTag
        var score: Int
        if tag == wantedTag {
            score = 100
        } else if tag.split(separator: "-").first.map(String.init) == primary {
            score = 50
        } else {
            return -1
        }
        if voice.voiceTraits.contains(.isPersonalVoice) { return -1 }
        if wantedTag == "de-ch" && tag == "de-de" { score += 20 }
        switch quality(voice) {
        case .premium: score += 30
        case .enhanced: score += 20
        case .standard: break
        }
        let id = voice.identifier.lowercased()
        if voice.voiceTraits.contains(.isNoveltyVoice) || id.contains("eloquence") || id.contains("novelty") { score -= 40 }
        // The smallest download of a voice sounds worse than its compact version.
        if id.contains("super-compact") { score -= 5 }
        return score
    }

    private static func quality(_ voice: AVSpeechSynthesisVoice) -> Voice.Quality {
        switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }

    private static func normalized(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Forwards the synthesizer's start / finish / cancel callbacks to the main actor.
    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        private let onChange: @MainActor (Bool) -> Void

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            report(true)
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            report(synthesizer.isSpeaking)
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            report(synthesizer.isSpeaking)
        }

        nonisolated private func report(_ speaking: Bool) {
            let onChange = onChange
            Task { @MainActor in onChange(speaking) }
        }
    }
}
