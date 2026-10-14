import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WortschatzImport

/// The import panel's paste box: a plain-text `NSTextView` that also takes files and images.
///
/// A SwiftUI `TextEditor` would swallow dropped files (its text view inserts their paths) and
/// cannot paste an image, so this view handles both itself:
/// - ⌘V (and Bearbeiten › Einsetzen) of copied files, or of an image without text (a
///   screenshot, a photo from Vorschau), imports them instead of pasting text.
/// - Files and images dragged onto it are imported; dragged text is inserted as usual.
/// - Tab moves the focus on (like the other fields); ⌥⇥ inserts a tab character.
/// - It has its own undo stack, which programmatic changes (an import, "Text leeren") reset.
struct ImportTextView: NSViewRepresentable {
    @Binding var text: String
    /// Incremented by the owner to put the keyboard focus here.
    var focusToken: Int
    var onFocusChange: (Bool) -> Void
    var onImport: ([ImportSource]) -> Void
    var onDragTargetChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = ImportNSTextView(frame: .zero)
        textView.delegate = coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: ImportTextView.inset.width - 5, height: ImportTextView.inset.height)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.focusRingType = .none
        textView.string = text
        textView.setAccessibilityLabel("Vokabelliste zum Importieren")
        textView.setAccessibilityIdentifier("editor-import-text")
        textView.setAccessibilityHelp(ImportPanelModel.hint)
        textView.onImport = { [weak coordinator] sources in coordinator?.parent.onImport(sources) }
        textView.onDragTargetChange = { [weak coordinator] targeted in coordinator?.parent.onDragTargetChange(targeted) }
        textView.onFocusChange = { [weak coordinator] focused in coordinator?.parent.onFocusChange(focused) }
        textView.updateDragTypeRegistration()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        coordinator.textView = textView
        coordinator.focusToken = focusToken
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // Typing undo refers to the old text.
            coordinator.undoManager.removeAllActions()
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            // After the panel has appeared (it may have just been expanded).
            Task { @MainActor in
                textView.window?.makeFirstResponder(textView)
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.onFocusChange = { _ in }
        coordinator.textView?.onDragTargetChange = { _ in }
    }

    /// Text inset (also used to place the SwiftUI placeholder exactly over the first line).
    static let inset = CGSize(width: 13, height: 10)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ImportTextView
        weak var textView: ImportNSTextView?
        var focusToken = 0
        /// The paste box's own undo stack (not the sheet's, which holds card-list actions).
        let undoManager = UndoManager()

        init(_ parent: ImportTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }
    }
}

/// The text view behind `ImportTextView`.
final class ImportNSTextView: NSTextView {
    var onImport: ([ImportSource]) -> Void = { _ in }
    var onDragTargetChange: (Bool) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    /// The current drag carries files or images (imported, not inserted as text).
    private var isImportDrag = false
    /// The last drop was an import (no text-insertion clean-up afterwards).
    private var didImportDrop = false

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange(false) }
        return resigned
    }

    /// Tab leaves the box like in every other field; ⌥⇥ still inserts a tab character.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if Self.wantsImport(pasteboard, preferText: true) {
            onImport(PasteboardImage.importSources(from: pasteboard))
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.wantsImport(.general, preferText: true) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// Whether the pasteboard should be imported rather than inserted: copied files, or an
    /// image (for a paste only when it comes without text, like a screenshot).
    static func wantsImport(_ pasteboard: NSPasteboard, preferText: Bool) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        guard PasteboardImage.hasImage(pasteboard) else { return false }
        guard preferText else { return true }
        let text = pasteboard.string(forType: .string) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Drag and drop

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL] + PasteboardImage.imageTypes.map { NSPasteboard.PasteboardType($0.identifier) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isImportDrag = Self.wantsImport(sender.draggingPasteboard, preferText: false)
        guard isImportDrag else { return super.draggingEntered(sender) }
        onDragTargetChange(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isImportDrag ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard isImportDrag else {
            super.draggingExited(sender)
            return
        }
        isImportDrag = false
        onDragTargetChange(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isImportDrag ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isImportDrag else {
            didImportDrop = false
            return super.performDragOperation(sender)
        }
        isImportDrag = false
        didImportDrop = true
        onDragTargetChange(false)
        let sources = PasteboardImage.importSources(from: sender.draggingPasteboard)
        guard !sources.isEmpty else { return false }
        onImport(sources)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if didImportDrop {
            didImportDrop = false
            return
        }
        super.concludeDragOperation(sender)
    }
}
