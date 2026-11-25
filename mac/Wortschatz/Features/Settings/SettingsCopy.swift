import Foundation
import WortschatzCore

/// Texts of the Settings window that depend on data (ports from src/screens/settings.js and
/// src/ui/study-options.js). Swiss spelling: "ss", never the sharp s.
enum SettingsCopy {
    // MARK: Appearance

    static func themeLabel(_ theme: ThemeSetting) -> String {
        switch theme {
        case .system: String(localized: "System", comment: "Appearance: follow the Mac")
        case .light: String(localized: "Hell", comment: "Appearance: light")
        case .dark: String(localized: "Dunkel", comment: "Appearance: dark")
        }
    }

    /// `themeHint`: what the choice means; for System also what the Mac shows right now.
    static func themeHint(_ theme: ThemeSetting, systemIsDark: Bool) -> String {
        switch theme {
        case .system:
            systemIsDark
                ? String(localized: "Folgt deinem Mac – zurzeit dunkel.") : String(localized: "Folgt deinem Mac – zurzeit hell.")
        case .light: String(localized: "Immer helles Design.")
        case .dark: String(localized: "Immer dunkles Design – angenehm am Abend.")
        }
    }

    /// The tooltip of an appearance choice.
    static func themeHelp(_ theme: ThemeSetting) -> String {
        switch theme {
        case .system: String(localized: "Folgt dem Erscheinungsbild deines Mac.")
        case .light: String(localized: "Immer helles Design.")
        case .dark: String(localized: "Immer dunkles Design – angenehm am Abend.")
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

    /// " Eigene Optionen haben: «Unité 3», «Unité 4»." – the sets whose options differ from the
    /// standard (they keep their own when the standard changes; the set's options show what
    /// differs and can reset it). Empty when there are none.
    static func ownOptionsText(_ sets: [SetSummary], standard: StudyOptions) -> String {
        let own = sets.filter { summary in
            summary.set.studyOptions != nil
                && !LearnOptionsCopy.deviations(
                    summary.options, standard: standard,
                    names: LearnOptionsCopy.sideNames(termLang: summary.set.termLang, defLang: summary.set.defLang),
                    termLang: summary.set.termLang
                ).isEmpty
        }
        .map { "«\(AppModel.shortTitle($0.set.title))»" }
        if own.isEmpty { return "" }
        if own.count <= 3 {
            let list = own.joined(separator: ", ")
            return String(localized: " Eigene Optionen haben: \(list).")
        }
        let firstThree = own.prefix(3).joined(separator: ", ")
        let more = own.count - 3
        return String(localized: " Eigene Optionen haben: \(firstThree) und \(more) weitere.")
    }

    /// `directionText(…, 'all')`: what the learner sees and answers with this direction.
    static func directionText(_ answerWith: AnswerWith, names: (term: LearnOptionsCopy.Side, definition: LearnOptionsCopy.Side)) -> String {
        switch answerWith {
        case .both: String(localized: "Schreiben fragt jede Karte in beide Richtungen ab, Lernen wechselt die Richtung zufällig.")
        case .definition, .term: LearnOptionsCopy.directionText(answerWith, names: names)
        }
    }

    // MARK: Data

    /// "Gespeichert: 3 Lernsets · 120 Begriffe · ca. 24 KB" (`updateSummary`).
    static func librarySummary(sets: [VocabSet], bytes: Int?) -> String {
        guard !sets.isEmpty else { return String(localized: "Noch keine Lernsets gespeichert.") }
        let cards = sets.reduce(0) { $0 + $1.cards.count }
        let setsText = Labels.plural(sets.count, "Lernset", "Lernsets")
        let cardsText = Labels.plural(cards, "Begriff", "Begriffe")
        if let bytes {
            let size = formatBytes(bytes)
            return String(localized: "Gespeichert: \(setsText) · \(cardsText) · \(size)")
        }
        return String(localized: "Gespeichert: \(setsText) · \(cardsText)")
    }

    /// `formatBytes`: "unter 1 KB", "ca. 24 KB", "ca. 1,2 MB".
    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return String(localized: "unter 1 KB") }
        if bytes < 1024 * 1024 {
            let kilobytes = Int((Double(bytes) / 1024).rounded())
            return String(localized: "ca. \(kilobytes) KB")
        }
        let megabytes = (Double(bytes) / (1024 * 1024) * 10).rounded() / 10
        // German shows a decimal comma (like the web app); English the formatting locale's separator.
        let separator = AppLanguage.current == "de" ? "," : AppLanguage.formattingLocale.decimalSeparator ?? "."
        let number = String(format: "%.1f", megabytes).replacingOccurrences(of: ".", with: separator)
        return String(localized: "ca. \(number) MB")
    }

    /// The first question of "Alle Daten löschen" (`wipeEverything`): what will be gone.
    static func wipeMessage(sets: [VocabSet]) -> String {
        let cards = sets.reduce(0) { $0 + $1.cards.count }
        let terms = Labels.plural(cards, "Begriff", "Begriffen")
        return switch sets.count {
        case 0:
            String(localized: "Deine Statistik und deine Einstellungen werden von diesem Mac gelöscht.")
        case 1:
            String(
                localized:
                    "Dein Lernset mit \(terms), dein Lernfortschritt, deine Statistik und deine Einstellungen werden von diesem Mac gelöscht."
            )
        default:
            String(
                localized:
                    "Alle \(sets.count) Lernsets mit \(terms), dein Lernfortschritt, deine Statistik und deine Einstellungen werden von diesem Mac gelöscht."
            )
        }
    }

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
