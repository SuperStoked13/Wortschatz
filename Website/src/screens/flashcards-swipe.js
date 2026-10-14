// Swiping a flashcard (port of the Mac app's FlashcardSwipe.swift): the current card follows a
// mouse, touch or pen drag, or two fingers on a precision touchpad (horizontal wheel events),
// freely up to 170 px and then reluctantly. Past 110 px the verdict settles on it and letting go
// sorts it to that side (right: «Weiss ich», left: «Lerne ich noch»); a quick flick sorts it too.
// Anything else springs it back. A click or tap without a drag still turns the card over.
// createSwipeTracker() is pure (tested under jsc); bindSwipe() wires DOM events at call time.

export const SWIPE = Object.freeze({
  threshold: 110, // px: letting go past this sorts the card
  freeTravel: 170, // px: beyond this the card follows more and more reluctantly
  rubber: 0.4, // how much of the travel past freeTravel still moves the card
  projectionMs: 140, // a flick: where the card would be this long after letting go decides
  flingFactor: 1.2, // … if that is past threshold × 1.2
  minTravel: 16, // px a flick must have moved
  sampleMs: 120, // velocity over the samples of the last 120 ms
  staleMs: 80, // no velocity when the last sample is older than this at release
  startPx: 6, // a press must move this far before it is a drag (else a click)
  wheelGapMs: 140, // wheel events have no phase: a gesture ends after this pause
  axisBias: 1.2, // a wheel gesture belongs to the card when it starts this much more sideways
});

// Where the card is drawn for a travel (+ to the right), with the rubber band past freeTravel.
export function swipeOffset(travel) {
  const distance = Math.abs(travel);
  if (!(distance > SWIPE.freeTravel)) return travel || 0;
  return Math.sign(travel) * (SWIPE.freeTravel + (distance - SWIPE.freeTravel) * SWIPE.rubber);
}

// -1 («Lerne ich noch») … 1 («Weiss ich»): how far toward the threshold.
export function swipeLean(offset) {
  return Math.max(-1, Math.min(1, (offset || 0) / SWIPE.threshold));
}

export function swipeVerdict(offset) {
  return offset >= 0 ? 'know' : 'stillLearning';
}

// The verdict the card would get if let go now (null: it springs back).
export function armedVerdict(offset) {
  return Math.abs(offset) >= SWIPE.threshold ? swipeVerdict(offset) : null;
}

// One swipe of the current card. Times are in ms (event.timeStamp / performance.now()).
export function createSwipeTracker() {
  let travel = 0;
  let tracking = false;
  let samples = [];

  function velocity(at) {
    const first = samples[0];
    const last = samples[samples.length - 1];
    if (!first || !last || !(at - last.time < SWIPE.staleMs)) return 0;
    const span = last.time - first.time;
    if (!(span > 4)) return 0;
    return ((last.travel - first.travel) / span) * 1000; // px per second
  }

  function update(next, time) {
    travel = next;
    samples.push({ time, travel: next });
    samples = samples.filter((s) => time - s.time <= SWIPE.sampleMs);
  }

  return {
    get travel() {
      return travel;
    },
    get offset() {
      return swipeOffset(travel);
    },
    get lean() {
      return swipeLean(swipeOffset(travel));
    },
    get armed() {
      return armedVerdict(swipeOffset(travel));
    },
    get isTracking() {
      return tracking;
    },
    begin(time) {
      tracking = true;
      travel = 0;
      samples = [{ time, travel: 0 }];
    },
    // A drag: where it has taken the card from where it started.
    moveTo(translation, time) {
      if (tracking) update(translation, time);
    },
    // Wheel events: by how much.
    moveBy(delta, time) {
      if (tracking) update(travel + delta, time);
    },
    // Let go at `time`: the side to sort the card to, or null (it springs back).
    end(time) {
      if (!tracking) return null;
      tracking = false;
      const offset = swipeOffset(travel);
      if (Math.abs(offset) >= SWIPE.threshold) return swipeVerdict(offset);
      const projected = travel + (velocity(time) * SWIPE.projectionMs) / 1000;
      if (
        Math.abs(projected) >= SWIPE.threshold * SWIPE.flingFactor &&
        Math.abs(travel) >= SWIPE.minTravel &&
        projected < 0 === travel < 0
      ) {
        return swipeVerdict(projected);
      }
      return null;
    },
    reset() {
      tracking = false;
      travel = 0;
      samples = [];
    },
  };
}

const TOOLS = '.fc-face__tools, button, a, input, textarea, select';

/**
 * Wires the swipe to the deck.
 * surface: the deck element (cards are `.fc-card.is-current` inside it)
 * wheelTarget: the element whose horizontal wheel gestures move the card
 * canStart() -> boolean: a card is up and nothing covers the screen
 * onMove({ offset, lean, armed }): the card follows (called at most once per frame)
 * onEnd(verdict | null, offset): let go; a verdict sorts the card, null springs it back
 * onCancel(offset): the swipe was interrupted (the card springs back from `offset`)
 * onTap(): a click or tap without a drag on the current card
 * Returns { cancel({ silent }), dispose(), isTracking, offset }; a silent cancel only forgets the
 * swipe (the card is sorted from where it is by a key, or taken away).
 */
export function bindSwipe({ surface, wheelTarget, canStart, onMove, onEnd, onCancel, onTap }) {
  const tracker = createSwipeTracker();
  let pointer = null; // { id, x0, y0, dragging, card }
  let suppressClickUntil = 0;
  let frame = 0;
  // Wheel gesture: 'none' | 'undecided' | 'horizontal' | 'vertical'
  const wheel = { axis: 'none', px: 0, py: 0, last: 0, timer: 0 };

  function emitMove() {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      if (tracker.isTracking) onMove({ offset: tracker.offset, lean: tracker.lean, armed: tracker.armed });
    });
  }

  function flushMove() {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
  }

  function finish(time) {
    flushMove();
    const offset = tracker.offset;
    const verdict = tracker.end(time);
    tracker.reset();
    onEnd(verdict, offset);
  }

  function cancel({ silent = false } = {}) {
    const wasTracking = tracker.isTracking;
    const offset = tracker.offset;
    if (pointer && pointer.card && pointer.id != null) {
      try {
        pointer.card.releasePointerCapture(pointer.id);
      } catch {
        /* already released */
      }
    }
    pointer = null;
    clearTimeout(wheel.timer);
    wheel.axis = 'none';
    flushMove();
    tracker.reset();
    if (wasTracking && !silent) onCancel(offset);
  }

  // ------------------------------------------------------------ pointers
  function onPointerDown(e) {
    if ((e.pointerType === 'mouse' && e.button !== 0) || e.isPrimary === false) return;
    if (pointer) {
      if (pointer.id === e.pointerId) return;
      // A new press: the last one ended where it was not heard (no capture); it is over.
      cancel();
    }
    const t = e.target;
    const card = t && t.closest ? t.closest('.fc-card.is-current') : null;
    if (!card || !surface.contains(card) || t.closest(TOOLS)) return;
    pointer = { id: e.pointerId, x0: e.clientX, y0: e.clientY, dragging: false, card, type: e.pointerType };
    try {
      card.setPointerCapture(e.pointerId);
    } catch {
      /* not capturable: moves outside the card are missed */
    }
    // No text selection or focus change from a press on the card.
    if (e.pointerType === 'mouse') e.preventDefault();
  }

  function onPointerMove(e) {
    if (!pointer || e.pointerId !== pointer.id) return;
    const dx = e.clientX - pointer.x0;
    const dy = e.clientY - pointer.y0;
    if (!pointer.dragging) {
      if (Math.hypot(dx, dy) < SWIPE.startPx) return;
      // A finger moving mostly up or down scrolls the page (touch-action: pan-y does that).
      if (pointer.type !== 'mouse' && Math.abs(dy) > Math.abs(dx)) {
        pointer.dragging = false;
        pointer.vertical = true;
        return;
      }
      if (pointer.vertical || !canStart()) return;
      pointer.dragging = true;
      tracker.begin(e.timeStamp);
    }
    e.preventDefault();
    tracker.moveTo(dx, e.timeStamp);
    emitMove();
  }

  function onPointerUp(e) {
    if (!pointer || e.pointerId !== pointer.id) return;
    const p = pointer;
    pointer = null;
    suppressClickUntil = performance.now() + 400;
    if (p.dragging) finish(e.timeStamp);
    else if (!p.vertical && Math.hypot(e.clientX - p.x0, e.clientY - p.y0) < SWIPE.startPx) onTap();
  }

  function onPointerCancel(e) {
    if (!pointer || e.pointerId !== pointer.id) return;
    const dragging = pointer.dragging;
    pointer = null;
    if (dragging) {
      const offset = tracker.offset;
      flushMove();
      tracker.reset();
      onCancel(offset);
    }
  }

  // A click that no pointer press handled (assistive technology, a synthetic click).
  function onClick(e) {
    if (performance.now() < suppressClickUntil) return;
    const t = e.target;
    const card = t && t.closest ? t.closest('.fc-card.is-current') : null;
    if (!card || !surface.contains(card) || t.closest(TOOLS)) return;
    onTap();
  }

  // --------------------------------------------------------------- wheel
  function endWheel() {
    clearTimeout(wheel.timer);
    const was = wheel.axis;
    wheel.axis = 'none';
    if (was === 'horizontal' && tracker.isTracking) finish(wheel.last);
  }

  function onWheel(e) {
    if (e.ctrlKey || pointer) return; // pinch zoom; a drag already holds the card
    const time = e.timeStamp;
    clearTimeout(wheel.timer);
    if (wheel.axis !== 'none' && time - wheel.last > SWIPE.wheelGapMs) endWheel();
    wheel.last = time;
    wheel.timer = setTimeout(endWheel, SWIPE.wheelGapMs);
    // Lines or pages: a notched mouse wheel, not two fingers.
    if (e.deltaMode !== 0) {
      if (wheel.axis === 'none') wheel.axis = 'vertical';
      return;
    }
    const dx = e.deltaX;
    const dy = e.deltaY;
    if (wheel.axis === 'none') {
      wheel.axis = 'undecided';
      wheel.px = 0;
      wheel.py = 0;
    }
    if (wheel.axis === 'vertical') return;
    if (wheel.axis === 'horizontal') {
      e.preventDefault();
      // deltaX > 0 scrolls right, i.e. the fingers moved left: the card goes with the fingers.
      tracker.moveBy(-dx, time);
      emitMove();
      return;
    }
    wheel.px += dx;
    wheel.py += dy;
    if (Math.abs(wheel.px) + Math.abs(wheel.py) < SWIPE.startPx) {
      // Keep the browser from starting a sideways history swipe meanwhile.
      if (Math.abs(dx) > Math.abs(dy)) e.preventDefault();
      return;
    }
    if (Math.abs(wheel.px) > Math.abs(wheel.py) * SWIPE.axisBias && canStart()) {
      wheel.axis = 'horizontal';
      e.preventDefault();
      tracker.begin(time);
      tracker.moveBy(-wheel.px, time);
      emitMove();
    } else {
      wheel.axis = 'vertical';
    }
  }

  surface.addEventListener('pointerdown', onPointerDown);
  surface.addEventListener('pointermove', onPointerMove);
  surface.addEventListener('pointerup', onPointerUp);
  surface.addEventListener('pointercancel', onPointerCancel);
  surface.addEventListener('lostpointercapture', onPointerCancel);
  surface.addEventListener('click', onClick);
  wheelTarget.addEventListener('wheel', onWheel, { passive: false });

  return {
    cancel,
    get isTracking() {
      return tracker.isTracking;
    },
    get offset() {
      return tracker.isTracking ? tracker.offset : 0;
    },
    dispose() {
      cancel();
      surface.removeEventListener('pointerdown', onPointerDown);
      surface.removeEventListener('pointermove', onPointerMove);
      surface.removeEventListener('pointerup', onPointerUp);
      surface.removeEventListener('pointercancel', onPointerCancel);
      surface.removeEventListener('lostpointercapture', onPointerCancel);
      surface.removeEventListener('click', onClick);
      wheelTarget.removeEventListener('wheel', onWheel);
    },
  };
}
