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
  A set can switch them off for itself (`isActive(forSet:)`, `UserDefaults` key `extendedSynonyms.<set id>`).
  Setting: Einstellungen › Allgemein › Antworten › "Weitere Synonyme erkennen" (UserDefaults `extendedSynonyms`).
- `PasteboardImage` – import sources from the pasteboard (⌘V, "Bild aus Zwischenablage") and from dropped item
  providers.
- `SoundEffects` – the quiet study sounds (correct, miss, streak milestone, round and session end, flashcards),
  synthesized once in the background and played on a serial queue, never on the main thread; muted per set or in
  Einstellungen.
- `InputSource` – the keyboard's current input source (its own file: Carbon's `EventModifiers` would clash with
  SwiftUI's).
## Updates (nur die App der Downloadseite)

- `AppUpdater` – Sparkle 2 (Swift package, 2.10.x), `#if os(macOS) && !PRO`: only the app of the download page updates
  itself, and only its Release builds (a DEBUG build and the unit tests' host never check or write its keys).
  Checks daily (Sparkle's schedule), loads in the background and installs on quit (`SUAutomaticallyUpdate`); «Nach
  Updates suchen…» (app menu) and Einstellungen › Daten › Updates check at once with Sparkle's window. Right before
  every check the app asks GitHub's release list (`WortschatzUpdateRepository` in `mac/Wortschatz-Info.plist`, the
  public repo) for the newest published release with an `appcast.xml` and gives that to Sparkle
  (`feedURLString(for:)`): Mac and Windows come out in separate releases, so «latest» may have no appcast; drafts and
  pre-releases never count, so a release withdrawn since is not checked. For Sparkle's daily check this works by
  declining it once (`updater(_:mayPerform:)`), asking GitHub, then `checkForUpdatesInBackground()`. Nothing goes
  online at launch, and with «Automatisch aktualisieren» off (= Sparkle's `automaticallyChecksForUpdates`) nothing at
  all unless the learner checks. Offline or rate-limited (60 requests per hour and address), the last appcast stays.
- `UpdateFeed` – the parts without Sparkle, tested in `WortschatzTests/UpdateFeedTests`: picking the release, the
  changes from the appcast's description, `UpdateNoticeStore` («Aktualisiert auf …» after a newer build starts, with
  the changes Sparkle downloaded for it; until closed, at most a week).
- Security: every DMG and every appcast is signed with Anthony's EdDSA key (`SUPublicEDKey`, `SURequireSignedFeed`,
  `SUVerifyUpdateBeforeExtraction`). The appcast names the DMG with its full release address (tag included): GitHub
  redirects every release file to `release-assets.githubusercontent.com/…/<id>?…`, and Sparkle resolves a relative
  address against that, where the DMG is not (`SUAppcastDriver`: `relativeToURL:downloadData.URL`).
  Sparkle installs through its installer service (sandbox: `SUEnableInstallerLauncherService` and the `-spks`/`-spki`
  mach-lookup exceptions) and clears the quarantine flag, so an update needs no «Dennoch öffnen».
- Entitlements for it: `network.client` (only used here) and `cs.disable-library-validation`: the app is signed ad hoc,
  and without it the hardened runtime refuses to load the ad-hoc signed Sparkle.framework («different Team IDs») and
  the app quits at launch.
- Release side: `Downloadseite/tools/release-mac.sh` + `appcast.py` (VEROEFFENTLICHEN.md › «Updates (Mac)»). A whole
  update without GitHub or the real key: `mac/scripts/update-test.sh`, its server redirecting like GitHub (tested
  25.11.2026 on macOS 27: installed in /Applications, no App Management prompt, no quarantine afterwards, no request
  to GitHub at the next launch). A wrong setting stops Sparkle silently except
  for «Fatal updater error» in the log (`/usr/bin/log show --predicate 'subsystem == "org.sparkle-project.Sparkle"'`).

Haptics live in `DesignSystem/Haptics.swift`.
