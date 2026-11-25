# DesignSystem

Liquid Glass components, colours, typography, key hints and the backdrop of the Mac app (spec §4.2).
Everything here is app-target code (MainActor by default); token enums are `nonisolated`.
Look at them all at once in `DesignGallery` (DEBUG, `#Preview`) or render them with the
snapshot harness (below).

## Rules (HIG, spec §4.2)

- **Glass only on the control layer**: study card, multiple-choice tiles, floating action bar,
  progress capsule, stat tiles, banners/toasts, the "Weiterlernen" hero. Lists, tables, text,
  backgrounds and content cards (set cards, panels in scrolling content) are never glass: they use
  `ContentPanel` / `.contentSurface`. System glass (sidebar, toolbar, sheets, menus) comes for free.
- **No glass on glass.** Every glass surface here sets `\.isOnGlassSurface`; `PrimaryActionButton`
  and `SecondaryButton` then switch to `.borderedProminent` / `.bordered` automatically. Chips,
  keycaps and the special-character bar are plain fills, so they can live inside glass.
- **GlassEffectContainer pitfall** (verified with snapshots): inside a container, modifiers applied
  *outside* `.glassEffect` / `.glassSurface` (`opacity`, `overlay`, `scaleEffect`, `clipShape`)
  are not drawn. Put state visuals (rings, dimming) on the content *before* the glass modifier.
  Offsets and transitions work.
- **Accessibility**: use `.glassSurface(...)` rather than raw `.glassEffect` — it falls back to an
  opaque surface with a hairline under Reduce Transparency and adds a border under increased
  contrast. Motion goes through `Motion` / `.motionAnimation` / `.shake` (a cross-fade or nothing
  under Reduce Motion). Every component has German VoiceOver labels; decorative parts are hidden.
- One primary action per screen bound to Return, marked with the ↩ keycap (spec §4.3).
- Swiss spelling in all copy: "ss", never the sharp s.

## Tokens

| File | API |
|---|---|
| `Theme.swift` | `Theme.accent`, `accentText`, `accentSoft`; status palettes `Theme.mastered / learning / new` and `Theme.palette(for: CardStatus)`; feedback `Theme.success / failure / warning / info` (each a `StatusPalette` with `fill`, `text`, `soft`); `Theme.star`, `flame`, `solidSurface`, `solidBackdrop`, `hairline`, `glassTintOpacity`. `CardStatus.label / palette / systemImage`. `Color.dynamic(light:dark:lightHC:darkHC:…)`, `Color(hex:)`. All colours adapt to dark mode and increased contrast. |
| `Typography.swift` | `Typography.prompt` (40 pt semibold rounded), `prompt(for: text)` (40/32/25 pt by length), `display`, `title`, `headline`, `answer`, `answerField`, `statValue`, `gaugeValue`, `feedbackTitle`, `eyebrow`, `count`, `keycap`, `specialCharacter`; `.eyebrowStyle()` |
| `Metrics.swift` | `Spacing.xxs…huge` (4-pt grid), `Radii.keycap/small/tile/panel/card`, `LayoutMetrics.studyColumnWidth` (760) etc., `Motion.spring/snappy/gentle/fade` (state changes), `Motion.arrive/fadeIn/depart(_:)` (curves that land exactly: screens coming and going, short glides), `Motion.animation(_:reduceMotion:)`, `.motionAnimation(_:value:)`, `EnvironmentValues.isSnapshotRendering` |
| `Effects.swift` | `.shake(trigger:amplitude:)` (wrong answers), `.pop(trigger:scale:)` — both no-ops under Reduce Motion |
| `StudyEntrance.swift` | How screens come and go (into Lernen/Schreiben and back): dissolve, sidebar slide, invisible build, fade-in. `.entranceReveal(_:)` fades a whole screen in place (never scale or move whole screens: text and glass tremble, AppKit re-checks the pointer every frame); `.entranceShift(x:y:)` lets SwiftUI-drawn content glide a few points meanwhile |

## Components

| Component | Use |
|---|---|
| `AppBackdrop(intensity:)` / `.appBackdrop()` | Accent-tinted `MeshGradient` behind a screen. Slow drift, paused when the window is inactive, static under Reduce Motion, opaque under Reduce Transparency. |
| `.glassSurface(tint:interactive:cornerRadius:)` / `.glassSurface(tint:interactive:in:)` | The glass primitive with accessibility fallbacks. Tint example: `Theme.success.fill.opacity(Theme.glassTintOpacity)`. |
| `GlassCard { }` | Study card, hero (radius 30, padding 32; both adjustable, `tint`, `isInteractive`). |
| `GlassPanel { }` | Compact glass for grouped info on the control layer (a floating summary strip). |
| `ContentPanel { }`, `.contentSurface(cornerRadius:isHighlighted:)` | The content layer's grouped surface (never glass): set cards in a grid, panels inside scrolling content or sheets (mastery panel, import detection). Quiet translucent fill + hairline, opaque under Reduce Transparency; `isHighlighted` for hover. |
| `KeyActionGate` | Used by `PrimaryActionButton` / `SecondaryButton` with a bound key: auto-repeats never trigger them, and right after Return changed the screen (`AppModel` navigation calls `returnKeyMoved(by:)`) they wait 280 ms. |
| `PrimaryActionButton("Weiter") { }` | `.glassProminent` capsule, accent, inline ↩ keycap, bound to `.defaultAction`. Options: `verbatim:` title, `systemImage`, `key:` (`.commandReturn` …), `bindsShortcut: false` when a flow reducer handles the key (hint stays, VoiceOver gets a hint), `tint`, `isFullWidth`, `controlSize`. |
| `SecondaryButton("Weiss ich nicht", key: .optionReturn) { }` | `.glass` capsule with optional keycap; same options plus `role`. |
| `Keycap(.returnKey)`, `KeyHint(.optionReturn, "Weiss ich nicht")`, `KeyHintRow([...])` | `KeyGlyph`: `.returnKey ↩`, `.optionReturn ⌥↩`, `.commandReturn ⌘↩`, `.escape esc`, `.digit(1…4)`, `.tab`, `.arrows`, `.command("E")`, `.shiftCommand("L")`; each has `symbol`, `accessibilityName` (German) and `keyboardShortcut`. Keycaps follow the current foreground style (they work inside prominent buttons). |
| `StatusCounts(fresh:learning:mastered:)` | Input of the progress views; inits from `SetProgress`, `LearnEngine.Counts`, `LearnEngine.CheckpointCounts`. `percent` follows mastery.js (never 100 before all mastered, never 0 once one is). |
| `ProgressCapsule(counts:style:isGlass:)` | Learn toolbar capsule: segmented bar + "Neu · Am Lernen · Gemeistert". `.compact` for narrow spaces; `isGlass: false` inside a toolbar. |
| `StatusBar(counts:height:)` | The segmented bar alone (set cards, rows). |
| `MasteryGauge(counts:size:)` | `.small` (18 pt, sidebar rows), `.medium` (set cards, %), `.large` (set header, % + "gemeistert"). |
| `StatTile("Lernserie", value: "5", unit: "Tage", systemImage: "flame.fill", tint: Theme.flame, caption:)` | Glass statistic tile. |
| `StatusChip(status:)`, `LanguageCapsule(termLang:defLang:style:)`, `NoteChip(GradeNote)`, `HintChip(GradeHint)`, `TintedChip` | Plain chips. Labels come from `Labels.STATUS / NOTE_LABELS / HINT_LABELS / LANGS`. |
| `ChoiceTile(number:text:state:emphasis:lang:) { }`, `ChoiceGrid(choices:lang:state:emphasis:onChoose:)` | Multiple-choice tiles on interactive glass (`ChoiceTileState`: `.idle/.highlighted/.filtered/.correct/.wrong/.dimmed`; `.filtered` fades a tile the typed letters do not start, `emphasis` underlines the typed letters in the accent colour). `lang` tags the text (Chinese glyphs, VoiceOver) and starts Arabic at the tile's right edge. The grid lays them out 2×2 in one `GlassEffectContainer`, equal row heights. Digits are never bound to the tiles: the study flow handles the keys. |
| `.cardTextDirection(lang)`, `.cardTextLine(lang)`, `.cardFieldDirection(lang)` | Card text in its language's direction (`CardTextDirection`): Arabic runs right to left on the text view only, the layout around it stays left to right. `cardTextLine` for a text on a line of its own (it starts at the right edge), `cardFieldDirection` for text fields (AppKit ignores the layout direction there, so an Arabic field aligns to the right instead). |
| `SpecialCharacterBar(lang:) { char in }`, `SpecialCharacters.characters(for:)`, `SpecialCharacters.insert(_:into:selection:)` | Port of `SPECIAL_CHARS` / `charsFor` / `insertAtCaret` (src/lib/keyboard.js). Use with `TextField(text:selection:)`. `FlowLayout` wraps rows. |
| `ToastCenter` (`@Observable`), `.toastOverlay(center)`, `@Environment(ToastCenter.self)` | `show(_:tone:systemImage:action:duration:)`, `dismiss(_:)`; 3.5 s, paused on hover, max 4, sticky toasts get a close button, VoiceOver announcement. A floating bottom bar marked `.reservesToastSpace()` (the study screens' action bar) keeps the toasts above it. |
| `CelebrationView(trigger:playsOnAppear:origin:)` / `.celebration(trigger:)` | Confetti burst (Canvas, deterministic). Reduce Motion: soft glow, no movement. |
| `Haptics.success() / failure() / selection()` | `NSHapticFeedbackManager` (`.levelChange` for correct). |
| `Announcer.announce(_:important:)` | VoiceOver announcement (for the flows' `.announce` effect). |
| `EmptyStateView(systemImage:title:message:) { actions }` | Empty states ("Noch keine Lernsets"). |

## Snapshot harness (DEBUG)

`App/DebugSnapshot.swift` renders registered views to PNGs in light and dark and quits. It hosts
each scene in an off-screen borderless window and captures the window server's composite, so real
Liquid Glass, materials, `MeshGradient` and AppKit-backed buttons appear exactly as in the app
(`ImageRenderer` drops glass and glass buttons; it is only the fallback). The app is never
activated, no app window opens, the store is never touched.

Register scenes from any file of the app target, no central list to edit:

```swift
#if DEBUG
final class LearnSnapshots: SnapshotCatalog {
    override class var scenes: [SnapshotScene] {
        [
            SnapshotScene("learn-mc") { LearnPreviewHost(.multipleChoice) },          // 1240×800, light + dark
            SnapshotScene("learn-written", size: CGSize(width: 1000, height: 700)) { … },
            SnapshotScene("learn-narrow", sizes: [CGSize(width: 980, height: 640)], colorSchemes: [.dark]) { … },
        ]
    }
}
#endif
```

Scene content must use in-memory sample data (never the real `library.json`). It is laid out at
exactly the scene size; add `AppBackdrop()` / `.appBackdrop()` for screens that have one.
`@Environment(\.isSnapshotRendering)` is `true`, so decorative animation shows a still frame.

Run it (paths contain spaces, quote them):

```bash
APP="<derivedData>/Build/Products/Debug/Wortschatz.app/Contents/MacOS/Wortschatz"
"$APP" --list-snapshots
"$APP" --render-snapshots "$OUT" [--snapshot-filter learn,design-study] \
       [--snapshot-appearance light|dark] [--snapshot-renderer image] [--snapshot-inactive]
```

The app is sandboxed: if `$OUT` is not writable the PNGs land in
`~/Library/Containers/app.wortschatz.mac/Data/tmp/WortschatzSnapshots/<name>-<hash>/`. The last
output line is always `SNAPSHOT_DIR=<path>`; copy from there:

```bash
dir=$("$APP" --render-snapshots "$OUT" | sed -n 's/^SNAPSHOT_DIR=//p'); ditto "$dir" "$OUT"
```

Files are `<scene>-light.png` / `<scene>-dark.png` (plus `-<w>x<h>` for multi-size scenes), at
2× on Retina. Built-in scenes: `design-foundations`, `design-controls`, `design-progress`,
`design-chips`, `design-study-question`, `design-study-feedback`, `design-feedback`,
`design-overview-mock` (composition reference), `design-a11y-reduce-transparency`,
`design-a11y-increased-contrast`, `design-gallery` (everything, 1240×4200).
