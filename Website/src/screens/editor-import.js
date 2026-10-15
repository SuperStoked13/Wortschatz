// Smart import panel for the editor screen: paste box, file drop / picker,
// PDF + photo OCR with progress, live parsing with a detection bar, separator
// controls, warnings, skipped lines and a preview of the recognised pairs.

import { h, prefersReducedMotion } from '../lib/dom.js';
import { button, segmented, selectField, chip, progressBar, callout, spinner, toast } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { langName, plural, textAttrs } from '../lib/labels.js';
import { parseVocab } from '../core/parser.js';
import { readImportFile, ACCEPT } from '../import/files.js';
import { SEPARATORS, SKIP_REASONS, flagTooltip, hasMarker, formatLabel, isApplePlatform, fill } from './editor-util.js';
import { bindPageDrop } from './editor-drop.js';

const PLACEHOLDER =
  'Füge deine Vokabelliste hier ein – z. B. aus Word, einer PDF oder Quizlet. Begriff und Übersetzung werden automatisch erkannt.';
const PARSE_DELAY = 250;
const PREVIEW_ROWS = 8;
const PROGRESS_DELAY = 160;

/**
 * createImportPanel({ open, getLangs, onDetected, onApply, onFileName, onChange })
 *   getLangs(): { termLang, defLang, termTouched, defTouched }
 *   onDetected(result): after every parse that found cards
 *   onApply(cards, { result, state }): -> boolean | Promise<boolean> (true = applied)
 *   onFileName(name): first file name of a successful file import
 *   onChange(): text or busy state changed
 */
export function createImportPanel({ open = true, getLangs, onDetected, onApply, onFileName, onChange } = {}) {
  let isOpen = !!open;
  let sep = 'auto';
  let userSwap = false;
  let expanded = false;
  let skippedOpen = false;
  let result = null;
  let parseTimer = null;
  let busy = false;
  let importToken = 0;
  let importAbort = null; // AbortController of the running file import
  let progressTimer = null;
  let applying = false;
  // Problems of the last file imports that did not stop them (e.g. scanned PDF
  // pages that could not be read); shown with the parser warnings until the
  // text is cleared or taken over.
  let fileNotes = [];

  const uid = Math.random().toString(36).slice(2, 8);
  const bodyId = `ed-import-body-${uid}`;
  const hintId = `ed-import-hint-${uid}`;

  const changed = () => {
    if (typeof onChange === 'function') onChange();
  };

  /* ------------------------------------------------------------ head */

  const toggleBtn = h(
    'button',
    {
      type: 'button',
      class: 'ed-import__toggle',
      'aria-expanded': String(isOpen),
      'aria-controls': bodyId,
      onClick: () => setOpen(!isOpen),
    },
    h('span', { class: 'ed-import__badge', 'aria-hidden': 'true' }, icon('sparkles', { size: 20 })),
    h(
      'span',
      { class: 'ed-import__heading' },
      h('span', { class: 'ed-import__title' }, 'Vokabelliste importieren'),
      h('span', { class: 'ed-import__sub' }, 'Text einfügen, Datei hochladen oder Foto – die Paare werden automatisch erkannt.'),
    ),
    h('span', { class: 'ed-import__chev', 'aria-hidden': 'true' }, icon('chevronDown', { size: 20 })),
  );

  /* ------------------------------------------------- paste + drop zone */

  const textarea = h('textarea', {
    class: ['ui-input', 'ui-textarea', 'ed-import__text'],
    placeholder: PLACEHOLDER,
    spellcheck: 'false',
    autocomplete: 'off',
    autocapitalize: 'off',
    // Each pasted line takes the direction of its text (Arabic lines run right to left).
    dir: 'auto',
    'aria-label': 'Vokabelliste zum Importieren',
    'aria-describedby': hintId,
    onInput: () => {
      scheduleParse();
      syncTools();
      changed();
    },
  });

  const fileInput = h('input', {
    type: 'file',
    multiple: true,
    accept: ACCEPT,
    hidden: true,
    tabindex: '-1',
    'aria-hidden': 'true',
    onChange: () => {
      const files = Array.from(fileInput.files || []);
      fileInput.value = '';
      handleFiles(files);
    },
  });

  const pickBtn = button({
    label: 'Datei wählen',
    icon: 'upload',
    variant: 'secondary',
    size: 'sm',
    onClick: () => fileInput.click(),
    attrs: { class: 'ed-drop__pick' },
  });

  const clearBtn = button({
    label: 'Text leeren',
    icon: 'x',
    variant: 'ghost',
    size: 'sm',
    attrs: { class: 'ed-import__clear', hidden: true },
    onClick: () => {
      textarea.value = '';
      parseNow();
      syncTools();
      changed();
      textarea.focus();
    },
  });

  const dropZone = h(
    'div',
    { class: 'ed-drop' },
    h(
      'div',
      { class: 'ed-drop__art', 'aria-hidden': 'true' },
      h('span', { class: 'ed-drop__tile ed-drop__tile--a' }, icon('fileText', { size: 20 })),
      h('span', { class: 'ed-drop__tile ed-drop__tile--b' }, icon('image', { size: 20 })),
    ),
    h(
      'p',
      { class: 'ed-drop__title' },
      h('span', { class: 'ed-drop__title-fine' }, 'Datei hierher ziehen'),
      h('span', { class: 'ed-drop__title-touch' }, 'Datei oder Foto hochladen'),
    ),
    h('p', { class: 'ed-drop__formats' }, 'TXT, CSV, PDF oder Foto'),
    pickBtn,
    h('p', { class: 'ed-drop__paste' }, 'Bilder mit ', h('kbd', { class: 'ui-kbd' }, isApplePlatform() ? '⌘V' : 'Strg+V'), ' einfügen'),
    fileInput,
  );

  const textWrap = h(
    'div',
    { class: 'ed-import__textwrap' },
    textarea,
    h(
      'div',
      { class: 'ed-import__overlay', 'aria-hidden': 'true' },
      h('span', { class: 'ed-import__overlay-icon' }, icon('upload', { size: 24 })),
      h('span', null, 'Loslassen zum Importieren'),
    ),
  );

  const hint = h(
    'p',
    { class: 'ed-import__hint', id: hintId },
    'Tipp: Funktioniert mit abwechselnden Zeilen, Tabellen (Tab, Komma, Strichpunkt, Bindestrich) und Quizlet-Exporten.',
  );

  /* ---------------------------------------------------------- progress */

  const progressLabel = h('span', { class: 'ed-progress__text' });
  const progressPct = h('span', { class: 'ed-progress__pct' });
  const progressAnnounce = h('span', { class: 'sr-only', role: 'status' });
  const bar = progressBar({ value: 0, label: 'Fortschritt der Texterkennung', size: 'sm' });
  const cancelBtn = button({ label: 'Abbrechen', variant: 'ghost', size: 'sm', onClick: () => cancelImport() });
  const progressBox = h(
    'div',
    { class: 'ed-progress', hidden: true },
    h('div', { class: 'ed-progress__row' }, spinner({ size: 16 }), progressLabel, progressPct, cancelBtn),
    bar,
    progressAnnounce,
  );

  /* --------------------------------------------------------- detection */

  const summary = h('div', { class: 'ed-detect__summary' });
  // Announces only changes of the pair count, not every keystroke.
  const announce = h('span', { class: 'sr-only', role: 'status' });
  let announced = null;

  const segCtl = segmented({
    options: SEPARATORS.map((s) => ({ value: s.value, label: s.label })),
    value: sep,
    ariaLabel: 'Trennung zwischen Begriff und Definition',
    size: 'sm',
    onChange: (v) => setSep(v, true),
  });
  segCtl.classList.add('ed-detect__seg');

  const sepSelect = selectField({
    options: SEPARATORS.map((s) => ({ value: s.value, label: s.label })),
    value: sep,
    ariaLabel: 'Trennung zwischen Begriff und Definition',
    size: 'sm',
    onChange: (v) => setSep(v, true),
  });
  sepSelect.classList.add('ed-detect__select');

  const customInput = h('input', {
    type: 'text',
    class: ['ui-input', 'ui-input--sm', 'ed-detect__custom'],
    maxlength: '8',
    placeholder: 'z. B. /',
    spellcheck: 'false',
    autocomplete: 'off',
    'aria-label': 'Eigenes Trennzeichen',
    hidden: true,
    onInput: () => scheduleParse(150),
  });

  const swapBtn = button({
    label: 'Seiten tauschen',
    icon: 'swap',
    variant: 'secondary',
    size: 'sm',
    attrs: { 'aria-pressed': 'false', class: 'ed-detect__swap' },
    onClick: () => {
      userSwap = !userSwap;
      swapBtn.setAttribute('aria-pressed', String(userSwap));
      parseNow();
    },
  });

  const controls = h(
    'div',
    { class: 'ed-detect__controls' },
    h('span', { class: 'ed-detect__label', 'aria-hidden': 'true' }, 'Trennung'),
    h('div', { class: 'ed-detect__sep' }, segCtl, sepSelect, customInput),
    swapBtn,
  );

  const warnBox = h('div', { class: 'ed-detect__warnings' });
  const skippedBox = h('div', { class: 'ed-detect__skipped' });
  const preview = h('div', { class: 'ed-preview' });

  const moreBtn = button({
    label: 'Alle anzeigen',
    variant: 'ghost',
    size: 'sm',
    iconRight: 'chevronDown',
    attrs: { class: 'ed-detect__more', 'aria-expanded': 'false' },
    onClick: () => {
      expanded = !expanded;
      renderPreview();
    },
  });

  const applyBtn = button({
    label: 'Karten übernehmen',
    icon: 'check',
    variant: 'primary',
    attrs: { class: 'ed-detect__apply' },
    onClick: () => apply(),
  });

  const detect = h(
    'div',
    { class: 'ed-detect', hidden: true },
    summary,
    announce,
    controls,
    warnBox,
    skippedBox,
    preview,
    h('div', { class: 'ed-detect__foot' }, moreBtn, applyBtn),
  );

  const body = h(
    'div',
    { class: 'ed-import__body', id: bodyId, hidden: !isOpen },
    h('div', { class: 'ed-import__grid' }, h('div', { class: 'ed-import__main' }, textWrap, h('div', { class: 'ed-import__tools' }, hint, clearBtn)), dropZone),
    progressBox,
    detect,
  );

  const el = h(
    'section',
    { class: ['ed-import', isOpen && 'is-open'], 'aria-label': 'Vokabelliste importieren' },
    h('h2', { class: 'ed-import__h' }, toggleBtn),
    body,
  );

  /* ------------------------------------------------------------ state */

  function setOpen(next, { focus = false } = {}) {
    isOpen = !!next;
    el.classList.toggle('is-open', isOpen);
    toggleBtn.setAttribute('aria-expanded', String(isOpen));
    body.hidden = !isOpen;
    if (isOpen && !prefersReducedMotion()) {
      body.classList.remove('is-opening');
      void body.offsetWidth;
      body.classList.add('is-opening');
    }
    if (isOpen && focus) textarea.focus();
  }

  function syncTools() {
    clearBtn.hidden = !textarea.value;
  }

  function setSep(value, fromUser) {
    sep = SEPARATORS.some((s) => s.value === value) ? value : 'auto';
    segCtl.setValue(sep);
    sepSelect.value = sep;
    customInput.hidden = sep !== 'custom';
    if (fromUser && sep === 'custom') customInput.focus();
    if (fromUser) parseNow();
  }

  function parseOptions() {
    const langs = typeof getLangs === 'function' ? getLangs() : {};
    const opts = { swap: userSwap };
    if (langs.termTouched && langs.termLang && langs.termLang !== 'other') opts.termLang = langs.termLang;
    opts.defLang = langs.defTouched && langs.defLang ? langs.defLang : 'de';
    const entry = SEPARATORS.find((s) => s.value === sep);
    if (sep === 'custom') {
      const custom = customInput.value;
      if (custom) Object.assign(opts, { mode: 'delimiter', delimiter: custom.trim() || custom });
    } else if (entry && entry.opts) {
      Object.assign(opts, entry.opts);
    }
    return opts;
  }

  function scheduleParse(delay = PARSE_DELAY) {
    clearTimeout(parseTimer);
    parseTimer = setTimeout(parseNow, delay);
  }

  function parseNow() {
    clearTimeout(parseTimer);
    parseTimer = null;
    const text = textarea.value;
    if (!text.trim()) fileNotes = [];
    result = text.trim() ? parseVocab(text, parseOptions()) : null;
    renderDetect();
    if (result && result.cards.length && typeof onDetected === 'function') onDetected(result);
  }

  // Brings `result` up to date with the text when a parse is still scheduled
  // (e.g. Cmd+Enter right after typing in the box).
  function flushParse() {
    if (parseTimer) parseNow();
  }

  /* ------------------------------------------------------- rendering */

  function renderDetect() {
    if (!result) {
      detect.hidden = true;
      summary.replaceChildren();
      announced = null;
      announce.textContent = '';
      return;
    }
    detect.hidden = false;
    const n = result.cards.length;
    const flagged = result.cards.filter((c) => hasMarker(c.flags)).length;
    const autoSwapped = result.swapped && !userSwap;
    const parts = [];
    if (n) {
      const layout = formatLabel(result);
      if (layout) parts.push(layout);
      if (result.termLang !== 'other' || result.defLang !== 'other') parts.push(`${langName(result.termLang)} → ${langName(result.defLang)}`);
    }
    fill(
      summary,
      h('span', { class: ['ed-detect__spark', !n && 'is-idle'], 'aria-hidden': 'true' }, icon(n ? 'sparkles' : 'search', { size: 18 })),
      h(
        'span',
        { class: 'ed-detect__text' },
        h('strong', { class: 'ed-detect__count' }, n ? `${plural(n, 'Paar', 'Paare')} erkannt` : 'Noch keine Paare erkannt'),
        parts.map((p) => [h('span', { class: 'ed-detect__dot', 'aria-hidden': 'true' }, '·'), h('span', { class: 'ed-detect__part' }, p)]),
      ),
      n && (autoSwapped || flagged)
        ? h(
            'span',
            { class: 'ed-detect__chips' },
            autoSwapped ? chip({ label: 'Seiten automatisch getauscht', tone: 'accent', icon: 'swap', size: 'sm' }) : null,
            flagged ? chip({ label: `${flagged} bitte prüfen`, tone: 'warning', icon: 'alert', size: 'sm' }) : null,
          )
        : null,
    );
    if (n !== announced) {
      announced = n;
      announce.textContent = n ? `${plural(n, 'Paar', 'Paare')} erkannt` : 'Noch keine Paare erkannt';
    }
    if (!n) {
      summary.append(
        h(
          'span',
          { class: 'ed-detect__empty' },
          sep === 'custom' && !customInput.value
            ? 'Gib oben dein Trennzeichen ein.'
            : 'Wähle eine andere Trennung oder prüfe, ob jede Zeile einen Begriff und eine Übersetzung enthält.',
        ),
      );
    }

    // Warnings (the skipped-lines message is covered by the disclosure below).
    const skipped = result.skipped || [];
    const warnings = [...fileNotes, ...(result.warnings || []).filter((w) => !(skipped.length && /übersprungen/.test(w)))];
    if (warnings.length) {
      warnBox.replaceChildren(
        callout({
          tone: 'warning',
          children: h('ul', { class: 'ed-warnings', role: 'list' }, warnings.map((w) => h('li', null, w))),
        }),
      );
    } else {
      warnBox.replaceChildren();
    }
    warnBox.hidden = !warnings.length;

    if (skipped.length) {
      const details = h(
        'details',
        { class: 'ed-skipped', open: skippedOpen || null },
        h(
          'summary',
          { class: 'ed-skipped__summary' },
          icon('chevronRight', { size: 16, className: 'ed-skipped__chev' }),
          `${plural(skipped.length, 'Zeile', 'Zeilen')} übersprungen`,
        ),
        h(
          'ul',
          { class: 'ed-skipped__list', role: 'list' },
          skipped.map((s) =>
            h(
              'li',
              { class: 'ed-skipped__item' },
              h('span', { class: 'ed-skipped__line' }, `Zeile ${s.line}`),
              h('span', { class: 'ed-skipped__text', dir: 'auto' }, s.text || '–'),
              h('span', { class: 'ed-skipped__reason' }, SKIP_REASONS[s.reason] || 'Übersprungen'),
            ),
          ),
        ),
      );
      details.addEventListener('toggle', () => {
        skippedOpen = details.open;
      });
      skippedBox.replaceChildren(details);
    } else {
      skippedBox.replaceChildren();
    }
    skippedBox.hidden = !skipped.length;

    renderPreview();
    applyBtn.disabled = !n;
    applyBtn.setLabel(n ? `${plural(n, 'Karte', 'Karten')} übernehmen` : 'Karten übernehmen');
  }

  function renderPreview() {
    const cards = result ? result.cards : [];
    const n = cards.length;
    preview.hidden = !n;
    moreBtn.hidden = n <= PREVIEW_ROWS;
    moreBtn.setAttribute('aria-expanded', String(expanded));
    moreBtn.setLabel(expanded ? 'Weniger anzeigen' : `Alle ${n} anzeigen`);
    moreBtn.classList.toggle('is-expanded', expanded);
    if (!n) {
      preview.replaceChildren();
      return;
    }
    const shown = expanded ? cards : cards.slice(0, PREVIEW_ROWS);
    // A missing side shows German text, without the side's language and direction.
    const termAttrs = textAttrs(result.termLang);
    const defAttrs = textAttrs(result.defLang);
    const rows = shown.map((card, i) => {
      const tip = hasMarker(card.flags) ? flagTooltip(card.flags) : null;
      return h(
        'li',
        { class: ['ed-prev', tip && 'is-flagged'] },
        h('span', { class: 'ed-prev__num' }, String(i + 1)),
        h('span', { class: ['ed-prev__term', !card.term && 'is-missing'], ...(card.term ? termAttrs : {}) }, card.term || 'Begriff fehlt'),
        h('span', { class: ['ed-prev__def', !card.definition && 'is-missing'], ...(card.definition ? defAttrs : {}) }, card.definition || 'Definition fehlt'),
        h(
          'span',
          { class: 'ed-prev__flag' },
          tip ? h('span', { class: 'ed-prev__flag-icon', 'data-tooltip': tip }, icon('alert', { size: 15 }), h('span', { class: 'sr-only' }, tip)) : null,
        ),
      );
    });
    const rest = n - shown.length;
    fill(
      preview,
      h(
        'div',
        { class: 'ed-preview__head', 'aria-hidden': 'true' },
        h('span', null, '#'),
        h('span', null, h('span', { class: 'ed-preview__role' }, 'Begriff · '), langName(result.termLang)),
        h('span', null, h('span', { class: 'ed-preview__role' }, 'Definition · '), langName(result.defLang)),
        h('span', null),
      ),
      h('ol', { class: 'ed-preview__list', role: 'list', 'aria-label': 'Vorschau der erkannten Karten' }, rows),
      rest > 0 ? h('p', { class: 'ed-preview__more' }, `… und ${rest} weitere`) : null,
    );
  }

  /* ------------------------------------------------------------ apply */

  function getState() {
    return { text: textarea.value, sep, custom: customInput.value, swap: userSwap, notes: fileNotes.slice() };
  }

  function setState(state = {}) {
    fileNotes = Array.isArray(state.notes) ? state.notes.slice() : [];
    textarea.value = state.text || '';
    customInput.value = state.custom || '';
    userSwap = !!state.swap;
    swapBtn.setAttribute('aria-pressed', String(userSwap));
    setSep(state.sep || 'auto', false);
    expanded = false;
    syncTools();
    parseNow();
    changed();
  }

  function reset() {
    setState({});
  }

  async function apply() {
    flushParse();
    if (!result || !result.cards.length || applying || typeof onApply !== 'function') return;
    applying = true;
    const state = getState();
    const cards = result.cards.map((c) => ({ term: c.term, definition: c.definition, flags: c.flags.slice() }));
    try {
      const ok = await onApply(cards, { result, state });
      if (ok) {
        reset();
        setOpen(false);
      }
    } finally {
      applying = false;
    }
  }

  /* ------------------------------------------------------------ files */

  function showProgress(fraction, message) {
    const pct = Math.round(Math.min(1, Math.max(0, fraction || 0)) * 100);
    bar.update(fraction || 0);
    progressPct.textContent = `${pct} %`;
    if (message && progressLabel.textContent !== message) {
      progressLabel.textContent = message;
      progressAnnounce.textContent = message;
    }
  }

  function setBusy(next) {
    busy = next;
    clearTimeout(progressTimer);
    el.classList.toggle('is-busy', busy);
    if (busy) {
      showProgress(0, 'Datei wird gelesen …');
      // Text files finish instantly: only show progress for slow imports.
      progressTimer = setTimeout(() => {
        if (busy) progressBox.hidden = false;
      }, PROGRESS_DELAY);
    } else {
      progressBox.hidden = true;
    }
    changed();
  }

  // Stops the running import (PDF reading, text recognition) and drops its result.
  function abortImport() {
    importToken++;
    if (importAbort) importAbort.abort();
    importAbort = null;
  }

  function cancelImport() {
    if (!busy) return;
    abortImport();
    setBusy(false);
    toast('Import abgebrochen');
  }

  async function handleFiles(input, { source = 'file' } = {}) {
    const files = Array.from(input || []).filter(Boolean);
    if (!files.length) return;
    if (busy) {
      toast('Bitte warte, bis der aktuelle Import fertig ist.');
      return;
    }
    if (!isOpen) setOpen(true);
    const token = ++importToken;
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    importAbort = controller;
    setBusy(true);
    const langs = typeof getLangs === 'function' ? getLangs() : {};
    const texts = [];
    const errors = [];
    const notes = [];
    let firstName = null;
    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      const prefix = files.length > 1 ? `Datei ${i + 1} von ${files.length}: ` : '';
      const name = file.name && source !== 'paste' ? `«${file.name}»: ` : '';
      try {
        const res = await readImportFile(file, {
          termLang: langs.termLang || 'fr',
          signal: controller ? controller.signal : undefined,
          onProgress: (f, msg) => {
            if (token === importToken) showProgress((i + f) / files.length, prefix + (msg || 'Wird gelesen …'));
          },
        });
        if (token !== importToken) return;
        const text = String(res.text || '').trim();
        if (text) {
          texts.push(text);
          if (!firstName) firstName = res.name || file.name;
        }
        for (const w of res.warnings || []) notes.push(`${name}${w}`);
      } catch (err) {
        if (token !== importToken) return;
        errors.push(`${name}${(err && err.message) || 'Die Datei konnte nicht gelesen werden.'}`);
      }
    }
    if (token !== importToken) return;
    importAbort = null;
    setBusy(false);
    for (const message of errors) toast(message, { tone: 'danger', duration: 7000 });
    if (!texts.length) return;

    const existing = textarea.value.trim();
    textarea.value = (existing ? [existing, ...texts] : texts).join('\n\n');
    fileNotes = [...(existing ? fileNotes : []), ...notes];
    syncTools();
    parseNow();
    changed();
    if (source !== 'paste' && firstName && typeof onFileName === 'function') onFileName(firstName);
    const n = result ? result.cards.length : 0;
    const found = n ? `${plural(n, 'Paar', 'Paare')} gefunden` : 'noch keine Paare gefunden';
    if (notes.length) {
      // Do not suggest completeness: part of the content could not be read.
      toast(`Text teilweise erkannt – ${found}. Nicht alles konnte gelesen werden, siehe Hinweis.`, { tone: 'warning', duration: 7000 });
    } else {
      toast(n ? `Text erkannt – ${found}. Prüfe die Vorschau.` : 'Text eingefügt. Es wurden noch keine Paare erkannt.', {
        tone: n ? 'success' : 'neutral',
      });
    }
    (n || notes.length ? detect : textWrap).scrollIntoView({ block: 'nearest', behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
  }

  const unbindDrop = bindPageDrop({
    onFiles: (files) => handleFiles(files),
    onActive: (active) => el.classList.toggle('is-dragover', active),
  });

  function destroy() {
    clearTimeout(parseTimer);
    clearTimeout(progressTimer);
    abortImport();
    unbindDrop();
  }

  return {
    el,
    textarea,
    setOpen,
    get isOpen() {
      return isOpen;
    },
    get busy() {
      return busy;
    },
    getText: () => textarea.value,
    // Text pasted elsewhere (e.g. a whole list into a card field).
    setText(text, { append = false } = {}) {
      const existing = textarea.value.trim();
      if (!(append && existing)) fileNotes = [];
      textarea.value = append && existing ? `${existing}\n\n${text}` : text;
      syncTools();
      setOpen(true);
      parseNow();
      changed();
    },
    pendingCount: () => {
      flushParse();
      return result && textarea.value.trim() ? result.cards.length : 0;
    },
    pendingCards: () => {
      flushParse();
      return result ? result.cards.map((c) => ({ term: c.term, definition: c.definition, flags: c.flags.slice() })) : [];
    },
    reparse: () => {
      if (textarea.value.trim()) parseNow();
    },
    getState,
    setState,
    reset,
    handleFiles,
    focus: () => textarea.focus(),
    scrollIntoView: () => el.scrollIntoView({ block: 'start', behavior: prefersReducedMotion() ? 'auto' : 'smooth' }),
    destroy,
  };
}
