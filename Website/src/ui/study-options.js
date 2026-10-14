// Shared study options form: the Write and Learn options modals and the
// defaults in Settings.
//
// mode 'write' (default) shows the Write-mode options, 'learn' the Learn-mode
// options (question types, terms per round; Learn always shuffles and has its
// own retype switch) and 'all' (Settings) both, in titled sections. Changes are
// reported as deep partial StudyOptions, e.g. { learn: { roundSize: 10 } }.
// Learn mode also shows "Wiederholungsfragen", an app preference for every set
// (PREF.learnReview, like the Mac's UserDefaults): it is written directly, never
// reported as a study option.

import { h } from '../lib/dom.js';
import { LANGS, langName } from '../lib/labels.js';
import { getPref, setPref, PREF } from '../lib/prefs.js';
import { canSpeak } from '../lib/speech.js';
import { DEFAULT_LEARN } from '../core/learn.js';
import { segmented, toggle } from './components.js';

export const STUDY_OPTION_MODES = Object.freeze(['write', 'learn', 'all']);

// "Begriffe pro Runde" choices in Learn mode.
export const ROUND_SIZES = Object.freeze([5, 7, 10, 15]);

// "Wiederholungsfragen" (Learn options, section "Wiederholung"): mastered cards are
// asked again now and then; off by default, the same for every set.
export const REVIEW_OPTION = Object.freeze({
  title: 'Wiederholung',
  label: 'Wiederholungsfragen',
  description: 'Gemeisterte Begriffe kommen zwischendurch nochmals dran. Ist eine Antwort falsch, ist der Begriff wieder am Lernen.',
  footer: 'Gilt für alle Lernsets.',
});

export function learnReviewEnabled() {
  return getPref(PREF.learnReview, false) === true;
}

export function setLearnReviewEnabled(on) {
  setPref(PREF.learnReview, on === true);
}

const ARTICLE_EXAMPLES = {
  fr: '«homme» für «l\'homme»',
  en: '«house» für «the house»',
  es: '«casa» für «la casa»',
  it: '«casa» für «la casa»',
  de: '«Herr» für «der Herr»',
};

const ABBREVIATION_EXAMPLES = {
  fr: '«etw.» = «etwas», «qc» = «quelque chose»',
  en: '«etw.» = «etwas», «sth» = «something»',
};

const ACCENT_EXAMPLES = {
  fr: '«ecole» = «école», «ahnlich» = «ähnlich»',
  es: '«arbol» = «árbol», «ahnlich» = «ähnlich»',
  it: '«citta» = «città», «ahnlich» = «ähnlich»',
};

function toleranceItems(termLang) {
  return [
    {
      key: 'articles',
      label: 'Artikel/Pronomen vergessen erlaubt',
      example: `${ARTICLE_EXAMPLES[termLang] || ARTICLE_EXAMPLES.de} – ein falscher Artikel bleibt falsch`,
    },
    {
      key: 'abbreviations',
      label: 'Abkürzungen gleichwertig',
      example: ABBREVIATION_EXAMPLES[termLang] || '«etw.» = «etwas», «jdn.» = «jemanden»',
    },
    { key: 'multipleAnswers', label: 'Eine von mehreren Antworten genügt', example: '«lieb» reicht bei «lieb, nett»' },
    { key: 'parentheses', label: 'Klammerinhalt optional', example: '«freuen» für «(sich) freuen»' },
    { key: 'ignoreCase', label: 'Gross-/Kleinschreibung ignorieren', example: '«herr» = «Herr»' },
    { key: 'ignoreAccents', label: 'Akzente ignorieren', example: ACCENT_EXAMPLES[termLang] || '«ahnlich» = «ähnlich»' },
    { key: 'typos', label: 'Kleine Tippfehler erlauben', example: '«Mädhcen» statt «Mädchen» – ein Buchstabe daneben' },
  ];
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isNamedLang = (code) => code !== 'other' && Object.prototype.hasOwnProperty.call(LANGS, code);
const normalizeMode = (mode) => (STUDY_OPTION_MODES.includes(mode) ? mode : 'write');

// How the two sides of a set are called: by language where known, generic
// otherwise (null/'other', e.g. the defaults in Settings that apply to every
// set), and Begriff/Definition when both sides share one language.
// `seen`/`written`/`answered` complete "Du siehst … und schreibst / antwortest …".
export function sideNames(termLang, defLang) {
  if (isNamedLang(termLang) && termLang === defLang) {
    return {
      term: { label: 'Begriff', seen: 'den Begriff', written: 'den Begriff', answered: 'mit dem Begriff' },
      definition: { label: 'Definition', seen: 'die Definition', written: 'die Definition', answered: 'mit der Definition' },
    };
  }
  const named = (code) => ({ label: langName(code), seen: langName(code), written: langName(code), answered: `auf ${langName(code)}` });
  return {
    term: isNamedLang(termLang)
      ? named(termLang)
      : { label: 'Lernsprache', seen: 'den Begriff in der Lernsprache', written: 'in der Lernsprache', answered: 'in der Lernsprache' },
    definition: isNamedLang(defLang)
      ? named(defLang)
      : { label: 'Übersetzung', seen: 'die Übersetzung', written: 'die Übersetzung', answered: 'mit der Übersetzung' },
  };
}

// 'both' means two questions per card in Write mode, but a random direction per
// question in Learn mode.
const BOTH_TEXT = {
  write: 'Jede Karte wird in beide Richtungen abgefragt.',
  learn: 'Die Richtung wechselt zufällig von Frage zu Frage.',
  all: 'Schreiben fragt jede Karte in beide Richtungen ab, Lernen wechselt die Richtung zufällig.',
};

// One sentence describing what the learner sees and answers for an answerWith
// value, e.g. 'Du siehst Deutsch und schreibst Französisch.' (Write mode) or
// 'Du siehst Deutsch und antwortest auf Französisch.' (Learn mode and 'all',
// where multiple choice questions are answered without typing).
export function directionText(answerWith, termLang, defLang, mode = 'write') {
  const m = normalizeMode(mode);
  if (answerWith === 'both') return BOTH_TEXT[m];
  const names = sideNames(termLang, defLang);
  const [shown, typed] = answerWith === 'definition' ? [names.term, names.definition] : [names.definition, names.term];
  if (m === 'write') return `Du siehst ${shown.seen} und schreibst ${typed.written}.`;
  return `Du siehst ${shown.seen} und antwortest ${typed.answered}.`;
}

// Complete, valid Learn options (both question types off falls back to both on,
// like the Learn engine does).
export function learnOptions(learn) {
  const src = isObj(learn) ? learn : {};
  const roundSize = Number.isInteger(src.roundSize) && src.roundSize >= 1 ? src.roundSize : DEFAULT_LEARN.roundSize;
  let mc = typeof src.mc === 'boolean' ? src.mc : DEFAULT_LEARN.mc;
  let written = typeof src.written === 'boolean' ? src.written : DEFAULT_LEARN.written;
  if (!mc && !written) {
    mc = DEFAULT_LEARN.mc;
    written = DEFAULT_LEARN.written;
  }
  const retype = typeof src.retype === 'boolean' ? src.retype : DEFAULT_LEARN.retype;
  return { roundSize, mc, written, retype };
}

// The question type that cannot be switched off because it is the only one on.
export function questionTypeLock(learn) {
  const { mc, written } = learnOptions(learn);
  if (mc && !written) return 'mc';
  if (written && !mc) return 'written';
  return null;
}

const LOCK_HINT = 'Mindestens ein Fragetyp bleibt aktiv.';

export function questionTypesHint(learn) {
  const { mc, written } = learnOptions(learn);
  if (mc && written) return 'Neue Begriffe kommen zuerst als Multiple Choice, danach schreibst du sie selbst.';
  if (mc) return `Alle Fragen kommen als Multiple Choice. ${LOCK_HINT}`;
  return `Alle Fragen beantwortest du schriftlich. ${LOCK_HINT}`;
}

// The round sizes to offer; a stored size outside ROUND_SIZES stays selectable.
export function roundSizeChoices(current) {
  const list = ROUND_SIZES.slice();
  if (Number.isInteger(current) && current >= 1 && !list.includes(current)) {
    list.push(current);
    list.sort((a, b) => a - b);
  }
  return list;
}

// Sections and controls per mode. Control ids: 'answerWith', 'questionTypes',
// 'roundSize', 'review', 'tolerance' and the toggle paths in TOGGLES.
// 'review' is the "Wiederholungsfragen" preference; a section's `footer` is shown below it.
const TOLERANCE_SECTION = { key: 'tolerance', title: 'Toleranz', note: 'Was trotzdem als richtig zählt', controls: ['tolerance'] };
const REVIEW_SECTION = { key: 'review', title: REVIEW_OPTION.title, note: null, controls: ['review'], footer: REVIEW_OPTION.footer };
const LAYOUTS = {
  write: [{ key: 'query', title: 'Abfrage', note: null, controls: ['answerWith', 'shuffle', 'copyAnswer', 'autoAdvance', 'audio'] }, TOLERANCE_SECTION],
  learn: [
    { key: 'query', title: 'Abfrage', note: null, controls: ['answerWith', 'questionTypes', 'roundSize', 'learn.retype', 'audio'] },
    REVIEW_SECTION,
    TOLERANCE_SECTION,
  ],
  all: [
    { key: 'query', title: 'Abfrage', note: 'Für Lernen und Schreiben', controls: ['answerWith', 'audio'] },
    { key: 'learn', title: 'Lernen', note: 'Multiple Choice, dann schriftlich', controls: ['questionTypes', 'roundSize', 'learn.retype'] },
    { key: 'write', title: 'Schreiben', note: 'Jede Karte schriftlich', controls: ['shuffle', 'copyAnswer', 'autoAdvance'] },
    TOLERANCE_SECTION,
  ],
};

export function studyOptionsLayout(mode = 'write') {
  return LAYOUTS[normalizeMode(mode)].map((section) => ({ ...section, controls: section.controls.slice() }));
}

const TOGGLES = {
  shuffle: { label: 'Mischen', description: 'Karten in zufälliger Reihenfolge abfragen.' },
  copyAnswer: { label: 'Richtige Antwort abtippen', description: 'Nach einem Fehler tippst du die Lösung einmal ab.' },
  autoAdvance: { label: 'Automatisch weiter', description: 'Nach einer richtigen Antwort geht es von selbst weiter.' },
  audio: { label: 'Vorlesen', description: 'Begriffe in der Lernsprache automatisch vorlesen.' },
  'learn.retype': {
    label: 'Richtige Antwort abtippen',
    description: 'Nach einem Fehler bei einer schriftlichen Frage tippst du die Lösung einmal ab.',
  },
};

const QUESTION_TYPES = [
  { key: 'mc', label: 'Multiple Choice', description: 'Vier Antworten zur Auswahl' },
  { key: 'written', label: 'Schriftlich', description: 'Antwort selbst eintippen' },
];

function cloneOptions(options) {
  const src = isObj(options) ? options : {};
  return { ...src, tolerance: { ...(isObj(src.tolerance) ? src.tolerance : {}) }, learn: learnOptions(src.learn) };
}

// Toggle paths are 'key' or 'learn.key'.
function readPath(state, path) {
  const [head, key] = path.split('.');
  return key ? !!(state[head] && state[head][key]) : !!state[head];
}

function writePath(state, path, value) {
  const [head, key] = path.split('.');
  if (key) state[head] = { ...state[head], [key]: value };
  else state[head] = value;
}

function patchFor(path, value) {
  const [head, key] = path.split('.');
  return key ? { [head]: { [key]: value } } : { [head]: value };
}

let formCounter = 0;

// termLang/defLang null (or 'other') label that side generically, e.g.
// "Lernsprache" for the defaults in Settings, which apply to every set.
export function studyOptionsForm({ options, termLang = 'fr', defLang = 'de', onChange, compact = false, mode = 'write' } = {}) {
  const m = normalizeMode(mode);
  const uid = `ui-so-${++formCounter}`;
  let state = cloneOptions(options);
  const emit = (patch) => {
    if (typeof onChange === 'function') onChange(patch);
  };
  const names = sideNames(termLang, defLang);
  const speechAvailable = canSpeak();
  const refreshers = [];
  const footerId = (key) => `${uid}-${key}-footer`;

  /* Antworten auf */
  function directionBox() {
    const hintFor = (value) => directionText(value || 'term', termLang, defLang, m);
    const labelId = `${uid}-dir`;
    const hint = h('p', { class: 'ui-so__direction-hint' }, hintFor(state.answerWith));
    const control = segmented({
      options: [
        { value: 'term', label: names.term.label },
        { value: 'definition', label: names.definition.label },
        { value: 'both', label: 'Beides' },
      ],
      value: state.answerWith || 'term',
      block: true,
      ariaLabel: 'Antworten auf',
      onChange: (value) => {
        state.answerWith = value;
        hint.textContent = hintFor(value);
        emit({ answerWith: value });
      },
    });
    control.setAttribute('aria-labelledby', labelId);
    refreshers.push(() => {
      control.setValue(state.answerWith || 'term');
      hint.textContent = hintFor(state.answerWith);
    });
    return h('div', { class: 'ui-so__direction' }, h('span', { class: 'ui-so__label', id: labelId }, 'Antworten auf'), control, hint);
  }

  /* Fragetypen: Multiple Choice / Schriftlich, never both off */
  function questionTypesBox() {
    const labelId = `${uid}-qt`;
    const hintId = `${uid}-qt-hint`;
    const hint = h('p', { class: 'ui-so__direction-hint', id: hintId, 'aria-live': 'polite' });
    const toggles = {};
    const sync = () => {
      const lock = questionTypeLock(state.learn);
      for (const { key } of QUESTION_TYPES) {
        const t = toggles[key];
        t.setChecked(state.learn[key]);
        t.setDisabled(lock === key);
        if (lock === key) t.setAttribute('title', LOCK_HINT);
        else t.removeAttribute('title');
      }
      hint.textContent = questionTypesHint(state.learn);
    };
    for (const item of QUESTION_TYPES) {
      const t = toggle({
        label: item.label,
        description: item.description,
        checked: state.learn[item.key],
        onChange: (checked) => {
          if (!checked && questionTypeLock(state.learn) === item.key) {
            sync(); // the last enabled type stays on
            return;
          }
          state.learn = { ...state.learn, [item.key]: checked };
          sync();
          emit({ learn: { [item.key]: checked } });
        },
      });
      const describedBy = t.input.getAttribute('aria-describedby');
      t.input.setAttribute('aria-describedby', describedBy ? `${describedBy} ${hintId}` : hintId);
      toggles[item.key] = t;
    }
    sync();
    refreshers.push(sync);
    return h(
      'div',
      { class: 'ui-so__direction ui-so__group', role: 'group', 'aria-labelledby': labelId },
      h('span', { class: 'ui-so__label', id: labelId }, 'Fragetypen'),
      QUESTION_TYPES.map(({ key }) => toggles[key]),
      hint,
    );
  }

  /* Begriffe pro Runde */
  function roundSizeBox() {
    const labelId = `${uid}-round`;
    let choices = roundSizeChoices(state.learn.roundSize);
    const build = () => {
      const control = segmented({
        options: choices.map((n) => ({ value: n, label: String(n) })),
        value: state.learn.roundSize,
        block: true,
        ariaLabel: 'Begriffe pro Runde',
        onChange: (value) => {
          state.learn = { ...state.learn, roundSize: value };
          emit({ learn: { roundSize: value } });
        },
      });
      control.setAttribute('aria-labelledby', labelId);
      return control;
    };
    let control = build();
    refreshers.push(() => {
      const next = roundSizeChoices(state.learn.roundSize);
      if (next.join() === choices.join()) {
        control.setValue(state.learn.roundSize);
        return;
      }
      choices = next;
      const fresh = build();
      control.replaceWith(fresh);
      control = fresh;
    });
    return h(
      'div',
      { class: 'ui-so__direction ui-so__group' },
      h('span', { class: 'ui-so__label', id: labelId }, 'Begriffe pro Runde'),
      control,
      h('p', { class: 'ui-so__direction-hint' }, 'Nach jeder Runde siehst du deinen Zwischenstand.'),
    );
  }

  /* Switches such as Mischen or Vorlesen */
  function toggleList(paths, section) {
    return h(
      'div',
      { class: 'ui-list' },
      paths.map((path) => {
        const def = TOGGLES[path];
        const unavailable = path === 'audio' && !speechAvailable;
        const t = toggle({
          label: def.label,
          description: unavailable ? 'Auf diesem Gerät nicht verfügbar.' : def.description,
          checked: readPath(state, path),
          disabled: unavailable,
          onChange: (checked) => {
            writePath(state, path, checked);
            emit(patchFor(path, checked));
          },
        });
        // Settings shows two "Richtige Antwort abtippen" switches: name them apart.
        if (m === 'all' && (path === 'copyAnswer' || path === 'learn.retype')) {
          t.input.removeAttribute('aria-labelledby');
          t.input.setAttribute('aria-label', `${def.label} (${section.title})`);
        }
        refreshers.push(() => t.setChecked(readPath(state, path)));
        return t;
      }),
    );
  }

  /* Toleranz */
  function toleranceList() {
    return h(
      'div',
      { class: 'ui-list' },
      toleranceItems(termLang).map((item) => {
        const t = toggle({
          label: item.label,
          description: item.example,
          checked: !!state.tolerance[item.key],
          onChange: (checked) => {
            state.tolerance[item.key] = checked;
            emit({ tolerance: { [item.key]: checked } });
          },
        });
        t.querySelector('.ui-toggle__desc')?.classList.add('ui-so__example');
        refreshers.push(() => t.setChecked(!!state.tolerance[item.key]));
        return t;
      }),
    );
  }

  /* Wiederholungsfragen: an app preference, written at once (not part of onChange) */
  function reviewBox() {
    const t = toggle({
      label: REVIEW_OPTION.label,
      description: REVIEW_OPTION.description,
      checked: learnReviewEnabled(),
      onChange: (checked) => setLearnReviewEnabled(checked),
    });
    // "Gilt für alle Lernsets." (the section's footer) is read with the switch.
    const describedBy = t.input.getAttribute('aria-describedby');
    t.input.setAttribute('aria-describedby', [describedBy, footerId('review')].filter(Boolean).join(' '));
    refreshers.push(() => t.setChecked(learnReviewEnabled()));
    return h('div', { class: 'ui-list' }, t);
  }

  const BOXES = { answerWith: directionBox, questionTypes: questionTypesBox, roundSize: roundSizeBox, review: reviewBox, tolerance: toleranceList };

  function sectionEl(section) {
    const body = [];
    let run = [];
    const flush = () => {
      if (run.length) body.push(toggleList(run, section));
      run = [];
    };
    for (const id of section.controls) {
      if (TOGGLES[id]) {
        run.push(id);
      } else {
        flush();
        body.push(BOXES[id]());
      }
    }
    flush();
    return h(
      'section',
      { class: 'ui-so__section', dataset: { section: section.key } },
      h(
        'div',
        { class: 'ui-so__heading' },
        h('h3', { class: 'ui-so__title' }, section.title),
        section.note ? h('span', { class: 'ui-so__note' }, section.note) : null,
      ),
      body,
      section.footer ? h('p', { class: 'ui-so__direction-hint ui-so__footer', id: footerId(section.key) }, section.footer) : null,
    );
  }

  const el = h('div', { class: ['ui-so', compact && 'ui-so--compact', `ui-so--${m}`] }, LAYOUTS[m].map(sectionEl));

  // Refreshes the controls from a full StudyOptions object (and the preference)
  // without emitting changes.
  el.update = (next) => {
    state = cloneOptions(next);
    for (const refresh of refreshers) refresh();
  };
  return el;
}
