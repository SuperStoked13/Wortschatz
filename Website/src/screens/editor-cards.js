// Card rows editor for the editor screen (Quizlet-style numbered rows).
//
// Rows are created once and updated in place: typing only touches the row
// being edited (the auto-grow uses a CSS grid replica, so no layout reads),
// duplicate detection is debounced and numbering is refreshed only when rows
// are added or removed. This keeps lists with several hundred cards fluid.

import { h, prefersReducedMotion } from '../lib/dom.js';
import { iconButton, starButton, toast } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { langName } from '../lib/labels.js';
import { flagTooltip, hasMarker, termKey, langTag } from './editor-util.js';

const DUP_DELAY = 180;
const MIN_ROWS = 2;

function setLang(el, code) {
  const tag = langTag(code);
  if (tag) el.setAttribute('lang', tag);
  else el.removeAttribute('lang');
}

function focusEnd(ta) {
  if (!ta) return;
  ta.focus({ preventScroll: true });
  const len = ta.value.length;
  try {
    ta.setSelectionRange(len, len);
  } catch {
    // some input types do not support selection
  }
  ta.scrollIntoView({ block: 'nearest', behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
}

/**
 * createCardList({ cards, termLang, defLang, onChange, onPasteList })
 *   cards: [{ id?, term, definition, starred?, flags? }]
 *   onChange(): any edit (content, rows, stars)
 *   onPasteList(text): multi-line text pasted into a field; return true when handled
 */
export function createCardList({ cards = [], termLang = 'fr', defLang = 'de', onChange, onPasteList } = {}) {
  let langs = { term: termLang, def: defLang };
  let rows = [];
  let rowSeq = 0;
  let dupTimer = null;
  let dupTerms = 0;
  let destroyed = false;
  const undoToasts = new Set();
  const fieldMap = new WeakMap(); // textarea -> { row, side }

  const notify = () => {
    if (typeof onChange === 'function') onChange();
  };

  /* ---------------------------------------------------------- structure */

  const termHead = h('span', { class: 'ed-cols__label' });
  const defHead = h('span', { class: 'ed-cols__label' });
  const cols = h(
    'div',
    { class: 'ed-cols', 'aria-hidden': 'true' },
    h('span', { class: 'ed-cols__num' }, '#'),
    h('span', { class: 'ed-cols__fields' }, termHead, defHead),
    h('span', { class: 'ed-cols__actions' }),
  );
  const list = h('ol', { class: 'ed-rows', role: 'list' });
  const addBtn = h(
    'button',
    { type: 'button', class: 'ed-add', onClick: () => addRow({ focus: true }) },
    h('span', { class: 'ed-add__icon', 'aria-hidden': 'true' }, icon('plus', { size: 18 })),
    h('span', null, 'Karte hinzufügen'),
  );
  const el = h('div', { class: 'ed-cardlist' }, cols, list, addBtn);

  /* --------------------------------------------------------------- rows */

  function makeField(row, side, value) {
    const ta = h('textarea', {
      class: 'ed-cell__input',
      rows: '1',
      spellcheck: 'true',
      autocapitalize: 'off',
      autocomplete: 'off',
      placeholder: side === 'term' ? 'Begriff eingeben' : 'Definition eingeben',
      value: value || '',
    });
    const wrap = h('div', { class: 'ed-grow', dataset: { value: value || '' } }, ta);
    const label = h('span', { class: 'ed-cell__label', 'aria-hidden': 'true' });
    const cell = h('label', { class: ['ed-cell', `ed-cell--${side}`] }, label, wrap);
    fieldMap.set(ta, { row, side });
    return { cell, wrap, ta, label };
  }

  function createRow(card = {}) {
    const row = {
      key: ++rowSeq,
      id: typeof card.id === 'string' && card.id ? card.id : null,
      starred: !!card.starred,
      flags: Array.isArray(card.flags) ? card.flags.slice() : [],
      dup: false,
      invalid: false,
    };
    row.term = makeField(row, 'term', card.term == null ? '' : String(card.term));
    row.def = makeField(row, 'def', card.definition == null ? '' : String(card.definition));
    row.num = h('span', { class: 'ed-card__num' });
    row.marker = h('span', { class: 'ed-card__flag', hidden: true }, icon('alert', { size: 15 }), h('span', { class: 'sr-only' }));
    row.notes = h('div', { class: 'ed-card__notes', hidden: true });
    row.star = starButton({
      starred: row.starred,
      size: 'sm',
      onToggle: (next) => {
        row.starred = next;
        notify();
        return next;
      },
    });
    row.del = iconButton({
      icon: 'trash',
      label: 'Karte löschen',
      size: 'sm',
      variant: 'danger',
      attrs: { class: 'ed-card__del' },
      onClick: () => removeRow(row, { undoable: true }),
    });
    row.el = h(
      'li',
      { class: 'ed-card' },
      h('div', { class: 'ed-card__side' }, row.num, row.marker),
      h('div', { class: 'ed-card__fields' }, row.term.cell, row.def.cell),
      h('div', { class: 'ed-card__actions' }, row.star, row.del),
      row.notes,
    );
    applyLangs(row);
    renderMarker(row);
    return row;
  }

  function applyLangs(row) {
    setLang(row.term.ta, langs.term);
    setLang(row.def.ta, langs.def);
    row.term.label.textContent = langName(langs.term);
    row.def.label.textContent = langName(langs.def);
  }

  function labelRow(row, index) {
    const n = index + 1;
    row.num.textContent = String(n);
    row.term.ta.setAttribute('aria-label', `Karte ${n}: Begriff (${langName(langs.term)})`);
    row.def.ta.setAttribute('aria-label', `Karte ${n}: Definition (${langName(langs.def)})`);
    row.del.setLabel(`Karte ${n} löschen`);
  }

  function renumber() {
    rows.forEach(labelRow);
  }

  function renderMarker(row) {
    const tip = hasMarker(row.flags) ? flagTooltip(row.flags) : null;
    row.el.classList.toggle('is-flagged', !!tip);
    row.marker.hidden = !tip;
    if (tip) {
      row.marker.dataset.tooltip = tip;
      row.marker.lastChild.textContent = tip;
    } else {
      delete row.marker.dataset.tooltip;
    }
  }

  function renderNotes(row) {
    const notes = [];
    if (row.invalid) {
      const t = row.term.ta.value.trim();
      notes.push(h('span', { class: 'ed-note ed-note--danger' }, icon('alertCircle', { size: 14 }), t ? 'Definition fehlt' : 'Begriff fehlt'));
    }
    if (row.dup) notes.push(h('span', { class: 'ed-note ed-note--warning' }, icon('copy', { size: 14 }), 'Doppelter Begriff'));
    row.notes.replaceChildren(...notes);
    row.notes.hidden = !notes.length;
    row.el.classList.toggle('is-invalid', row.invalid);
    row.el.classList.toggle('is-duplicate', row.dup);
    row.term.ta.setAttribute('aria-invalid', row.invalid && !row.term.ta.value.trim() ? 'true' : 'false');
    row.def.ta.setAttribute('aria-invalid', row.invalid && !row.def.ta.value.trim() ? 'true' : 'false');
  }

  const isFilled = (row) => !!(row.term.ta.value.trim() || row.def.ta.value.trim());
  const isComplete = (row) => !!(row.term.ta.value.trim() && row.def.ta.value.trim());

  function animateIn(row, cls = 'is-entering') {
    if (prefersReducedMotion()) return;
    row.el.classList.add(cls);
    row.el.addEventListener('animationend', () => row.el.classList.remove(cls), { once: true });
  }

  function addRow({ focus = false, card = null, index = rows.length, animate = true } = {}) {
    const row = createRow(card || {});
    const before = rows[index] ? rows[index].el : null;
    list.insertBefore(row.el, before);
    rows.splice(index, 0, row);
    renumber();
    if (animate) animateIn(row);
    if (focus) focusEnd(row.term.ta);
    scheduleDuplicates();
    notify();
    return row;
  }

  function removeRow(row, { undoable = false, focusAfter = true } = {}) {
    const index = rows.indexOf(row);
    if (index < 0) return;
    const filled = isFilled(row);
    // The list never becomes empty: the last row is replaced by a fresh one, so
    // a new word typed there does not inherit the deleted card's id (and with
    // it the learning progress) or its star.
    const replacement = rows.length === 1 ? addRow({ index: index + 1, animate: false }) : null;
    const neighbour = rows[index + 1] || rows[index - 1];
    const hadFocus = row.el.contains(document.activeElement);
    rows.splice(index, 1);
    // An undo may re-insert the row before the exit animation has finished.
    const detach = () => {
      if (!rows.includes(row)) row.el.remove();
    };
    if (prefersReducedMotion()) detach();
    else {
      row.el.classList.add('is-leaving');
      row.el.addEventListener('animationend', detach, { once: true });
      setTimeout(detach, 260);
    }
    renumber();
    scheduleDuplicates();
    if (replacement) {
      if (focusAfter) focusEnd(replacement.term.ta);
    } else if (focusAfter && hadFocus && neighbour) {
      // Keyboard users can keep deleting from the same position.
      neighbour.del.focus({ preventScroll: true });
    }
    notify();
    if (undoable && filled) {
      trackToast(
        toast('Karte gelöscht', {
          action: {
            label: 'Rückgängig',
            onClick: () => restoreRow(row, index),
          },
        }),
      );
    }
  }

  function restoreRow(row, index) {
    // The toast can outlive the editor (e.g. after saving): nothing to restore into.
    if (destroyed || rows.includes(row)) return;
    const at = Math.min(index, rows.length);
    row.el.classList.remove('is-leaving');
    list.insertBefore(row.el, rows[at] ? rows[at].el : null);
    rows.splice(at, 0, row);
    renumber();
    animateIn(row, 'is-new');
    scheduleDuplicates();
    notify();
  }

  // Undo toasts only make sense while this list exists; see closeToasts().
  function trackToast(handle) {
    if (!handle) return;
    for (const t of undoToasts) if (t.el && !t.el.isConnected) undoToasts.delete(t);
    undoToasts.add(handle);
  }

  function closeToasts() {
    undoToasts.forEach((t) => t.close());
    undoToasts.clear();
  }

  function setField(field, value) {
    field.ta.value = value;
    field.wrap.dataset.value = value;
  }

  /* ------------------------------------------------------ duplicates */

  function scheduleDuplicates(now = false) {
    clearTimeout(dupTimer);
    if (now) checkDuplicates();
    else dupTimer = setTimeout(checkDuplicates, DUP_DELAY);
  }

  function checkDuplicates() {
    dupTimer = null;
    const counts = new Map();
    const keys = rows.map((row) => {
      const key = termKey(row.term.ta.value);
      if (key) counts.set(key, (counts.get(key) || 0) + 1);
      return key;
    });
    let groups = 0;
    for (const n of counts.values()) if (n > 1) groups++;
    const changed = groups !== dupTerms;
    dupTerms = groups;
    rows.forEach((row, i) => {
      const dup = !!keys[i] && counts.get(keys[i]) > 1;
      if (dup !== row.dup) {
        row.dup = dup;
        renderNotes(row);
      }
    });
    if (changed) notify();
  }

  /* ---------------------------------------------------------- events */

  list.addEventListener('input', (e) => {
    const info = fieldMap.get(e.target);
    if (!info) return;
    const { row, side } = info;
    row[side].wrap.dataset.value = e.target.value;
    if (row.flags.length) {
      row.flags = [];
      renderMarker(row);
    }
    if (row.invalid && (isComplete(row) || !isFilled(row))) {
      row.invalid = false;
      renderNotes(row);
    }
    if (side === 'term') scheduleDuplicates();
    notify();
  });

  list.addEventListener('keydown', (e) => {
    const info = fieldMap.get(e.target);
    if (!info || e.isComposing || e.keyCode === 229) return;
    const { row, side } = info;
    const index = rows.indexOf(row);
    const last = index === rows.length - 1;
    const plain = !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey;

    if (e.key === 'Enter' && plain) {
      e.preventDefault();
      if (side === 'term') focusEnd(row.def.ta);
      else if (!last) focusEnd(rows[index + 1].term.ta);
      else if (isFilled(row)) addRow({ focus: true });
      return;
    }
    if (e.key === 'Tab' && plain && side === 'def' && last && isFilled(row)) {
      e.preventDefault();
      addRow({ focus: true });
      return;
    }
    if (e.key === 'Backspace' && plain && side === 'term' && rows.length > 1 && !isFilled(row)) {
      const ta = e.target;
      if (ta.selectionStart === 0 && ta.selectionEnd === 0) {
        e.preventDefault();
        const prev = rows[index - 1];
        removeRow(row, { focusAfter: false });
        focusEnd(prev ? prev.def.ta : rows[0].term.ta);
      }
    }
  });

  list.addEventListener('paste', (e) => {
    const info = fieldMap.get(e.target);
    if (!info || !e.clipboardData) return;
    const text = e.clipboardData.getData('text/plain');
    if (!text) return;
    const lines = text.split(/\r\n?|\n/).filter((l) => l.trim());
    // One spreadsheet row ("term<Tab>definition") pasted into an empty card
    // fills both fields, in the column order of the sheet.
    if (lines.length === 1 && !isFilled(info.row)) {
      const cells = lines[0].split('\t').map((c) => c.trim());
      if (cells.length === 2 && cells[0] && cells[1]) {
        e.preventDefault();
        fillRow(info.row, cells[0], cells[1]);
        return;
      }
    }
    if (typeof onPasteList !== 'function') return;
    const tabbed = lines.length >= 2 && lines.filter((l) => l.includes('\t')).length >= 2;
    if (lines.length >= 3 || tabbed) {
      if (onPasteList(text)) e.preventDefault();
    }
  });

  function fillRow(row, term, definition) {
    setField(row.term, term);
    setField(row.def, definition);
    if (row.flags.length) {
      row.flags = [];
      renderMarker(row);
    }
    if (row.invalid) {
      row.invalid = false;
      renderNotes(row);
    }
    focusEnd(row.def.ta);
    scheduleDuplicates();
    notify();
  }

  /* ------------------------------------------------------------- API */

  function setLangs(termCode, defCode) {
    langs = { term: termCode, def: defCode };
    termHead.textContent = `Begriff · ${langName(termCode)}`;
    defHead.textContent = `Definition · ${langName(defCode)}`;
    rows.forEach(applyLangs);
    renumber();
  }

  function buildRows(input, { flash = false } = {}) {
    const frag = document.createDocumentFragment();
    const created = input.map((card) => {
      const row = createRow(card);
      frag.append(row.el);
      if (flash) animateIn(row, 'is-new');
      return row;
    });
    return { frag, created };
  }

  function setCards(input, { flash = false } = {}) {
    const cardsIn = Array.isArray(input) ? input : [];
    const { frag, created } = buildRows(cardsIn, { flash });
    rows = created;
    list.replaceChildren(frag);
    while (rows.length < MIN_ROWS) {
      const row = createRow({});
      rows.push(row);
      list.append(row.el);
    }
    renumber();
    scheduleDuplicates(true);
    notify();
    return created;
  }

  // Appends cards after the last non-empty row (trailing empty rows are reused).
  function appendCards(input, { flash = false } = {}) {
    while (rows.length && !isFilled(rows[rows.length - 1])) {
      rows.pop().el.remove();
    }
    const { frag, created } = buildRows(Array.isArray(input) ? input : [], { flash });
    rows.push(...created);
    list.append(frag);
    while (rows.length < MIN_ROWS) {
      const row = createRow({});
      rows.push(row);
      list.append(row.el);
    }
    renumber();
    scheduleDuplicates(true);
    notify();
    return created;
  }

  // Cards to save: non-empty rows, in order.
  function getCards() {
    return rows.filter(isFilled).map((row) => ({
      id: row.id || undefined,
      term: row.term.ta.value.trim(),
      definition: row.def.ta.value.trim(),
      starred: row.starred,
    }));
  }

  // Everything needed to restore the list (undo).
  function snapshot() {
    return rows.map((row) => ({
      id: row.id,
      term: row.term.ta.value,
      definition: row.def.ta.value,
      starred: row.starred,
      flags: row.flags.slice(),
    }));
  }

  function restore(snap) {
    setCards(snap);
  }

  // Swaps term and definition in every row (Quizlet's "flip" action).
  function swapSides() {
    for (const row of rows) {
      const t = row.term.ta.value;
      setField(row.term, row.def.ta.value);
      setField(row.def, t);
      if (row.flags.length) {
        row.flags = row.flags.map((f) => (f === 'missingTerm' ? 'missingDefinition' : f === 'missingDefinition' ? 'missingTerm' : f));
        renderMarker(row);
      }
      if (row.invalid) renderNotes(row);
    }
    scheduleDuplicates(true);
    notify();
  }

  function stats() {
    let filled = 0;
    let complete = 0;
    let flagged = 0;
    let invalid = 0;
    for (const row of rows) {
      if (isFilled(row)) filled++;
      if (isComplete(row)) complete++;
      if (row.flags.length && hasMarker(row.flags)) flagged++;
      if (row.invalid) invalid++;
    }
    // invalid: rows marked by the last validate() and not fixed since
    return { rows: rows.length, filled, complete, incomplete: filled - complete, invalid, duplicates: dupTerms, flagged };
  }

  // Marks incomplete rows; returns the first incomplete row's empty field.
  function validate() {
    let first = null;
    for (const row of rows) {
      const invalid = isFilled(row) && !isComplete(row);
      if (invalid !== row.invalid) {
        row.invalid = invalid;
        renderNotes(row);
      }
      if (invalid && !first) first = row.term.ta.value.trim() ? row.def.ta : row.term.ta;
    }
    return first;
  }

  function focusFirst() {
    const row = rows.find((r) => !isComplete(r)) || rows[0];
    if (!row) return;
    focusEnd(row.term.ta.value.trim() ? row.def.ta : row.term.ta);
  }

  function isEmpty() {
    return !rows.some(isFilled);
  }

  function destroy() {
    destroyed = true;
    clearTimeout(dupTimer);
    closeToasts();
  }

  setLangs(termLang, defLang);
  setCards(cards);

  return {
    el,
    list,
    addRow: (opts) => addRow(opts),
    setCards,
    appendCards,
    getCards,
    snapshot,
    restore,
    swapSides,
    setLangs,
    stats,
    validate,
    focusFirst,
    focusField: focusEnd,
    isEmpty,
    closeToasts,
    destroy,
  };
}
