// Arabic and Chinese card text in the screens (on a minimal fake DOM, jsc has none): the
// innermost element holding card text carries its language and direction (lib/labels.js
// textAttrs: rtl for Arabic, auto for «Andere», none for left-to-right languages), answer
// fields and what was typed follow their text (fieldAttrs: dir="auto"), and the editor's
// duplicate check folds what grading treats as equal.
import { test, expect, run } from './harness.js';
import { setTextAttrs } from '../src/lib/dom.js';
import { termList } from '../src/screens/write-views.js';
import { createCard } from '../src/screens/write-card.js';
import { createMcCard } from '../src/screens/learn-mc.js';
import { termKey } from '../src/screens/editor-util.js';
import { createCardList } from '../src/screens/editor-cards.js';
import { createSheet } from '../src/screens/exam-sheet.js';
import { resultsView } from '../src/screens/exam-results.js';
import { makeQuestions, evaluateExam } from '../src/core/exam.js';

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
  contains(name) {
    return this.list().includes(name);
  }
  add(...names) {
    const list = this.list();
    for (const n of names) if (!list.includes(n)) list.push(n);
    this.el.setAttribute('class', list.join(' '));
  }
  remove(...names) {
    this.el.setAttribute('class', this.list().filter((n) => !names.includes(n)).join(' '));
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
      removeProperty(name) {
        delete this[name];
      },
    };
    this.dataset = {};
    this.classList = new FakeClassList(this);
    this.hidden = false;
    this.disabled = false;
    this.value = '';
    this.offsetWidth = 0;
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
  set htmlFor(v) {
    this.setAttribute('for', v);
  }
  get spellcheck() {
    return this.getAttribute('spellcheck') !== 'false';
  }
  set spellcheck(v) {
    this.setAttribute('spellcheck', v ? 'true' : 'false');
  }
  get isConnected() {
    return false;
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
  replaceChildren(...nodes) {
    for (const n of this.childNodes) n.parentNode = null;
    this.childNodes = [];
    this.append(...nodes);
  }
  removeChild(node) {
    const i = this.childNodes.indexOf(node);
    if (i >= 0) this.childNodes.splice(i, 1);
    node.parentNode = null;
    return node;
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
  focus() {
    globalThis.document.activeElement = this;
  }
  click() {
    for (const fn of (this.listeners.click || []).slice()) fn({ type: 'click', target: this, preventDefault() {} });
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
  addEventListener() {},
  removeEventListener() {},
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (ns, tag) => new FakeElement(tag),
  createDocumentFragment: () => new FakeElement('#fragment'),
  createTextNode: (text) => new FakeText(text),
};

// The shared tooltip listens on the window once a control with a tooltip exists; jsc has
// setTimeout but no clearTimeout (the editor's duplicate check is debounced).
globalThis.window = { addEventListener() {}, removeEventListener() {} };
if (typeof globalThis.clearTimeout !== 'function') globalThis.clearTimeout = () => {};

const attrsOf = (el) => ({ lang: el.getAttribute('lang'), dir: el.getAttribute('dir') });

/* ----------------------------------------------------------------- tests */

test('setTextAttrs sets and removes lang and dir', () => {
  const el = new FakeElement('p');
  setTextAttrs(el, { lang: 'ar', dir: 'rtl' });
  expect(attrsOf(el)).toEqual({ lang: 'ar', dir: 'rtl' });
  setTextAttrs(el, { lang: 'zh-CN', dir: null });
  expect(attrsOf(el)).toEqual({ lang: 'zh-CN', dir: null });
  setTextAttrs(el, {});
  expect(attrsOf(el)).toEqual({ lang: null, dir: null });
  expect(setTextAttrs(null, { lang: 'ar' })).toBe(null);
});

test('the card list after a round: each side with its language, Arabic right to left', () => {
  const list = termList([
    { correct: true, term: 'كِتَاب', definition: 'Buch', termLang: 'ar', defLang: 'de' },
    { correct: false, term: '你好 (nǐ hǎo)', definition: 'Hallo', termLang: 'zh', defLang: 'de' },
    { correct: true, term: 'shalom', definition: 'שלום', termLang: 'en', defLang: 'other' },
  ]);
  const terms = list.querySelectorAll('.wr-item__term').map(attrsOf);
  const defs = list.querySelectorAll('.wr-item__def').map(attrsOf);
  expect(terms).toEqual([
    { lang: 'ar', dir: 'rtl' },
    { lang: 'zh-CN', dir: null },
    { lang: 'en-GB', dir: null },
  ]);
  // «Andere» (here Hebrew) has no language tag; its direction follows the text.
  expect(defs).toEqual([
    { lang: 'de-CH', dir: null },
    { lang: 'de-CH', dir: null },
    { lang: null, dir: 'auto' },
  ]);
  // The list itself stays left to right.
  expect(list.getAttribute('dir')).toBe(null);
});

const question = (extra) => ({
  promptLabel: 'Deutsch',
  prompt: 'Buch',
  promptLang: 'de',
  answerLang: 'ar',
  expected: 'كِتَاب',
  placeholder: 'Antwort auf Arabisch eingeben',
  placeholderShort: 'Auf Arabisch …',
  starred: false,
  ...extra,
});

const noop = () => {};
const handlers = { onSubmit: noop, onDontKnow: noop, onContinue: noop, onCopySubmit: noop, onOverride: noop, onEdit: noop, onToggleStar: () => false, onSpeak: noop };

test('Schreiben: prompt, answer field, «Genau:» and the correct answer carry their language', () => {
  const card = createCard(handlers);
  card.setQuestion(question({ promptLang: 'ar', prompt: 'كِتَاب', answerLang: 'de', expected: 'Buch' }), { animate: false });
  const prompt = card.el.querySelector('.wr-q__prompt');
  expect(attrsOf(prompt)).toEqual({ lang: 'ar', dir: 'rtl' });
  expect(attrsOf(card.input)).toEqual({ lang: 'de-CH', dir: 'auto' });

  // The next question: the prompt loses the Arabic direction, the field takes Arabic.
  card.setQuestion(question(), { animate: false });
  expect(attrsOf(prompt)).toEqual({ lang: 'de-CH', dir: null });
  expect(attrsOf(card.input)).toEqual({ lang: 'ar', dir: 'auto' });

  card.showCorrect({ praise: 'Richtig!', result: { exact: false, expectedDisplay: 'كِتَاب' } });
  expect(attrsOf(card.el.querySelector('.wr-answer__exact').querySelector('strong'))).toEqual({ lang: 'ar', dir: 'rtl' });

  card.setQuestion(question(), { animate: false });
  card.showIncorrect({ given: 'كتب' });
  expect(attrsOf(card.el.querySelector('.wr-fb__expected'))).toEqual({ lang: 'ar', dir: 'rtl' });
  // What was typed follows its own direction, like the field.
  const diff = card.el.querySelector('.wr-diff');
  expect(attrsOf(diff)).toEqual({ lang: 'ar', dir: 'auto' });
  // Typed without vowel marks: the marks of the answer are not shown as missing.
  expect(diff.querySelectorAll('.wr-diff__add').map((n) => n.textContent)).toEqual(['ا']);
  card.dispose();
});

test('Schreiben: a pinyin answer is compared with the pinyin of «你好 (nǐ hǎo)»', () => {
  const card = createCard(handlers);
  card.setQuestion(question({ answerLang: 'zh', expected: '你好 (nǐ hǎo)', prompt: 'Hallo' }), { animate: false });
  expect(attrsOf(card.input)).toEqual({ lang: 'zh-CN', dir: 'auto' });
  card.showIncorrect({ given: 'ni3 hao' });
  const diff = card.el.querySelector('.wr-diff');
  // A near miss gets a letter diff (not the plain «different word» line): only the tone is off.
  expect(diff.classList.contains('wr-diff--plain')).toBe(false);
  expect(attrsOf(diff)).toEqual({ lang: 'zh-CN', dir: 'auto' });
  expect(diff.querySelectorAll('.wr-diff__add').map((n) => n.textContent).join('')).toBe('ǎ');
  expect(attrsOf(card.el.querySelector('.wr-fb__expected'))).toEqual({ lang: 'zh-CN', dir: null });
  card.dispose();
});

test('Lernen multiple choice: options and prompt carry their language, typed letters their direction', () => {
  const mc = createMcCard({ onChoose: noop, onDontKnow: noop, onContinue: noop, onEdit: noop, onToggleStar: () => false, onSpeak: noop, onSurfaceClick: noop, onPick: noop });
  mc.setQuestion(question({ promptLang: 'de', prompt: 'Buch' }), [{ text: 'كِتَاب' }, { text: 'قلم' }, { text: 'بيت' }, { text: 'مدرسة' }], { animate: false });
  expect(mc.el.querySelectorAll('.ln-tile__text').map(attrsOf)).toEqual(Array(4).fill({ lang: 'ar', dir: 'rtl' }));
  expect(attrsOf(mc.el.querySelector('.wr-q__prompt'))).toEqual({ lang: 'de-CH', dir: null });
  expect(mc.el.querySelector('.ln-ta__typed').getAttribute('dir')).toBe('auto');
  mc.setQuestion(question({ promptLang: 'zh', prompt: '你好', answerLang: 'de' }), [{ text: 'Hallo' }, { text: 'Danke' }], { animate: false });
  expect(attrsOf(mc.el.querySelector('.wr-q__prompt'))).toEqual({ lang: 'zh-CN', dir: null });
  expect(mc.el.querySelectorAll('.ln-tile__text').map(attrsOf)).toEqual(Array(2).fill({ lang: 'de-CH', dir: null }));
});

test('Prüfung: answer fields, prompts and the marked answers carry their language', () => {
  const cards = [
    { id: 'a', term: 'كِتَاب', definition: 'Buch' },
    { id: 'b', term: 'قلم', definition: 'Stift' },
  ];
  const questions = makeQuestions(cards, { count: 2, answerWith: 'term' }, { termLang: 'ar', defLang: 'de', rng: () => 0 });
  const sheet = createSheet({ questions, termLang: 'ar', defLang: 'de' }, { input: noop, submit: noop });
  expect(sheet.el.querySelectorAll('.ex-q__input').map(attrsOf)).toEqual(Array(2).fill({ lang: 'ar', dir: 'auto' }));
  const prompt = sheet.el.querySelector('.ex-q__prompt').children.find((n) => n.hasAttribute('lang'));
  expect(attrsOf(prompt)).toEqual({ lang: 'de-CH', dir: null });

  const byCard = Object.fromEntries(questions.map((q) => [q.cardId, q.number]));
  const answers = { [byCard.a]: 'كتب', [byCard.b]: 'قلم' };
  const result = evaluateExam(questions, answers, cards, 'half', { elapsedMs: 60000 });
  const view = resultsView(result, { newExam: noop, learn: noop, retake: noop, done: noop });
  const root = view.el || view;
  // What was typed follows its text; the right answer is Arabic, right to left.
  expect(root.querySelectorAll('.ex-answer').map(attrsOf)).toEqual(Array(2).fill({ lang: 'ar', dir: 'auto' }));
  expect(root.querySelectorAll('.ex-expected__text').map(attrsOf)).toEqual([{ lang: 'ar', dir: 'rtl' }]);
  expect(root.querySelectorAll('.ex-item__prompt').map(attrsOf)).toEqual(Array(2).fill({ lang: 'de-CH', dir: null }));
});

test('editor rows: the language on the field and its sizing copy, spell check off for Arabic and Chinese', () => {
  const editor = createCardList({ cards: [{ term: 'كِتَاب', definition: 'Buch' }], termLang: 'ar', defLang: 'de' });
  const [termWrap, defWrap] = editor.el.querySelectorAll('.ed-grow');
  const [termField, defField] = editor.el.querySelectorAll('.ed-cell__input');
  expect(attrsOf(termWrap)).toEqual({ lang: 'ar', dir: null });
  expect(attrsOf(termField)).toEqual({ lang: 'ar', dir: 'auto' });
  expect(termField.getAttribute('spellcheck')).toBe('false');
  expect(attrsOf(defWrap)).toEqual({ lang: 'de-CH', dir: null });
  expect(attrsOf(defField)).toEqual({ lang: 'de-CH', dir: 'auto' });
  expect(defField.getAttribute('spellcheck')).toBe('true');
  // Other languages chosen later: Chinese without spell check, «Andere» without a language.
  editor.setLangs('zh', 'other');
  expect(attrsOf(termWrap)).toEqual({ lang: 'zh-CN', dir: null });
  expect(termField.getAttribute('spellcheck')).toBe('false');
  expect(attrsOf(defField)).toEqual({ lang: null, dir: 'auto' });
  expect(defField.getAttribute('spellcheck')).toBe('true');
  editor.destroy();
});

test('editor duplicate check: vowel marks, tatweel, full-width punctuation and Han spaces do not count', () => {
  expect(termKey('كِتَابٌ')).toBe(termKey('كتاب'));
  expect(termKey('كـتـاب')).toBe(termKey('كتاب'));
  expect(termKey('كيف حالك؟')).toBe(termKey('كيف حالك'));
  expect(termKey('你 好。')).toBe(termKey('你好'));
  expect(termKey('你好！')).toBe('你好');
  // Latin text as before: case and a final full stop.
  expect(termKey('Le Chat.')).toBe('le chat');
  expect(termKey('la mer') === termKey('la mère')).toBe(false);
});

await run('text-direction.test.js');
