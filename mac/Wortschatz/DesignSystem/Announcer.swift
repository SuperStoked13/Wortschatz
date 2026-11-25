import SwiftUI

/// VoiceOver announcements (spec §5: "VoiceOver announces feedback"), e.g. for the flows'
/// `.announce(String)` effect.
enum Announcer {
    /// Posts `text` for VoiceOver to speak (without VoiceOver nobody hears it). `important`
    /// interrupts current speech (wrong answers, errors).
    static func announce(_ text: String, important: Bool = false) {
        guard !text.isEmpty else { return }
        var message = AttributedString(text)
        message.accessibilitySpeechAnnouncementPriority = important ? .high : .default
        AccessibilityNotification.Announcement(message).post()
    }
}
