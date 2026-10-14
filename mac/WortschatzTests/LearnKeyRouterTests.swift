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
