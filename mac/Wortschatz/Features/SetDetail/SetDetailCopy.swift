import Foundation
import WortschatzCore

/// German texts of the set detail (ports of the helpers in src/screens/set.js and
/// src/ui/study-options.js).
enum SetDetailCopy {
    /// "Eigene Optionen: Multiple Choice: aus · 10 Fragen pro Runde" under the study note: what
    /// this set does differently from the standard (`LearnOptionsCopy.deviations`).
    static func ownOptionsNote(_ deviations: [String]) -> String {
        let list = deviations.joined(separator: " · ")
        return String(localized: "Eigene Optionen: \(list)")
    }

    private static func isNamed(_ lang: Lang) -> Bool { lang != .other }

    /// `directionText(answerWith, termLang, defLang, 'learn')` with the side names of
    /// `sideNames` (study-options.js), one whole sentence per case: "Du siehst Deutsch und
    /// antwortest auf Französisch."
    static func learnDirection(_ answerWith: AnswerWith, termLang: Lang, defLang: Lang) -> String {
        if answerWith == .both { return String(localized: "Die Richtung wechselt zufällig von Frage zu Frage.") }
        if isNamed(termLang), termLang == defLang {
            return answerWith == .definition
                ? String(localized: "Du siehst den Begriff und antwortest mit der Definition.")
                : String(localized: "Du siehst die Definition und antwortest mit dem Begriff.")
        }
        let term: String? = isNamed(termLang) ? Labels.langName(termLang) : nil
        let definition: String? = isNamed(defLang) ? Labels.langName(defLang) : nil
        if answerWith == .definition {
            // The term side is shown, the definition side is answered.
            switch (term, definition) {
            case let (term?, definition?):
                return String(localized: "Du siehst \(term) und antwortest auf \(definition).")
            case let (term?, .none):
                return String(localized: "Du siehst \(term) und antwortest mit der Übersetzung.")
            case let (.none, definition?):
                return String(localized: "Du siehst den Begriff in der Lernsprache und antwortest auf \(definition).")
            case (.none, .none):
                return String(localized: "Du siehst den Begriff in der Lernsprache und antwortest mit der Übersetzung.")
            }
        }
        // The definition side is shown, the term side is answered.
        switch (definition, term) {
        case let (definition?, term?):
            return String(localized: "Du siehst \(definition) und antwortest auf \(term).")
        case let (definition?, .none):
            return String(localized: "Du siehst \(definition) und antwortest in der Lernsprache.")
        case let (.none, term?):
            return String(localized: "Du siehst die Übersetzung und antwortest auf \(term).")
        case (.none, .none):
            return String(localized: "Du siehst die Übersetzung und antwortest in der Lernsprache.")
        }
    }

    /// Valid question types (`learnOptions`: both off falls back to both on).
    private static func questionTypes(_ learn: LearnOptions) -> (mc: Bool, written: Bool) {
        learn.mc || learn.written ? (learn.mc, learn.written) : (true, true)
    }

    /// The Learn explanation under the study buttons (`studyNote`).
    static func studyNote(_ set: VocabSet, options: StudyOptions) -> String {
        let direction = learnDirection(options.answerWith, termLang: set.termLang, defLang: set.defLang)
        let types = questionTypes(options.learn)
        if !types.written {
            return String(localized: "\(direction) Alle Fragen als Multiple Choice. Zweimal richtig = gemeistert.")
        } else if !types.mc {
            return String(localized: "\(direction) Alle Fragen schriftlich. Zweimal richtig = gemeistert.")
        }
        return String(
            localized: "\(direction) Neue Begriffe zuerst als Multiple Choice, danach schriftlich. Zweimal richtig = gemeistert.")
    }

    /// `learnTagline`.
    static func learnTagline(_ options: StudyOptions) -> String {
        let types = questionTypes(options.learn)
        if types.mc, types.written { return String(localized: "Multiple Choice & schriftlich – bis alles sitzt") }
        return types.mc
            ? String(localized: "Multiple Choice – bis alles sitzt") : String(localized: "Schriftlich – bis alles sitzt")
    }

    /// What Schreiben asks (`answerLabel`): "Antworten auf Französisch".
    static func writeAnswerLabel(_ set: VocabSet, options: StudyOptions) -> String {
        switch options.answerWith {
        case .both:
            return String(localized: "Antworten in beide Richtungen")
        case .term, .definition:
            let lang = options.answerWith == .definition ? set.defLang : set.termLang
            if lang == .other || set.termLang == set.defLang {
                return options.answerWith == .definition
                    ? String(localized: "Antworten mit der Definition") : String(localized: "Antworten mit dem Begriff")
            }
            return String(localized: "Antworten auf \(Labels.langName(lang))")
        }
    }

    /// The caption under the mastery gauge (`progressCaption`).
    static func progressCaption(_ stats: SetProgress) -> String {
        if stats.total == 0 { return String(localized: "Füge Begriffe hinzu, um loszulegen.") }
        if stats.mastered == stats.total {
            return String(localized: "Alles gemeistert – grossartig! Wiederhole ab und zu, damit es sitzt.")
        }
        if stats.mastered == 0, stats.learning == 0 {
            return String(localized: "Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest.")
        }
        return String(
            localized:
                "\(stats.mastered) von \(Labels.plural(stats.total, "Begriff", "Begriffen")) gemeistert. Zweimal hintereinander richtig zählt als gemeistert."
        )
    }

    /// The tooltip of a card's status (`progressTitle`): "3× richtig · 1× falsch".
    static func progressTitle(_ progress: CardProgress?) -> String {
        guard let p = progress, p.correct + p.incorrect > 0 else { return String(localized: "Noch nicht geübt") }
        return String(localized: "\(p.correct)× richtig · \(p.incorrect)× falsch")
    }

    /// "52 Begriffe · Zuletzt gelernt vor 2 Tagen".
    static func facts(_ set: VocabSet, now: Double, timeZone: TimeZone) -> String {
        let studied = set.lastStudiedAt.map {
            String(localized: "Zuletzt gelernt \(TimeUtil.relativeTime($0, now: now, timeZone: timeZone))")
        }
        return [StudyCopy.terms(set.cards.count), studied ?? String(localized: "Noch nicht gelernt")].joined(separator: " · ")
    }
}
