# Neuigkeiten

<!--
Diese Liste steht auf https://wortschatz.duckdns.org/neuigkeiten und auf Englisch unter /en/whats-new
(online mit dem nächsten GitHub-Release).

Wann ein Eintrag dazukommt: bei jeder Änderung an der Mac- oder der Windows-App, die man beim Benutzen
bemerkt – eine neue Funktion, eine spürbare Verbesserung, ein behobener Fehler. Nicht für Kleinigkeiten
(Wortlaut, Abstände, Farben), interne Umbauten, Tests, Build-Skripte oder die Downloadseite.

So sieht ein Eintrag aus, immer unter «## Nächste Version», das Neueste zuoberst:

  - Neu: Arabisch und Mandarin als Lernsprachen.
  - Verbessert (Mac): …
  - Behoben (Windows): …

Art: Neu, Verbessert oder Behoben. Die Plattform in Klammern nur, wenn es nur eine der beiden Apps
betrifft. Ein oder zwei Sätze für die Benutzer, auf Deutsch mit ss statt ß. Ändert sich ein Punkt vor dem
Release nochmals, den Eintrag anpassen statt einen zweiten schreiben.

Darunter, eingerückt, dieselbe Neuigkeit auf Englisch für https://wortschatz.duckdns.org/en/whats-new:

  - Neu: Arabisch und Mandarin als Lernsprachen.
    EN: Arabic and Mandarin as study languages.

Bezeichnungen aus der App stehen in «…», in der EN-Zeile so, wie die englische App sie zeigt (z. B. «Separator»
statt «Trennung»; nachschlagen in mac/Wortschatz/Resources/Localizable.xcstrings oder
windows-native/src/Wortschatz.Core/Strings/). Fehlt die EN-Zeile, zeigt die englische Seite den deutschen Text.
Ändert sich der deutsche Eintrag, die EN-Zeile mit anpassen.

Versionsnummern nicht von Hand setzen: Downloadseite/tools/release-mac.sh und release-windows.sh machen
beim Bauen aus «Nächste Version» den Abschnitt «## 1.1 – 2026-10-20». Bis dahin zeigt die Seite die
Einträge als «Demnächst».

Die leere «## 1.0» unten ist der Ausgangspunkt (frühere Änderungen werden nicht aufgeführt) und
erscheint nicht auf der Seite.
-->

## Nächste Version

## 1.8.4 – 2026-11-26

- Verbessert (Mac): Mit grossen Lernsets reagieren «Lernen» und «Schreiben» schneller auf eine Antwort, und Karteikarten gleiten beim Hereinkommen und Wegziehen ruhiger.
  EN: With large study sets, «Learn» and «Write» respond faster to an answer, and flashcards move more smoothly when they slide in or you drag them away.

## 1.8.3 – 2026-11-26

- Verbessert (Mac): Karteikarten drehen sich flüssiger, die Seitenleiste gleitet beim Starten und Beenden von «Lernen» ruhiger, und der Lernset-Editor scrollt mit vielen Karten flüssiger.
  EN: Flashcards turn over more smoothly, the sidebar slides more calmly when you start or leave «Learn», and the study set editor scrolls more smoothly with many cards.
- Verbessert (Windows): Lernen läuft ruhiger: Eine neue Runde eines grossen Lernsets ist bis zu dreimal schneller bereit, das Speichern nach jeder Antwort braucht viel weniger Arbeitsspeicher, und wer mit der Maus antwortet, sieht die nächste Frage wieder ganz hereingleiten.
  EN: Learning runs more calmly: a new round of a large study set is ready up to three times faster, saving after each answer needs far less memory, and if you answer with the mouse, the next question slides in completely again.
- Behoben (Windows): Ein langer Lernset-Name oben links in «Lernen», «Schreiben», «Karteikarten» und «Prüfung» wurde unschön abgeschnitten – jetzt endet er mit «…».
  EN: A long study set name at the top left of «Learn», «Write», «Flashcards» and «Test» was cut off awkwardly – it now ends with «…».

## 1.8.2 – 2026-11-26

- Verbessert (Windows): Neues Lernset: Eine eingefügte Liste steht sofort in den Karten – «Trennung» und «Seiten tauschen» ändern sie direkt dort, «Karten übernehmen» braucht es nicht mehr. Die Sprachen stehen zuerst auf «Automatisch» und werden erkannt.
  EN: New study set: a pasted list shows up in the cards right away – «Trennung» (separator) and «Seiten tauschen» (swap sides) change them right there, and «Karten übernehmen» (add cards) is no longer needed. The languages start on «Automatisch» (automatic) and are detected.
- Behoben (Windows): Nach einem Klick in der Seitenleiste blieb um «Übersicht» oder das Lernset ein blauer Rahmen stehen, als wäre der Knopf noch gedrückt.
  EN: After a click in the sidebar, a blue frame stayed around «Übersicht» (overview) or the study set, as if the button were still pressed.
- Neu (Windows): Wortschatz aktualisiert sich selbst: Neue Versionen lädt die App im Hintergrund und installiert sie, wenn du sie beendest, und danach steht in der Seitenleiste, was neu ist. Ausschalten kannst du das unter Einstellungen › Daten › Updates.
  EN: Wortschatz now updates itself: the app downloads new versions in the background and installs them when you quit it, and afterwards the sidebar shows what’s new. You can turn this off under Settings › Data › Updates.
- Verbessert (Mac): Grosse Lernsets laufen flüssiger: Beim Lernen ist eine neue Runde bis zu fünfmal schneller bereit, und im Lernset-Editor stocken Tippen und Rechtschreibprüfung weniger.
  EN: Large study sets run more smoothly: when learning, a new round is ready up to five times faster, and typing and the spell check in the study set editor stutter less.

## 1.8.1 – 2026-11-25

- Neu (Mac): Das App-Symbol im Glas-Look von macOS 26 – es passt sich dem dunklen Modus an und lässt sich getönt oder klar darstellen.
  EN: The app icon in the glass look of macOS 26 – it adapts to dark mode and can be shown tinted or clear.

## 1.8 – 2026-11-25

- Verbessert (Mac): Neues Lernset: Eine eingefügte Liste steht sofort in den Karten – «Trennung» und «Seiten tauschen» ändern sie direkt dort, «Karten übernehmen» braucht es nicht mehr. Die Sprachen stehen zuerst auf «Automatisch» und werden erkannt.
  EN: New study set: a pasted list shows up in the cards right away – «Trennung» (separator) and «Seiten tauschen» (swap sides) change them right there, and «Karten übernehmen» (add cards) is no longer needed. The languages start on «Automatisch» (automatic) and are detected.
- Verbessert (Mac): Lernen, Multiple Choice, Schreiben und Karteikarten werden in grossen Fenstern grösser – Fragen, Antworten und Karten sind besser lesbar.
  EN: Learn, multiple choice, Write and Flashcards grow in large windows – questions, answers and cards are easier to read.
- Verbessert (Mac): Ohne Lernsets lädt «Backup laden…» auf der Übersicht direkt ein Backup.
  EN: Without study sets, «Backup laden…» (load backup) on the overview loads a backup directly.
- Behoben (Mac): Solange die Einstellungen offen waren, erschienen Meldungen doppelt.
  EN: While Settings was open, messages appeared twice.
- Neu (Mac): Wortschatz aktualisiert sich selbst: Neue Versionen lädt die App im Hintergrund und installiert sie, wenn du sie beendest, und danach steht in der Seitenleiste, was neu ist. Ausschalten kannst du das unter Einstellungen › Daten › Updates.
  EN: Wortschatz now updates itself: the app downloads new versions in the background and installs them when you quit it, and afterwards the sidebar shows what’s new. You can turn this off under Settings › Data › Updates.

## 1.7.1 – 2026-11-25

- Verbessert (Mac): Tippen beim Lernen, Schreiben und in der Prüfung, die Suche in der Seitenleiste und das Sortieren der Karteikarten laufen flüssiger, besonders bei grossen Lernsets.
  EN: Typing in Learn, Write and the exam, searching in the sidebar and sorting flashcards run more smoothly, especially with large study sets.
- Behoben (Windows): Die Übersicht zeigt wieder aktuell, wann du ein Lernset zuletzt gelernt hast. Bisher blieb zum Beispiel «vor 5 Minuten» stehen, bis sich etwas an deinen Lernsets änderte.
  EN: The overview shows again how long ago you last studied a set. Before, «vor 5 Minuten» (5 minutes ago), for example, stayed until something in your sets changed.
- Verbessert (Windows): Die App braucht weniger Arbeitsspeicher und läuft beim Lernen flüssiger: Nach einer Antwort stockt nichts mehr, während im Hintergrund gespeichert wird, und grosse Lernsets starten schneller.
  EN: The app uses less memory and runs more smoothly while you study: nothing stutters after an answer while your progress is saved in the background, and large study sets start faster.

## 1.7 – 2026-11-25

- Behoben (Mac): Sehr lange Wörter auf Karteikarten und beim Lernen und Schreiben werden nach Silben mit Bindestrich getrennt, statt irgendwo mitten im Wort umzubrechen oder ganz klein zu werden.
  EN: Very long words on flashcards and in Learn and Write are now split at syllables with a hyphen, instead of breaking anywhere inside the word or getting tiny.
- Verbessert (Mac): Stehen beim Lernset links und rechts dieselbe Sprache (zum Beispiel Deutsch → Deutsch), weist der Editor darauf hin.
  EN: If a study set has the same language on both sides (for example German → German), the editor points it out.
- Behoben (Mac): Stellst du in den Optionen eines Lernsets eine Option wieder auf den Standard zurück, folgt das Lernset dort wieder dem Standard. Bisher behielt es den Wert als eigene Option, auch wenn man den Standard später änderte.
  EN: If you set an option in a study set’s options back to the default, the set follows the default there again. Before, it kept the value as its own option, even when you later changed the default.
- Verbessert (Mac): Änderst du «Antworten auf», die Fragetypen, «Fragen pro Runde» oder «Mischen», gilt das sofort, auch für angefangenes Lernen und Schreiben – ohne Neustart, und was du schon kannst, bleibt. Bisher galt es erst nach einem Neustart, und in den Einstellungen oder den Optionen eines Lernsets geändert gar nicht für Angefangenes.
  EN: Changing «Antworten auf», the question types, «Fragen pro Runde» or «Mischen» now applies right away, also to learning and writing you already started – no restart, and what you already know stays. Before, it only applied after a restart, and changes in Settings or a study set’s options didn’t reach a started session at all.
- Neu (Mac): Wortschatz gibt es jetzt auch auf Englisch. Die App folgt der Sprache deines Mac; unter Einstellungen › Allgemein › Sprache stellst du Deutsch oder Englisch nur für Wortschatz ein.
  EN: Wortschatz is now also available in English. The app follows your Mac’s language; under Settings › General › Language you can choose German or English for Wortschatz alone.
- Neu (Windows): Wortschatz gibt es jetzt auch auf Englisch. Die App folgt der Sprache von Windows; unter Einstellungen › Allgemein › Sprache stellst du Deutsch oder Englisch nur für Wortschatz ein. Die Umstellung gilt sofort.
  EN: Wortschatz is now also available in English. The app follows the language of Windows; under Settings › General › Language you can choose German or English for Wortschatz alone. The change applies right away.
- Verbessert (Windows): «Wiederholungsfragen» und «Nachkontrolle nach Fehlern» gelten sofort, auch für angefangenes Lernen; bisher lief es mit der alten Einstellung weiter, bis man neu startete. «Standard wiederherstellen» in Einstellungen › Lernen setzt die beiden jetzt auch zurück.
  EN: «Wiederholungsfragen» (repeat questions) and «Nachkontrolle nach Fehlern» (re-check after mistakes) now apply right away, also to learning you already started; before, it kept the old setting until you restarted. «Standard wiederherstellen» in Einstellungen › Lernen now resets these two as well.
- Verbessert (Windows): Hat man «Antworten auf», die Fragetypen, «Fragen pro Runde» oder «Mischen» in den Einstellungen oder in den Optionen eines Lernsets geändert, fragt angefangenes Lernen oder Schreiben beim Weitermachen «Neu starten?». Bisher lief es ohne Hinweis mit den alten Einstellungen weiter.
  EN: If you changed «Antworten auf», the question types, «Fragen pro Runde» or «Mischen» in Settings or in a study set’s options, learning or writing you already started now asks «Neu starten?» when you continue. Before, it silently kept the old settings.
- Behoben (Windows): Stellt man in den Optionen eines Lernsets eine Option wieder auf den Standard zurück, folgt das Lernset dort wieder dem Standard. Bisher behielt es den Wert als eigene Option, auch wenn man den Standard später änderte.
  EN: If you set an option in a study set’s options back to the default, the set follows the default there again. Before, it kept the value as its own option, even when you later changed the default.
- Neu (Windows): In den Optionen eines Lernsets lässt sich unter «Toleranz» ausschalten, dass Synonyme ausserhalb des Sets als richtig zählen. Steht ein Synonym als eigene Karte im Lernset, zählt es weiterhin.
  EN: In a study set’s options, under «Toleranz», you can turn off synonyms from outside the set counting as correct. A synonym that has its own card in the study set still counts.
- Behoben (Windows): Die Lernzeit am Ende von «Lernen» zählt nur noch, solange man lernt: Nach zwei Minuten ohne Eingabe hält die Uhr an, wie schon beim Schreiben. Bisher lief sie weiter, solange «Lernen» offen war.
  EN: The study time at the end of «Lernen» now only counts while you’re studying: after two minutes without input the clock pauses, as it already did in «Schreiben». Before, it kept running as long as «Lernen» was open.
- Verbessert (Windows): Beim Lernen kommt jeder Begriff nur noch einmal als Multiple Choice. Hat man ihn einmal richtig, fragt die App ihn von da an nur noch schriftlich ab, auch nach einer falschen Antwort; nur wer die Multiple Choice falsch hat, bekommt sie nochmals.
  EN: When learning, each term comes up as multiple choice only once. Once you get it right, the app only asks you to write it from then on, even after a wrong answer; only a wrong multiple-choice answer brings multiple choice back.
- Neu (Windows): Beim Lernen und Schreiben zählen auch gleichbedeutende Wörter, die nicht im Lernset stehen – zum Beispiel «Velo» für «Fahrrad» –, markiert als «Synonym – nicht im Set». Ausschalten lässt es sich in den Einstellungen unter Allgemein › Antworten.
  EN: When learning and writing, words with the same meaning that aren’t in the study set count too – for example «Velo» for «Fahrrad» (both mean bike) – marked as «Synonym – nicht im Set». You can turn it off in Settings under Allgemein › Antworten.
- Behoben (Windows): Trennt man einen externen Bildschirm oder ändert die Skalierung, holt die App ihr Fenster ganz auf den Bildschirm zurück, statt abgeschnitten oder in der falschen Grösse zu bleiben.
  EN: If you disconnect an external display or change the scaling, the app brings its window fully back onto the screen instead of leaving it cut off or the wrong size.
- Verbessert (Windows): Auf grossen Bildschirmen werden Lernen, Schreiben, Karteikarten und Prüfung grösser dargestellt (Karte, Schrift und Knöpfe), statt klein in der Mitte zu stehen.
  EN: On large screens, learning, writing, flashcards and tests are shown bigger (card, text and buttons) instead of sitting small in the middle.
- Verbessert (Windows): Stehen beim Lernset links und rechts dieselbe Sprache (zum Beispiel Deutsch → Deutsch), weist der Editor darauf hin.
  EN: If a study set has the same language on both sides (for example German → German), the editor points it out.
- Behoben (Windows): Wählt man bei den Karteikarten eine andere Vorderseite, wechselt auch die Karte, die gerade oben liegt, nicht erst die nächste.
  EN: When you pick a different front side for flashcards, the card currently on top switches too, not just the next one.
- Behoben (Windows): Sehr lange Wörter auf Karteikarten werden nach Silben mit Bindestrich getrennt, statt irgendwo mitten im Wort umzubrechen.
  EN: Very long words on flashcards are hyphenated by syllable instead of breaking somewhere in the middle of the word.
- Neu (Windows): Eine neue Version räumt beim Start auf: Ältere heruntergeladene Versionen (zum Beispiel «Wortschatz-1.4-Windows.exe» im Download-Ordner oder auf dem Schreibtisch) werden gelöscht, deine Lernsets bleiben. Umbenannte Dateien und eine Version, die gerade läuft, bleiben.
  EN: A new version tidies up when it starts: older downloaded versions (for example «Wortschatz-1.4-Windows.exe» in the Downloads folder or on the desktop) are deleted, and your study sets stay. Renamed files and a version that is currently running are left alone.

## 1.6.2 – 2026-11-24

- Verbessert (Mac): «Wiederholungsfragen» und «Nachkontrolle nach Fehlern» gelten sofort, auch für angefangenes Lernen; bisher lief es mit der alten Einstellung weiter, bis man neu startete. «Standard wiederherstellen» in Einstellungen › Lernen setzt die beiden jetzt auch zurück.
  EN: «Wiederholungsfragen» (repeat questions) and «Nachkontrolle nach Fehlern» (re-check after mistakes) now apply right away, also to learning you already started; before, it kept the old setting until you restarted. «Standard wiederherstellen» in Einstellungen › Lernen now resets these two as well.

## 1.6.1 – 2026-11-24

- Behoben (Mac): Die Lernzeit am Ende von «Lernen» zählt nur noch, solange man lernt: Nach zwei Minuten ohne Eingabe hält die Uhr an, wie schon beim Schreiben. Bisher lief sie weiter, solange «Lernen» offen war.
  EN: The study time at the end of «Lernen» now only counts while you’re studying: after two minutes without input the clock pauses, as it already did in «Schreiben». Before, it kept running as long as «Lernen» was open.

## 1.6 – 2026-11-24

- Verbessert (Mac): Beim Lernen kommt jeder Begriff nur noch einmal als Multiple Choice. Hat man ihn einmal richtig, fragt die App ihn von da an nur noch schriftlich ab, auch nach einer falschen Antwort; nur wer die Multiple Choice falsch hat, bekommt sie nochmals.
  EN: When learning, each term comes up as multiple choice only once. Once you get it right, the app only asks you to write it from then on, even after a wrong answer; only a wrong multiple-choice answer brings multiple choice back.

## 1.5 – 2026-11-23

- Neu: Hast du eine Antwort ganz getippt, geht es ohne Eingabetaste weiter: bei Multiple Choice, sobald nur noch eine Antwort passt und sie (oder eine ihrer Formen) vollständig dasteht, und beim Abtippen der richtigen Antwort, sobald sie genau so dasteht wie angezeigt.
  EN: Once you’ve typed out an answer completely, you move on without pressing Return: in multiple choice as soon as only one answer fits and it (or one of its forms) is complete, and when retyping the correct answer as soon as it matches exactly.
- Verbessert (Mac): Mit eingeschalteten Soundeffekten erscheint die Antwort nach einem Tastendruck sofort; vorher wartete die Anzeige auf den Lautsprecher oder die Kopfhörer, mit AirPods bis zu einer Zehntelsekunde.
  EN: With sound effects on, the answer appears right after a key press; before, the display waited for the speakers or headphones – up to a tenth of a second with AirPods.
- Behoben: Gegen Ende einer Lernsitzung kam eine Nachkontrolle manchmal schon wenige Fragen, nachdem du den Begriff gemeistert hattest. Jetzt kommt sie frühestens nach 10 anderen Fragen.
  EN: Towards the end of a study session, a follow-up check sometimes came only a few questions after you had mastered the term. Now it comes after at least 10 other questions.
- Verbessert: Multiple Choice beim Lernen ist schwieriger: Die falschen Antworten sind möglichst ähnlich – dieselbe Wortart (Nomen zu Nomen, Verb zu Verb, Adjektiv zu Adjektiv), oft aus demselben Teil des Lernsets und ähnlich geschrieben.
  EN: Multiple choice when learning is harder: the wrong answers are as similar as possible – the same part of speech (noun for noun, verb for verb, adjective for adjective), often from the same part of the study set and spelled similarly.
- Neu (Mac): In den Optionen eines Lernsets lässt sich unter «Toleranz» ausschalten, dass Synonyme ausserhalb des Sets als richtig zählen. Steht ein Synonym als eigene Karte im Lernset, zählt es weiterhin.
  EN: In a study set’s options, under «Toleranz», you can turn off synonyms from outside the set counting as correct. A synonym that has its own card in the study set still counts.
- Neu: Schreibst du die Antwort einer anderen Karte mit demselben Begriff – etwa «to kidnap sb» bei «etw. entführen», wenn «jmdn. entführen» eine eigene Karte ist –, fragt die App, ob die Antwort als richtig, als falsch oder für die andere Karte zählen soll.
  EN: If you type the answer of another card with the same term – say «to kidnap sb» for «etw. entführen» when «jmdn. entführen» has its own card – the app asks whether the answer should count as correct, as wrong or for the other card.
- Verbessert: Am Ende von Lernen und Schreiben zeigt «Am häufigsten falsch» alle Begriffe, die mindestens einmal falsch waren (nicht nur zehn), und mit dem Stern daneben markierst du sie gleich zum gezielten Üben.
  EN: At the end of learning and writing, «Am häufigsten falsch» (most often wrong) shows every term you got wrong at least once (not just ten), and the star next to each lets you mark it for focused practice right away.
- Neu: Die Soundeffekte lassen sich in den Optionen eines Lernsets für dieses eine Lernset ausschalten, zum Beispiel wenn du dazu Musik hörst. Das gilt nur auf dem Gerät, auf dem du es umstellst.
  EN: Sound effects can be turned off in a study set’s options for just that study set, for example when you’re listening to music. This only applies on the device where you change it.
- Verbessert: Kommt beim Lernen eine Nachkontrolle, steht das auf der Karte. Bei der ersten in einer Sitzung zeigt ein kurzer Hinweis, dass du die Nachkontrolle in den Optionen ausschalten kannst, mit einem Knopf direkt dorthin.
  EN: When a follow-up check comes up while learning, the card says so. The first time in a session, a short hint shows that you can turn follow-up checks off in the options, with a button that takes you straight there.

## 1.4 – 2026-11-03

- Neu: Nachkontrolle beim Lernen: Hattest du in einem Lernset mit mehr als 60 Begriffen einen Begriff einmal falsch, kommt er nach dem Meistern etwa 30 bis 50 Fragen später nochmals. Lässt sich in den Optionen ausschalten.
  EN: Follow-up checks when learning: if you got a term wrong once in a study set with more than 60 terms, it comes back about 30 to 50 questions after you’ve mastered it. You can turn this off in the options.
- Verbessert: Lernen mischt neue und bekannte Begriffe: Ein Begriff kommt frühestens nach 10 anderen Fragen wieder (meist nach 10 bis 15), statt dass nach jeder Runde dieselben Begriffe gleich nochmals kommen.
  EN: Learning mixes new and familiar terms: a term comes back after at least 10 other questions (usually after 10 to 15), instead of the same terms coming right back after every round.
- Verbessert: Die Einstellungen stehen als eigener Eintrag unten in der Seitenleiste. Die Optionen eines Lernsets lassen sich auch auf der Lernset-Seite öffnen und zeigen, was vom Standard abweicht, mit «Auf Standard zurücksetzen».
  EN: Settings have their own entry at the bottom of the sidebar. A study set’s options can also be opened from the study set page and show what differs from the default, with «Auf Standard zurücksetzen» (reset to default).

## 1.3 – 2026-11-03

- Verbessert (Windows): Die native Windows-App, die seit 1.2 die frühere Web-App ersetzt, hat jetzt fast alle Funktionen der Mac-App und ist überall verfeinert – zum Beispiel Vokabellisten aus PDFs und Fotos importieren, Tippfehler-Hinweise und «Rückgängig» im Editor, Sonderzeichen zum Anklicken und mehr Möglichkeiten in der Prüfung. Dazu viele Korrekturen, damit nichts mehr ohne Rückfrage verloren geht.
  EN: The native Windows app, which replaced the earlier web app in 1.2, now has almost every feature of the Mac app and has been refined throughout – for example importing vocabulary lists from PDFs and photos, typo hints and Undo in the editor, clickable special characters and more options in tests. Plus many fixes so that nothing gets lost without asking anymore.

## 1.2 – 2026-11-03

- Neu (Windows): Die Windows-App ist jetzt ein eigenes Programm statt einer Webseite im Fenster. Sie sieht aus wie die Mac-App, startet schneller und hat Karteikarten, Prüfung, Töne, Rechtsklick-Menüs und Tastenkürzel. Beim ersten Start übernimmt sie alles aus der bisherigen App und entfernt diese danach.
  EN: The Windows app is now a proper program instead of a web page in a window. It looks like the Mac app, starts faster and has flashcards, tests, sounds, right-click menus and keyboard shortcuts. On first launch it takes over everything from the previous app and then removes it.

## 1.1 – 2026-10-15

- Neu: Arabisch und Mandarin als Lernsprachen. Bei Mandarin zählen Schriftzeichen oder Pinyin, Töne gehen auch als Zahlen (ni3 hao3). Bei Arabisch spielen Vokalzeichen keine Rolle.
  EN: Arabic and Mandarin as study languages. For Mandarin, characters or pinyin both count, and tones can be typed as numbers too (ni3 hao3). For Arabic, vowel marks don’t matter.

## 1.0 – 2026-10-14
