// Wortschatz UI kit. Every factory returns a DOM element (or a small handle for
// overlays). German labels are passed in by callers; only generic ones
// ("Schliessen", "Abbrechen") have defaults here.

import { h, focusableWithin, prefersReducedMotion } from '../lib/dom.js';
import { STATUS } from '../lib/labels.js';
import { icon } from './icons.js';

let idCounter = 0;
const nextId = (prefix) => `ui-${prefix}-${++idCounter}`;
const clamp01 = (v) => Math.min(1, Math.max(0, Number(v) || 0));
const isNode = (v) => !!v && typeof v === 'object' && typeof v.nodeType === 'number';

function iconEl(name, size) {
  if (!name) return null;
  if (isNode(name)) return name;
  return icon(name, { size });
}

// Waits for the exit animation of `el` (or a timeout) before calling done().
function afterAnimation(el, done, timeout = 400) {
  if (prefersReducedMotion()) {
    done();
    return;
  }
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    done();
  };
  el.addEventListener('animationend', (e) => e.target === el && finish());
  setTimeout(finish, timeout);
}

/* ------------------------------------------------------------------ buttons */

const BTN_ICON = { sm: 16, md: 18, lg: 20 };

export function button({
  label,
  icon: iconName,
  iconRight,
  variant = 'secondary',
  size = 'md',
  onClick,
  type = 'button',
  disabled = false,
  title,
  kbd: kbdText,
  block = false,
  href,
  attrs = {},
} = {}) {
  const iconSize = BTN_ICON[size] || 18;
  const iconOnly = !label && !!(iconName || iconRight);
  const { class: extraClass, ...rest } = attrs || {};
  const props = {
    class: ['ui-btn', `ui-btn--${variant}`, `ui-btn--${size}`, block && 'ui-btn--block', iconOnly && 'ui-btn--icon-only', extraClass],
    title,
    'aria-label': iconOnly ? title || null : null,
    ...rest,
  };
  if (href) {
    props.href = href;
    if (disabled) props['aria-disabled'] = 'true';
  } else {
    props.type = type;
    props.disabled = disabled;
  }
  const labelEl = label != null && label !== '' ? h('span', { class: 'ui-btn__label' }, label) : null;
  const el = h(
    href ? 'a' : 'button',
    props,
    iconEl(iconName, iconSize),
    labelEl,
    iconEl(iconRight, iconSize),
    kbdText ? h('kbd', { class: 'ui-kbd ui-btn__kbd', 'aria-hidden': 'true' }, kbdText) : null,
  );
  if (typeof onClick === 'function') {
    el.addEventListener('click', (e) => {
      if (el.getAttribute('aria-disabled') === 'true' || el.classList.contains('is-loading')) {
        e.preventDefault();
        return;
      }
      onClick(e);
    });
  }
  el.setLabel = (text) => {
    const target = el.querySelector('.ui-btn__label');
    if (target) target.textContent = text;
  };
  el.setLoading = (loading) => {
    el.classList.toggle('is-loading', !!loading);
    el.setAttribute('aria-busy', loading ? 'true' : 'false');
    const existing = el.querySelector('.ui-spinner');
    if (loading && !existing) el.prepend(spinner({ size: iconSize - 2 }));
    if (!loading && existing) existing.remove();
  };
  return el;
}

const ICON_BTN_ICON = { sm: 16, md: 20, lg: 22 };

export function iconButton({ icon: name, label, onClick, variant = 'ghost', size = 'md', pressed, href, disabled = false, attrs = {} } = {}) {
  const { class: extraClass, ...rest } = attrs || {};
  const props = {
    class: ['ui-icon-btn', `ui-icon-btn--${variant}`, `ui-icon-btn--${size}`, extraClass],
    'aria-label': label,
    'data-tooltip': label || null,
    'aria-pressed': pressed == null ? null : String(!!pressed),
    ...rest,
  };
  if (href) props.href = href;
  else {
    props.type = 'button';
    props.disabled = disabled;
  }
  const el = h(href ? 'a' : 'button', props, iconEl(name, ICON_BTN_ICON[size] || 20));
  if (typeof onClick === 'function') el.addEventListener('click', onClick);
  el.setPressed = (value) => el.setAttribute('aria-pressed', String(!!value));
  el.setIcon = (next) => el.replaceChildren(iconEl(next, ICON_BTN_ICON[size] || 20));
  el.setLabel = (text) => {
    el.setAttribute('aria-label', text);
    el.dataset.tooltip = text;
  };
  ensureTooltips();
  return el;
}

// Star toggle used for "markierte" cards. onToggle(next) may return the stored value.
export function starButton({ starred = false, onToggle, label = 'Markieren', labelActive = 'Markierung entfernen', size = 'md' } = {}) {
  let state = !!starred;
  const el = iconButton({ icon: state ? 'starFilled' : 'star', label: state ? labelActive : label, size, pressed: state, attrs: { class: 'ui-star' } });
  el.setStarred = (value) => {
    state = !!value;
    el.setPressed(state);
    el.setIcon(state ? 'starFilled' : 'star');
    el.setLabel(state ? labelActive : label);
  };
  el.addEventListener('click', (e) => {
    e.stopPropagation();
    let next = !state;
    if (typeof onToggle === 'function') {
      const result = onToggle(next);
      if (typeof result === 'boolean') next = result;
    }
    el.setStarred(next);
    if (next) {
      el.classList.remove('is-popping');
      void el.offsetWidth;
      el.classList.add('is-popping');
    }
  });
  return el;
}

/* ------------------------------------------------------------------ toggles */

export function toggle({ label, description, checked = false, onChange, id, disabled = false, ariaLabel } = {}) {
  const inputId = id || nextId('toggle');
  const descId = description ? `${inputId}-desc` : null;
  // The switch is named by its title only (or by ariaLabel); the wrapping label
  // would add the description, which aria-describedby already reads.
  const labelId = label ? `${inputId}-label` : null;
  const input = h('input', {
    type: 'checkbox',
    role: 'switch',
    class: 'ui-toggle__input',
    id: inputId,
    checked: !!checked,
    disabled,
    'aria-describedby': descId,
    'aria-labelledby': labelId && !ariaLabel ? labelId : null,
    'aria-label': ariaLabel || null,
  });
  input.addEventListener('change', () => {
    if (typeof onChange === 'function') onChange(input.checked);
  });
  const el = h(
    'label',
    { class: ['ui-toggle', disabled && 'is-disabled', !label && !description && 'ui-toggle--bare'], for: inputId },
    label || description
      ? h(
          'span',
          { class: 'ui-toggle__text' },
          label ? h('span', { class: 'ui-toggle__label', id: labelId }, label) : null,
          description ? h('span', { class: 'ui-toggle__desc', id: descId }, description) : null,
        )
      : null,
    input,
    h('span', { class: 'ui-toggle__track', 'aria-hidden': 'true' }, h('span', { class: 'ui-toggle__thumb' })),
  );
  el.input = input;
  el.setChecked = (value) => {
    input.checked = !!value;
  };
  el.setDisabled = (value) => {
    input.disabled = !!value;
    el.classList.toggle('is-disabled', !!value);
  };
  Object.defineProperty(el, 'checked', {
    get: () => input.checked,
    set: (value) => {
      input.checked = !!value;
    },
  });
  return el;
}

/* -------------------------------------------------------------- segmented */

export function segmented({ options = [], value, onChange, ariaLabel, size = 'md', block = false } = {}) {
  let current = value;
  const indicator = h('span', { class: 'ui-seg__indicator', 'aria-hidden': 'true' });
  const root = h('div', {
    class: ['ui-seg', `ui-seg--${size}`, block && 'ui-seg--block'],
    role: 'radiogroup',
    'aria-label': ariaLabel || null,
  });
  root.append(indicator);

  const buttons = options.map((opt) => {
    const btn = h(
      'button',
      {
        type: 'button',
        class: 'ui-seg__btn',
        role: 'radio',
        title: opt.title || null,
        'aria-label': opt.ariaLabel || null,
        disabled: !!opt.disabled,
      },
      iconEl(opt.icon, size === 'sm' ? 15 : 16),
      opt.label != null && opt.label !== '' ? h('span', { class: 'ui-seg__label' }, opt.label) : null,
      opt.count != null ? h('span', { class: 'ui-seg__count' }, String(opt.count)) : null,
    );
    btn.addEventListener('click', () => select(opt.value, true));
    root.append(btn);
    return btn;
  });

  const indexOf = (v) => options.findIndex((o) => o.value === v);

  function sync() {
    const idx = indexOf(current);
    buttons.forEach((btn, i) => {
      const on = i === idx;
      btn.setAttribute('aria-checked', String(on));
      btn.tabIndex = on || (idx === -1 && i === 0) ? 0 : -1;
    });
    place(true);
  }

  function place(animate) {
    const btn = buttons[indexOf(current)];
    if (!btn || !btn.offsetWidth) {
      indicator.style.opacity = '0';
      return;
    }
    if (!animate) indicator.classList.add('is-instant');
    indicator.style.width = `${btn.offsetWidth}px`;
    indicator.style.height = `${btn.offsetHeight}px`;
    indicator.style.transform = `translate(${btn.offsetLeft}px, ${btn.offsetTop}px)`;
    indicator.style.opacity = '1';
    root.dataset.ready = 'true';
    if (!animate) {
      void indicator.offsetWidth;
      indicator.classList.remove('is-instant');
    }
  }

  function select(next, fromUser) {
    if (next === current) return;
    current = next;
    sync();
    if (fromUser && typeof onChange === 'function') onChange(next);
  }

  root.addEventListener('keydown', (e) => {
    const keys = ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End'];
    if (!keys.includes(e.key)) return;
    e.preventDefault();
    const enabled = buttons.map((b, i) => (b.disabled ? -1 : i)).filter((i) => i >= 0);
    if (!enabled.length) return;
    const pos = Math.max(0, enabled.indexOf(buttons.indexOf(document.activeElement)));
    let target = pos;
    if (e.key === 'Home') target = 0;
    else if (e.key === 'End') target = enabled.length - 1;
    else if (e.key === 'ArrowRight' || e.key === 'ArrowDown') target = (pos + 1) % enabled.length;
    else target = (pos - 1 + enabled.length) % enabled.length;
    const idx = enabled[target];
    buttons[idx].focus();
    select(options[idx].value, true);
  });

  if (typeof ResizeObserver === 'function') {
    new ResizeObserver(() => place(false)).observe(root);
  } else if (typeof requestAnimationFrame === 'function') {
    requestAnimationFrame(() => place(false));
  }

  sync();
  root.setValue = (next) => {
    current = next;
    sync();
  };
  Object.defineProperty(root, 'value', { get: () => current });
  return root;
}

/* ------------------------------------------------------------- text fields */

// Grows a textarea with its content. Returns the textarea; call ta.fit() after
// setting its value programmatically.
export function autoGrow(textarea) {
  const fit = () => {
    if (!textarea.isConnected) return;
    textarea.style.height = 'auto';
    const extra = textarea.offsetHeight - textarea.clientHeight;
    textarea.style.height = `${textarea.scrollHeight + extra}px`;
  };
  textarea.addEventListener('input', fit);
  if (typeof ResizeObserver === 'function') {
    let width = -1;
    new ResizeObserver(() => {
      if (textarea.offsetWidth !== width) {
        width = textarea.offsetWidth;
        fit();
      }
    }).observe(textarea);
  }
  textarea.fit = fit;
  return textarea;
}

export function textField({
  label,
  value = '',
  placeholder,
  onInput,
  multiline = false,
  rows = 3,
  autofocus = false,
  id,
  attrs = {},
  hint,
  type = 'text',
  size = 'md',
  autoGrow: grow = false,
} = {}) {
  const inputId = id || nextId('field');
  const hintId = `${inputId}-hint`;
  const { class: extraClass, ...rest } = attrs || {};
  const common = {
    id: inputId,
    class: ['ui-input', `ui-input--${size}`, multiline && 'ui-textarea', extraClass],
    placeholder: placeholder || null,
    autofocus,
    'aria-describedby': hint ? hintId : null,
    ...rest,
  };
  const input = multiline ? h('textarea', { ...common, rows: String(rows) }) : h('input', { ...common, type });
  input.value = value == null ? '' : String(value);
  if (multiline && grow) autoGrow(input);
  if (typeof onInput === 'function') input.addEventListener('input', () => onInput(input.value));

  const hintEl = hint ? h('p', { class: 'ui-field__hint', id: hintId }, hint) : null;
  const errorEl = h('p', { class: 'ui-field__error', id: `${inputId}-error`, hidden: true });
  const el = h(
    'div',
    { class: ['ui-field', `ui-field--${size}`] },
    label ? h('label', { class: 'ui-field__label', for: inputId }, label) : null,
    input,
    hintEl,
    errorEl,
  );
  el.input = input;
  el.focus = (opts) => input.focus(opts);
  el.setError = (message) => {
    const has = !!message;
    errorEl.hidden = !has;
    errorEl.textContent = has ? message : '';
    el.classList.toggle('is-invalid', has);
    input.setAttribute('aria-invalid', has ? 'true' : 'false');
    const ids = [hint ? hintId : null, has ? errorEl.id : null].filter(Boolean).join(' ');
    if (ids) input.setAttribute('aria-describedby', ids);
    else input.removeAttribute('aria-describedby');
  };
  Object.defineProperty(el, 'value', {
    get: () => input.value,
    set: (next) => {
      input.value = next == null ? '' : String(next);
      if (input.fit) input.fit();
    },
  });
  return el;
}

export function selectField({ label, options = [], value, onChange, id, hint, size = 'md', ariaLabel } = {}) {
  const selectId = id || nextId('select');
  const select = h(
    'select',
    {
      id: selectId,
      class: ['ui-select', `ui-select--${size}`],
      'aria-label': !label ? ariaLabel || null : null,
      value: value == null ? undefined : String(value),
    },
    options.map((o) => h('option', { value: String(o.value), disabled: !!o.disabled }, o.label)),
  );
  select.addEventListener('change', () => {
    if (typeof onChange === 'function') onChange(select.value);
  });
  const el = h(
    'div',
    { class: 'ui-field' },
    label ? h('label', { class: 'ui-field__label', for: selectId }, label) : null,
    h('div', { class: 'ui-select-wrap' }, select, icon('chevronDown', { size: 16, className: 'ui-select-wrap__chevron' })),
    hint ? h('p', { class: 'ui-field__hint' }, hint) : null,
  );
  el.select = select;
  Object.defineProperty(el, 'value', {
    get: () => select.value,
    set: (next) => {
      select.value = String(next);
    },
  });
  return el;
}

/* --------------------------------------------------------- chips & badges */

export function chip({ label, tone = 'neutral', icon: name, onClick, selected, count, size = 'md', title } = {}) {
  const interactive = typeof onClick === 'function';
  const el = h(
    interactive ? 'button' : 'span',
    {
      class: ['ui-chip', `ui-chip--${tone}`, size === 'sm' && 'ui-chip--sm', interactive && 'ui-chip--interactive'],
      type: interactive ? 'button' : null,
      'aria-pressed': interactive && selected != null ? String(!!selected) : null,
      title: title || null,
    },
    iconEl(name, size === 'sm' ? 12 : 14),
    label != null && label !== '' ? h('span', { class: 'ui-chip__label' }, label) : null,
    count != null ? h('span', { class: 'ui-chip__count' }, String(count)) : null,
  );
  if (interactive) el.addEventListener('click', onClick);
  el.setSelected = (value) => el.setAttribute('aria-pressed', String(!!value));
  el.setCount = (value) => {
    const c = el.querySelector('.ui-chip__count');
    if (c) c.textContent = String(value);
  };
  return el;
}

export function kbd(text) {
  return h('kbd', { class: 'ui-kbd' }, text);
}

export function spinner({ size = 18, label } = {}) {
  return h('span', {
    class: 'ui-spinner',
    role: label ? 'status' : null,
    'aria-label': label || null,
    'aria-hidden': label ? null : 'true',
    style: { width: `${size}px`, height: `${size}px` },
  });
}

/* --------------------------------------------------------------- progress */

export function progressBar({ value = 0, tone = 'accent', label, size = 'md' } = {}) {
  const fill = h('span', { class: 'ui-progress__fill' });
  const el = h(
    'div',
    {
      class: ['ui-progress', `ui-progress--${tone}`, `ui-progress--${size}`],
      role: 'progressbar',
      'aria-valuemin': '0',
      'aria-valuemax': '100',
      'aria-label': label || null,
    },
    fill,
  );
  el.update = (next) => {
    const v = clamp01(next);
    fill.style.width = `${v * 100}%`;
    el.setAttribute('aria-valuenow', String(Math.round(v * 100)));
    el.classList.toggle('is-complete', v >= 1);
  };
  el.update(value);
  return el;
}

export function masteryBar({ mastered = 0, learning = 0, fresh = 0, showLegend = false, size = 'md' } = {}) {
  const segs = {
    mastered: h('span', { class: 'ui-mastery__seg ui-mastery__seg--mastered' }),
    learning: h('span', { class: 'ui-mastery__seg ui-mastery__seg--learning' }),
    fresh: h('span', { class: 'ui-mastery__seg ui-mastery__seg--new' }),
  };
  const bar = h('div', { class: 'ui-mastery__bar', role: 'img' }, segs.mastered, segs.learning, segs.fresh);
  const counts = {};
  const legend = showLegend
    ? h(
        'ul',
        { class: 'ui-mastery__legend' },
        [
          ['mastered', STATUS.mastered],
          ['learning', STATUS.learning],
          ['fresh', STATUS.new],
        ].map(([key, text]) => {
          counts[key] = h('strong', { class: 'ui-mastery__count' });
          return h(
            'li',
            { class: 'ui-mastery__item' },
            h('span', { class: `ui-dot ui-dot--${key === 'fresh' ? 'new' : key}`, 'aria-hidden': 'true' }),
            h('span', { class: 'ui-mastery__label' }, text),
            counts[key],
          );
        }),
      )
    : null;
  const el = h('div', { class: ['ui-mastery', `ui-mastery--${size}`] }, bar, legend);
  el.update = ({ mastered: m = 0, learning: l = 0, fresh: f = 0 } = {}) => {
    const total = m + l + f;
    const pct = (n) => (total > 0 ? (n / total) * 100 : 0);
    segs.mastered.style.width = `${pct(m)}%`;
    segs.learning.style.width = `${pct(l)}%`;
    segs.fresh.style.width = `${total > 0 ? pct(f) : 100}%`;
    segs.mastered.hidden = m === 0;
    segs.learning.hidden = l === 0;
    segs.fresh.hidden = total > 0 && f === 0;
    bar.setAttribute('aria-label', `${m} gemeistert, ${l} am Lernen, ${f} neu`);
    if (counts.mastered) {
      counts.mastered.textContent = String(m);
      counts.learning.textContent = String(l);
      counts.fresh.textContent = String(f);
    }
  };
  el.update({ mastered, learning, fresh });
  return el;
}

const SVG_NS = 'http://www.w3.org/2000/svg';

function svgEl(tag, attrs) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, String(v));
  return el;
}

export function ring({ value = 0, size = 88, label, sublabel, tone = 'accent', stroke } = {}) {
  const width = stroke || Math.max(6, Math.round(size / 11));
  const r = (size - width) / 2;
  const circumference = 2 * Math.PI * r;
  const svg = svgEl('svg', { viewBox: `0 0 ${size} ${size}`, width: size, height: size, class: 'ui-ring__svg', 'aria-hidden': 'true' });
  svg.append(svgEl('circle', { class: 'ui-ring__track', cx: size / 2, cy: size / 2, r, 'stroke-width': width, fill: 'none' }));
  const arc = svgEl('circle', {
    class: 'ui-ring__arc',
    cx: size / 2,
    cy: size / 2,
    r,
    'stroke-width': width,
    fill: 'none',
    'stroke-linecap': 'round',
    'stroke-dasharray': circumference.toFixed(2),
    'stroke-dashoffset': circumference.toFixed(2),
    transform: `rotate(-90 ${size / 2} ${size / 2})`,
  });
  svg.append(arc);
  const labelEl = h('span', { class: 'ui-ring__label' });
  const subEl = h('span', { class: 'ui-ring__sublabel' });
  const el = h(
    'div',
    {
      class: ['ui-ring', `ui-ring--${tone}`],
      role: 'img',
      style: { width: `${size}px`, height: `${size}px`, '--ring-size': `${size}px` },
    },
    svg,
    h('span', { class: 'ui-ring__center' }, labelEl, subEl),
  );
  el.update = (next, nextLabel, nextSub) => {
    const v = clamp01(next);
    // A zero-length round cap still draws a dot, so hide the arc at 0.
    arc.style.opacity = v <= 0 ? '0' : '1';
    arc.setAttribute('stroke-dashoffset', (circumference * (1 - v)).toFixed(2));
    const text = nextLabel != null ? nextLabel : label != null ? label : `${Math.round(v * 100)} %`;
    const sub = nextSub != null ? nextSub : sublabel || '';
    labelEl.textContent = text;
    subEl.textContent = sub;
    subEl.hidden = !sub;
    el.setAttribute('aria-label', sub ? `${text} ${sub}` : text);
    el.classList.toggle('is-complete', v >= 1);
  };
  el.update(value);
  return el;
}

/* ------------------------------------------------------------------ modal */

const modalStack = [];
let scrollLocks = 0;

function lockScroll() {
  if (scrollLocks++ > 0) return;
  const root = document.documentElement;
  const gap = window.innerWidth - root.clientWidth;
  root.style.setProperty('--scrollbar-gap', `${Math.max(0, gap)}px`);
  root.classList.add('ui-scroll-locked');
}

function unlockScroll() {
  scrollLocks = Math.max(0, scrollLocks - 1);
  if (scrollLocks === 0) document.documentElement.classList.remove('ui-scroll-locked');
}

// Makes everything outside `keep` inert; returns a restore function.
function inertOutside(keep) {
  const changed = [];
  for (const child of Array.from(document.body.children)) {
    if (child === keep || child.id === 'toasts' || child.classList.contains('ui-tooltip')) continue;
    if (child.tagName === 'SCRIPT' || child.hasAttribute('inert')) continue;
    child.setAttribute('inert', '');
    changed.push(child);
  }
  return () => changed.forEach((child) => child.removeAttribute('inert'));
}

function onModalKeydown(e) {
  const top = modalStack[modalStack.length - 1];
  if (!top) return;
  if (e.key === 'Escape') {
    if (top.dismissible) {
      e.preventDefault();
      e.stopPropagation();
      top.close('esc');
    }
  } else if (e.key === 'Tab') {
    const items = focusableWithin(top.dialog);
    if (!items.length) {
      e.preventDefault();
      top.dialog.focus();
      return;
    }
    const first = items[0];
    const last = items[items.length - 1];
    const active = document.activeElement;
    if (e.shiftKey && (active === first || active === top.dialog || !top.dialog.contains(active))) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && (active === last || !top.dialog.contains(active))) {
      e.preventDefault();
      first.focus();
    }
  }
}

function onModalFocusIn(e) {
  const top = modalStack[modalStack.length - 1];
  if (!top || top.root.contains(e.target)) return;
  if (e.target.closest && (e.target.closest('.ui-menu') || e.target.closest('#toasts'))) return;
  const items = focusableWithin(top.dialog);
  (items[0] || top.dialog).focus({ preventScroll: true });
}

// describe: point aria-describedby at the body so screen readers announce it with the
// title even when focus starts on a footer button. By default only short confirm-style
// bodies (plain text or a .ui-confirm__message) are used as the description, not forms.
// role: 'dialog' or 'alertdialog' (urgent confirmations).
export function openModal({
  title,
  content,
  actions = [],
  onClose,
  size = 'md',
  dismissible = true,
  closeLabel = 'Schliessen',
  className,
  role = 'dialog',
  describe,
} = {}) {
  const previousFocus = document.activeElement;
  const titleId = nextId('modal-title');
  const bodyId = nextId('modal-body');
  let closed = false;
  let restoreInert = () => {};

  const api = { close, el: null, root: null, body: null };

  const closeBtn = dismissible ? iconButton({ icon: 'x', label: closeLabel, size: 'sm', onClick: () => close('button') }) : null;
  const header =
    title || closeBtn
      ? h(
          'header',
          { class: 'ui-modal__header' },
          title ? h('h2', { class: 'ui-modal__title', id: titleId }, title) : h('span', { class: 'ui-modal__spacer' }),
          closeBtn,
        )
      : null;

  const body = content != null ? h('div', { class: 'ui-modal__body', id: bodyId }, isNode(content) ? content : String(content)) : null;
  const described = !!body && (describe != null ? !!describe : !isNode(content) || !!body.querySelector('.ui-confirm__message'));

  const actionButtons = actions.filter(Boolean).map((action) =>
    button({
      label: action.label,
      icon: action.icon,
      variant: action.variant || 'secondary',
      disabled: !!action.disabled,
      kbd: action.kbd,
      attrs: action.autofocus ? { autofocus: true } : {},
      onClick: async () => {
        let result;
        if (typeof action.onClick === 'function') result = await action.onClick(api);
        if (action.close !== false && result !== false) close('action');
      },
    }),
  );
  const footer = actionButtons.length ? h('footer', { class: 'ui-modal__footer' }, actionButtons) : null;

  const dialog = h(
    'div',
    {
      class: ['ui-modal', `ui-modal--${size}`, className],
      role: role === 'alertdialog' ? 'alertdialog' : 'dialog',
      'aria-modal': 'true',
      'aria-labelledby': title ? titleId : null,
      'aria-describedby': described ? bodyId : null,
      tabindex: '-1',
    },
    header,
    body,
    footer,
  );
  const root = h('div', { class: 'ui-modal-root', dataset: { state: 'open' } }, h('div', { class: 'ui-modal-backdrop' }), dialog);

  // Close on a click that both starts and ends outside the dialog.
  let downOutside = false;
  root.addEventListener('pointerdown', (e) => {
    downOutside = !dialog.contains(e.target);
  });
  root.addEventListener('click', (e) => {
    if (dismissible && downOutside && !dialog.contains(e.target)) close('backdrop');
    downOutside = false;
  });

  const entry = { root, dialog, dismissible, close };
  api.el = dialog;
  api.root = root;
  api.body = body;

  function close(reason = 'api') {
    if (closed) return;
    closed = true;
    const idx = modalStack.indexOf(entry);
    if (idx >= 0) modalStack.splice(idx, 1);
    if (!modalStack.length) {
      document.removeEventListener('keydown', onModalKeydown);
      document.removeEventListener('focusin', onModalFocusIn);
    }
    restoreInert();
    unlockScroll();
    root.dataset.state = 'closing';
    afterAnimation(dialog, () => root.remove(), 320);
    if (previousFocus && previousFocus.isConnected && typeof previousFocus.focus === 'function') {
      previousFocus.focus({ preventScroll: true });
    }
    if (typeof onClose === 'function') onClose(reason);
  }

  hideTooltip();
  closeMenu();
  document.body.append(root);
  restoreInert = inertOutside(root);
  lockScroll();
  if (!modalStack.length) {
    document.addEventListener('keydown', onModalKeydown);
    document.addEventListener('focusin', onModalFocusIn);
  }
  modalStack.push(entry);

  const auto = dialog.querySelector('[autofocus], [data-autofocus]');
  (auto || dialog).focus({ preventScroll: true });
  return api;
}

export function confirmDialog({ title, message, confirmLabel = 'Löschen', cancelLabel = 'Abbrechen', danger = true } = {}) {
  return new Promise((resolve) => {
    let result = false;
    const content = message == null ? null : isNode(message) ? message : h('p', { class: 'ui-confirm__message' }, message);
    openModal({
      title,
      size: 'sm',
      className: ['ui-confirm', danger && 'ui-confirm--danger'],
      role: danger ? 'alertdialog' : 'dialog',
      describe: true,
      content,
      actions: [
        // Block bodies: openModal keeps the dialog open when a handler returns false.
        {
          label: cancelLabel,
          variant: 'secondary',
          autofocus: danger,
          onClick: () => {
            result = false;
          },
        },
        {
          label: confirmLabel,
          variant: danger ? 'danger' : 'primary',
          autofocus: !danger,
          onClick: () => {
            result = true;
          },
        },
      ],
      onClose: () => resolve(result),
    });
  });
}

export function hasOpenModal() {
  return modalStack.length > 0;
}

/* ------------------------------------------------------------------ toasts */

// 'streak': the daily Lernserie went on (a filled flame in the flame colour, like the Mac app).
const TOAST_ICONS = { success: 'checkCircle', danger: 'alertCircle', warning: 'alert', neutral: 'info', streak: 'flameFilled' };
const MAX_TOASTS = 4;

function toastHost() {
  let host = document.getElementById('toasts');
  if (!host) {
    host = h('div', { id: 'toasts', 'aria-live': 'polite' });
    document.body.append(host);
  }
  host.classList.add('ui-toasts');
  return host;
}

export function toast(message, { tone = 'neutral', duration = 3500, action, icon: iconName } = {}) {
  const host = toastHost();
  const sticky = !(duration > 0) || !Number.isFinite(duration);
  let timer = null;
  let remaining = duration;
  let startedAt = 0;
  let closed = false;

  const el = h(
    'div',
    {
      class: ['ui-toast', `ui-toast--${tone}`],
      role: tone === 'danger' ? 'alert' : 'status',
      dataset: { state: 'open' },
    },
    icon(iconName || TOAST_ICONS[tone] || 'info', { size: 18, className: 'ui-toast__icon' }),
    h('span', { class: 'ui-toast__msg' }, message),
    action && action.label
      ? h(
          'button',
          {
            type: 'button',
            class: 'ui-toast__action',
            onClick: () => {
              if (typeof action.onClick === 'function') action.onClick();
              close();
            },
          },
          action.label,
        )
      : null,
    sticky
      ? h('button', { type: 'button', class: 'ui-toast__close', 'aria-label': 'Schliessen', onClick: () => close() }, icon('x', { size: 16 }))
      : null,
  );

  function close() {
    if (closed) return;
    closed = true;
    clearTimeout(timer);
    el.dataset.state = 'closing';
    afterAnimation(el, () => el.remove(), 300);
  }
  function start() {
    if (sticky || closed) return;
    startedAt = Date.now();
    timer = setTimeout(close, remaining);
  }
  function pause() {
    if (sticky || closed) return;
    clearTimeout(timer);
    remaining = Math.max(800, remaining - (Date.now() - startedAt));
  }

  el.addEventListener('pointerenter', pause);
  el.addEventListener('pointerleave', start);
  el.addEventListener('focusin', pause);
  el.addEventListener('focusout', start);

  host.append(el);
  const open = Array.from(host.querySelectorAll('.ui-toast[data-state="open"]'));
  if (open.length > MAX_TOASTS) open.slice(0, open.length - MAX_TOASTS).forEach((t) => t._close && t._close());
  el._close = close;
  start();
  return { close, el };
}

/* ------------------------------------------------------------------- menu */

let activeMenu = null;

// Bottom edge of the sticky app header. Menus and tooltips layer above it, so they must
// not point at content scrolled under it (0 for an element inside the header or while
// a modal is open).
function headerBottomFor(el) {
  const header = document.getElementById('app-header');
  if (!header || header.contains(el) || modalStack.length) return 0;
  return Math.max(0, header.getBoundingClientRect().bottom);
}

function closeMenu() {
  if (activeMenu) activeMenu.close(false);
}

export function menu(anchor, items = [], { align = 'end', label } = {}) {
  if (activeMenu) {
    const same = activeMenu.anchor === anchor;
    activeMenu.close(false);
    if (same) return null;
  }
  hideTooltip();

  const list = h('div', { class: 'ui-menu', role: 'menu', tabindex: '-1', 'aria-label': label || null, dataset: { state: 'open' } });
  const entries = [];
  for (const item of items) {
    if (!item) continue;
    if (item.divider && entries.length) list.append(h('div', { class: 'ui-menu__sep', role: 'separator' }));
    if (!item.label) continue;
    const btn = h(
      'button',
      {
        type: 'button',
        class: ['ui-menu__item', item.danger && 'is-danger'],
        role: 'menuitem',
        tabindex: '-1',
        disabled: !!item.disabled,
      },
      iconEl(item.icon, 18),
      h('span', { class: 'ui-menu__label' }, item.label),
      item.hint ? h('span', { class: 'ui-menu__hint' }, item.hint) : null,
    );
    btn.addEventListener('click', () => activate(item));
    btn.addEventListener('pointermove', () => {
      if (document.activeElement !== btn && !btn.disabled) btn.focus({ preventScroll: true });
    });
    list.append(btn);
    entries.push(btn);
  }

  let closed = false;
  const handle = { anchor, el: list, close };

  function activate(item) {
    close(true);
    if (typeof item.onClick === 'function') item.onClick();
  }

  const headerBottom = () => headerBottomFor(anchor);

  function position() {
    if (!anchor.isConnected) {
      close(false);
      return;
    }
    const rect = anchor.getBoundingClientRect();
    const mw = list.offsetWidth;
    const mh = list.offsetHeight;
    const vw = document.documentElement.clientWidth;
    const vh = window.innerHeight;
    const gap = 6;
    let left = align === 'start' ? rect.left : rect.right - mw;
    left = Math.min(Math.max(8, left), vw - mw - 8);
    let top = rect.bottom + gap;
    let placement = 'bottom';
    if (top + mh > vh - 8 && rect.top - gap - mh > headerBottom() + 8) {
      top = rect.top - gap - mh;
      placement = 'top';
    }
    list.style.left = `${Math.round(left)}px`;
    list.style.top = `${Math.round(top)}px`;
    list.dataset.placement = placement;
    list.style.transformOrigin = `${align === 'start' ? 'left' : 'right'} ${placement === 'top' ? 'bottom' : 'top'}`;
  }

  function move(delta) {
    const enabled = entries.filter((b) => !b.disabled);
    if (!enabled.length) return;
    const idx = enabled.indexOf(document.activeElement);
    const next = idx === -1 ? (delta > 0 ? 0 : enabled.length - 1) : (idx + delta + enabled.length) % enabled.length;
    enabled[next].focus();
  }

  function onKeydown(e) {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      move(1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      move(-1);
    } else if (e.key === 'Home' || e.key === 'End') {
      e.preventDefault();
      const enabled = entries.filter((b) => !b.disabled);
      if (enabled.length) enabled[e.key === 'Home' ? 0 : enabled.length - 1].focus();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      close(true);
    } else if (e.key === 'Tab') {
      close(false);
    } else if (e.key.length === 1 && /\S/.test(e.key)) {
      const ch = e.key.toLowerCase();
      const hit = entries.find((b) => !b.disabled && b.textContent.trim().toLowerCase().startsWith(ch));
      if (hit) hit.focus();
    }
  }

  function onPointerDown(e) {
    if (!list.contains(e.target) && !anchor.contains(e.target)) close(false);
  }
  // Close once the anchor has scrolled under the header or out of the viewport instead
  // of leaving the menu floating detached above the header.
  function onScroll() {
    const rect = anchor.isConnected ? anchor.getBoundingClientRect() : null;
    if (rect && (rect.bottom <= headerBottom() || rect.top >= window.innerHeight)) close(false);
    else position();
  }
  function onResize() {
    close(false);
  }

  function close(restoreFocus) {
    if (closed) return;
    closed = true;
    if (activeMenu === handle) activeMenu = null;
    anchor.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onPointerDown, true);
    window.removeEventListener('scroll', onScroll, true);
    window.removeEventListener('resize', onResize);
    list.dataset.state = 'closing';
    afterAnimation(list, () => list.remove(), 200);
    if (restoreFocus && anchor.isConnected) anchor.focus({ preventScroll: true });
  }

  list.addEventListener('keydown', onKeydown);
  document.body.append(list);
  position();
  anchor.setAttribute('aria-haspopup', 'menu');
  anchor.setAttribute('aria-expanded', 'true');
  document.addEventListener('pointerdown', onPointerDown, true);
  window.addEventListener('scroll', onScroll, true);
  window.addEventListener('resize', onResize);
  activeMenu = handle;
  const first = entries.find((b) => !b.disabled);
  (first || list).focus({ preventScroll: true });
  return handle;
}

/* ------------------------------------------------------------ empty state */

export function emptyState({ icon: name = 'layers', title, text, action } = {}) {
  return h(
    'div',
    { class: 'ui-empty' },
    h('div', { class: 'ui-empty__art', 'aria-hidden': 'true' }, h('span', { class: 'ui-empty__tile' }, iconEl(name, 30))),
    title ? h('h2', { class: 'ui-empty__title' }, title) : null,
    text ? h('p', { class: 'ui-empty__text' }, text) : null,
    action ? h('div', { class: 'ui-empty__action' }, action) : null,
  );
}

const CALLOUT_ICONS = { neutral: 'info', accent: 'sparkles', success: 'checkCircle', warning: 'alert', danger: 'alertCircle' };

// Inline notice box, e.g. parser warnings.
export function callout({ tone = 'neutral', icon: name, title, text, children } = {}) {
  return h(
    'div',
    { class: ['ui-callout', `ui-callout--${tone}`], role: tone === 'danger' ? 'alert' : null },
    iconEl(name || CALLOUT_ICONS[tone] || 'info', 18),
    h('div', { class: 'ui-callout__body' }, title ? h('p', { class: 'ui-callout__title' }, title) : null, text ? h('p', null, text) : null, children || null),
  );
}

/* --------------------------------------------------------------- tooltips */

let tooltipEl = null;
let tooltipTarget = null;
let tooltipTimer = null;
let tooltipsReady = false;

function hideTooltip() {
  clearTimeout(tooltipTimer);
  tooltipTarget = null;
  if (tooltipEl) tooltipEl.dataset.visible = 'false';
}

function showTooltip(target) {
  const text = target.dataset.tooltip;
  if (!text || !target.isConnected) return;
  if (!tooltipEl) {
    tooltipEl = h('div', { class: 'ui-tooltip', 'aria-hidden': 'true' });
    document.body.append(tooltipEl);
  }
  tooltipEl.textContent = text;
  tooltipEl.dataset.visible = 'false';
  placeTooltip(target);
  tooltipEl.dataset.visible = 'true';
}

function placeTooltip(target) {
  const rect = target.getBoundingClientRect();
  const tw = tooltipEl.offsetWidth;
  const th = tooltipEl.offsetHeight;
  const vw = document.documentElement.clientWidth;
  let top = rect.top - th - 8;
  let placement = 'top';
  if (top < headerBottomFor(target) + 8) {
    top = rect.bottom + 8;
    placement = 'bottom';
  }
  const left = Math.min(Math.max(8, rect.left + rect.width / 2 - tw / 2), vw - tw - 8);
  tooltipEl.style.left = `${Math.round(left)}px`;
  tooltipEl.style.top = `${Math.round(top)}px`;
  tooltipEl.dataset.placement = placement;
}

// Moving keyboard focus scrolls the new target into view; its tooltip then follows the
// target (or still opens when its delay is up) instead of being dropped. Any other
// scroll hides the tooltip.
function onTooltipScroll() {
  const target = tooltipTarget;
  if (!target || target !== document.activeElement) return hideTooltip();
  const rect = target.getBoundingClientRect();
  if (rect.bottom <= headerBottomFor(target) || rect.top >= window.innerHeight) return hideTooltip();
  if (tooltipEl && tooltipEl.dataset.visible === 'true') placeTooltip(target);
}

function scheduleTooltip(target, delay) {
  clearTimeout(tooltipTimer);
  tooltipTarget = target;
  tooltipTimer = setTimeout(() => {
    if (tooltipTarget === target) showTooltip(target);
  }, delay);
}

// Controls whose tap already does something; tooltips on or inside them stay
// hover/focus-only. tabindex="-1" containers (#app, dialogs) and the tab stops added
// below do not count.
const TOOLTIP_STOP = 'data-tooltip-stop';
const TOOLTIP_INTERACTIVE = `a[href], button, input, select, textarea, summary, label, [contenteditable="true"], [tabindex]:not([tabindex="-1"]):not([${TOOLTIP_STOP}])`;

// A tooltip on a non-interactive element (the editor's flag markers) is the only place
// its text is shown, so that element also becomes a keyboard stop: Tab reaches it and
// keyboard focus opens the tooltip, as hover does for the mouse and a tap on touch.
// Elements that set their own tabindex are left alone.
function syncTooltipStop(el) {
  const owned = el.hasAttribute(TOOLTIP_STOP);
  if (!owned && el.hasAttribute('tabindex')) return;
  const wanted = el.hasAttribute('data-tooltip') && !el.closest(TOOLTIP_INTERACTIVE) && !el.closest('[aria-hidden="true"]');
  if (wanted === owned) return;
  if (wanted) {
    el.setAttribute('tabindex', '0');
    el.setAttribute(TOOLTIP_STOP, '');
  } else {
    el.removeAttribute('tabindex');
    el.removeAttribute(TOOLTIP_STOP);
  }
}

function watchTooltipStops() {
  if (typeof MutationObserver === 'undefined') return;
  const selector = `[data-tooltip], [${TOOLTIP_STOP}]`;
  const scan = (root) => {
    if (root.nodeType !== 1) return;
    if (root.matches(selector)) syncTooltipStop(root);
    for (const el of root.querySelectorAll(selector)) syncTooltipStop(el);
  };
  new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === 'attributes') syncTooltipStop(record.target);
      else record.addedNodes.forEach(scan);
    }
  }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['data-tooltip'] });
  scan(document.documentElement);
}

function ensureTooltips() {
  if (tooltipsReady || typeof document === 'undefined') return;
  tooltipsReady = true;
  const findTarget = (node) => (node && node.closest ? node.closest('[data-tooltip]') : null);
  document.addEventListener('pointerover', (e) => {
    if (e.pointerType === 'touch') return;
    const target = findTarget(e.target);
    if (target === tooltipTarget) return;
    if (target && !target.disabled) scheduleTooltip(target, tooltipEl && tooltipEl.dataset.visible === 'true' ? 60 : 450);
    else hideTooltip();
  });
  document.addEventListener('pointerout', (e) => {
    if (e.pointerType === 'touch') return;
    if (tooltipTarget && !tooltipTarget.contains(e.relatedTarget)) hideTooltip();
  });
  // Touch has no hover: tapping a non-interactive target (e.g. the editor's flag marker)
  // shows its text until the next tap, scroll or key press. A scroll gesture cancels
  // the pointer, so it never gets here.
  document.addEventListener('pointerup', (e) => {
    if (e.pointerType !== 'touch') return;
    const target = findTarget(e.target);
    if (!target || target.closest(TOOLTIP_INTERACTIVE)) return;
    clearTimeout(tooltipTimer);
    tooltipTarget = target;
    showTooltip(target);
  });
  document.addEventListener('focusin', (e) => {
    const target = findTarget(e.target);
    if (target && target === e.target && target.matches(':focus-visible')) scheduleTooltip(target, 250);
  });
  // Only focus leaving the tooltip's own target hides it: a tap on a marker also blurs
  // whatever field had focus, which must not hide the tooltip the tap just opened.
  document.addEventListener('focusout', (e) => {
    if (tooltipTarget && tooltipTarget.contains(e.target)) hideTooltip();
  });
  document.addEventListener('pointerdown', hideTooltip, true);
  document.addEventListener('keydown', hideTooltip, true);
  window.addEventListener('scroll', onTooltipScroll, true);
  watchTooltipStops();
}

/* -------------------------------------------------------------- overlays */

// Closes menus, tooltips and modals (not toasts). The router calls this on navigation.
export function closeOverlays() {
  hideTooltip();
  closeMenu();
  for (const entry of modalStack.slice().reverse()) entry.close('route');
}

export function hasOpenOverlay() {
  return modalStack.length > 0 || !!activeMenu;
}
