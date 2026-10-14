import SwiftUI
import WortschatzCore

/// The Write screen's key strategy (spec §4.3), the same as Learn's: every hardware key press
/// becomes the flow's `KeyInput` (with the repeat flag; `LearnKeyRouter.input` does the
/// mapping) and the `WriteFlow` reducer decides what it does. Which keys the screen takes
/// depends on where the keyboard focus is:
///
/// - **Screen focus** (feedback, round summary, results, messages): Return, ⌥↩, ⌘↩, esc, and
///   after a correct answer any printable key ("Weiter mit beliebiger Taste": the key continues
///   and lands in the next answer field).
/// - **Answer field focus** (question, copy step): the field keeps every other key; Return
///   arrives through its `onSubmit`, ⌥↩ and esc through the field's own key handler
///   (`studyFieldKeys`), ⌘↩ as a key equivalent of the Lernen menu.
///
/// Shortcuts with ⌘ or ⌃ (other than ⌘↩), Tab, the arrows and function keys always pass
/// through, so menus, focus navigation and VoiceOver keep working.
enum WriteKeyRouter {
    /// Where the keyboard focus is on the Write screen.
    enum Focus: Hashable {
        /// The screen itself (it is focusable and receives the keys).
        case screen
        /// The answer or copy field.
        case answer
    }

    /// The flow's key for a SwiftUI key press, nil for keys the screen leaves alone.
    static func input(for press: SwiftUI.KeyPress) -> KeyInput? {
        LearnKeyRouter.input(key: press.key, characters: press.characters, modifiers: press.modifiers)
    }

    /// Whether the screen consumes `input` in `state` (otherwise it travels on, e.g. to focus
    /// navigation).
    static func consumes(_ input: KeyInput, in state: WriteFlow.State, focus: Focus?) -> Bool {
        switch input {
        case .returnKey, .optionReturn, .commandReturn, .escape:
            return true
        case .digit, .character:
            return focus != .answer && state.phase == .feedback(.correct)
        case .arrow, .deleteBackward, .deleteWordBackward:
            return false
        }
    }

    /// Where the focus belongs in `state`: the answer field while something is typed, the
    /// screen everywhere else (so Return reaches the reducer). nil while a sheet, popover or
    /// alert is open: the focus is theirs then.
    static func focus(for state: WriteFlow.State) -> Focus? {
        guard !state.isBlocked else { return nil }
        return state.isInputEditable ? .answer : .screen
    }
}
