import AppKit
import SwiftUI
import WortschatzCore

/// The Learn screen's single key strategy (spec §4.3): every hardware key press is translated
/// into the flow's `KeyInput` (with the repeat flag) and the `LearnFlow` reducer decides what it
/// does. Which keys the screen takes depends on where the keyboard focus is:
///
/// - **Screen focus** (multiple choice, feedback, checkpoint, finish): Return, ⌥↩, ⌘↩, esc,
///   the arrows, digits, letters and ⌫ of a multiple-choice question (typing picks an option,
///   `LearnFlow.typeAhead`), and any printable key after feedback ("any key continues").
/// - **Answer field focus** (written question, copy step): letters, digits and arrows belong to
///   the text field. Return arrives through the field's `onSubmit`; ⌥↩ and esc through the
///   field's own key handler (`studyFieldKeys`, see `fieldInput`), because the field editor
///   would otherwise insert a line break for ⌥↩ and swallow esc before the Lernen menu sees
///   them; ⌘↩ reaches the menu first.
///
/// Shortcuts with ⌘ or ⌃ (other than ⌘↩), Tab and function keys always pass through, so menus,
/// focus navigation and VoiceOver keep working. ⌘↩ (and, without a focused field, ⌥↩ and esc)
/// may also arrive as key equivalents of the Lernen menu (`LearnController.handle(_:showOptions:)`).
enum LearnKeyRouter {
    /// Where the keyboard focus is on the Learn screen.
    enum Focus: Hashable {
        /// The screen itself (it is focusable and receives the keys).
        case screen
        /// The answer or copy field.
        case answer
    }

    /// The flow's key for a SwiftUI key press, nil for keys the screen leaves alone.
    static func input(for press: SwiftUI.KeyPress) -> KeyInput? {
        input(key: press.key, characters: press.characters, modifiers: press.modifiers)
    }

    static func input(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> KeyInput? {
        let typing: EventModifiers = [.command, .control, .option, .shift]
        if isDeleteKey(key, characters: characters) {
            // ⌘⌫ stays with the menu ("Löschen" deletes the set).
            switch modifiers.intersection(typing) {
            case []: return .deleteBackward
            case .option: return .deleteWordBackward
            default: return nil
            }
        }
        switch key {
        case .return, KeyEquivalent("\u{3}"):
            // Return and the keypad's Enter.
            if modifiers.contains(.control) { return nil }
            if modifiers.contains(.command) { return .commandReturn }
            if modifiers.contains(.option) { return .optionReturn }
            return .returnKey
        case .escape:
            return modifiers.isDisjoint(with: typing) ? .escape : nil
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            // Arrow keys carry the function/keypad flags; any real modifier means something else.
            guard modifiers.isDisjoint(with: typing) else { return nil }
            switch key {
            case .upArrow: return .arrow(.up)
            case .downArrow: return .arrow(.down)
            case .leftArrow: return .arrow(.left)
            default: return .arrow(.right)
            }
        default:
            break
        }
        guard modifiers.isDisjoint(with: [.command, .control]), characters.count == 1, let character = characters.first
        else { return nil }
        if character.isASCII, let digit = character.wholeNumberValue { return .digit(digit) }
        guard isPrintable(character) else { return nil }
        return .character(String(character))
    }

    /// Whether the screen consumes `input` in `state` (otherwise it travels on, e.g. into the
    /// answer field or to focus navigation).
    static func consumes(_ input: KeyInput, in state: LearnFlow.State, focus: Focus?) -> Bool {
        switch input {
        case .returnKey, .optionReturn, .commandReturn, .escape:
            return true
        case .digit, .arrow, .character:
            guard focus != .answer else { return false }
            switch state.phase {
            case .question(.mc): return true
            case .feedback: return true
            case .question(.written), .copy, .checkpoint, .finished, .allMastered, .empty: return false
            }
        case .deleteBackward, .deleteWordBackward:
            return focus != .answer && state.phase == .question(.mc)
        }
    }

    /// Where the focus belongs in `state`: the answer field while something is typed, the
    /// screen everywhere else (so Return and the digit keys reach the reducer). nil while a
    /// prompt, popover or sheet is open: the focus is theirs then.
    static func focus(for state: LearnFlow.State) -> Focus? {
        guard state.prompt == nil, state.overlay == nil else { return nil }
        switch state.phase {
        case .question(.written), .copy: return .answer
        default: return .screen
        }
    }

    /// The keys an answer or copy field hands to the flow itself: ⌥↩ ("Weiss ich nicht") and esc
    /// ("Beenden"). Return stays with the field's `onSubmit` and ⌘↩ with the Lernen menu; every
    /// other key is typing.
    static func fieldInput(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> KeyInput? {
        switch input(key: key, characters: characters, modifiers: modifiers) {
        case .optionReturn: .optionReturn
        case .escape: .escape
        case .returnKey, .commandReturn, .digit, .arrow, .character, .deleteBackward, .deleteWordBackward, nil: nil
        }
    }

    /// The keys `fieldInput` can map (Return, the keypad's Enter, esc), for `onKeyPress(keys:)`.
    static let fieldKeys: Set<KeyEquivalent> = [.return, KeyEquivalent("\u{3}"), .escape]

    /// Whether the focused text field is composing: a dead key (^, ¨, `) waits for its letter or
    /// an input method shows marked text. Return and esc belong to the composition then.
    static var isComposingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    /// ⌫ comes as U+0008 (SwiftUI's `.delete`) or U+007F (AppKit's characters, e.g. through the
    /// window's key fallback), fn-⌦ as `.deleteForward` (U+F728). With no caret on a
    /// multiple-choice question, both remove the last letter.
    static func isDeleteKey(_ key: KeyEquivalent, characters: String) -> Bool {
        let codes: Set<UInt32> = [0x08, 0x7F, 0xF728]
        if let scalar = key.character.unicodeScalars.first, codes.contains(scalar.value) { return true }
        let typed = characters.unicodeScalars
        return typed.count == 1 && codes.contains(typed.first!.value)
    }

    /// Letters, digits, punctuation, symbols and the space bar; not control characters (Tab,
    /// Delete) or the private-use characters AppKit gives function keys.
    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            !(0xF700...0xF8FF).contains(scalar.value) && scalar.properties.generalCategory != .control
        }
    }
}

extension View {
    /// ⌥↩ and esc typed in an answer or copy field go to the study flow
    /// (`LearnKeyRouter.fieldInput`) with their repeat flag, so "Weiss ich nicht" and "Beenden"
    /// work while typing; the reducer decides what they do (an open prompt or sheet blocks them).
    func studyFieldKeys(_ press: @escaping (KeyInput, _ isRepeat: Bool) -> Void) -> some View {
        onKeyPress(keys: LearnKeyRouter.fieldKeys, phases: [.down, .repeat]) { keyPress in
            guard !LearnKeyRouter.isComposingText,
                let input = LearnKeyRouter.fieldInput(
                    key: keyPress.key, characters: keyPress.characters, modifiers: keyPress.modifiers)
            else { return .ignored }
            press(input, keyPress.phase == .repeat)
            return .handled
        }
    }
}
