import Foundation
import Observation
import WortschatzCore
import WortschatzImport

/// One card row of the editor. A reference type, so typing in a row only updates that row's
/// view (lists with several hundred cards stay fluid, like the web's in-place rows).
@Observable
final class SetEditorRow: Identifiable {
    /// The values needed to rebuild a row (undo).
    struct Snapshot: Equatable {
        var id: UUID
        var cardID: String?
        var term: String
        var definition: String
        var starred: Bool
        var flags: [ParseFlag]
        var importKey: String?
    }

    /// The row's identity in the list (not the card id: new rows have none yet).
    let id: UUID
    /// The stored card's id; kept on save so the learning progress stays with the card.
    var cardID: String?
    var term: String
    var definition: String
    var starred: Bool
    /// Parser flags of an imported card ("bitte prüfen"); cleared by the first edit.
    var flags: [ParseFlag]
    /// The pair of the import box this card shows (`SetEditorModel.importKey`), nil for a card
    /// typed in or loaded from the set. Such cards follow the import box: another Trennung,
    /// "Seiten tauschen" or more text changes them in place.
    var importKey: String?
    /// Marked by the last save attempt: filled but incomplete, until fixed.
    var isInvalid = false
    /// Its term appears in another row too.
    var isDuplicate = false
    /// Probable typos found by the spell checker (hints only; never block saving).
    var termSpelling: [SpellingIssue] = []
    var definitionSpelling: [SpellingIssue] = []

    init(
        id: UUID = UUID(), cardID: String? = nil, term: String = "", definition: String = "", starred: Bool = false,
        flags: [ParseFlag] = [], importKey: String? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.term = term
        self.definition = definition
        self.starred = starred
        self.flags = flags
        self.importKey = importKey
    }

    convenience init(card: Card) {
        self.init(cardID: card.id, term: card.term, definition: card.definition, starred: card.starred)
    }

    convenience init(_ snapshot: Snapshot) {
        self.init(
            id: snapshot.id, cardID: snapshot.cardID, term: snapshot.term, definition: snapshot.definition,
            starred: snapshot.starred, flags: snapshot.flags, importKey: snapshot.importKey)
    }

    var snapshot: Snapshot {
        Snapshot(
            id: id, cardID: cardID, term: term, definition: definition, starred: starred, flags: flags, importKey: importKey)
    }

    var trimmedTerm: String { JSCompat.trim(term) }
    var trimmedDefinition: String { JSCompat.trim(definition) }

    /// Term or definition has text (empty rows are not saved).
    var isFilled: Bool { !trimmedTerm.isEmpty || !trimmedDefinition.isEmpty }
    /// Term and definition have text.
    var isComplete: Bool { !trimmedTerm.isEmpty && !trimmedDefinition.isEmpty }
    /// The parser marked it for review.
    var isFlagged: Bool { SetEditorCopy.hasMarker(flags) }
    /// The spell checker found a probable typo in the term or the definition.
    var hasSpellingIssues: Bool { !termSpelling.isEmpty || !definitionSpelling.isEmpty }

    /// The card to save.
    var draft: CardDraft {
        CardDraft(id: cardID, term: trimmedTerm, definition: trimmedDefinition, starred: starred)
    }
}

/// A keyboard focus target of the editor.
enum SetEditorField: Hashable {
    case title
    case description
    case customSeparator
    case term(UUID)
    case definition(UUID)

    /// The card row of a term or definition field.
    var rowID: UUID? {
        switch self {
        case let .term(id), let .definition(id): id
        case .title, .description, .customSeparator: nil
        }
    }
}
