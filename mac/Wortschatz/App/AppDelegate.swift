import AppKit

/// The app delegate (`@NSApplicationDelegateAdaptor`): quitting waits until the library is
/// saved, or until the learner decided what happens to changes that cannot be saved
/// (`AppModel.replyToTermination`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running app's model (set when the app starts).
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let reply = model.replyToTermination()
        // "Jetzt neu starten" (Einstellungen › Sprache): the library is saved, so the new instance
        // may start; it waits until this one has quit.
        if reply == .terminateNow, AppLanguage.relaunchRequested { AppLanguage.launchNewInstance() }
        return reply
    }
}
