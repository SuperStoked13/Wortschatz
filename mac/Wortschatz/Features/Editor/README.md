# Features/Editor
The set editor sheet (spec §4.4 "Editor", §4.3 key map); a port of src/screens/editor.js and editor-cards.js.
Swift files in this folder are compiled into the app automatically.

| File | Contents |
|---|---|
| `EditorSheet.swift` | `EditorSheet(request:)` (the shell's contract) and `SetEditorView(editor:)`: lazy scroll column, floating save bar, focus and scrolling, drops, file chooser, prompts, toasts, ⌘S. |
| `SetEditorModel.swift` | `@Observable` editor state: title, description, languages ("Automatisch" for a new set: filled from the recognition, else from the cards when saving), card rows, the import box's pairs as cards (`syncImport`: replaced in place on every parse, the learner's edits kept by pair), duplicate check, validation, saving through `AppModel.store` (`createSet` / `updateSet`, card ids kept), undo (toast "Rückgängig" + ⌘Z/⇧⌘Z), external changes. |
| `SetEditorRow.swift` | `SetEditorRow` (one card row, a reference type so typing only redraws that row) and `SetEditorField` (focus targets). |
| `SetEditorMetaSection.swift` | Titel, Beschreibung, "Ich lerne" ⇄ "Übersetzung". |
| `SetEditorCardList.swift` | Cards header with issue chips, pinned column header, `SetEditorRowView`, "Karte hinzufügen" and key hints. |
| `SetEditorChrome.swift` | Header, the glass save bar ("Lernset erstellen ⌘↩" / "Sichern ⌘↩", "Abbrechen esc"), drop overlay, prompt buttons. |
| `SetEditorCopy.swift` | German texts and pure helpers (port of editor-util.js): `termKey`, `titleFromFileName`, flag tooltips, `formatLabel`, paste shapes. |
| `SetEditorSnapshots.swift` | DEBUG snapshot scenes `editor-*` (new, pasted user list, applied, edit, validation, review, import edits). |

Keys: Return moves on (title → description → import box or first card; term → definition → next card, a new card
after a filled last one); ⇥ in the last definition adds a card; ⌫ in an empty term removes the card (neither while an
input method composes in the field); ⌥↩ breaks a line;
⌘↩ / ⌘S save (the import box's pairs are cards already: there is no separate "übernehmen"); esc stops a running import, else cancels
(asking "Änderungen verwerfen?" when there are unsaved changes).
