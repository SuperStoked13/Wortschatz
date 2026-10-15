// The study screens' shortcuts (src/screens/write-keys.js, shared by Lernen and Schreiben):
// which keydown is which command (⌘ → Ctrl, ⌥ → Alt, never Ctrl+Alt = AltGr), the key names
// of the hints, characters typed with AltGr / ⌥, that the screens' modules import, and the
// key routing of both screens on a minimal stand-in document (held keys, who owns Enter), and
// the Arabic keyboard and Chinese input methods (Pinyin).
import { test, expect, run } from './harness.js';
import { studyCommand, shortcutText, shortcutAria, isTypedKey, startsComposition, settleEnter, ENTER_SETTLE_MS, bindWriteKeys } from '../src/screens/write-keys.js';
import * as learnKeys from '../src/screens/learn-keys.js';
import * as learnScreen from '../src/screens/learn.js';
import * as writeScreen from '../src/screens/write.js';
import * as writeViews from '../src/screens/write-views.js';
import * as learnMc from '../src/screens/learn-mc.js';

const key = (k, mods = {}) => ({ key: k, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...mods });

test('Enter combinations: Alt «Weiss ich nicht», Ctrl or ⌘ «Ich hatte recht»', () => {
  expect(studyCommand(key('Enter', { altKey: true }))).toBe('dontKnow');
  expect(studyCommand(key('Enter', { ctrlKey: true }))).toBe('override');
  expect(studyCommand(key('Enter', { metaKey: true }))).toBe('override');
  expect(studyCommand(key('Enter'))).toBe(null);
  expect(studyCommand(key('Enter', { shiftKey: true }))).toBe(null);
  // AltGr (Ctrl+Alt) is no command.
  expect(studyCommand(key('Enter', { ctrlKey: true, altKey: true }))).toBe(null);
});

test('Letters with Ctrl or ⌘: K, R, D, E and Shift+R; Esc alone leaves', () => {
  expect(studyCommand(key('k', { ctrlKey: true }))).toBe('options');
  expect(studyCommand(key('K', { metaKey: true }))).toBe('options');
  expect(studyCommand(key('r', { ctrlKey: true }))).toBe('speak');
  expect(studyCommand(key('d', { ctrlKey: true }))).toBe('star');
  expect(studyCommand(key('e', { ctrlKey: true }))).toBe('edit');
  expect(studyCommand(key('R', { ctrlKey: true, shiftKey: true }))).toBe('restart');
  expect(studyCommand(key('Escape'))).toBe('exit');
  expect(studyCommand(key('Escape', { shiftKey: true }))).toBe(null);
  // Plain letters, other combinations and AltGr letters (€ is AltGr+E) are no commands.
  expect(studyCommand(key('k'))).toBe(null);
  expect(studyCommand(key('e', { ctrlKey: true, altKey: true }))).toBe(null);
  expect(studyCommand(key('€', { ctrlKey: true, altKey: true }))).toBe(null);
  expect(studyCommand(key('x', { ctrlKey: true }))).toBe(null);
  expect(studyCommand(key('k', { ctrlKey: true, shiftKey: true }))).toBe(null);
  expect(studyCommand(null)).toBe(null);
});

test('Key names: Strg and Alt on Windows, ⌘ and ⌥ on Apple', () => {
  expect(shortcutText('dontKnow')).toBe('Alt+↵');
  expect(shortcutText('dontKnow', true)).toBe('⌥↵');
  expect(shortcutText('override')).toBe('Strg+↵');
  expect(shortcutText('options')).toBe('Strg+K');
  expect(shortcutText('options', true)).toBe('⌘K');
  expect(shortcutText('restart')).toBe('Strg+Umschalt+R');
  expect(shortcutText('exit')).toBe('Esc');
  expect(shortcutText('nothing')).toBe('');
  expect(shortcutAria('override')).toBe('Control+Enter');
  expect(shortcutAria('override', true)).toBe('Meta+Enter');
  expect(shortcutAria('dontKnow')).toBe('Alt+Enter');
  expect(ENTER_SETTLE_MS).toBe(280);
});

test('Typed characters: plain, Shift, AltGr and ⌥; not Ctrl, ⌘ or named keys', () => {
  expect(isTypedKey(key('a'))).toBe(true);
  expect(isTypedKey(key('A', { shiftKey: true }))).toBe(true);
  expect(isTypedKey(key('@', { ctrlKey: true, altKey: true }))).toBe(true);
  expect(isTypedKey({ ...key('@'), getModifierState: (m) => m === 'AltGraph' })).toBe(true);
  expect(isTypedKey(key('ç', { altKey: true }))).toBe(true);
  expect(isTypedKey(key('a', { ctrlKey: true }))).toBe(false);
  expect(isTypedKey(key('a', { metaKey: true }))).toBe(false);
  expect(isTypedKey(key('Backspace'))).toBe(false);
  expect(isTypedKey(key('Dead'))).toBe(false);
  expect(isTypedKey(key('😀'))).toBe(true);
});

test('Arabic keyboard: the «لا» key types two letters at once; named keys stay named', () => {
  expect(isTypedKey(key('لا'))).toBe(true);
  expect(isTypedKey(key('لأ', { shiftKey: true }))).toBe(true);
  expect(isTypedKey(key('ك'))).toBe(true);
  expect(isTypedKey(key('١'))).toBe(true);
  expect(isTypedKey(key('لا', { ctrlKey: true }))).toBe(false);
  for (const named of ['Process', 'Unidentified', 'Enter', 'ArrowLeft', 'ab']) expect(isTypedKey(key(named))).toBe(false);
  // Several characters that are not all letters (a digit after a letter) are no key.
  expect(isTypedKey(key('ل1'))).toBe(false);
});

test('Arabic keyboard: Ctrl shortcuts fall back to the key position', () => {
  // Chromium reports the layout's letter (Ctrl+R gives «ق» on Arabic 101).
  expect(studyCommand(key('ق', { ctrlKey: true, code: 'KeyR' }))).toBe('speak');
  expect(studyCommand(key('ن', { ctrlKey: true, code: 'KeyK' }))).toBe('options');
  expect(studyCommand(key('ي', { ctrlKey: true, code: 'KeyD' }))).toBe('star');
  expect(studyCommand(key('ث', { metaKey: true, code: 'KeyE' }))).toBe('edit');
  expect(studyCommand(key('ً', { ctrlKey: true, shiftKey: true, code: 'KeyR' }))).toBe('restart');
  // AltGr stays typing; a Latin layout keeps its own letters (AZERTY «,» sits on KeyM).
  expect(studyCommand(key('ق', { ctrlKey: true, altKey: true, code: 'KeyR' }))).toBe(null);
  expect(studyCommand(key(',', { ctrlKey: true, code: 'KeyM' }))).toBe(null);
  expect(studyCommand(key('k', { ctrlKey: true, code: 'KeyX' }))).toBe('options');
  expect(studyCommand(key('x', { ctrlKey: true, code: 'KeyK' }))).toBe(null);
});

test('An input method\'s first key (keyCode 229, nothing composed yet) starts a composition', () => {
  expect(startsComposition({ key: 'Process', keyCode: 229, isComposing: false })).toBe(true);
  expect(startsComposition({ key: 'Process', keyCode: 229, isComposing: true })).toBe(false);
  expect(startsComposition({ key: 'Process', keyCode: 229, isComposing: false, repeat: true })).toBe(false);
  expect(startsComposition({ key: 'n', keyCode: 78, isComposing: false })).toBe(false);
  expect(startsComposition(null)).toBe(false);
});

test('Multiple choice digits: ASCII and Arabic-Indic, never with Alt or Ctrl', () => {
  expect(learnKeys.choiceDigit(key('3'))).toBe(3);
  expect(learnKeys.choiceDigit(key('٣'))).toBe(3);
  expect(learnKeys.choiceDigit(key('۲'))).toBe(2);
  expect(learnKeys.choiceDigit(key('٠'))).toBe(0);
  expect(learnKeys.choiceDigit(key('3', { altKey: true }))).toBe(null);
  expect(learnKeys.choiceDigit(key('٣', { ctrlKey: true }))).toBe(null);
  expect(learnKeys.choiceDigit(key('a'))).toBe(null);
  expect(learnKeys.choiceDigit(key('12'))).toBe(null);
  expect(learnKeys.choiceDigit(null)).toBe(null);
});

test('The study screens and their key and view modules import without a DOM', () => {
  expect(typeof learnKeys.bindLearnKeys).toBe('function');
  expect(typeof learnScreen.render).toBe('function');
  expect(typeof writeScreen.render).toBe('function');
  expect(typeof writeViews.attachStreakBadge).toBe('function');
  expect(typeof writeViews.keyHints).toBe('function');
  expect(typeof writeViews.studyKeyRows).toBe('function');
  expect(typeof learnMc.createMcCard).toBe('function');
});

/* -------------------------------------------- key routing on a stand-in document */

// A focusable stand-in: `classes` decide what closest() finds ('button', 'tile', …).
function node(tag, classes = [], parent = null) {
  const el = {
    tag,
    classes,
    parent,
    closest(selector) {
      for (let n = el; n; n = n.parent) {
        for (const s of selector.split(',').map((x) => x.trim())) {
          if (s === n.tag || (s.startsWith('.') && n.classes.includes(s.slice(1))) || (s === 'a[href]' && n.tag === 'a')) return n;
        }
      }
      return null;
    },
  };
  return el;
}

// Runs fn(dispatch) with a stand-in `document`; dispatch(target, key, mods) returns the event.
function withDocument(fn) {
  const saved = globalThis.document;
  const listeners = [];
  globalThis.document = {
    addEventListener: (type, l) => listeners.push(l),
    removeEventListener: (type, l) => listeners.splice(listeners.indexOf(l), 1),
  };
  const dispatch = (target, k, mods = {}) => {
    const e = {
      ...key(k, mods),
      repeat: false,
      isComposing: false,
      keyCode: 0,
      target,
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true;
      },
      getModifierState: () => false,
      ...mods,
    };
    for (const l of listeners.slice()) l(e);
    return e;
  };
  try {
    fn(dispatch);
  } finally {
    globalThis.document = saved;
  }
}

test('Schreiben: a held key never moves on after a correct answer; a fresh one does', () => {
  withDocument((dispatch) => {
    const input = node('input');
    let continued = 0;
    const off = bindWriteKeys({
      ownInput: () => input,
      isLocked: () => false,
      onEnter: () => {},
      canContinueOnKey: () => true,
      onContinueKey: () => continued++,
      onCommand: () => {},
    });
    const held = dispatch(input, 'a', { repeat: true });
    expect(continued).toBe(0);
    expect(held.defaultPrevented).toBe(true);
    dispatch(input, 'a');
    expect(continued).toBe(1);
    off();
  });
});

test('Lernen: Enter on a tile or «Auswählen» is the screen\'s while it owns Enter; other controls keep it', () => {
  withDocument((dispatch) => {
    const grid = node('div', ['ln-tiles']);
    const tile = node('button', ['ln-tile'], grid);
    const pick = node('button', ['ln-pick']);
    const dont = node('button', ['ln-dont']);
    const body = node('body');
    let entered = 0;
    let owns = true;
    const asked = [];
    const off = learnKeys.bindLearnKeys({
      ownInput: () => null,
      isLocked: () => false,
      onEnter: () => entered++,
      ownsEnter: (control) => {
        asked.push(control);
        return owns && !!control.closest('.ln-tiles, .ln-pick');
      },
      onKey: () => {},
      onCommand: () => {},
    });
    // On the tile and on «Auswählen»: the screen chooses (the browser's click is prevented).
    expect(dispatch(tile, 'Enter').defaultPrevented).toBe(true);
    expect(dispatch(pick, 'Enter').defaultPrevented).toBe(true);
    expect(entered).toBe(2);
    // The focused control is what ownsEnter is asked about.
    expect(asked[0]).toBe(tile);
    // «Weiss ich nicht?» focused: its own click (nothing prevented, no primary action).
    const onDont = dispatch(dont, 'Enter');
    expect(onDont.defaultPrevented).toBe(false);
    expect(entered).toBe(2);
    // Nothing typed or highlighted: a focused tile clicks itself.
    owns = false;
    expect(dispatch(tile, 'Enter').defaultPrevented).toBe(false);
    expect(entered).toBe(2);
    // No control focused: the primary action; a held Enter does nothing.
    dispatch(body, 'Enter');
    expect(entered).toBe(3);
    expect(dispatch(body, 'Enter', { repeat: true }).defaultPrevented).toBe(true);
    expect(entered).toBe(3);
    off();
  });
});

test('Lernen: commands are prevented (Ctrl+R must not reload), held ones do nothing; AltGr keeps typing', () => {
  withDocument((dispatch) => {
    const body = node('body');
    const commands = [];
    const keys = [];
    const off = learnKeys.bindLearnKeys({
      ownInput: () => null,
      isLocked: () => false,
      onEnter: () => {},
      ownsEnter: () => false,
      onKey: (e, info) => keys.push([e.key, info.kind]),
      onCommand: (command) => commands.push(command),
    });
    expect(dispatch(body, 'r', { ctrlKey: true }).defaultPrevented).toBe(true);
    expect(dispatch(body, 'r', { ctrlKey: true, repeat: true }).defaultPrevented).toBe(true);
    dispatch(body, 'Enter', { altKey: true });
    expect(commands).toEqual(['speak', 'dontKnow']);
    // AltGr+E (Ctrl+Alt) types «€»: no command, a typed character.
    dispatch(body, '€', { ctrlKey: true, altKey: true });
    expect(commands).toHaveLength(2);
    expect(keys).toEqual([['€', 'char']]);
    off();
  });
});

test('Schreiben: Pinyin\'s first key in the locked field moves on and is left to the input method', () => {
  withDocument((dispatch) => {
    const input = node('input');
    const other = node('input');
    let continued = 0;
    let entered = 0;
    let can = true;
    const commands = [];
    const off = bindWriteKeys({
      ownInput: () => input,
      isLocked: () => false,
      onEnter: () => entered++,
      canContinueOnKey: () => can,
      onContinueKey: () => continued++,
      onCommand: (command) => commands.push(command),
    });
    // Not prevented: the composition then starts in the next question's (fresh) field.
    const first = dispatch(input, 'Process', { keyCode: 229 });
    expect(continued).toBe(1);
    expect(first.defaultPrevented).toBe(false);
    // Keys while composing, held keys, other fields and a question still to answer do nothing.
    dispatch(input, 'Process', { keyCode: 229, isComposing: true });
    dispatch(input, 'Process', { keyCode: 229, repeat: true });
    dispatch(other, 'Process', { keyCode: 229 });
    can = false;
    dispatch(input, 'Process', { keyCode: 229 });
    expect(continued).toBe(1);
    // Enter and Ctrl+R while composing belong to the input method.
    const confirm = dispatch(input, 'Enter', { keyCode: 229, isComposing: true });
    dispatch(input, 'r', { ctrlKey: true, keyCode: 229, isComposing: true });
    expect(entered).toBe(0);
    expect(confirm.defaultPrevented).toBe(false);
    expect(commands).toEqual([]);
    off();
  });
});

test('Lernen: Pinyin\'s first key in the answer field reaches onKey as «compose», never prevented', () => {
  withDocument((dispatch) => {
    const input = node('input');
    const body = node('body');
    const keys = [];
    const off = learnKeys.bindLearnKeys({
      ownInput: () => input,
      isLocked: () => false,
      onEnter: () => {},
      ownsEnter: () => false,
      onKey: (e, info) => keys.push([e.key, info.kind, info.own]),
      onCommand: () => {},
    });
    const first = dispatch(input, 'Process', { keyCode: 229 });
    expect(keys).toEqual([['Process', 'compose', true]]);
    expect(first.defaultPrevented).toBe(false);
    dispatch(input, 'Process', { keyCode: 229, isComposing: true });
    dispatch(body, 'Process', { keyCode: 229 });
    expect(keys).toHaveLength(1);
    // The Arabic «لا» key types on a multiple choice question.
    dispatch(body, 'لا');
    expect(keys[1]).toEqual(['لا', 'char', false]);
    off();
  });
});

test('The Enter swallow after leaving a screen leaves an input method\'s Enter alone', async () => {
  const saved = globalThis.window;
  const listeners = [];
  globalThis.window = {
    addEventListener: (type, l) => listeners.push(l),
    removeEventListener: (type, l) => {
      const i = listeners.indexOf(l);
      if (i >= 0) listeners.splice(i, 1);
    },
  };
  try {
    settleEnter(40);
    const press = (extra = {}) => {
      const e = {
        key: 'Enter',
        keyCode: 13,
        isComposing: false,
        defaultPrevented: false,
        preventDefault() {
          this.defaultPrevented = true;
        },
        stopPropagation() {},
        ...extra,
      };
      for (const l of listeners.slice()) l(e);
      return e;
    };
    expect(press({ keyCode: 229, isComposing: true }).defaultPrevented).toBe(false);
    expect(press().defaultPrevented).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(listeners).toHaveLength(0);
  } finally {
    globalThis.window = saved;
  }
});

await run('study-keys.test.js');
