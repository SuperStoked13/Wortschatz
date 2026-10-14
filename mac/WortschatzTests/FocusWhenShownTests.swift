import AppKit
import Testing

@testable import Wortschatz

/// `focusWhenShown` after a miss: the answer field gives way to the copy field. The old field
/// keeps the keys while it fades out; only once it is gone may the copy field take them.
/// Plays that swap with real AppKit text fields in a window that is never shown.
@Suite("Focus moves into the copy field after a miss")
@MainActor
struct FocusWhenShownTests {
    static func makeField(_ identifier: String?) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.isEditable = true
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        return field
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("The fading answer field keeps the keys; the copy field takes them once it is gone")
    func swapToCopyField() {
        let window = Self.makeWindow()
        let answer = Self.makeField("learn-answer")
        let copy = Self.makeField("learn-copy")
        window.contentView?.addSubview(answer)
        #expect(window.makeFirstResponder(answer))
        #expect(AnswerFieldLocator.keyHolder(in: window, field: answer, identifier: "learn-answer") == .field)

        // The copy field appears while the answer field still fades out with the keys.
        window.contentView?.addSubview(copy)
        let target = AnswerFieldLocator.field(in: window, identifier: "learn-copy")
        #expect(target === copy)
        #expect(AnswerFieldLocator.keyHolder(in: window, field: target, identifier: "learn-copy") == .otherField)

        // The answer field is gone: nobody has the keys until the copy field takes them.
        answer.removeFromSuperview()
        #expect(AnswerFieldLocator.keyHolder(in: window, field: copy, identifier: "learn-copy") != .field)
        #expect(window.makeFirstResponder(copy))
        #expect(AnswerFieldLocator.keyHolder(in: window, field: copy, identifier: "learn-copy") == .field)
        window.close()
    }

    @Test("Without identifiers the single remaining field is found, two are ambiguous")
    func withoutIdentifiers() {
        let window = Self.makeWindow()
        let old = Self.makeField(nil)
        let new = Self.makeField(nil)
        window.contentView?.addSubview(old)
        window.contentView?.addSubview(new)
        #expect(window.makeFirstResponder(old))
        #expect(AnswerFieldLocator.field(in: window, identifier: "learn-copy") == nil)
        // Ambiguous and another field is being edited: wait, never claim the keys are here.
        #expect(AnswerFieldLocator.keyHolder(in: window, field: nil, identifier: "learn-copy") == .otherField)
        old.removeFromSuperview()
        #expect(AnswerFieldLocator.field(in: window, identifier: "learn-copy") === new)
        #expect(window.makeFirstResponder(new))
        #expect(AnswerFieldLocator.keyHolder(in: window, field: new, identifier: "learn-copy") == .field)
        window.close()
    }

    @Test("No text field being edited: nobody has the keys")
    func nothingEdited() {
        let window = Self.makeWindow()
        let field = Self.makeField("write-copy")
        window.contentView?.addSubview(field)
        #expect(AnswerFieldLocator.keyHolder(in: window, field: field, identifier: "write-copy") == .none)
        window.close()
    }
}
