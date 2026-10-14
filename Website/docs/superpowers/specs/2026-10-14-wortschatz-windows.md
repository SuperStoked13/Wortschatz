# Wortschatz for Windows

Date: 2026-10-14. Requested by the user: turn Wortschatz into a downloadable Windows app, with only the UI changes that are needed. Their answers to the follow-up questions:
- Port the Mac-only features as well, except the ones that only work on the Mac. That excludes the AI synonyms («Weitere Synonyme erkennen», Apple FoundationModels).
- Package it as a single `Wortschatz.exe`. They approved downloading the Go compiler and a few Go libraries.

## Shape

- **The app is the web app in `Website/`.** It is shown in WebView2, the Edge engine that ships with Windows 10 and 11.
- **Host: `windows/host/`** (Go).
  - It uses `github.com/jchv/go-webview2`'s `pkg/edge` with its own Win32 window.
  - **Build:** `windows/build.sh` cross-compiles `windows/dist/Wortschatz.exe` on the Mac.
    - Go 1.27.2 lives in `windows/.toolchain`, with its checksum in `build.sh`.
    - `go-winres` adds the icon, the version info and a per-monitor-v2 DPI manifest.
  - **Web files:** they are embedded in the exe and unpacked to `%LOCALAPPDATA%\Wortschatz\App\<hash>` (a new folder per build; old ones are removed).
  - **Serving:** WebView2 maps the folder to `https://wortschatz.example/`. **Never change this origin:** all sets and progress live in its localStorage, under `%LOCALAPPDATA%\Wortschatz\WebView2`.
  - **What the host does:**
    - one window only (a second start brings it to the front);
    - the title bar and the start background follow the app's theme;
    - browser accelerator keys, swipe navigation, the status bubble and DevTools are off (`WORTSCHATZ_DEVTOOLS=1` turns the DevTools and the accelerators back on);
    - the page is hidden while the window is minimised;
    - closing the window asks first while the editor holds unsaved changes;
    - a clear message appears if WebView2 is missing;
    - it writes a log to `%LOCALAPPDATA%\Wortschatz\wortschatz.log`.
- **Bridge:**
  - The host injects `window.wortschatzHost = { platform: 'windows', setTheme, setUnsaved }` before any page script.
  - The page side is `src/lib/host.js`:
    - `isDesktopApp()` switches the copy from «in diesem Browser» to «auf diesem Computer» and drops the localhost/Start.command help;
    - `reportTheme` and `reportUnsaved` talk to the host;
    - outside text fields the browser context menu is hidden;
    - Ctrl-, Shift- and middle-clicks cannot open extra windows.

## Ported from the Mac app (web app, so also in the browser version)

Karteikarten, Prüfung, Wiederholungsfragen (with «Falsche lernen» and `?cards=…&review=1`), «N richtig in Folge», the daily Lernserie in the header with a once-a-day toast, synthesized sound effects (Einstellungen › Töne), typing to choose in multiple choice, «Nur schwierige» and the «Schwierig» filter, Mac keyboard shortcuts (⌘ → Strg, never Strg+Alt because that is AltGr), and a voice choice per language. «Nur nicht gemeisterte» is gone (the Mac's «Nur offene»).

App preferences that the Mac keeps in UserDefaults live in `src/lib/prefs.js` (`wortschatz:v1:pref:*`). They are not in backups. Flashcard decks are per set (`flashcards:<setId>`), and they are not exported either.

Other window fixes:
- a file dropped outside the import area can no longer replace the app;
- the header no longer shifts when a dialog opens (classic Windows scrollbars);
- Ctrl+S saves in the editor;
- exports say they went to «Downloads».

## Verification and limits

- The web tests (`Website/tests/run.sh`) and `go test`/`go vet` run in `build.sh`.
- The new screens were smoke-tested in the browser pane at 1200×800 and 600×600, in dark and light.
- Nothing could be run on Windows itself. Untested there: the WebView2 window (focus, DPI, title-bar colour, icon), real Windows voices, AltGr typing, precision-touchpad swiping of flashcards, and the speed of the flashcard animations.
