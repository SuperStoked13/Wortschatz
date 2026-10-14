// Short, quiet interface sounds (port of the Mac app's SoundEffects.swift): a soft two-note
// chime for a correct answer, a muted low tone for a miss, a rising arpeggio for a streak
// milestone, small fanfares after a round and at the end, and for the flashcards a chime or
// a warm tone with a swish of air. Synthesized on first use, no audio files.
// The switch is Einstellungen › Töne › «Soundeffekte» (pref 'soundEffects', on by default).
// renderSound() is pure; playing needs Web Audio and runs only after a user gesture.

import { getPref, setPref, PREF } from './prefs.js';

export const SAMPLE_RATE = 44100;
const VOLUME = 0.55;

const note = (frequency, start, gain, decay, overtone = 0.18) => ({ frequency, start, gain, decay, overtone });
const swish = (from, to, start, duration, gain) => ({ from, to, start, duration, gain, q: 0.8 });

const SCORES = {
  // A5 → E6, light and short.
  correct: { notes: [note(880.0, 0, 0.2, 0.11), note(1318.51, 0.075, 0.17, 0.13)] },
  // E♭4 → B♭3, soft and low, no buzz.
  wrong: { notes: [note(311.13, 0, 0.26, 0.08, 0.08), note(233.08, 0.09, 0.24, 0.1, 0.08)] },
  // C6 E6 G6 C7: a streak milestone (5, 10, 15 … in a row).
  streak: {
    notes: [note(1046.5, 0, 0.14, 0.12), note(1318.51, 0.065, 0.14, 0.12), note(1567.98, 0.13, 0.14, 0.13), note(2093.0, 0.195, 0.12, 0.22)],
  },
  // G5 C6 E6: a round is done.
  roundDone: { notes: [note(783.99, 0, 0.16, 0.14), note(1046.5, 0.09, 0.16, 0.14), note(1318.51, 0.18, 0.15, 0.26)] },
  // C5 E5 G5, then C6 + E6 together: the session is finished.
  finished: {
    notes: [
      note(523.25, 0, 0.15, 0.14),
      note(659.25, 0.09, 0.15, 0.14),
      note(783.99, 0.18, 0.15, 0.16),
      note(1046.5, 0.28, 0.13, 0.34),
      note(1318.51, 0.28, 0.1, 0.34),
    ],
  },
  // D5 F♯5 A5 D6: the first answer of the day extended the Lernserie.
  dailyStreak: {
    notes: [note(587.33, 0, 0.15, 0.13), note(739.99, 0.08, 0.15, 0.13), note(880.0, 0.16, 0.15, 0.14), note(1174.66, 0.24, 0.13, 0.28)],
  },
  // Flashcards: «Weiss ich» is the correct chime, a little softer, with air rising.
  know: { notes: [note(880.0, 0, 0.16, 0.1), note(1318.51, 0.07, 0.14, 0.13)], swishes: [swish(1500, 3200, 0.02, 0.22, 0.11)] },
  // «Lerne ich noch»: E5 → D5, warm and quiet ("not yet", not the low tone of a miss), air falling.
  stillLearning: {
    notes: [note(659.25, 0, 0.15, 0.09, 0.07), note(587.33, 0.075, 0.13, 0.12, 0.07)],
    swishes: [swish(1500, 800, 0.02, 0.22, 0.14)],
  },
  // «Zurück»: only air, falling.
  undo: { notes: [], swishes: [swish(2200, 700, 0, 0.2, 0.13)] },
};

export const SOUNDS = Object.freeze(Object.keys(SCORES));

// Noise through two gliding band-pass stages under a smooth swell (no click at either end).
function addSwish(s, samples, rate) {
  const first = Math.floor(s.start * rate);
  const length = Math.floor(s.duration * rate);
  const peak = 0.35;
  let seed = 0x9e3779b9;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0, z1 = 0, z2 = 0, w1 = 0, w2 = 0;
  for (let i = 0; i < length && first + i < samples.length; i += 1) {
    const u = i / length;
    const swell = u < peak ? Math.sin(((Math.PI / 2) * u) / peak) ** 2 : Math.cos(((Math.PI / 2) * (u - peak)) / (1 - peak)) ** 2;
    const frequency = s.from * (s.to / s.from) ** u;
    const w0 = (2 * Math.PI * frequency) / rate;
    const alpha = Math.sin(w0) / (2 * s.q);
    const b0 = alpha / (1 + alpha);
    const b2 = -alpha / (1 + alpha);
    const a1 = (-2 * Math.cos(w0)) / (1 + alpha);
    const a2 = (1 - alpha) / (1 + alpha);
    // xorshift32: the same noise every time.
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    const x = (seed >>> 0) / 4294967296 * 2 - 1;
    const y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    const v = b0 * y + b2 * z2 - a1 * w1 - a2 * w2;
    z2 = z1;
    z1 = y;
    w2 = w1;
    w1 = v;
    samples[first + i] += s.gain * swell * v;
  }
}

// The sound as mono samples in [-1, 1] (before the output volume). Pure.
export function renderSound(name, rate = SAMPLE_RATE) {
  const score = SCORES[name];
  if (!score) throw new Error(`Unbekannter Sound: ${name}`);
  const notes = score.notes || [];
  const swishes = score.swishes || [];
  const ends = [...notes.map((n) => n.start + n.decay * 7), ...swishes.map((s) => s.start + s.duration)];
  const count = Math.floor((Math.max(0, ...ends) + 0.02) * rate);
  const samples = new Float32Array(count);
  for (const s of swishes) addSwish(s, samples, rate);
  const attack = 0.004;
  for (const n of notes) {
    const first = Math.floor(n.start * rate);
    const last = Math.min(count, Math.floor((n.start + n.decay * 7) * rate));
    for (let i = first; i < last; i += 1) {
      const t = i / rate - n.start;
      const envelope = Math.min(1, t / attack) * Math.exp(-t / n.decay);
      const phase = 2 * Math.PI * n.frequency * t;
      const tone = Math.sin(phase) + n.overtone * Math.sin(2 * phase) * Math.exp(-t / (n.decay * 0.5)) + 0.05 * Math.sin(3 * phase);
      samples[i] += n.gain * envelope * tone;
    }
  }
  // A short fade at the very end, so the last sample never clicks.
  const fade = Math.min(count, Math.floor(0.01 * rate));
  for (let k = 0; k < fade; k += 1) samples[count - 1 - k] *= k / fade;
  for (let i = 0; i < count; i += 1) samples[i] = Math.max(-1, Math.min(1, samples[i]));
  return samples;
}

export function soundEffectsEnabled() {
  return getPref(PREF.soundEffects, true) !== false;
}

export function setSoundEffectsEnabled(on) {
  setPref(PREF.soundEffects, !!on);
}

let context = null;
const buffers = new Map();

function audioContext() {
  if (context) return context;
  const Ctor = typeof window !== 'undefined' ? window.AudioContext || window.webkitAudioContext : null;
  if (!Ctor) return null;
  try {
    context = new Ctor();
  } catch {
    context = null;
  }
  return context;
}

// Plays `name` unless sound effects are off (`force` plays anyway: the preview in settings).
// Overlapping sounds don't cut each other off. Never throws.
export function playSound(name, { force = false } = {}) {
  if (!SCORES[name] || (!force && !soundEffectsEnabled())) return;
  const ctx = audioContext();
  if (!ctx) return;
  try {
    if (ctx.state === 'suspended' && typeof ctx.resume === 'function') ctx.resume().catch(() => {});
    let buffer = buffers.get(name);
    if (!buffer) {
      const samples = renderSound(name, ctx.sampleRate || SAMPLE_RATE);
      buffer = ctx.createBuffer(1, samples.length, ctx.sampleRate || SAMPLE_RATE);
      buffer.getChannelData(0).set(samples);
      buffers.set(name, buffer);
    }
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    const gain = ctx.createGain();
    gain.gain.value = VOLUME;
    source.connect(gain);
    gain.connect(ctx.destination);
    source.start();
  } catch {
    /* no audio device: stay quiet */
  }
}

// What a study step (Lernen, Schreiben) sounds like: the fanfare when the session or a round is
// done, else the chime of the answer just recorded (a streak milestone gets its own).
// answer: 'correct' | 'wrong' | 'dontKnow' | null — «Weiss ich nicht» stays quiet.
export function studyStepSound({ finished = false, roundDone = false, answer = null, milestone = false } = {}) {
  if (finished) return 'finished';
  if (roundDone) return 'roundDone';
  if (answer === 'correct') return milestone ? 'streak' : 'correct';
  if (answer === 'wrong') return 'wrong';
  return null;
}

export function playStudyStep(step) {
  const name = studyStepSound(step);
  if (name) playSound(name);
}
