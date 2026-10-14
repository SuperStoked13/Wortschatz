// Text-to-speech via the Web Speech API (browser only at call time, safe to import anywhere):
// the voice chosen in Einstellungen › Stimmen zum Vorlesen (PREF.voices, per language), else the
// best installed one. A word is never read with a voice of another language: when none is
// installed (often French on a German Windows), the missing-voice handler is told instead
// (main.js shows a hint) and nothing is spoken.

import { LANGS } from './labels.js';
import { PREF, getPref, setPref } from './prefs.js';

let voicesHooked = false;
const voiceCache = new Map();
const voiceListeners = new Set();
let missingVoiceHandler = null;

export function canSpeak() {
  return typeof globalThis.speechSynthesis !== 'undefined' && typeof globalThis.SpeechSynthesisUtterance === 'function';
}

function installedVoices() {
  if (!canSpeak()) return [];
  try {
    return globalThis.speechSynthesis.getVoices() || [];
  } catch {
    return [];
  }
}

function hookVoices() {
  if (voicesHooked || !canSpeak()) return;
  voicesHooked = true;
  const synth = globalThis.speechSynthesis;
  const changed = () => {
    voiceCache.clear();
    for (const fn of [...voiceListeners]) {
      try {
        fn();
      } catch {
        /* a broken listener must not stop the others */
      }
    }
  };
  if (typeof synth.addEventListener === 'function') synth.addEventListener('voiceschanged', changed);
  else synth.onvoiceschanged = changed;
  synth.getVoices(); // kicks off async loading in Chromium
}

// Starts loading the voices early (Chromium lists them only after a moment), so the first
// speaker button already knows whether the language has a voice.
export function primeVoices() {
  hookVoices();
}

// Whether the installed voices are known (Chromium: after the first 'voiceschanged').
export function voicesLoaded() {
  hookVoices();
  return installedVoices().length > 0;
}

// fn() whenever the installed voices change or finish loading; returns `off`.
export function onVoicesChanged(fn) {
  hookVoices();
  voiceListeners.add(fn);
  return () => voiceListeners.delete(fn);
}

// fn(langCode) when a word should be read in a language without an installed voice.
export function setMissingVoiceHandler(fn) {
  missingVoiceHandler = typeof fn === 'function' ? fn : null;
}

const norm = (tag) => String(tag || '').replace(/_/g, '-').toLowerCase();

// The BCP 47 tag to speak `langCode` in ('fr' → 'fr-FR'); '' for 'other'.
function bcp47For(langCode) {
  return (LANGS[langCode] && LANGS[langCode].bcp47) || (langCode && langCode !== 'other' ? langCode : '');
}

// How well `voice` fits the wanted tag; negative: another language.
function scoreVoice(voice, wanted) {
  const lang = norm(voice && voice.lang);
  const primary = wanted.split('-')[0];
  let score = 0;
  if (lang === wanted) score += 100;
  else if (lang.split('-')[0] === primary) score += 50;
  else return -1;
  // Swiss German voices are rare; Germany German is the natural fallback.
  if (wanted === 'de-ch' && lang === 'de-de') score += 20;
  const name = String(voice.name || '').toLowerCase();
  if (/premium|enhanced|neural|natural/.test(name)) score += 15;
  if (/google/.test(name)) score += 6;
  if (voice.localService) score += 4;
  if (voice.default) score += 2;
  if (/compact|eloquence|novelty|whisper|bad news|bells|jester|organ|trinoids|zarvox/.test(name)) score -= 30;
  return score;
}

// The voices that speak `bcp47`, best first (equal scores keep the system's order). Pure.
export function rankVoices(voices, bcp47) {
  const wanted = norm(bcp47);
  if (!wanted || !Array.isArray(voices)) return [];
  return voices
    .map((voice, index) => ({ voice, index, score: voice ? scoreVoice(voice, wanted) : -1 }))
    .filter((entry) => entry.score >= 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map((entry) => entry.voice);
}

const voiceId = (voice) => String((voice && (voice.voiceURI || voice.name)) || '');

function storedVoices() {
  const stored = getPref(PREF.voices, null);
  return stored && typeof stored === 'object' && !Array.isArray(stored) ? stored : {};
}

// The voice chosen for `langCode` in the settings (its voiceURI), or null for «Automatisch».
export function preferredVoiceId(langCode) {
  const id = storedVoices()[langCode];
  return typeof id === 'string' && id ? id : null;
}

// Stores the voice for `langCode` (null: «Automatisch»).
export function setPreferredVoice(langCode, id) {
  const next = { ...storedVoices() };
  if (typeof id === 'string' && id) next[langCode] = id;
  else delete next[langCode];
  setPref(PREF.voices, Object.keys(next).length ? next : null);
}

// The best installed voice for `langCode` (ignoring the settings), or null.
function automaticVoice(langCode) {
  const wanted = norm(bcp47For(langCode));
  if (!wanted) return null;
  if (voiceCache.has(wanted)) return voiceCache.get(wanted);
  const voices = installedVoices();
  const best = rankVoices(voices, wanted)[0] || null;
  if (voices.length) voiceCache.set(wanted, best);
  return best;
}

// The voice that reads `langCode`: the chosen one while it is installed (and still speaks the
// language), else the automatic one; null when none speaks it.
function voiceFor(langCode) {
  const id = preferredVoiceId(langCode);
  const wanted = norm(bcp47For(langCode));
  if (id && wanted) {
    const chosen = installedVoices().find((v) => voiceId(v) === id);
    if (chosen && scoreVoice(chosen, wanted) >= 0) return chosen;
  }
  return automaticVoice(langCode);
}

// The region of a voice in German ('fr-CA' → 'Kanada'), or ''.
function regionName(tag) {
  const region = norm(tag).split('-')[1];
  if (!region || region.length !== 2) return '';
  try {
    return new Intl.DisplayNames(['de-CH', 'de'], { type: 'region' }).of(region.toUpperCase()) || '';
  } catch {
    return '';
  }
}

// How a voice reads in the picker: «Hortense (Frankreich)». Windows names carry their language
// («Microsoft Hortense - French (France)»); the row already names it. Pure.
export function voiceLabel(voice) {
  const raw = String((voice && voice.name) || '').trim();
  const name = raw.replace(/^Microsoft\s+/i, '').replace(/\s+-\s+.*$/, '').trim() || raw || 'Stimme';
  const region = regionName(voice && voice.lang);
  return region && !name.includes(region) ? `${name} (${region})` : name;
}

// The installed voices for `langCode` for the settings picker, best first: [{ id, label }].
export function voiceOptions(langCode) {
  hookVoices();
  return rankVoices(installedVoices(), bcp47For(langCode)).map((voice) => ({ id: voiceId(voice), label: voiceLabel(voice) }));
}

// The label of the voice «Automatisch» uses for `langCode`, or null when none is installed.
export function automaticVoiceLabel(langCode) {
  hookVoices();
  const voice = automaticVoice(langCode);
  return voice ? voiceLabel(voice) : null;
}

const SAMPLES = {
  fr: "Bonjour ! Aujourd'hui, nous apprenons de nouveaux mots.",
  en: "Hello! Today we're learning some new words.",
  es: '¡Hola! Hoy aprendemos palabras nuevas.',
  it: 'Ciao! Oggi impariamo parole nuove.',
};

// A short sentence to try a voice with («Probe hören»).
export function voiceSample(langCode) {
  return SAMPLES[langCode] || 'Hallo! Heute lernen wir neue Wörter.';
}

// Makes vocabulary notation read naturally: "beau/belle" -> "beau, belle", brackets dropped.
function speakable(text) {
  return String(text)
    .replace(/[()[\]{}]/g, ' ')
    .replace(/\s*\/\s*/g, ', ')
    .replace(/\s*;\s*/g, ', ')
    .replace(/\s+/g, ' ')
    .trim();
}

// Speaks `text` in the language `langCode` ('fr', 'de', …); cancels anything still speaking.
export function speak(text, langCode) {
  if (!canSpeak() || text == null || String(text).trim() === '') return;
  hookVoices();
  const synth = globalThis.speechSynthesis;
  const bcp47 = bcp47For(langCode);
  const voice = bcp47 ? voiceFor(langCode) : null;
  // The voices are known and none speaks the language: the system voice would read the word
  // with the wrong pronunciation, so say so instead. (Before the voices have loaded, the
  // utterance's language lets the browser choose.)
  if (bcp47 && !voice && installedVoices().length > 0) {
    synth.cancel();
    if (missingVoiceHandler) {
      try {
        missingVoiceHandler(langCode);
      } catch {
        /* the hint is optional */
      }
    }
    return;
  }
  const utterance = new globalThis.SpeechSynthesisUtterance(speakable(text));
  if (bcp47) utterance.lang = bcp47;
  if (voice) utterance.voice = voice;
  utterance.rate = 0.92;
  synth.cancel();
  synth.speak(utterance);
}

export function stopSpeaking() {
  if (canSpeak()) globalThis.speechSynthesis.cancel();
}
