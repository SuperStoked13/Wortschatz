# Wortschatz: Arabisch und Chinesisch (Mandarin)

Date: 2026-10-15. Both apps: Website/ (Windows app UI + JS reference) and mac/ (WortschatzCore + app). JS and Swift stay in
parity; regenerate `mac/Parity` fixtures after JS core changes (`mac/scripts/gen-fixtures.sh`).

## Decisions (user)

> "Can you add Arabic, Mandarin"

Asked upfront, all answered with the recommended option:

- **Chinese answers: characters or pinyin.** For a card like «你好 (nǐ hǎo)» typing 你好 or nǐ hǎo is correct. Tone numbers
  equal tone marks (ni3 hao3 = nǐ hǎo). Spaces between pinyin syllables don't matter (nihao). Cards with only characters
  still need characters.
- **Missing tones behave like accents.** «Akzente ignorieren» off: wrong, hint «Nur die Töne fehlen». On: correct, note «Töne».
- **Arabic is generous.** Vowel marks (harakat, shadda, sukun, tanwin, superscript alef, Quranic marks) never matter.
  ة/ه, ى/ي and hamza forms (أ إ آ ٱ → ا, ؤ → و, ئ → ي) count as correct with the note «Schreibvariante». Tatweel ـ is
  ignored. The Arabic comma «،» separates alternatives like «,».
- **No automatic pinyin** (not now).

Not asked, decided here: the German name is «Chinesisch» (short «ZH»), «Arabisch» («AR»). Traditional and simplified
characters are not converted into each other. Cantonese voices are never used for Chinese. Anki is not embedded.

## Languages

| Code | Name | Short | BCP 47 | RTL |
|---|---|---|---|---|
| `ar` | Arabisch | AR | `ar` | yes |
| `zh` | Chinesisch | ZH | `zh-CN` | no |

- `LANG_ORDER` = fr, en, es, it, **ar, zh**, de, other (JS `lib/labels.js`, Swift `Labels.swift`). JS `LANGS.ar` gets
  `rtl: true` (only ar; other entries keep exactly `{name, short, bcp47}`); Swift gets `Lang.isRTL`.
- Storage accepts `ar`/`zh`: `store/db.js` `LANG_CODES`, Swift `Lang` enum (`Models.swift`). Unknown codes still fall back
  to fr/de as today. Rollout: older app versions turn `ar`/`zh` sets into fr/de, so Mac and Windows ship together.

## Shared text folds (`core/text.js`, `TextNormalizer.swift`)

- `normalizeBasic` also removes bidi controls U+200E U+200F U+061C U+202A–U+202E U+2066–U+2069 (like zero-width chars).
- New `foldScripts(s)` — comparison only, never applied to stored text:
  - Arabic presentation forms (U+FB50–U+FDFF, U+FE70–U+FEFE) → NFKC of those characters only (no whole-string NFKC).
  - Remove Arabic vowel and Quranic marks on NFC text by explicit ranges: U+0610–U+061A, U+064B–U+0652, U+0656–U+065F,
    U+0670, U+06D6–U+06DC, U+06DF–U+06E8, U+06EA–U+06ED. Keep U+0653–U+0655 (madda/hamza: those are variants, below).
    Remove tatweel U+0640.
  - Punctuation to ASCII: ، → `,` ؛ → `;` ؟ → `?`; full-width U+FF01–U+FF5E → ASCII U+0021–U+007E; 、 → `,` 。 → `.`
    【 → `[` 】 → `]`.
  - Remove spaces between two Han characters.
  - Script ranges are explicit code-point ranges (Swift has no Script property). Arabic: U+0600–U+06FF, U+0750–U+077F,
    U+08A0–U+08FF, U+FB50–U+FDFF, U+FE70–U+FEFE. Han: U+3400–U+4DBF, U+4E00–U+9FFF, U+F900–U+FAFF, U+20000–U+2FA1F.
  - Used by: grading `prep` and `splitAlternatives`, synonyms `keyOf`, learn `textKey`/`answerKeys`, editor duplicate
    check (`termKey`), type-ahead folding (+ its own rules), Swift `Synonyms`/`ExtendedSynonyms.looseKey`.

## Grading (`core/grading.js`, `Grading.swift`)

- `resolveLang` accepts `ar` and `zh`. `ARTICLES.ar = ['ال']` (a **glued** article: no space, like an elided article but
  without an apostrophe; «كتاب» for «الكتاب» → correct with «Artikel fehlte» when articles are tolerated, hint «Artikel
  fehlt» otherwise), `ARTICLES.zh = []`, `REFLEXIVES.ar = REFLEXIVES.zh = []`.
- `prep` applies `foldScripts` to both sides, so vowel marks and tatweel never matter and never produce a note.
- `PUNCT` also strips 「」『』《》〈〉.
- `isSentenceLike`: text containing Arabic or Han letters that ends in `.`, `?`, `!` or `…` (after the fold) is a
  sentence (commas inside don't split it).
- `isAlternationSlash`: a Han run of any length is word-like (谢谢/多谢 splits).
- **Letter variants** (Arabic only): a new comparator dimension that folds ة→ه, ى→ي, أ/إ/آ/ٱ→ا, ؤ→و, ئ→ي. Always
  allowed (no setting). Its combos exist only when given or expected contains Arabic letters (so Latin grading and its
  parity data stay identical), and each variant combo is tried right after its non-variant twin and before any accent
  combo, so a hamza difference reports «Schreibvariante», not «Akzente». Rank weight 2. Note key `variant`.
- **Chinese** (only when the answer language resolves to `zh`):
  - Tone numbers become tone marks on both sides before splitting: a syllable is a run of Latin letters directly followed
    by a digit 1–5; inside it `v` and `u:` become `ü`; the mark goes on `a` or `e` if present, on `o` in `ou`, otherwise on
    the last vowel (tones 1–4 = U+0304, U+0301, U+030C, U+0300, then NFC); 5 (and 0) is neutral: the digit is dropped.
  - Spaces don't count when comparing (pinyin syllables, Han).
  - An expected alternative made of a Han part and a Latin part («你好 (nǐ hǎo)», «你好（nǐ hǎo）», «你好 nǐ hǎo»,
    «nǐ hǎo 你好») accepts: the whole, the Han part alone (no note, not even «Klammerinhalt weggelassen», independent of the
    brackets setting) and the Latin part alone (note `pinyin` «Nur Pinyin»). Han-only alternatives accept no pinyin.
  - Missing or wrong tones run through the existing accent comparator; for `zh` the note `accents` is reported as `tones`
    («Töne») and the hint `accentsOnly` as `tonesOnly` («Nur die Töne fehlen»).
  - Typo budget counts only non-Han letters: a wrong character is never a typo. Pinyin keeps the Latin typo rule.
- `NOTE_ORDER` = article, pronoun, abbreviation, partial, parentheses, pinyin, case, accents, tones, variant, typo, order.
  `HINT_ORDER` gets `tonesOnly` right after `accentsOnly`. Labels: `variant` «Schreibvariante», `pinyin` «Nur Pinyin»,
  `tones` «Töne», hint `tonesOnly` «Nur die Töne fehlen» (JS `lib/labels.js`, Swift `Labels.swift`; unknown keys are
  dropped silently, so the labels are required).
- Exam (`core/exam.js`, `Exam.swift`): `tones` is a small mistake like `accents`; `variant` and `pinyin` are accepted
  forms (full point).
- `diffAnswer`/`diffChars`: compare letter+mark clusters (`\P{M}\p{M}*`), so marks never stand alone; when the learner typed
  no Arabic vowel marks, drop marks and tatweel from the expected side first. For Chinese, the diff uses the form
  (whole, Han, pinyin) the answer was closest to.

## Multiple-choice type-ahead (`core/typeahead.js`, `LearnTypeAhead.swift`, hand-mirrored tests)

- Folding: tatweel and Arabic marks dropped, ة→ه, ى→ي, hamza via NFD (Swift switches to NFD + strip marks like the JS,
  fixing today's mismatch: `.diacriticInsensitive` keeps harakat).
- Starts: also after `(`/`（` and at a Han→Latin boundary, so «ni» selects «你好 (nǐ hǎo)»; for `zh` spaces are ignored.
- Arabic «ال» is a glued article prefix: «كت» selects «الكتاب».
- Arabic-Indic digits (U+0660–U+0669, U+06F0–U+06F9) choose options like ASCII digits.

## Language detection (`core/langdetect.js`, `LangDetect.swift`, parity)

- `SUPPORTED` = fr, de, en, es, it, **ar, zh** (appended). Lexicon, trigram, suffix and consonant features stay on the five
  Latin languages. An Arabic token adds ar evidence, a Han run zh evidence; those tokens skip the Latin features (today they
  produce spurious de/en/es scores). Pinyin tone vowels (ǎ ǐ ǒ ǔ ǚ ǜ ǘ ǖ strong, ā ē ī ō ū weaker) are zh evidence.
  Arabic marks and tatweel are removed before tokenising.
- Latin-only text gives bit-identical results to today: `PRIOR` ar/zh = 0, script languages with score 0 are left out of
  softmax/rank/column votes, and they iterate last.

## Vocabulary import (`core/parser.js`, `VocabParser*.swift`, parity)

- `LANG_CODES` + ar/zh; header names: arabisch, arabe, arabic, árabe, arabo, عربي, العربية / chinesisch, chinois,
  chinese, chino, cinese, mandarin, 中文, 汉语, 漢語, 普通话, 普通話; codes AR, ZH.
- 7-language votes and priors (ar/zh prior 0).
- «你好（nǐ hǎo）- Hallo» and «你好 (nǐ hǎo)- Hallo» parse (closing bracket glued to a spaced dash); «你好：Hallo» uses the
  full-width colon like `:`.
- Three cells Han | pinyin | translation (or pinyin | Han | translation) become «汉字 (pinyin)» → translation.
- Stored text is otherwise kept as written (only bidi controls are dropped).

## Photo and PDF import

- Web OCR (`import/ocr.js`): `ar` → `ara`, `zh` → `chi_sim` (tesseract data from the same CDN path, ~1.7 MB each). No space
  between two CJK characters when OCR words are joined.
- `import/layout.js` / `TextLayout.swift` (parity): a cell whose letters are mostly right-to-left joins its pieces from
  right to left and is assigned to a column by its right edge; no space is inserted between two Han characters when
  pieces, cells or wrapped lines are joined. `import/pdf.js` passes pdf.js `dir` through.
- Mac OCR (`OCRService.swift`): `ar` → `ar-SA`, `zh` → `zh-Hans`; `VisionSettings.supported` de-duplicates by full
  identifier; if Vision rejects the combination with the definition language, recognise with the term language alone.
- Mac spell checker (`VocabSpellChecker.swift`): `ar` → `ar`, `zh` → none.

## Read aloud

- Web `lib/speech.js`, Mac `SpeechService.swift`: for `zh`, never a Cantonese voice (zh-HK, zh-MO, yue*). Samples for
  «Probe hören»: ar «مرحبًا! اليوم نتعلّم كلمات جديدة.», zh «你好！今天我们学习新词。». For `zh` text with Han characters,
  Latin (pinyin) runs and brackets are not read.
- The Mac voice list follows `LANG_ORDER` without «Andere».

## Screens

- **Web**: one helper in `lib/labels.js` (`textAttrs(code)` → `{lang, dir}`: `rtl` for ar, `auto` for other/unknown, none
  for LTR languages; `fieldAttrs(code)` → `{lang, dir: 'auto'}`) replaces the per-screen `bcp47` copies; `dir` sits only on
  the innermost element holding card text (layout stays LTR). User text (set titles, search hits, import text, skipped
  lines, export preview) gets `dir="auto"`. CSS: `:lang(ar)` card text line-height 1.6 and `letter-spacing: normal`;
  `:lang(zh)` `letter-spacing: normal` and a CJK font stack (Microsoft YaHei UI, PingFang SC, Noto Sans CJK SC); MC tiles
  `text-align: start`; diff spans without padding for Arabic. Editor auto-grow mirror gets the field's `lang`;
  spellcheck off for ar/zh fields. Screen-reader announcement of the right answer carries its language.
- **Mac**: `Lang.isRTL`; Arabic card text and answer fields get a right-to-left layout direction on the text view only
  (prompt, answer field and box, MC tiles, Write, Karteikarten, Prüfung sheet and results, set table, editor rows, card
  editors, checkpoint, summaries, import preview). Han text gets its language identifier where it is missing (MC tiles,
  set table cells, checkpoint) so Chinese glyphs are used.
- **Special characters**: ar none, zh `ü`.
- **Study options**: accent example for zh «ni hao» = «nǐ hǎo».
- **Mac Apple-Intelligence synonyms**: zh only when `SystemLanguageModel.default.supportsLocale` says so; ar is not
  supported by the on-device model (measured 2026-10-15), so it stays off.

## Keyboard and input methods

- Web: Enter in the dashboard search, Escape in modals and the Enter swallow after a submit ignore composing keys
  (`isComposing` / keyCode 229). «Any key continues» after an answer also continues on keyCode 229 without
  `preventDefault`, so a Pinyin composition starts in the fresh field instead of the locked one. Ctrl shortcuts fall back
  to `e.code` on non-Latin layouts (Arabic) like flashcards/exam already do. `isTypedKey` accepts multi-code-point letter
  keys (the Arabic «لا» key).
- Mac: «any key continues» with an input method (not a plain layout) active continues without inserting the raw letter;
  editor Backspace/Tab and special-character inserts do nothing while marked text is composing; Arabic-Indic digits choose
  MC options.

## Out of scope

Automatic pinyin, traditional↔simplified conversion, Cantonese, Anki import/scheduling, other RTL languages (Hebrew,
Persian work as «Andere» and profit from `dir="auto"` and the bidi fixes).
