// Write mode dialogs: a yes/no question, the card editor and the options sheet.

import { h } from '../lib/dom.js';
import { LANGS, langName } from '../lib/labels.js';
import { openModal, textField } from '../ui/components.js';
import { studyOptionsForm } from '../ui/study-options.js';

// Yes/no dialog on top of openModal, styled like the shared confirmDialog with a primary
// (non-danger) confirm button and its own cancel label.
export function ask({ title, message, confirmLabel, cancelLabel = 'Abbrechen' }) {
  return new Promise((resolve) => {
    let result = false;
    openModal({
      title,
      size: 'sm',
      className: 'ui-confirm',
      content: h('p', { class: 'ui-confirm__message' }, message),
      actions: [
        {
          label: cancelLabel,
          variant: 'secondary',
          onClick: () => {
            result = false;
          },
        },
        {
          label: confirmLabel,
          variant: 'primary',
          autofocus: true,
          onClick: () => {
            result = true;
          },
        },
      ],
      onClose: () => resolve(result),
    });
  });
}

const fieldAttrs = (lang) => ({ lang: (LANGS[lang] && LANGS[lang].bcp47) || null, autocomplete: 'off', spellcheck: 'false' });

/**
 * Edits a card's term and definition.
 * focusSide: 'term' | 'definition' – the side the learner had to type, usually the one to fix.
 * onSave({ term, definition }) -> boolean (true = saved, closes the dialog)
 * onClose(reason)
 */
export function openCardEditor({ termLang, defLang, card, focusSide = 'term', onSave, onClose }) {
  const termField = textField({
    label: termLang === 'other' ? 'Begriff' : `Begriff · ${langName(termLang)}`,
    value: card.term,
    autofocus: focusSide === 'term',
    attrs: fieldAttrs(termLang),
  });
  const defField = textField({
    label: defLang === 'other' ? 'Definition' : `Definition · ${langName(defLang)}`,
    value: card.definition,
    autofocus: focusSide !== 'term',
    attrs: fieldAttrs(defLang),
  });
  let modal = null;

  const save = () => {
    const term = termField.value.trim();
    const definition = defField.value.trim();
    termField.setError(term ? '' : 'Bitte gib den Begriff ein.');
    defField.setError(definition ? '' : 'Bitte gib die Definition ein.');
    if (!term || !definition) {
      (term ? defField : termField).focus();
      return false;
    }
    return onSave({ term, definition }) === true;
  };

  const form = h(
    'form',
    {
      class: 'wr-edit',
      onSubmit: (e) => {
        e.preventDefault();
        if (save() && modal) modal.close('saved');
      },
    },
    termField,
    defField,
    h('button', { type: 'submit', hidden: true, tabindex: '-1' }),
  );

  modal = openModal({
    title: 'Karte bearbeiten',
    content: form,
    size: 'sm',
    actions: [
      { label: 'Abbrechen', variant: 'secondary' },
      { label: 'Speichern', variant: 'primary', onClick: () => save() },
    ],
    onClose,
  });
  return modal;
}

/**
 * Study options sheet (direction, toggles, tolerance). mode: 'write' (default) or
 * 'learn' (see studyOptionsForm). Changes are reported live through onChange(patch);
 * onClose({ reason, restartAsked }) runs when the sheet closes.
 */
export function openOptionsDialog({ options, termLang, defLang, onChange, onClose, mode = 'write' }) {
  let restartAsked = false;
  const form = studyOptionsForm({ options, termLang, defLang, compact: true, onChange, mode });
  return openModal({
    title: 'Optionen',
    content: form,
    className: 'wr-options',
    actions: [
      {
        label: 'Neu starten',
        icon: 'rotate',
        variant: 'ghost',
        onClick: () => {
          restartAsked = true;
        },
      },
      { label: 'Fertig', variant: 'primary', autofocus: true },
    ],
    onClose: (reason) => onClose({ reason, restartAsked }),
  });
}
