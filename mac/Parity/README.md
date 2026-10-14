# Parity fixtures (JS reference → Swift)

The Swift port in `mac/Packages/WortschatzCore` must behave exactly like the web app's JS
(`src/core`, `src/lib`, `src/import/layout.js`, `src/store`). For every module there is a generator
here that runs the JS with JavaScriptCore and records inputs and outputs. A Swift parity test then
replays every case and compares the results JSON-for-JSON.

```
mac/Parity/gen-<name>.js  --jsc, TZ=Europe/Zurich-->  Tests/WortschatzCoreTests/Fixtures/<name>.json
                                                       Tests/WortschatzCoreTests/<Name>ParityTests.swift
```

Commands (from the project root, the path contains spaces so quote it):

```bash
mac/scripts/gen-fixtures.sh              # all generators (new gen-*.js files are picked up automatically)
mac/scripts/gen-fixtures.sh grading      # only gen-grading.js
cd mac/Packages/WortschatzCore && swift test                  # everything
cd mac/Packages/WortschatzCore && swift test --filter Parity  # parity suites only
```

Commit the generated `Fixtures/*.json`. `swift test` never runs JS. Regenerate them whenever a
generator or the web reference changes. Output is deterministic: two runs must be byte-identical
(`diff -r`).

## Writing a generator

- It is an ES module run with `jsc -m`, not Node. Use `print` (there is no `console`) and
  `readFile(path)` (UTF-8). jsc cannot list directories, so add new test fixtures to
  `FIXTURE_FILES` in `lib.js`.
- Import the web reference by **absolute path**:
  `import { grade } from '../../Website/src/core/grading.js';`
  Import the helpers relatively: `import { Cases, mulberry32, … } from './lib.js';`
- Keep it **deterministic**. Never use `Math.random` or `Date.now()`. Use `mulberry32(seed)` for
  fuzzing and pass explicit `now`/`rng` arguments to every engine function.
- Build large, diverse case sets (hundreds to thousands of cases):
  - every input of the module's `tests/*.test.js`;
  - every file in `tests/fixtures/` (`fixtureTexts()`), including the user's 52-pair list `user-example.txt`;
  - seeded fuzz.
- Record cases with `cases.add(fn, args, out)` (or `cases.run(fn, f, args)`, which records a thrown
  error as `{"throws": message}`), then finish with `cases.emit()`.
- Arguments and results go through `plain()`: `undefined` is dropped from objects (and becomes
  `null` in arrays), `Map` becomes an object, `Set` an array, `Date` epoch ms, `-0` becomes `0`, and
  `NaN`/`±Infinity` become `null`. JSON cannot carry NaN, lone surrogates or `undefined` arguments,
  so test those in the ported unit tests instead.

### Fixture format

```json
{"module":"text","count":11331,"cases":[
{"args":["  l’homme  ",false],"fn":"normalizeBasic","id":"normalizeBasic#0","out":"l'homme"},
...
]}
```

Each case has `id` (`<fn>#<n>`, for error messages), `fn` (the Swift test switches on it), `args`
(the JSON argument list) and `out` (the JS result). Keys are sorted and there is one case per line.

### Scripted engines (session.js, learn.js)

For the stateful engines, a case's `args` should describe a whole scenario: the cards, the
options, the seed and a list of actions such as `{"op":"answer","correct":true,"now":…}`.
- `out` holds the state snapshot (and any derived values like `current`, `counts` or
  `checkpoint`) after every action.
- Both sides create `mulberry32(seed)` once per scenario and pass the same rng to every call, so
  random numbers are consumed in the same order.

## Writing the Swift side

```swift
@Suite("Parity: grading.js")
struct GradingParityTests {
    @Test func fixture() throws {
        try runParity("grading") { c in
            switch c.fn {
            case "grade":
                let r = Grading.grade(given: try c.string(0), expected: try c.string(1),
                                      tolerance: Tolerance(json: c.arg(2)), lang: c.optionalString(3).flatMap(Lang.init(rawValue:)))
                return try encodeToJSONValue(r)
            default:
                return nil // an unknown fn fails the test
            }
        }
    }
}
```

Helpers live in `Tests/WortschatzCoreTests/Support/`:
- `runParity(_:tolerance:nullMatchesMissing:maxReported:_:)` runs every case. It reports up to 25
  mismatches with a path-based diff and the case's args, then a summary count per `fn`. Cases whose
  `fn` the closure does not handle fail the test.
- `ParityCase` provides the arguments:
  - `arg(i)` returns a `JSONValue` (`.null` when absent);
  - `string`, `double`, `int` and `bool` throw on a wrong type;
  - `optionalString` and `optionalDouble` return nil instead;
  - `decode(i, as:)` uses the type's `Decodable` conformance.
- `encodeToJSONValue(_:)` encodes an `Encodable` result. `assertParity(actual, expected, id)` checks a single value.
- `Fixtures.load(name)` loads `Fixtures/<name>.json` from `Bundle.module`.
- `zurich` is `TimeZone(identifier: "Europe/Zurich")`. Pass it wherever the JS uses local time.

Leniently decoded model types also have `init(json:)` / `init?(json:)` (`Card`, `VocabSet`,
`CardProgress`, `StudyOptionsPatch`, `Settings`, `StudySubset`, `ParseOptions`, …). They mirror
the JS sanitisers, so garbage inputs from a fixture map the same way they do in JS.

## Comparison rules (`ParityDiff`)

| JSON | Rule |
|---|---|
| number | equal within an absolute tolerance, 1e-9 by default (`tolerance: 0` for exact, e.g. PRNG). Round in the generator only where the JS itself rounds. |
| string | identical Unicode scalars. Swift `==` treats NFC "é" and NFD "e\u{301}" as equal, JS does not, and the diff does not either. |
| array | same length, compared element by element |
| object | Same keys. If JS **omitted** a key, Swift may omit it or write `null`. If JS wrote `null`, Swift must write `null` too: encode with `encodeNullable` (see `VocabSet`, `CardProgress`, `GradeResult.hint`, `LearnState.last` …). `nullMatchesMissing: true` relaxes this. |

Key order never matters.

## Porting pitfalls found so far

- **Strings:**
  - JS works in UTF-16 code units (`length`, `slice`, regex indices). `Array.from(s)` iterates
    code points, Swift `Character` grapheme clusters.
  - Port on `unicodeScalars`, or on `utf16` / `NSString` when index arithmetic matters.
  - `Dictionary<String, _>` and `Set<String>` also use canonical equivalence for their keys.
- **Whitespace:** JS `\s` / `trim()` differ from `CharacterSet.whitespacesAndNewlines`. Use
  `JSCompat.isWhitespace` / `JSCompat.trim`. NEL (U+0085) is *not* whitespace in JS.
- **Numbers:**
  - `Math.round` rounds half up (`JSCompat.round`).
  - Number formatting is `JSCompat.numberToString` ("5", not "5.0"; "1e-7").
  - `Number.isInteger` is `JSCompat.isInteger`.
- **Dates:**
  - All timestamps are epoch ms as `Double`.
  - Local calendar logic takes a `TimeZone` (`TimeUtil.localDate`, `dateKey`, `localTimestamp`,
    `dayNumber`). `localTimestamp` copies JS `new Date(y, m-1, d, …)`: an ambiguous time takes the
    earlier instant, a time in a gap moves forward.
  - `new Date(x)` truncates fractional ms (`JSCompat.timeClip`).
- **Unicode tables:** `\p{L}`, `\p{M}` and NFC/NFD agree between JSC and Swift/Foundation for every
  sampled character (Latin, Greek, Cyrillic, Arabic, Devanagari, Thai, CJK, Hangul, emoji). Very new
  code points could still differ.
- **Case mapping:** `lowercased()` is per scalar, while JS `toLowerCase()` applies the Greek final
  sigma rule ("ΑΣ" → "ας"). Fuzzed parity cases hit this, so use the module-internal
  `Grading.JSText` (code points with JS `===` identity, JS `toLowerCase`, `trim`, `slice`, `split`)
  wherever a port must match JS string handling exactly.
- **`/iu` regexes:** simple case folding also matches "ſ" (U+017F) to "s" and the Kelvin sign
  (U+212A) to "k", plus the Latin-1 capitals to their lowercase forms. Word-list regexes therefore
  need per-scalar comparison after the same folding. JSC does not case-close `\p{L}` / `\p{N}`, so
  U+0345 is not a letter there.
- **JS object quirks:** a lookup like `table[word]` on a plain object also finds inherited keys such
  as `constructor`. LangDetect keeps this on purpose (documented in `LangDetect.swift`).
- **Swift test code:** long `+` chains of string literals type-check very slowly, so use
  `[…].joined(separator: "\n")`. An `RNG` passed through `??` needs `@escaping`.
  `WriteSessionParityTests.apply` shows how to replay a scripted engine scenario.
- **Shell:** in zsh a `$VAR` holding a list is not word-split, so use arrays.
- **Randomness:** `mulberry32(seed:)` is bit-identical (tested on 530 seed sequences).
  - Engines must consume `rng()` in exactly the JS order, including the extra call in
    `randomIndex` and the clamps `if (!(j >= 0)) j = 0; if (j > i) j = i`.
  - The `shuffle` cases in `random.json` check the Fisher–Yates loop shape.
