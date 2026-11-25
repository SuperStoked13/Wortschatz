import Foundation
import WortschatzCore
#if os(macOS)
import AppKit
#endif

/// The language of the app's texts: German (the source language, Swiss spelling) or English.
/// The Mac decides (System Settings › General › Language & Region, which also has a setting per
/// app); Einstellungen › Allgemein can pin one for Wortschatz alone. macOS picks the language when
/// the app starts, so a change applies from the next start.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
    /// Whatever the Mac prefers (German or English, else German).
    case system
    case de
    case en

    var id: String { rawValue }

    /// The defaults key macOS reads at launch for the app's languages. The per-app setting of
    /// System Settings writes the same key into the app's own domain.
    private static let defaultsKey = "AppleLanguages"

    /// The language of the texts on screen now: "de" or "en".
    static let current: String = Bundle.main.preferredLocalizations.first == "en" ? "en" : "de"

    /// The choice stored for Wortschatz alone (`.system` when the Mac decides).
    static var choice: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
            let first = (UserDefaults.standard.persistentDomain(forName: id)?[defaultsKey] as? [String])?.first
        else { return .system }
        if first.hasPrefix("en") { return .en }
        if first.hasPrefix("de") { return .de }
        return .system
    }

    /// Stores `choice` for the next start (System forgets the app's own setting).
    static func choose(_ choice: AppLanguage) {
        switch choice {
        case .system: UserDefaults.standard.removeObject(forKey: defaultsKey)
        case .de, .en: UserDefaults.standard.set([choice.rawValue], forKey: defaultsKey)
        }
    }

    /// The language the Mac itself would pick for the app ("de" or "en"), ignoring the app's own
    /// setting.
    static var systemLanguage: String {
        let preferred =
            CFPreferencesCopyValue(
                defaultsKey as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String] ?? Locale.preferredLanguages
        let match = Bundle.preferredLocalizations(from: ["de", "en"], forPreferences: preferred).first
        return match == "en" ? "en" : "de"
    }

    /// The language `choice` leads to at the next start.
    static func language(for choice: AppLanguage) -> String {
        choice == .system ? systemLanguage : choice.rawValue
    }

    /// The locale of dates and numbers in the texts: Swiss German, or with English the Mac's own
    /// format when it is English too (else British English).
    static let formattingLocale: Locale = {
        if current == "de" { return Locale(identifier: "de_CH") }
        if Locale.current.language.languageCode == .english { return Locale.current }
        return Locale(identifier: "en_GB")
    }()

    /// Points the core's German texts at the String Catalog. Runs first thing at launch, before
    /// any text is built.
    static func install() {
        CoreText.translate = { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }
        CoreText.translateInTable = { Bundle.main.localizedString(forKey: $0, value: $0, table: $1) }
    }
}

#if os(macOS)
// MARK: - Restarting in the new language

extension AppLanguage {
    /// The launch argument of the new instance: the process id of the one that is quitting.
    private static let previousInstanceFlag = "--after-language-change"

    /// Set by "Jetzt neu starten"; the app delegate starts the new instance once quitting is sure.
    @MainActor static var relaunchRequested = false

    /// Quits (saving as always) and starts again, so macOS picks the new language.
    @MainActor static func relaunch() {
        relaunchRequested = true
        NSApp.terminate(nil)
    }

    /// Starts a second instance of the app that waits until this one has quit
    /// (`waitForPreviousInstance`). Called by the app delegate after the library was saved.
    @MainActor static func launchNewInstance() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [previousInstanceFlag, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    /// In an instance started by `launchNewInstance`: waits (10 s at most) until the previous one
    /// has quit, so the library is not opened while it may still be written. Runs before the
    /// library is opened; returns at once for a normal launch.
    static func waitForPreviousInstance(arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.firstIndex(of: previousInstanceFlag), flag + 1 < arguments.count,
            let pid = pid_t(arguments[flag + 1])
        else { return }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let previous = NSRunningApplication(processIdentifier: pid), !previous.isTerminated else { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
#endif
