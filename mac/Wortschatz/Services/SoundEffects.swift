import AVFoundation
import Foundation

/// Short, quiet interface sounds for studying: a soft two-note chime for a correct answer, a
/// muted low tone for a miss, a rising arpeggio for a streak milestone, a small fanfare after a
/// round and at the end of a session, and for the flashcards a chime or a warm tone with a swish
/// when a card is sorted and a breath of air when it comes back (turning a card over is silent). The tones are
/// synthesized once, in the background right after launch (soft bell timbre and filtered noise,
/// 20–240 KB of audio each), and played with `AVAudioPlayer`, so there are no audio files to ship.
/// The players live on a queue of their own (`Playback`): a key press only queues its sound.
///
/// The switch is Settings › Allgemein › "Soundeffekte" (`defaultsKey`, on by default). A set's
/// options can mute that set on this Mac too (`setKey(_:)`, say while listening to music): its
/// sounds stay off while the set is on screen (`currentSetID`).
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    /// `UserDefaults` key of the on/off switch (read with `@AppStorage` in Settings).
    static let defaultsKey = "soundEffects"

    nonisolated enum Sound: CaseIterable, Sendable {
        /// A correct answer.
        case correct
        /// A wrong answer.
        case wrong
        /// A streak milestone (5, 10, 15 … correct in a row).
        case streak
        /// A round is done (checkpoint, round summary).
        case roundDone
        /// The session is finished.
        case finished
        /// The first answer of the day extended the daily streak.
        case dailyStreak
        /// A flashcard is sorted to "Weiss ich".
        case know
        /// A flashcard is sorted to "Lerne ich noch".
        case stillLearning
        /// "Zurück": the last sorted flashcard comes back.
        case undo
    }

    /// The set on screen (the app model's route), whose own switch may mute it.
    var currentSetID: @MainActor () -> String? = { nil }

    var isEnabled: Bool {
        Self.isOnEverywhere && (currentSetID().map(Self.isOn(forSet:)) ?? true)
    }

    /// The switch in Settings (all sets).
    static var isOnEverywhere: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// `UserDefaults` key of a set's own switch ("Soundeffekte" in its options; false = muted on
    /// this Mac). Windows: preferences.json, the same key.
    static func setKey(_ setID: String) -> String { "\(defaultsKey).\(setID)" }

    /// Whether the set's own switch is on (it is unless switched off).
    static func isOn(forSet setID: String) -> Bool {
        UserDefaults.standard.object(forKey: setKey(setID)) as? Bool ?? true
    }

    /// The players (on their own queue).
    private let playback = Playback()
    /// Sounds whose players were requested from `playback`.
    private var loaded: Set<Sound> = []
    /// The tones as WAV files, synthesized off the main thread by `synthesizeAhead()`.
    private var waves: [Sound: Data] = [:]

    private init() {}

    /// Synthesizes the tones in the background (the app calls this at launch), so opening the
    /// first study screen only has to build the players.
    func synthesizeAhead() {
        guard isEnabled, waves.isEmpty else { return }
        let scores = Sound.allCases.map { ($0, Self.notes(for: $0), Self.swishes(for: $0)) }
        Task.detached(priority: .utility) {
            let waves = scores.map { ($0.0, Synth.wav($0.1, swishes: $0.2)) }
            await SoundEffects.shared.store(waves)
        }
    }

    private func store(_ synthesized: [(Sound, Data)]) {
        for (sound, data) in synthesized where waves[sound] == nil { waves[sound] = data }
    }

    /// Builds the players ahead of the first sound (a study screen calls this when it opens),
    /// so the first chime is not late.
    func prepare() {
        guard isEnabled else { return }
        for sound in Sound.allCases { load(sound) }
    }

    /// What a study step recorded, for its sound.
    enum StudyAnswer {
        /// Correct, or a miss counted as correct ("Ich hatte recht").
        case correct
        case wrong
        case dontKnow
    }

    /// The sound of one step of a study screen (Lernen, Schreiben): the fanfare when the
    /// session or a round is done, else the chime of the answer just recorded (a streak
    /// milestone gets its own). "Weiss ich nicht" stays quiet.
    func playStudyStep(finished: Bool, roundDone: Bool, answer: StudyAnswer?, reachedMilestone: Bool) {
        if finished { return play(.finished) }
        if roundDone { return play(.roundDone) }
        switch answer {
        case .correct: play(reachedMilestone ? .streak : .correct)
        case .wrong: play(.wrong)
        case .dontKnow, nil: break
        }
    }

    func play(_ sound: Sound) {
        guard isEnabled else { return }
        load(sound)
        playback.play(sound)
    }

    /// Has `playback` build the players of `sound` (once), from the tone synthesized ahead or,
    /// if that is not ready yet, synthesized on the playback queue.
    private func load(_ sound: Sound) {
        guard loaded.insert(sound).inserted else { return }
        let wave = waves[sound]
        let notes = Self.notes(for: sound)
        let swishes = Self.swishes(for: sound)
        playback.load(sound) { wave ?? Synth.wav(notes, swishes: swishes) }
    }

    // MARK: Tones

    private static func notes(for sound: Sound) -> [Synth.Note] {
        switch sound {
        case .correct:
            // A5 → E6, light and short.
            [.init(880.00, at: 0, gain: 0.20, decay: 0.11), .init(1318.51, at: 0.075, gain: 0.17, decay: 0.13)]
        case .wrong:
            // E♭4 → B♭3, soft and low, no buzz.
            [
                .init(311.13, at: 0, gain: 0.26, decay: 0.08, overtone: 0.08),
                .init(233.08, at: 0.09, gain: 0.24, decay: 0.10, overtone: 0.08),
            ]
        case .streak:
            // C6 E6 G6 C7.
            [
                .init(1046.50, at: 0, gain: 0.14, decay: 0.12), .init(1318.51, at: 0.065, gain: 0.14, decay: 0.12),
                .init(1567.98, at: 0.13, gain: 0.14, decay: 0.13), .init(2093.00, at: 0.195, gain: 0.12, decay: 0.22),
            ]
        case .roundDone:
            // G5 C6 E6.
            [
                .init(783.99, at: 0, gain: 0.16, decay: 0.14), .init(1046.50, at: 0.09, gain: 0.16, decay: 0.14),
                .init(1318.51, at: 0.18, gain: 0.15, decay: 0.26),
            ]
        case .finished:
            // C5 E5 G5, then C6 + E6 together.
            [
                .init(523.25, at: 0, gain: 0.15, decay: 0.14), .init(659.25, at: 0.09, gain: 0.15, decay: 0.14),
                .init(783.99, at: 0.18, gain: 0.15, decay: 0.16), .init(1046.50, at: 0.28, gain: 0.13, decay: 0.34),
                .init(1318.51, at: 0.28, gain: 0.10, decay: 0.34),
            ]
        case .dailyStreak:
            // D5 F♯5 A5 D6.
            [
                .init(587.33, at: 0, gain: 0.15, decay: 0.13), .init(739.99, at: 0.08, gain: 0.15, decay: 0.13),
                .init(880.00, at: 0.16, gain: 0.15, decay: 0.14), .init(1174.66, at: 0.24, gain: 0.13, decay: 0.28),
            ]
        case .undo:
            // Air only (`swishes`).
            []
        case .know:
            // The correct chime (A5 → E6), a little softer: it is the learner's own verdict.
            [.init(880.00, at: 0, gain: 0.16, decay: 0.10), .init(1318.51, at: 0.07, gain: 0.14, decay: 0.13)]
        case .stillLearning:
            // E5 → D5, warm and quiet: "not yet", not "wrong" (that is the low tone of a miss).
            [
                .init(659.25, at: 0, gain: 0.15, decay: 0.09, overtone: 0.07),
                .init(587.33, at: 0.075, gain: 0.13, decay: 0.12, overtone: 0.07),
            ]
        }
    }

    /// The air in a sound: a sorted card swishes up ("Weiss ich") or down ("Lerne ich noch") under
    /// its tones, a card coming back falls. Well below the chimes.
    private static func swishes(for sound: Sound) -> [Synth.Swish] {
        switch sound {
        case .know: [.init(from: 1500, to: 3200, at: 0.02, duration: 0.22, gain: 0.11)]
        case .stillLearning: [.init(from: 1500, to: 800, at: 0.02, duration: 0.22, gain: 0.14)]
        case .undo: [.init(from: 2200, to: 700, at: 0, duration: 0.2, gain: 0.13)]
        case .correct, .wrong, .streak, .roundDone, .finished, .dailyStreak: []
        }
    }
}

/// The players of `SoundEffects`, on a serial queue of their own. `AVAudioPlayer.play()` waits
/// for the output device's next I/O cycle: after a few quiet seconds that took 10–90 ms (AirPods,
/// measured 23.11.2026), and on the main thread it held back the frame that shows the answer to
/// the key just pressed.
private nonisolated final class Playback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.wortschatz.sound-effects", qos: .userInitiated)
    /// Two players per sound, so a quick second answer does not cut the first chime off. Only
    /// used on `queue`.
    private var players: [SoundEffects.Sound: [AVAudioPlayer]] = [:]

    func load(_ sound: SoundEffects.Sound, wave: @escaping @Sendable () -> Data) {
        queue.async { [self] in
            guard players[sound] == nil else { return }
            let data = wave()
            players[sound] = (0..<2).compactMap { _ in
                guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) else { return nil }
                player.volume = 0.55
                player.prepareToPlay()
                return player
            }
        }
    }

    func play(_ sound: SoundEffects.Sound) {
        queue.async { [self] in
            guard let pool = players[sound], let player = pool.first(where: { !$0.isPlaying }) ?? pool.first else { return }
            player.stop()
            player.currentTime = 0
            player.play()
        }
    }
}

/// A tiny synthesizer: decaying sine partials (a soft bell) and swishes of filtered noise,
/// rendered into a 16-bit mono WAV file in memory.
nonisolated enum Synth {
    struct Note {
        var frequency: Double
        var start: Double
        var gain: Double
        /// Time constant of the exponential decay, in seconds.
        var decay: Double
        /// Level of the second partial (brightness).
        var overtone: Double

        init(_ frequency: Double, at start: Double, gain: Double, decay: Double, overtone: Double = 0.18) {
            self.frequency = frequency
            self.start = start
            self.gain = gain
            self.decay = decay
            self.overtone = overtone
        }

        /// Until the note has decayed to silence (about −60 dB).
        var end: Double { start + decay * 7 }
    }

    /// A breath of air: noise through a band whose pitch glides from `from` to `to` (Hz),
    /// swelling to its peak in the first third and fading out smoothly (no click at either end).
    struct Swish {
        var from: Double
        var to: Double
        var start: Double
        var duration: Double
        var gain: Double
        /// Width of the band: lower is more air, higher more of a whistle.
        var q: Double

        init(from: Double, to: Double, at start: Double, duration: Double, gain: Double, q: Double = 0.8) {
            self.from = from
            self.to = to
            self.start = start
            self.duration = duration
            self.gain = gain
            self.q = q
        }

        var end: Double { start + duration }
    }

    static let sampleRate = 44_100.0

    static func wav(_ notes: [Note], swishes: [Swish] = []) -> Data {
        let length = ((notes.map(\.end) + swishes.map(\.end)).max() ?? 0) + 0.02
        let count = Int(length * sampleRate)
        var samples = [Double](repeating: 0, count: count)
        for swish in swishes {
            add(swish, to: &samples)
        }
        let attack = 0.004
        for note in notes {
            let first = Int(note.start * sampleRate)
            let last = min(count, Int(note.end * sampleRate))
            guard first < last else { continue }
            for i in first..<last {
                let t = Double(i) / sampleRate - note.start
                let envelope = min(1, t / attack) * exp(-t / note.decay)
                let phase = 2 * Double.pi * note.frequency * t
                let tone = sin(phase) + note.overtone * sin(2 * phase) * exp(-t / (note.decay * 0.5)) + 0.05 * sin(3 * phase)
                samples[i] += note.gain * envelope * tone
            }
        }
        // A short fade at the very end, so the last sample never clicks.
        let fade = min(count, Int(0.01 * sampleRate))
        for k in 0..<fade {
            samples[count - 1 - k] *= Double(k) / Double(fade)
        }
        // 16-bit little-endian PCM, converted in one pass.
        let pcm = samples
            .map { Int16(max(-1, min(1, $0)) * Double(Int16.max)).littleEndian }
            .withUnsafeBytes { Data($0) }
        return header(dataSize: pcm.count) + pcm
    }

    /// Adds `swish` to `samples`: white noise (the same every time) through two band-pass
    /// stages that glide with the pitch, under a smooth swell.
    private static func add(_ swish: Swish, to samples: inout [Double]) {
        let first = Int(swish.start * sampleRate)
        let length = Int(swish.duration * sampleRate)
        guard length > 0 else { return }
        let peak = 0.35
        var noise: UInt64 = 0x9E37_79B9_7F4A_7C15
        // Two biquad band-pass stages (constant peak gain), coefficients follow the glide.
        var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
        var (z1, z2, w1, w2) = (0.0, 0.0, 0.0, 0.0)
        for i in 0..<length where first + i < samples.count {
            let u = Double(i) / Double(length)
            let swell = u < peak
                ? pow(sin(.pi / 2 * u / peak), 2)
                : pow(cos(.pi / 2 * (u - peak) / (1 - peak)), 2)
            let frequency = swish.from * pow(swish.to / swish.from, u)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * swish.q)
            let b0 = alpha / (1 + alpha), b2 = -alpha / (1 + alpha)
            let a1 = -2 * cos(w0) / (1 + alpha), a2 = (1 - alpha) / (1 + alpha)
            noise ^= noise << 13
            noise ^= noise >> 7
            noise ^= noise << 17
            let x = Double(noise >> 11) / Double(UInt64(1) << 53) * 2 - 1
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            let v = b0 * y + b2 * z2 - a1 * w1 - a2 * w2
            (z2, z1, w2, w1) = (z1, y, w1, v)
            samples[first + i] += swish.gain * swell * v
        }
    }

    private static func header(dataSize: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(rate)
        append32(rate * 2) // bytes per second
        append16(2) // bytes per frame
        append16(16) // bits per sample
        append("data")
        append32(UInt32(dataSize))
        return data
    }
}
