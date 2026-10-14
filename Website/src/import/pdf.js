// PDF text extraction with pdf.js (loaded lazily from jsDelivr on first use).
// Text-layer PDFs are read directly and their layout (table columns,
// paragraphs) is rebuilt; scanned pages without a text layer are rendered and
// passed through OCR. Browser only — no DOM access at import time.

import { itemsToLines } from './layout.js';
import { createRecognizer } from './ocr.js';

const PDFJS_ROOT = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.10.38/';
const PDFJS_URL = `${PDFJS_ROOT}build/pdf.min.mjs`;
const PDFJS_WORKER_URL = `${PDFJS_ROOT}build/pdf.worker.min.mjs`;

const MAX_OCR_PAGES = 30;
const RENDER_TARGET_WIDTH = 2000; // px; scanned pages are rendered at scale 2–4
const RENDER_MAX_SIDE = 3000;
const MAX_ANGLE = 0.2; // radians; rotated text (margin notes, stamps) is skipped

const MSG_LOAD = 'Zum Lesen von PDF-Dateien wird eine Internetverbindung benötigt.';
const MSG_LOAD_FAILED = 'Der PDF-Leser konnte nicht geladen werden. Bitte versuche es erneut.';
const MSG_PASSWORD = 'Diese PDF-Datei ist passwortgeschützt. Entferne den Schutz oder kopiere den Text direkt aus der PDF.';
const MSG_INVALID = 'Die PDF-Datei ist beschädigt oder keine gültige PDF.';
const MSG_FAILED = 'Die PDF-Datei konnte nicht gelesen werden.';
const MSG_READ = 'Die Datei konnte nicht gelesen werden. Ist sie noch vorhanden und vollständig heruntergeladen?';
const MSG_ABORTED = 'Import abgebrochen.';

let libPromise = null;

function pdfError(message, code, cause) {
  const err = new Error(message);
  err.code = code;
  if (cause !== undefined) err.cause = cause;
  return err;
}

function abortError() {
  const err = pdfError(MSG_ABORTED, 'ABORTED');
  err.name = 'AbortError';
  return err;
}

const isAbort = (e) => !!e && (e.code === 'ABORTED' || e.name === 'AbortError');

function throwIfAborted(signal) {
  if (signal && signal.aborted) throw abortError();
}

// Settles like `promise`, or rejects with an AbortError as soon as `signal` aborts
// (the work behind `promise` is stopped by the caller's cleanup).
function abortable(promise, signal) {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortError());
    signal.addEventListener('abort', onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener('abort', onAbort);
        resolve(value);
      },
      (err) => {
        signal.removeEventListener('abort', onAbort);
        reject(err);
      },
    );
  });
}

// Shown when scanned pages of an otherwise readable PDF could not be recognised.
function skippedPagesMessage(pages, cause) {
  const n = pages.length;
  let which;
  if (n === 1) which = `Seite ${pages[0]} ist gescannt und konnte`;
  else if (n <= 6) which = `Die Seiten ${pages.slice(0, -1).join(', ')} und ${pages[n - 1]} sind gescannt und konnten`;
  else which = `${n} Seiten sind gescannt und konnten`;
  let reason = 'Versuche es später noch einmal.';
  if (cause && cause.code === 'PDF_TOO_MANY_PAGES') {
    reason = `Die Texterkennung ist auf ${MAX_OCR_PAGES} Seiten beschränkt – teile die Datei bitte auf.`;
  } else if (cause && cause.code === 'OFFLINE') {
    reason = 'Für die Texterkennung wird eine Internetverbindung benötigt.';
  }
  return `${which} nicht gelesen werden – die Vokabeln darauf fehlen. ${reason}`;
}

function reporter(onProgress) {
  if (typeof onProgress !== 'function') return () => {};
  return (fraction, message) => {
    try {
      onProgress(Math.min(1, Math.max(0, fraction || 0)), message);
    } catch {
      // Progress callbacks must never break the extraction.
    }
  };
}

// pdf.js 4.x relies on Promise.withResolvers (Safari < 17.4, older Chromium).
function ensurePromiseWithResolvers() {
  if (typeof Promise.withResolvers === 'function') return;
  Object.defineProperty(Promise, 'withResolvers', {
    configurable: true,
    writable: true,
    value: function withResolvers() {
      let resolve;
      let reject;
      const promise = new this((res, rej) => {
        resolve = res;
        reject = rej;
      });
      return { promise, resolve, reject };
    },
  });
}

// Loads pdf.js once (the promise is cached; a failed load can be retried).
export function loadPdfJs() {
  if (!libPromise) {
    libPromise = (async () => {
      ensurePromiseWithResolvers();
      let lib;
      try {
        lib = await import(PDFJS_URL);
      } catch (e) {
        const offline = typeof navigator !== 'undefined' && navigator.onLine === false;
        throw pdfError(offline ? MSG_LOAD : MSG_LOAD_FAILED, offline ? 'OFFLINE' : 'PDF_LOAD', e);
      }
      lib.GlobalWorkerOptions.workerSrc = PDFJS_WORKER_URL;
      return lib;
    })();
    libPromise.catch(() => {
      libPromise = null;
    });
  }
  return libPromise;
}

function openError(e) {
  const name = e && e.name;
  if (name === 'PasswordException') return pdfError(MSG_PASSWORD, 'PDF_PASSWORD', e);
  if (name === 'InvalidPDFException' || name === 'MissingPDFException' || name === 'FormatError') {
    return pdfError(MSG_INVALID, 'PDF_INVALID', e);
  }
  return pdfError(MSG_FAILED, 'PDF_FAILED', e);
}

// pdf.js text items → layout items in viewport space (top-left origin, page
// rotation and crop box applied): x = left edge, y = baseline.
function toLayoutItems(textItems, viewport, Util) {
  const items = [];
  for (const it of textItems || []) {
    if (!it || typeof it.str !== 'string' || !it.str.trim() || !Array.isArray(it.transform)) continue;
    const tx = Util.transform(viewport.transform, it.transform);
    if (Math.abs(Math.atan2(tx[1], tx[0])) > MAX_ANGLE) continue;
    const fontHeight = Math.hypot(tx[2], tx[3]);
    items.push({
      str: it.str,
      x: tx[4],
      y: tx[5],
      w: Math.abs(it.width || 0) * viewport.scale,
      h: it.height > 0 ? it.height * viewport.scale : fontHeight,
    });
  }
  return items;
}

function visibleChars(items) {
  let n = 0;
  for (const it of items) n += it.str.replace(/\s+/g, '').length;
  return n;
}

async function pageHasImages(page, OPS) {
  const imageOps = new Set(
    [
      'paintImageXObject',
      'paintImageXObjectRepeat',
      'paintInlineImageXObject',
      'paintInlineImageXObjectGroup',
      'paintImageMaskXObject',
      'paintImageMaskXObjectGroup',
      'paintImageMaskXObjectRepeat',
      'paintSolidColorImageMask',
      'paintJpegXObject',
    ]
      .map((k) => OPS && OPS[k])
      .filter((v) => v !== undefined),
  );
  try {
    const list = await page.getOperatorList();
    return list.fnArray.some((fn) => imageOps.has(fn));
  } catch {
    return true;
  }
}

async function renderPage(page) {
  const base = page.getViewport({ scale: 1 });
  let scale = Math.min(4, Math.max(2, RENDER_TARGET_WIDTH / base.width));
  scale = Math.min(scale, RENDER_MAX_SIDE / Math.max(base.width, base.height));
  const viewport = page.getViewport({ scale });
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.floor(viewport.width));
  canvas.height = Math.max(1, Math.floor(viewport.height));
  const ctx = canvas.getContext('2d', { alpha: false });
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  // 'print' intent renders without requestAnimationFrame, so OCR keeps going
  // while the tab is in the background.
  await page.render({ canvasContext: ctx, viewport, intent: 'print' }).promise;
  return canvas;
}

// Renders the given pages and replaces their text with the OCR result.
// Recognised page numbers are added to `done` (also when a later page fails).
async function recognizePages(doc, pages, texts, { ocrLangs, report, start, label, signal, done }) {
  const span = 1 - start;
  report(start, `${label} – Texterkennung läuft …`);
  throwIfAborted(signal);
  const starting = createRecognizer({
    langs: ocrLangs,
    onProgress: (f, msg) => report(start + span * 0.2 * f, `${label} – ${msg}`),
  });
  let recognizer;
  try {
    recognizer = await abortable(starting, signal);
  } catch (e) {
    // Aborted while the engine was starting: shut it down once it is up.
    if (isAbort(e)) starting.then((r) => r.terminate(), () => {});
    throw e;
  }
  // Stops the running recognition right away instead of after the current page.
  const stop = () => recognizer.terminate();
  if (signal) signal.addEventListener('abort', stop, { once: true });
  try {
    for (let k = 0; k < pages.length; k++) {
      throwIfAborted(signal);
      const i = pages[k];
      const from = start + span * (0.2 + (0.8 * k) / pages.length);
      const width = (span * 0.8) / pages.length;
      const prefix = pages.length > 1 ? `Seite ${k + 1} von ${pages.length} – ` : '';
      const page = await doc.getPage(i);
      const canvas = await abortable(renderPage(page), signal);
      page.cleanup();
      try {
        const text = await abortable(
          recognizer.recognize(canvas, {
            rescale: false,
            onProgress: (f, msg) => report(from + width * f, prefix + msg),
          }),
          signal,
        );
        // Keep any real text the page had (e.g. a header) if OCR found nothing.
        if (text.trim()) texts[i - 1] = text;
        if (done) done.add(i);
      } finally {
        canvas.width = 0;
        canvas.height = 0;
      }
    }
  } finally {
    if (signal) signal.removeEventListener('abort', stop);
    await recognizer.terminate();
  }
}

// Extracts the text of a PDF. Pages are separated by a blank line.
// opts.ocrLangs: tesseract models used for scanned pages (default French + German).
// opts.signal: AbortSignal; aborting stops the reading and the text recognition
//   and rejects with an Error whose code is 'ABORTED' (name 'AbortError').
// opts.onWarning(message): called for problems that do not stop the import,
//   e.g. scanned pages of a text PDF that could not be recognised.
// opts.pdfjs: an already loaded pdf.js module (default: loadPdfJs(); tests pass a stub).
export async function extractPdfText(file, { onProgress, ocrLangs = ['fra', 'deu'], signal, onWarning, pdfjs } = {}) {
  const report = reporter(onProgress);
  const warn = (message) => {
    if (typeof onWarning === 'function') onWarning(message);
  };
  report(0, 'PDF wird geöffnet …');
  throwIfAborted(signal);
  // Read the file first: an unreadable file fails without loading pdf.js.
  let data;
  try {
    data = new Uint8Array(await file.arrayBuffer());
  } catch (e) {
    throw pdfError(MSG_READ, 'READ', e);
  }
  const lib = pdfjs || (await abortable(loadPdfJs(), signal));

  const task = lib.getDocument({
    data,
    isEvalSupported: false,
    cMapUrl: `${PDFJS_ROOT}cmaps/`,
    cMapPacked: true,
    standardFontDataUrl: `${PDFJS_ROOT}standard_fonts/`,
    // Slightly broken PDFs are common; their repair notices are not user-relevant.
    verbosity: lib.VerbosityLevel ? lib.VerbosityLevel.ERRORS : 0,
  });
  let doc;
  try {
    doc = await abortable(task.promise, signal);
  } catch (e) {
    task.destroy().catch(() => {});
    throw isAbort(e) ? e : openError(e);
  }

  try {
    const n = doc.numPages;
    const texts = new Array(n).fill('');
    const chars = new Array(n).fill(0);
    let textShare = 1;
    for (let i = 1; i <= n; i++) {
      throwIfAborted(signal);
      report(((i - 1) / n) * textShare, n > 1 ? `Seite ${i} von ${n} wird gelesen …` : 'PDF wird gelesen …');
      const page = await doc.getPage(i);
      const viewport = page.getViewport({ scale: 1 });
      const content = await page.getTextContent();
      const items = toLayoutItems(content.items, viewport, lib.Util);
      chars[i - 1] = visibleChars(items);
      texts[i - 1] = itemsToLines(items).join('\n');
      // A first page without text hints at a scan: leave room for the OCR phase.
      if (i === 1 && chars[0] < 3) textShare = 0.1;
      page.cleanup();
    }

    // Pages to OCR: all of them when the document has no text layer at all,
    // otherwise text-less pages that contain images (scanned inserts).
    const ocrPages = [];
    const allEmpty = chars.every((c) => c < 3);
    for (let i = 1; i <= n; i++) {
      if (allEmpty) ocrPages.push(i);
      else if (chars[i - 1] < 40) {
        throwIfAborted(signal);
        const page = await doc.getPage(i);
        if (await pageHasImages(page, lib.OPS)) ocrPages.push(i);
        page.cleanup();
      }
    }

    let doneMessage = 'PDF gelesen';
    if (ocrPages.length && allEmpty) {
      if (ocrPages.length > MAX_OCR_PAGES) {
        throw pdfError(
          `Diese PDF-Datei enthält ${ocrPages.length} gescannte Seiten. Die Texterkennung ist auf ${MAX_OCR_PAGES} Seiten beschränkt – teile die Datei bitte auf.`,
          'PDF_TOO_MANY_PAGES',
        );
      }
      await recognizePages(doc, ocrPages, texts, { ocrLangs, report, start: textShare, label: 'PDF enthält keinen Text', signal });
    } else if (ocrPages.length) {
      // Mixed document: scanned inserts are a bonus. If their recognition is
      // impossible (offline, too many pages), keep the text that was read and
      // tell the learner which pages are missing.
      const done = new Set();
      try {
        if (ocrPages.length > MAX_OCR_PAGES) throw pdfError(MSG_FAILED, 'PDF_TOO_MANY_PAGES');
        await recognizePages(doc, ocrPages, texts, { ocrLangs, report, start: 0.95, label: 'Gescannte Seiten', signal, done });
      } catch (e) {
        if (isAbort(e)) throw e;
        const missing = ocrPages.filter((i) => !done.has(i));
        if (missing.length) {
          doneMessage = 'PDF gelesen – gescannte Seiten konnten nicht erkannt werden.';
          warn(skippedPagesMessage(missing, e));
        }
      }
    }

    report(1, doneMessage);
    return texts
      .map((t) => t.trim())
      .filter(Boolean)
      .join('\n\n');
  } finally {
    doc.destroy().catch(() => {});
  }
}
