import Foundation
import WortschatzCore

/// Texts and pure helpers of the set editor: a port of src/screens/editor-util.js plus the
/// small helpers of editor.js and editor-cards.js. Swiss spelling ("ss", never the sharp s).
nonisolated enum SetEditorCopy {
    // MARK: Limits

    /// The list never shrinks below this many rows (`MIN_ROWS` in editor-cards.js).
    static let minimumRows = 2
    /// `maxlength` of the title field.
    static let titleLimit = 120
    /// `maxlength` of the description field.
    static let descriptionLimit = 600

    // MARK: Languages

    /// "Ich lerne": the display order of the language pickers.
    static let termLanguages: [Lang] = Labels.LANG_ORDER
    /// "Übersetzung": German first.
    static let definitionLanguages: [Lang] = [.de] + Labels.LANG_ORDER.filter { $0 != .de }

    /// Whether a detected language may fill a picker (`knownLang` in editor.js).
    static func isKnown(_ lang: Lang) -> Bool {
        lang != .other
    }

    // MARK: Texts

    static let titlePlaceholder = String(localized: "z. B. Unité 3 – Les personnes")
    static let descriptionPlaceholder = String(localized: "Optional – z. B. Kapitel, Lehrmittel oder Prüfungsdatum")
    static let titleMissing = String(localized: "Gib deinem Lernset einen Titel.")
    static let titleFromFile = String(localized: "Aus dem Dateinamen übernommen – du kannst ihn jederzeit ändern.")
    static let detected = String(localized: "Automatisch erkannt")
    static let listDiverted = String(localized: "Liste erkannt – die Paare stehen jetzt in den Karten. Trennung und Seiten passt du oben an.")
    /// "1 möglicher Tippfehler" / "3 mögliche Tippfehler" (the card list's chip).
    static func typoCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 möglicher Tippfehler") : String(localized: "\(count) mögliche Tippfehler")
    }
    /// "Automatisch" in the language pickers (a new set's default).
    static let automatic = String(localized: "Automatisch", comment: "Language picker: recognise the language")
    static let emptyLead = String(localized: "Tippe deine Vokabeln ein – oder importiere oben eine ganze Liste auf einmal.")
    static let termPlaceholder = String(localized: "Begriff eingeben")
    static let definitionPlaceholder = String(localized: "Definition eingeben")

    /// The save button: "Lernset erstellen" for a new set, "Sichern" for an existing one.
    static func saveLabel(isEditing: Bool) -> String {
        isEditing
            ? String(localized: "Sichern", comment: "Button: save the edited set")
            : String(localized: "Lernset erstellen", comment: "Button: create the new set")
    }

    /// Why saving cannot work yet (`readiness` in editor.js), nil when it can.
    static func readiness(titleIsEmpty: Bool, completeCards: Int) -> String? {
        if titleIsEmpty { return String(localized: "Titel fehlt") }
        if completeCards == 0 { return String(localized: "Noch keine vollständige Karte") }
        return nil
    }

    /// The cards section's error after a save attempt (`cardsMessage` in editor.js).
    static func cardsMessage(completeCards: Int, invalidCards: Int) -> String? {
        if completeCards == 0 { return String(localized: "Füge mindestens eine Karte mit Begriff und Definition hinzu.") }
        if invalidCards > 0 {
            return String(localized: "\(Labels.plural(invalidCards, "Karte ist", "Karten sind")) unvollständig – ergänze Begriff und Definition oder lösche sie.")
        }
        return nil
    }

    // MARK: Keys

    /// Case- and whitespace-insensitive key used to find duplicate terms (`termKey`).
    static func termKey(_ term: String) -> String {
        var key = TextNormalizer.normalizeBasic(term).lowercased()
        while let last = key.last, last == "." || last == "!" || last == "?" {
            key.removeLast()
        }
        return key
    }

    /// Title suggestion from a file name (`titleFromFileName`): "Unité_3 - Vocabulaire.pdf" →
    /// "Unité 3 - Vocabulaire"; camera and screenshot names give "".
    static func titleFromFileName(_ name: String) -> String {
        var base = name.replacing(/\.[A-Za-z0-9]{1,5}$/, with: "")
        base = base.replacing(/_+/, with: " ")
        base = base.replacing(/\s+/, with: " ")
        base = JSCompat.trim(base)
        guard base.count >= 2 else { return "" }
        let generic = /^(?i:image|img|screenshot|bildschirmfoto|scan|dsc|pxl|photo|foto|untitled|unbenannt)(?:[\s\d._-]|$)/
        if base.firstMatch(of: generic) != nil { return "" }
        return String(base.prefix(80))
    }

    // MARK: Parser flags

    /// Flags that earn an amber "bitte prüfen" marker, in display order (`FLAG_TEXT`;
    /// `duplicate` is shown separately).
    private static let flagTexts: [ParseFlag: String] = [
        .merged: String(localized: "Aus mehreren Zeilen zusammengefügt"),
        .lowConfidence: String(localized: "Unsicher erkannt"),
        .langMismatch: String(localized: "Sprache passt nicht zur Spalte"),
        .missingTerm: String(localized: "Begriff fehlt"),
        .missingDefinition: String(localized: "Definition fehlt"),
    ]

    /// Whether the flags earn a marker (`hasMarker`).
    static func hasMarker(_ flags: [ParseFlag]) -> Bool {
        flags.contains { flagTexts[$0] != nil }
    }

    /// The marker's tooltip, e.g. "Unsicher erkannt – bitte prüfen" (`flagTooltip`).
    static func flagTooltip(_ flags: [ParseFlag]) -> String? {
        let parts = flags.compactMap { flagTexts[$0] }
        return parts.isEmpty ? nil : String(localized: "\(parts.joined(separator: " · ")) – bitte prüfen")
    }

    /// The flags after swapping term and definition.
    static func swapped(_ flags: [ParseFlag]) -> [ParseFlag] {
        flags.map {
            switch $0 {
            case .missingTerm: .missingDefinition
            case .missingDefinition: .missingTerm
            default: $0
            }
        }
    }

    // MARK: Detection

    /// "Getrennt durch …" per delimiter, each a whole label (translatable as one phrase).
    private static let delimiterLabels: [String: String] = [
        "\t": String(localized: "Getrennt durch Tabulator"),
        ",": String(localized: "Getrennt durch Komma"),
        ";": String(localized: "Getrennt durch Strichpunkt"),
        "-": String(localized: "Getrennt durch Bindestrich"),
        "=": String(localized: "Getrennt durch Gleichheitszeichen"),
        ":": String(localized: "Getrennt durch Doppelpunkt"),
        "|": String(localized: "Getrennt durch Senkrechten Strich"),
        "→": String(localized: "Getrennt durch Pfeil"),
        "/": String(localized: "Getrennt durch Schrägstrich"),
    ]

    /// Short German description of the detected layout (`formatLabel`).
    static func formatLabel(_ result: ParseResult) -> String? {
        switch result.format {
        case .blocks, .alternating:
            return String(localized: "Abwechselnde Zeilen")
        case .columns:
            return String(localized: "Zwei Spalten nacheinander")
        case .delimited:
            let delimiter = result.delimiter ?? ""
            if delimiter == "  " { return String(localized: "Spalten mit Abstand") }
            if delimiter == " " { return String(localized: "Beide Sprachen in einer Zeile") }
            let key = delimiter == "\t" ? "\t" : JSCompat.trim(delimiter)
            if let label = delimiterLabels[key] { return label }
            return key.isEmpty ? nil : String(localized: "Getrennt durch «\(key)»")
        case .empty:
            return nil
        }
    }

    /// Why a line was skipped (`SKIP_REASONS`).
    static func skipReason(_ reason: SkipReason) -> String {
        switch reason {
        case .heading: String(localized: "Überschrift")
        case .pageNumber: String(localized: "Seitenzahl")
        case .noise: String(localized: "Kein Vokabeltext")
        case .unpaired: String(localized: "Ohne Gegenstück")
        }
    }

    /// "52 Paare erkannt" / "Noch keine Paare erkannt".
    static func pairsDetected(_ count: Int) -> String {
        count > 0
            ? String(localized: "\(Labels.plural(count, "Paar", "Paare")) erkannt")
            : String(localized: "Noch keine Paare erkannt")
    }

    // MARK: Pasting into fields

    /// What a paste into a card field (or the title) means.
    enum PasteShape: Equatable {
        /// One spreadsheet row ("term⇥definition") pasted into an empty card: fills both fields.
        case pair(term: String, definition: String)
        /// A whole list: goes to the import box instead.
        case list(String)
    }

    /// The text an edit inserted: `new` without the prefix and suffix it shares with `old`.
    static func insertedText(old: String, new: String) -> String {
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        return String(newChars[prefix..<(newChars.count - suffix)])
    }

    /// The paste handling of editor-cards.js: a single tab-separated row into an empty card
    /// fills it; three or more lines (or two tab-separated ones) are a list for the import box.
    static func pasteShape(_ inserted: String, rowIsEmpty: Bool) -> PasteShape? {
        guard inserted.contains(where: { $0.isNewline || $0 == "\t" }) else { return nil }
        let lines = inserted.split(whereSeparator: \.isNewline).map(String.init).filter { !JSCompat.trim($0).isEmpty }
        if lines.count == 1, rowIsEmpty {
            let cells = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map { JSCompat.trim(String($0)) }
            if cells.count == 2, !cells[0].isEmpty, !cells[1].isEmpty {
                return .pair(term: cells[0], definition: cells[1])
            }
        }
        let tabbed = lines.count >= 2 && lines.filter { $0.contains("\t") }.count >= 2
        if lines.count >= 3 || tabbed { return .list(inserted) }
        return nil
    }
}
