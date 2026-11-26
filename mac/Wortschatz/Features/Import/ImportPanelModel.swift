import Foundation
import Observation
import WortschatzCore
import UniformTypeIdentifiers
import WortschatzImport

/// The languages the import panel parses and recognises text with (`getLangs()` of the web
/// editor): the pickers' values and whether the learner chose them.
struct ImportLanguages: Equatable, Sendable {
    var termLang: Lang = .other
    var defLang: Lang = .de
    var termTouched = false
    var defTouched = false
}

/// State of the editor's smart import panel (port of src/screens/editor-import.js): the paste
/// box, file imports (text, PDF, images with OCR) through `ImportCoordinator`, live parsing
/// with `VocabParser` (debounced, off the main actor) and the separator controls. Every parse
/// goes to the editor (`onResult`), whose card list shows the pairs right away.
@Observable
final class ImportPanelModel {
    /// Everything needed to put the panel back (undo).
    struct Snapshot: Equatable {
        var text: String
        var separator: ImportSeparator
        var customSeparator: String
        var swapsSides: Bool
        var fileNotes: [String]
        var isExpanded: Bool
    }

    static let placeholder = String(
        localized:
            "Füge deine Vokabelliste hier ein – z. B. aus Word, einer PDF oder Quizlet. Begriff und Übersetzung werden automatisch erkannt."
    )
    static let hint = String(
        localized: "Tipp: Funktioniert mit abwechselnden Zeilen, Tabellen (Tab, Komma, Strichpunkt, Bindestrich) und Quizlet-Exporten.")
    /// Typing pauses this long before the text is parsed (`PARSE_DELAY`).
    static let parseDelay: Duration = .milliseconds(250)
    /// Delay after typing a custom separator.
    static let customSeparatorDelay: Duration = .milliseconds(150)

    /// The text in the paste box.
    private(set) var text = ""
    private(set) var separator: ImportSeparator = .auto
    private(set) var customSeparator = ""
    /// "Seiten tauschen" (applied after the automatic orientation).
    private(set) var swapsSides = false
    /// The latest recognition; nil while the box is empty.
    private(set) var result: ParseResult?
    /// Problems of the last file imports that did not stop them (e.g. unreadable scanned
    /// pages); shown with the parser's warnings until the text is cleared.
    private(set) var fileNotes: [String] = []
    var isExpanded: Bool
    var showsSkippedLines = false
    /// The file chooser ("Datei wählen…").
    var isChoosingFiles = false
    /// Incremented to put the keyboard focus into the paste box.
    private(set) var focusToken = 0
    /// Incremented when the detection should scroll into view (after a file import).
    private(set) var revealToken = 0

    let importer: ImportCoordinator

    /// The editor's languages; set by the owner.
    @ObservationIgnored var languages: () -> ImportLanguages = { ImportLanguages() }
    /// Called after every parse that found cards (fills untouched language pickers).
    @ObservationIgnored var onDetected: (ParseResult) -> Void = { _ in }
    /// Called after every parse, nil for an empty box: the editor's cards follow it.
    @ObservationIgnored var onResult: (ParseResult?) -> Void = { _ in }
    /// Called with the first file name of a successful file import (title suggestion).
    @ObservationIgnored var onFileName: (String) -> Void = { _ in }

    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private var parseTask: Task<Void, Never>?
    @ObservationIgnored private var parseGeneration = 0
    @ObservationIgnored private var announcedCount: Int?
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(isExpanded: Bool, toasts: ToastCenter, importer: ImportCoordinator = ImportCoordinator()) {
        self.isExpanded = isExpanded
        self.toasts = toasts
        self.importer = importer
    }

    // MARK: Derived

    /// Whether the box holds more than whitespace.
    var hasText: Bool { !JSCompat.isBlank(text) }

    /// A file import is running.
    var isBusy: Bool { importer.isRunning }

    /// "Eigenes…" is chosen but nothing typed yet.
    var needsCustomSeparator: Bool { separator == .custom && customSeparator.isEmpty }

    /// The warnings to show: file notes, then the parser's (the skipped-lines warning is covered
    /// by the skipped-lines disclosure; compared as a whole, so it works in every language).
    var warnings: [String] {
        guard let result else { return fileNotes }
        let skippedWarning = VocabParser.skippedLinesWarning(result.skipped.filter { $0.reason != .unpaired }.count)
        return fileNotes + result.warnings.filter { $0 != skippedWarning }
    }

    // MARK: Text

    /// A change typed or pasted in the box: parsed after a short pause.
    func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        scheduleParse(after: Self.parseDelay)
    }

    /// Text from elsewhere (a whole list pasted into a card field): appended below the
    /// current text or replacing it, then parsed at once (`setText`).
    func setText(_ newText: String, append: Bool) {
        let existing = JSCompat.trim(text)
        let appends = append && !existing.isEmpty
        if !appends { fileNotes = [] }
        text = appends ? "\(existing)\n\n\(newText)" : newText
        isExpanded = true
        parseNow()
    }

    /// "Text leeren".
    func clearText() {
        text = ""
        parseNow()
        focusTextArea()
    }

    func focusTextArea() {
        isExpanded = true
        focusToken += 1
    }

    // MARK: Options

    func setSeparator(_ newValue: ImportSeparator) {
        guard newValue != separator else { return }
        separator = newValue
        parseNow()
    }

    func setCustomSeparator(_ newValue: String) {
        let limited = String(newValue.prefix(8))
        guard limited != customSeparator else { return }
        customSeparator = limited
        scheduleParse(after: Self.customSeparatorDelay)
    }

    /// "Seiten tauschen" set back (undo in the editor).
    func setSwapsSides(_ value: Bool) {
        guard value != swapsSides else { return }
        swapsSides = value
        parseNow()
    }

    /// "Seiten tauschen".
    func toggleSwap() {
        swapsSides.toggle()
        parseNow()
    }

    /// Parses again with the current languages (after a picker change).
    func reparse() {
        if hasText { parseNow() }
    }

    // MARK: Parsing

    /// Brings `result` up to date when a parse is still scheduled (e.g. ⌘↩ right after typing).
    func flushParse() {
        if parseTask != nil { parseNow() }
    }

    /// Parses the text now, on the main actor.
    func parseNow() {
        parseTask?.cancel()
        parseTask = nil
        parseGeneration += 1
        guard hasText else {
            fileNotes = []
            apply(nil)
            return
        }
        apply(VocabParser.parseVocab(text, options: parseOptions()))
    }

    private func parseOptions() -> ParseOptions {
        let langs = languages()
        var options = ParseOptions(swap: swapsSides)
        if langs.termTouched, langs.termLang != .other { options.termLang = langs.termLang }
        options.defLang = langs.defTouched ? langs.defLang : .de
        separator.configure(&options, custom: customSeparator)
        return options
    }

    private func scheduleParse(after delay: Duration) {
        parseTask?.cancel()
        parseGeneration += 1
        let generation = parseGeneration
        parseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let text = self.text
            let options = self.parseOptions()
            let parsed: ParseResult? = JSCompat.trim(text).isEmpty ? nil : await Self.parse(text, options: options)
            guard !Task.isCancelled, generation == self.parseGeneration else { return }
            self.parseTask = nil
            if parsed == nil { self.fileNotes = [] }
            self.apply(parsed)
        }
    }

    /// `parseVocab` off the main actor: long lists stay smooth to type in.
    private nonisolated static func parse(_ text: String, options: ParseOptions) async -> ParseResult {
        await Task.detached(priority: .userInitiated) {
            VocabParser.parseVocab(text, options: options)
        }.value
    }

    private func apply(_ newResult: ParseResult?) {
        result = newResult
        let count = newResult?.cards.count
        if count != announcedCount {
            announcedCount = count
            if let count { Announcer.announce(SetEditorCopy.pairsDetected(count)) }
        }
        if let newResult, !newResult.cards.isEmpty { onDetected(newResult) }
        onResult(newResult)
    }

    // MARK: State

    func snapshot() -> Snapshot {
        Snapshot(
            text: text, separator: separator, customSeparator: customSeparator, swapsSides: swapsSides,
            fileNotes: fileNotes, isExpanded: isExpanded)
    }

    func restore(_ snapshot: Snapshot) {
        text = snapshot.text
        separator = snapshot.separator
        customSeparator = snapshot.customSeparator
        swapsSides = snapshot.swapsSides
        isExpanded = snapshot.isExpanded
        showsSkippedLines = false
        parseNow()
        // parseNow drops the notes of an empty box only.
        fileNotes = snapshot.fileNotes
    }

    // MARK: Files

    /// Reads files or pasted images (drop, "Datei wählen…", ⌘V) and appends their text.
    func importSources(_ sources: [ImportSource]) {
        guard !sources.isEmpty else { return }
        guard !importer.isRunning else {
            toasts.show(ImportCoordinator.busyMessage)
            return
        }
        isExpanded = true
        let langs = languages()
        importTask = Task { [weak self] in
            guard let importer = self?.importer else { return }
            // "Automatisch" (`.other`): the text recognition guesses the language itself.
            let outcome = await importer.run(
                sources, termLang: langs.termLang == .other ? nil : langs.termLang, defLang: langs.defLang)
            self?.finishImport(outcome)
        }
    }

    /// Dropped or pasted item providers. False when none of them can be imported.
    @discardableResult
    func importProviders(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { provider in
            PasteboardImage.acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        guard !usable.isEmpty else { return false }
        Task { [weak self] in
            let sources = await PasteboardImage.importSources(from: usable)
            self?.importSources(sources)
        }
        return true
    }

    /// "Bild aus Zwischenablage": an image or files copied elsewhere.
    func importFromPasteboard() {
        let sources = PasteboardImage.importSources()
        guard !sources.isEmpty else {
            toasts.show(String(localized: "In der Zwischenablage ist kein Bild und keine Datei."), systemImage: "doc.on.clipboard")
            return
        }
        importSources(sources)
    }

    /// Result of the file chooser.
    func filesChosen(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            importSources(urls.map(ImportSource.init(url:)))
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            toasts.show(AppModel.message(for: error, fallback: ImportMessages.read), tone: .danger, duration: .seconds(7))
        }
    }

    /// "Abbrechen" next to the progress: stops reading and recognition, drops the result.
    func cancelImport() {
        importer.cancel()
    }

    /// The editor closes: nothing keeps running.
    func teardown() {
        parseTask?.cancel()
        parseTask = nil
        importer.cancel()
        importTask?.cancel()
        importTask = nil
    }

    /// The end of `handleFiles` in editor-import.js: errors as toasts, texts appended below
    /// the current text, notes kept, the title suggested and a summary toast.
    private func finishImport(_ outcome: ImportCoordinator.Outcome) {
        importTask = nil
        switch outcome {
        case .busy:
            toasts.show(ImportCoordinator.busyMessage)
        case .cancelled:
            toasts.show(ImportCoordinator.cancelledMessage)
        case let .finished(batch):
            for message in batch.errorMessages {
                toasts.show(message, tone: .danger, duration: .seconds(7))
            }
            guard !batch.texts.isEmpty else { return }
            let hadText = hasText
            let notes = (hadText ? fileNotes : []) + batch.warnings
            text = batch.appended(to: text)
            parseNow()
            fileNotes = notes
            if let name = batch.firstName { onFileName(name) }
            let count = result?.cards.count ?? 0
            let pairs = Labels.plural(count, "Paar", "Paare")
            if !batch.warnings.isEmpty {
                // Do not suggest completeness: part of the content could not be read.
                toasts.show(
                    count > 0
                        ? String(
                            localized:
                                "Text teilweise erkannt – \(pairs) gefunden. Nicht alles konnte gelesen werden, siehe Hinweis.")
                        : String(
                            localized:
                                "Text teilweise erkannt – noch keine Paare gefunden. Nicht alles konnte gelesen werden, siehe Hinweis."
                        ),
                    tone: .warning, duration: .seconds(7))
            } else if count > 0 {
                toasts.show(String(localized: "Text erkannt – \(pairs) gefunden. Prüfe die Karten."), tone: .success)
            } else {
                toasts.show(String(localized: "Text eingefügt. Es wurden noch keine Paare erkannt."))
            }
            revealToken += 1
        }
    }
}
