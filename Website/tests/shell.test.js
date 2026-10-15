// The app shell around the study screens: set page helpers («Nur schwierige», keys), the daily
// Lernserie copy and celebration rules, shortcuts, voices (speech.js) and the Windows host glue.
import { test, expect, run } from './harness.js';
import { DIFFICULT_MISTAKES, difficultCards, mistakesOf, setPageCommand } from '../src/screens/set-model.js';
import { commandKey, commandLetter, isComposingKey, isTypingTarget } from '../src/lib/shortcuts.js';
import * as streakModule from '../src/ui/daily-streak.js';
import {
  streakTone,
  streakTitle,
  streakCaption,
  streakTooltip,
  celebrationMessage,
  shouldCelebrate,
  msUntilMidnight,
  CELEBRATE_DELAY_MS,
  CELEBRATE_TOAST_MS,
} from '../src/ui/daily-streak.js';
import * as speech from '../src/lib/speech.js';
import { isDesktopApp, opensNewWindow, blockNewWindows, reportUnsaved } from '../src/lib/host.js';
import { hasIcon } from '../src/ui/icons.js';
import { PREF, getPref, setPref } from '../src/lib/prefs.js';

/* ---------------------------------------------------------------- set page */

const card = (id, extra = {}) => ({ id, term: id, definition: `${id}-def`, starred: false, ...extra });

test('difficult cards: at least 4 mistakes, most mistakes first, then card order', () => {
  expect(DIFFICULT_MISTAKES).toBe(4);
  const cards = [card('a'), card('b'), card('c'), card('d'), card('e')];
  const progress = {
    a: { correct: 9, incorrect: 4 },
    b: { correct: 0, incorrect: 3 },
    c: { correct: 1, incorrect: 7 },
    d: { correct: 2, incorrect: 4 },
    e: { correct: 0, incorrect: 0 },
  };
  expect(difficultCards(cards, progress).map((c) => c.id)).toEqual(['c', 'a', 'd']);
  expect(difficultCards(cards, {})).toEqual([]);
  expect(difficultCards(null, progress)).toEqual([]);
});

test('mistakesOf reads only real counts', () => {
  expect(mistakesOf({ a: { incorrect: 5 } }, 'a')).toBe(5);
  expect(mistakesOf({ a: { incorrect: '6' } }, 'a')).toBe(6);
  expect(mistakesOf({ a: { incorrect: -2 } }, 'a')).toBe(0);
  expect(mistakesOf({ a: { incorrect: NaN } }, 'a')).toBe(0);
  expect(mistakesOf({}, 'a')).toBe(0);
  expect(mistakesOf(null, 'a')).toBe(0);
  // Inherited keys are not progress.
  expect(mistakesOf({}, 'toString')).toBe(0);
});

const key = (k, mods = {}) => ({ key: k, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...mods });

test('set page keys: Ctrl+L Lernen, Ctrl+Shift+L Schreiben, Ctrl+E Bearbeiten (⌘ on the Mac)', () => {
  expect(setPageCommand(key('l', { ctrlKey: true }))).toBe('learn');
  expect(setPageCommand(key('l', { metaKey: true }))).toBe('learn');
  expect(setPageCommand(key('L', { ctrlKey: true, shiftKey: true }))).toBe('write');
  expect(setPageCommand(key('e', { ctrlKey: true }))).toBe('edit');
  expect(setPageCommand(key('E', { metaKey: true }))).toBe('edit');
  expect(setPageCommand(key('l'))).toBe(null);
  expect(setPageCommand(key('e', { ctrlKey: true, shiftKey: true }))).toBe(null);
  expect(setPageCommand(key('k', { ctrlKey: true }))).toBe(null);
});

test('Ctrl+Alt (AltGr on Swiss keyboards) is never a shortcut', () => {
  expect(commandKey(key('l', { ctrlKey: true, altKey: true }), 'l')).toBe(false);
  expect(setPageCommand(key('e', { ctrlKey: true, altKey: true }))).toBe(null);
  expect(commandKey(key('n', { ctrlKey: true }), 'n')).toBe(true);
  expect(commandKey(key('N', { ctrlKey: true, shiftKey: true }), 'n')).toBe(false);
  expect(commandKey(key('s', { metaKey: true }), 's')).toBe(true);
  expect(commandKey(null, 's')).toBe(false);
});

test('Arabic keyboard: shortcuts fall back to the key position; Latin layouts keep their letters', () => {
  // Chromium reports the layout's letter (Ctrl+N gives «ى» on Arabic 101).
  expect(commandKey(key('ى', { ctrlKey: true, code: 'KeyN' }), 'n')).toBe(true);
  expect(commandKey(key('س', { metaKey: true, code: 'KeyS' }), 's')).toBe(true);
  expect(setPageCommand(key('م', { ctrlKey: true, code: 'KeyL' }))).toBe('learn');
  expect(setPageCommand(key('م', { ctrlKey: true, shiftKey: true, code: 'KeyL' }))).toBe('write');
  expect(setPageCommand(key('ث', { ctrlKey: true, code: 'KeyE' }))).toBe('edit');
  expect(commandKey(key('ى', { ctrlKey: true, altKey: true, code: 'KeyN' }), 'n')).toBe(false);
  expect(commandLetter(key('ق', { code: 'KeyR' }))).toBe('r');
  expect(commandLetter(key('R', { code: 'KeyR' }))).toBe('r');
  // AZERTY: «,» sits where QWERTY has M, «a» where it has Q; the letter typed counts.
  expect(commandLetter(key(',', { code: 'KeyM' }))).toBe('');
  expect(commandLetter(key('a', { code: 'KeyQ' }))).toBe('a');
  expect(commandLetter(key('Enter', { code: 'Enter' }))).toBe('');
  expect(commandLetter(null)).toBe('');
});

test('keys an input method is composing (Pinyin) are no shortcuts', () => {
  expect(isComposingKey({ key: 'Process', keyCode: 229, isComposing: false })).toBe(true);
  expect(isComposingKey({ key: 'Enter', keyCode: 13, isComposing: true })).toBe(true);
  expect(isComposingKey({ key: 'Enter', keyCode: 13, isComposing: false })).toBe(false);
  expect(isComposingKey(null)).toBe(false);
});

test('typing targets: text fields, selects and editable content', () => {
  const el = (tagName, extra = {}) => ({ nodeType: 1, tagName, ...extra });
  expect(isTypingTarget(el('INPUT', { type: 'text' }))).toBe(true);
  expect(isTypingTarget(el('INPUT', { type: 'search' }))).toBe(true);
  expect(isTypingTarget(el('INPUT', { type: '' }))).toBe(true);
  expect(isTypingTarget(el('INPUT', { type: 'checkbox' }))).toBe(false);
  expect(isTypingTarget(el('INPUT', { type: 'radio' }))).toBe(false);
  expect(isTypingTarget(el('TEXTAREA'))).toBe(true);
  expect(isTypingTarget(el('SELECT'))).toBe(true);
  expect(isTypingTarget(el('DIV', { isContentEditable: true }))).toBe(true);
  expect(isTypingTarget(el('A'))).toBe(false);
  expect(isTypingTarget({ nodeType: 3, parentElement: el('TEXTAREA') })).toBe(true);
  expect(isTypingTarget(null)).toBe(false);
});

/* ---------------------------------------------------------- daily Lernserie */

test('Lernserie title, caption and tooltip (Mac sidebar footer)', () => {
  const s = (current, today, longest) => ({ current, today, longest });
  expect(streakTitle(s(6, 3, 9))).toBe('6 Tage Lernserie');
  expect(streakTitle(s(1, 1, 1))).toBe('1 Tag Lernserie');
  expect(streakTitle(s(0, 0, 4))).toBe('Noch keine Lernserie');
  expect(streakCaption(s(6, 3, 9))).toBe('Heute geschafft');
  expect(streakCaption(s(6, 0, 9))).toBe('Heute noch lernen');
  expect(streakCaption(s(0, 0, 4))).toBe('Rekord: 4 Tage');
  expect(streakCaption(s(0, 0, 1))).toBe('Rekord: 1 Tag');
  expect(streakCaption(s(0, 0, 0))).toBe('Lerne heute, um zu starten');
  expect(streakTooltip(s(6, 3, 9))).toBe('Längste Serie: 9 Tage');
  expect(streakTooltip(s(0, 0, 0))).toBe('');
  expect(streakTone(s(6, 3, 9))).toBe('lit');
  expect(streakTone(s(6, 0, 9))).toBe('pending');
  expect(streakTone(s(0, 0, 9))).toBe('off');
  expect(streakTone(null)).toBe('off');
});

test('the once-a-day toast: message, timing and when it is due', () => {
  expect(celebrationMessage(1)).toBe('Neue Lernserie gestartet – lerne morgen weiter!');
  expect(celebrationMessage(5)).toBe('Lernserie: 5 Tage in Folge!');
  expect(CELEBRATE_DELAY_MS).toBe(650);
  expect(CELEBRATE_TOAST_MS).toBe(3500);
  const today = '2026-10-14';
  expect(shouldCelebrate({ current: 3, today: 1, longest: 3 }, null, today)).toBe(true);
  expect(shouldCelebrate({ current: 3, today: 1, longest: 3 }, '2026-10-13', today)).toBe(true);
  expect(shouldCelebrate({ current: 3, today: 1, longest: 3 }, today, today)).toBe(false);
  expect(shouldCelebrate({ current: 3, today: 0, longest: 3 }, null, today)).toBe(false);
  expect(shouldCelebrate({ current: 0, today: 0, longest: 0 }, null, today)).toBe(false);
  expect(PREF.streakCelebrated).toBe('dailyStreakCelebrated');
});

test('the indicator is refreshed at the next local midnight', () => {
  const evening = new Date(2026, 9, 14, 23, 59, 30).getTime();
  expect(msUntilMidnight(evening)).toBe(30 * 1000);
  const morning = new Date(2026, 9, 14, 0, 0, 0).getTime();
  expect(msUntilMidnight(morning)).toBe(new Date(2026, 9, 15, 0, 0, 0).getTime() - morning);
});

test('the watcher celebrates the first answer of a day in Lernen or Schreiben once, and stops cleanly', async () => {
  const { db } = await import('../src/store/db.js');
  const { dateKey } = await import('../src/lib/time.js');
  // Fake timers (jsc has setTimeout but no clearTimeout) and the bits of a document it reads.
  const realSetTimeout = globalThis.setTimeout;
  const realClearTimeout = globalThis.clearTimeout;
  const timers = new Map();
  let nextTimer = 1;
  globalThis.setTimeout = (fn, ms) => {
    const id = nextTimer++;
    timers.set(id, { fn, ms });
    return id;
  };
  globalThis.clearTimeout = (id) => timers.delete(id);
  const docListeners = new Map();
  globalThis.document = {
    documentElement: { dataset: { route: 'set' } },
    visibilityState: 'visible',
    addEventListener: (type, fn) => docListeners.set(type, fn),
    removeEventListener: (type, fn) => {
      if (docListeners.get(type) === fn) docListeners.delete(type);
    },
  };
  const celebrations = () => [...timers.values()].filter((t) => t.ms === CELEBRATE_DELAY_MS).length;
  const shown = [];
  setPref(PREF.streakCelebrated, null);
  const stop = streakModule.watchDailyStreak({ update: (streak) => shown.push(streak) });
  try {
    expect(shown).toHaveLength(1);
    // The next midnight is scheduled (a second late).
    expect([...timers.values()].some((t) => t.ms > 1000)).toBe(true);
    const set = db.createSet({ title: 'Serie', termLang: 'fr', defLang: 'de', cards: [{ term: 'la mer', definition: 'das Meer' }] });
    const cardId = db.getSet(set.id).cards[0].id;
    const updates = shown.length;
    // Writes without answers leave the indicator alone.
    db.toggleStar(set.id, cardId);
    expect(shown).toHaveLength(updates);
    // An answer outside Lernen and Schreiben updates the indicator but celebrates nothing.
    db.recordAnswer(set.id, cardId, true);
    expect(shown[shown.length - 1].today).toBe(1);
    expect(getPref(PREF.streakCelebrated)).toBe(null);
    expect(celebrations()).toBe(0);
    // The next answer in Lernen: today is celebrated, the toast follows after 650 ms.
    globalThis.document.documentElement.dataset.route = 'learn';
    db.recordAnswer(set.id, cardId, false);
    expect(getPref(PREF.streakCelebrated)).toBe(dateKey(Date.now()));
    expect(celebrations()).toBe(1);
    // Only once a day.
    globalThis.document.documentElement.dataset.route = 'write';
    db.recordAnswer(set.id, cardId, true);
    expect(celebrations()).toBe(1);
    expect(docListeners.has('visibilitychange')).toBe(true);
  } finally {
    stop();
    const left = timers.size;
    const listening = docListeners.size;
    globalThis.setTimeout = realSetTimeout;
    if (realClearTimeout === undefined) delete globalThis.clearTimeout;
    else globalThis.clearTimeout = realClearTimeout;
    delete globalThis.document;
    setPref(PREF.streakCelebrated, null);
    // stop() cancels the pending toast and the midnight refresh and removes its listener.
    expect(left).toBe(0);
    expect(listening).toBe(0);
  }
});

test('daily-streak.js exports its DOM parts and the filled flame icon exists', () => {
  expect(typeof streakModule.createStreakIndicator).toBe('function');
  expect(typeof streakModule.watchDailyStreak).toBe('function');
  expect(hasIcon('flameFilled')).toBe(true);
  expect(hasIcon('cards')).toBe(true);
  expect(hasIcon('graduationCap')).toBe(true);
});

/* ------------------------------------------------------------------ voices */

const voice = (name, lang, extra = {}) => ({ name, lang, voiceURI: `uri:${name}`, localService: true, default: false, ...extra });

test('rankVoices keeps only voices of the language, best first', () => {
  const voices = [
    voice('Microsoft Katja - German (Germany)', 'de-DE'),
    voice('Microsoft Hortense - French (France)', 'fr-FR'),
    voice('Microsoft Karsten - German (Switzerland)', 'de-CH'),
    voice('Microsoft Caroline - French (Canada)', 'fr-CA'),
    voice('Microsoft Zira - English (United States)', 'en-US'),
  ];
  expect(speech.rankVoices(voices, 'fr-FR').map((v) => v.lang)).toEqual(['fr-FR', 'fr-CA']);
  // de-CH first, Germany German as the close second.
  expect(speech.rankVoices(voices, 'de-CH').map((v) => v.lang)).toEqual(['de-CH', 'de-DE']);
  expect(speech.rankVoices(voices, 'en-GB').map((v) => v.lang)).toEqual(['en-US']);
  expect(speech.rankVoices(voices, 'it-IT')).toEqual([]);
  expect(speech.rankVoices(voices, '')).toEqual([]);
  // Equal scores keep the system's order.
  const twins = [voice('B', 'es-ES'), voice('A', 'es-ES')];
  expect(speech.rankVoices(twins, 'es-ES').map((v) => v.name)).toEqual(['B', 'A']);
});

test('voice labels drop the Windows prefix and language and add the region', () => {
  expect(speech.voiceLabel(voice('Microsoft Hortense - French (France)', 'fr-FR'))).toBe('Hortense (Frankreich)');
  expect(speech.voiceLabel(voice('Microsoft Denise Online (Natural) - French (France)', 'fr-FR'))).toBe('Denise Online (Natural) (Frankreich)');
  expect(speech.voiceLabel(voice('Thomas', 'fr_FR'))).toBe('Thomas (Frankreich)');
  expect(speech.voiceLabel(voice('Anna', 'de'))).toBe('Anna');
  expect(speech.voiceLabel(voice('Jean-Pierre', 'fr-CH'))).toBe('Jean-Pierre (Schweiz)');
});

test('voice samples per language', () => {
  expect(speech.voiceSample('fr')).toBe("Bonjour ! Aujourd'hui, nous apprenons de nouveaux mots.");
  expect(speech.voiceSample('de')).toBe('Hallo! Heute lernen wir neue Wörter.');
  expect(speech.voiceSample('other')).toBe('Hallo! Heute lernen wir neue Wörter.');
  expect(speech.voiceSample('ar')).toBe('مرحبًا! اليوم نتعلّم كلمات جديدة.');
  expect(speech.voiceSample('zh')).toBe('你好！今天我们学习新词。');
});

test('Chinese is never read by a Cantonese voice; Arabic takes any Arabic voice', () => {
  const voices = [
    voice('Microsoft Tracy - Chinese (Traditional, Hong Kong S.A.R.)', 'zh-HK'),
    voice('Sinji', 'zh_HK'),
    voice('Macau', 'zh-MO'),
    voice('Google 粵語', 'yue-HK'),
    voice('Cantonese Hant', 'zh-Hant-HK'),
    voice('Microsoft Hanhan - Chinese (Traditional, Taiwan)', 'zh-TW'),
    voice('Microsoft Huihui - Chinese (Simplified, PRC)', 'zh-CN'),
    voice('Microsoft Hoda - Arabic (Egypt)', 'ar-EG'),
    voice('Microsoft Naayf - Arabic (Saudi Arabia)', 'ar-SA'),
    voice('Majed', 'ar-001'),
  ];
  // Mainland Mandarin first, Taiwan Mandarin as the fallback.
  expect(speech.rankVoices(voices, 'zh-CN').map((v) => v.lang)).toEqual(['zh-CN', 'zh-TW']);
  expect(speech.rankVoices(voices, 'ar').map((v) => v.lang)).toEqual(['ar-EG', 'ar-SA', 'ar-001']);
  // Cantonese voices still read Cantonese when that is asked for.
  expect(speech.rankVoices(voices, 'zh-HK').map((v) => v.lang)).toEqual(['zh-HK', 'zh_HK', 'zh-MO', 'zh-Hant-HK', 'zh-TW', 'zh-CN']);
  // The region name comes from Intl («China», with some ICU versions «China, Festland»).
  expect(speech.voiceLabel(voices[6]).startsWith('Huihui (China')).toBe(true);
});

test('speakable: Chinese with characters reads only the characters, never the pinyin', () => {
  expect(speech.speakable('你好 (nǐ hǎo)', 'zh')).toBe('你好');
  expect(speech.speakable('你好（nǐ hǎo）', 'zh')).toBe('你好');
  expect(speech.speakable('你好 nǐ hǎo', 'zh')).toBe('你好');
  expect(speech.speakable('nǐ hǎo 你好', 'zh')).toBe('你好');
  expect(speech.speakable('ni3 hao3 你好', 'zh')).toBe('你好');
  expect(speech.speakable('你好 (nǐ hǎo, ní hǎo)', 'zh')).toBe('你好');
  expect(speech.speakable('nǐ hǎo / ní hǎo 你好', 'zh')).toBe('你好');
  expect(speech.speakable('谢谢/多谢', 'zh')).toBe('谢谢, 多谢');
  expect(speech.speakable('谢谢 (xièxie)；多谢 (duōxiè)', 'zh')).toBe('谢谢, 多谢');
  // Characters inside brackets are read; only the brackets go.
  expect(speech.speakable('(很) 好 (hǎo)', 'zh')).toBe('很 好');
  // Pinyin alone is all there is to read; other languages keep their Latin letters.
  expect(speech.speakable('nǐ hǎo', 'zh')).toBe('nǐ hǎo');
  expect(speech.speakable('le chat (m)', 'fr')).toBe('le chat m');
  expect(speech.speakable('beau/belle; joli', 'fr')).toBe('beau, belle, joli');
  expect(speech.speakable('你好 (nǐ hǎo)', 'other')).toBe('你好 nǐ hǎo');
  expect(speech.speakable('كِتَاب (m)', 'ar')).toBe('كِتَاب m');
});

test('the chosen voice per language is an app preference', () => {
  expect(speech.preferredVoiceId('fr')).toBe(null);
  speech.setPreferredVoice('fr', 'uri:Hortense');
  speech.setPreferredVoice('de', 'uri:Karsten');
  expect(speech.preferredVoiceId('fr')).toBe('uri:Hortense');
  expect(getPref(PREF.voices)).toEqual({ fr: 'uri:Hortense', de: 'uri:Karsten' });
  speech.setPreferredVoice('fr', null);
  expect(speech.preferredVoiceId('fr')).toBe(null);
  speech.setPreferredVoice('de', '');
  expect(getPref(PREF.voices, 'none')).toBe('none');
});

// A stand-in for the Web Speech API (jsc has none).
function fakeSpeech(initial) {
  const state = { voices: initial, spoken: [], cancels: 0, listeners: [] };
  globalThis.speechSynthesis = {
    getVoices: () => state.voices,
    cancel: () => {
      state.cancels += 1;
    },
    speak: (u) => state.spoken.push(u),
    addEventListener: (type, fn) => {
      if (type === 'voiceschanged') state.listeners.push(fn);
    },
  };
  globalThis.SpeechSynthesisUtterance = function SpeechSynthesisUtterance(text) {
    this.text = text;
  };
  state.change = (voices) => {
    state.voices = voices;
    for (const fn of state.listeners) fn();
  };
  return state;
}

test('speak never reads a word with a voice of another language', () => {
  const german = [voice('Microsoft Katja - German (Germany)', 'de-DE'), voice('Microsoft Karsten - German (Switzerland)', 'de-CH')];
  const fake = fakeSpeech(german);
  const missing = [];
  speech.setMissingVoiceHandler((code) => missing.push(code));
  let changes = 0;
  const off = speech.onVoicesChanged(() => (changes += 1));

  speech.speak('la voiture', 'fr');
  expect(fake.spoken).toHaveLength(0);
  expect(missing).toEqual(['fr']);

  speech.speak('der Hund', 'de');
  expect(fake.spoken).toHaveLength(1);
  expect(fake.spoken[0].voice.lang).toBe('de-CH');
  expect(fake.spoken[0].lang).toBe('de-CH');
  expect(fake.spoken[0].text).toBe('der Hund');

  // A French voice is installed later: the cache is dropped and it reads.
  const hortense = voice('Microsoft Hortense - French (France)', 'fr-FR');
  const julie = voice('Microsoft Julie - French (France)', 'fr-FR');
  fake.change([...german, hortense, julie]);
  expect(changes).toBe(1);
  speech.speak('beau/belle', 'fr');
  expect(fake.spoken).toHaveLength(2);
  expect(fake.spoken[1].voice.name).toBe(hortense.name);
  expect(fake.spoken[1].text).toBe('beau, belle');
  expect(speech.voiceOptions('fr').map((o) => o.label)).toEqual(['Hortense (Frankreich)', 'Julie (Frankreich)']);
  expect(speech.automaticVoiceLabel('fr')).toBe('Hortense (Frankreich)');
  expect(speech.automaticVoiceLabel('it')).toBe(null);

  // The chosen voice wins while it is installed and speaks the language.
  speech.setPreferredVoice('fr', julie.voiceURI);
  speech.speak('la mer', 'fr');
  expect(fake.spoken[2].voice.name).toBe(julie.name);
  speech.setPreferredVoice('fr', 'uri:Microsoft Katja - German (Germany)');
  speech.speak('la mer', 'fr');
  expect(fake.spoken[3].voice.name).toBe(hortense.name);
  speech.setPreferredVoice('fr', null);

  // 'other' has no language: the system voice reads it.
  speech.speak('xyz', 'other');
  expect(fake.spoken[4].voice).toBe(undefined);
  expect(missing).toEqual(['fr']);

  // Before the voices have loaded, the utterance's language lets the browser choose.
  fake.change([]);
  speech.speak('il mare', 'it');
  expect(fake.spoken[5].lang).toBe('it-IT');
  expect(fake.spoken[5].voice).toBe(undefined);
  expect(speech.voicesLoaded()).toBe(false);

  off();
  speech.setMissingVoiceHandler(null);
  delete globalThis.speechSynthesis;
  delete globalThis.SpeechSynthesisUtterance;
  expect(speech.canSpeak()).toBe(false);
});

test('speak reads Chinese characters with a Mandarin voice, even when Cantonese was chosen', () => {
  const tracy = voice('Microsoft Tracy - Chinese (Traditional, Hong Kong S.A.R.)', 'zh-HK');
  const huihui = voice('Microsoft Huihui - Chinese (Simplified, PRC)', 'zh-CN');
  const fake = fakeSpeech([tracy, huihui]);
  const missing = [];
  speech.setMissingVoiceHandler((code) => missing.push(code));
  speech.setPreferredVoice('zh', tracy.voiceURI);

  speech.speak('你好 (nǐ hǎo)', 'zh');
  expect(fake.spoken).toHaveLength(1);
  expect(fake.spoken[0].text).toBe('你好');
  expect(fake.spoken[0].lang).toBe('zh-CN');
  expect(fake.spoken[0].voice.name).toBe(huihui.name);
  expect(speech.voiceOptions('zh').map((o) => o.label.split(' ')[0])).toEqual(['Huihui']);

  // No Arabic voice installed: nothing is read, the hint is shown.
  speech.speak('كِتَاب', 'ar');
  expect(fake.spoken).toHaveLength(1);
  expect(missing).toEqual(['ar']);

  speech.setPreferredVoice('zh', null);
  speech.setMissingVoiceHandler(null);
  delete globalThis.speechSynthesis;
  delete globalThis.SpeechSynthesisUtterance;
});

/* ------------------------------------------------------------- Windows host */

test('only Ctrl-, Shift-, ⌘- and middle clicks would open a new window', () => {
  expect(opensNewWindow({ type: 'click', button: 0, ctrlKey: true })).toBe(true);
  expect(opensNewWindow({ type: 'click', button: 0, shiftKey: true })).toBe(true);
  expect(opensNewWindow({ type: 'click', button: 0, metaKey: true })).toBe(true);
  expect(opensNewWindow({ type: 'click', button: 0 })).toBe(false);
  expect(opensNewWindow({ type: 'auxclick', button: 1 })).toBe(true);
  expect(opensNewWindow({ type: 'auxclick', button: 2 })).toBe(false);
  expect(opensNewWindow(null)).toBe(false);
});

test('outside the Windows app the host glue does nothing', () => {
  expect(isDesktopApp()).toBe(false);
  blockNewWindows();
  reportUnsaved(true);
  globalThis.window = { wortschatzHost: { platform: 'windows', setUnsaved: (on) => (globalThis.__unsaved = on) } };
  try {
    expect(isDesktopApp()).toBe(true);
    reportUnsaved(1);
    expect(globalThis.__unsaved).toBe(true);
    reportUnsaved(false);
    expect(globalThis.__unsaved).toBe(false);
  } finally {
    delete globalThis.window;
    delete globalThis.__unsaved;
  }
});

/* ----------------------------------------------------------------- modules */

test('the shell screens import under jsc', async () => {
  for (const path of ['../src/screens/settings.js', '../src/screens/dashboard.js', '../src/screens/editor.js', '../src/main.js']) {
    const mod = await import(path);
    if (path !== '../src/main.js') expect(typeof mod.render).toBe('function');
  }
});

await run('shell.test.js');
