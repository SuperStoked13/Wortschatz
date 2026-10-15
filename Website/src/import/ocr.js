// Text recognition for photos and screenshots (tesseract.js, loaded lazily
// from jsDelivr on first use). Browser only — nothing here touches the DOM at
// import time, so the module still links under jsc.

import { itemsToLines, deskewItems, estimateSlope } from './layout.js';
import { detectColumn, detectLanguage } from '../core/langdetect.js';

const TESSERACT_URL = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';
const TESSERACT_SRI = 'sha384-GJqSu7vueQ9qN0E9yLPb3Wtpd7OrgK8KmYzC8T1IysG1bcvxvIO4qtYR/D3A991F';

const SMALL_WIDTH = 1200; // narrower images are upscaled 2× for better accuracy
const MAX_SIDE = 3000; // longest side after scaling (only the width for very tall screenshots)
const MAX_PIXELS = 12e6;

const MSG_OFFLINE = 'Für die Texterkennung wird eine Internetverbindung benötigt.';
const MSG_START = 'Die Texterkennung konnte nicht gestartet werden. Bitte prüfe die Internetverbindung und versuche es erneut.';
const MSG_FAILED = 'Die Texterkennung ist fehlgeschlagen. Versuche es mit einem schärferen Foto oder einem Screenshot.';
const MSG_DECODE = 'Das Bild konnte nicht geöffnet werden.';
const MSG_LOADING = 'Sprachdaten werden geladen …';
const MSG_ABORTED = 'Import abgebrochen.';

// Simplified Chinese only (chi_tra would double the download).
const TESS_CODES = { fr: 'fra', en: 'eng', es: 'spa', it: 'ita', ar: 'ara', zh: 'chi_sim' };
// A space between two CJK characters (Han, kana, CJK and full-width punctuation):
// tesseract splits Chinese text into many words, but Chinese has no spaces.
const CJK_SPACE = /([\u3001-\u303F\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uFF01-\uFF60\u{20000}-\u{2FA1F}]) +(?=[\u3001-\u303F\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uFF01-\uFF60\u{20000}-\u{2FA1F}])/gu;
const NOISE_WORD = /^[|¦_\u2500-\u259F]+$/; // table rules, box drawing
const EDGE_BARS = /^[|¦]+|[|¦]+$/g;

// With the French model loaded, umlauts are often read as circumflexes
// ("schôn"). German never writes â, ô or û.
const CIRCUMFLEX = /[âôûÂÔÛ]/;
const CIRCUMFLEXES = /[âôûÂÔÛ]/g;
const UMLAUT_OF = { â: 'ä', ô: 'ö', û: 'ü', Â: 'Ä', Ô: 'Ö', Û: 'Ü' };
const PLAIN_OF = { â: 'a', ô: 'o', û: 'u', Â: 'A', Ô: 'O', Û: 'U' };

let tesseractPromise = null;

function ocrError(message, code, cause) {
  const err = new Error(message);
  err.code = code;
  if (cause !== undefined) err.cause = cause;
  return err;
}

// Same shape as files.js abortError (code 'ABORTED', name 'AbortError').
function abortError() {
  const err = ocrError(MSG_ABORTED, 'ABORTED');
  err.name = 'AbortError';
  return err;
}

function throwIfAborted(signal) {
  if (signal && signal.aborted) throw abortError();
}

function isOffline() {
  return typeof navigator !== 'undefined' && navigator.onLine === false;
}

function reporter(onProgress) {
  if (typeof onProgress !== 'function') return () => {};
  return (fraction, message) => {
    try {
      onProgress(Math.min(1, Math.max(0, fraction || 0)), message);
    } catch {
      // A failing progress callback must never break the recognition.
    }
  };
}

function percentLabel(p) {
  return `Texterkennung läuft … ${Math.round(Math.min(1, Math.max(0, p)) * 100)}\u00A0%`;
}

// ---------------------------------------------------------------------------
// Pure helpers

// Tesseract language models for the learned language (+ German for the definitions).
export function ocrLangsFor(termLang) {
  if (!termLang) return ['fra', 'deu'];
  if (termLang === 'de') return ['deu'];
  return [TESS_CODES[termLang] || 'eng', 'deu'];
}

// Scale factor applied before recognition: small images are upscaled 2×,
// large ones are reduced so the longest side stays ≤ 3000 px (tall
// screenshots keep their width) and the pixel count stays reasonable.
export function imageScaleFor(width, height) {
  const w = Number(width);
  const h = Number(height);
  if (!(w > 0) || !(h > 0)) return 1;
  let scale = w < SMALL_WIDTH ? 2 : 1;
  const limitedSide = h > 2 * w ? w : Math.max(w, h);
  scale = Math.min(scale, MAX_SIDE / limitedSide);
  scale = Math.min(scale, Math.sqrt(MAX_PIXELS / (w * h)));
  return scale;
}

// Restores umlauts that OCR read as circumflexes in German text: every cell of
// a German table column (unless the cell itself is clearly French), any other
// cell or line only when it is clearly German on its own. Languages are judged
// with the doubtful letters made plain, so the misreading does not count as
// French evidence. French cells ("le rôle", "tôt") are never changed.
export function fixGermanUmlauts(lines) {
  const list = Array.isArray(lines) ? lines.map((l) => (l == null ? '' : String(l))) : [];
  if (!list.some((l) => CIRCUMFLEX.test(l))) return list;
  const plain = (s) => s.replace(CIRCUMFLEXES, (c) => PLAIN_OF[c]);
  const rows = list.map((l) => l.split('\t'));
  const columns = [];
  for (const cells of rows) {
    if (cells.length < 2) continue;
    cells.forEach((cell, i) => {
      if (!cell.trim()) return;
      if (!columns[i]) columns[i] = [];
      columns[i].push(plain(cell));
    });
  }
  const germanColumn = columns.map((col) => {
    const { lang, confidence } = detectColumn(col);
    return lang === 'de' && confidence >= 0.6;
  });
  const isGerman = (cell, inGermanColumn) => {
    const { lang, confidence } = detectLanguage(plain(cell));
    return inGermanColumn ? !(lang === 'fr' && confidence >= 0.8) : lang === 'de' && confidence >= 0.9;
  };
  return rows.map((cells) =>
    cells
      .map((cell, i) => {
        if (!CIRCUMFLEX.test(cell)) return cell;
        const inGermanColumn = cells.length >= 2 && Boolean(germanColumn[i]);
        return isGerman(cell, inGermanColumn) ? cell.replace(CIRCUMFLEXES, (c) => UMLAUT_OF[c]) : cell;
      })
      .join('\t'),
  );
}

function collect(data, key) {
  if (data && Array.isArray(data[key]) && data[key].length) return data[key];
  // Newer result shape: blocks → paragraphs → lines → words.
  const out = [];
  for (const block of (data && data.blocks) || []) {
    for (const para of (block && block.paragraphs) || []) {
      for (const line of (para && para.lines) || []) {
        if (key === 'lines') out.push(line);
        else for (const word of (line && line.words) || []) out.push(word);
      }
    }
  }
  return out;
}

function baselineY(word) {
  const { bbox, baseline: bl } = word;
  if (bl && bl.has_baseline !== false && Number.isFinite(bl.y0) && Number.isFinite(bl.y1)) {
    const cx = (bbox.x0 + bbox.x1) / 2;
    const span = bl.x1 - bl.x0;
    const t = span > 0 ? Math.min(1, Math.max(0, (cx - bl.x0) / span)) : 0.5;
    const y = bl.y0 + (bl.y1 - bl.y0) * t;
    // Ignore implausible baselines (outside the word box ± its height).
    const h = bbox.y1 - bbox.y0;
    if (y >= bbox.y0 && y <= bbox.y1 + h) return y;
  }
  return bbox.y1;
}

// Converts a tesseract.js result (`data`) into text lines, rebuilding rows and
// table columns from the word boxes. Falls back to the plain text output.
export function ocrDataToText(data) {
  if (!data) return '';
  const items = [];
  for (const word of collect(data, 'words')) {
    if (!word || !word.bbox) continue;
    const raw = String(word.text || '').trim();
    const text = raw.replace(EDGE_BARS, '').trim();
    if (!text || NOISE_WORD.test(text)) continue;
    const conf = Number(word.confidence);
    if (Number.isFinite(conf) && conf < 30 && !/[\p{L}\p{N}]/u.test(text)) continue;
    const { x0, y0, x1, y1 } = word.bbox;
    if (![x0, y0, x1, y1].every(Number.isFinite) || x1 <= x0 || y1 <= y0) continue;
    // Adjust the box when border bars were stripped from the word's start.
    const per = (x1 - x0) / Math.max(1, raw.length);
    const lead = raw.length - raw.replace(/^[|¦]+/, '').length;
    const x = x0 + lead * per;
    const w = Math.max(per, text.length * per);
    // A trailing space (with its width) marks a word boundary for layout.
    items.push({ str: `${text} `, x, y: baselineY(word), w: (w * (text.length + 1)) / text.length, h: y1 - y0 });
  }
  if (!items.length) return typeof data.text === 'string' ? fixGermanUmlauts(data.text.trim().split('\n').map(joinCjk)).join('\n') : '';

  const lines = collect(data, 'lines');
  let slope = estimateSlope(
    lines.map((l) => l && l.baseline),
    { minWidth: 120 },
  );
  if (!slope) {
    slope = estimateSlope(
      collect(data, 'words').map((w) => w && w.baseline),
      { minWidth: 80 },
    );
  }
  return fixGermanUmlauts(itemsToLines(deskewItems(items, slope)).map(joinCjk)).join('\n');
}

// Chinese (and Japanese) text without the spaces between OCR words.
function joinCjk(line) {
  return line.replace(CJK_SPACE, '$1');
}

// ---------------------------------------------------------------------------
// Browser plumbing

function loadTesseract() {
  const existing = globalThis.Tesseract;
  if (existing && typeof existing.createWorker === 'function') return Promise.resolve(existing);
  if (!tesseractPromise) {
    tesseractPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = TESSERACT_URL;
      script.async = true;
      script.crossOrigin = 'anonymous';
      script.integrity = TESSERACT_SRI;
      script.onload = () => {
        const T = globalThis.Tesseract;
        if (T && typeof T.createWorker === 'function') resolve(T);
        else reject(ocrError(MSG_START, 'OCR_LOAD'));
      };
      script.onerror = () => {
        script.remove();
        reject(ocrError(isOffline() ? MSG_OFFLINE : MSG_START, isOffline() ? 'OFFLINE' : 'OCR_LOAD'));
      };
      document.head.appendChild(script);
    });
    tesseractPromise.catch(() => {
      tesseractPromise = null;
    });
  }
  return tesseractPromise;
}

function loadImageElement(blob) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.decoding = 'async';
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(ocrError(MSG_DECODE, 'DECODE'));
    };
    img.src = url;
  });
}

async function decodeImage(blob) {
  if (typeof createImageBitmap === 'function') {
    try {
      return await createImageBitmap(blob, { imageOrientation: 'from-image' });
    } catch {
      try {
        return await createImageBitmap(blob);
      } catch {
        // fall through to <img>, which also handles formats like HEIC in Safari
      }
    }
  }
  return loadImageElement(blob);
}

function sourceSize(src) {
  return {
    width: src.naturalWidth || src.videoWidth || src.width || 0,
    height: src.naturalHeight || src.videoHeight || src.height || 0,
  };
}

function isCanvasLike(src) {
  return (
    (typeof HTMLCanvasElement !== 'undefined' && src instanceof HTMLCanvasElement) ||
    (typeof OffscreenCanvas !== 'undefined' && src instanceof OffscreenCanvas)
  );
}

// Draws the image on a white canvas at the recognition scale. Canvas sources
// (e.g. rendered PDF pages) are used at their size when `rescale` is false.
async function toRecognitionCanvas(source, { rescale = true } = {}) {
  let src = source;
  let decoded = null;
  if (!isCanvasLike(source) && typeof Blob !== 'undefined' && source instanceof Blob) {
    decoded = await decodeImage(source);
    src = decoded;
  }
  const { width, height } = sourceSize(src);
  if (!width || !height) throw ocrError(MSG_DECODE, 'DECODE');
  if (!rescale && isCanvasLike(src)) return src;
  const scale = rescale ? imageScaleFor(width, height) : 1;
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  const ctx = canvas.getContext('2d', { alpha: false });
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(src, 0, 0, canvas.width, canvas.height);
  if (decoded && typeof decoded.close === 'function') decoded.close();
  return canvas;
}

function canvasToBlob(canvas) {
  if (typeof canvas.convertToBlob === 'function') return canvas.convertToBlob({ type: 'image/png' });
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(ocrError(MSG_DECODE, 'DECODE'))), 'image/png');
  });
}

function releaseCanvas(canvas) {
  canvas.width = 0;
  canvas.height = 0;
}

function initStage(status) {
  const s = String(status || '');
  if (s.startsWith('loading tesseract core')) return [0, 0.15];
  if (s.startsWith('initializing tesseract')) return [0.15, 0.2];
  if (s.startsWith('loading language traineddata')) return [0.2, 0.9];
  if (s.startsWith('initializing api')) return [0.9, 1];
  return null;
}

// Starts one tesseract worker that can recognise several images (e.g. the
// pages of a scanned PDF) without reloading the language data each time.
// `onProgress(fraction, message)` reports the start-up (download) phase.
export async function createRecognizer({ langs = ['fra', 'deu'], onProgress } = {}) {
  const report = reporter(onProgress);
  report(0, MSG_LOADING);
  const T = await loadTesseract();
  const state = { handler: null };
  const logger = (m) => {
    if (state.handler) state.handler(m);
  };
  state.handler = (m) => {
    const stage = m && initStage(m.status);
    if (!stage) return;
    const p = Number.isFinite(m.progress) ? m.progress : 0;
    report(stage[0] + (stage[1] - stage[0]) * p, MSG_LOADING);
  };
  let worker;
  try {
    worker = await T.createWorker(langs && langs.length ? langs : ['fra', 'deu'], 1, {
      logger,
      errorHandler: () => {},
    });
  } catch (e) {
    throw ocrError(isOffline() ? MSG_OFFLINE : MSG_START, isOffline() ? 'OFFLINE' : 'OCR_LOAD', e);
  } finally {
    state.handler = null;
  }
  report(1, MSG_LOADING);

  let busy = Promise.resolve();
  let terminated = false;

  async function recognizeOne(source, { onProgress: onPage, rescale = true } = {}) {
    if (terminated) throw ocrError(MSG_FAILED, 'OCR_FAILED');
    const pageReport = reporter(onPage);
    pageReport(0, percentLabel(0));
    let canvas;
    try {
      canvas = await toRecognitionCanvas(source, { rescale });
    } catch (e) {
      throw e && e.code === 'DECODE' ? e : ocrError(MSG_DECODE, 'DECODE', e);
    }
    let blob;
    try {
      blob = await canvasToBlob(canvas);
    } finally {
      if (canvas !== source) releaseCanvas(canvas);
    }
    state.handler = (m) => {
      if (m && String(m.status).startsWith('recognizing text')) {
        const p = Number.isFinite(m.progress) ? m.progress : 0;
        pageReport(p, percentLabel(p));
      }
    };
    try {
      const result = await worker.recognize(blob);
      pageReport(1, percentLabel(1));
      return ocrDataToText(result && result.data);
    } catch (e) {
      throw ocrError(MSG_FAILED, 'OCR_FAILED', e);
    } finally {
      state.handler = null;
    }
  }

  return {
    // Recognises one image (Blob/File, canvas, ImageBitmap or <img>); calls are queued.
    recognize(source, opts) {
      const job = busy.then(() => recognizeOne(source, opts));
      busy = job.catch(() => {});
      return job;
    },
    async terminate() {
      if (terminated) return;
      terminated = true;
      try {
        await worker.terminate();
      } catch {
        // The worker may already be gone; nothing else to clean up.
      }
    },
  };
}

// Recognises the text on a photo or screenshot. Returns plain text lines
// (table columns separated by tabs), '' when nothing was found.
// signal: optional AbortSignal; aborting stops the engine and rejects with
// code 'ABORTED' (name 'AbortError').
export async function recognizeImage(file, { langs = ['fra', 'deu'], onProgress, signal } = {}) {
  const report = reporter(onProgress);
  throwIfAborted(signal);
  report(0, 'Bild wird vorbereitet …');
  // Decode first so that unreadable files fail before the engine is downloaded.
  let canvas;
  try {
    canvas = await toRecognitionCanvas(file);
  } catch (e) {
    throw e && e.code === 'DECODE' ? e : ocrError(MSG_DECODE, 'DECODE', e);
  }
  try {
    throwIfAborted(signal);
    const recognizer = await createRecognizer({
      langs,
      onProgress: (f, msg) => report(0.02 + 0.28 * f, msg),
    });
    // The engine finished starting after an abort: shut it down right away.
    let stop = null;
    try {
      throwIfAborted(signal);
      if (signal && typeof signal.addEventListener === 'function') {
        stop = () => {
          recognizer.terminate();
        };
        signal.addEventListener('abort', stop, { once: true });
      }
      const text = await recognizer.recognize(canvas, {
        rescale: false,
        onProgress: (f, msg) => report(0.3 + 0.7 * f, msg),
      });
      throwIfAborted(signal);
      return text;
    } catch (e) {
      // A recognition cut short by terminate() reports OCR_FAILED; the abort is the real cause.
      if (signal && signal.aborted) throw abortError();
      throw e;
    } finally {
      if (stop) signal.removeEventListener('abort', stop);
      await recognizer.terminate();
    }
  } finally {
    releaseCanvas(canvas);
  }
}
