import Carbon

/// The keyboard's current input source (Text Input Sources). Its own file: Carbon's
/// `EventModifiers` would clash with SwiftUI's wherever both are imported.
enum InputSource {
    /// Whether the current keyboard input source is an input method (Pinyin, Zhuyin, Kana …)
    /// rather than a plain layout (ABC, Swiss German, Arabic): its keys compose text instead of
    /// typing their letter.
    static var isInputMethodActive: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return false }
        return isInputMethod(sourceType: Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String)
    }

    /// An input source of `sourceType` (`kTISPropertyInputSourceType`) composes text: anything but
    /// a plain keyboard layout.
    static func isInputMethod(sourceType: String) -> Bool {
        sourceType != (kTISTypeKeyboardLayout as String)
    }
}
