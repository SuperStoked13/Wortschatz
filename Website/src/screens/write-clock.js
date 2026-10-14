// Active study time for a Write session. The session clock (session.tick) is advanced
// regularly while the page is visible and the learner is active; hidden or idle stretches
// are skipped by moving the session's reference time forward instead (resume).

const TICK_MS = 15000;
const IDLE_MS = 2 * 60 * 1000;

/**
 * isStudying() -> boolean   whether time should currently count
 * tick()                    advance the session clock to now and persist
 * resume()                  restart counting from now without adding the gap
 * onHidden()                optional, e.g. stop speech output
 */
export function createStudyClock({ isStudying, tick, resume, onHidden }) {
  let lastActivity = Date.now();
  let idle = false;

  function tickNow() {
    if (isStudying()) tick();
  }

  function markActive() {
    lastActivity = Date.now();
    if (idle) {
      idle = false;
      resume();
    }
  }

  function onVisibility() {
    if (document.visibilityState === 'hidden') {
      tickNow();
      if (typeof onHidden === 'function') onHidden();
    } else {
      lastActivity = Date.now();
      idle = false;
      resume();
    }
  }

  const timer = setInterval(() => {
    if (idle || document.visibilityState !== 'visible') return;
    tickNow();
    if (Date.now() - lastActivity > IDLE_MS) idle = true;
  }, TICK_MS);

  document.addEventListener('keydown', markActive, true);
  document.addEventListener('pointerdown', markActive, true);
  document.addEventListener('visibilitychange', onVisibility);

  return {
    tickNow,
    dispose() {
      clearInterval(timer);
      document.removeEventListener('keydown', markActive, true);
      document.removeEventListener('pointerdown', markActive, true);
      document.removeEventListener('visibilitychange', onVisibility);
    },
  };
}
