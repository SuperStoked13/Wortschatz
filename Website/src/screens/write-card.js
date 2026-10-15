// Write mode question card: prompt, answer field, special characters and the
// correct / incorrect feedback states. The answer <input> is created once and
// kept in place for the whole session, so focus (and the on-screen keyboard on
// phones) survives from one question to the next. The prompt's head (language,
// Vorlesen, Bearbeiten, Markieren) is built once too; the screens add the
// answer-streak flame there.

import { h, replayClass, setTextAttrs } from '../lib/dom.js';
import { bcp47, textAttrs, fieldAttrs } from '../lib/labels.js';
import { charsFor, insertAtCaret } from '../lib/keyboard.js';
import { canSpeak } from '../lib/speech.js';
import { diffAnswer, splitAlternatives } from '../core/grading.js';
import { button, iconButton, starButton, chip, kbd } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { charColumns } from './write-model.js';
import { shortcutAria } from './write-keys.js';
import { isApplePlatform } from './editor-util.js';

let uidCounter = 0;

// Special-character keys per row on phones; touch screens too narrow for that many
// 40px keys drop to one fewer per row (the tight layout in write.css).
const CHAR_KEYS_PER_ROW = 8;

// Below this width the long placeholders ("Antwort auf Französisch eingeben") are cut off.
const NARROW_QUERY = '(max-width: 479px)';
const COPY_PLACEHOLDER = { long: 'Richtige Antwort abtippen', short: 'Antwort abtippen' };

const speakable = (lang) => canSpeak() && !!bcp47(lang);

// MediaQueryList change events (addListener: Safari before 14).
function listen(mql, fn) {
  if (typeof mql.addEventListener === 'function') mql.addEventListener('change', fn);
  else if (typeof mql.addListener === 'function') mql.addListener(fn);
}

function unlisten(mql, fn) {
  if (typeof mql.removeEventListener === 'function') mql.removeEventListener('change', fn);
  else if (typeof mql.removeListener === 'function') mql.removeListener(fn);
}

// replaceChildren() would turn null into the text "null".
function fill(el, ...children) {
  el.replaceChildren(...children.flat().filter((c) => c != null && c !== false));
}

// Mouse/touch presses on these controls must not steal focus from the answer field.
function keepFocus(el) {
  el.addEventListener('mousedown', (e) => e.preventDefault());
  return el;
}

// Diff against whichever accepted variant is closest to what was typed, so a
// small slip in "le monsieur" is not drowned by the missing ", messieurs".
// diffAnswer folds what grading treats as equal (ss/ß, apostrophes, spaces, œ,
// Arabic vowel marks; Chinese tone numbers and the characters or pinyin part).
// `lang` (app code) lets splitAlternatives read German noun lists.
function closestDiff(given, expected, lang) {
  const candidates = new Set([expected]);
  try {
    for (const alt of splitAlternatives(expected, lang)) if (alt) candidates.add(alt);
  } catch {
    /* fall back to the full answer */
  }
  let best = null;
  let bestCost = Infinity;
  for (const target of candidates) {
    const parts = diffAnswer(given, target, lang);
    const cost = parts.reduce((n, p) => n + (p.type === 'same' ? 0 : p.text.length), 0);
    if (cost < bestCost) {
      best = parts;
      bestCost = cost;
    }
  }
  return best || [];
}

// What was typed (`lang`: app code) takes its direction from the text, as in the field.
function diffView(given, expected, lang) {
  const parts = closestDiff(given, expected, lang);
  // A character diff only helps for near misses; for a different word it is noise.
  const same = parts.reduce((n, p) => n + (p.type === 'same' ? p.text.replace(/\s/g, '').length : 0), 0);
  const typed = given.replace(/\s/g, '').length;
  const attrs = fieldAttrs(lang);
  if (typed === 0 || same / typed < 0.5) {
    return h('p', { class: 'wr-diff wr-diff--plain', ...attrs }, given);
  }
  return h(
    'p',
    { class: 'wr-diff', ...attrs },
    h('span', { class: 'sr-only' }, given),
    h(
      'span',
      { 'aria-hidden': 'true' },
      parts.map((p) => {
        if (p.type === 'same') return p.text;
        return h(p.type === 'del' ? 'del' : 'ins', { class: `wr-diff__${p.type}` }, p.text);
      }),
    ),
  );
}

/**
 * handlers: {
 *   onSubmit(value), onDontKnow(), onContinue(), onCopySubmit(value),
 *   onOverride(), onEdit(), onToggleStar() -> boolean, onSpeak(text, lang)
 * }
 * labels (optional, e.g. for Learn mode): {
 *   dontKnow: the "Weiss ich nicht" button, miss: the title after a wrong answer
 * }
 */
export function createCard(handlers, { dontKnow: dontKnowLabel = 'Weiss ich nicht', miss: missTitle = 'Nicht ganz.' } = {}) {
  const n = ++uidCounter;
  const promptId = `wr-prompt-${n}`;
  const inputId = `wr-input-${n}`;
  const noteId = `wr-note-${n}`;

  let q = null; // current question info (see write.js questionInfo)
  let phase = 'question';
  let editable = true;
  let charsLang = null;
  let placeholders = { long: '', short: '' };
  const narrow = typeof matchMedia === 'function' ? matchMedia(NARROW_QUERY) : null;

  // ---------------------------------------------------------------- prompt
  const langLabel = h('span', { class: 'wr-q__lang' });
  const speakPrompt = keepFocus(
    iconButton({ icon: 'volume', label: 'Vorlesen', size: 'sm', onClick: () => q && handlers.onSpeak(q.prompt, q.promptLang) }),
  );
  const editBtn = keepFocus(iconButton({ icon: 'edit', label: 'Karte bearbeiten', size: 'sm', onClick: () => handlers.onEdit() }));
  const star = keepFocus(
    starButton({
      size: 'sm',
      label: 'Markieren',
      labelActive: 'Markierung entfernen',
      onToggle: () => handlers.onToggleStar(),
    }),
  );
  const promptText = h('p', { class: 'wr-q__prompt', id: promptId });
  const promptBlock = h(
    'div',
    { class: 'wr-q' },
    h('div', { class: 'wr-q__head' }, langLabel, h('div', { class: 'wr-q__tools' }, speakPrompt, editBtn, star)),
    promptText,
  );

  // ------------------------------------------------------- feedback panel
  const feedback = h('div', { class: 'wr-fb', hidden: true });

  // ----------------------------------------------------------- answer area
  const answerLabel = h('label', { class: 'wr-answer__label', for: inputId });
  const input = h('input', {
    id: inputId,
    class: 'wr-input',
    type: 'text',
    autocomplete: 'off',
    autocorrect: 'off',
    autocapitalize: 'off',
    spellcheck: 'false',
    enterkeyhint: 'go',
    'aria-describedby': promptId,
  });
  const badge = h('span', { class: 'wr-field__badge', 'aria-hidden': 'true' }, icon('check', { size: 20, strokeWidth: 2.5 }));
  const field = h('div', { class: 'wr-field' }, input, badge);
  const chars = h('div', { class: 'wr-chars', role: 'group', 'aria-label': 'Sonderzeichen einfügen' });
  const note = h('div', { class: 'wr-answer__note', id: noteId, hidden: true });
  const answer = h('div', { class: 'wr-answer' }, answerLabel, field, chars, note);

  // Edits are only allowed while the user is expected to type.
  input.addEventListener('beforeinput', (e) => {
    if (!editable) e.preventDefault();
  });
  input.addEventListener('input', () => {
    if (input.getAttribute('aria-invalid') === 'true') input.removeAttribute('aria-invalid');
  });

  // -------------------------------------------------------------- actions
  const actions = h('div', { class: 'wr-actions' });
  const timer = h('span', { class: 'wr-timer', 'aria-hidden': 'true' });

  const el = h('section', { class: 'wr-card', 'aria-label': 'Abfrage', dataset: { phase: 'question' } }, promptBlock, feedback, answer, actions, timer);

  // ------------------------------------------------------------- helpers
  function setPhase(next) {
    phase = next;
    el.dataset.phase = next;
  }

  function setEditable(on) {
    editable = on;
    if (on) input.removeAttribute('aria-readonly');
    else input.setAttribute('aria-readonly', 'true');
  }

  function renderChars(lang) {
    if (lang === charsLang) return;
    charsLang = lang;
    const list = charsFor(lang);
    chars.replaceChildren(
      ...list.map((ch) =>
        keepFocus(
          h(
            'button',
            {
              type: 'button',
              class: 'wr-char',
              tabindex: '-1',
              title: 'Mit Umschalttaste als Grossbuchstabe',
              onClick: (e) => {
                if (!editable) return;
                insertAtCaret(input, e.shiftKey ? ch.toUpperCase() : ch);
              },
            },
            ch,
          ),
        ),
      ),
    );
    chars.hidden = list.length === 0;
    // Phones lay the keys out in balanced rows (write.css).
    chars.style.setProperty('--wr-chars-cols', String(charColumns(list.length, CHAR_KEYS_PER_ROW)));
    chars.style.setProperty('--wr-chars-cols-tight', String(charColumns(list.length, CHAR_KEYS_PER_ROW - 1)));
  }

  function fillPrompt() {
    langLabel.textContent = q.promptLabel;
    promptText.textContent = q.prompt;
    setTextAttrs(promptText, textAttrs(q.promptLang));
    promptText.classList.toggle('is-long', q.prompt.length > 60);
    promptText.classList.toggle('is-very-long', q.prompt.length > 140);
    speakPrompt.hidden = !speakable(q.promptLang);
    star.setStarred(!!q.starred);
  }

  function applyPlaceholder() {
    input.placeholder = narrow && narrow.matches ? placeholders.short || placeholders.long : placeholders.long;
  }

  // Screen readers always get the full placeholder text.
  function prepareInput({ placeholder, label }) {
    placeholders = placeholder;
    answerLabel.replaceChildren(label);
    answerLabel.className = 'wr-answer__label';
    input.value = '';
    applyPlaceholder();
    setTextAttrs(input, fieldAttrs(q.answerLang));
    input.removeAttribute('aria-invalid');
    input.setAttribute('aria-label', `${label}: ${placeholder.long}`);
    renderChars(q.answerLang);
    setEditable(true);
  }

  const questionPlaceholder = () => ({ long: q.placeholder, short: q.placeholderShort || q.placeholder });

  function enterHint(text) {
    return h('span', { class: 'wr-hint' }, kbd('Enter ↵'), h('span', { class: 'wr-hint__text' }, text));
  }

  function primary(label, onClick, extra = {}) {
    return button({ label, variant: 'primary', onClick, ...extra });
  }

  function stopTimer() {
    timer.classList.remove('is-running');
    timer.style.removeProperty('--wr-advance');
  }

  // ------------------------------------------------------------- phases
  function setQuestion(question, { animate = true } = {}) {
    q = question;
    setPhase('question');
    stopTimer();
    fillPrompt();
    feedback.hidden = true;
    feedback.replaceChildren();
    answer.hidden = false;
    chars.hidden = false;
    note.hidden = true;
    note.replaceChildren();
    prepareInput({ placeholder: questionPlaceholder(), label: 'Deine Antwort' });
    chars.hidden = charsFor(q.answerLang).length === 0;
    actions.replaceChildren(
      keepFocus(
        button({
          label: dontKnowLabel,
          variant: 'ghost',
          onClick: () => handlers.onDontKnow(),
          attrs: { class: 'wr-actions__dont', 'aria-keyshortcuts': shortcutAria('dontKnow', isApplePlatform()) },
        }),
      ),
      h('span', { class: 'wr-actions__spacer' }),
      enterHint('zum Antworten'),
      keepFocus(primary('Antworten', () => handlers.onSubmit(input.value))),
    );
    if (animate) replayClass(promptBlock, 'is-swapping');
    focus();
  }

  // notes: [{ label, tone }] chips; exactLabel introduces result.expectedDisplay.
  function showCorrect({ praise, result, autoAdvanceMs = 0, notes = [], exactLabel = 'Genau:' }) {
    setPhase('correct');
    setEditable(false);
    chars.hidden = true;
    answerLabel.className = 'wr-answer__label wr-answer__label--ok';
    answerLabel.replaceChildren(icon('checkCircle', { size: 18, strokeWidth: 2 }), h('span', null, praise));
    replayClass(answerLabel, 'ui-anim-pop');

    const showExact = result && !result.exact && result.expectedDisplay;
    fill(
      note,
      showExact
        ? h(
            'p',
            { class: 'wr-answer__exact' },
            h('span', { class: 'wr-answer__exact-label' }, exactLabel),
            ' ',
            h('strong', textAttrs(q.answerLang), result.expectedDisplay),
          )
        : null,
      notes.length ? h('div', { class: 'wr-chips' }, notes.map(({ label, tone }) => chip({ label, tone, size: 'sm' }))) : null,
    );
    note.hidden = !showExact && !notes.length;

    const continueBtn = keepFocus(
      button({
        label: 'Weiter',
        variant: autoAdvanceMs ? 'secondary' : 'primary',
        iconRight: 'arrowRight',
        onClick: () => handlers.onContinue(),
      }),
    );
    fill(
      actions,
      h('span', { class: 'wr-hint wr-hint--solo' }, autoAdvanceMs ? 'Weiter mit beliebiger Taste' : null, autoAdvanceMs ? null : kbd('Enter ↵'), autoAdvanceMs ? null : h('span', { class: 'wr-hint__text' }, 'zum Weitermachen')),
      h('span', { class: 'wr-actions__spacer' }),
      continueBtn,
    );
    if (autoAdvanceMs > 0) {
      timer.style.setProperty('--wr-advance', `${autoAdvanceMs}ms`);
      timer.classList.remove('is-running');
      void timer.offsetWidth;
      timer.classList.add('is-running');
    } else {
      stopTimer();
    }
    focus();
  }

  // opts: { given, dontKnow, hintLabel, copy, canOverride, editedCorrect }
  function showIncorrect({ given = '', dontKnow = false, hintLabel = null, copy = false, canOverride = false, editedCorrect = false }) {
    setPhase('incorrect');
    stopTimer();

    const head = h(
      'div',
      { class: ['wr-fb__head', dontKnow && 'wr-fb__head--calm'] },
      h('span', { class: 'wr-fb__icon', 'aria-hidden': 'true' }, icon(dontKnow ? 'lightbulb' : 'x', { size: 18, strokeWidth: 2.25 })),
      h('h2', { class: 'wr-fb__title' }, dontKnow ? 'Kein Problem – merk dir das:' : missTitle),
      hintLabel && !editedCorrect ? chip({ label: hintLabel, tone: 'warning', icon: 'lightbulb', size: 'sm' }) : null,
    );

    const rows = h('div', { class: 'wr-fb__rows' });
    if (given && !dontKnow) {
      rows.append(
        h(
          'div',
          { class: 'wr-fb__row wr-fb__row--given' },
          h('span', { class: 'wr-fb__label' }, 'Deine Antwort'),
          diffView(given, q.expected, q.answerLang),
        ),
      );
    }
    const speakAnswer = speakable(q.answerLang)
      ? keepFocus(iconButton({ icon: 'volume', label: 'Antwort vorlesen', size: 'sm', onClick: () => handlers.onSpeak(q.expected, q.answerLang) }))
      : null;
    rows.append(
      h(
        'div',
        { class: 'wr-fb__row wr-fb__row--answer' },
        h('span', { class: 'wr-fb__label' }, 'Richtige Antwort'),
        h('div', { class: 'wr-fb__answer' }, h('p', { class: 'wr-fb__expected', ...textAttrs(q.answerLang) }, q.expected), speakAnswer),
      ),
    );

    fill(
      feedback,
      head,
      rows,
      editedCorrect
        ? h(
            'p',
            { class: 'wr-fb__edited', role: 'status' },
            icon('checkCircle', { size: 16 }),
            'Mit deiner Korrektur stimmt deine Antwort jetzt.',
          )
        : null,
    );
    feedback.hidden = false;
    replayClass(feedback, 'is-revealing');

    const tools = [];
    if (canOverride) {
      tools.push(
        keepFocus(
          button({
            label: editedCorrect ? 'Als richtig zählen' : 'Ich hatte recht',
            icon: 'check',
            variant: editedCorrect ? 'success' : 'ghost',
            size: 'sm',
            onClick: () => handlers.onOverride(),
            attrs: { 'aria-keyshortcuts': shortcutAria('override', isApplePlatform()) },
          }),
        ),
      );
    }
    tools.push(keepFocus(button({ label: 'Bearbeiten', icon: 'edit', variant: 'ghost', size: 'sm', onClick: () => handlers.onEdit() })));
    const toolGroup = h('div', { class: 'wr-actions__tools' }, tools);

    if (copy) {
      answer.hidden = false;
      note.hidden = true;
      note.replaceChildren();
      prepareInput({ placeholder: COPY_PLACEHOLDER, label: 'Tippe die richtige Antwort ab' });
      chars.hidden = charsFor(q.answerLang).length === 0;
      actions.replaceChildren(
        toolGroup,
        h('span', { class: 'wr-actions__spacer' }),
        enterHint('zum Prüfen'),
        keepFocus(primary('Weiter', () => handlers.onCopySubmit(input.value), { iconRight: 'arrowRight' })),
      );
      focus();
    } else {
      setEditable(false);
      answer.hidden = true;
      const next = primary('Weiter', () => handlers.onContinue(), { iconRight: 'arrowRight', kbd: 'Enter' });
      actions.replaceChildren(toolGroup, h('span', { class: 'wr-actions__spacer' }), next);
      next.focus({ preventScroll: true });
    }
  }

  function rejectEmpty() {
    replayClass(field, 'ui-anim-shake');
    focus();
  }

  function rejectCopy() {
    input.setAttribute('aria-invalid', 'true');
    replayClass(field, 'ui-anim-shake');
    focus();
  }

  // Updates prompt/answer texts after the card was edited (keeps typed text).
  function refresh(question) {
    if (!question) return;
    q = question;
    fillPrompt();
    if (phase !== 'incorrect') placeholders = questionPlaceholder();
    applyPlaceholder();
    const expected = feedback.querySelector('.wr-fb__expected');
    if (expected) expected.textContent = q.expected;
  }

  // The step's main control: the answer field, or "Weiter" when the field is hidden
  // (a miss without the copy step).
  function focusPrimary() {
    if (!answer.hidden) {
      focus();
      return;
    }
    const next = actions.querySelector('.ui-btn--primary');
    if (next && el.isConnected) next.focus({ preventScroll: true });
  }

  function focus() {
    if (answer.hidden || !el.isConnected) return;
    if (document.activeElement !== input) input.focus({ preventScroll: true });
    // Put the caret at the end (e.g. after a modal closed).
    const len = input.value.length;
    try {
      input.setSelectionRange(len, len);
    } catch {
      /* some input types do not support selection */
    }
  }

  // Ctrl+R: read the prompt aloud (only where the speaker button shows).
  function pressSpeak() {
    if (q && !speakPrompt.hidden) handlers.onSpeak(q.prompt, q.promptLang);
  }

  // Ctrl+D: the star button's own click (pop included); returns the new state.
  function pressStar() {
    star.click();
    return star.getAttribute('aria-pressed') === 'true';
  }

  if (narrow) listen(narrow, applyPlaceholder);

  return {
    el,
    input,
    setQuestion,
    showCorrect,
    showIncorrect,
    rejectEmpty,
    rejectCopy,
    refresh,
    focus,
    focusPrimary,
    stopTimer,
    pressSpeak,
    pressStar,
    dispose() {
      if (narrow) unlisten(narrow, applyPlaceholder);
    },
    setStarred: (value) => star.setStarred(!!value),
    get value() {
      return input.value;
    },
    get phase() {
      return phase;
    },
  };
}
