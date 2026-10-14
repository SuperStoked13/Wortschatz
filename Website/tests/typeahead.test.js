// Typing on a multiple-choice question (src/core/typeahead.js): every case of the Mac app's
// LearnTypeAheadTests.swift, the matching ones as they are and the reducer ones against
// typingKey() (the screen's part of LearnFlowReducer), plus the arrow grid and the hint texts.
import { test, expect, run } from './harness.js';
import {
  TYPE_AHEAD_MAX,
  TYPE_AHEAD_MIN_LETTERS,
  TYPING_IDLE,
  articlePrefixes,
  typeAhead,
  moveHighlight,
  typingKey,
  optionState,
  returnLabel,
  typingHint,
  correctionHint,
} from '../src/core/typeahead.js';

const pick = (typed, choices, lang = 'fr') => typeAhead(typed, choices, lang).selected;

/* ------------------------------------------------------------- matching */

test('An article alone never picks; two letters after it do, if only one option fits', () => {
  const choices = ['la voiture', 'le chat', 'la maison', 'un arbre'];
  expect(pick('la', choices)).toBe(null);
  expect(pick('la ', choices)).toBe(null);
  expect(pick('la v', choices)).toBe(null);
  expect(pick('la vo', choices)).toBe(0);
  expect(pick('la voiture', choices)).toBe(0);
  expect(pick('La VOI', choices)).toBe(0);
  // "la " narrows to the options with that article.
  const narrowed = typeAhead('la ', choices, 'fr');
  expect(narrowed.matching).toEqual([0, 2]);
  expect(narrowed.isActive && !narrowed.hasEnoughLetters).toBe(true);
});

test('Two options starting alike need more letters', () => {
  const choices = ['la voiture', 'la vache', 'le vélo', 'la maison'];
  expect(pick('la v', choices)).toBe(null);
  expect(typeAhead('la va', choices, 'fr').matching).toEqual([1]);
  expect(pick('la va', choices)).toBe(1);
  expect(pick('la vo', choices)).toBe(0);
  // Without the article: "ve" fits only le vélo (accents do not matter).
  expect(pick('ve', choices)).toBe(2);
  expect(pick('v', choices)).toBe(null);
});

test('The option can be started without its article, at an alternative, or with a pronoun', () => {
  expect(pick('voi', ['la voiture', 'le chat', 'la maison', 'un arbre'])).toBe(0);
  expect(pick('ch', ['la voiture', 'le chat', 'la maison', 'un arbre'])).toBe(1);
  const alternatives = ['laid, laide', 'beau', 'joli', 'moche'];
  expect(pick('lai', alternatives)).toBe(0);
  expect(typeAhead('laide', alternatives, 'fr').ranges[0]).toEqual([6, 11]);
  const verbs = ['se dépêcher', 'se laver', 'partir', 'dormir'];
  expect(pick('se d', verbs)).toBe(null);
  expect(pick('se de', verbs)).toBe(0);
  expect(pick('dep', verbs)).toBe(0);
  const german = ['der Hund', 'die Katze', 'das Haus', 'der Hase'];
  expect(pick('der h', german, 'de')).toBe(null);
  expect(pick('der hu', german, 'de')).toBe(0);
  expect(pick('ha', german, 'de')).toBe(null);
  expect(pick('hau', german, 'de')).toBe(2);
});

test("Apostrophes and accents do not matter; l' counts as an article", () => {
  const choices = ["l'été", 'la tête', 'le thé', 'la fête'];
  expect(pick("l'e", choices)).toBe(null);
  expect(pick('l’et', choices)).toBe(0);
  expect(pick('te', choices)).toBe(1);
  expect(pick('the', choices)).toBe(2);
});

test('The typed article decides between options that only differ there', () => {
  const choices = ['le livre', 'la livraison', 'le lit', 'la lune'];
  // Strong match "le liv" wins over "la livraison" (matching only after its article).
  expect(typeAhead('le liv', choices, 'fr').matching).toEqual([0]);
  expect(pick('le liv', choices)).toBe(0);
  // Another article than the option's still finds it when nothing else fits.
  expect(pick('le voi', ['la voiture', 'le chat', 'la maison', 'un arbre'])).toBe(0);
});

test('An option typed in full wins over a longer one starting the same', () => {
  const choices = ['le pain', 'le pain de mie', 'le lait', "l'eau"];
  expect(pick('le pai', choices)).toBe(null);
  expect(pick('le pain', choices)).toBe(0);
  expect(pick('le pain d', choices)).toBe(1);
  // A one-letter option typed in full.
  expect(pick('y', ['y', 'en', 'le', 'lui'])).toBe(0);
});

test('Letters that start no option match nothing; ranges cover the typed part', () => {
  const choices = ['La Voiture', 'le chat', 'la maison', 'un arbre'];
  const none = typeAhead('xyz', choices, 'fr');
  expect(none.isActive && none.matching.length === 0 && none.selected === null).toBe(true);
  expect(typeAhead('la vo', choices, 'fr').ranges[0]).toEqual([0, 5]);
  expect(typeAhead('voi', choices, 'fr').ranges[0]).toEqual([3, 6]);
  expect(typeAhead('  ', choices, 'fr')).toEqual({ selected: null, matching: [], ranges: {}, isActive: false, hasEnoughLetters: false });
  // Several spaces count as one.
  expect(pick('la   vo', choices)).toBe(0);
});

test('Article prefixes come from grading.js, longest first; no language means all of them', () => {
  const fr = articlePrefixes('fr');
  expect(fr.slice(0, 2)).toEqual(['de la ', "de l'"]);
  expect(fr.includes('la ') && fr.includes("l'") && fr.includes('se ') && fr.includes("s'")).toBe(true);
  // "oneself" has no trailing space: it never starts an answer.
  expect(articlePrefixes('en').includes('oneself')).toBe(false);
  expect(articlePrefixes('de').includes('sich ')).toBe(true);
  const all = articlePrefixes(null);
  expect(all.includes('der ') && all.includes('il ') && all.includes("un'")).toBe(true);
  expect(all.length).toBe(new Set(all).size);
  expect(articlePrefixes('other')).toEqual([]);
  // Without a language every article counts.
  expect(pick('der hu', ['der Hund', 'die Katze', 'das Haus', 'der Hase'], null)).toBe(0);
});

test('Ranges are offsets into the original text (decomposed accents, ß)', () => {
  // "e" + combining acute: one character, two code units.
  const decomposed = 'le thé';
  const r = typeAhead('the', [decomposed, 'la tete'], 'fr').ranges[0];
  expect(decomposed.slice(r[0], r[1])).toBe('thé');
  expect(pick('strasse', ['die Straße', 'der Weg'], 'de')).toBe(0);
  expect(typeAhead('die stras', ['die Straße', 'der Weg'], 'de').ranges[0]).toEqual([0, 9]);
});

/* ----------------------------------------------------------------- keys */

// A multiple-choice question in a session (the Mac test's four new cards): the answer is the
// option at `correct`.
function session(correct = 1) {
  const texts = ['le chat', 'la voiture', 'un arbre', 'la maison'];
  const choices = texts.map((text, i) => ({ cardId: `c${i}`, text }));
  const s = {
    state: TYPING_IDLE,
    choices,
    lang: 'fr',
    correct,
    actions: [],
    announced: [],
    send(key, repeat = false) {
      const out = typingKey(s.state, key, { choices, lang: 'fr', columns: 2, repeat });
      s.state = out.state;
      if (out.action) s.actions.push(out.action);
      if (out.announce) s.announced.push(out.announce);
      return out;
    },
    type(text, repeat = false) {
      for (const ch of text) s.send({ kind: 'char', text: ch }, repeat);
    },
    get answer() {
      return texts[correct];
    },
    option(i) {
      return optionState(s.state, i, typeAhead(s.state.typed, texts, 'fr'));
    },
  };
  return s;
}

test('Typing the answer highlights it and Return chooses it', () => {
  for (let correct = 0; correct < 4; correct++) {
    const s = session(correct);
    s.type(s.answer.slice(0, 2));
    // An article (or two letters of it) is not enough.
    expect(s.state.highlighted).toBe(null);
    expect(returnLabel(s.state)).toBe(null);
    s.type(s.answer.slice(2));
    expect(s.state.typed).toBe(s.answer);
    expect(s.state.highlighted).toBe(correct);
    expect(returnLabel(s.state)).toBe('Auswählen');
    expect(s.option(correct)).toBe('highlighted');
    expect(s.announced[s.announced.length - 1]).toBe(`Antwort ${correct + 1}: ${s.answer}. Eingabetaste wählt sie.`);
    const out = s.send({ kind: 'return' });
    expect(out.action).toEqual({ type: 'choose', index: correct });
    expect(s.state.typed).toBe('');
    expect(s.state.highlighted).toBe(null);
  }
});

test('Options the letters do not start fade; ⌫ deletes, esc clears before leaving', () => {
  const s = session();
  s.type('la ');
  const texts = s.choices.map((c) => c.text);
  const filtered = [0, 1, 2, 3].filter((i) => s.option(i) === 'filtered');
  expect(filtered.map((i) => texts[i]).sort()).toEqual(['le chat', 'un arbre']);
  s.type('vo');
  expect(texts[s.state.highlighted]).toBe('la voiture');
  s.send({ kind: 'delete' });
  expect(s.state.typed).toBe('la v');
  expect(s.state.highlighted).toBe(null);
  const cleared = s.send({ kind: 'escape' });
  expect(s.state.typed).toBe('');
  expect(cleared.action).toBe(null);
  expect(cleared.announce).toBe('Eingabe gelöscht');
  // Nothing typed: esc leaves.
  expect(s.send({ kind: 'escape' }).action).toEqual({ type: 'leave' });
});

test('Held ⌫ keeps deleting, ⌥⌫ deletes a word; other held keys do nothing', () => {
  const s = session();
  s.type('la voi');
  s.send({ kind: 'delete', word: true });
  expect(s.state.typed).toBe('la ');
  s.type('vo');
  expect(s.state.highlighted !== null).toBe(true);
  // Held ⌫: the repeats delete too, one letter each.
  s.send({ kind: 'delete' });
  s.send({ kind: 'delete' }, true);
  expect(s.state.typed).toBe('la ');
  expect(s.state.highlighted).toBe(null);
  s.send({ kind: 'delete' }, true);
  s.send({ kind: 'delete' }, true);
  s.send({ kind: 'delete' }, true);
  expect(s.state.typed).toBe('');
  // More ⌫ on nothing typed does nothing (and never leaves the question).
  expect(s.send({ kind: 'delete' }, true).action).toBe(null);
  expect(s.send({ kind: 'delete', word: true }).action).toBe(null);
  expect(s.actions).toEqual([]);
  // A held letter still types only once.
  s.send({ kind: 'char', text: 'x' });
  s.send({ kind: 'char', text: 'x' }, true);
  expect(s.state.typed).toBe('x');
  // ⌥⌫ over trailing spaces takes the word before them.
  s.type('ab cd  ');
  s.send({ kind: 'delete', word: true });
  expect(s.state.typed).toBe('xab ');
});

test('Return with letters that pick nothing is rejected; digits and arrows still work', () => {
  const s = session();
  s.type('xq');
  const rejections = s.state.rejections;
  const out = s.send({ kind: 'return' });
  expect(out.action).toEqual({ type: 'reject' });
  expect(out.announce).toBe('Keine eindeutige Antwort – tippe weiter oder wähle mit 1 bis 4.');
  expect(s.state.rejections).toBe(rejections + 1);
  expect(s.state.typed).toBe('xq');
  // Arrows take over from typing.
  s.send({ kind: 'arrow', direction: 'down' });
  expect(s.state.typed).toBe('');
  expect(s.state.highlighted).toBe(0);
  // A digit still chooses directly.
  s.type('la');
  expect(s.send({ kind: 'digit', n: s.correct + 1 }).action).toEqual({ type: 'choose', index: s.correct });
  // 0 = "Weiss ich nicht", a digit past the options does nothing.
  expect(s.send({ kind: 'digit', n: 0 }).action).toEqual({ type: 'dontKnow' });
  expect(s.send({ kind: 'digit', n: 5 }).action).toBe(null);
  // Return with nothing typed and nothing highlighted does nothing.
  expect(session().send({ kind: 'return' }).action).toBe(null);
});

test('A leading space is ignored and the next question starts with nothing typed', () => {
  const s = session();
  s.type(' ');
  expect(s.state.typed).toBe('');
  s.type('zz');
  const out = s.send({ kind: 'digit', n: s.correct + 1 });
  expect(out.state.typed).toBe('');
  expect(out.state.highlighted).toBe(null);
  // Nothing matches: no option fades.
  expect([0, 1, 2, 3].map((i) => optionState({ ...TYPING_IDLE, typed: 'zz' }, i, typeAhead('zz', s.choices.map((c) => c.text), 'fr')))).toEqual([
    'idle',
    'idle',
    'idle',
    'idle',
  ]);
});

test('Typing stops at TYPE_AHEAD_MAX characters; the minimum letters are 2', () => {
  expect(TYPE_AHEAD_MIN_LETTERS).toBe(2);
  const s = session();
  s.type('a'.repeat(TYPE_AHEAD_MAX + 5));
  expect(s.state.typed.length).toBe(TYPE_AHEAD_MAX);
});

test('Arrow keys move over a 2-column grid; the first press lands on option 1', () => {
  expect(moveHighlight(null, 'down', 4)).toBe(0);
  expect(moveHighlight(null, 'left', 4)).toBe(0);
  expect(moveHighlight(0, 'right', 4)).toBe(1);
  expect(moveHighlight(1, 'right', 4)).toBe(1);
  expect(moveHighlight(1, 'left', 4)).toBe(0);
  expect(moveHighlight(0, 'down', 4)).toBe(2);
  expect(moveHighlight(3, 'up', 4)).toBe(1);
  expect(moveHighlight(2, 'down', 4)).toBe(2);
  // Three options: ↓ from the right one reaches the lone last option.
  expect(moveHighlight(1, 'down', 3)).toBe(2);
  expect(moveHighlight(2, 'right', 3)).toBe(2);
  // One column (phones): ↑↓ step by one, ←→ stay.
  expect(moveHighlight(0, 'down', 4, 1)).toBe(1);
  expect(moveHighlight(2, 'up', 4, 1)).toBe(1);
  expect(moveHighlight(1, 'right', 4, 1)).toBe(1);
  expect(moveHighlight(3, 'down', 4, 1)).toBe(3);
  expect(moveHighlight(null, 'up', 0)).toBe(null);
  // The same arrow again announces nothing new.
  const s = session();
  s.send({ kind: 'arrow', direction: 'right' });
  expect(s.announced).toEqual(['Antwort 1: le chat']);
  s.send({ kind: 'arrow', direction: 'left' });
  expect(s.announced.length).toBe(1);
});

test('The hint under the tiles says what Enter does and how to correct', () => {
  const texts = ['la voiture', 'le chat', 'la maison', 'un arbre'];
  expect(typingHint(typeAhead('la vo', texts, 'fr'), texts)).toEqual({ kind: 'pick', text: 'wählt «la voiture»' });
  expect(typingHint(typeAhead('la', texts, 'fr'), texts)).toEqual({ kind: 'more', text: 'Weiter tippen …' });
  expect(typingHint(typeAhead('xq', texts, 'fr'), texts)).toEqual({ kind: 'none', text: 'Keine Antwort passt' });
  expect(correctionHint(false)).toBe('Rücktaste korrigiert · Esc löscht');
  expect(correctionHint(true)).toBe('⌫ korrigiert · esc löscht');
  expect([correctionHint(false), correctionHint(true), 'Eingabe gelöscht'].join(' ').includes('ß')).toBe(false);
});

await run('typeahead.test.js');
