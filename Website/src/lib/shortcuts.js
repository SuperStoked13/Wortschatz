// Keyboard shortcuts of the app shell (Mac ⌘ → Ctrl): whether a keydown is Ctrl/⌘ + a key,
// and whether the user is typing (then keys belong to the text field). Pure: it only reads
// the event and its target, so it imports anywhere.

// A key an input method (Pinyin, Japanese …) is composing: it belongs to the IME, not to Enter,
// Esc or a shortcut (keyCode 229 is the keydown that starts or feeds a composition).
export function isComposingKey(e) {
  return !!e && (!!e.isComposing || e.keyCode === 229);
}

// The Latin letter of a shortcut key, lower case ('' for other keys). Non-Latin layouts (Arabic,
// Cyrillic …) report their own letter in `key`; the key's position (`code`) names it then.
export function commandLetter(e) {
  if (!e || typeof e.key !== 'string') return '';
  const key = e.key.toLowerCase();
  if (/^[a-z]$/.test(key)) return key;
  const code = /^Key([A-Z])$/.exec(String(e.code || ''));
  return code && /[^\x00-\x7f]/.test(key) ? code[1].toLowerCase() : '';
}

// Ctrl (or ⌘) + `key` with Shift exactly as asked. Alt never: Ctrl+Alt is AltGr on Swiss and
// German keyboards (@ # | € …), so those keys must keep typing.
export function commandKey(e, key, { shift = false } = {}) {
  if (!e || typeof e.key !== 'string') return false;
  if (!(e.ctrlKey || e.metaKey) || e.altKey) return false;
  if (!!e.shiftKey !== shift) return false;
  return e.key.toLowerCase() === key || commandLetter(e) === key;
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
