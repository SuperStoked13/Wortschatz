// Prüfung › the marked exam (port of the Mac's ExamResultsView): the Swiss grade in a large
// circle with the verdict, the points and the time, the counts as tiles, and every answer with
// its mark (what was typed with the mistakes marked, the right answer, a note and the points).
// The bar offers «Neue Prüfung», «Falsche lernen», «Falsche prüfen» and «Fertig».

import { h } from '../lib/dom.js';
import { textAttrs, fieldAttrs } from '../lib/labels.js';
import { button, chip } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { isApplePlatform } from './editor-util.js';
import { confetti } from './write-views.js';
import { examDock, compactLabel } from './exam-setup.js';
import * as E from '../core/exam.js';

function hero(result) {
  const grade = result.grade;
  const circle = h(
    'div',
    { class: ['ex-grade', `ex-grade--${E.gradeTone(grade)}`], role: 'img', 'aria-label': `Note ${E.gradeText(grade)}` },
    h('span', { class: 'ex-grade__label', 'aria-hidden': 'true' }, 'Note'),
    h('span', { class: 'ex-grade__value', 'aria-hidden': 'true' }, E.gradeText(grade)),
  );
  const wrap = h('div', { class: 'ex-grade-wrap' }, circle);
  if (E.celebrates(grade)) {
    const burst = confetti();
    if (burst) wrap.append(burst);
  }
  const title = h('h1', { class: 'ex-res__title', tabindex: '-1' }, E.verdict(grade));
  return {
    el: h(
      'header',
      { class: 'ex-res__hero' },
      wrap,
      title,
      h('p', { class: 'ex-res__text' }, E.resultSubtitle(result)),
      result.timedOut ? h('p', { class: 'ex-res__timeout' }, icon('clock', { size: 16, strokeWidth: 2 }), h('span', null, E.TIMED_OUT_LINE)) : null,
    ),
    title,
  };
}

function tile({ value, label, caption, iconName, tone }) {
  return h(
    'div',
    { class: ['ex-tile', `ex-tile--${tone}`] },
    h('span', { class: 'ex-tile__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 16, strokeWidth: 2.25 })),
    h('span', { class: 'ex-tile__value' }, String(value)),
    h('span', { class: 'ex-tile__label' }, label),
    h('span', { class: 'ex-tile__caption' }, caption),
  );
}

function tiles(result) {
  const blank = E.markCount(result, 'blank');
  return h(
    'div',
    { class: ['ex-tiles', blank > 0 && 'ex-tiles--four'] },
    tile({ value: E.markCount(result, 'correct'), label: 'Richtig', caption: 'ganzer Punkt', iconName: 'check', tone: 'success' }),
    tile({ value: E.markCount(result, 'minor'), label: 'Kleine Fehler', caption: E.minorCaption(result.tolerance), iconName: 'checkCircle', tone: 'info' }),
    tile({ value: E.markCount(result, 'wrong'), label: 'Falsch', caption: 'kein Punkt', iconName: 'x', tone: 'danger' }),
    blank > 0 ? tile({ value: blank, label: 'Ohne Antwort', caption: 'kein Punkt', iconName: 'minus', tone: 'muted' }) : null,
  );
}

const BADGE_ICONS = { correct: 'check', wrong: 'x', blank: 'minus' };

function markBadge(item) {
  const kind = E.markBadge(item);
  return h(
    'span',
    { class: ['ex-mark', `ex-mark--${kind}`] },
    kind === 'half' ? h('span', { 'aria-hidden': 'true' }, '½') : icon(BADGE_ICONS[kind], { size: 14, strokeWidth: 2.5 }),
    h('span', { class: 'sr-only' }, `${E.markLabel(item)}.`),
  );
}

// What was typed, with the mistakes marked against the answer it was compared with (a
// synonym's own word when it matched another card). Its direction follows the text, as in
// the field.
function diffLine(item) {
  const q = item.question;
  const attrs = fieldAttrs(q.answerLang);
  const parts = E.answerDiff(item.given, item.matched != null ? item.matched : q.expected, q.answerLang);
  if (!parts) return h('p', { class: 'ex-answer ex-answer--wrong', ...attrs }, item.given);
  return h(
    'p',
    { class: 'ex-answer', ...attrs },
    h('span', { class: 'sr-only' }, item.given),
    h(
      'span',
      { 'aria-hidden': 'true' },
      parts.map((p) => (p.type === 'same' ? p.text : h(p.type === 'del' ? 'del' : 'ins', { class: `ex-diff ex-diff--${p.type}` }, p.text))),
    ),
  );
}

function answerRow(item) {
  const q = item.question;
  let answer;
  if (item.mark === 'correct') answer = h('p', { class: 'ex-answer ex-answer--right', ...fieldAttrs(q.answerLang) }, item.given);
  else if (item.mark === 'blank') answer = h('p', { class: 'ex-answer ex-answer--none' }, 'Keine Antwort');
  else answer = diffLine(item);
  const expected = E.showsExpected(item)
    ? h(
        'p',
        { class: 'ex-expected' },
        h('span', { class: 'ex-expected__label' }, E.expectedLabel(item)),
        ' ',
        h('strong', { class: 'ex-expected__text', ...textAttrs(q.answerLang) }, q.expected),
      )
    : null;
  let note = null;
  if (item.note) {
    const info = E.noteTone(item) === 'info';
    note = chip({ label: item.note, tone: info ? 'neutral' : 'warning', icon: info ? 'info' : 'lightbulb', size: 'sm' });
    if (info) note.classList.add('ex-chip--info');
  }
  return h(
    'li',
    { class: ['ex-item', `ex-item--${E.markBadge(item)}`] },
    markBadge(item),
    h(
      'div',
      { class: 'ex-item__body' },
      h(
        'p',
        { class: 'ex-item__ask' },
        h('span', { class: 'ex-item__num' }, `${q.number}.`),
        ' ',
        h('span', { class: 'ex-item__prompt', ...textAttrs(q.promptLang) }, q.prompt),
      ),
      answer,
      expected,
      note ? h('div', { class: 'ex-item__note' }, note) : null,
    ),
    h(
      'span',
      { class: ['ex-item__points', item.points > 0 && 'is-scored'] },
      h('span', { 'aria-hidden': 'true' }, E.itemPointsText(item)),
      h('span', { class: 'sr-only' }, E.itemPointsLabel(item)),
    ),
  );
}

function answerList(result) {
  return h(
    'section',
    { class: 'ex-answers', 'aria-labelledby': 'ex-answers-title' },
    h(
      'div',
      { class: 'ex-answers__head' },
      h('h2', { class: 'ex-answers__title', id: 'ex-answers-title' }, 'Deine Antworten'),
      h('p', { class: 'ex-answers__rule', 'data-tooltip': E.SMALL_MISTAKES_TEXT, tabindex: '0' }, E.toleranceText(result.tolerance)),
    ),
    h('ol', { class: 'ex-answers__list' }, result.items.map(answerRow)),
  );
}

/**
 * on: { newExam(), learn(), retake(), done() }
 * Returns { el, dock, focusPrimary(), focusTitle() }.
 */
export function resultsView(result, on) {
  const toPractise = E.cardIdsToPractise(result).length;
  const head = hero(result);

  const again = button({
    label: 'Neue Prüfung',
    icon: 'rotate',
    variant: 'secondary',
    onClick: () => on.newExam(),
    attrs: {
      'data-tooltip': `Neue Prüfung (${isApplePlatform() ? '⇧⌘R' : 'Strg+⇧+R'})`,
      'aria-keyshortcuts': isApplePlatform() ? 'Shift+Meta+R' : 'Control+Shift+R',
    },
  });
  compactLabel(again, 'Neue Prüfung', 'Neu');
  const trailing = [];
  if (toPractise > 0) {
    const learn = button({
      label: 'Falsche lernen',
      icon: 'sparkles',
      variant: 'secondary',
      onClick: () => on.learn(),
      attrs: { 'data-tooltip': E.learnMistakesTooltip(toPractise) },
    });
    const retake = button({
      label: 'Falsche prüfen',
      icon: 'graduationCap',
      variant: 'secondary',
      onClick: () => on.retake(),
      attrs: { 'data-tooltip': E.retakeMistakesTooltip(toPractise) },
    });
    trailing.push(compactLabel(learn, 'Falsche lernen', 'Lernen'), compactLabel(retake, 'Falsche prüfen', 'Prüfen'));
  }
  const done = button({ label: 'Fertig', variant: 'primary', kbd: '↵', onClick: () => on.done(), attrs: { 'data-primary': 'true', class: 'ex-done' } });
  trailing.push(done);
  const dock = examDock({ leading: [again], trailing, className: 'ex-dock--results' });

  const body = h('div', { class: 'ex-col' }, head.el, tiles(result), answerList(result));
  const el = h('div', { class: 'ex-page ex-res ex-enter' }, body, dock);
  return {
    el,
    dock,
    focusPrimary() {
      done.focus({ preventScroll: true });
    },
    // After the time ran out: focus rests on the verdict, so a key meant for the sheet presses
    // nothing (↵ reaches «Fertig» through the screen's keys once the hold is over).
    focusTitle() {
      head.title.focus({ preventScroll: true });
    },
  };
}
