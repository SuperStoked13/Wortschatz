// Karteikarten card stage (port of the Mac's FlashcardCard.swift): the card on its stack, turning
// over in 3D (always the same way round, lifted halfway, a streak of light), sealed and gliding off
// to its side when sorted, rising from the stack, coming back on «Zurück», following swipes.
// Smooth by design: both faces are built once per card and every movement is a Web Animation of
// transform / opacity only, sampled from the Mac's curves. Reduced motion: sides cross-fade, cards
// only fade. The pure helpers at the top are tested under jsc.

import { h, prefersReducedMotion, setTextAttrs } from '../lib/dom.js';
import { bcp47, textAttrs } from '../lib/labels.js';
import { canSpeak } from '../lib/speech.js';
import { iconButton, kbd } from '../ui/components.js';
import { icon } from '../ui/icons.js';

/* ---------------------------------------------------------- pure helpers */

// Timings (ms) and distances (px) of FlashcardMotion; curves are cubic-bezier control points.
export const MOTION = Object.freeze({
  flip: { duration: 620, curve: [0.36, 0, 0.2, 1] },
  flipLift: 0.045,
  flipRise: 10,
  glide: { duration: 500, delay: 60, curve: [0.42, 0, 0.72, 0.72] },
  fling: { duration: 420, curve: [0.2, 0.55, 0.35, 1] },
  snapBack: { duration: 360, curve: [0.2, 0.9, 0.3, 1] },
  arrive: { duration: 480, delay: 40, curve: [0.22, 1, 0.36, 1] },
  sink: { duration: 300, curve: [0.32, 0, 0.67, 0] },
  fade: { duration: 200, curve: [0.42, 0, 0.58, 1] },
  glideDistance: 280,
  glideDrop: 24,
  glideLean: 6,
  glideShrink: 0.06,
  riseDistance: 16,
  riseScale: 0.965,
  returnDistance: 140,
  returnScale: 0.94,
});

// The stack under the card: each edge hangs 9 px lower and is 18 px narrower on each side.
export const STACK = Object.freeze({ peekDrop: 9, peekInset: 18, depth: 18, levels: 2 });

// The card's height for the room the column has: an index-card shape, 240…440 px.
export function cardHeightFor(width, available) {
  const shaped = width * 0.58;
  return Math.round(Math.max(240, Math.min(440, Math.min(shaped, available))));
}

// Type size of a side's text by its length (Typography.flashcard): 46 / 36 / 28 px semibold,
// 22 px medium for long texts.
export function cardTextSize(text) {
  const n = Array.from(String(text == null ? '' : text)).length;
  if (n < 24) return { size: 46, weight: 600 };
  if (n < 60) return { size: 36, weight: 600 };
  if (n < 140) return { size: 28, weight: 600 };
  return { size: 22, weight: 500 };
}

// A CSS cubic-bezier timing function as t -> eased progress.
export function cubicBezier(x1, y1, x2, y2) {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const sx = (t) => ((ax * t + bx) * t + cx) * t;
  const sy = (t) => ((ay * t + by) * t + cy) * t;
  const dsx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (!(x > 0)) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sx(t) - x;
      if (Math.abs(err) < 1e-7) return sy(t);
      const d = dsx(t);
      if (Math.abs(d) < 1e-6) break;
      t -= err / d;
    }
    if (!(t >= 0 && t <= 1) || Math.abs(sx(t) - x) > 1e-5) {
      let lo = 0;
      let hi = 1;
      t = x;
      for (let i = 0; i < 40; i++) {
        const v = sx(t);
        if (Math.abs(v - x) < 1e-7) break;
        if (v < x) lo = t;
        else hi = t;
        t = (lo + hi) / 2;
      }
    }
    return sy(t);
  };
}

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const smooth = (v) => v * v * (3 - 2 * v);

// Where in its turn the card is at `angle` (180° per half-turn), as FlashcardMotion.turn: the
// side up, the tilt (-90…90), the lift (0 flat … 1 edge-on), and the streak of light (strength and
// position in card heights, 0 top … 1 bottom: it rises from the lower part to the upper third and
// has faded exactly when the card lies flat).
export function turnAt(angle) {
  const rem = angle % 360;
  const turned = rem < 0 ? rem + 360 : rem;
  const showsBack = turned > 90 && turned <= 270;
  const tilt = showsBack ? turned - 180 : turned > 270 ? turned - 360 : turned;
  const lift = Math.sin((Math.min(1, Math.abs(tilt) / 90) * Math.PI) / 2);
  const through = tilt >= 0 ? tilt / 180 : 1 + tilt / 180;
  return { showsBack, tilt, lift, sheen: Math.abs(Math.sin((tilt * Math.PI) / 180)), sheenPosition: 0.9 - 0.8 * through };
}

// A sorted (or swiped) card on its way to its side, as FlashcardMotion's GlideEffect: `offset`
// 0 on the deck … 1 gone to the right (-1 left); it drops a little, leans toward its side, gets
// smaller and fades from about a third of the way on (`fades` 0: not at all, under a swipe).
export function glideAt(offset, fades = 1) {
  const p = Math.abs(offset);
  const fade = clamp01((p - 0.3) / 0.65);
  return {
    x: MOTION.glideDistance * offset,
    y: MOTION.glideDrop * p * p,
    rotate: MOTION.glideLean * offset,
    scale: 1 - MOTION.glideShrink * p,
    opacity: 1 - clamp01(fades) * smooth(fade),
  };
}

export function glideTransform(g) {
  return `translate(${g.x.toFixed(2)}px, ${g.y.toFixed(2)}px) rotate(${g.rotate.toFixed(3)}deg) scale(${g.scale.toFixed(4)})`;
}

// The turning layer at `angle`: lifted and grown toward you halfway, turned around the axis
// leaning 0.12 off the horizontal.
export function turnTransform(angle) {
  const t = turnAt(angle);
  return `translateY(${(-MOTION.flipRise * t.lift).toFixed(2)}px) scale(${(1 + MOTION.flipLift * t.lift).toFixed(4)}) rotate3d(1, 0.12, 0, ${angle.toFixed(2)}deg)`;
}

// Keyframes for `fn(eased progress)` sampled at `steps` points along a curve (played linearly,
// so the derived values follow the Mac's curves exactly between the samples).
export function sampledFrames(curve, fn, steps = 30) {
  const ease = cubicBezier(...curve);
  const frames = [];
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    frames.push({ offset: t, ...fn(ease(t)) });
  }
  return frames;
}

const bezierCss = (c) => `cubic-bezier(${c.join(', ')})`;
const direction = (verdict) => (verdict === 'know' ? 1 : -1);
const hasText = (text) => typeof text === 'string' && text.trim() !== '';

/* ------------------------------------------------------------- the stage */

/**
 * The deck area: the stack and the cards on it.
 * handlers: { onSpeak(), onStar(), onEdit() } for the tools of the current card.
 * apple: show ⌘ shortcuts (else «Strg+»).
 * Card info: { key, id, starred, up: 'front'|'back', front: Side, back: Side } with
 * Side = { text, lang, label }.
 */
export function createCardStage({ onSpeak, onStar, onEdit, apple = false }) {
  const edges = [1, 0].map((level) =>
    h('div', {
      class: ['fc-stack__edge', `fc-stack__edge--${level}`],
      style: { '--fc-drop': `${STACK.peekDrop * (level + 1)}px`, '--fc-inset': `${STACK.peekInset * (level + 1)}px` },
    }),
  );
  const stack = h('div', { class: 'fc-stack', 'aria-hidden': 'true', dataset: { count: '0' } }, edges);
  const layer = h('div', { class: 'fc-deck__cards' });
  const el = h('div', { class: 'fc-deck' }, stack, layer);

  let current = null; // the card on the deck
  let leaving = []; // cards still leaving, oldest first
  let fitFrame = 0;
  let height = 0;
  const fitQueue = new Set();
  const shortcut = (key) => (apple ? `⌘${key}` : `Strg+${key}`);
  const reduced = () => prefersReducedMotion();

  /* ---------------------------------------------------------- building */

  function buildFace(which) {
    const label = h('span', { class: 'fc-face__label' });
    const speak = iconButton({ icon: 'volume', label: 'Vorlesen', size: 'sm', onClick: () => onSpeak(), attrs: { 'aria-keyshortcuts': apple ? 'Meta+R' : 'Control+R' } });
    speak.dataset.tooltip = `Vorlesen (${shortcut('R')})`;
    const star = iconButton({ icon: 'star', label: 'Markieren', size: 'sm', pressed: false, onClick: () => onStar(), attrs: { class: 'ui-star', 'aria-keyshortcuts': apple ? 'Meta+D' : 'Control+D' } });
    star.dataset.tooltip = `Markieren (${shortcut('D')})`;
    const edit = iconButton({ icon: 'edit', label: 'Karte bearbeiten', size: 'sm', onClick: () => onEdit(), attrs: { 'aria-keyshortcuts': apple ? 'Meta+E' : 'Control+E' } });
    edit.dataset.tooltip = `Karte bearbeiten (${shortcut('E')})`;
    // A mouse press on a tool leaves the focus where it was (on the step's primary button), so
    // Space and Enter go on turning cards instead of pressing the star or 🔊 again.
    for (const tool of [speak, star, edit]) tool.addEventListener('mousedown', (e) => e.preventDefault());
    const text = h('p', { class: 'fc-face__text' });
    const body = h('div', { class: 'fc-face__body' }, text);
    const seal = h(
      'div',
      { class: 'fc-face__seal', 'aria-hidden': 'true' },
      h('span', { class: 'fc-face__ripple' }),
      h(
        'span',
        { class: 'fc-face__ring' },
        icon('check', { size: 70, strokeWidth: 2.4, className: 'fc-face__seal-know' }),
        icon('rotate', { size: 66, strokeWidth: 2.4, className: 'fc-face__seal-learning' }),
      ),
    );
    const sheen = h('div', { class: 'fc-face__sheen', 'aria-hidden': 'true' });
    const face = h(
      'div',
      { class: ['fc-face', `fc-face--${which}`] },
      h('div', { class: 'fc-face__wash', 'aria-hidden': 'true' }),
      seal,
      h('div', { class: 'fc-face__head' }, label, h('div', { class: 'fc-face__tools' }, speak, star, edit)),
      body,
      h('div', { class: 'fc-face__hint', 'aria-hidden': 'true' }, kbd('␣'), h('span', null, which === 'back' ? 'Vorderseite' : 'Umdrehen')),
      sheen,
    );
    return { el: face, label, text, body, speak, star, edit, sheen, shown: null, size: 46 };
  }

  function setSide(face, side) {
    const shown = `${side.label}\u0000${side.lang}\u0000${side.text}`;
    if (face.shown === shown) return;
    face.shown = shown;
    face.label.textContent = side.label;
    const filled = hasText(side.text);
    face.text.classList.toggle('fc-face__text--empty', !filled);
    face.text.textContent = filled ? side.text : 'Keine Angabe';
    // «Keine Angabe» is German, without the side's language and direction.
    setTextAttrs(face.text, filled ? textAttrs(side.lang) : {});
    const { size, weight } = filled ? cardTextSize(side.text) : { size: 20, weight: 500 };
    face.size = size;
    face.text.style.fontSize = `${size}px`;
    face.text.style.fontWeight = String(weight);
    face.speak.hidden = !(filled && canSpeak() && !!bcp47(side.lang));
  }

  function setStarred(card, starred) {
    for (const face of [card.faces.front, card.faces.back]) {
      const label = starred ? 'Markierung entfernen' : 'Markieren';
      if (face.star.getAttribute('aria-pressed') === String(starred)) continue;
      face.star.setPressed(starred);
      face.star.setIcon(starred ? 'starFilled' : 'star');
      face.star.setAttribute('aria-label', label);
      face.star.dataset.tooltip = `${label} (${shortcut('D')})`;
    }
  }

  function setInfo(card, info) {
    card.info = info;
    setSide(card.faces.front, info.front);
    setSide(card.faces.back, info.back);
    const popped = card.starred === false && info.starred;
    setStarred(card, !!info.starred);
    if (popped) {
      const face = card.faces[card.up];
      face.star.classList.remove('is-popping');
      void face.star.offsetWidth;
      face.star.classList.add('is-popping');
    }
    card.starred = !!info.starred;
    queueFit(card);
  }

  function buildCard(info) {
    const faces = { front: buildFace('front'), back: buildFace('back') };
    const turn = h('div', { class: 'fc-card__turn' }, faces.front.el, faces.back.el);
    const glide = h('div', { class: 'fc-card__glide' }, turn);
    const move = h('div', { class: 'fc-card__move' }, glide);
    const root = h('div', { class: 'fc-card is-current', role: 'group', 'aria-roledescription': 'Karteikarte', dataset: { up: info.up } }, move);
    const card = { key: info.key, id: info.id, info: null, el: root, move, glide, turn, faces, up: info.up, turns: info.up === 'back' ? 1 : 0, starred: null, anims: {}, timer: 0, kind: null };
    for (const face of [faces.front, faces.back]) face.star.addEventListener('animationend', () => face.star.classList.remove('is-popping'));
    setInfo(card, info);
    return card;
  }

  /* ---------------------------------------------------------- text fit */

  // Long texts shrink (down to 0.55 of their size) until they fit the card; beyond that the
  // seventh line ends with an ellipsis (CSS line clamp).
  function fitFace(face) {
    const text = face.text;
    if (!text.isConnected || text.classList.contains('fc-face__text--empty')) return;
    const box = face.body.clientHeight;
    if (!box) return;
    const pad = typeof getComputedStyle === 'function' ? getComputedStyle(face.body) : null;
    const room = box - ((pad && parseFloat(pad.paddingTop)) || 0) - ((pad && parseFloat(pad.paddingBottom)) || 0);
    text.style.fontSize = `${face.size}px`;
    if (text.scrollHeight <= room + 1) return;
    let lo = face.size * 0.55;
    let hi = face.size;
    for (let i = 0; i < 6; i++) {
      const mid = (lo + hi) / 2;
      text.style.fontSize = `${mid}px`;
      if (text.scrollHeight <= room + 1) lo = mid;
      else hi = mid;
    }
    text.style.fontSize = `${Math.floor(lo)}px`;
  }

  function queueFit(card) {
    fitQueue.add(card);
    if (fitFrame || typeof requestAnimationFrame !== 'function') return;
    fitFrame = requestAnimationFrame(() => {
      fitFrame = 0;
      const cards = Array.from(fitQueue);
      fitQueue.clear();
      for (const c of cards) {
        fitFace(c.faces.front);
        fitFace(c.faces.back);
      }
    });
  }

  /* --------------------------------------------------------- animating */

  function play(target, frames, options) {
    if (typeof target.animate !== 'function') return null;
    try {
      return target.animate(frames, options);
    } catch {
      return null;
    }
  }

  function stop(card, name) {
    const anim = card.anims[name];
    card.anims[name] = null;
    if (anim) anim.cancel();
  }

  // Freezes a layer where its animation has it now (inline style) and stops the animation.
  function freeze(card, name) {
    const anim = card.anims[name];
    card.anims[name] = null;
    if (!anim) return;
    try {
      if (typeof anim.commitStyles === 'function') anim.commitStyles();
    } catch {
      /* not rendered: it ends where it would have */
    }
    anim.cancel();
  }

  function arrive(card, from, delay = 0) {
    if (reduced()) {
      card.anims.move = play(card.move, [{ opacity: 0 }, { opacity: 1 }], { duration: MOTION.fade.duration, easing: bezierCss(MOTION.fade.curve), fill: 'backwards' });
      return;
    }
    card.anims.move = play(card.move, [{ transform: from, opacity: 0 }, { transform: 'none', opacity: 1 }], {
      duration: MOTION.arrive.duration,
      delay,
      easing: bezierCss(MOTION.arrive.curve),
      fill: 'backwards',
    });
  }

  function release(card) {
    clearTimeout(card.timer);
    for (const name of Object.keys(card.anims)) stop(card, name);
    card.el.remove();
    leaving = leaving.filter((c) => c !== card);
    fitQueue.delete(card);
  }

  // Removed once its exit is over (it is invisible by then); a timer backs up the animation.
  function releaseAfter(card, anim, ms) {
    clearTimeout(card.timer);
    card.timer = setTimeout(() => release(card), ms + 120);
    if (anim) anim.onfinish = () => release(card);
  }

  function markLeaving(card, kind) {
    card.kind = kind;
    card.el.classList.remove('is-current', 'is-swiping', 'is-armed');
    card.el.classList.add('is-leaving');
    card.el.setAttribute('aria-hidden', 'true');
    card.el.inert = true;
    leaving.push(card);
    // Fast sorting: only the last few are still worth drawing.
    while (leaving.length > 3) release(leaving[0]);
  }

  /* ------------------------------------------------------------ public */

  // Puts a new current card on the deck. arrival: 'stack' (the next card rises), 'side' (back
  // from the side `verdict` sent it to), 'none'.
  function present(info, { arrival = 'stack', verdict = 'know' } = {}) {
    if (current) drop();
    const card = buildCard(info);
    current = card;
    layer.append(card.el);
    if (arrival === 'stack') {
      arrive(card, `translateY(${MOTION.riseDistance}px) scale(${MOTION.riseScale})`, MOTION.arrive.delay);
    } else if (arrival === 'side') {
      arrive(card, `translate(${direction(verdict) * MOTION.returnDistance}px, ${MOTION.riseDistance}px) scale(${MOTION.returnScale})`);
    }
    queueFit(card);
    return card;
  }

  // The current card's texts, labels or star changed (same card).
  function update(info) {
    if (current && current.key === info.key) setInfo(current, info);
  }

  // Turns the current card so that `showBack` is up: one more half-turn, always the same way
  // round, continuing from where a running turn has it.
  function flip(showBack, card = current) {
    if (!card) return;
    const target = showBack ? 'back' : 'front';
    if (reduced()) {
      crossFade(card, target);
      return;
    }
    let from = card.turns * 180;
    const running = card.anims.turn;
    if (running && card.turnFrom != null) {
      const t = clamp01((Number(running.currentTime) || 0) / MOTION.flip.duration);
      from = card.turnFrom + (card.turnTo - card.turnFrom) * cubicBezier(...MOTION.flip.curve)(t);
    }
    stop(card, 'turn');
    stop(card, 'sheenFront');
    stop(card, 'sheenBack');
    let next = card.turns + 1;
    if ((next % 2 === 1) !== showBack) next += 1;
    card.turns = next;
    card.up = target;
    const to = next * 180;
    card.turnFrom = from;
    card.turnTo = to;
    card.el.classList.add('is-turning');
    const turnFrames = sampledFrames(MOTION.flip.curve, (e) => ({ transform: turnTransform(from + (to - from) * e) }), 36);
    const sheenFrames = sampledFrames(
      MOTION.flip.curve,
      (e) => {
        const t = turnAt(from + (to - from) * e);
        return { opacity: t.sheen.toFixed(3), transform: `translateY(${((t.sheenPosition - 0.5) * 100).toFixed(2)}%)` };
      },
      36,
    );
    // Held at its end until the card is handed back to its resting state in the same frame
    // (no frame of the wrong side between the animation's end and the clean-up).
    const options = { duration: MOTION.flip.duration, easing: 'linear', fill: 'forwards' };
    const anim = play(card.turn, turnFrames, options);
    card.anims.turn = anim;
    card.anims.sheenFront = play(card.faces.front.sheen, sheenFrames, options);
    card.anims.sheenBack = play(card.faces.back.sheen, sheenFrames, options);
    const land = () => {
      if (card.anims.turn !== anim) return;
      stop(card, 'turn');
      stop(card, 'sheenFront');
      stop(card, 'sheenBack');
      card.turnFrom = null;
      card.el.classList.remove('is-turning');
      card.el.dataset.up = card.up;
    };
    if (anim) anim.onfinish = land;
    else land();
  }

  // Reduced motion: the sides cross-fade, nothing turns.
  function crossFade(card, target) {
    const other = target === 'back' ? 'front' : 'back';
    card.up = target;
    card.turns = target === 'back' ? 1 : 0;
    stop(card, 'fadeIn');
    stop(card, 'fadeOut');
    card.el.dataset.up = target;
    card.el.classList.add('is-xfade');
    const options = { duration: MOTION.fade.duration, easing: bezierCss(MOTION.fade.curve) };
    card.anims.fadeIn = play(card.faces[target].el, [{ opacity: 0 }, { opacity: 1 }], options);
    const out = play(card.faces[other].el, [{ opacity: 1 }, { opacity: 0 }], { ...options, fill: 'forwards' });
    card.anims.fadeOut = out;
    const done = () => {
      if (card.anims.fadeOut !== out) return;
      stop(card, 'fadeOut');
      card.el.classList.remove('is-xfade');
    };
    if (out) out.onfinish = done;
    else done();
  }

  // The current card leaves. 'sorted': the verdict lands on it and it glides off to its side
  // (`flung`: let go after a swipe, it flies on from `releaseOffset`); 'sink': it goes back under
  // the stack ("Zurück" brought the previous card back).
  function depart(kind, { verdict = 'know', flung = false, releaseOffset = 0 } = {}) {
    const card = current;
    if (!card) return;
    current = null;
    markLeaving(card, kind);
    stop(card, 'settle');
    if (kind === 'sorted') {
      card.verdict = verdict;
      card.el.dataset.verdict = verdict;
      card.el.style.setProperty('--fc-wash', '1');
      card.el.classList.add('is-sealed');
      card.el.style.zIndex = '3';
      let anim;
      if (reduced()) {
        stop(card, 'move');
        anim = play(card.move, [{ opacity: 1 }, { opacity: 0 }], { duration: MOTION.fade.duration, easing: bezierCss(MOTION.fade.curve), fill: 'forwards' });
        card.anims.move = anim;
        releaseAfter(card, anim, MOTION.fade.duration);
        return;
      }
      stop(card, 'glide');
      const dir = direction(verdict);
      const start = Math.max(-1, Math.min(1, (releaseOffset || 0) / MOTION.glideDistance));
      const timing = flung ? MOTION.fling : MOTION.glide;
      // A card swiped a little to one side and then sorted to the other glides across the
      // middle; it only starts to fade once it is let go.
      const fadesFrom = start === 0 && !flung ? 1 : 0;
      const frames = sampledFrames(timing.curve, (e) => {
        const g = glideAt(start + (dir - start) * e, fadesFrom + (1 - fadesFrom) * e);
        return { transform: glideTransform(g), opacity: g.opacity.toFixed(3) };
      });
      anim = play(card.glide, frames, { duration: timing.duration, delay: timing.delay || 0, easing: 'linear', fill: 'both' });
      card.glide.style.transform = '';
      card.anims.glide = anim;
      releaseAfter(card, anim, (timing.delay || 0) + timing.duration);
    } else {
      // Under the card that comes back, sinking into the stack.
      card.el.style.zIndex = '1';
      stop(card, 'move');
      const anim = reduced()
        ? play(card.move, [{ opacity: 1 }, { opacity: 0 }], { duration: MOTION.fade.duration, easing: bezierCss(MOTION.fade.curve), fill: 'forwards' })
        : play(card.move, [{ transform: 'none', opacity: 1 }, { transform: `translateY(${MOTION.riseDistance}px) scale(${MOTION.riseScale})`, opacity: 0 }], {
            duration: MOTION.sink.duration,
            easing: bezierCss(MOTION.sink.curve),
            fill: 'forwards',
          });
      card.anims.move = anim;
      releaseAfter(card, anim, reduced() ? MOTION.fade.duration : MOTION.sink.duration);
    }
  }

  // "Zurück" while the sorted card is still on its way out: it comes back along its own path,
  // front side up. False when it is already gone (the caller brings a new one from the side).
  function recall(info) {
    const card = leaving.find((c) => c.key === info.key && c.kind === 'sorted');
    if (!card) return false;
    if (current) drop();
    clearTimeout(card.timer);
    leaving = leaving.filter((c) => c !== card);
    freeze(card, 'glide');
    freeze(card, 'move');
    const fromGlide = { transform: card.glide.style.transform || 'none', opacity: card.glide.style.opacity || '1' };
    const fromMove = { transform: card.move.style.transform || 'none', opacity: card.move.style.opacity || '1' };
    for (const layerEl of [card.glide, card.move]) {
      layerEl.style.transform = '';
      layerEl.style.opacity = '';
    }
    card.kind = null;
    card.el.classList.remove('is-leaving', 'is-sealed', 'is-armed');
    card.el.classList.add('is-current');
    card.el.removeAttribute('aria-hidden');
    card.el.inert = false;
    card.el.style.zIndex = '';
    card.el.style.setProperty('--fc-wash', '0');
    delete card.el.dataset.verdict;
    current = card;
    const options = { duration: reduced() ? MOTION.fade.duration : MOTION.arrive.duration, easing: bezierCss(reduced() ? MOTION.fade.curve : MOTION.arrive.curve) };
    card.anims.glide = play(card.glide, [fromGlide, { transform: 'none', opacity: 1 }], options);
    card.anims.move = play(card.move, [fromMove, { transform: 'none', opacity: 1 }], options);
    setInfo(card, info);
    if (card.up !== info.up) flip(info.up === 'back', card);
    return true;
  }

  // Takes the current card away at once (or with a short fade): a restart, a deleted card.
  function drop({ fade = false } = {}) {
    const card = current;
    if (!card) return;
    current = null;
    if (!fade) {
      card.el.remove();
      for (const name of Object.keys(card.anims)) stop(card, name);
      return;
    }
    markLeaving(card, 'drop');
    card.el.style.zIndex = '1';
    const anim = play(card.move, [{ opacity: 1 }, { opacity: 0 }], { duration: 120, easing: 'ease-out', fill: 'forwards' });
    releaseAfter(card, anim, 120);
  }

  // ------------------------------------------------------------- swiping
  // The current card follows a swipe (`offset` px, + right): on the glide, not fading, washed in
  // the colour of the side it heads for; past the threshold (`armed`) the verdict's seal settles.
  function swipeTo({ offset, lean, armed }) {
    const card = current;
    if (!card) return;
    stop(card, 'settle');
    stop(card, 'glide');
    card.el.classList.add('is-swiping');
    card.glide.style.transform = reduced() ? `translateX(${offset.toFixed(2)}px)` : glideTransform(glideAt(offset / MOTION.glideDistance, 0));
    card.el.style.setProperty('--fc-wash', Math.abs(lean).toFixed(3));
    if (lean !== 0) card.el.dataset.verdict = lean > 0 ? 'know' : 'stillLearning';
    card.el.classList.toggle('is-armed', !!armed);
  }

  // Let go before the threshold (or interrupted): back to the middle, landing softly.
  function swipeSettle(fromOffset) {
    const card = current;
    if (!card) return;
    card.el.classList.remove('is-armed', 'is-swiping');
    card.el.style.setProperty('--fc-wash', '0');
    stop(card, 'settle');
    const from = fromOffset || 0;
    card.glide.style.transform = '';
    if (!from) return;
    const anim = reduced()
      ? play(card.glide, [{ transform: `translateX(${from}px)` }, { transform: 'none' }], { duration: MOTION.fade.duration, easing: bezierCss(MOTION.fade.curve) })
      : play(
          card.glide,
          sampledFrames(MOTION.snapBack.curve, (e) => ({ transform: glideTransform(glideAt(((1 - e) * from) / MOTION.glideDistance, 0)) }), 24),
          { duration: MOTION.snapBack.duration, easing: 'linear' },
        );
    card.anims.settle = anim;
  }

  // ------------------------------------------------------------- the rest
  function setStack(count) {
    stack.dataset.count = String(Math.max(0, Math.min(STACK.levels, count)));
  }

  function setHeight(px) {
    if (px === height) return;
    height = px;
    el.style.setProperty('--fc-card-h', `${px}px`);
    if (current) queueFit(current);
  }

  function clear() {
    if (current) drop();
    for (const card of leaving.slice()) release(card);
    setStack(0);
  }

  return {
    el,
    present,
    update,
    flip,
    depart,
    recall,
    drop,
    swipeTo,
    swipeSettle,
    setStack,
    setHeight,
    clear,
    get current() {
      return current ? { key: current.key, id: current.id, up: current.up } : null;
    },
    get busy() {
      return leaving.length > 0;
    },
    dispose() {
      if (fitFrame && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(fitFrame);
      fitFrame = 0;
      clear();
    },
  };
}
