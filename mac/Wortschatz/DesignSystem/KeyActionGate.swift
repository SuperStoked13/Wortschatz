import AppKit

/// Keeps one key press from doing two things (spec §4.3: "Pressing Return once must never
/// trigger two transitions: debounce state changes and ignore key repeat"). It guards buttons
/// bound to a key (`PrimaryActionButton`, `SecondaryButton`); the study screens have the same
/// rules in their flow reducers (`LearnFlow.INPUT_LOCK_MS`).
///
/// - A held key's auto-repeats never trigger a bound button: holding Return through "Fertig" does
///   not also press the next screen's "Lernen ↩".
/// - After Return moved to another screen (`returnKeyMoved(by:)`, called by the navigation), the
///   new screen's key-bound buttons wait `settleTime`, so a quick double press meant for one step
///   does not run the next one as well.
/// - A screen that changed by itself (`hold(for:)`) holds them back a little longer.
///
/// Clicks are never held back.
enum KeyActionGate {
    /// As long as the study flows' input lock.
    static let settleTime: Duration = .milliseconds(280)

    /// The end of the current settle time.
    private static var settlesUntil: ContinuousClock.Instant?

    /// Whether the event being handled (if it is a key press) may trigger a key-bound button.
    static func allowsCurrentEvent() -> Bool {
        allows(NSApp.currentEvent)
    }

    /// Navigation calls this with the event that caused it: when that was Return (or Enter), the
    /// next key-bound action waits `settleTime`.
    static func returnKeyMoved(by event: NSEvent?, at now: ContinuousClock.Instant = .now) {
        guard let event, isReturnKeyDown(event) else { return }
        settlesUntil = now + settleTime
    }

    /// The screen changed under the learner's fingers without a key press (an exam handed in by
    /// its timer): key-bound buttons wait `duration`, so a Return meant for the screen that went
    /// away does not press the new screen's button.
    static func hold(for duration: Duration, at now: ContinuousClock.Instant = .now) {
        let until = now + duration
        if let settlesUntil, settlesUntil > until { return }
        settlesUntil = until
    }

    /// Whether `event` may trigger a key-bound button at `now`: anything but a key press, or a
    /// key press that is neither an auto-repeat nor inside the settle time.
    static func allows(_ event: NSEvent?, at now: ContinuousClock.Instant = .now) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        if event.isARepeat { return false }
        if let settlesUntil, now < settlesUntil { return false }
        return true
    }

    /// Forgets a running settle time (tests).
    static func reset() {
        settlesUntil = nil
    }

    private static func isReturnKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Return, and Enter on the keypad (or fn-Return).
        return event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}"
    }
}
