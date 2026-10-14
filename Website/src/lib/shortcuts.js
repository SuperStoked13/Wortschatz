// Keyboard shortcuts of the app shell (Mac ⌘ → Ctrl): whether a keydown is Ctrl/⌘ + a key,
// and whether the user is typing (then keys belong to the text field). Pure: it only reads
// the event and its target, so it imports anywhere.

// Ctrl (or ⌘) + `key` with Shift exactly as asked. Alt never: Ctrl+Alt is AltGr on Swiss and
// German keyboards (@ # | € …), so those keys must keep typing.
export function commandKey(e, key, { shift = false } = {}) {
  if (!e || typeof e.key !== 'string') return false;
  if (!(e.ctrlKey || e.metaKey) || e.altKey) return false;
  if (!!e.shiftKey !== shift) return false;
  return e.key.toLowerCase() === key;
}

const NON_TEXT_INPUTS = /^(button|checkbox|radio|range|color|file|submit|reset|image)$/i;

// A text field, a select or editable content: letters and Ctrl+letter edit text there.
export function isTypingTarget(target) {
  const el = target && target.nodeType === 1 ? target : target && target.parentElement;
  if (!el) return false;
  const tag = el.tagName;
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag === 'INPUT') return !NON_TEXT_INPUTS.test(el.type || '');
  return !!el.isContentEditable;
}
