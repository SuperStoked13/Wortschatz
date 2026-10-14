import AppKit
import Observation
import SwiftUI
import WortschatzCore
import WortschatzImport

/// The set editor (spec §4.4 "Editor", port of src/screens/editor.js and the logic of
/// editor-cards.js): title, description and languages, the import panel, the card rows with
/// duplicate and completeness checks, undo, and saving through `AppModel.store`.
///
/// Views only render it and forward events. Keyboard focus and scrolling are requested
/// through `focusRequest` / `scrollRequest`, which the sheet applies.
@Observable
final class SetEditorModel {
    enum Mode: Equatable {
        case create
        case edit(setID: String)
    }

    /// How imported cards join the list.
    enum ApplyMode: Sendable {
        case replace, append
    }

    /// A question the sheet shows as an alert.
    enum Prompt: Identifiable, Equatable {
        /// "Karten übernehmen": the list has cards already (Anhängen / Ersetzen).
        case applyImport(cards: [ParsedCard], existing: Int, keepsProgress: Bool)
        /// Saving while recognised pairs still wait in the import box.
        case pendingImport(count: Int)
        /// Esc with unsaved changes.
        case discard(isEditing: Bool)

        var id: String {
            switch self {
            case .applyImport: "apply"
            case .pendingImport: "pending"
            case .discard: "discard"
            }
        }

        var title: String {
            switch self {
            case .applyImport: "Karten übernehmen"
            case .pendingImport: "Liste noch nicht übernommen"
            case .discard: "Änderungen verwerfen?"
            }
        }

        var message: String {
            switch self {
            case let .applyImport(cards, existing, keepsProgress):
                let question = "Dein Lernset enthält schon \(Labels.plural(existing, "Karte", "Karten")). Möchtest du die \(Labels.plural(cards.count, "neue Karte", "neuen Karten")) anhängen oder die bisherigen ersetzen?"
                return keepsProgress ? "\(question)\n\nBeim Ersetzen bleibt der Lernfortschritt für gleiche Begriffe erhalten." : question
            case let .pendingImport(count):
                let waiting = count == 1 ? "wartet noch 1 erkanntes Paar" : "warten noch \(count) erkannte Paare"
                return "Im Importfeld \(waiting). Sollen sie vor dem Speichern angehängt werden?"
            case let .discard(isEditing):
                return isEditing
                    ? "Deine Änderungen an diesem Lernset sind noch nicht gespeichert und gehen verloren."
                    : "Dein neues Lernset ist noch nicht gespeichert und geht verloren."
            }
        }
    }

    /// Where the keyboard focus should go; `token` makes repeated requests distinct.
    struct FocusRequest: Equatable {
        let field: SetEditorField
        let token: Int
    }

    /// A place the scroll view should bring into view.
    enum ScrollTarget: Hashable {
        case importPanel, detection, cards
        case row(UUID)
    }

    struct ScrollRequest: Equatable {
        let target: ScrollTarget
        let anchor: UnitPoint?
        let token: Int
    }

    /// Counts for the header, the issue chips and the save bar (`list.stats()`).
    struct Stats: Equatable {
        var rows = 0
        /// Rows with a term or a definition (they are saved).
        var filled = 0
        /// Rows with both.
        var complete = 0
        /// Rows marked incomplete by the last save attempt and not fixed since.
        var invalid = 0
        /// Imported rows the parser marked for review.
        var flagged = 0
        /// Terms that appear more than once.
        var duplicates = 0
        /// Probable typos (spell checker), counted per word.
        var typos = 0
    }

    let mode: Mode
    /// Toasts of the sheet (undo actions live as long as the editor).
    let toasts: ToastCenter
    let importPanel: ImportPanelModel

    private(set) var title: String
    private(set) var details: String
    private(set) var termLang: Lang
    private(set) var defLang: Lang
    /// The learner picked the language (an existing set's languages count as picked).
    private(set) var termTouched: Bool
    private(set) var defTouched: Bool
    /// The picker was filled from the recognised list ("Automatisch erkannt").
    private(set) var termDetected = false
    private(set) var defDetected = false
    /// The title came from a file name.
    private(set) var titleFromFile = false
    private(set) var rows: [SetEditorRow]
    private(set) var duplicateTerms = 0
    /// A save was attempted: errors show from now on.
    private(set) var attempted = false
    private(set) var focusRequest: FocusRequest?
    private(set) var scrollRequest: ScrollRequest?
    var prompt: Prompt?
    private(set) var isSaving = false
    /// Saved or discarded: the sheet is going away.
    private(set) var isClosed = false

    @ObservationIgnored let app: AppModel
    /// The sheet's undo manager (⌘Z for deleted rows, imports and swapped sides).
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var baseline: Fingerprint?
    @ObservationIgnored private var loadedAt: Double
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?
    @ObservationIgnored private var spellingTask: Task<Void, Never>?
    @ObservationIgnored private let speller = VocabSpellChecker.shared
    @ObservationIgnored private var undoRecords: [UndoRecord] = []
    @ObservationIgnored private var requestCounter = 0

    init(app: AppModel, request: EditorRequest) {
        let original = request.setID.flatMap { app.store.getSet($0) }
        let toasts = ToastCenter()
        self.app = app
        self.toasts = toasts
        mode = original.map { .edit(setID: $0.id) } ?? .create
        title = original?.title ?? ""
        details = original?.description ?? ""
        termLang = original?.termLang ?? .fr
        defLang = original?.defLang ?? .de
        termTouched = original != nil
        defTouched = original != nil
        rows = Self.padded(original?.cards.map(SetEditorRow.init(card:)) ?? [])
        loadedAt = original?.updatedAt ?? 0
        importPanel = ImportPanelModel(isExpanded: original == nil, toasts: toasts)
        baseline = fingerprint()
        importPanel.languages = { [weak self] in self?.importLanguages ?? ImportLanguages() }
        importPanel.onDetected = { [weak self] result in self?.detected(result) }
        importPanel.onFileName = { [weak self] name in self?.suggestTitle(fromFileName: name) }
        checkDuplicates()
        checkSpelling()
    }

    // MARK: Derived

    var isEditing: Bool { mode != .create }
    var heading: String { isEditing ? "Lernset bearbeiten" : "Neues Lernset" }
    var saveLabel: String { SetEditorCopy.saveLabel(isEditing: isEditing) }

    var importLanguages: ImportLanguages {
        ImportLanguages(termLang: termLang, defLang: defLang, termTouched: termTouched, defTouched: defTouched)
    }

    var stats: Stats {
        var stats = Stats(rows: rows.count, duplicates: duplicateTerms)
        for row in rows {
            if row.isFilled { stats.filled += 1 }
            if row.isComplete { stats.complete += 1 }
            if row.isFlagged { stats.flagged += 1 }
            if row.isInvalid { stats.invalid += 1 }
            stats.typos += row.termSpelling.count + row.definitionSpelling.count
        }
        return stats
    }

    var isTitleEmpty: Bool { JSCompat.trim(title).isEmpty }

    var titleError: String? {
        attempted && isTitleEmpty ? SetEditorCopy.titleMissing : nil
    }

    var cardsError: String? {
        guard attempted else { return nil }
        let stats = stats
        return SetEditorCopy.cardsMessage(completeCards: stats.complete, invalidCards: stats.invalid)
    }

    /// Why saving cannot work yet ("Titel fehlt"), nil when it can.
    var readiness: String? {
        SetEditorCopy.readiness(titleIsEmpty: isTitleEmpty, completeCards: stats.complete)
    }

    /// Unsaved changes (also: text waiting in the import box).
    var isDirty: Bool {
        !isClosed && (fingerprint() != baseline || importPanel.hasText)
    }

    private var isListEmpty: Bool { !rows.contains(where: \.isFilled) }

    // MARK: Title, description, languages

    func setTitle(_ value: String) {
        guard value != title else { return }
        if case let .list(text)? = pasteShape(old: title, new: value, rowIsEmpty: false) {
            // The field shows the paste for a moment, then gets its old text back.
            let old = title
            title = value
            Task { @MainActor [weak self] in
                self?.title = old
                self?.divertList(text)
            }
            return
        }
        title = String(value.replacing(/[\r\n]+/, with: " ").prefix(SetEditorCopy.titleLimit))
        titleFromFile = false
    }

    func setDetails(_ value: String) {
        guard value != details else { return }
        if case let .list(text)? = pasteShape(old: details, new: value, rowIsEmpty: false) {
            let old = details
            details = value
            Task { @MainActor [weak self] in
                self?.details = old
                self?.divertList(text)
            }
            return
        }
        details = String(value.prefix(SetEditorCopy.descriptionLimit))
    }

    func setTermLang(_ lang: Lang) {
        termTouched = true
        termDetected = false
        guard lang != termLang else { return }
        termLang = lang
        importPanel.reparse()
        checkSpelling()
    }

    func setDefLang(_ lang: Lang) {
        defTouched = true
        defDetected = false
        guard lang != defLang else { return }
        defLang = lang
        importPanel.reparse()
        checkSpelling()
    }

    /// "Begriffe und Definitionen tauschen": languages and every row (undoable).
    func flipSides() {
        undoable("Seiten tauschen", toast: "Begriffe und Definitionen getauscht", systemImage: "arrow.left.arrow.right") {
            termTouched = true
            defTouched = true
            termDetected = false
            defDetected = false
            (termLang, defLang) = (defLang, termLang)
            for row in rows {
                (row.term, row.definition) = (row.definition, row.term)
                row.flags = SetEditorCopy.swapped(row.flags)
            }
        }
        checkDuplicates()
        checkSpelling()
        importPanel.reparse()
    }

    /// Recognised languages fill the pickers the learner has not chosen (`onDetected`).
    private func detected(_ result: ParseResult) {
        let nextTerm = !termTouched && SetEditorCopy.isKnown(result.termLang) ? result.termLang : termLang
        let nextDef = !defTouched && SetEditorCopy.isKnown(result.defLang) ? result.defLang : defLang
        guard nextTerm != nextDef, nextTerm != termLang || nextDef != defLang else { return }
        if nextTerm != termLang { termDetected = true }
        if nextDef != defLang { defDetected = true }
        termLang = nextTerm
        defLang = nextDef
        checkSpelling()
    }

    /// The first imported file's name becomes the title while there is none (`onFileName`).
    private func suggestTitle(fromFileName name: String) {
        guard isTitleEmpty else { return }
        let suggestion = SetEditorCopy.titleFromFileName(name)
        guard !suggestion.isEmpty else { return }
        title = suggestion
        titleFromFile = true
    }

    // MARK: Card rows

    func setTerm(_ row: SetEditorRow, _ value: String) {
        update(row, term: true, to: value)
    }

    func setDefinition(_ row: SetEditorRow, _ value: String) {
        update(row, term: false, to: value)
    }

    private func update(_ row: SetEditorRow, term: Bool, to value: String) {
        let old = term ? row.term : row.definition
        guard value != old else { return }
        if let shape = pasteShape(old: old, new: value, rowIsEmpty: !row.isFilled) {
            // The field shows the paste for a moment; then it gets its old text back, so the
            // text field notices the change.
            if term { row.term = value } else { row.definition = value }
            Task { @MainActor [weak self] in
                if term { row.term = old } else { row.definition = old }
                switch shape {
                case let .pair(newTerm, newDefinition): self?.fill(row, term: newTerm, definition: newDefinition)
                case let .list(text): self?.divertList(text)
                }
            }
            return
        }
        if term { row.term = value } else { row.definition = value }
        if !row.flags.isEmpty { row.flags = [] }
        if row.isInvalid, row.isComplete || !row.isFilled { row.isInvalid = false }
        if term { scheduleDuplicates() }
        scheduleSpelling()
    }

    func toggleStar(_ row: SetEditorRow) {
        row.starred.toggle()
        Announcer.announce(row.starred ? "Markiert" : "Markierung entfernt")
    }

    /// "Karte hinzufügen" (and Return / Tab at the end of the list).
    @discardableResult
    func addRow(focus: Bool = true) -> SetEditorRow {
        let row = SetEditorRow()
        rows.append(row)
        if focus { requestFocus(.term(row.id)) }
        return row
    }

    /// The row's trash button: filled rows can be brought back (toast, ⌘Z). The list never
    /// becomes empty: the last row is replaced by a fresh one, so a new word typed there does
    /// not inherit the deleted card's id (and its progress) or its star.
    func deleteRow(_ row: SetEditorRow, focused: SetEditorField?) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let change = {
            self.rows.remove(at: index)
            if self.rows.isEmpty { self.rows.append(SetEditorRow()) }
        }
        if row.isFilled {
            undoable("Karte löschen", toast: "Karte gelöscht", systemImage: "trash", change)
        } else {
            change()
            Announcer.announce("Karte gelöscht")
        }
        scheduleDuplicates()
        // Keyboard users keep working at the same position.
        if let focused, focused.rowID == row.id {
            let neighbour = rows[min(index, rows.count - 1)]
            if case .term = focused { requestFocus(.term(neighbour.id)) } else { requestFocus(.definition(neighbour.id)) }
        }
    }

    /// Return in a field (`keydown Enter` in editor.js / editor-cards.js): title → description
    /// → import box or first card; term → definition; definition → next row's term, or a new
    /// row after a filled last row.
    func submit(_ field: SetEditorField) {
        switch field {
        case .title:
            requestFocus(.description)
        case .description:
            if importPanel.isExpanded {
                importPanel.focusTextArea()
            } else if let first = rows.first {
                requestFocus(.term(first.id))
            }
        case .customSeparator:
            importPanel.parseNow()
        case let .term(id):
            requestFocus(.definition(id))
        case let .definition(id):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            if index < rows.count - 1 {
                requestFocus(.term(rows[index + 1].id))
            } else if rows[index].isFilled {
                addRow()
            }
        }
    }

    /// Tab in the last card's definition adds a card (only after a filled row).
    func tabFromDefinition(of row: SetEditorRow) -> Bool {
        guard row.id == rows.last?.id, row.isFilled else { return false }
        addRow()
        return true
    }

    /// Backspace in an empty card's term removes the card and continues in the previous
    /// definition.
    func deleteBackwardInEmptyTerm(of row: SetEditorRow) -> Bool {
        guard rows.count > 1, !row.isFilled, let index = rows.firstIndex(where: { $0.id == row.id }) else { return false }
        let previous = index > 0 ? rows[index - 1] : nil
        rows.remove(at: index)
        scheduleDuplicates()
        if let previous {
            requestFocus(.definition(previous.id))
        } else if let first = rows.first {
            requestFocus(.term(first.id))
        }
        return true
    }

    private func fill(_ row: SetEditorRow, term: String, definition: String) {
        row.term = term
        row.definition = definition
        row.flags = []
        row.isInvalid = false
        requestFocus(.definition(row.id))
        scheduleDuplicates()
        scheduleSpelling()
    }

    /// A whole list pasted into a field goes to the import box (`onPasteList`).
    private func divertList(_ text: String) {
        importPanel.setText(text, append: true)
        toasts.show(SetEditorCopy.listDiverted, systemImage: "sparkles")
        scroll(to: .importPanel, anchor: .top)
    }

    private func pasteShape(old: String, new: String, rowIsEmpty: Bool) -> SetEditorCopy.PasteShape? {
        SetEditorCopy.pasteShape(SetEditorCopy.insertedText(old: old, new: new), rowIsEmpty: rowIsEmpty)
    }

    private static func padded(_ rows: [SetEditorRow]) -> [SetEditorRow] {
        var rows = rows
        while rows.count < SetEditorCopy.minimumRows { rows.append(SetEditorRow()) }
        return rows
    }

    private func setRows(_ newRows: [SetEditorRow]) {
        rows = Self.padded(newRows)
    }

    /// Appends after the last non-empty row (trailing empty rows are reused).
    private func appendRows(_ newRows: [SetEditorRow]) {
        var kept = rows
        while let last = kept.last, !last.isFilled { kept.removeLast() }
        rows = Self.padded(kept + newRows)
    }

    // MARK: Duplicates

    private func scheduleDuplicates() {
        duplicateTask?.cancel()
        duplicateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.checkDuplicates()
        }
    }

    /// Marks rows whose term appears more than once (`checkDuplicates`).
    private func checkDuplicates() {
        duplicateTask?.cancel()
        duplicateTask = nil
        var counts: [String: Int] = [:]
        let keys = rows.map { row in
            let key = SetEditorCopy.termKey(row.term)
            if !key.isEmpty { counts[key, default: 0] += 1 }
            return key
        }
        duplicateTerms = counts.values.filter { $0 > 1 }.count
        for (row, key) in zip(rows, keys) {
            let duplicate = !key.isEmpty && (counts[key] ?? 0) > 1
            if row.isDuplicate != duplicate { row.isDuplicate = duplicate }
        }
    }

    // MARK: Spelling

    private func scheduleSpelling() {
        runSpelling(after: .milliseconds(400))
    }

    /// Marks probable typos in every row, in small portions so a 500-card list never stalls
    /// the editor. The spell checker caches each text, so later passes only pay for fields
    /// that changed.
    func checkSpelling() {
        runSpelling(after: nil)
    }

    private func runSpelling(after delay: Duration?) {
        spellingTask?.cancel()
        spellingTask = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            let rows = self.rows
            let termLang = self.termLang
            let defLang = self.defLang
            for (index, row) in rows.enumerated() {
                guard !Task.isCancelled else { return }
                let term = self.speller.issues(in: row.term, lang: termLang)
                let definition = self.speller.issues(in: row.definition, lang: defLang)
                if row.termSpelling != term { row.termSpelling = term }
                if row.definitionSpelling != definition { row.definitionSpelling = definition }
                if index % 20 == 19 { await Task.yield() }
            }
        }
    }

    /// A suggestion from a typo chip replaces the word (undoable like other list changes).
    func replaceSpelling(_ issue: SpellingIssue, in row: SetEditorRow, isTerm: Bool, with replacement: String) {
        let text = (isTerm ? row.term : row.definition) as NSString
        var range = issue.range
        if NSMaxRange(range) > text.length || text.substring(with: range) != issue.word {
            range = text.range(of: issue.word)
        }
        guard range.location != NSNotFound else { return }
        let corrected = text.replacingCharacters(in: range, with: replacement)
        undoable(
            "Tippfehler korrigieren", toast: "«\(issue.word)» durch «\(replacement)» ersetzt", tone: .success,
            systemImage: "textformat.abc"
        ) {
            if isTerm { row.term = corrected } else { row.definition = corrected }
            if !row.flags.isEmpty { row.flags = [] }
        }
        if isTerm { checkDuplicates() }
        checkSpelling()
    }

    /// "Ignorieren": the spell checker accepts the word from now on (in every set).
    func ignoreSpelling(_ issue: SpellingIssue, isTerm: Bool) {
        speller.ignore(issue.word, lang: isTerm ? termLang : defLang)
        checkSpelling()
        importPanel.spellingDidChange()
        Announcer.announce("«\(issue.word)» wird nicht mehr als Tippfehler markiert")
    }

    // MARK: Import

    /// "N Karten übernehmen": replaces an empty list, else asks Anhängen / Ersetzen.
    func applyImport() {
        guard prompt == nil else { return }
        let cards = importPanel.pendingCards()
        guard importPanel.hasText, !cards.isEmpty else { return }
        let existing = stats.filled
        if existing > 0 {
            prompt = .applyImport(cards: cards, existing: existing, keepsProgress: isEditing)
        } else {
            apply(cards, mode: .replace)
        }
    }

    /// The answer to "Karten übernehmen" (nil: cancelled). Takes the prompt that was shown:
    /// the alert may already have cleared `prompt` when its button runs.
    func resolveApply(_ shown: Prompt, mode: ApplyMode?) {
        guard case let .applyImport(cards, _, _) = shown else { return }
        prompt = nil
        if let mode { apply(cards, mode: mode) }
    }

    private func apply(_ cards: [ParsedCard], mode: ApplyMode) {
        let created = cards.map(SetEditorRow.init(parsed:))
        undoable(
            "Karten übernehmen", toast: "\(Labels.plural(cards.count, "Karte", "Karten")) übernommen", tone: .success,
            includesImport: true
        ) {
            switch mode {
            case .append:
                appendRows(created)
            case .replace:
                // Replacing keeps the ids (and the progress) of rows with the same term.
                setRows(isEditing ? Self.withPreservedIDs(created, previous: rows) : created)
            }
            importPanel.reset()
            importPanel.isExpanded = false
        }
        checkDuplicates()
        checkSpelling()
        if mode == .append, let first = created.first {
            scroll(to: .row(first.id), anchor: .center)
        } else {
            scroll(to: .cards, anchor: .top)
        }
    }

    /// Imported rows replacing existing ones keep the card id and star of a row with the same
    /// term (`withPreservedIds`).
    static func withPreservedIDs(_ created: [SetEditorRow], previous: [SetEditorRow]) -> [SetEditorRow] {
        var pool: [String: [SetEditorRow]] = [:]
        for row in previous {
            let key = SetEditorCopy.termKey(row.term)
            guard row.cardID != nil, !key.isEmpty else { continue }
            pool[key, default: []].append(row)
        }
        for row in created {
            let key = SetEditorCopy.termKey(row.term)
            guard var matches = pool[key], !matches.isEmpty else { continue }
            let match = matches.removeFirst()
            pool[key] = matches
            row.cardID = match.cardID
            row.starred = match.starred
        }
        return created
    }

    // MARK: Saving

    /// ⌘↩ / ⌘S: takes a list still waiting in the import box over (asking first when the
    /// list has cards), validates, then creates or updates the set.
    func save() {
        guard !isSaving, !isClosed, prompt == nil else { return }
        if importPanel.isBusy {
            toasts.show("Bitte warte, bis der Import fertig ist.")
            return
        }
        let pending = importPanel.pendingCount()
        if pending > 0 {
            if isListEmpty {
                takeOverPending(append: false)
            } else {
                prompt = .pendingImport(count: pending)
                return
            }
        }
        commit()
    }

    /// The answer to "Liste noch nicht übernommen": true appends, false saves without the
    /// list, nil goes back to editing.
    func resolvePendingImport(_ shown: Prompt, append: Bool?) {
        guard case .pendingImport = shown else { return }
        prompt = nil
        guard let append else { return }
        if append { takeOverPending(append: true) }
        commit()
    }

    private func takeOverPending(append: Bool) {
        let created = importPanel.pendingCards().map(SetEditorRow.init(parsed:))
        if append { appendRows(created) } else { setRows(created) }
        importPanel.reset()
        importPanel.isExpanded = false
        checkDuplicates()
        checkSpelling()
    }

    private func commit() {
        guard validateAll() else { return }
        isSaving = true
        let cards = rows.filter(\.isFilled).map(\.draft)
        let cleanTitle = JSCompat.trim(title)
        let cleanDetails = JSCompat.trim(details)
        do {
            let saved: VocabSet
            switch mode {
            case .create:
                saved = try app.store.createSet(
                    title: cleanTitle, description: cleanDetails, termLang: termLang, defLang: defLang, cards: cards)
            case let .edit(setID):
                saved = try app.store.updateSet(
                    setID,
                    SetPatch(title: cleanTitle, description: cleanDetails, termLang: termLang, defLang: defLang, cards: cards))
            }
            isClosed = true
            finish()
            app.editorDidSave(setID: saved.id)
            app.toasts.show(isEditing ? "Änderungen gespeichert" : "Lernset erstellt", tone: .success)
        } catch {
            isSaving = false
            toasts.show(
                AppModel.message(for: error, fallback: "Das Lernset konnte nicht gespeichert werden."), tone: .danger,
                duration: .seconds(7))
        }
    }

    /// Marks every problem and moves the focus to the first one (`validateAll`).
    @discardableResult
    func validateAll() -> Bool {
        attempted = true
        var firstInvalid: SetEditorField?
        for row in rows {
            let invalid = row.isFilled && !row.isComplete
            if row.isInvalid != invalid { row.isInvalid = invalid }
            if invalid, firstInvalid == nil {
                firstInvalid = row.trimmedTerm.isEmpty ? .term(row.id) : .definition(row.id)
            }
        }
        let message = cardsError
        if isTitleEmpty {
            requestFocus(.title)
            Announcer.announce(SetEditorCopy.titleMissing, important: true)
        } else if let firstInvalid {
            requestFocus(firstInvalid)
        } else if message != nil {
            focusFirstIncomplete()
        }
        if !isTitleEmpty, let message { Announcer.announce(message, important: true) }
        return !isTitleEmpty && message == nil
    }

    private func focusFirstIncomplete() {
        guard let row = rows.first(where: { !$0.isComplete }) ?? rows.first else { return }
        requestFocus(row.trimmedTerm.isEmpty ? .term(row.id) : .definition(row.id))
    }

    // MARK: Closing

    /// Esc / "Abbrechen": stops a running import first; asks before throwing changes away.
    func cancel() {
        if importPanel.isBusy {
            importPanel.cancelImport()
            return
        }
        guard !isClosed, prompt == nil else { return }
        if isDirty {
            prompt = .discard(isEditing: isEditing)
        } else {
            close()
        }
    }

    /// "Verwerfen".
    func discard() {
        prompt = nil
        close()
    }

    private func close() {
        isClosed = true
        finish()
        app.closeEditor()
    }

    /// Stops background work and forgets this editor's undo actions (also when the sheet
    /// goes away by other means).
    func finish() {
        importPanel.teardown()
        duplicateTask?.cancel()
        duplicateTask = nil
        spellingTask?.cancel()
        spellingTask = nil
        forgetUndo()
    }

    // MARK: External changes

    /// The library changed while the sheet is open (`db.subscribe` in editor.js): a deleted
    /// set closes the editor; a set changed elsewhere is reloaded when nothing was edited.
    func storeDidChange() {
        guard case let .edit(setID) = mode, !isSaving, !isClosed else { return }
        guard let fresh = app.store.getSet(setID) else {
            isClosed = true
            finish()
            app.closeEditor()
            app.toasts.show("Dieses Lernset wurde gelöscht.", tone: .danger)
            return
        }
        guard fresh.updatedAt != loadedAt, !isDirty else { return }
        load(fresh)
        toasts.show("Das Lernset wurde anderswo geändert – die neue Version ist geladen.")
    }

    private func load(_ set: VocabSet) {
        forgetUndo()
        title = set.title
        details = set.description
        termLang = set.termLang
        defLang = set.defLang
        rows = Self.padded(set.cards.map(SetEditorRow.init(card:)))
        loadedAt = set.updatedAt
        baseline = fingerprint()
        checkDuplicates()
        checkSpelling()
    }

    /// Undo actions and their toasts only make sense while this editor (and this version of
    /// the set) is open.
    private func forgetUndo() {
        for record in undoRecords {
            undoManager?.removeAllActions(withTarget: record)
        }
        undoRecords.removeAll()
        toasts.dismissAll()
    }

    // MARK: Focus and scrolling

    func requestFocus(_ field: SetEditorField) {
        requestCounter += 1
        focusRequest = FocusRequest(field: field, token: requestCounter)
    }

    func scroll(to target: ScrollTarget, anchor: UnitPoint? = nil) {
        requestCounter += 1
        scrollRequest = ScrollRequest(target: target, anchor: anchor, token: requestCounter)
    }

    // MARK: Undo

    private struct UndoState {
        var rows: [SetEditorRow.Snapshot]
        var termLang: Lang
        var defLang: Lang
        var importPanel: ImportPanelModel.Snapshot?
    }

    /// The target of one undoable change on the undo manager.
    private final class UndoRecord {
        let before: UndoState
        let after: UndoState

        init(before: UndoState, after: UndoState) {
            self.before = before
            self.after = after
        }
    }

    private func undoState(includesImport: Bool) -> UndoState {
        UndoState(
            rows: rows.map(\.snapshot), termLang: termLang, defLang: defLang,
            importPanel: includesImport ? importPanel.snapshot() : nil)
    }

    /// Runs `change` and offers to undo it: a toast with "Rückgängig" and ⌘Z (with redo).
    private func undoable(
        _ actionName: String, toast message: String, tone: ToastCenter.Toast.Tone = .neutral, systemImage: String? = nil,
        includesImport: Bool = false, _ change: () -> Void
    ) {
        let before = undoState(includesImport: includesImport)
        change()
        let record = UndoRecord(before: before, after: undoState(includesImport: includesImport))
        undoRecords.append(record)
        registerUndo(record, actionName: actionName, reverting: true)
        toasts.show(
            message, tone: tone, systemImage: systemImage,
            action: .init("Rückgängig") { [weak self, weak record] in
                guard let self, let record, !self.isClosed else { return }
                self.undoManager?.removeAllActions(withTarget: record)
                self.restore(record.before)
            })
    }

    private func registerUndo(_ record: UndoRecord, actionName: String, reverting: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: record) { [weak self] record in
            guard let self, !self.isClosed else { return }
            self.restore(reverting ? record.before : record.after)
            self.registerUndo(record, actionName: actionName, reverting: !reverting)
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ state: UndoState) {
        rows = state.rows.map(SetEditorRow.init)
        let languagesChanged = state.termLang != termLang || state.defLang != defLang
        termLang = state.termLang
        defLang = state.defLang
        if let panel = state.importPanel {
            importPanel.restore(panel)
            if panel.isExpanded { scroll(to: .importPanel, anchor: .top) }
        } else if languagesChanged {
            importPanel.reparse()
        }
        checkDuplicates()
        checkSpelling()
    }

    // MARK: Dirty check

    private struct Fingerprint: Equatable {
        var title: String
        var details: String
        var termLang: Lang
        var defLang: Lang
        var cards: [CardDraft]
    }

    private func fingerprint() -> Fingerprint {
        Fingerprint(
            title: JSCompat.trim(title), details: JSCompat.trim(details), termLang: termLang, defLang: defLang,
            cards: rows.filter(\.isFilled).map(\.draft))
    }
}
