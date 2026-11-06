import Foundation
import WortschatzCore

/// German texts of the set detail (ports of the helpers in src/screens/set.js and
/// src/ui/study-options.js).
enum SetDetailCopy {
    /// "Eigene Optionen: Multiple Choice: aus · 10 Fragen pro Runde" under the study note: what
    /// this set does differently from the standard (`LearnOptionsCopy.deviations`).
    static func ownOptionsNote(_ deviations: [String]) -> String {
        "Eigene Optionen: \(deviations.joined(separator: " · "))"
    }

    /// How a set side is called in sentences ("Du siehst Deutsch und antwortest auf Französisch").
    private struct SideName {
        let seen: String
        let answered: String
    }

    private static func isNamed(_ lang: Lang) -> Bool { lang != .other }

    /// `sideNames` of study-options.js.
    private static func sideNames(_ termLang: Lang, _ defLang: Lang) -> (term: SideName, definition: SideName) {
        if isNamed(termLang), termLang == defLang {
            return (SideName(seen: "den Begriff", answered: "mit dem Begriff"),
                    SideName(seen: "die Definition", answered: "mit der Definition"))
        }
        func named(_ lang: Lang) -> SideName {
            SideName(seen: Labels.langName(lang), answered: "auf \(Labels.langName(lang))")
        }
        return (
            isNamed(termLang) ? named(termLang) : SideName(seen: "den Begriff in der Lernsprache", answered: "in der Lernsprache"),
            isNamed(defLang) ? named(defLang) : SideName(seen: "die Übersetzung", answered: "mit der Übersetzung")
        )
    }

    /// `directionText(answerWith, termLang, defLang, 'learn')`.
    static func learnDirection(_ answerWith: AnswerWith, termLang: Lang, defLang: Lang) -> String {
        if answerWith == .both { return "Die Richtung wechselt zufällig von Frage zu Frage." }
        let names = sideNames(termLang, defLang)
        let (shown, typed) = answerWith == .definition ? (names.term, names.definition) : (names.definition, names.term)
        return "Du siehst \(shown.seen) und antwortest \(typed.answered)."
    }

    /// Valid question types (`learnOptions`: both off falls back to both on).
    private static func questionTypes(_ learn: LearnOptions) -> (mc: Bool, written: Bool) {
        learn.mc || learn.written ? (learn.mc, learn.written) : (true, true)
    }

    /// The Learn explanation under the study buttons (`studyNote`).
    static func studyNote(_ set: VocabSet, options: StudyOptions) -> String {
        let direction = learnDirection(options.answerWith, termLang: set.termLang, defLang: set.defLang)
        let types = questionTypes(options.learn)
        var how = "Neue Begriffe zuerst als Multiple Choice, danach schriftlich."
        if !types.written {
            how = "Alle Fragen als Multiple Choice."
        } else if !types.mc {
            how = "Alle Fragen schriftlich."
        }
        return "\(direction) \(how) Zweimal richtig = gemeistert."
    }

    /// `learnTagline`.
    static func learnTagline(_ options: StudyOptions) -> String {
        let types = questionTypes(options.learn)
        if types.mc, types.written { return "Multiple Choice & schriftlich – bis alles sitzt" }
        return types.mc ? "Multiple Choice – bis alles sitzt" : "Schriftlich – bis alles sitzt"
    }

    /// What Schreiben asks (`answerLabel`): "Antworten auf Französisch".
    static func writeAnswerLabel(_ set: VocabSet, options: StudyOptions) -> String {
        switch options.answerWith {
        case .both:
            return "Antworten in beide Richtungen"
        case .term, .definition:
            let lang = options.answerWith == .definition ? set.defLang : set.termLang
            if lang == .other || set.termLang == set.defLang {
                return options.answerWith == .definition ? "Antworten mit der Definition" : "Antworten mit dem Begriff"
            }
            return "Antworten auf \(Labels.langName(lang))"
        }
    }

    /// The caption under the mastery gauge (`progressCaption`).
    static func progressCaption(_ stats: SetProgress) -> String {
        if stats.total == 0 { return "Füge Begriffe hinzu, um loszulegen." }
        if stats.mastered == stats.total {
            return "Alles gemeistert – grossartig! Wiederhole ab und zu, damit es sitzt."
        }
        if stats.mastered == 0, stats.learning == 0 {
            return "Ein Begriff gilt als gemeistert, wenn du ihn zweimal hintereinander richtig beantwortest."
        }
        return "\(stats.mastered) von \(Labels.plural(stats.total, "Begriff", "Begriffen")) gemeistert. Zweimal hintereinander richtig zählt als gemeistert."
    }

    /// The tooltip of a card's status (`progressTitle`): "3× richtig · 1× falsch".
    static func progressTitle(_ progress: CardProgress?) -> String {
        guard let p = progress, p.correct + p.incorrect > 0 else { return "Noch nicht geübt" }
        return "\(p.correct)× richtig · \(p.incorrect)× falsch"
    }

    /// "52 Begriffe · Zuletzt gelernt vor 2 Tagen".
    static func facts(_ set: VocabSet, now: Double, timeZone: TimeZone) -> String {
        let studied = set.lastStudiedAt.map { "Zuletzt gelernt \(TimeUtil.relativeTime($0, now: now, timeZone: timeZone))" }
        return [StudyCopy.terms(set.cards.count), studied ?? "Noch nicht gelernt"].joined(separator: " · ")
    }
}
