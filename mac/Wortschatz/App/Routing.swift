import Foundation
import WortschatzCore

// Navigation values of the main window (spec §4.1). `AppModel` owns the current values; views
// only read them and call `AppModel` methods to change them.

/// A row of the sidebar.
enum SidebarItem: Hashable, Sendable {
    /// "Übersicht" at the top.
    case overview
    /// A set in the "Lernsets" section.
    case set(String)

    /// The set id of a `.set` row.
    var setID: String? {
        if case let .set(id) = self { id } else { nil }
    }
}

/// What a study screen (Learn, Write, Flashcards or Exam) is asked to show. Mirrors the web routes
/// `#/set/<id>/learn?new=1&subset=starred`:
///
/// - `subset == nil` and `forceNew == false`: resume the stored session, whatever its subset
///   (the "Weiterlernen" / "Fortsetzen" buttons), else start a new one with all cards.
/// - `forceNew == true`: start a new session with `subset ?? .all`, replacing a stored one.
///   The caller has already asked the learner where that would throw answers away
///   (`AppModel.startLearn` / `startWrite` do that for subset starts).
/// - `subset != nil` and `forceNew == false`: resume when the stored session has that subset,
///   otherwise start one.
///
/// Every request gets a fresh `id`, so starting again (for example "Neu starten") recreates
/// the study screen even for the same set, mode and subset.
struct StudyRequest: Hashable, Identifiable, Sendable {
    let id: UUID
    var setID: String
    var mode: StudyMode
    var subset: StudySubset?
    var forceNew: Bool
    /// Learn: a new session asks the cards that are mastered already again (as repetition
    /// questions), whatever the "Wiederholungsfragen" option says. The exam's "Falsche lernen"
    /// uses it: an exam records nothing, so a word it found wrong may still count as mastered.
    var reviewMastered: Bool

    init(
        setID: String, mode: StudyMode, subset: StudySubset? = nil, forceNew: Bool = false,
        reviewMastered: Bool = false
    ) {
        id = UUID()
        self.setID = setID
        self.mode = mode
        self.subset = subset
        self.forceNew = forceNew
        self.reviewMastered = reviewMastered
    }

    /// The same request (same `id`, so an open screen stays as it is) asking to resume whatever
    /// session is stored. A study screen's route becomes this once the screen has started its
    /// session, so a screen built for the route again (the main window was closed and reopened)
    /// continues that session instead of starting another one.
    var resuming: StudyRequest {
        var request = self
        request.subset = nil
        request.forceNew = false
        return request
    }
}

/// The content of the detail column.
enum DetailRoute: Hashable, Sendable {
    case overview
    case set(String)
    case learn(StudyRequest)
    case write(StudyRequest)
    case flashcards(StudyRequest)
    /// Prüfungsmodus: the request's subset and `forceNew` are not used (an exam starts with its
    /// settings and is never kept).
    case exam(StudyRequest)

    /// The study screen for `request` (by its mode).
    static func study(_ request: StudyRequest) -> DetailRoute {
        switch request.mode {
        case .learn: .learn(request)
        case .write: .write(request)
        case .flashcards: .flashcards(request)
        case .exam: .exam(request)
        }
    }

    /// The set the route is about (nil for the overview).
    var setID: String? {
        switch self {
        case .overview: nil
        case let .set(id): id
        case let .learn(request), let .write(request), let .flashcards(request), let .exam(request): request.setID
        }
    }

    /// The running study request (Learn, Write, Flashcards or Exam), if any.
    var study: StudyRequest? {
        switch self {
        case let .learn(request), let .write(request), let .flashcards(request), let .exam(request): request
        case .overview, .set: nil
        }
    }

    var isStudy: Bool { study != nil }

    /// The sidebar row that belongs to the route.
    var sidebarItem: SidebarItem {
        setID.map(SidebarItem.set) ?? .overview
    }
}

/// What the editor sheet is asked to do (spec §4.4, Editor). A fresh `id` per request, so the
/// sheet is recreated each time it opens.
struct EditorRequest: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        /// "Neues Lernset" (⌘N): an empty editor, focus in the import text area.
        case new
        /// "Liste importieren…" (⌘O): a new set, opening the file chooser right away.
        case importList
        /// "Bearbeiten" (⌘E): the existing set with this id.
        case edit(setID: String)
    }

    let id: UUID
    var kind: Kind

    init(_ kind: Kind) {
        id = UUID()
        self.kind = kind
    }

    /// The set being edited (nil for a new set).
    var setID: String? {
        if case let .edit(setID) = kind { setID } else { nil }
    }
}
