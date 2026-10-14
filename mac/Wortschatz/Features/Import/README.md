# Features/Import
The editor's smart import panel (spec §4.4 "Import area" and "Recognition"); a port of
src/screens/editor-import.js and editor-drop.js. Swift files in this folder are compiled into the app automatically.

| File | Contents |
|---|---|
| `ImportPanelModel.swift` | `@Observable` panel state: paste text, live parsing with `VocabParser` (debounced 250 ms, off the main actor), separator and side swap, file notes, pending cards, file imports through `ImportCoordinator` (progress, cancel, summary toasts, title suggestion). |
| `ImportSeparator.swift` | "Trennung": Automatisch, Tab, Komma, Strichpunkt, Bindestrich, Zeilenweise, Eigenes… and their parse options. |
| `ImportTextView.swift` | The paste box: a plain-text `NSTextView` that imports dropped files/images and ⌘V of copied files or an image (a SwiftUI `TextEditor` would insert file paths and cannot paste images). Tab leaves the box, ⌥⇥ inserts a tab. |
| `ImportPanelView.swift` | Disclosure header, paste box, drop zone ("Datei wählen…", "Bild aus Zwischenablage ⌘V"), progress with "Abbrechen". |
| `ImportDetectionPanel.swift` | Detection bar on a `ContentPanel` ("✨ 52 Paare erkannt · Abwechselnde Zeilen · Französisch → Deutsch"), separator controls, warnings, skipped lines, preview `Table` with flagged rows, "N Karten übernehmen". |

The whole editor sheet is a drop target as well (`onDrop` in `SetEditorView`), for several files at once.
