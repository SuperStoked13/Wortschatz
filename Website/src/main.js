// Boot: theme, header (with the daily Lernserie), router and the app-wide guards (stray file
// drops, links in new windows, Ctrl+N, voices that are missing). Modules are imported
// dynamically inside a try/catch so a broken module shows a friendly message instead of a
// blank page.

function showBootError(err) {
  if (typeof console !== 'undefined') console.error('Wortschatz konnte nicht starten', err);
  const app = document.getElementById('app') || document.body;
  const box = document.createElement('section');
  box.className = 'app-error';
  box.setAttribute('role', 'alert');

  const title = document.createElement('h1');
  title.className = 'app-error__title';
  title.textContent = 'Wortschatz konnte nicht starten';

  // Checked inline: the error may come from a module (host.js too) that failed to load.
  const desktop = typeof window !== 'undefined' && !!window.wortschatzHost && window.wortschatzHost.platform === 'windows';
  const text = document.createElement('p');
  text.className = 'app-error__text';
  text.textContent = desktop
    ? 'Beim Laden ist ein Fehler aufgetreten. Deine Lernsets sind auf diesem Computer gespeichert und gehen dadurch nicht verloren. Lade Wortschatz neu – hilft das nicht, schliesse Wortschatz und öffne es erneut.'
    : 'Beim Laden ist ein Fehler aufgetreten. Deine Lernsets sind in diesem Browser gespeichert und gehen dadurch nicht verloren. Lade die Seite neu – hilft das nicht, starte Wortschatz über «Start.command» neu.';

  const actions = document.createElement('div');
  actions.className = 'app-error__actions';
  const reload = document.createElement('button');
  reload.type = 'button';
  reload.className = 'ui-btn ui-btn--primary ui-btn--md';
  reload.textContent = 'Neu laden';
  reload.addEventListener('click', () => location.reload());
  actions.append(reload);

  box.append(title, text);
  if (err && err.message) {
    const detail = document.createElement('pre');
    detail.className = 'app-error__detail';
    detail.textContent = err.message;
    box.append(detail);
  }
  box.append(actions);
  app.replaceChildren(box);
}

function renderHeader(header, { h, iconButton, streak }) {
  const settingsLink = iconButton({ icon: 'settings', label: 'Einstellungen', href: '#/settings' });
  header.replaceChildren(
    h(
      'div',
      { class: 'app-header__inner' },
      h(
        'a',
        { class: 'app-brand', href: '#/' },
        h('img', { class: 'app-brand__mark', src: 'assets/icon.svg', alt: '', width: '30', height: '30' }),
        h('span', { class: 'app-brand__name' }, 'Wortschatz'),
      ),
      h('div', { class: 'app-header__spacer' }),
      streak || null,
      h('nav', { class: 'app-header__nav', 'aria-label': 'Hauptnavigation' }, settingsLink),
    ),
  );

  window.addEventListener('wortschatz:route', (e) => {
    if (e.detail && e.detail.name === 'settings') settingsLink.setAttribute('aria-current', 'page');
    else settingsLink.removeAttribute('aria-current');
  });

  let ticking = false;
  const syncScrolled = () => {
    ticking = false;
    header.dataset.scrolled = String(window.scrollY > 2);
  };
  window.addEventListener(
    'scroll',
    () => {
      if (!ticking) {
        ticking = true;
        requestAnimationFrame(syncScrolled);
      }
    },
    { passive: true },
  );
  syncScrolled();
}

// Storage-full errors can surface from any screen: show them as a toast.
function watchStorageErrors(toast) {
  const handle = (err) => {
    if (err && err.code === 'QUOTA') {
      toast(err.message || 'Der Speicher für Wortschatz ist voll.', { tone: 'danger', duration: 7000 });
      return true;
    }
    return false;
  };
  window.addEventListener('error', (e) => {
    if (handle(e.error)) e.preventDefault();
  });
  window.addEventListener('unhandledrejection', (e) => {
    if (handle(e.reason)) e.preventDefault();
  });
}

function isEditable(target) {
  const el = target && target.nodeType === 1 ? target : target && target.parentElement;
  return !!(el && el.closest && el.closest('input, textarea, [contenteditable=""], [contenteditable="true"]'));
}

// A file (or a link) dropped where no screen takes it would make the browser, or the Windows
// app, open it in place of Wortschatz. Window listeners run after the screens' own (editor,
// backup panel), so `defaultPrevented` tells whether a screen already took the drop.
function guardDrops() {
  const guard = (e) => {
    if (e.defaultPrevented || !e.dataTransfer) return;
    const types = Array.from(e.dataTransfer.types || []);
    const files = types.includes('Files');
    const link = types.includes('text/uri-list') && !isEditable(e.target);
    if (!files && !link) return;
    e.preventDefault();
    if (e.type === 'dragover') e.dataTransfer.dropEffect = 'none';
  };
  window.addEventListener('dragover', guard);
  window.addEventListener('drop', guard);
}

// Ctrl+N (⌘N): a new set from anywhere, unless the user is typing or a dialog is open.
function bindNewSetKey({ commandKey, isTypingTarget, hasOpenModal, navigate, currentRoute }) {
  document.addEventListener('keydown', (e) => {
    if (e.defaultPrevented || e.isComposing || !commandKey(e, 'n')) return;
    if (isTypingTarget(e.target) || hasOpenModal()) return;
    e.preventDefault();
    if (e.repeat) return;
    const route = currentRoute();
    if (route && route.name === 'editor' && !(route.params && route.params.id)) return;
    navigate('/new');
  });
}

// A word in a language without an installed voice is not read (speech.js); say why, once per
// language while the app is open.
function explainMissingVoices({ setMissingVoiceHandler, toast, langName, desktop }) {
  const told = new Set();
  setMissingVoiceHandler((code) => {
    if (told.has(code)) return;
    told.add(code);
    const name = langName(code);
    const message = desktop
      ? `Für ${name} ist auf diesem Computer keine Stimme installiert. Du kannst in den Windows-Einstellungen unter «Zeit und Sprache» eine hinzufügen.`
      : `Für ${name} ist auf diesem Gerät keine Stimme installiert.`;
    toast(message, { tone: 'warning', icon: 'volume', duration: 7000 });
  });
}

async function boot() {
  try {
    const [{ h }, { iconButton, toast, hasOpenModal }, theme, router, host, streak, speech, { langName }, shortcuts] = await Promise.all([
      import('./lib/dom.js'),
      import('./ui/components.js'),
      import('./lib/theme.js'),
      import('./router.js'),
      import('./lib/host.js'),
      import('./ui/daily-streak.js'),
      import('./lib/speech.js'),
      import('./lib/labels.js'),
      import('./lib/shortcuts.js'),
    ]);
    theme.initTheme();
    host.limitContextMenu();
    host.blockNewWindows();
    guardDrops();
    const header = document.getElementById('app-header');
    const indicator = header ? streak.createStreakIndicator() : null;
    if (header) renderHeader(header, { h, iconButton, streak: indicator });
    streak.watchDailyStreak(indicator);
    watchStorageErrors(toast);
    explainMissingVoices({ setMissingVoiceHandler: speech.setMissingVoiceHandler, toast, langName, desktop: host.isDesktopApp() });
    speech.primeVoices();
    bindNewSetKey({
      commandKey: shortcuts.commandKey,
      isTypingTarget: shortcuts.isTypingTarget,
      hasOpenModal,
      navigate: router.navigate,
      currentRoute: router.currentRoute,
    });
    router.startRouter(document.getElementById('app'));
    document.documentElement.dataset.booted = 'true';
  } catch (err) {
    showBootError(err);
  }
}

// Only boot in a browser, so the module graph can be link-checked under jsc.
if (typeof document !== 'undefined') boot();
