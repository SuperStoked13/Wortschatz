import Carbon
import Testing

@testable import Wortschatz

/// «Any key continues» treats input methods (Pinyin, Kana …) differently from plain keyboard
/// layouts (ABC, Arabic): `InputSource` tells them apart.
@MainActor
@Suite("Eingabequelle: Eingabemethode oder Tastaturbelegung")
struct InputSourceTests {
    @Test("Eingabemethoden setzen zusammen, Tastaturbelegungen tippen")
    func sourceTypes() {
        #expect(!InputSource.isInputMethod(sourceType: kTISTypeKeyboardLayout as String))
        #expect(InputSource.isInputMethod(sourceType: kTISTypeKeyboardInputMode as String))
        #expect(InputSource.isInputMethod(sourceType: kTISTypeKeyboardInputMethodWithoutModes as String))
    }

    @Test("Die aktuelle Eingabequelle lässt sich lesen")
    func currentSource() {
        // Whatever this Mac uses: the same answer twice, no crash.
        #expect(InputSource.isInputMethodActive == InputSource.isInputMethodActive)
    }
}
