// Turns a dropped, picked or pasted File into text for the vocabulary parser:
// text files are decoded, PDFs go through pdf.js, photos through OCR.
// Browser only — no DOM access at import time.

import { extractPdfText } from './pdf.js';
import { recognizeImage, ocrLangsFor } from './ocr.js';

// Value for <input type="file" accept="…">.
export const ACCEPT = '.txt,.text,.csv,.tsv,.tab,.md,.pdf,application/pdf,text/plain,text/csv,image/*,.heic,.heif';

const TEXT_EXT = new Set(['txt', 'text', 'csv', 'tsv', 'tab', 'md', 'markdown']);
const IMAGE_EXT = new Set(['png', 'jpg', 'jpeg', 'jpe', 'jfif', 'pjpeg', 'pjp', 'heic', 'heif', 'webp', 'gif', 'bmp', 'avif', 'tif', 'tiff']);
const HEIC_EXT = new Set(['heic', 'heif']);
const DOCUMENT_EXT = new Set(['doc', 'docx', 'odt', 'pages', 'rtf', 'xls', 'xlsx', 'numbers', 'key', 'ppt', 'pptx']);
const TEXT_TYPES = new Set(['application/csv', 'application/x-csv', 'application/tab-separated-values']);
const NON_TEXT_TEXT_TYPES = new Set(['text/html', 'text/rtf', 'text/xml', 'text/javascript', 'text/css']);
const MAX_TEXT_BYTES = 5 * 1024 * 1024;

const MSG_UNSUPPORTED = 'Dieses Dateiformat wird nicht unterstützt.';
const MSG_DOCUMENT = `${MSG_UNSUPPORTED} Kopiere den Text aus dem Dokument und füge ihn ins Textfeld ein – oder speichere es als PDF.`;
const MSG_EMPTY = 'Die Datei ist leer.';
const MSG_TOO_LARGE = 'Die Textdatei ist zu gross (maximal 5 MB).';
// Neutral wording: the Windows app (WebView2) cannot decode HEIC either.
const MSG_HEIC =
  'HEIC-Fotos kann Wortschatz auf diesem Gerät nicht öffnen. Mache bitte einen Screenshot des Fotos oder exportiere es als JPG und versuche es erneut.';
const MSG_PDF_EMPTY = 'In der PDF-Datei wurde kein Text gefunden.';
const MSG_READ = 'Die Datei konnte nicht gelesen werden. Ist sie noch vorhanden und vollständig heruntergeladen?';
const MSG_ABORTED = 'Import abgebrochen.';
const MSG_IMAGE_EMPTY =
  'Auf dem Bild wurde kein Text erkannt. Achte auf gutes Licht und eine scharfe Aufnahme und fotografiere die Seite möglichst gerade.';

function fileError(message, code, cause) {
  const err = new Error(message);
  err.code = code;
  if (cause !== undefined) err.cause = cause;
  return err;
}

function abortError() {
  const err = fileError(MSG_ABORTED, 'ABORTED');
  err.name = 'AbortError';
  return err;
}

function throwIfAborted(signal) {
  if (signal && signal.aborted) throw abortError();
}

// Settles like `promise`, or rejects with an AbortError as soon as `signal` aborts.
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

function extensionOf(name) {
  const n = String(name || '').toLowerCase();
  const dot = n.lastIndexOf('.');
  return dot > 0 && dot < n.length - 1 ? n.slice(dot + 1) : '';
}

function mimeOf(file) {
  return String((file && file.type) || '')
    .toLowerCase()
    .split(';')[0]
    .trim();
}

// 'text' | 'pdf' | 'image' | null (unsupported), from MIME type and file name.
export function detectFileKind(file) {
  if (!file) return null;
  const ext = extensionOf(file.name);
  const type = mimeOf(file);
  if (type === 'application/pdf' || ext === 'pdf') return 'pdf';
  if (DOCUMENT_EXT.has(ext)) return null;
  if (TEXT_EXT.has(ext)) return 'text';
  if (type === 'image/svg+xml' || ext === 'svg') return null;
  if (IMAGE_EXT.has(ext) || type.startsWith('image/')) return 'image';
  if (NON_TEXT_TEXT_TYPES.has(type)) return null;
  if (type.startsWith('text/') || TEXT_TYPES.has(type)) return 'text';
  if (!ext && !type) return 'text';
  return null;
}

function isHeic(file, sniffed) {
  const type = mimeOf(file);
  return sniffed === 'heic' || HEIC_EXT.has(extensionOf(file && file.name)) || type === 'image/heic' || type === 'image/heif' || type.startsWith('image/heic-') || type.startsWith('image/heif-');
}

// Content sniffing so mislabeled files (e.g. a PDF without extension) still work.
function sniff(bytes) {
  const b = bytes;
  const ascii = (from, to) => String.fromCharCode(...b.slice(from, to));
  if (b.length >= 5 && ascii(0, 5) === '%PDF-') return 'pdf';
  if (b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'image';
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image';
  if (b.length >= 4 && ascii(0, 4) === 'GIF8') return 'image';
  if (b.length >= 12 && ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP') return 'image';
  if (b.length >= 12 && ascii(4, 8) === 'ftyp') {
    const brand = ascii(8, 12);
    if (/^(heic|heix|hevc|hevx|heim|heis|mif1|msf1)$/.test(brand)) return 'heic';
    if (/^avi[fs]$/.test(brand)) return 'image';
  }
  return null;
}

function decodeWith(label, bytes) {
  return new TextDecoder(label).decode(bytes);
}

// UTF-16 without BOM: one of the two byte lanes is mostly zero (Latin text).
function utf16Lane(bytes) {
  const n = Math.min(bytes.length, 1024) & ~1;
  if (n < 4) return null;
  let evenZero = 0;
  let oddZero = 0;
  for (let i = 0; i < n; i += 2) {
    if (bytes[i] === 0) evenZero++;
    if (bytes[i + 1] === 0) oddZero++;
  }
  const pairs = n / 2;
  if (oddZero > pairs * 0.4 && evenZero < pairs * 0.05) return 'utf-16le';
  if (evenZero > pairs * 0.4 && oddZero < pairs * 0.05) return 'utf-16be';
  return null;
}

// Bytes → string: BOMs are honoured, UTF-8 is tried strictly first and
// Windows-1252 (old Excel/Windows exports) is the fallback.
export function decodeText(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return decodeWith('utf-8', bytes.subarray(3));
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return decodeWith('utf-16le', bytes.subarray(2));
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return decodeWith('utf-16be', bytes.subarray(2));
  const lane = utf16Lane(bytes);
  if (lane) return decodeWith(lane, bytes);
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return decodeWith('windows-1252', bytes);
  }
}

// Binary data decoded as text shows up as many control characters.
function looksBinary(text) {
  const sample = text.slice(0, 4096);
  if (!sample) return false;
  const controls = sample.match(/[\u0000-\u0008\u000E-\u001F\u007F]/g);
  return Boolean(controls) && controls.length > sample.length * 0.02;
}

function reporter(onProgress) {
  if (typeof onProgress !== 'function') return () => {};
  return (fraction, message) => {
    try {
      onProgress(Math.min(1, Math.max(0, fraction || 0)), message);
    } catch {
      // ignore errors from the UI callback
    }
  };
}

// Reads an import file. Resolves to { text, kind: 'text'|'pdf'|'image', name, warnings };
// rejects with a German, user-presentable Error (err.code for programmatic use).
// warnings: German messages about content that could not be read although the
//   import worked (e.g. scanned pages of a text PDF); [] when everything was read.
// signal: optional AbortSignal; aborting rejects with code 'ABORTED' and stops
//   the PDF reading and its text recognition.
export async function readImportFile(file, { termLang = 'fr', onProgress, signal } = {}) {
  if (!file || typeof file.arrayBuffer !== 'function') throw fileError(MSG_UNSUPPORTED, 'UNSUPPORTED');
  const name = String(file.name || '');
  const report = reporter(onProgress);
  throwIfAborted(signal);
  if (!file.size) throw fileError(MSG_EMPTY, 'EMPTY');

  let sniffed = null;
  try {
    sniffed = sniff(new Uint8Array(await file.slice(0, 16).arrayBuffer()));
  } catch {
    sniffed = null;
  }
  const declared = detectFileKind(file);
  const kind = sniffed === 'heic' ? 'image' : sniffed || declared;
  if (!kind) {
    throw fileError(DOCUMENT_EXT.has(extensionOf(name)) ? MSG_DOCUMENT : MSG_UNSUPPORTED, 'UNSUPPORTED');
  }

  if (kind === 'text') {
    if (file.size > MAX_TEXT_BYTES) throw fileError(MSG_TOO_LARGE, 'TOO_LARGE');
    report(0, 'Datei wird gelesen …');
    let buffer;
    try {
      buffer = await file.arrayBuffer();
    } catch (e) {
      // e.g. a dropped folder or a cloud file that is not downloaded
      throw fileError(MSG_READ, 'READ', e);
    }
    throwIfAborted(signal);
    const text = decodeText(buffer).replace(/^\uFEFF/, '');
    if (looksBinary(text)) throw fileError(MSG_UNSUPPORTED, 'UNSUPPORTED');
    report(1, 'Datei gelesen');
    return { text, kind: 'text', name, warnings: [] };
  }

  const langs = ocrLangsFor(termLang);

  if (kind === 'pdf') {
    const warnings = [];
    const text = await extractPdfText(file, {
      onProgress: report,
      ocrLangs: langs,
      signal,
      onWarning: (message) => warnings.push(message),
    });
    if (!text.trim()) throw fileError(MSG_PDF_EMPTY, 'NO_TEXT');
    return { text, kind: 'pdf', name, warnings };
  }

  let text;
  try {
    // recognizeImage gets the signal so it can stop its engine; the race makes
    // an abort take effect immediately either way.
    text = await abortable(recognizeImage(file, { langs, onProgress: report, signal }), signal);
  } catch (e) {
    if (e && e.code === 'DECODE' && isHeic(file, sniffed)) throw fileError(MSG_HEIC, 'HEIC', e);
    throw e;
  }
  if (!text.trim()) throw fileError(MSG_IMAGE_EMPTY, 'NO_TEXT');
  return { text, kind: 'image', name, warnings: [] };
}
