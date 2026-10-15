# Features/Settings
The Settings window (⌘,, spec §4.4), a port of src/screens/settings.js. Swift files in this folder are compiled into the app automatically.

| File | Contents |
|---|---|
| `SettingsView.swift` | `SettingsView()` (TabView with toolbar tabs), `SettingsTab` (titles, symbols, pane sizes), `SettingsWriter` (writes `LibraryStore.updateSettings`), `SettingsDefaultsFooter` |
| `SettingsGeneralTab.swift` | Allgemein: appearance thumbnails (System/Hell/Dunkel), sound effects, "Weitere Synonyme erkennen" (`SynonymAssistant`, disabled with the reason when Apple Intelligence is off), a voice per language in `Labels.LANG_ORDER` without «Andere» (`SpeechService`, never a Cantonese voice for Chinese) with a sample |
| `SettingsStudyTabs.swift` | Lernen, Schreiben, Toleranz; `SettingsDefaults` ("Standard wiederherstellen" per tab) |
| `SettingsDataTab.swift` | Daten: backup export/import (own panels, `BackupImportSheet`), drag and drop, web migration steps, Speicherort, "Alle Daten löschen…" |
| `SettingsWipeSheet.swift` | The two confirmations of "Alle Daten löschen…" |
| `SettingsCopy.swift` | Texts that depend on data (theme hint, direction text, summary, wipe message, path) |
| `SettingsSnapshots.swift` | DEBUG snapshot scenes `settings-*` |

Snapshots: `Wortschatz --render-snapshots <dir> --snapshot-filter settings-` (each tab at its pane size, light and dark).
