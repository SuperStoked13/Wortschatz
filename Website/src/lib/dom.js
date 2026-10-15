// Tiny hyperscript + DOM helpers. Browser only at call time; safe to import anywhere.

const PROP_KEYS = new Set(['value', 'checked', 'disabled', 'hidden', 'selected', 'autofocus', 'indeterminate']);

function appendChildren(el, children) {
  for (const child of children) {
    if (child == null || child === false || child === true || child === '') continue;
    if (Array.isArray(child)) {
      appendChildren(el, child);
    } else if (typeof child === 'object' && typeof child.nodeType === 'number') {
      el.appendChild(child);
    } else {
      el.appendChild(document.createTextNode(String(child)));
    }
  }
}

function classString(value) {
  if (Array.isArray(value)) return value.flat(Infinity).filter(Boolean).join(' ');
  return value ? String(value) : '';
}

// h('button', { class: ['ui-btn', active && 'is-active'], onClick }, 'Label')
export function h(tag, props = null, ...children) {
  const el = document.createElement(tag);
  const deferred = [];
  let ref = null;

  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (key === 'class' || key === 'className') {
        const cls = classString(value);
        if (cls) el.className = cls;
      } else if (key === 'style') {
        if (typeof value === 'string') el.style.cssText = value;
        else if (value && typeof value === 'object') {
          for (const [k, v] of Object.entries(value)) {
            if (v == null || v === false) continue;
            if (k.startsWith('--') || k.includes('-')) el.style.setProperty(k, String(v));
            else el.style[k] = v;
          }
        }
      } else if (key === 'dataset') {
        if (value) for (const [k, v] of Object.entries(value)) if (v != null) el.dataset[k] = String(v);
      } else if (key === 'ref') {
        ref = value;
      } else if (key === 'html') {
        if (value != null) el.innerHTML = String(value);
      } else if (key.length > 2 && key.startsWith('on') && typeof value === 'function') {
        el.addEventListener(key.slice(2).toLowerCase(), value);
      } else if (PROP_KEYS.has(key)) {
        // Applied after children so <select value> can match its <option>s.
        deferred.push([key, value]);
      } else if (key === 'for' || key === 'htmlFor') {
        if (value != null) el.htmlFor = String(value);
      } else if (value == null || value === false) {
        continue;
      } else {
        el.setAttribute(key, value === true ? '' : String(value));
      }
    }
  }

  appendChildren(el, children);

  for (const [key, value] of deferred) {
    if (key === 'value') {
      if (value != null) el.value = value;
    } else {
      el[key] = Boolean(value);
    }
  }
  if (typeof ref === 'function') ref(el);
  return el;
}

// Sets or removes `lang` and `dir` on an element reused for other text (lib/labels.js
// textAttrs/fieldAttrs; a null value removes the attribute).
export function setTextAttrs(el, { lang = null, dir = null } = {}) {
  if (!el) return el;
  if (lang) el.setAttribute('lang', lang);
  else el.removeAttribute('lang');
  if (dir) el.setAttribute('dir', dir);
  else el.removeAttribute('dir');
  return el;
}

export function clear(el) {
  if (el) while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

export function $(sel, root = document) {
  return root ? root.querySelector(sel) : null;
}

export function $$(sel, root = document) {
  return root ? Array.from(root.querySelectorAll(sel)) : [];
}

// Delegated listener: handler(event, matchedElement). Returns off().
export function on(el, type, selector, handler) {
  const listener = (event) => {
    const start = event.target && event.target.nodeType === 1 ? event.target : event.target && event.target.parentElement;
    const match = start && start.closest ? start.closest(selector) : null;
    if (match && el.contains(match)) handler(event, match);
  };
  el.addEventListener(type, listener);
  return () => el.removeEventListener(type, listener);
}

export const FOCUSABLE =
  'a[href], area[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), ' +
  'textarea:not([disabled]), iframe, [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';

export function isVisible(el) {
  return !!(el && (el.offsetWidth || el.offsetHeight || el.getClientRects().length)) && getComputedStyle(el).visibility !== 'hidden';
}

export function focusableWithin(container) {
  return $$(FOCUSABLE, container).filter((el) => !el.closest('[inert]') && isVisible(el));
}

// Focus the first [autofocus] element, else the first text field, else the first focusable.
// Returns the focused element or null.
export function focusFirst(container) {
  if (!container) return null;
  const target =
    $$('[autofocus]', container).find(isVisible) ||
    $$('input:not([type="hidden"]):not([disabled]), textarea:not([disabled]), select:not([disabled])', container).find(isVisible) ||
    focusableWithin(container)[0] ||
    null;
  if (target) target.focus({ preventScroll: false });
  return target;
}

// Re-trigger a CSS animation class (e.g. a shake on a wrong answer).
export function replayClass(el, className) {
  if (!el) return;
  el.classList.remove(className);
  void el.offsetWidth; // force reflow so the animation restarts
  el.classList.add(className);
  el.addEventListener('animationend', () => el.classList.remove(className), { once: true });
}

export function prefersReducedMotion() {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
}
