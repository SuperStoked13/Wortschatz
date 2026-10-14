# Services
App-side services (spec §4.1, §4.4). Swift files in this folder are compiled into the app automatically.

- `SpeechService` – read-aloud with `AVSpeechSynthesizer` (port of src/lib/speech.js): best installed voice per
  language (fr-FR, de-CH → de-DE, en-GB, es-ES, it-IT), "beau/belle" → "beau, belle", every utterance cancels the
  previous one, per-language voice choice for Settings › Allgemein › Stimme (`voices(for:)`, `setPreferredVoice`).
  The app has one instance, `AppModel.speech`, used by the set screens, Learn, Write and Settings.
- `ImportCoordinator` – one cancellable file import at a time for the editor, with delayed progress and VoiceOver
  status announcements. The work happens in the `WortschatzImport` module of the package (`ImportPipeline`: text
  files, PDFKit, Vision OCR).
- `SynonymAssistant` – synonyms that are not in the set ("ensemble" for "gemeinsam" → "en commun") with Apple's
  on-device language model (FoundationModels): the prompt's translations are prefetched when a written question
  shows, an otherwise wrong answer is translated back (Learn and Write wait for it, at most 3 s). The model only lists
  translations; `ExtendedSynonyms` in the package compares them. Lists are cached in Caches/<bundle id>/synonyms.json.
  Setting: Einstellungen › Allgemein › Antworten › "Weitere Synonyme erkennen" (UserDefaults `extendedSynonyms`).
- `PasteboardImage` – import sources from the pasteboard (⌘V, "Bild aus Zwischenablage") and from dropped item
  providers.

Haptics live in `DesignSystem/Haptics.swift`.
