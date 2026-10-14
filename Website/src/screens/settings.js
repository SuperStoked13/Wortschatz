// Settings (#/settings): theme, sound effects, the voice per language, default study
// options, backup export/import, "delete everything" and an about block. Every change is
// saved immediately. Inside the Windows app the copy says "auf diesem Computer".

import { h } from '../lib/dom.js';
import { icon } from '../ui/icons.js';
import { button, iconButton, segmented, toggle, openModal, confirmDialog, toast, callout } from '../ui/components.js';
import { studyOptionsForm } from '../ui/study-options.js';
import { LANGS, LANG_ORDER, plural, langName } from '../lib/labels.js';
import { dateKey, formatDate } from '../lib/time.js';
import { applyTheme, resolveTheme } from '../lib/theme.js';
import { isDesktopApp } from '../lib/host.js';
import { PREF, onPrefChange } from '../lib/prefs.js';
import { playSound, soundEffectsEnabled, setSoundEffectsEnabled } from '../lib/sounds.js';
import {
  canSpeak,
  speak,
  stopSpeaking,
  voicesLoaded,
  onVoicesChanged,
  voiceOptions,
  automaticVoiceLabel,
  preferredVoiceId,
  setPreferredVoice,
  voiceSample,
} from '../lib/speech.js';
import { db, createDb, memoryStorage, DEFAULT_STUDY_OPTIONS } from '../store/db.js';
import { downloadJson, readJsonFile } from '../store/backup.js';
import { navigate } from '../router.js';
import { isApplePlatform } from './editor-util.js';

const APP_VERSION = '1.0';
const APP_PORT = '4173';
const APP_HOST = `localhost:${APP_PORT}`;

const THEME_OPTIONS = [
  { value: 'system', label: 'System', icon: 'monitor' },
  { value: 'light', label: 'Hell', icon: 'sun' },
  { value: 'dark', label: 'Dunkel', icon: 'moon' },
];

const SAVED_MS = 1800;

let instance = 0;

function errorMessage(err, fallback) {
  return (err && err.message) || fallback;
}

// The defaults apply to every set, so the direction labels name the
// translation language only when all sets share it (new sets start with
// Deutsch); the learned language is always called "Lernsprache".
function sharedDefLang(sets) {
  const langs = new Set(sets.map((s) => s.defLang));
  if (!langs.size) return 'de';
  return langs.size === 1 ? [...langs][0] : null;
}

// Compares the shared, Write and Learn options and the tolerance switches.
function sameStudyOptions(a, b) {
  const keys = ['answerWith', 'shuffle', 'copyAnswer', 'autoAdvance', 'audio'];
  if (keys.some((k) => a[k] !== b[k])) return false;
  const same = (x, y) => {
    const ox = x || {};
    const oy = y || {};
    return Object.keys(oy).every((k) => ox[k] === oy[k]);
  };
  return same(a.tolerance, b.tolerance) && same(a.learn, b.learn);
}

function formatBytes(bytes) {
  if (bytes < 1024) return 'unter 1 KB';
  if (bytes < 1024 * 1024) return `ca. ${Math.round(bytes / 1024)} KB`;
  return `ca. ${(bytes / (1024 * 1024)).toFixed(1).replace('.', ',')} MB`;
}

function themeHint(value) {
  if (value === 'light') return 'Immer helles Design.';
  if (value === 'dark') return 'Immer dunkles Design – angenehm am Abend.';
  return `Folgt deinem Gerät – zurzeit ${resolveTheme('system') === 'dark' ? 'dunkel' : 'hell'}.`;
}

function backupFileName() {
  return `wortschatz-backup-${dateKey()}.json`;
}

// The languages of the library that can be read aloud, in picker order.
function libraryLangs(sets) {
  const used = new Set();
  for (const set of sets) {
    for (const code of [set.termLang, set.defLang]) if (code && code !== 'other' && LANGS[code]) used.add(code);
  }
  return LANG_ORDER.filter((code) => used.has(code));
}

// Where more voices come from on this device.
function voicesHint(desktop) {
  if (desktop) return 'Weitere Stimmen fügst du in den Windows-Einstellungen unter «Zeit und Sprache» hinzu.';
  if (isApplePlatform()) {
    return 'Weitere Stimmen lädst du in den Systemeinstellungen unter Bedienungshilfen › Gesprochene Inhalte › Systemstimme › Stimmen verwalten. Premium- und erweiterte Stimmen klingen am natürlichsten.';
  }
  return 'Welche Stimmen zur Wahl stehen, hängt von deinem Gerät und deinem Browser ab.';
}

/* ------------------------------------------------------------- render */

export function render(outlet) {
  const uid = ++instance;
  const cleanups = [];
  const timers = new Set();
  const later = (fn, ms) => {
    const id = setTimeout(() => {
      timers.delete(id);
      fn();
    }, ms);
    timers.add(id);
    return id;
  };
  cleanups.push(() => {
    for (const id of timers) clearTimeout(id);
    timers.clear();
  });

  let settings = db.getSettings();
  // Inside the Windows app the data lives on the computer, not in a browser.
  const desktop = isDesktopApp();

  /* Small building blocks */

  function savedIndicator() {
    const el = h('span', { class: 'st-saved', role: 'status' });
    let timer = null;
    el.flash = () => {
      if (timer) {
        clearTimeout(timer);
        timers.delete(timer);
      }
      el.replaceChildren(icon('check', { size: 14, strokeWidth: 2.25 }), 'Gespeichert');
      el.classList.remove('is-visible');
      void el.offsetWidth;
      el.classList.add('is-visible');
      timer = later(() => el.classList.remove('is-visible'), SAVED_MS);
    };
    return el;
  }

  function section({ id, title, text, aside, body, tone }) {
    const titleId = `st-${uid}-${id}`;
    return h(
      'section',
      { class: ['st-section', tone && `st-section--${tone}`], 'aria-labelledby': titleId },
      h(
        'div',
        { class: 'st-section__aside' },
        h('div', { class: 'st-section__heading' }, h('h2', { class: 'st-section__title', id: titleId }, title), aside || null),
        text ? h('p', { class: 'st-section__text' }, text) : null,
      ),
      h('div', { class: 'st-section__body' }, body),
    );
  }

  function row({ iconName, title, text, control, tone, wide = false }) {
    return h(
      'div',
      { class: ['st-row', tone && `st-row--${tone}`, wide && 'st-row--wide'] },
      h('span', { class: 'st-row__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 20 })),
      h('div', { class: 'st-row__text' }, h('p', { class: 'st-row__title' }, title), text ? h('p', { class: 'st-row__desc' }, text) : null),
      control ? h('div', { class: 'st-row__control' }, control) : null,
    );
  }

  function save(write, indicator) {
    try {
      write();
      if (indicator) indicator.flash();
      return true;
    } catch (err) {
      toast(errorMessage(err, 'Die Einstellung konnte nicht gespeichert werden.'), { tone: 'danger' });
      return false;
    }
  }

  /* Header */

  const head = h(
    'header',
    { class: 'st-head' },
    h('a', { class: 'ui-back', href: '#/' }, icon('arrowLeft', { size: 16 }), 'Lernsets'),
    h('h1', { class: 'ui-h1' }, 'Einstellungen'),
    h(
      'p',
      { class: 'ui-lead st-head__lead' },
      desktop ? 'Alles wird sofort gespeichert – auf diesem Computer.' : 'Alles wird sofort gespeichert – in diesem Browser auf diesem Gerät.',
    ),
  );

  /* Appearance */

  const appearanceSaved = savedIndicator();
  const themeDesc = h('p', { class: 'st-row__desc' });
  const themeSeg = segmented({
    options: THEME_OPTIONS,
    value: settings.theme,
    ariaLabel: 'Farbschema',
    onChange: (value) => {
      applyTheme(value);
      showTheme(value);
      save(() => db.updateSettings({ theme: value }), appearanceSaved);
    },
  });
  themeSeg.classList.add('st-theme');
  const themeRow = row({ iconName: 'monitor', title: 'Farbschema', control: themeSeg, wide: true });
  themeRow.querySelector('.st-row__text').append(themeDesc);
  const themeIcon = themeRow.querySelector('.st-row__icon');

  function showTheme(value) {
    themeDesc.textContent = themeHint(value);
    const option = THEME_OPTIONS.find((o) => o.value === value) || THEME_OPTIONS[0];
    themeIcon.replaceChildren(icon(option.icon, { size: 20 }));
  }
  showTheme(settings.theme);

  const appearance = section({
    id: 'appearance',
    title: 'Darstellung',
    text: 'Hell, dunkel oder passend zu deinem Gerät.',
    aside: appearanceSaved,
    body: h('div', { class: 'st-panel' }, themeRow),
  });

  if (typeof matchMedia === 'function') {
    const mql = matchMedia('(prefers-color-scheme: dark)');
    const onScheme = () => {
      if (themeSeg.value === 'system') themeDesc.textContent = themeHint('system');
    };
    if (typeof mql.addEventListener === 'function') {
      mql.addEventListener('change', onScheme);
      cleanups.push(() => mql.removeEventListener('change', onScheme));
    }
  }

  /* Sounds (an app preference: not in backups, like the Mac app's) */

  const soundSaved = savedIndicator();
  const soundToggle = toggle({
    ariaLabel: 'Soundeffekte',
    checked: soundEffectsEnabled(),
    onChange: (on) => {
      setSoundEffectsEnabled(on);
      soundSaved.flash();
      // Switching them on plays the «richtig» chime as a sample.
      if (on) playSound('correct', { force: true });
    },
  });
  const soundRow = row({
    iconName: 'volume',
    title: 'Soundeffekte',
    text: 'Leise Töne für richtige und falsche Antworten, Serien und geschaffte Runden.',
    control: soundToggle,
  });
  soundRow.classList.add('st-row--switch');
  const sounds = section({ id: 'sounds', title: 'Töne', aside: soundSaved, body: h('div', { class: 'st-panel' }, soundRow) });
  cleanups.push(
    onPrefChange((name, value) => {
      if (name === PREF.soundEffects) soundToggle.setChecked(value !== false);
    }),
  );

  /* Voices: one per language of the library, «Automatisch» picks the best installed one */

  const speechOk = canSpeak();
  const voiceSaved = savedIndicator();
  const voiceRows = h('div', { class: 'st-panel st-voices' });
  const voices = speechOk
    ? section({
        id: 'voices',
        title: 'Stimmen zum Vorlesen',
        text: `Für jede Sprache in deinen Lernsets. ${voicesHint(desktop)}`,
        aside: voiceSaved,
        body: voiceRows,
      })
    : null;
  let voiceSig = null;

  function voiceRow(lang) {
    const name = langName(lang);
    const options = voiceOptions(lang);
    const none = voicesLoaded() && !options.length;
    const auto = automaticVoiceLabel(lang);
    const chosen = preferredVoiceId(lang);
    // A chosen voice that is no longer installed reads as «Automatisch» (what speech.js uses).
    const value = chosen && options.some((o) => o.id === chosen) ? chosen : '';
    let first = 'Automatisch';
    if (none) first = 'Keine Stimme installiert';
    else if (auto) first = `Automatisch (${auto})`;
    const select = h(
      'select',
      { class: 'ui-select ui-select--sm st-voice__select', 'aria-label': `Stimme für ${name}`, 'data-voice': lang, disabled: none, value },
      h('option', { value: '' }, first),
      options.map((o) => h('option', { value: o.id }, o.label)),
    );
    select.addEventListener('change', () => {
      setPreferredVoice(lang, select.value || null);
      voiceSaved.flash();
    });
    // Icon only, like the Mac app: the picker keeps its room in narrow windows.
    const sample = iconButton({
      icon: 'volume',
      label: 'Probe hören',
      variant: 'secondary',
      size: 'sm',
      disabled: none,
      attrs: { 'aria-label': `Probe hören auf ${name}`, 'data-voice-sample': lang },
      onClick: () => speak(voiceSample(lang), lang),
    });
    const pick = h('div', { class: 'ui-select-wrap st-voice__pick' }, select, icon('chevronDown', { size: 16, className: 'ui-select-wrap__chevron' }));
    return row({ iconName: 'globe', title: name, control: h('div', { class: 'st-voice' }, pick, sample) });
  }

  // Rebuilds the rows when the library's languages or the installed voices change, and keeps
  // the keyboard on the same control.
  function renderVoices() {
    if (!voices) return;
    const langs = libraryLangs(db.listSets());
    voices.hidden = !langs.length;
    const sig = JSON.stringify([langs, voicesLoaded(), langs.map((l) => voiceOptions(l).map((o) => o.id))]);
    if (sig === voiceSig) return;
    voiceSig = sig;
    const active = document.activeElement;
    let focusSelector = null;
    if (active && voiceRows.contains(active)) {
      for (const attr of ['data-voice', 'data-voice-sample']) {
        if (active.hasAttribute(attr)) focusSelector = `[${attr}="${active.getAttribute(attr)}"]`;
      }
    }
    voiceRows.replaceChildren(...langs.map(voiceRow));
    const again = focusSelector ? voiceRows.querySelector(focusSelector) : null;
    if (again && !again.disabled) again.focus({ preventScroll: true });
  }
  if (voices) {
    cleanups.push(onVoicesChanged(renderVoices));
    cleanups.push(stopSpeaking);
  }

  /* Default study options */

  const studySaved = savedIndicator();
  const studyForm = studyOptionsForm({
    mode: 'all',
    options: settings.study,
    termLang: null,
    defLang: sharedDefLang(db.listSets()),
    onChange: (patch) => {
      save(() => db.updateSettings({ study: patch }), studySaved);
      syncResetButton();
    },
  });
  const resetStudyBtn = button({
    label: 'Auf Standard zurücksetzen',
    icon: 'rotate',
    variant: 'ghost',
    size: 'sm',
    onClick: () => {
      if (save(() => db.updateSettings({ study: DEFAULT_STUDY_OPTIONS }), studySaved)) {
        settings = db.getSettings();
        studyForm.update(settings.study);
        syncResetButton();
        toast('Standard-Lernoptionen wiederhergestellt', { tone: 'success' });
      }
    },
  });

  function syncResetButton() {
    const current = db.getSettings().study;
    resetStudyBtn.disabled = sameStudyOptions(current, DEFAULT_STUDY_OPTIONS);
  }

  const study = section({
    id: 'study',
    title: 'Standard-Lernoptionen',
    text: 'Gelten für Lernen und Schreiben in allen Lernsets. Was du in den Optionen eines Lernsets umstellst, gilt nur für dieses Lernset.',
    aside: studySaved,
    body: h('div', { class: 'st-study' }, studyForm, h('div', { class: 'st-study__foot' }, resetStudyBtn)),
  });

  /* Backup & data */

  const fileInput = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'st-file-input',
    tabindex: '-1',
    'aria-hidden': 'true',
    onChange: () => {
      const file = fileInput.files && fileInput.files[0];
      fileInput.value = '';
      if (file) handleBackupFile(file);
    },
  });

  const summary = h('p', { class: 'st-summary' });

  const exportBtn = button({ label: 'Exportieren', icon: 'download', variant: 'secondary', size: 'sm', onClick: exportBackup });
  const importBtn = button({ label: 'Datei wählen', icon: 'upload', variant: 'secondary', size: 'sm', onClick: () => fileInput.click() });

  const backupPanel = h(
    'div',
    { class: 'st-panel st-drop' },
    row({
      iconName: 'download',
      title: 'Backup exportieren',
      text: 'Alle Lernsets, dein Fortschritt und deine Einstellungen als Datei.',
      control: exportBtn,
    }),
    row({
      iconName: 'upload',
      title: 'Backup importieren',
      text: [
        'Lernsets aus einer Backup-Datei (.json) wiederherstellen.',
        h('span', { class: 'st-drop-hint' }, ' Du kannst die Datei auch hierher ziehen.'),
      ],
      control: importBtn,
    }),
    h('div', { class: 'st-panel__foot' }, icon('info', { size: 16 }), summary),
    fileInput,
    h('div', { class: 'st-drop__overlay', 'aria-hidden': 'true' }, icon('upload', { size: 22 }), 'Backup hier ablegen'),
  );
  setupDrop(backupPanel);

  const wipeBtn = button({ label: 'Alle Daten löschen', icon: 'trash', variant: 'danger-soft', size: 'sm', onClick: wipeEverything });
  const dangerPanel = h(
    'div',
    { class: 'st-panel st-panel--danger' },
    row({
      iconName: 'trash',
      tone: 'danger',
      title: 'Alle Daten löschen',
      text: `Entfernt alle Lernsets, den Lernfortschritt, die Statistik und die Einstellungen ${desktop ? 'von diesem Computer' : 'aus diesem Browser'}.`,
      control: wipeBtn,
    }),
  );

  const data = section({
    id: 'data',
    title: 'Backup & Daten',
    text: desktop
      ? 'Sichere deine Lernsets regelmässig – zum Beispiel bevor du den Computer wechselst oder Windows neu installierst.'
      : 'Sichere deine Lernsets regelmässig – zum Beispiel bevor du Browserdaten löschst oder das Gerät wechselst.',
    body: h('div', { class: 'st-stack' }, backupPanel, dangerPanel),
  });

  /* About */

  const about = section({
    id: 'about',
    title: 'Über Wortschatz',
    text: 'Dein persönlicher Vokabeltrainer: Lernen mit Multiple Choice und schriftlichen Antworten, Schreiben zum Festigen.',
    body: aboutBlock(),
  });

  const root = h('div', { class: ['ui-page', 'st'] }, head, appearance, sounds, voices, study, data, about);
  outlet.append(root);
  updateSummary();
  syncResetButton();
  renderVoices();

  /* ----------------------------------------------------------- about */

  function aboutBlock() {
    const host = typeof location !== 'undefined' ? location.host : '';
    // Storage is per origin: 127.0.0.1:4173 or [::1]:4173 do not see the sets of localhost:4173.
    // The Windows app always runs under its own fixed address.
    const onOtherAddress = !desktop && typeof location !== 'undefined' && /^https?:$/.test(location.protocol) && host !== APP_HOST;
    // The Windows app is started like any program: no Start.command, no address to keep.
    const items = desktop
      ? [
          [
            'monitor',
            'Deine Daten bleiben auf diesem Computer.',
            'Es gibt kein Konto und keine Cloud. Mit einem Backup nimmst du deine Lernsets auf einen anderen Computer mit.',
          ],
        ]
      : browserAboutItems();
    return h(
      'div',
      { class: 'st-panel st-about' },
      h(
        'div',
        { class: 'st-about__brand' },
        h('img', { class: 'st-about__logo', src: 'assets/icon.svg', alt: '', width: '52', height: '52' }),
        h(
          'div',
          { class: 'st-about__name' },
          h('p', { class: 'st-about__title' }, 'Wortschatz'),
          h('p', { class: 'st-about__version' }, `Version ${APP_VERSION}`),
        ),
      ),
      onOtherAddress
        ? callout({
            tone: 'warning',
            title: 'Andere Adresse erkannt',
            text: `Du verwendest gerade ${host}. Lernsets, die du unter ${APP_HOST} erstellt hast, sind hier nicht sichtbar.`,
          })
        : null,
      h(
        'ul',
        { class: 'st-about__list', role: 'list' },
        items.map(([iconName, title, text]) =>
          h(
            'li',
            { class: 'st-about__item' },
            h('span', { class: 'st-about__icon', 'aria-hidden': 'true' }, icon(iconName, { size: 18 })),
            h('div', null, h('p', { class: 'st-about__item-title' }, title), h('p', { class: 'st-about__item-text' }, text)),
          ),
        ),
      ),
    );
  }

  // The browser version (Start.command on the Mac).
  function browserAboutItems() {
    return [
      [
        'monitor',
        'Deine Daten bleiben in diesem Browser auf diesem Gerät.',
        'Es gibt kein Konto und keine Cloud. Mit einem Backup nimmst du deine Lernsets in einen anderen Browser oder auf ein anderes Gerät mit.',
      ],
      [
        'play',
        'Wortschatz starten',
        h(
          'span',
          null,
          'Doppelklicke im Wortschatz-Ordner auf ',
          h('code', { class: 'st-code' }, 'Start.command'),
          '. Das Terminal-Fenster, das sich dabei öffnet, bleibt offen, solange du lernst.',
        ),
      ],
      [
        'globe',
        'Immer dieselbe Adresse verwenden',
        h(
          'span',
          null,
          'Öffne Wortschatz immer unter ',
          h('code', { class: 'st-code' }, APP_HOST),
          '. Der Browser speichert die Daten pro Adresse – unter einer anderen Adresse oder einem anderen Port wären deine Lernsets nicht zu sehen.',
        ),
      ],
    ];
  }

  /* ---------------------------------------------------------- backup */

  function updateSummary() {
    const sets = db.listSets();
    const cards = sets.reduce((n, s) => n + s.cards.length, 0);
    let size = 0;
    try {
      size = JSON.stringify(db.exportAll()).length;
    } catch {
      size = 0;
    }
    summary.textContent = sets.length
      ? `Gespeichert: ${plural(sets.length, 'Lernset', 'Lernsets')} · ${plural(cards, 'Begriff', 'Begriffe')} · ${formatBytes(size)}`
      : 'Noch keine Lernsets gespeichert.';
  }

  function exportBackup() {
    try {
      const name = backupFileName();
      downloadJson(name, db.exportAll());
      // The Windows app saves without asking: say where the file went.
      toast(desktop ? `Backup im Ordner «Downloads» gespeichert: ${name}` : `Backup gespeichert: ${name}`, { tone: 'success' });
    } catch (err) {
      toast(errorMessage(err, 'Das Backup konnte nicht erstellt werden.'), { tone: 'danger' });
    }
  }

  async function handleBackupFile(file) {
    if (!/\.json$/i.test(file.name || '') && file.type && !/json/.test(file.type)) {
      toast('Bitte wähle eine Backup-Datei im JSON-Format.', { tone: 'danger' });
      return;
    }
    importBtn.setLoading(true);
    let payload;
    try {
      payload = await readJsonFile(file);
    } catch (err) {
      importBtn.setLoading(false);
      toast(errorMessage(err, 'Die Datei konnte nicht gelesen werden.'), { tone: 'danger' });
      return;
    }
    importBtn.setLoading(false);
    if (!root.isConnected) return;

    // Validate against a throwaway in-memory store; nothing real is touched yet.
    let preview;
    try {
      const scratch = createDb(() => memoryStorage());
      scratch.importAll(payload, { mode: 'replace' });
      preview = scratch.listSets();
    } catch (err) {
      toast(errorMessage(err, 'Diese Datei ist kein gültiges Wortschatz-Backup.'), { tone: 'danger', duration: 6000 });
      return;
    }
    openImportDialog(file, payload, preview);
  }

  function openImportDialog(file, payload, preview) {
    const existing = db.listSets();
    const existingIds = new Set(existing.map((s) => s.id));
    const cardCount = preview.reduce((n, s) => n + s.cards.length, 0);
    const updates = preview.filter((s) => existingIds.has(s.id)).length;
    const additions = preview.length - updates;
    const exportedAt = typeof payload.exportedAt === 'number' ? formatDate(payload.exportedAt) : '';
    let mode = existing.length ? 'merge' : 'replace';

    const meta = [plural(preview.length, 'Lernset', 'Lernsets'), plural(cardCount, 'Begriff', 'Begriffe'), exportedAt && `vom ${exportedAt}`]
      .filter(Boolean)
      .join(' · ');
    const fileInfo = h(
      'div',
      { class: 'st-file' },
      h('span', { class: 'st-file__icon', 'aria-hidden': 'true' }, icon('fileText', { size: 20 })),
      h('div', { class: 'st-file__body' }, h('p', { class: 'st-file__name' }, file.name || 'Backup'), h('p', { class: 'st-file__meta' }, meta)),
    );

    let content;
    if (!existing.length) {
      content = h(
        'div',
        { class: 'st-import' },
        fileInfo,
        h('p', { class: 'st-import__text' }, 'Das Backup wird vollständig wiederhergestellt – mit Lernfortschritt, Statistik und Einstellungen.'),
      );
    } else {
      const mergeParts = [];
      if (additions) mergeParts.push(plural(additions, 'neues Lernset', 'neue Lernsets'));
      if (updates) mergeParts.push(`${updates} ${updates === 1 ? 'wird' : 'werden'} durch die Backup-Version ersetzt`);
      const mergeDetail = mergeParts.length ? mergeParts.join(' · ') : 'Keine Änderungen';
      const previewIds = new Set(preview.map((s) => s.id));
      const lost = existing.filter((s) => !previewIds.has(s.id)).length;
      let replaceDetail = 'Alle deine Lernsets sind im Backup enthalten.';
      if (lost === 1) replaceDetail = '1 Lernset, das nicht im Backup ist, geht verloren.';
      else if (lost > 1) replaceDetail = `${lost} Lernsets, die nicht im Backup sind, gehen verloren.`;
      const groupName = `st-${uid}-import-mode`;
      const choice = (value, title, text, detail, tone) =>
        h(
          'label',
          { class: ['st-choice', tone && `st-choice--${tone}`] },
          h('input', {
            type: 'radio',
            name: groupName,
            value,
            class: 'st-choice__input',
            checked: mode === value,
            'data-autofocus': mode === value ? '' : null,
            onChange: () => {
              mode = value;
              syncConfirm();
            },
          }),
          h('span', { class: 'st-choice__radio', 'aria-hidden': 'true' }),
          h(
            'span',
            { class: 'st-choice__body' },
            h('span', { class: 'st-choice__title' }, title),
            h('span', { class: 'st-choice__text' }, text),
            h('span', { class: 'st-choice__detail' }, detail),
          ),
        );
      content = h(
        'div',
        { class: 'st-import' },
        fileInfo,
        h(
          'fieldset',
          { class: 'st-choices' },
          h('legend', { class: 'st-choices__legend' }, 'Wie möchtest du importieren?'),
          choice(
            'merge',
            'Zusammenführen',
            'Lernsets aus dem Backup kommen dazu. Deine übrigen Lernsets und Einstellungen bleiben erhalten.',
            mergeDetail,
          ),
          choice(
            'replace',
            'Alles ersetzen',
            'Alle aktuellen Lernsets, der Fortschritt und die Einstellungen werden durch das Backup ersetzt.',
            replaceDetail,
            'danger',
          ),
        ),
      );
    }

    const modal = openModal({
      title: 'Backup importieren',
      content,
      actions: [
        { label: 'Abbrechen', variant: 'secondary' },
        { label: 'Importieren', variant: 'primary', onClick: () => runImport(payload, mode) },
      ],
    });
    const confirmBtn = modal.el.querySelector('.ui-modal__footer .ui-btn:last-child');

    function syncConfirm() {
      if (!confirmBtn) return;
      const destructive = mode === 'replace' && existing.length > 0;
      confirmBtn.classList.toggle('ui-btn--primary', !destructive);
      confirmBtn.classList.toggle('ui-btn--danger', destructive);
      confirmBtn.setLabel(destructive ? 'Alles ersetzen' : 'Importieren');
    }
    syncConfirm();
  }

  function runImport(payload, mode) {
    let result;
    try {
      result = db.importAll(payload, { mode });
    } catch (err) {
      toast(errorMessage(err, 'Das Backup konnte nicht importiert werden.'), { tone: 'danger', duration: 6000 });
      return;
    }
    applyTheme(db.getSettings().theme || 'system');
    const total = result.setsAdded + result.setsUpdated;
    let message;
    if (mode === 'replace') {
      message = `Backup wiederhergestellt: ${plural(total, 'Lernset', 'Lernsets')}`;
    } else {
      const parts = [];
      if (result.setsAdded) parts.push(plural(result.setsAdded, 'neues Lernset', 'neue Lernsets'));
      if (result.setsUpdated) parts.push(`${result.setsUpdated} aktualisiert`);
      message = parts.length ? `Backup importiert: ${parts.join(', ')}` : 'Backup importiert – keine Änderungen';
    }
    toast(message, { tone: 'success', duration: 5000, action: { label: 'Ansehen', onClick: () => navigate('/') } });
  }

  function hasFiles(e) {
    return !!e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files');
  }

  function setupDrop(target) {
    let depth = 0;
    // A file released next to the drop panel would make the browser open it
    // and leave the app: everywhere else on the page, file drops are refused.
    const refuseDrop = (e) => {
      if (!hasFiles(e) || target.contains(e.target)) return;
      e.preventDefault();
      if (e.type === 'dragover') e.dataTransfer.dropEffect = 'none';
    };
    document.addEventListener('dragover', refuseDrop);
    document.addEventListener('drop', refuseDrop);
    cleanups.push(() => {
      document.removeEventListener('dragover', refuseDrop);
      document.removeEventListener('drop', refuseDrop);
    });
    target.addEventListener('dragenter', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth++;
      target.classList.add('is-dragging');
    });
    target.addEventListener('dragover', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    });
    target.addEventListener('dragleave', () => {
      depth = Math.max(0, depth - 1);
      if (!depth) target.classList.remove('is-dragging');
    });
    target.addEventListener('drop', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth = 0;
      target.classList.remove('is-dragging');
      const file = e.dataTransfer.files && e.dataTransfer.files[0];
      if (file) handleBackupFile(file);
    });
  }

  /* --------------------------------------------------------- wipe all */

  async function wipeEverything() {
    const sets = db.listSets();
    const cards = sets.reduce((n, s) => n + s.cards.length, 0);
    const fromHere = desktop ? 'von diesem Computer' : 'aus diesem Browser';
    let what;
    if (!sets.length) what = `Deine Statistik und deine Einstellungen werden ${fromHere} gelöscht.`;
    else if (sets.length === 1) {
      what = `Dein Lernset mit ${plural(cards, 'Begriff', 'Begriffen')}, dein Lernfortschritt, deine Statistik und deine Einstellungen werden ${fromHere} gelöscht.`;
    } else {
      what = `Alle ${sets.length} Lernsets mit ${plural(cards, 'Begriff', 'Begriffen')}, dein Lernfortschritt, deine Statistik und deine Einstellungen werden ${fromHere} gelöscht.`;
    }
    const firstMessage = h(
      'div',
      { class: 'st-confirm' },
      h('p', { class: 'ui-confirm__message' }, what),
      sets.length
        ? h(
            'div',
            { class: 'st-confirm__tip' },
            h('p', null, 'Tipp: Sichere vorher ein Backup.'),
            button({ label: 'Exportieren', icon: 'download', variant: 'secondary', size: 'sm', onClick: exportBackup }),
          )
        : null,
    );
    const first = await confirmDialog({ title: 'Alle Daten löschen?', message: firstMessage, confirmLabel: 'Weiter' });
    if (!first || !root.isConnected) return;

    const second = await confirmDialog({
      title: 'Wirklich alles löschen?',
      message: 'Das kann nicht rückgängig gemacht werden. Ohne Backup sind deine Lernsets danach endgültig weg.',
      confirmLabel: 'Endgültig löschen',
    });
    if (!second || !root.isConnected) return;

    try {
      db.clearAll();
    } catch (err) {
      toast(errorMessage(err, 'Die Daten konnten nicht gelöscht werden.'), { tone: 'danger' });
      return;
    }
    applyTheme('system');
    toast('Alle Daten wurden gelöscht.', { tone: 'success' });
    navigate('/');
  }

  /* ------------------------------------------------------------ sync */

  // Keeps the controls in step with changes from other tabs or screens.
  function syncFromStore(keys) {
    if (!keys || keys.includes('settings')) {
      settings = db.getSettings();
      if (themeSeg.value !== settings.theme) {
        themeSeg.setValue(settings.theme);
        showTheme(settings.theme);
      }
      studyForm.update(settings.study);
      syncResetButton();
    }
    if (!keys || keys.some((k) => k === 'sets' || k.startsWith('progress:') || k === 'activity')) updateSummary();
    if (!keys || keys.includes('sets')) renderVoices();
  }

  cleanups.push(
    db.subscribe((event) => {
      if (root.isConnected) syncFromStore(event && Array.isArray(event.keys) ? event.keys : null);
    }),
  );

  return () => {
    for (const fn of cleanups.splice(0)) {
      try {
        fn();
      } catch {
        /* keep cleaning up */
      }
    }
  };
}
