import SwiftUI
import WortschatzCore

/// Sprache (Einstellungen › Allgemein): System (the Mac decides), Deutsch or English. macOS picks
/// the language when the app starts, so a choice that leads to another language offers a restart.
struct SettingsLanguageSection: View {
    @State private var choice = AppLanguage.choice

    var body: some View {
        let next = AppLanguage.language(for: choice)
        Section {
            LabeledContent {
                Picker("Sprache", selection: $choice) {
                    Text("System").tag(AppLanguage.system)
                    Divider()
                    // Each language in its own language.
                    Text(verbatim: "Deutsch").tag(AppLanguage.de)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: choice) { _, choice in AppLanguage.choose(choice) }
            } label: {
                Text("Sprache der App")
                Text(hint)
            }
            if next != AppLanguage.current {
                LabeledContent {
                    #if os(macOS)
                    Button("Jetzt neu starten") { AppLanguage.relaunch() }
                    #endif
                } label: {
                    Text("Die neue Sprache gilt ab dem nächsten Start von Wortschatz.")
                }
            }
        } header: {
            Text("Sprache")
        }
    }

    private var hint: String {
        switch choice {
        case .system:
            let name = Labels.langName(Lang(rawValue: AppLanguage.systemLanguage) ?? .de)
            return String(localized: "Folgt der Sprache deines Mac – zurzeit \(name).")
        case .de, .en:
            return String(localized: "Gilt nur für Wortschatz, unabhängig von der Sprache deines Mac.")
        }
    }
}
