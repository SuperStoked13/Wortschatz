#if os(macOS)
import SwiftUI

/// Einstellungen › Daten › Updates (`AppUpdater`): «Automatisch aktualisieren» (off: the app never
/// goes online by itself) and «Jetzt suchen». A DEBUG build shows both off: it never updates itself.
struct SettingsUpdateSection: View {
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        Section {
            Toggle(isOn: $updater.checksAutomatically) {
                Label {
                    Text("Automatisch aktualisieren")
                    if updater.checksAutomatically && !updater.installsAutomatically {
                        Text("Sucht einmal am Tag nach neuen Versionen und fragt, bevor eine installiert wird.")
                    } else {
                        Text("Lädt neue Versionen im Hintergrund und installiert sie, wenn du Wortschatz beendest.")
                    }
                } icon: {
                    SettingsRowIcon(systemImage: "arrow.triangle.2.circlepath", tint: Theme.accent)
                }
            }
            .disabled(!updater.isEnabled)
            LabeledContent {
                Button("Jetzt suchen") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            } label: {
                Label {
                    Text("Nach Updates suchen")
                    Text(lastCheckText)
                } icon: {
                    SettingsRowIcon(systemImage: "arrow.down.circle", tint: Theme.info.fill)
                }
            }
        } header: {
            Text("Updates")
        }
    }

    private var lastCheckText: String {
        guard updater.isEnabled else { return String(localized: "Nur in der App von der Downloadseite.") }
        guard let date = updater.lastCheck else { return String(localized: "Noch nie gesucht.") }
        let when = date.formatted(.relative(presentation: .named).locale(AppLanguage.formattingLocale))
        return String(localized: "Zuletzt gesucht: \(when)")
    }
}
#endif
