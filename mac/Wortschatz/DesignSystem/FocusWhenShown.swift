import AppKit
import SwiftUI

private struct FocusTaskID<Key: Hashable>: Hashable {
    let key: Key
    let isWanted: Bool
}

extension View {
    /// Puts the keyboard focus into this text field as soon as it is really in the window, so
    /// typing works without clicking first. Meant for screens with a single text field (the
    /// study screens' answer field); give the field the same `accessibilityIdentifier`.
    ///
    /// SwiftUI alone is unreliable here: a request made in the same update that creates the
    /// field is ignored, and after some step changes (e.g. from a round's checkpoint into the
    /// next round) it ignores every request, leaving the keys with the window. So the request is
    /// repeated for a moment while AppKit's real first responder is checked, and when SwiftUI
    /// does not move the keys, the field is made first responder directly through AppKit
    /// (SwiftUI's focus state follows).
    ///
    /// `key` changes with every new step; nothing happens while `isWanted` is false (a popover,
    /// sheet or alert has the keys then, and the field gets them back when it closes).
    ///
    /// Only *this* field counts as having the keys: when a step swaps one field for another (the
    /// answer field for the copy field after a miss), the old one keeps the keys while it fades
    /// out. Taking them from it then would end its editing mid-transition, so the request waits
    /// until it is gone and then moves the keys into the new field.
    func focusWhenShown<Value: Hashable, Key: Hashable>(
        _ focus: FocusState<Value?>.Binding, equals value: Value, isWanted: Bool, key: Key, fieldIdentifier: String
    ) -> some View {
        task(id: FocusTaskID(key: key, isWanted: isWanted)) {
            guard isWanted else { return }
            for (attempt, delay) in [0, 40, 100, 200, 400, 600].enumerated() {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled else { return }
                guard let window = NSApp.keyWindow else {
                    if attempt == 0 { focus.wrappedValue = value }
                    continue
                }
                let field = AnswerFieldLocator.field(in: window, identifier: fieldIdentifier)
                switch AnswerFieldLocator.keyHolder(in: window, field: field, identifier: fieldIdentifier) {
                case .field:
                    if focus.wrappedValue != value { focus.wrappedValue = value }
                    return
                case .otherField:
                    continue
                case .none:
                    if attempt == 0 {
                        focus.wrappedValue = value
                    } else if let field {
                        window.makeFirstResponder(field)
                    }
                }
            }
        }
    }
}

/// Finds a study screen's answer field in the window's AppKit views, and who has the keys.
enum AnswerFieldLocator {
    static func field(in window: NSWindow, identifier: String) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var editable: [NSTextField] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, field.isEditable, field.isEnabled, !field.isHiddenOrHasHiddenAncestor {
                if field.accessibilityIdentifier() == identifier { return field }
                editable.append(field)
            }
            stack.append(contentsOf: view.subviews)
        }
        // A study screen has a single editable field; anything else is ambiguous.
        return editable.count == 1 ? editable[0] : nil
    }

    enum KeyHolder: Equatable {
        /// The wanted field is being edited.
        case field
        /// Another text field in the window is (e.g. the previous step's field, fading out).
        case otherField
        /// No text field: the window or another control has the keys.
        case none
    }

    /// Who has the window's keys, seen from the wanted `field` (nil when it cannot be told apart
    /// from another field yet). A text field being edited hands its keys to the window's field
    /// editor, whose delegate it is.
    static func keyHolder(in window: NSWindow, field: NSTextField?, identifier: String) -> KeyHolder {
        guard let editor = window.firstResponder as? NSTextView else { return .none }
        // An editor of an unknown kind: taken as the field, as it always was.
        guard let editing = editor.delegate as? NSTextField else { return .field }
        // The edited field has left the window (a removed step).
        guard editing.window === window else { return .none }
        if let field { return editing === field ? .field : .otherField }
        return editing.accessibilityIdentifier() == identifier ? .field : .otherField
    }
}
