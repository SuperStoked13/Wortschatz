import AppKit

/// The app delegate (`@NSApplicationDelegateAdaptor`): quitting waits until the library is
/// saved, or until the learner decided what happens to changes that cannot be saved
/// (`AppModel.replyToTermination`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running app's model (set when the app starts).
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.replyToTermination() ?? .terminateNow
    }
}
