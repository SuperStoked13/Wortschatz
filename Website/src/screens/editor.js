// Editor screen: create (#/new) and edit (#/set/:id/edit) a vocabulary set.
// Title, description and languages, the smart import panel (paste, files,
// PDF/photo OCR, live parsing) and the Quizlet-style card rows.

import { h, prefersReducedMotion } from '../lib/dom.js';
import { navigate, setLeaveGuard, setTitle } from '../router.js';
import { button, iconButton, textField, selectField, chip, toast, openModal, emptyState, hasOpenModal } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { LANGS, LANG_ORDER, langShort, plural } from '../lib/labels.js';
import { db } from '../store/db.js';
import { createCardList } from './editor-cards.js';
import { createImportPanel } from './editor-import.js';
import { termKey, titleFromFileName, isApplePlatform, fill } from './editor-util.js';
import { reportUnsaved } from '../lib/host.js';
import { commandKey, isComposingKey } from '../lib/shortcuts.js';

const TERM_LANGS = LANG_ORDER;
const DEF_LANGS = ['de', ...LANG_ORDER.filter((c) => c !== 'de')];
const langOptions = (codes) => codes.map((code) => ({ value: code, label: LANGS[code].name }));
const knownLang = (code) => !!code && code !== 'other' && !!LANGS[code];

function smooth() {
  return prefersReducedMotion() ? 'auto' : 'smooth';
}

function replay(el, cls, ms = 1200) {
  if (!el || prefersReducedMotion()) return;
  el.classList.remove(cls);
  void el.offsetWidth;
  el.classList.add(cls);
  setTimeout(() => el.classList.remove(cls), ms);
}

// Imported cards replacing existing rows keep the ids (and so the learning
// progress) of rows with the same term.
function withPreservedIds(cards, previous) {
  const pool = new Map();
  for (const row of previous) {
    const key = termKey(row.term);
    if (!row.id || !key) continue;
    if (!pool.has(key)) pool.set(key, []);
    pool.get(key).push(row);
  }
  return cards.map((card) => {
    const match = (pool.get(termKey(card.term)) || []).shift();
    return match ? { ...card, id: match.id, starred: match.starred } : card;
  });
}

// Small modal with a choice; resolves to the chosen action's value or null
// (closed with Esc, the X or the backdrop). Action values must be truthy:
// openModal keeps a dialog open when an action handler returns false.
function chooseModal({ title, message, note, actions, className }) {
  return new Promise((resolve) => {
    let choice = null;
    openModal({
      title,
      size: 'sm',
      className: ['ed-choice', className],
      content: h(
        'div',
        { class: 'ed-choice__body' },
        h('p', { class: 'ui-confirm__message' }, message),
        note ? h('p', { class: 'ed-choice__note' }, icon('info', { size: 15 }), h('span', null, note)) : null,
      ),
      actions: actions.map((a) => ({ ...a, onClick: () => (choice = a.value) })),
      onClose: () => resolve(choice),
    });
  });
}

function renderMissing(outlet) {
  outlet.append(
    h(
      'div',
      { class: 'ui-page ed ed--missing' },
      emptyState({
        icon: 'search',
        title: 'Lernset nicht gefunden',
        text: 'Dieses Lernset gibt es nicht mehr – vielleicht wurde es gelöscht.',
        action: button({ label: 'Zur Übersicht', variant: 'primary', href: '#/', icon: 'arrowLeft' }),
      }),
    ),
  );
}

export function render(outlet, ctx = {}) {
  const params = (ctx && ctx.params) || {};
  const setId = params.id || null;
  const isEdit = !!setId;
  const original = isEdit ? db.getSet(setId) : null;
  if (isEdit && !original) {
    renderMissing(outlet);
    return () => {};
  }
  const titleSetter = typeof ctx.setTitle === 'function' ? ctx.setTitle : setTitle;
  titleSetter(isEdit ? `${original.title} bearbeiten` : 'Neues Lernset');

  const state = {
    termLang: original ? original.termLang : 'fr',
    defLang: original ? original.defLang : 'de',
    // An existing set's languages are a deliberate choice; a new set's are defaults.
    termTouched: isEdit,
    defTouched: isEdit,
    attempted: false,
    saving: false,
    saved: false,
    baseline: '',
    loadedAt: original ? original.updatedAt : 0,
  };
  const saveLabel = isEdit ? 'Speichern' : 'Erstellen';
  const kbdLabel = isApplePlatform() ? '⌘↵' : 'Strg ↵';
  let rafId = 0;
  // What the Windows app was last told about unsaved changes (syncUnsaved).
  let reportedUnsaved = false;
  const hasRaf = typeof requestAnimationFrame === 'function';
  // Toasts whose "Rückgängig" acts on this editor; closed once it is saved or left.
  const undoToasts = new Set();

  /* -------------------------------------------------------------- meta */

  const titleNote = h(
    'p',
    { class: 'ed-meta__note', hidden: true },
    icon('sparkles', { size: 14 }),
    'Aus dem Dateinamen übernommen – du kannst ihn jederzeit ändern.',
  );
  const titleField = textField({
    label: 'Titel',
    value: original ? original.title : '',
    placeholder: 'z. B. Unité 3 – Les personnes',
    size: 'lg',
    attrs: { maxlength: '120', autocomplete: 'off', class: 'ed-meta__title', enterkeyhint: 'next', dir: 'auto' },
    onInput: () => {
      titleNote.hidden = true;
      if (state.attempted) titleField.setError(titleField.value.trim() ? null : 'Gib deinem Lernset einen Titel.');
      changed();
    },
  });

  const descField = textField({
    label: 'Beschreibung',
    value: original ? original.description : '',
    placeholder: 'Optional – z. B. Kapitel, Lehrmittel oder Prüfungsdatum',
    multiline: true,
    rows: 1,
    autoGrow: true,
    attrs: { maxlength: '600', class: 'ed-meta__desc', dir: 'auto' },
    onInput: () => changed(),
  });

  titleField.input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.metaKey && !e.ctrlKey && !isComposingKey(e)) {
      e.preventDefault();
      descField.focus();
    }
  });

  const termAuto = h('p', { class: 'ed-lang__auto', hidden: true }, icon('sparkles', { size: 13 }), 'Automatisch erkannt');
  const defAuto = h('p', { class: 'ed-lang__auto', hidden: true }, icon('sparkles', { size: 13 }), 'Automatisch erkannt');

  const termSelect = selectField({
    label: 'Ich lerne',
    options: langOptions(TERM_LANGS),
    value: state.termLang,
    onChange: (v) => {
      state.termTouched = true;
      termAuto.hidden = true;
      setLangs(v, state.defLang);
      panel.reparse();
    },
  });
  const defSelect = selectField({
    label: 'Übersetzung',
    options: langOptions(DEF_LANGS),
    value: state.defLang,
    onChange: (v) => {
      state.defTouched = true;
      defAuto.hidden = true;
      setLangs(state.termLang, v);
      panel.reparse();
    },
  });
  termSelect.classList.add('ed-lang');
  defSelect.classList.add('ed-lang');
  termSelect.append(termAuto);
  defSelect.append(defAuto);

  const flipBtn = iconButton({
    icon: 'swap',
    label: 'Begriffe und Definitionen tauschen',
    variant: 'secondary',
    attrs: { class: 'ed-langs__flip' },
    onClick: () => flipSides(true),
  });

  const meta = h(
    'section',
    { class: 'ed-meta', 'aria-label': 'Angaben zum Lernset' },
    h('div', { class: 'ed-meta__titlewrap' }, titleField, titleNote),
    descField,
    h('div', { class: 'ed-langs' }, termSelect, flipBtn, defSelect),
  );

  /* ------------------------------------------------------------- cards */

  const list = createCardList({
    cards: original ? original.cards : [],
    termLang: state.termLang,
    defLang: state.defLang,
    onChange: () => changed(),
    onPasteList: (text) => {
      panel.setText(text, { append: true });
      panel.scrollIntoView();
      toast('Liste erkannt – prüfe die Vorschau und übernimm die Karten.', { icon: 'sparkles' });
      return true;
    },
  });

  const cardsCount = h('span', { class: 'ed-cards__count' });
  const cardsTitle = h('h2', { class: 'ui-h2 ed-cards__title', id: 'ed-cards-title', tabindex: '-1' }, 'Karten', cardsCount);
  const cardsIssues = h('div', { class: 'ed-cards__issues' });
  const cardsLead = h('p', { class: 'ed-cards__lead' }, 'Tippe deine Vokabeln ein – oder importiere oben eine ganze Liste auf einmal.');
  const cardsError = h('p', { class: 'ed-cards__error', role: 'alert', hidden: true });
  const keyHints = h(
    'p',
    { class: 'ed-keys' },
    h('span', { class: 'ed-keys__item' }, h('kbd', { class: 'ui-kbd' }, '↵'), 'nächstes Feld'),
    h('span', { class: 'ed-keys__item' }, h('kbd', { class: 'ui-kbd' }, '⇧↵'), 'Zeilenumbruch'),
    h('span', { class: 'ed-keys__item' }, h('kbd', { class: 'ui-kbd' }, 'Tab'), 'in der letzten Karte: neue Karte'),
    h('span', { class: 'ed-keys__item' }, h('kbd', { class: 'ui-kbd' }, kbdLabel), saveLabel),
  );
  const cardsSection = h(
    'section',
    { class: 'ed-cards', 'aria-labelledby': 'ed-cards-title' },
    h('div', { class: 'ed-cards__head' }, cardsTitle, cardsIssues),
    cardsLead,
    cardsError,
    list.el,
    keyHints,
  );

  /* ------------------------------------------------------------ import */

  const panel = createImportPanel({
    open: !isEdit,
    getLangs: () => ({ ...state }),
    onDetected,
    onApply: applyImport,
    onFileName: (name) => {
      if (titleField.value.trim()) return;
      const suggestion = titleFromFileName(name);
      if (!suggestion) return;
      titleField.value = suggestion;
      titleField.setError(null);
      titleNote.hidden = false;
      replay(titleField, 'is-flash');
      changed();
    },
    onChange: () => changed(),
  });

  /* ------------------------------------------------- header, dock, page */

  const makeSave = (cls) => {
    const btn = button({ label: saveLabel, variant: 'primary', kbd: kbdLabel, attrs: { class: ['ed-save', cls] } });
    btn.addEventListener('click', () => save());
    return btn;
  };
  const headSave = makeSave('ed-head__save');
  const dockSave = makeSave('ed-dock__save');
  const headMeta = h('p', { class: 'ed-head__meta' });
  const head = h(
    'header',
    { class: 'ed-head' },
    h(
      'a',
      { class: 'ui-back ed-head__back', href: isEdit ? `#/set/${encodeURIComponent(setId)}` : '#/' },
      icon('arrowLeft', { size: 16 }),
      isEdit ? 'Zurück zum Lernset' : 'Lernsets',
    ),
    h(
      'div',
      { class: 'ed-head__row' },
      h('div', { class: 'ed-head__text' }, h('h1', { class: 'ui-h1 ed-head__title' }, isEdit ? 'Lernset bearbeiten' : 'Neues Lernset'), headMeta),
      h('div', { class: 'ed-head__actions' }, headSave),
    ),
  );

  const dockStatus = h('p', { class: 'ed-dock__status' });
  const dock = h('div', { class: 'ed-dock', dataset: { visible: 'false' } }, h('div', { class: 'ed-dock__inner' }, dockStatus, dockSave));

  const root = h('div', { class: ['ui-page', 'ed', isEdit ? 'ed--edit' : 'ed--new'] }, head, meta, panel.el, cardsSection, dock);
  outlet.append(root);

  /* ----------------------------------------------------------- helpers */

  function serialize() {
    return JSON.stringify([
      titleField.value.trim(),
      descField.value.trim(),
      state.termLang,
      state.defLang,
      list.getCards().map((c) => [c.id || '', c.term, c.definition, !!c.starred]),
    ]);
  }

  function isDirty() {
    if (state.saved) return false;
    return serialize() !== state.baseline || !!panel.getText().trim();
  }

  function setLangs(termLang, defLang) {
    state.termLang = termLang;
    state.defLang = defLang;
    if (termSelect.value !== termLang) termSelect.value = termLang;
    if (defSelect.value !== defLang) defSelect.value = defLang;
    list.setLangs(termLang, defLang);
    changed();
  }

  function flipSides(withToast) {
    state.termTouched = true;
    state.defTouched = true;
    termAuto.hidden = true;
    defAuto.hidden = true;
    setLangs(state.defLang, state.termLang);
    list.swapSides();
    panel.reparse();
    if (withToast) {
      undoToast('Begriffe und Definitionen getauscht', { icon: 'swap', action: { label: 'Rückgängig', onClick: () => flipSides(false) } });
    }
  }

  // Detected languages fill the pickers unless the user has chosen them.
  function onDetected(result) {
    const nextTerm = !state.termTouched && knownLang(result.termLang) ? result.termLang : state.termLang;
    const nextDef = !state.defTouched && knownLang(result.defLang) ? result.defLang : state.defLang;
    if (nextTerm === nextDef || (nextTerm === state.termLang && nextDef === state.defLang)) return;
    if (nextTerm !== state.termLang) {
      termAuto.hidden = false;
      replay(termSelect, 'is-flash');
    }
    if (nextDef !== state.defLang) {
      defAuto.hidden = false;
      replay(defSelect, 'is-flash');
    }
    setLangs(nextTerm, nextDef);
  }

  async function applyImport(cards, { state: importState }) {
    const existing = list.stats().filled;
    let mode = 'replace';
    if (existing > 0) {
      mode = await chooseModal({
        title: 'Karten übernehmen',
        message: `Dein Lernset enthält schon ${plural(existing, 'Karte', 'Karten')}. Möchtest du die ${plural(cards.length, 'neue Karte', 'neuen Karten')} anhängen oder die bisherigen ersetzen?`,
        note: isEdit ? 'Beim Ersetzen bleibt der Lernfortschritt für gleiche Begriffe erhalten.' : null,
        actions: [
          { label: 'Ersetzen', variant: 'secondary', value: 'replace' },
          { label: 'Anhängen', variant: 'primary', value: 'append', autofocus: true },
        ],
      });
      if (!mode) return false;
    }
    const before = list.snapshot();
    const created =
      mode === 'append' ? list.appendCards(cards, { flash: true }) : list.setCards(isEdit ? withPreservedIds(cards, before) : cards, { flash: true });
    if (!cardsError.hidden) showCardsError(cardsMessage(list.stats()));
    undoToast(`${plural(cards.length, 'Karte', 'Karten')} übernommen`, {
      tone: 'success',
      action: {
        label: 'Rückgängig',
        onClick: () => {
          list.restore(before);
          panel.setState(importState);
          panel.setOpen(true);
          panel.scrollIntoView();
        },
      },
    });
    const target = mode === 'append' && created[0] ? created[0].el : cardsSection;
    requestAnimationFrame(() => {
      cardsTitle.focus({ preventScroll: true });
      target.scrollIntoView({ block: mode === 'append' ? 'center' : 'start', behavior: smooth() });
    });
    return true;
  }

  function undoToast(message, opts) {
    const handle = toast(message, opts);
    for (const t of undoToasts) if (t.el && !t.el.isConnected) undoToasts.delete(t);
    if (handle) undoToasts.add(handle);
    return handle;
  }

  function closeUndoToasts() {
    undoToasts.forEach((t) => t.close());
    undoToasts.clear();
    list.closeToasts();
  }

  /* -------------------------------------------------- status & validity */

  function changed() {
    if (rafId) return;
    rafId = hasRaf ? requestAnimationFrame(refresh) : setTimeout(refresh, 16);
  }

  function readiness(st) {
    if (!titleField.value.trim()) return 'Titel fehlt';
    if (!st.complete) return 'Noch keine vollständige Karte';
    return null;
  }

  // Uses the rows marked by the last validation, so a row that is still being
  // typed is not flagged before the next save attempt.
  function cardsMessage(st) {
    if (!st.complete) return 'Füge mindestens eine Karte mit Begriff und Definition hinzu.';
    if (st.invalid) {
      return `${plural(st.invalid, 'Karte ist', 'Karten sind')} unvollständig – ergänze Begriff und Definition oder lösche sie.`;
    }
    return null;
  }

  function showCardsError(message) {
    cardsError.hidden = !message;
    cardsError.replaceChildren(...(message ? [icon('alertCircle', { size: 16 }), h('span', null, message)] : []));
  }

  function refresh() {
    rafId = 0;
    const st = list.stats();
    if (state.attempted && !cardsError.hidden) showCardsError(cardsMessage(st));
    const count = plural(st.filled, 'Karte', 'Karten');
    headMeta.replaceChildren(
      h('span', null, count),
      h('span', { class: 'ed-head__pair' }, `${langShort(state.termLang)} → ${langShort(state.defLang)}`),
    );
    cardsCount.textContent = String(st.filled);
    cardsLead.hidden = st.filled > 0;

    const issues = [];
    if (st.duplicates) issues.push(chip({ label: `${plural(st.duplicates, 'Begriff', 'Begriffe')} doppelt`, tone: 'warning', icon: 'copy', size: 'sm' }));
    if (st.flagged) issues.push(chip({ label: `${st.flagged} bitte prüfen`, tone: 'warning', icon: 'alert', size: 'sm' }));
    if (st.invalid) issues.push(chip({ label: `${st.invalid} unvollständig`, tone: 'danger', icon: 'alertCircle', size: 'sm' }));
    cardsIssues.replaceChildren(...issues);

    const blocker = readiness(st);
    for (const btn of [headSave, dockSave]) {
      if (blocker) btn.setAttribute('aria-disabled', 'true');
      else btn.removeAttribute('aria-disabled');
      btn.title = blocker || '';
    }
    const extras = [];
    if (st.duplicates) extras.push(`${st.duplicates} doppelt`);
    if (st.invalid) extras.push(`${st.invalid} unvollständig`);
    fill(
      dockStatus,
      h('strong', { class: 'ed-dock__count' }, count),
      blocker ? h('span', { class: 'ed-dock__hint' }, blocker) : null,
      !blocker && extras.length ? h('span', { class: 'ed-dock__warn' }, extras.join(' · ')) : null,
    );
    syncUnsaved();
  }

  // The Windows app asks before its window closes while changes are not saved (the browser's
  // beforeunload does not run there). Only real changes are reported.
  function syncUnsaved(force = null) {
    const dirty = force == null ? isDirty() : force;
    if (dirty === reportedUnsaved) return;
    reportedUnsaved = dirty;
    reportUnsaved(dirty);
  }

  function validateAll() {
    state.attempted = true;
    const titleOk = !!titleField.value.trim();
    titleField.setError(titleOk ? null : 'Gib deinem Lernset einen Titel.');
    const firstInvalid = list.validate();
    const message = cardsMessage(list.stats());
    showCardsError(message);
    refresh();
    if (!titleOk) {
      titleField.focus({ preventScroll: true });
      titleField.scrollIntoView({ block: 'center', behavior: smooth() });
    } else if (firstInvalid) {
      list.focusField(firstInvalid);
    } else if (message) {
      list.focusFirst();
    }
    return titleOk && !message;
  }

  /* -------------------------------------------------------------- save */

  // A list still sitting in the import box is taken over before saving.
  async function takePendingImport() {
    const pending = panel.pendingCount();
    if (!pending) return true;
    if (list.isEmpty()) {
      list.setCards(panel.pendingCards());
    } else {
      const choice = await chooseModal({
        title: 'Liste noch nicht übernommen',
        message: `Im Importfeld ${pending === 1 ? 'wartet noch 1 erkanntes Paar' : `warten noch ${pending} erkannte Paare`}. Sollen sie vor dem Speichern angehängt werden?`,
        actions: [
          { label: 'Ohne Liste', variant: 'secondary', value: 'skip' },
          { label: `${plural(pending, 'Karte', 'Karten')} anhängen`, variant: 'primary', value: 'append', autofocus: true },
        ],
      });
      if (!choice) return false;
      if (choice === 'skip') return true;
      list.appendCards(panel.pendingCards());
    }
    panel.reset();
    panel.setOpen(false);
    return true;
  }

  async function save() {
    if (state.saving || state.saved || hasOpenModal()) return;
    if (panel.busy) {
      toast('Bitte warte, bis der Import fertig ist.');
      return;
    }
    if (!(await takePendingImport())) return;
    if (!validateAll()) return;

    state.saving = true;
    headSave.setLoading(true);
    dockSave.setLoading(true);
    const data = {
      title: titleField.value.trim(),
      description: descField.value.trim(),
      termLang: state.termLang,
      defLang: state.defLang,
      cards: list.getCards(),
    };
    let saved;
    try {
      saved = isEdit ? db.updateSet(setId, data) : db.createSet(data);
    } catch (err) {
      state.saving = false;
      headSave.setLoading(false);
      dockSave.setLoading(false);
      toast((err && err.message) || 'Das Lernset konnte nicht gespeichert werden.', { tone: 'danger', duration: 7000 });
      return;
    }
    state.saved = true;
    syncUnsaved(false);
    // An undo after saving would only change the editor that is being left.
    closeUndoToasts();
    setLeaveGuard(null);
    navigate(`/set/${encodeURIComponent(saved.id)}`);
    toast(isEdit ? 'Änderungen gespeichert' : 'Lernset erstellt', { tone: 'success' });
  }

  /* ------------------------------------------------- external changes */

  function load(set) {
    closeUndoToasts();
    titleField.value = set.title;
    descField.value = set.description;
    state.termLang = set.termLang;
    state.defLang = set.defLang;
    termSelect.value = set.termLang;
    defSelect.value = set.defLang;
    list.setLangs(set.termLang, set.defLang);
    list.setCards(set.cards);
    state.loadedAt = set.updatedAt;
    state.baseline = serialize();
    changed();
  }

  const unsubscribe = db.subscribe((event) => {
    if (!isEdit || state.saving || state.saved) return;
    if (event && Array.isArray(event.keys) && !event.keys.includes('sets')) return;
    const fresh = db.getSet(setId);
    if (!fresh) {
      state.saved = true;
      setLeaveGuard(null);
      toast('Dieses Lernset wurde gelöscht.', { tone: 'danger' });
      navigate('/', { replace: true });
      return;
    }
    if (fresh.updatedAt !== state.loadedAt && !isDirty()) {
      load(fresh);
      toast('Das Lernset wurde anderswo geändert – die neue Version ist geladen.');
    }
  });

  /* ---------------------------------------------------- global events */

  const onKeydown = (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && !isComposingKey(e)) {
      if (hasOpenModal()) return;
      e.preventDefault();
      save();
      return;
    }
    // Ctrl+S / ⌘S saves too (instead of the browser's «Seite speichern unter»).
    if (!isComposingKey(e) && commandKey(e, 's')) {
      e.preventDefault();
      if (!e.repeat && !hasOpenModal()) save();
    }
  };

  // Cmd/Ctrl+V of an image (screenshot, photo) anywhere on the page runs OCR.
  const onPaste = (e) => {
    const cd = e.clipboardData;
    if (!cd || hasOpenModal()) return;
    const text = cd.getData('text/plain');
    if (text && text.trim()) return;
    let files = Array.from(cd.files || []);
    if (!files.length && cd.items) {
      files = Array.from(cd.items)
        .filter((item) => item.kind === 'file')
        .map((item) => item.getAsFile())
        .filter(Boolean);
    }
    files = files.filter((f) => /^image\//.test(f.type || '') || f.type === 'application/pdf');
    if (!files.length) return;
    e.preventDefault();
    panel.handleFiles(files, { source: 'paste' });
    panel.scrollIntoView();
  };

  const onBeforeUnload = (e) => {
    if (!isDirty()) return;
    e.preventDefault();
    e.returnValue = '';
  };

  document.addEventListener('keydown', onKeydown);
  document.addEventListener('paste', onPaste);
  window.addEventListener('beforeunload', onBeforeUnload);

  setLeaveGuard(async () => {
    if (state.saved || !isDirty()) return true;
    const choice = await chooseModal({
      title: 'Änderungen verwerfen?',
      message: isEdit
        ? 'Deine Änderungen an diesem Lernset sind noch nicht gespeichert und gehen verloren.'
        : 'Dein neues Lernset ist noch nicht gespeichert und geht verloren.',
      className: ['ui-confirm', 'ui-confirm--danger'],
      actions: [
        { label: 'Weiter bearbeiten', variant: 'secondary', value: 'stay', autofocus: true },
        { label: 'Verwerfen', variant: 'danger', value: 'discard' },
      ],
    });
    return choice === 'discard';
  });

  // The floating save dock appears once the header button scrolls away (on
  // small screens the header button is hidden, so the dock is always shown).
  const docRoot = document.documentElement;
  function setDock(visible) {
    dock.dataset.visible = String(visible);
    dock.inert = !visible;
    if (visible) docRoot.setAttribute('data-ed-dock', '');
    else docRoot.removeAttribute('data-ed-dock');
  }
  let observer = null;
  if (typeof IntersectionObserver === 'function') {
    observer = new IntersectionObserver((entries) => setDock(!entries[entries.length - 1].isIntersecting), {
      rootMargin: '-64px 0px 0px 0px',
    });
    observer.observe(headSave);
  } else {
    setDock(true);
  }

  state.baseline = serialize();
  refresh();

  return () => {
    document.removeEventListener('keydown', onKeydown);
    document.removeEventListener('paste', onPaste);
    window.removeEventListener('beforeunload', onBeforeUnload);
    setLeaveGuard(null);
    reportedUnsaved = false;
    reportUnsaved(false);
    unsubscribe();
    if (observer) observer.disconnect();
    docRoot.removeAttribute('data-ed-dock');
    if (rafId) {
      if (hasRaf) cancelAnimationFrame(rafId);
      else clearTimeout(rafId);
    }
    closeUndoToasts();
    panel.destroy();
    list.destroy();
  };
}
