# Features/SetDetail
The set screen (spec §4.4, port of src/screens/set.js).

- `SetDetailScreen.swift`: header (language capsule, title, description, facts), the mastery panel
  (gauge + clickable legend → filter), the actions (Lernen ↩ / Weiterlernen ↩, Schreiben, Karteikarten,
  Prüfung, Nur markierte, Nur schwierige, Bearbeiten, Optionen, "…"), running sessions and the Learn note.
  Adapts to narrow/short windows (`SetDetailLayout`).
- `SetTermsSection.swift`: filter (Alle/Neu/Am Lernen/Gemeistert/Markiert/Schwierig), inline search and the
  `Table` (Begriff | Definition | Status | ★ | 🔊), sortable, row context menu, double-click edits.
- `TextExportSheet.swift`: "Als Text exportieren" (separators, preview, Kopieren, Sichern… ↩).
- `SetDetailCopy.swift`: the German helper texts (studyNote, answerLabel, progressCaption, …).
