#if DEBUG
import Foundation
import WortschatzCore

/// In-memory sample libraries for previews and the snapshot harness (DEBUG only). The main
/// set is the user's own 52-pair list (tests/fixtures/user-example.txt).
enum SampleLibrary {
    enum Scenario {
        /// Several sets with progress, a streak and a running Write session.
        case populated
        /// `populated` plus a running Learn session (round 3) on the main set.
        case learning
        /// One set that was never studied (no session, no activity).
        case fresh
        /// No sets.
        case empty
        /// One set without cards.
        case emptySet

        /// The scenario named by `--sample-library <name>` (nil without the flag).
        init?(arguments: [String]) {
            guard let flag = arguments.firstIndex(of: "--sample-library") else { return nil }
            let name = flag + 1 < arguments.count ? arguments[flag + 1] : ""
            switch name {
            case "learning": self = .learning
            case "fresh": self = .fresh
            case "empty": self = .empty
            case "empty-set": self = .emptySet
            default: self = .populated
            }
        }
    }

    /// The user's list (French → German), in file order.
    static let userPairs: [(String, String)] = [
        ("le monsieur, messieurs", "der Herr"),
        ("l'homme", "der Mann"),
        ("la madame, mesdames", "Frau"),
        ("la femme", "die Frau"),
        ("la dame", "die Dame"),
        ("la mademoiselle, mesdemoiselles", "das Fräulein, die Frau"),
        ("l'enfant", "das Kind"),
        ("le garçon", "der Junge"),
        ("la fille", "das Mädchen"),
        ("appeler", "nennen"),
        ("s'appeler", "heissen"),
        ("le nom", "der Name"),
        ("le nom de famille", "der Familienname, der Nachname"),
        ("le prénom", "der Vorname"),
        ("marié, mariée", "verheiratet"),
        ("veuf, veuve", "verwitwet"),
        ("séparé, séparée", "getrennt"),
        ("la personne", "die Person"),
        ("l'adresse", "die Adresse, die Anschrift"),
        ("la rue", "die Strasse"),
        ("le numéro de la maison", "die Hausnummer"),
        ("brave", "lieb"),
        ("gentil, gentille", "lieb, nett"),
        ("bon, bonne", "gut, gütig"),
        ("aimable", "freundlich"),
        ("sage", "brav, artig"),
        ("le charme", "der Charme"),
        ("charmant, charmante", "charmant"),
        ("la raison", "die Vernunft"),
        ("raisonnable", "vernünftig"),
        ("sérieux, sérieuse", "ernst, ernsthaft"),
        ("sympathique", "sympathisch"),
        ("calme", "ruhig"),
        ("tranquille", "still"),
        ("comique", "komisch"),
        ("le courage", "der Mut"),
        ("courageux, courageuse", "mutig"),
        ("la bêtise", "die Dummheit"),
        ("bête", "dumm"),
        ("méchant, méchante", "böse, gemein"),
        ("lâche", "feige"),
        ("le visage", "das Gesicht"),
        ("la figure", "das Gesicht"),
        ("les cheveux", "das Haar, die Haare"),
        ("ressembler à", "ähneln, gleichen"),
        ("se ressembler", "sich ähnlich sein, sich gleichen"),
        ("joli, jolie", "hübsch"),
        ("la beauté", "die Schönheit"),
        ("beau, bel, belle", "schön"),
        ("attirant, attirante", "attraktiv, anziehend"),
        ("laid, laide", "hässlich"),
        ("moche", "hässlich"),
    ]

    private static let colours: [(String, String)] = [
        ("rouge", "rot"), ("bleu, bleue", "blau"), ("vert, verte", "grün"), ("jaune", "gelb"),
        ("noir, noire", "schwarz"), ("blanc, blanche", "weiss"), ("gris, grise", "grau"), ("orange", "orange"),
        ("violet, violette", "violett"), ("rose", "rosa"), ("marron", "braun"), ("beige", "beige"),
    ]

    private static let verbs: [(String, String)] = [
        ("être", "sein"), ("avoir", "haben"), ("aller", "gehen"), ("faire", "machen, tun"), ("dire", "sagen"),
        ("pouvoir", "können"), ("vouloir", "wollen"), ("savoir", "wissen"), ("venir", "kommen"), ("prendre", "nehmen"),
    ]

    private static let airport: [(String, String)] = [
        ("the departure lounge", "die Abflughalle"), ("the boarding pass", "die Bordkarte"),
        ("the luggage", "das Gepäck"), ("the gate", "das Gate, der Flugsteig"), ("to check in", "einchecken"),
        ("the delay", "die Verspätung"), ("the customs", "der Zoll"), ("the passport", "der Reisepass"),
        ("the aisle seat", "der Platz am Gang"), ("to land", "landen"),
    ]

    /// The id of the user's 52-card set in every scenario that has it.
    static let mainSetTitle = "Unité 3 – Les personnes"

    /// A store with the scenario's data, timed relative to `now`.
    static func store(_ scenario: Scenario, now: Double = TimeUtil.nowMs()) -> LibraryStore {
        var counter = 0
        let store = LibraryStore(
            backend: MemoryBackend(), now: { now }, timeZone: .current,
            makeID: {
                counter += 1
                return String(format: "sample%04d", counter)
            })
        do {
            try fill(store, scenario: scenario, now: now)
        } catch {
            assertionFailure("Sample library: \(error)")
        }
        return store
    }

    /// An app model on a sample store (nothing is saved).
    @MainActor
    static func model(_ scenario: Scenario, now: Double = TimeUtil.nowMs()) -> AppModel {
        AppModel(store: store(scenario, now: now), persistence: .disabled)
    }

    /// `--ui-test-library <name>`: an app model on a library file of its own, `<name>.json`
    /// next to the real library.json (which is never touched), saved like the real one, so UI
    /// tests can quit and relaunch the app. `--reset-library` deletes that file and its backups
    /// first; `--sample-library <scenario>` fills it when it holds no sets. nil without the flag
    /// or for a name other than letters, digits, "-" and "_".
    @MainActor
    static func persistentModel(arguments: [String]) -> AppModel? {
        guard let flag = arguments.firstIndex(of: "--ui-test-library"), flag + 1 < arguments.count else { return nil }
        let name = arguments[flag + 1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !name.isEmpty, name != "library", name.unicodeScalars.allSatisfy(allowed.contains),
            let folder = try? FileBackend.defaultURL().deletingLastPathComponent()
        else { return nil }
        let backend = FileBackend(url: folder.appending(path: "\(name).json", directoryHint: .notDirectory))
        if arguments.contains("--reset-library") {
            try? FileManager.default.removeItem(at: backend.url)
            backend.discardBackups()
        }
        let store = LibraryStore(backend: backend)
        if store.listSets().isEmpty, let scenario = Scenario(arguments: arguments) {
            do {
                try store.importAll(Self.store(scenario).exportAll(), mode: .replace)
            } catch {
                assertionFailure("Sample library: \(error)")
            }
        }
        return AppModel(store: store)
    }

    private static func drafts(_ pairs: [(String, String)], starred: Set<Int> = []) -> [CardDraft] {
        pairs.enumerated().map { index, pair in
            CardDraft(term: pair.0, definition: pair.1, starred: starred.contains(index))
        }
    }

    private static func fill(_ store: LibraryStore, scenario: Scenario, now: Double) throws {
        let hour = TimeUtil.HOUR
        let day = TimeUtil.DAY
        switch scenario {
        case .empty:
            return
        case .emptySet:
            try store.createSet(title: "Unité 4 – La maison", description: "Noch leer: Begriffe folgen.")
            return
        case .fresh:
            try store.createSet(
                title: mainSetTitle, description: "Wortschatz aus dem Französischbuch, Kapitel 3",
                cards: drafts(userPairs, starred: [3, 8, 20]))
            return
        case .populated, .learning:
            break
        }

        let airportSet = try store.createSet(
            title: "English – At the airport", termLang: .en, defLang: .de, cards: drafts(airport))
        for (index, card) in airportSet.cards.prefix(6).enumerated() {
            try store.recordAnswer(airportSet.id, card.id, correct: index % 3 != 0, at: now - 5 * day - Double(index) * 60_000)
        }

        let verbSet = try store.createSet(title: "Verbes – présent", description: "Die wichtigsten unregelmässigen Verben", cards: drafts(verbs))
        _ = verbSet

        let colourSet = try store.createSet(title: "Les couleurs", cards: drafts(colours))
        for (index, card) in colourSet.cards.enumerated() {
            // Two correct answers each, spread over the last four days (streak).
            let dayOffset = Double(1 + index % 4)
            try store.recordAnswer(colourSet.id, card.id, correct: true, at: now - dayOffset * day - 3 * hour)
            try store.recordAnswer(colourSet.id, card.id, correct: true, at: now - dayOffset * day - 2 * hour)
        }

        let main = try store.createSet(
            title: mainSetTitle, description: "Wortschatz aus dem Französischbuch, Kapitel 3",
            cards: drafts(userPairs, starred: [3, 8, 20, 37, 44]))
        let studied = now - 2 * hour
        for (index, card) in main.cards.enumerated() {
            switch index {
            case 0..<14:
                // Mastered: two correct answers in a row.
                try store.recordAnswer(main.id, card.id, correct: true, at: studied - 600_000)
                try store.recordAnswer(main.id, card.id, correct: true, at: studied - Double(index) * 1000)
            case 14..<30:
                // Am Lernen: one answer, some wrong.
                try store.recordAnswer(main.id, card.id, correct: index % 3 != 0, at: studied - Double(index) * 1000)
            default:
                break
            }
        }

        // A running Write session on the main set: round 1, nine answers.
        var session = WriteSession.createSession(
            main.cards, answerWith: .term, shuffle: true, rng: mulberry32(seed: 42), now: studied - 900_000)
        for step in 0..<9 {
            session = WriteSession.answer(session, correct: step % 4 != 3, now: studied - Double(9 - step) * 60_000)
        }
        try store.saveSession(main.id, session)

        if scenario == .learning {
            try store.saveLearn(main.id, learnState(main.cards, progress: store.getProgress(main.id), now: studied + 600_000))
        }
    }

    /// A Learn session in round 3 built by hand (written questions only), as `createLearn` and a
    /// few rounds would leave it.
    private static func learnState(_ cards: [Card], progress: ProgressMap, now: Double) -> LearnState {
        let ids = cards.map(\.id)
        var stage: [String: Int] = [:]
        var seen: [String: Bool] = [:]
        for id in ids {
            let streak = progress[id]?.streak ?? 0
            stage[id] = min(streak, 2)
            if progress[id] != nil { seen[id] = true }
        }
        let open = ids.filter { (stage[$0] ?? 0) < 2 }
        let round = Array(open.prefix(7))
        let queue = round.suffix(4).map {
            LearnQueueQuestion(qid: "3.1:\($0)", cardId: $0, type: .written, ask: .term)
        }
        let log = round.prefix(3).map {
            LearnRoundLogEntry(qid: "3.1:\($0)", cardId: $0, type: .written, ask: .term, correct: true, stageAfter: 2)
        }
        // The three answers of this round were the session's answers 19 to 21 (clock = answered).
        var lastAt: [String: Int] = [:]
        for (i, entry) in log.enumerated() { lastAt[entry.cardId] = 19 + i }
        return LearnState(
            subset: .all, answerWith: .term, learn: LearnSessionOptions(), order: ids, stage: stage,
            initiallyMastered: [], seen: seen, round: 3, queue: queue, clock: 22, lastAt: lastAt, roundLog: log,
            rounds: [
                LearnRoundRecord(round: 1, answered: 9, correct: 6, cardIds: Array(ids.prefix(7))),
                LearnRoundRecord(round: 2, answered: 10, correct: 8, cardIds: Array(ids.dropFirst(7).prefix(7))),
            ],
            answered: 22, correct: 17, misses: [:], last: nil, startedAt: now - 3_600_000, updatedAt: now,
            finishedAt: nil, elapsedMs: 1_200_000)
    }
}
#endif
