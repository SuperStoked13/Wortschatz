import Foundation

// The texts of the "Andere Karte mit dem gleichen Begriff" sheet – the same as SameTermCards.cs of the Windows app.
extension SameTermCards {
    public static var title: String { L("Andere Karte mit dem gleichen Begriff") }

    /// "«to kidnap sb» ist die richtige Antwort für «jmdn. entführen». Gefragt war aber «etw. entführen»."
    public static func message(given: String, askedPrompt: String, otherPrompt: String) -> String {
        L("«%@» ist die richtige Antwort für «%@». Gefragt war aber «%@».", JSCompat.trim(given), otherPrompt, askedPrompt)
    }

    /// The three choices (right, for the other card, wrong), each with what it does.
    public static func choices(askedPrompt: String, otherPrompt: String) -> [(button: String, explanation: String)] {
        [
            (L("Als richtig zählen"), L("«%@» zählt als gewusst – für dich ist es dasselbe.", askedPrompt)),
            (L("Für die andere Karte zählen"),
             L("«%@» zählt als gewusst. «%@» bleibt falsch und kommt nochmals.", otherPrompt, askedPrompt)),
            (L("Als falsch zählen"), L("Nichts wird gutgeschrieben, die Antwort bleibt falsch.")),
        ]
    }

    /// The toast after "Für die andere Karte zählen".
    public static func countedForOther(askedPrompt: String, otherPrompt: String) -> String {
        L("«%@» als gewusst gezählt – «%@» bleibt falsch und kommt nochmals.", otherPrompt, askedPrompt)
    }
}
