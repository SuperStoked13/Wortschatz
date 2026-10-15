import SwiftUI
import Testing
import WortschatzCore

@testable import Wortschatz

/// The Learn screen's key mapping for typing on multiple choice: ⌫ arrives as U+0008 through
/// SwiftUI's `onKeyPress` but as U+007F through the window's key fallback, fn-⌦ as U+F728.
@Suite("LearnKeyRouter: deleting typed letters")
@MainActor
struct LearnKeyRouterTests {
    static func input(_ key: KeyEquivalent, _ characters: String, _ modifiers: EventModifiers = []) -> KeyInput? {
        LearnKeyRouter.input(key: key, characters: characters, modifiers: modifiers)
    }

    @Test("⌫ and fn-⌦ delete a letter, however they arrive")
    func deleteKeys() {
        #expect(Self.input(.delete, "\u{8}") == .deleteBackward)
        #expect(Self.input(.delete, "\u{7F}") == .deleteBackward)
        #expect(Self.input(KeyEquivalent("\u{7F}"), "\u{7F}") == .deleteBackward)
        #expect(Self.input(.deleteForward, "\u{F728}") == .deleteBackward)
        #expect(Self.input(.deleteForward, "\u{F728}", .function) == .deleteBackward)
    }

    @Test("⌥⌫ deletes a word; ⌘⌫ stays with the menu, ⌃⌫ and ⇧⌫ do nothing here")
    func modifiedDeleteKeys() {
        #expect(Self.input(.delete, "\u{7F}", .option) == .deleteWordBackward)
        #expect(Self.input(.delete, "\u{7F}", .command) == nil)
        #expect(Self.input(.delete, "\u{7F}", .control) == nil)
        #expect(Self.input(.delete, "\u{7F}", .shift) == nil)
    }

    @Test("Delete keys are no letters, and letters are no delete keys")
    func lettersStayLetters() {
        #expect(Self.input(KeyEquivalent("a"), "a") == .character("a"))
        #expect(Self.input(KeyEquivalent(" "), " ") == .character(" "))
        #expect(Self.input(.return, "\r") == .returnKey)
        #expect(!LearnKeyRouter.isDeleteKey(KeyEquivalent("x"), characters: "x"))
    }
}

/// Arabic and Chinese keyboards (spec «Keyboard and input methods»): Arabic-Indic digits choose
/// like 1–4, the Arabic «لا» key types its two letters, and after an answer a key typed with an
/// input method (Pinyin) continues without its raw letter.
@Suite("LearnKeyRouter: Arabic and Chinese keyboards")
@MainActor
struct LearnKeyRouterScriptTests {
    static func input(_ characters: String, _ modifiers: EventModifiers = []) -> KeyInput? {
        let key = KeyEquivalent(characters.first ?? " ")
        return LearnKeyRouter.input(key: key, characters: characters, modifiers: modifiers)
    }

    @Test("Arabic-Indic and Persian digits are digits")
    func arabicDigits() {
        #expect(Self.input("1") == .digit(1))
        #expect(Self.input("٠") == .digit(0))
        #expect(Self.input("٣") == .digit(3))
        #expect(Self.input("٤", .shift) == .digit(4))
        #expect(Self.input("۲") == .digit(2))
        #expect(Self.input("٣", .command) == nil)
        // Other numerals stay characters (full-width, superscript).
        #expect(Self.input("３") == .character("３"))
        #expect(Self.input("²") == .character("²"))
    }

    @Test("A key that types several letters types them all")
    func multiLetterKeys() {
        #expect(Self.input("لا") == .character("لا"))
        #expect(Self.input("ب") == .character("ب"))
        #expect(Self.input("中") == .character("中"))
        #expect(Self.input("a1") == nil)
        #expect(Self.input("لا", .control) == nil)
    }

    @Test("After an answer, a letter typed with an input method only continues")
    func inputMethodContinues() {
        #expect(LearnKeyRouter.continuing(.character("n"), afterAnswer: true, inputMethod: true) == .character(" "))
        // A plain layout (Arabic, ABC) types the letter into the next answer as before.
        #expect(LearnKeyRouter.continuing(.character("n"), afterAnswer: true, inputMethod: false) == .character("n"))
        #expect(LearnKeyRouter.continuing(.character("ب"), afterAnswer: true, inputMethod: false) == .character("ب"))
        // While answering, letters keep picking options (type-ahead); other keys never change.
        #expect(LearnKeyRouter.continuing(.character("n"), afterAnswer: false, inputMethod: true) == .character("n"))
        #expect(LearnKeyRouter.continuing(.digit(2), afterAnswer: true, inputMethod: true) == .digit(2))
        #expect(LearnKeyRouter.continuing(.returnKey, afterAnswer: true, inputMethod: true) == .returnKey)
        #expect(LearnKeyRouter.continuing(.character(" "), afterAnswer: true, inputMethod: true) == .character(" "))
    }

    @Test("The input source is asked only when it matters")
    func inputSourceAskedLazily() {
        var asked = 0
        func inputMethod() -> Bool {
            asked += 1
            return true
        }
        _ = LearnKeyRouter.continuing(.character("n"), afterAnswer: false, inputMethod: inputMethod())
        _ = LearnKeyRouter.continuing(.returnKey, afterAnswer: true, inputMethod: inputMethod())
        #expect(asked == 0)
        _ = LearnKeyRouter.continuing(.character("n"), afterAnswer: true, inputMethod: inputMethod())
        #expect(asked == 1)
    }
}
