/*
  The app window on the home page: five short scenes (Lernen, Schreiben, Karteikarten,
  Prüfung, Import) played with the app's own words and states. A pausable clock drives
  them, so the window stops when it is off screen, when the tab is hidden or when the
  visitor pauses it. Under "Bewegung reduzieren" every scene shows one still frame.
*/
(() => {
  'use strict';

  const root = document.querySelector('[data-demo]');
  if (!root) return;

  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const win = root.querySelector('.window');
  const tabs = [...root.querySelectorAll('[role="tab"]')];
  const thumb = root.querySelector('.segmented-thumb');
  const segmented = root.querySelector('.segmented');
  const captions = [...root.querySelectorAll('[data-caption]')];
  const panel = root.querySelector('[role="tabpanel"]');
  const toggle = root.querySelector('[data-demo-toggle]');
  const toggleLabel = root.querySelector('[data-toggle-label]');
  const keycast = root.querySelector('[data-keycast]');
  const MODES = tabs.map((tab) => tab.dataset.mode);

  const EASE = {
    arrive: 'cubic-bezier(0.22, 1, 0.36, 1)',
    depart: 'cubic-bezier(0.32, 0, 0.67, 0)',
    soft: 'cubic-bezier(0.4, 0, 0.2, 1)',
    turn: 'cubic-bezier(0.45, 0.05, 0.25, 1)',
  };

  const abortError = () => new DOMException('Szene beendet', 'AbortError');

  // ------------------------------------------------------------------ clock

  class Clock {
    constructor() {
      this.now = 0;
      this.timers = new Set();
      this.running = false;
      this.last = 0;
      this.frame = 0;
      this.tick = this.tick.bind(this);
    }

    start() {
      if (this.running) return;
      this.running = true;
      this.last = performance.now();
      this.frame = requestAnimationFrame(this.tick);
    }

    stop() {
      this.running = false;
      cancelAnimationFrame(this.frame);
    }

    tick(time) {
      if (!this.running) return;
      this.now += Math.min(64, Math.max(0, time - this.last));
      this.last = time;
      for (const timer of [...this.timers]) {
        if (timer.at <= this.now) {
          this.timers.delete(timer);
          timer.done();
        }
      }
      this.frame = requestAnimationFrame(this.tick);
    }

    wait(ms, signal) {
      return new Promise((resolve, reject) => {
        if (signal.aborted) {
          reject(abortError());
          return;
        }
        const onAbort = () => {
          this.timers.delete(timer);
          reject(abortError());
        };
        const timer = {
          at: this.now + ms,
          done: () => {
            signal.removeEventListener('abort', onAbort);
            resolve();
          },
        };
        this.timers.add(timer);
        signal.addEventListener('abort', onAbort, { once: true });
      });
    }
  }

  const clock = new Clock();

  // A fixed sequence of "random" numbers, so typing feels human but always the same.
  let seed = 11;
  const random = () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };

  // ---------------------------------------------------------------- helpers

  const el = (scope, name) => scope.querySelector(`[data-el="${name}"]`);

  function animate(node, keyframes, options) {
    if (!node || still.matches || typeof node.animate !== 'function') return null;
    return node.animate(keyframes, options);
  }

  function cancelAnimations(...nodes) {
    for (const node of nodes) node?.getAnimations?.().forEach((animation) => animation.cancel());
  }

  function bump(node) {
    node.classList.remove('bump');
    void node.offsetWidth;
    node.classList.add('bump');
  }

  function setCount(node, value) {
    const text = String(value);
    if (node.textContent === text) return;
    node.textContent = text;
    if (!still.matches) bump(node);
  }

  function press(node, ms = 170) {
    if (!node) return;
    node.classList.add('is-pressed');
    window.setTimeout(() => node.classList.remove('is-pressed'), ms);
  }

  function showKey(label) {
    if (!keycast || still.matches) return;
    const key = document.createElement('span');
    key.className = 'keycast-key';
    key.textContent = label;
    keycast.append(key);
    while (keycast.children.length > 6) keycast.firstElementChild.remove();
    window.setTimeout(() => {
      key.classList.add('is-leaving');
      window.setTimeout(() => key.remove(), 400);
    }, 950);
  }

  /** Swaps a text the way a new question arrives: the old one leaves, the new one glides in. */
  async function swapText(node, text, ctx) {
    if (still.matches || !ctx) {
      node.textContent = text;
      return;
    }
    const out = animate(node, [{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'translateX(-10px)' }], {
      duration: 170,
      easing: EASE.depart,
      fill: 'forwards',
    });
    await ctx.wait(175);
    node.textContent = text;
    out?.cancel();
    animate(node, [{ opacity: 0, transform: 'translateX(16px)' }, { opacity: 1, transform: 'none' }], {
      duration: 480,
      easing: EASE.arrive,
    });
  }

  function makeContext(signal) {
    return {
      signal,
      wait: (ms) => clock.wait(ms, signal),
      key: showKey,
      /** Types `text` into `node` letter by letter; `box` gets has-text and is-typing. */
      async type(node, text, box, { min = 70, max = 135 } = {}) {
        box?.classList.add('is-typing');
        for (const char of text) {
          node.textContent += char;
          box?.classList.add('has-text');
          await clock.wait(min + random() * (max - min) + (char === ' ' ? 60 : 0), signal);
        }
        box?.classList.remove('is-typing');
      },
    };
  }

  // ----------------------------------------------------------------- Lernen

  function learnScene(scene) {
    const prompt = el(scene, 'prompt');
    const choices = el(scene, 'choices');
    const tiles = [...scene.querySelectorAll('[data-tile]')];
    const labels = tiles.map((tile) => tile.querySelector('.tile-text'));
    const pill = el(scene, 'pill');
    const praise = el(scene, 'praise');
    const streak = el(scene, 'streak');
    const answer = el(scene, 'answer');
    const answerText = el(scene, 'answer-text');
    const primary = el(scene, 'primary');
    const primaryLabel = el(scene, 'primary-label');
    const secondary = el(scene, 'secondary');
    const counts = {
      fresh: scene.querySelector('[data-count="new"]'),
      learning: scene.querySelector('[data-count="learning"]'),
      mastered: scene.querySelector('[data-count="mastered"]'),
    };
    const segments = {
      learning: scene.querySelector('[data-seg="learning"]'),
      mastered: scene.querySelector('[data-seg="mastered"]'),
    };
    const TOTAL = 8;
    const Q1 = ['der Garten', 'das Haus', 'die Strasse', 'das Fenster'];
    const Q2 = ['der Weg', 'das Haus', 'der Garten', 'die Strasse'];
    let words = Q1;

    function progress(fresh, learning, mastered) {
      setCount(counts.fresh, fresh);
      setCount(counts.learning, learning);
      setCount(counts.mastered, mastered);
      segments.learning.style.setProperty('--w', `${(learning / TOTAL) * 100}%`);
      segments.mastered.style.setProperty('--w', `${(mastered / TOTAL) * 100}%`);
    }

    function label(index, typed = 0) {
      const node = labels[index];
      const text = words[index];
      node.textContent = '';
      if (typed > 0) {
        const mark = document.createElement('u');
        mark.textContent = text.slice(0, typed);
        node.append(mark, text.slice(typed));
      } else {
        node.textContent = text;
      }
    }

    function setChoices(list) {
      words = list;
      tiles.forEach((tile, index) => {
        tile.className = 'tile glass';
        label(index);
      });
    }

    function typeAhead(typed) {
      let first = -1;
      tiles.forEach((tile, index) => {
        const match = words[index].toLowerCase().startsWith(typed.toLowerCase());
        tile.classList.toggle('is-filtered', !match);
        label(index, match ? typed.length : 0);
        if (match && first === -1) first = index;
      });
      tiles.forEach((tile, index) => tile.classList.toggle('is-highlighted', index === first));
    }

    function choose(index) {
      tiles.forEach((tile, i) => {
        tile.classList.remove('is-highlighted', 'is-filtered');
        tile.classList.add(i === index ? 'is-correct' : 'is-dimmed');
        label(i);
      });
    }

    function status(kind, title) {
      pill.dataset.kind = kind;
      pill.classList.remove('is-counting');
      secondary.classList.toggle('is-off', kind === 'correct' || kind === 'miss');
      if (title) praise.textContent = title;
    }

    function countdown(ms) {
      if (still.matches) return;
      pill.style.setProperty('--countdown', `${ms}ms`);
      pill.classList.remove('is-counting');
      void pill.offsetWidth;
      pill.classList.add('is-counting');
    }

    function setStreak(n) {
      streak.textContent = String(n);
      pill.classList.toggle('has-streak', n >= 3);
    }

    function setPrimary(text) {
      primary.classList.toggle('is-off', !text);
      if (text) primaryLabel.textContent = text;
    }

    async function nextChoices(ctx, text, list) {
      status('keys');
      setPrimary('');
      const out = animate(choices, [{ opacity: 1 }, { opacity: 0 }], { duration: 160, easing: EASE.depart, fill: 'forwards' });
      await swapText(prompt, text, ctx);
      setChoices(list);
      out?.cancel();
      animate(choices, [{ opacity: 0, transform: 'translateY(8px)' }, { opacity: 1, transform: 'none' }], {
        duration: 420,
        easing: EASE.arrive,
      });
    }

    return {
      el: scene,
      reset() {
        cancelAnimations(prompt, choices);
        scene.dataset.step = 'mc';
        prompt.textContent = 'la maison';
        setChoices(Q1);
        progress(8, 0, 0);
        status('keys');
        setStreak(0);
        setPrimary('');
        answer.className = 'answer-box';
        answerText.textContent = '';
      },
      still() {
        choose(1);
        status('correct', 'Super!');
        progress(7, 1, 0);
        setPrimary('Weiter');
      },
      async play(ctx) {
        // 1: type the first letters, the matching tile is marked, Return chooses it.
        await ctx.wait(1400);
        let typed = '';
        for (const char of 'das h') {
          typed += char;
          ctx.key(char === ' ' ? '␣' : char.toUpperCase());
          typeAhead(typed);
          await ctx.wait(char === ' ' ? 260 : 190 + random() * 70);
        }
        await ctx.wait(520);
        ctx.key('↩');
        choose(1);
        status('correct', 'Super!');
        setStreak(1);
        progress(7, 1, 0);
        setPrimary('Weiter');
        countdown(900);
        await ctx.wait(1300);

        // 2: a digit chooses directly.
        await nextChoices(ctx, 'le jardin', Q2);
        await ctx.wait(1500);
        ctx.key('3');
        choose(2);
        status('correct', 'Klasse!');
        setStreak(2);
        progress(6, 2, 0);
        setPrimary('Weiter');
        countdown(900);
        await ctx.wait(1300);

        // 3: the first word comes back, now written. Right twice: mastered.
        status('typing');
        setPrimary('Antworten');
        const out = animate(choices, [{ opacity: 1 }, { opacity: 0 }], { duration: 160, easing: EASE.depart, fill: 'forwards' });
        await swapText(prompt, 'la maison', ctx);
        out?.cancel();
        scene.dataset.step = 'written';
        await ctx.wait(700);
        answer.classList.add('is-active');
        await ctx.wait(500);
        await ctx.type(answerText, 'das Haus', answer);
        await ctx.wait(500);
        ctx.key('↩');
        press(primary);
        answer.classList.remove('is-active');
        answer.classList.add('is-correct');
        status('correct', 'Genau!');
        setStreak(3);
        progress(6, 1, 1);
        setPrimary('Weiter');
        countdown(900);
        await ctx.wait(2600);
      },
    };
  }

  // -------------------------------------------------------------- Schreiben

  function writeScene(scene) {
    const prompt = el(scene, 'prompt');
    const answer = el(scene, 'answer');
    const answerText = el(scene, 'answer-text');
    const exact = el(scene, 'exact');
    const note = el(scene, 'note');
    const pill = el(scene, 'pill');
    const primary = el(scene, 'primary');
    const primaryLabel = el(scene, 'primary-label');
    const accent = scene.querySelector('[data-char="ê"]');
    const counts = {
      left: scene.querySelector('[data-count="left"]'),
      wrong: scene.querySelector('[data-count="wrong"]'),
      right: scene.querySelector('[data-count="right"]'),
    };

    function counters(left, wrong, right) {
      setCount(counts.left, left);
      setCount(counts.wrong, wrong);
      setCount(counts.right, right);
    }

    function ask() {
      scene.dataset.state = 'asking';
      pill.dataset.kind = 'typing';
      primaryLabel.textContent = 'Antworten';
      answer.className = 'answer-box';
      answerText.textContent = '';
    }

    function accept(word, noteText) {
      answer.classList.remove('is-active');
      answer.classList.add('is-correct');
      scene.dataset.state = 'accepted';
      exact.textContent = word;
      note.textContent = noteText;
      pill.dataset.kind = 'correct';
      primaryLabel.textContent = 'Weiter';
    }

    async function next(ctx, text) {
      const card = scene.querySelector('.study-card');
      const out = animate(card, [{ opacity: 1 }, { opacity: 0.55 }], { duration: 160, easing: EASE.depart, fill: 'forwards' });
      await swapText(prompt, text, ctx);
      out?.cancel();
      ask();
      animate(card, [{ opacity: 0.55 }, { opacity: 1 }], { duration: 320, easing: EASE.soft });
    }

    return {
      el: scene,
      reset() {
        cancelAnimations(prompt);
        prompt.textContent = 'das Fenster';
        ask();
        counters(6, 0, 2);
      },
      still() {
        answerText.textContent = 'fenêtre';
        answer.classList.add('has-text');
        accept('la fenêtre', 'Artikel fehlte');
        counters(5, 0, 3);
      },
      async play(ctx) {
        // Without the article, with ê from the bar: accepted, with a note.
        await ctx.wait(1000);
        answer.classList.add('is-active');
        await ctx.wait(400);
        await ctx.type(answerText, 'fen', answer);
        await ctx.wait(380);
        accent.classList.add('is-pressed');
        answerText.textContent += 'ê';
        await ctx.wait(170);
        accent.classList.remove('is-pressed');
        await ctx.wait(260);
        await ctx.type(answerText, 'tre', answer);
        await ctx.wait(480);
        ctx.key('↩');
        press(primary);
        accept('la fenêtre', 'Artikel fehlte');
        counters(5, 0, 3);
        await ctx.wait(2500);

        // Without the pronoun: accepted too.
        await next(ctx, 'heissen');
        await ctx.wait(700);
        answer.classList.add('is-active');
        await ctx.wait(300);
        await ctx.type(answerText, 'appeler', answer);
        await ctx.wait(480);
        ctx.key('↩');
        press(primary);
        accept('s’appeler', 'Pronomen fehlte');
        counters(4, 0, 4);
        await ctx.wait(2500);

        // A missing accent is a mistake: the difference is marked.
        await next(ctx, 'früh');
        await ctx.wait(700);
        answer.classList.add('is-active');
        await ctx.wait(300);
        await ctx.type(answerText, 'tot', answer);
        await ctx.wait(520);
        ctx.key('↩');
        press(primary);
        answer.classList.remove('is-active');
        scene.dataset.state = 'missed';
        pill.dataset.kind = 'miss';
        primaryLabel.textContent = 'Weiter';
        counters(3, 1, 4);
        await ctx.wait(3200);
      },
    };
  }

  // ----------------------------------------------------------- Karteikarten

  function cardsScene(scene) {
    const card = el(scene, 'card');
    const turn = el(scene, 'turn');
    const front = el(scene, 'front');
    const back = el(scene, 'back');
    const sheen = el(scene, 'sheen');
    const know = el(scene, 'know');
    const learning = el(scene, 'learning');
    const knowButton = el(scene, 'know-btn');
    const learningButton = el(scene, 'learning-btn');
    const position = el(scene, 'position');
    const progress = el(scene, 'progress');
    let flipped = false;

    function setPosition(n) {
      setCount(position, n);
      progress.style.setProperty('--w', `${(n / 8) * 100}%`);
    }

    function clearCard() {
      cancelAnimations(card, turn, sheen);
      delete card.dataset.verdict;
      flipped = false;
      turn.style.transform = '';
    }

    async function flip(ctx) {
      ctx.key('␣');
      const from = flipped ? 180 : 0;
      flipped = !flipped;
      if (still.matches) {
        turn.style.transform = `rotateX(${from + 180}deg)`;
        return;
      }
      animate(
        turn,
        [
          { transform: `translateY(0) scale(1) rotateZ(0deg) rotateX(${from}deg)` },
          { transform: `translateY(-10px) scale(1.045) rotateZ(-2.5deg) rotateX(${from + 90}deg)`, offset: 0.5 },
          { transform: `translateY(0) scale(1) rotateZ(0deg) rotateX(${from + 180}deg)` },
        ],
        { duration: 640, easing: EASE.turn, fill: 'forwards' },
      );
      animate(
        sheen,
        [
          { opacity: 0, backgroundPosition: '0 0%' },
          { opacity: 1, offset: 0.4 },
          { opacity: 0, backgroundPosition: '0 100%' },
        ],
        { duration: 640, easing: EASE.soft },
      );
      await ctx.wait(660);
    }

    async function sort(ctx, kind, nextFront, nextBack) {
      const isKnow = kind === 'know';
      ctx.key(isKnow ? '→' : '←');
      press(isKnow ? knowButton : learningButton);
      card.dataset.verdict = isKnow ? 'know' : 'learning';
      if (isKnow) setCount(know, Number(know.textContent) + 1);
      else setCount(learning, Number(learning.textContent) + 1);
      await ctx.wait(360);
      if (still.matches) {
        clearCard();
        front.textContent = nextFront;
        back.textContent = nextBack;
        setPosition(Number(position.textContent) + 1);
        return;
      }
      // The sorted card leaves as a copy while the next one rises from the stack.
      const ghost = card.cloneNode(true);
      ghost.removeAttribute('data-el');
      ghost.querySelectorAll('[data-el]').forEach((node) => node.removeAttribute('data-el'));
      ghost.classList.add('is-ghost');
      ghost.querySelector('.flashcard-turn').style.transform = flipped ? 'rotateX(180deg)' : '';
      card.after(ghost);
      clearCard();
      front.textContent = nextFront;
      back.textContent = nextBack;
      setPosition(Number(position.textContent) + 1);
      const dir = isKnow ? 1 : -1;
      animate(
        ghost,
        [
          { transform: 'none', opacity: 1 },
          { transform: `translate(${dir * 92}px, 8px) rotate(${dir * 2}deg) scale(0.98)`, opacity: 1, offset: 0.33 },
          { transform: `translate(${dir * 280}px, 24px) rotate(${dir * 6}deg) scale(0.94)`, opacity: 0 },
        ],
        { duration: 500, easing: 'cubic-bezier(0.45, 0, 0.75, 0.55)', fill: 'forwards' },
      );
      animate(card, [{ transform: 'translateY(16px) scale(0.965)', opacity: 0 }, { transform: 'none', opacity: 1 }], {
        duration: 460,
        delay: 140,
        easing: EASE.arrive,
        fill: 'backwards',
      });
      await ctx.wait(620);
      ghost.remove();
    }

    return {
      el: scene,
      reset() {
        scene.querySelectorAll('.flashcard.is-ghost').forEach((ghost) => ghost.remove());
        clearCard();
        front.textContent = 'le chemin';
        back.textContent = 'der Weg';
        know.textContent = '2';
        learning.textContent = '1';
        setPosition(3);
      },
      still() {
        turn.style.transform = 'rotateX(180deg)';
        flipped = true;
      },
      async play(ctx) {
        await ctx.wait(1400);
        await flip(ctx);
        await ctx.wait(1500);
        await sort(ctx, 'know', 'la rue', 'die Strasse');
        await ctx.wait(1200);
        await flip(ctx);
        await ctx.wait(1500);
        await sort(ctx, 'learning', 'tôt', 'früh');
        await ctx.wait(1800);
      },
    };
  }

  // ---------------------------------------------------------------- Prüfung

  function examScene(scene) {
    const timer = el(scene, 'timer');
    const answered = el(scene, 'answered');
    const handIn = el(scene, 'handin');
    const done = el(scene, 'done');
    const ring = el(scene, 'ring');
    const value = el(scene, 'grade-value');
    const rows = { 7: scene.querySelector('[data-row="7"]'), 8: scene.querySelector('[data-row="8"]') };
    const fields = { 7: el(scene, 'field-7'), 8: el(scene, 'field-8') };
    let seconds = 372;

    const clockText = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;

    function activate(n) {
      Object.entries(rows).forEach(([key, row]) => row.classList.toggle('is-active', Number(key) === n));
    }

    function showResult() {
      scene.dataset.state = 'result';
      ring.style.setProperty('--offset', '100');
      value.textContent = '1.0';
    }

    async function countUp(ctx) {
      void ring.getBoundingClientRect();
      ring.style.setProperty('--offset', '6');
      for (let step = 1; step <= 14; step += 1) {
        const grade = 1 + (4.7 * (1 - (1 - step / 14) ** 3));
        value.textContent = grade.toFixed(1);
        await ctx.wait(70);
      }
      value.textContent = '5.7';
    }

    async function tick(ctx) {
      try {
        for (;;) {
          await ctx.wait(1000);
          seconds -= 1;
          timer.textContent = clockText(seconds);
        }
      } catch {
        // the scene ended
      }
    }

    return {
      el: scene,
      reset() {
        scene.dataset.state = 'sheet';
        seconds = 372;
        timer.textContent = clockText(seconds);
        answered.textContent = '6';
        Object.values(rows).forEach((row) => row.classList.remove('is-done', 'is-active', 'is-typing'));
        Object.values(fields).forEach((field) => {
          field.textContent = '';
        });
        ring.style.setProperty('--offset', '100');
        value.textContent = '5.7';
      },
      still() {
        scene.dataset.state = 'result';
        ring.style.setProperty('--offset', '6');
      },
      async play(ctx) {
        tick(ctx);
        await ctx.wait(900);
        activate(7);
        await ctx.wait(500);
        await ctx.type(fields[7], 'das Fenster', rows[7]);
        await ctx.wait(420);
        ctx.key('↩');
        rows[7].classList.add('is-done');
        setCount(answered, 7);
        activate(8);
        await ctx.wait(600);
        await ctx.type(fields[8], 'der weg', rows[8]);
        await ctx.wait(520);
        ctx.key('↩');
        rows[8].classList.add('is-done');
        rows[8].classList.remove('is-active');
        setCount(answered, 8);
        await ctx.wait(800);
        ctx.key('⌘↩');
        press(handIn);
        await ctx.wait(320);
        showResult();
        await ctx.wait(350);
        await countUp(ctx);
        await ctx.wait(2400);
        ctx.key('↩');
        press(done);
        await ctx.wait(500);
      },
    };
  }

  // ----------------------------------------------------------------- Import

  function importScene(scene) {
    const paste = el(scene, 'paste');
    const lines = [...el(scene, 'lines').children];
    const rows = [...scene.querySelectorAll('.preview-row')];
    const take = el(scene, 'take');
    lines.forEach((line, index) => line.style.setProperty('--n', String(index)));

    return {
      el: scene,
      reset() {
        scene.dataset.state = 'empty';
        paste.classList.remove('is-flash');
        rows.forEach((row) => row.classList.remove('is-shown'));
      },
      still() {
        scene.dataset.state = 'pasted detected';
        rows.forEach((row) => row.classList.add('is-shown'));
      },
      async play(ctx) {
        await ctx.wait(1300);
        ctx.key('⌘V');
        scene.dataset.state = 'pasted';
        paste.classList.add('is-flash');
        await ctx.wait(700);
        paste.classList.remove('is-flash');
        await ctx.wait(500);
        scene.dataset.state = 'pasted detected';
        await ctx.wait(450);
        for (const row of rows) {
          row.classList.add('is-shown');
          await ctx.wait(150);
        }
        await ctx.wait(1300);
        press(take, 220);
        await ctx.wait(1800);
      },
    };
  }

  // ----------------------------------------------------------------- driver

  const factories = { learn: learnScene, write: writeScene, cards: cardsScene, exam: examScene, import: importScene };
  const scenes = {};
  for (const node of win.querySelectorAll('[data-scene]')) {
    const make = factories[node.dataset.scene];
    if (make) scenes[node.dataset.scene] = make(node);
  }

  let current = MODES[0];
  let run = null;
  let visible = false;
  let paused = false;
  let thumbPlaced = false;

  function placeThumb(animated) {
    const tab = tabs.find((candidate) => candidate.dataset.mode === current);
    if (!tab || !thumb) return;
    const x = tab.offsetLeft;
    const w = tab.offsetWidth;
    const fromX = Number(thumb.dataset.x);
    const fromW = Number(thumb.dataset.w);
    thumb.style.setProperty('--thumb-x', `${x}px`);
    thumb.style.setProperty('--thumb-w', `${w}px`);
    thumb.dataset.x = String(x);
    thumb.dataset.w = String(w);
    if (!animated || !thumbPlaced || still.matches || fromX === x) {
      thumbPlaced = true;
      return;
    }
    // The glass drop stretches a little on its way and lands without overshooting.
    const middle = (fromX + x) / 2;
    thumb.animate(
      [
        { transform: `translateX(${fromX}px)`, width: `${fromW}px` },
        { transform: `translateX(${middle - 8}px) scaleY(0.9)`, width: `${(fromW + w) / 2 + 16}px`, offset: 0.45 },
        { transform: `translateX(${x}px)`, width: `${w}px` },
      ],
      { duration: 520, easing: EASE.arrive },
    );
  }

  function updateClock() {
    if (visible && !paused && !document.hidden && !still.matches) clock.start();
    else clock.stop();
  }

  async function play(mode) {
    run?.abort();
    const controller = new AbortController();
    run = controller;
    const scene = scenes[mode];
    if (!scene) return;
    scene.reset();
    if (still.matches) {
      scene.still();
      return;
    }
    const ctx = makeContext(controller.signal);
    try {
      await scene.play(ctx);
      await ctx.wait(300);
      if (!controller.signal.aborted) select(MODES[(MODES.indexOf(mode) + 1) % MODES.length]);
    } catch (error) {
      if (error?.name !== 'AbortError') console.error(error);
    }
  }

  function select(mode, { focus = false } = {}) {
    if (!scenes[mode]) return;
    const moved = mode !== current;
    current = mode;
    for (const tab of tabs) {
      const selected = tab.dataset.mode === mode;
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focus) tab.focus();
    }
    panel?.setAttribute('aria-labelledby', `tab-${mode}`);
    for (const caption of captions) {
      caption.hidden = false;
      caption.classList.toggle('is-active', caption.dataset.caption === mode);
    }
    for (const [name, scene] of Object.entries(scenes)) scene.el.classList.toggle('is-active', name === mode);
    placeThumb(moved);
    play(mode);
  }

  segmented?.addEventListener('click', (event) => {
    const tab = event.target.closest('[role="tab"]');
    if (tab) select(tab.dataset.mode);
  });

  segmented?.addEventListener('keydown', (event) => {
    const index = MODES.indexOf(current);
    const moves = {
      ArrowRight: index + 1,
      ArrowLeft: index - 1,
      Home: 0,
      End: MODES.length - 1,
    };
    if (!(event.key in moves)) return;
    event.preventDefault();
    const next = (moves[event.key] + MODES.length) % MODES.length;
    select(MODES[next], { focus: true });
  });

  toggle?.addEventListener('click', () => {
    paused = !paused;
    toggle.setAttribute('aria-pressed', String(paused));
    if (toggleLabel) toggleLabel.textContent = paused ? 'Animation fortsetzen' : 'Animation anhalten';
    updateClock();
  });

  if ('IntersectionObserver' in window) {
    new IntersectionObserver(
      ([entry]) => {
        visible = entry.isIntersecting;
        updateClock();
      },
      { threshold: 0.2 },
    ).observe(win);
  } else {
    visible = true;
  }

  if ('ResizeObserver' in window && segmented) {
    new ResizeObserver(() => placeThumb(false)).observe(segmented);
  }
  document.fonts?.ready?.then(() => placeThumb(false));
  document.addEventListener('visibilitychange', updateClock);
  still.addEventListener('change', () => {
    updateClock();
    select(current);
  });

  if (toggle && still.matches) toggle.hidden = true;
  select(current);
  updateClock();
})();
