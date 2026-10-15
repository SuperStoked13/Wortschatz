// Study options form shared by the Write and Learn options modals and the
// defaults in Settings: wording of the answer direction, the Learn helpers and
// the rendered form per mode (on a minimal fake DOM, jsc has none).
import { test, expect, run } from './harness.js';
import {
  directionText,
  studyOptionsForm,
  studyOptionsLayout,
  learnOptions,
  questionTypeLock,
  questionTypesHint,
  roundSizeChoices,
  ROUND_SIZES,
  STUDY_OPTION_MODES,
  REVIEW_OPTION,
  learnReviewEnabled,
  setLearnReviewEnabled,
} from '../src/ui/study-options.js';
import { DEFAULT_STUDY_OPTIONS } from '../src/store/db.js';
import { DEFAULT_LEARN } from '../src/core/learn.js';
import { getPref, setPref, PREF } from '../src/lib/prefs.js';

/* ------------------------------------------------------------- fake DOM */

class FakeText {
  constructor(text) {
    this.nodeType = 3;
    this.data = String(text);
    this.parentNode = null;
  }
  get textContent() {
    return this.data;
  }
  set textContent(v) {
    this.data = String(v);
  }
}

class FakeClassList {
  constructor(el) {
    this.el = el;
  }
  list() {
    return (this.el.getAttribute('class') || '').split(/\s+/).filter(Boolean);
  }
  write(list) {
    this.el.setAttribute('class', list.join(' '));
  }
  contains(name) {
    return this.list().includes(name);
  }
  add(...names) {
    const list = this.list();
    for (const n of names) if (!list.includes(n)) list.push(n);
    this.write(list);
  }
  remove(...names) {
    this.write(this.list().filter((n) => !names.includes(n)));
  }
  toggle(name, force) {
    const on = force === undefined ? !this.contains(name) : !!force;
    if (on) this.add(name);
    else this.remove(name);
    return on;
  }
}

class FakeElement {
  constructor(tag) {
    this.nodeType = 1;
    this.localName = String(tag).toLowerCase();
    this.tagName = this.localName.toUpperCase();
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = new Map();
    this.listeners = {};
    this.style = {
      setProperty(name, value) {
        this[name] = value;
      },
    };
    this.dataset = {};
    this.classList = new FakeClassList(this);
    this.checked = false;
    this.disabled = false;
    this.hidden = false;
    this.value = '';
    this.tabIndex = -1;
    this.offsetWidth = 0;
    this.offsetHeight = 0;
    this.offsetLeft = 0;
    this.offsetTop = 0;
  }
  get className() {
    return this.getAttribute('class') || '';
  }
  set className(v) {
    this.setAttribute('class', v);
  }
  get id() {
    return this.getAttribute('id') || '';
  }
  set id(v) {
    this.setAttribute('id', v);
  }
  get htmlFor() {
    return this.getAttribute('for') || '';
  }
  set htmlFor(v) {
    this.setAttribute('for', v);
  }
  setAttribute(name, value) {
    this.attrs.set(name, String(value));
  }
  getAttribute(name) {
    return this.attrs.has(name) ? this.attrs.get(name) : null;
  }
  hasAttribute(name) {
    return this.attrs.has(name);
  }
  removeAttribute(name) {
    this.attrs.delete(name);
  }
  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.childNodes.push(node);
    return node;
  }
  append(...nodes) {
    for (const n of nodes) this.appendChild(typeof n === 'string' ? new FakeText(n) : n);
  }
  removeChild(node) {
    const i = this.childNodes.indexOf(node);
    if (i >= 0) this.childNodes.splice(i, 1);
    node.parentNode = null;
    return node;
  }
  replaceWith(node) {
    const parent = this.parentNode;
    if (!parent) return;
    if (node.parentNode) node.parentNode.removeChild(node);
    parent.childNodes[parent.childNodes.indexOf(this)] = node;
    node.parentNode = parent;
    this.parentNode = null;
  }
  get children() {
    return this.childNodes.filter((n) => n.nodeType === 1);
  }
  get firstChild() {
    return this.childNodes[0] || null;
  }
  get textContent() {
    return this.childNodes.map((n) => n.textContent).join('');
  }
  set textContent(v) {
    for (const n of this.childNodes) n.parentNode = null;
    this.childNodes = v == null || v === '' ? [] : [new FakeText(v)];
  }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn);
  }
  dispatchEvent(event) {
    const e = { target: this, preventDefault() {}, ...event, currentTarget: this };
    for (const fn of (this.listeners[e.type] || []).slice()) fn(e);
    return true;
  }
  focus() {
    globalThis.document.activeElement = this;
  }
  // Simple selectors only: tag, .class, [attr] and [attr="value"], combined.
  matches(selector) {
    const re = /([a-z0-9-]+)|\.([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\]/gi;
    let m;
    while ((m = re.exec(selector))) {
      if (m[1] && m.index === 0 && this.localName !== m[1].toLowerCase()) return false;
      if (m[2] && !this.classList.contains(m[2])) return false;
      if (m[3] && (!this.hasAttribute(m[3]) || (m[4] !== undefined && this.getAttribute(m[3]) !== m[4]))) return false;
    }
    return true;
  }
  querySelectorAll(selector) {
    const out = [];
    const walk = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
}

globalThis.document = {
  activeElement: null,
  createElement: (tag) => new FakeElement(tag),
  createTextNode: (text) => new FakeText(text),
};

/* -------------------------------------------------------------- helpers */

const full = (patch = {}) => {
  const o = JSON.parse(JSON.stringify(DEFAULT_STUDY_OPTIONS));
  return { ...o, ...patch, tolerance: { ...o.tolerance, ...(patch.tolerance || {}) }, learn: { ...o.learn, ...(patch.learn || {}) } };
};

function render(props = {}) {
  const patches = [];
  const form = studyOptionsForm({ options: full(), onChange: (p) => patches.push(p), ...props });
  return { form, patches };
}

const titles = (form) => form.querySelectorAll('.ui-so__title').map((n) => n.textContent);
const toggleLabels = (form) => form.querySelectorAll('.ui-toggle__label').map((n) => n.textContent);
const togglesNamed = (form, label) => form.querySelectorAll('.ui-toggle').filter((t) => t.querySelector('.ui-toggle__label').textContent === label);
const toggleNamed = (form, label) => {
  const found = togglesNamed(form, label);
  if (found.length !== 1) throw new Error(`expected one toggle "${label}", found ${found.length}`);
  return found[0];
};
const inputOf = (t) => t.querySelector('input');
function flip(t, checked) {
  const input = inputOf(t);
  input.checked = checked;
  input.dispatchEvent({ type: 'change' });
}
const segNamed = (form, ariaLabel) => form.querySelector(`.ui-seg[aria-label="${ariaLabel}"]`);
const segLabels = (seg) => seg.querySelectorAll('.ui-seg__btn').map((b) => b.textContent);
const segSelected = (seg) => seg.querySelectorAll('.ui-seg__btn').filter((b) => b.getAttribute('aria-checked') === 'true').map((b) => b.textContent);
function pick(seg, label) {
  const btn = seg.querySelectorAll('.ui-seg__btn').find((b) => b.textContent === label);
  btn.dispatchEvent({ type: 'click' });
}
const sectionKeys = (form) => form.querySelectorAll('.ui-so__section').map((s) => s.dataset.section);

// All visible text and attribute values of a subtree.
function allText(node) {
  if (node.nodeType === 3) return node.data;
  return [...node.attrs.values(), ...node.childNodes.map(allText)].join(' ');
}

const TOLERANCE_LABELS = [
  'Artikel/Pronomen vergessen erlaubt',
  'Abkürzungen gleichwertig',
  'Eine von mehreren Antworten genügt',
  'Klammerinhalt optional',
  'Gross-/Kleinschreibung ignorieren',
  'Akzente ignorieren',
  'Kleine Tippfehler erlauben',
];

/* -------------------------------------------------------- directionText */

test('directionText names both languages of a set', () => {
  expect(directionText('term', 'fr', 'de')).toBe('Du siehst Deutsch und schreibst Französisch.');
  expect(directionText('definition', 'fr', 'de')).toBe('Du siehst Französisch und schreibst Deutsch.');
  expect(directionText('term', 'en', 'de')).toBe('Du siehst Deutsch und schreibst Englisch.');
  expect(directionText('both', 'fr', 'de')).toBe('Jede Karte wird in beide Richtungen abgefragt.');
});

test('directionText stays generic when the learned language is unknown (Settings defaults apply to every set)', () => {
  expect(directionText('term', null, 'de')).toBe('Du siehst Deutsch und schreibst in der Lernsprache.');
  expect(directionText('definition', null, 'de')).toBe('Du siehst den Begriff in der Lernsprache und schreibst Deutsch.');
  expect(directionText('term', null, null)).toBe('Du siehst die Übersetzung und schreibst in der Lernsprache.');
  expect(directionText('term', 'other', 'de')).toBe('Du siehst Deutsch und schreibst in der Lernsprache.');
  for (const text of [directionText('term', null, null), directionText('definition', 'other', 'other')]) {
    expect(text.includes('Französisch')).toBe(false);
  }
});

test('directionText falls back to Begriff/Definition when both sides share a language', () => {
  expect(directionText('term', 'de', 'de')).toBe('Du siehst die Definition und schreibst den Begriff.');
  expect(directionText('definition', 'de', 'de')).toBe('Du siehst den Begriff und schreibst die Definition.');
});

test('directionText treats a missing direction as the default (answer with the term)', () => {
  expect(directionText(undefined, 'es', 'de')).toBe('Du siehst Deutsch und schreibst Spanisch.');
});

test('directionText in Learn mode: answers are chosen or typed, "both" alternates per question', () => {
  expect(directionText('term', 'fr', 'de', 'learn')).toBe('Du siehst Deutsch und antwortest auf Französisch.');
  expect(directionText('definition', 'fr', 'de', 'learn')).toBe('Du siehst Französisch und antwortest auf Deutsch.');
  expect(directionText('term', null, 'de', 'learn')).toBe('Du siehst Deutsch und antwortest in der Lernsprache.');
  expect(directionText('definition', null, null, 'learn')).toBe('Du siehst den Begriff in der Lernsprache und antwortest mit der Übersetzung.');
  expect(directionText('term', 'de', 'de', 'learn')).toBe('Du siehst die Definition und antwortest mit dem Begriff.');
  expect(directionText('definition', 'de', 'de', 'learn')).toBe('Du siehst den Begriff und antwortest mit der Definition.');
  expect(directionText('both', 'fr', 'de', 'learn')).toBe('Die Richtung wechselt zufällig von Frage zu Frage.');
});

test('directionText for Settings ("all") covers both modes; unknown modes mean Write', () => {
  expect(directionText('term', null, 'de', 'all')).toBe('Du siehst Deutsch und antwortest in der Lernsprache.');
  expect(directionText('both', null, 'de', 'all')).toBe('Schreiben fragt jede Karte in beide Richtungen ab, Lernen wechselt die Richtung zufällig.');
  expect(directionText('term', 'fr', 'de', 'quiz')).toBe(directionText('term', 'fr', 'de'));
});

/* -------------------------------------------------------- Learn helpers */

test('learnOptions completes and repairs Learn options like the engine', () => {
  expect(learnOptions(undefined)).toEqual(DEFAULT_LEARN);
  expect(learnOptions('x')).toEqual(DEFAULT_LEARN);
  expect(learnOptions({ roundSize: 10, mc: false })).toEqual({ roundSize: 10, mc: false, written: true, retype: false });
  expect(learnOptions({ mc: false, written: false, retype: true })).toEqual({ roundSize: 7, mc: true, written: true, retype: true });
  expect(learnOptions({ roundSize: 0 }).roundSize).toBe(7);
  expect(learnOptions({ roundSize: 7.5 }).roundSize).toBe(7);
  expect(learnOptions({ roundSize: '10' }).roundSize).toBe(7);
  expect(learnOptions({ mc: 'no' }).mc).toBe(true);
});

test('questionTypeLock names the only enabled question type', () => {
  expect(questionTypeLock({ mc: true, written: true })).toBe(null);
  expect(questionTypeLock({ mc: true, written: false })).toBe('mc');
  expect(questionTypeLock({ mc: false, written: true })).toBe('written');
  expect(questionTypeLock({ mc: false, written: false })).toBe(null); // repaired to both on
  expect(questionTypeLock(undefined)).toBe(null);
});

test('questionTypesHint explains the flow and the lock', () => {
  expect(questionTypesHint({ mc: true, written: true })).toBe('Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst.');
  expect(questionTypesHint({ mc: true, written: false })).toBe('Alle Fragen kommen als Multiple Choice. Mindestens ein Fragetyp bleibt aktiv.');
  expect(questionTypesHint({ mc: false, written: true })).toBe('Alle Fragen beantwortest du schriftlich. Mindestens ein Fragetyp bleibt aktiv.');
});

test('roundSizeChoices offers 5 | 7 | 10 | 15 and keeps a stored other size selectable', () => {
  expect(ROUND_SIZES).toEqual([5, 7, 10, 15]);
  expect(Object.isFrozen(ROUND_SIZES)).toBe(true);
  expect(roundSizeChoices(7)).toEqual([5, 7, 10, 15]);
  expect(roundSizeChoices(8)).toEqual([5, 7, 8, 10, 15]);
  expect(roundSizeChoices(30)).toEqual([5, 7, 10, 15, 30]);
  for (const junk of [undefined, 0, -1, 7.5, '8']) expect(roundSizeChoices(junk)).toEqual([5, 7, 10, 15]);
});

test('studyOptionsLayout: sections and controls per mode', () => {
  expect(STUDY_OPTION_MODES).toEqual(['write', 'learn', 'all']);
  const shape = (mode) => studyOptionsLayout(mode).map((s) => [s.title, s.controls]);
  expect(shape('write')).toEqual([
    ['Abfrage', ['answerWith', 'shuffle', 'copyAnswer', 'autoAdvance', 'audio']],
    ['Toleranz', ['tolerance']],
  ]);
  expect(shape('learn')).toEqual([
    ['Abfrage', ['answerWith', 'questionTypes', 'roundSize', 'learn.retype', 'audio']],
    ['Wiederholung', ['review']],
    ['Toleranz', ['tolerance']],
  ]);
  expect(shape('all')).toEqual([
    ['Abfrage', ['answerWith', 'audio']],
    ['Lernen', ['questionTypes', 'roundSize', 'learn.retype']],
    ['Schreiben', ['shuffle', 'copyAnswer', 'autoAdvance']],
    ['Toleranz', ['tolerance']],
  ]);
  expect(shape(undefined)).toEqual(shape('write'));
  expect(shape('nonsense')).toEqual(shape('write'));
  // Callers get copies.
  studyOptionsLayout('learn')[0].controls.push('shuffle');
  expect(shape('learn')[0][1]).toEqual(['answerWith', 'questionTypes', 'roundSize', 'learn.retype', 'audio']);
});

/* ------------------------------------------------------- rendered forms */

test('Write mode (default) renders the Write options exactly as before', () => {
  const { form, patches } = render({ termLang: 'fr', defLang: 'de' });
  expect(form.classList.contains('ui-so')).toBe(true);
  expect(titles(form)).toEqual(['Abfrage', 'Toleranz']);
  expect(toggleLabels(form)).toEqual(['Mischen', 'Richtige Antwort abtippen', 'Automatisch weiter', 'Vorlesen', ...TOLERANCE_LABELS]);
  expect(segNamed(form, 'Begriffe pro Runde')).toBe(null);
  expect(form.textContent.includes('Fragetypen')).toBe(false);
  const dir = segNamed(form, 'Antworten auf');
  expect(segLabels(dir)).toEqual(['Französisch', 'Deutsch', 'Beides']);
  expect(segSelected(dir)).toEqual(['Französisch']);
  expect(form.textContent).toContain('Du siehst Deutsch und schreibst Französisch.');

  flip(toggleNamed(form, 'Mischen'), false);
  flip(toggleNamed(form, 'Richtige Antwort abtippen'), false);
  flip(toggleNamed(form, 'Kleine Tippfehler erlauben'), true);
  pick(dir, 'Beides');
  expect(patches).toEqual([{ shuffle: false }, { copyAnswer: false }, { tolerance: { typos: true } }, { answerWith: 'both' }]);
  expect(form.textContent).toContain('Jede Karte wird in beide Richtungen abgefragt.');
});

test('Learn mode shows question types, terms per round and its own retype switch', () => {
  const { form, patches } = render({ termLang: 'fr', defLang: 'de', mode: 'learn', compact: true });
  expect(form.classList.contains('ui-so--compact')).toBe(true);
  expect(titles(form)).toEqual(['Abfrage', 'Wiederholung', 'Toleranz']);
  expect(toggleLabels(form)).toEqual(['Multiple Choice', 'Schriftlich', 'Richtige Antwort abtippen', 'Vorlesen', 'Wiederholungsfragen', ...TOLERANCE_LABELS]);
  // Write-only switches are hidden: Learn always shuffles and auto-advances.
  for (const label of ['Mischen', 'Automatisch weiter']) expect(togglesNamed(form, label)).toHaveLength(0);
  expect(form.textContent).toContain('Fragetypen');
  expect(form.textContent).toContain('Du siehst Deutsch und antwortest auf Französisch.');

  const rounds = segNamed(form, 'Begriffe pro Runde');
  expect(segLabels(rounds)).toEqual(['5', '7', '10', '15']);
  expect(segSelected(rounds)).toEqual(['7']);
  pick(rounds, '10');
  expect(segSelected(rounds)).toEqual(['10']);

  // "Richtige Antwort abtippen" is learn.retype here (default off), not copyAnswer.
  const retype = toggleNamed(form, 'Richtige Antwort abtippen');
  expect(inputOf(retype).checked).toBe(false);
  flip(retype, true);
  flip(toggleNamed(form, 'Akzente ignorieren'), true);
  pick(segNamed(form, 'Antworten auf'), 'Beides');
  expect(patches).toEqual([{ learn: { roundSize: 10 } }, { learn: { retype: true } }, { tolerance: { ignoreAccents: true } }, { answerWith: 'both' }]);
  expect(form.textContent).toContain('Die Richtung wechselt zufällig von Frage zu Frage.');
});

test('Learn mode never lets both question types be switched off', () => {
  const { form, patches } = render({ mode: 'learn' });
  const mc = toggleNamed(form, 'Multiple Choice');
  const written = toggleNamed(form, 'Schriftlich');
  expect([inputOf(mc).checked, inputOf(written).checked]).toEqual([true, true]);
  expect([inputOf(mc).disabled, inputOf(written).disabled]).toEqual([false, false]);
  expect(form.textContent).toContain('Neue Begriffe kommen zuerst als Multiple Choice');

  // Multiple choice off: written is now the last one and gets locked with a hint.
  flip(mc, false);
  expect(patches).toEqual([{ learn: { mc: false } }]);
  expect(inputOf(written).disabled).toBe(true);
  expect(written.classList.contains('is-disabled')).toBe(true);
  expect(written.getAttribute('title')).toBe('Mindestens ein Fragetyp bleibt aktiv.');
  expect(form.textContent).toContain('Alle Fragen beantwortest du schriftlich. Mindestens ein Fragetyp bleibt aktiv.');

  // A change event on the locked switch (e.g. a stale click) changes nothing.
  flip(written, false);
  expect(inputOf(written).checked).toBe(true);
  expect(patches).toHaveLength(1);

  // Back on: both unlocked again.
  flip(mc, true);
  expect(patches[1]).toEqual({ learn: { mc: true } });
  expect([inputOf(mc).disabled, inputOf(written).disabled]).toEqual([false, false]);
  expect(written.hasAttribute('title')).toBe(false);

  // The hint is announced and describes both switches.
  const hint = form.querySelector('[aria-live="polite"]');
  expect(hint.textContent).toBe(questionTypesHint({ mc: true, written: true }));
  for (const t of [mc, written]) expect(inputOf(t).getAttribute('aria-describedby').split(' ')).toContain(hint.id);
});

test('Learn mode starts locked when only one question type is stored', () => {
  const { form } = render({ mode: 'learn', options: full({ learn: { mc: true, written: false } }) });
  expect(inputOf(toggleNamed(form, 'Multiple Choice')).disabled).toBe(true);
  expect(inputOf(toggleNamed(form, 'Schriftlich')).checked).toBe(false);
  expect(inputOf(toggleNamed(form, 'Schriftlich')).disabled).toBe(false);
  // Corrupt "both off" input shows both on, like the engine treats it.
  const repaired = render({ mode: 'learn', options: full({ learn: { mc: false, written: false } }) }).form;
  expect(inputOf(toggleNamed(repaired, 'Multiple Choice')).checked).toBe(true);
  expect(inputOf(toggleNamed(repaired, 'Schriftlich')).checked).toBe(true);
});

test('Settings ("all") shows Write and Learn options in titled sections', () => {
  const { form, patches } = render({ termLang: null, defLang: 'de', mode: 'all' });
  expect(titles(form)).toEqual(['Abfrage', 'Lernen', 'Schreiben', 'Toleranz']);
  expect(sectionKeys(form)).toEqual(['query', 'learn', 'write', 'tolerance']);
  expect(toggleLabels(form)).toEqual([
    'Vorlesen',
    'Multiple Choice',
    'Schriftlich',
    'Richtige Antwort abtippen',
    'Mischen',
    'Richtige Antwort abtippen',
    'Automatisch weiter',
    ...TOLERANCE_LABELS,
  ]);
  expect(segLabels(segNamed(form, 'Antworten auf'))).toEqual(['Lernsprache', 'Deutsch', 'Beides']);
  expect(segLabels(segNamed(form, 'Begriffe pro Runde'))).toEqual(['5', '7', '10', '15']);

  // The two retype switches are bound to different options and named apart.
  const [learnRetype, writeCopy] = togglesNamed(form, 'Richtige Antwort abtippen');
  expect(inputOf(learnRetype).getAttribute('aria-label')).toBe('Richtige Antwort abtippen (Lernen)');
  expect(inputOf(writeCopy).getAttribute('aria-label')).toBe('Richtige Antwort abtippen (Schreiben)');
  expect([inputOf(learnRetype).checked, inputOf(writeCopy).checked]).toEqual([false, true]);
  flip(learnRetype, true);
  flip(writeCopy, false);
  flip(toggleNamed(form, 'Schriftlich'), false);
  pick(segNamed(form, 'Begriffe pro Runde'), '15');
  flip(toggleNamed(form, 'Mischen'), false);
  expect(patches).toEqual([{ learn: { retype: true } }, { copyAnswer: false }, { learn: { written: false } }, { learn: { roundSize: 15 } }, { shuffle: false }]);
  expect(inputOf(toggleNamed(form, 'Multiple Choice')).disabled).toBe(true);
});

test('unknown modes render the Write form', () => {
  const { form } = render({ mode: 'test' });
  expect(titles(form)).toEqual(['Abfrage', 'Toleranz']);
  expect(togglesNamed(form, 'Mischen')).toHaveLength(1);
  expect(togglesNamed(form, 'Multiple Choice')).toHaveLength(0);
});

test('Vorlesen is disabled with a note when the device cannot speak', () => {
  for (const mode of STUDY_OPTION_MODES) {
    const t = toggleNamed(render({ mode }).form, 'Vorlesen');
    expect(inputOf(t).disabled).toBe(true);
    expect(t.textContent).toContain('Auf diesem Gerät nicht verfügbar.');
  }
});

test('Learn mode: "Wiederholungsfragen" is an app preference for every set, not a study option', () => {
  setPref(PREF.learnReview, null);
  expect(learnReviewEnabled()).toBe(false); // off by default
  const { form, patches } = render({ mode: 'learn' });
  const section = form.querySelectorAll('.ui-so__section').find((n) => n.dataset.section === 'review');
  expect(section.querySelector('.ui-so__title').textContent).toBe('Wiederholung');
  const t = toggleNamed(form, 'Wiederholungsfragen');
  expect(t.textContent).toContain(
    'Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen.',
  );
  const footer = section.querySelector('.ui-so__footer');
  expect(footer.textContent).toBe('Gilt für alle Lernsets.');
  expect(inputOf(t).getAttribute('aria-describedby').split(' ')).toContain(footer.id);
  expect(inputOf(t).checked).toBe(false);

  // Switching writes the preference at once and reports no study option.
  flip(t, true);
  expect(getPref(PREF.learnReview)).toBe(true);
  expect(learnReviewEnabled()).toBe(true);
  expect(patches).toEqual([]);
  // A new form (another set) shows it on; update() re-reads it.
  const other = render({ mode: 'learn', termLang: 'en' }).form;
  expect(inputOf(toggleNamed(other, 'Wiederholungsfragen')).checked).toBe(true);
  setLearnReviewEnabled(false);
  expect(getPref(PREF.learnReview)).toBe(false);
  other.update(full());
  expect(inputOf(toggleNamed(other, 'Wiederholungsfragen')).checked).toBe(false);
  // Write mode and Settings do not show it.
  for (const mode of ['write', 'all']) expect(togglesNamed(render({ mode }).form, 'Wiederholungsfragen')).toHaveLength(0);
  expect(REVIEW_OPTION.footer).toBe('Gilt für alle Lernsets.');
  setPref(PREF.learnReview, null);
});

test('update() refreshes every control without emitting changes', () => {
  const { form, patches } = render({ mode: 'all' });
  form.update(
    full({
      answerWith: 'definition',
      shuffle: false,
      copyAnswer: false,
      tolerance: { typos: true },
      learn: { roundSize: 15, mc: false, written: true, retype: true },
    }),
  );
  expect(patches).toEqual([]);
  expect(segSelected(segNamed(form, 'Antworten auf'))).toEqual(['Deutsch']);
  expect(segSelected(segNamed(form, 'Begriffe pro Runde'))).toEqual(['15']);
  expect(inputOf(toggleNamed(form, 'Mischen')).checked).toBe(false);
  expect(inputOf(toggleNamed(form, 'Kleine Tippfehler erlauben')).checked).toBe(true);
  const [learnRetype, writeCopy] = togglesNamed(form, 'Richtige Antwort abtippen');
  expect([inputOf(learnRetype).checked, inputOf(writeCopy).checked]).toEqual([true, false]);
  expect(inputOf(toggleNamed(form, 'Multiple Choice')).checked).toBe(false);
  expect(inputOf(toggleNamed(form, 'Schriftlich')).disabled).toBe(true);

  // A stored size outside the presets gets its own segment.
  form.update(full({ learn: { roundSize: 8 } }));
  const rounds = segNamed(form, 'Begriffe pro Runde');
  expect(segLabels(rounds)).toEqual(['5', '7', '8', '10', '15']);
  expect(segSelected(rounds)).toEqual(['8']);
  expect(form.querySelectorAll('.ui-seg[aria-label="Begriffe pro Runde"]')).toHaveLength(1);
  expect(inputOf(toggleNamed(form, 'Schriftlich')).disabled).toBe(false);
  // The rebuilt control still reports changes.
  pick(rounds, '10');
  expect(patches).toEqual([{ learn: { roundSize: 10 } }]);
});

test('form copy uses Swiss spelling in every mode', () => {
  for (const mode of STUDY_OPTION_MODES) {
    for (const [termLang, defLang] of [
      ['fr', 'de'],
      [null, 'de'],
      ['de', 'de'],
    ]) {
      const form = studyOptionsForm({ options: full(), termLang, defLang, mode });
      expect(allText(form).includes('ß')).toBe(false);
    }
  }
});

test('«Akzente ignorieren» shows missing tones for Chinese; Arabic vowel marks are no example', () => {
  const example = (termLang) => {
    const toggle = toggleNamed(render({ termLang, defLang: 'de' }).form, 'Akzente ignorieren');
    return toggle.querySelector('.ui-toggle__desc').textContent;
  };
  expect(example('zh')).toBe('«ni hao» = «nǐ hǎo», «ahnlich» = «ähnlich»');
  expect(example('ar')).toBe('«ahnlich» = «ähnlich»');
  expect(example('fr')).toBe('«ecole» = «école», «ahnlich» = «ähnlich»');
  // Both languages are named in the sentences of the form.
  expect(directionText('definition', 'ar', 'de')).toBe('Du siehst Arabisch und schreibst Deutsch.');
  expect(directionText('term', 'zh', 'de', 'learn')).toBe('Du siehst Deutsch und antwortest auf Chinesisch.');
});

await run();
