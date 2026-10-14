import Foundation
import WortschatzCore

/// Texts of the Settings window that depend on data (ports from src/screens/settings.js and
/// src/ui/study-options.js). Swiss spelling: "ss", never the sharp s.
enum SettingsCopy {
    // MARK: Appearance

    static func themeLabel(_ theme: ThemeSetting) -> String {
        switch theme {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    /// `themeHint`: what the choice means; for System also what the Mac shows right now.
    static func themeHint(_ theme: ThemeSetting, systemIsDark: Bool) -> String {
        switch theme {
        case .system: "Folgt deinem Mac – zurzeit \(systemIsDark ? "dunkel" : "hell")."
        case .light: "Immer helles Design."
        case .dark: "Immer dunkles Design – angenehm am Abend."
        }
    }

    /// The tooltip of an appearance choice.
    static func themeHelp(_ theme: ThemeSetting) -> String {
        switch theme {
        case .system: "Folgt dem Erscheinungsbild deines Mac."
        case .light: "Immer helles Design."
        case .dark: "Immer dunkles Design – angenehm am Abend."
        }
    }

    // MARK: Study defaults

    /// `sharedDefLang`: the defaults apply to every set, so the translation side is named by its
    /// language only when all sets share it (an empty library counts as Deutsch, the default of
    /// new sets); otherwise it is called "Übersetzung" (`.other`).
    static func sharedDefLang(_ sets: [VocabSet]) -> Lang {
        let langs = Set(sets.map(\.defLang))
        guard let first = langs.first else { return .de }
        return langs.count == 1 ? first : .other
    }

    /// The language every set is learned in (`.other` when they differ or there are no sets), so
    /// examples can fit the learner's sets.
    static func sharedTermLang(_ sets: [VocabSet]) -> Lang {
        let langs = Set(sets.map(\.termLang))
        return langs.count == 1 ? langs.first ?? .other : .other
    }

    /// `directionText(…, 'all')`: what the learner sees and answers with this direction.
    static func directionText(_ answerWith: AnswerWith, names: (term: LearnOptionsCopy.Side, definition: LearnOptionsCopy.Side)) -> String {
        switch answerWith {
        case .both: "Schreiben fragt jede Karte in beide Richtungen ab, Lernen wechselt die Richtung zufällig."
        case .definition, .term: LearnOptionsCopy.directionText(answerWith, names: names)
        }
    }

    // MARK: Data

    /// "Gespeichert: 3 Lernsets · 120 Begriffe · ca. 24 KB" (`updateSummary`).
    static func librarySummary(sets: [VocabSet], bytes: Int?) -> String {
        guard !sets.isEmpty else { return "Noch keine Lernsets gespeichert." }
        let cards = sets.reduce(0) { $0 + $1.cards.count }
        var parts = [Labels.plural(sets.count, "Lernset", "Lernsets"), Labels.plural(cards, "Begriff", "Begriffe")]
        if let bytes { parts.append(formatBytes(bytes)) }
        return "Gespeichert: " + parts.joined(separator: " · ")
    }

    /// `formatBytes`: "unter 1 KB", "ca. 24 KB", "ca. 1,2 MB".
    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "unter 1 KB" }
        if bytes < 1024 * 1024 { return "ca. \(Int((Double(bytes) / 1024).rounded())) KB" }
        let megabytes = (Double(bytes) / (1024 * 1024) * 10).rounded() / 10
        return "ca. " + String(format: "%.1f", megabytes).replacingOccurrences(of: ".", with: ",") + " MB"
    }

    /// The first question of "Alle Daten löschen" (`wipeEverything`): what will be gone.
    static func wipeMessage(sets: [VocabSet]) -> String {
        let cards = sets.reduce(0) { $0 + $1.cards.count }
        let terms = Labels.plural(cards, "Begriff", "Begriffen")
        return switch sets.count {
        case 0:
            "Deine Statistik und deine Einstellungen werden von diesem Mac gelöscht."
        case 1:
            "Dein Lernset mit \(terms), dein Lernfortschritt, deine Statistik und deine Einstellungen werden von diesem Mac gelöscht."
        default:
            "Alle \(sets.count) Lernsets mit \(terms), dein Lernfortschritt, deine Statistik und deine Einstellungen werden von diesem Mac gelöscht."
        }
    }

    /// The three steps of "Aus der Web-Version übernehmen" (shortened from `WebMigrationSheet`).
    static let webMigrationSteps: [(title: String, text: String)] = [
        ("Backup in der Web-Version sichern",
         "Im Browser unter Einstellungen → Backup & Daten auf «Exportieren» klicken."),
        ("Datei finden",
         "Die Datei «wortschatz-backup-…json» liegt danach in deinem Download-Ordner."),
        ("Hier importieren",
         "Lernsets, Fortschritt und Einstellungen werden übernommen."),
    ]

    /// The library folder for display: the user's home as "~" (the sandbox container path
    /// otherwise starts with the full home path).
    static func displayPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if let range = path.range(of: "/Library/Containers/") {
            return "~" + path[range.lowerBound...]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if path.hasPrefix(home) {
            return "~/" + path.dropFirst(home.count).drop { $0 == "/" }
        }
        return path
    }
}
