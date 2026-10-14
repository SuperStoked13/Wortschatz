// Prüfung › «Prüfung einrichten» (port of the Mac's ExamSetupView): how many words, the time
// limit, the direction, what a small mistake costs and (with starred cards) only the starred
// ones, with captions that follow every change, two notes and the bar with the summary pill,
// «Zurück zum Lernset» and «Prüfung starten». Also the empty state «Nichts zu prüfen».
// The view only reports changes; exam.js stores them and calls update().

import { h } from '../lib/dom.js';
import { button, segmented, selectField, toggle, emptyState } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { sideNames, directionText } from '../ui/study-options.js';
import * as E from '../core/exam.js';

// The bar at the bottom of every exam page: something on the left, the actions on the right,
// ending with the page's main action. `above`: what floats over it (the sheet's accents).
export function examDock({ leading = [], trailing = [], above = null, className = '' }) {
  return h(
    'div',
    { class: ['ex-dock', className] },
    above,
    h('div', { class: 'ex-bar' }, h('div', { class: 'ex-bar__lead' }, leading), h('div', { class: 'ex-bar__trail' }, trailing)),
  );
}

// A quiet pill on the left of the bar ("20 Wörter · 10 Minuten").
export function examPill(...children) {
  return h('div', { class: 'ex-pill' }, children);
}

// Button label with a shorter form for narrow bars (the long one stays the accessible name).
export function compactLabel(btn, long, short) {
  const label = btn.querySelector('.ui-btn__label');
  if (!label || !short) return btn;
  label.replaceChildren(h('span', { class: 'ex-long' }, long), h('span', { class: 'ex-short', 'aria-hidden': 'true' }, short));
  btn.setAttribute('aria-label', long);
  return btn;
}

function settingRow({ key, iconName, title, tooltip }) {
  const titleEl = h('span', { class: 'ex-set__title', id: `ex-set-${key}` }, title);
  const caption = h('span', { class: 'ex-set__caption', id: `ex-set-${key}-caption` });
  const control = h('div', { class: 'ex-set__control' });
  const el = h(
    'div',
    { class: 'ex-set', dataset: { key } },
    h(
      'div',
      { class: 'ex-set__label', 'data-tooltip': tooltip || null },
      h('span', { class: 'ex-set__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 16, strokeWidth: 2 })),
      h('span', { class: 'ex-set__text' }, titleEl, caption),
    ),
    control,
  );
  return {
    el,
    titleEl,
    caption,
    control,
    setCaption(text) {
      if (caption.textContent !== text) caption.textContent = text;
    },
    setControl(next) {
      control.replaceChildren(next);
    },
  };
}

// Gives the control of a row the row's title and caption as its name and description.
function describe(el, key) {
  el.setAttribute('aria-labelledby', `ex-set-${key}`);
  el.setAttribute('aria-describedby', `ex-set-${key}-caption`);
  return el;
}

/**
 * model: { set, settings }
 * on: { change(patch), start(), back() }
 * Returns { el, dock, update(model), focusPrimary() }.
 */
export function setupView(model, on) {
  let set = model.set;
  let settings = model.settings;

  // ---------------------------------------------------------------- header
  const header = h(
    'header',
    { class: 'ex-setup__head' },
    h('span', { class: 'ex-setup__badge', 'aria-hidden': 'true' }, icon('graduationCap', { size: 36, strokeWidth: 1.9 })),
    h('p', { class: 'ex-eyebrow' }, 'Prüfungsmodus'),
    h('h1', { class: 'ex-setup__title' }, 'Prüfung einrichten'),
    h('p', { class: 'ex-setup__text' }, 'Alle Fragen auf einer Seite, mit Zeitlimit und einer Note wie in der Schule.'),
  );

  // ------------------------------------------------------------------ rows
  const countRow = settingRow({ key: 'count', iconName: 'list', title: 'Wörter' });
  const timeRow = settingRow({ key: 'time', iconName: 'clock', title: 'Zeitlimit' });
  const dirRow = settingRow({ key: 'direction', iconName: 'swap', title: 'Antworten auf' });
  const tolRow = settingRow({ key: 'tolerance', iconName: 'checkCircle', title: 'Kleine Fehler', tooltip: E.SMALL_MISTAKES_TEXT });
  const starRow = settingRow({ key: 'starred', iconName: 'star', title: E.starredLabel(0) });
  starRow.setCaption(E.STARRED_CAPTION);

  const card = h('section', { class: 'ex-setup__card', 'aria-label': 'Einstellungen der Prüfung' }, countRow.el, timeRow.el, dirRow.el, tolRow.el, starRow.el);

  // Wörter: rebuilt only when the choices change (another starred filter, cards added).
  let countSeg = null;
  let countSig = '';
  // Antworten auf: the side names follow the set's languages.
  let dirSeg = null;
  let dirSig = '';

  const timeSelect = selectField({
    size: 'sm',
    ariaLabel: 'Zeitlimit',
    value: settings.minutes,
    options: E.MINUTE_CHOICES.map((m) => ({ value: m, label: E.minuteChoiceLabel(m) })),
    onChange: (v) => on.change({ minutes: Number(v) }),
  });
  describe(timeSelect.select, 'time');
  timeRow.setControl(timeSelect);

  const tolSeg = describe(
    segmented({
      ariaLabel: 'Kleine Fehler',
      value: settings.tolerance,
      options: E.TOLERANCES.map((t) => ({ value: t, label: E.toleranceTitle(t) })),
      onChange: (v) => on.change({ tolerance: v }),
    }),
    'tolerance',
  );
  tolRow.setControl(tolSeg);

  const starToggle = toggle({ ariaLabel: 'Nur markierte', checked: settings.starredOnly, onChange: (v) => on.change({ starredOnly: v }) });
  starToggle.input.setAttribute('aria-describedby', 'ex-set-starred-caption');
  starRow.setControl(starToggle);

  const notes = h(
    'div',
    { class: 'ex-setup__notes' },
    h('p', { class: 'ex-note' }, icon('info', { size: 16 }), h('span', null, E.SMALL_MISTAKES_TEXT)),
    h('p', { class: 'ex-note' }, icon('sparkles', { size: 16 }), h('span', null, E.NOT_MASTERY_NOTE)),
  );

  // ------------------------------------------------------------------- bar
  const summary = h('span', { class: 'ex-pill__text' });
  const back = button({ label: 'Zurück zum Lernset', variant: 'secondary', kbd: 'Esc', onClick: () => on.back() });
  compactLabel(back, 'Zurück zum Lernset', 'Zurück');
  const start = button({
    label: 'Prüfung starten',
    icon: 'graduationCap',
    variant: 'primary',
    kbd: '↵',
    onClick: () => on.start(),
    attrs: { 'data-primary': 'true', class: 'ex-start' },
  });
  compactLabel(start, 'Prüfung starten', 'Starten');
  const dock = examDock({
    leading: [examPill(icon('list', { size: 16 }), summary)],
    trailing: [back, start],
  });

  const body = h('div', { class: 'ex-col ex-col--setup' }, header, card, notes);
  const el = h('div', { class: 'ex-page ex-setup ex-enter' }, body, dock);

  // Puts focus back into the row it was in after a control was rebuilt.
  function keepFocus(row, rebuild) {
    const had = row.control.contains(document.activeElement);
    rebuild();
    if (!had) return;
    const target = row.control.querySelector('[aria-checked="true"]') || row.control.querySelector('button, input, select');
    if (target) target.focus({ preventScroll: true });
  }

  function update(next = {}) {
    if (next.set) set = next.set;
    if (next.settings) settings = next.settings;
    const scope = E.examScope(set.cards, settings);
    const available = scope.length;
    const planned = E.plannedCount(set.cards, settings);

    // Wörter
    const choices = E.countChoicesFor(available);
    const sig = `${available}|${choices.join(',')}`;
    if (sig !== countSig) {
      countSig = sig;
      keepFocus(countRow, () => {
        countSeg = describe(
          segmented({
            ariaLabel: 'Wörter',
            value: E.countSelection(settings, available),
            options: choices.map((c) => ({ value: c, label: E.countChoiceLabel(c, available) })),
            onChange: (v) => on.change({ count: v }),
          }),
          'count',
        );
        countRow.setControl(countSeg);
      });
    } else {
      countSeg.setValue(E.countSelection(settings, available));
    }
    countRow.setCaption(E.countCaption(planned, available));

    // Zeitlimit
    if (timeSelect.value !== String(settings.minutes)) timeSelect.value = settings.minutes;
    timeRow.setCaption(E.timeCaption(settings.minutes, planned));

    // Antworten auf
    const names = sideNames(set.termLang, set.defLang);
    const dsig = `${names.term.label}|${names.definition.label}`;
    if (dsig !== dirSig) {
      dirSig = dsig;
      keepFocus(dirRow, () => {
        dirSeg = describe(
          segmented({
            ariaLabel: 'Antworten auf',
            value: settings.answerWith,
            options: [
              { value: 'term', label: names.term.label },
              { value: 'definition', label: names.definition.label },
              { value: 'both', label: 'Beides' },
            ],
            onChange: (v) => on.change({ answerWith: v }),
          }),
          'direction',
        );
        dirRow.setControl(dirSeg);
      });
    } else {
      dirSeg.setValue(settings.answerWith);
    }
    dirRow.setCaption(directionText(settings.answerWith, set.termLang, set.defLang, 'learn'));

    // Kleine Fehler
    tolSeg.setValue(settings.tolerance);
    tolRow.setCaption(E.toleranceText(settings.tolerance));

    // Nur markierte (only with starred cards)
    const starred = E.starredCount(set.cards);
    starRow.el.hidden = starred === 0;
    starRow.titleEl.textContent = E.starredLabel(starred);
    if (starToggle.checked !== settings.starredOnly) starToggle.setChecked(settings.starredOnly);

    summary.textContent = E.setupSummary(planned, settings.minutes);
  }

  update();

  return {
    el,
    dock,
    update,
    focusPrimary() {
      start.focus({ preventScroll: true });
    },
  };
}

// The set has no card with both sides filled in.
export function emptyView({ setId, onBack }) {
  const back = button({ label: 'Zurück zum Lernset', variant: 'secondary', kbd: 'Esc', onClick: () => onBack() });
  const add = button({ label: 'Begriffe hinzufügen', icon: 'plus', variant: 'primary', href: `#/set/${encodeURIComponent(setId)}/edit`, attrs: { 'data-primary': 'true' } });
  const el = h(
    'div',
    { class: 'ex-page ex-empty ex-enter' },
    h(
      'div',
      { class: 'ex-col ex-col--setup' },
      emptyState({
        icon: 'graduationCap',
        title: 'Nichts zu prüfen',
        text: 'Dieses Lernset hat noch keine Begriffe mit Übersetzung. Füge welche hinzu, dann geht es los.',
        action: h('div', { class: 'ex-empty__actions' }, back, add),
      }),
    ),
  );
  return {
    el,
    focusPrimary() {
      add.focus({ preventScroll: true });
    },
  };
}
