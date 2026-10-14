// File import adapters (src/import/files.js, src/import/pdf.js) with stubbed
// File objects, a stubbed pdf.js module and a stubbed tesseract engine, so the
// browser-only paths run under jsc: read errors, scanned-page warnings, abort.
import { test, expect, run } from './harness.js';
import { readImportFile } from '../src/import/files.js';
import { extractPdfText } from '../src/import/pdf.js';

const SCAN_OP = 85; // stands for pdf.js OPS.paintImageXObject

// A File-like object whose reads fail like Chrome's NotReadableError.
function unreadableFile(name, type = '') {
  const fail = () => Promise.reject(new Error('The requested file could not be read, typically due to permission problems.'));
  return { name, type, size: 2048, arrayBuffer: fail, slice: () => ({ arrayBuffer: fail }) };
}

function pdfFile() {
  const bytes = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37]); // %PDF-1.7
  return { name: 'liste.pdf', type: 'application/pdf', size: bytes.length, arrayBuffer: async () => bytes.buffer, slice: () => ({ arrayBuffer: async () => bytes.buffer }) };
}

// AbortController stand-in (jsc has none).
function controller() {
  const listeners = new Set();
  const signal = {
    aborted: false,
    addEventListener(type, fn) {
      if (type === 'abort') listeners.add(fn);
    },
    removeEventListener(type, fn) {
      listeners.delete(fn);
    },
  };
  return {
    signal,
    abort() {
      if (signal.aborted) return;
      signal.aborted = true;
      const fns = [...listeners];
      listeners.clear();
      fns.forEach((fn) => fn());
    },
  };
}

// Text items of one table row "term<gap>definition" per entry.
function rowsToItems(rows) {
  const items = [];
  rows.forEach(([term, def], k) => {
    const y = 700 - k * 20;
    items.push({ str: term, transform: [12, 0, 0, 12, 50, y], width: term.length * 6, height: 12 });
    items.push({ str: def, transform: [12, 0, 0, 12, 300, y], width: def.length * 6, height: 12 });
  });
  return items;
}

// Minimal pdf.js stand-in. pages: [{ rows?: [[term, def]], scanned?: boolean }]
function fakePdfJs(pages, log, hooks = {}) {
  const pageObjects = pages.map((p, idx) => ({
    getViewport: ({ scale }) => ({ transform: [scale, 0, 0, -scale, 0, 800 * scale], scale, width: 600 * scale, height: 800 * scale }),
    getTextContent: async () => {
      if (hooks.onTextContent) hooks.onTextContent(idx + 1);
      return { items: rowsToItems(p.rows || []) };
    },
    getOperatorList: async () => ({ fnArray: p.scanned ? [SCAN_OP] : [] }),
    render: () => {
      log.rendered.push(idx + 1);
      return { promise: Promise.resolve() };
    },
    cleanup() {},
  }));
  const doc = {
    numPages: pages.length,
    getPage: async (i) => {
      log.getPage.push(i);
      return pageObjects[i - 1];
    },
    destroy: async () => {
      log.docDestroyed = true;
    },
  };
  return {
    OPS: { paintImageXObject: SCAN_OP },
    Util: {
      transform: (a, b) => [
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
      ],
    },
    getDocument: () => ({ promise: Promise.resolve(doc), destroy: async () => {} }),
  };
}

const newLog = () => ({ getPage: [], rendered: [], docDestroyed: false });

// Canvas stand-in for the page rendering + recognition canvas.
function installFakeDocument() {
  const ctx = { fillRect() {}, drawImage() {} };
  globalThis.document = {
    createElement: () => ({ width: 0, height: 0, getContext: () => ctx, convertToBlob: async () => ({ size: 1 }) }),
  };
}

const TEXT_ROWS = [
  ['le chat', 'die Katze'],
  ['le chien', 'der Hund'],
  ['la maison', 'das Haus'],
  ['le jardin', 'der Garten'],
];

/* ------------------------------------------------- read errors (German) */

test('readImportFile: an unreadable text file fails with a German READ error', async () => {
  let err = null;
  try {
    await readImportFile(unreadableFile('Ordner'));
  } catch (e) {
    err = e;
  }
  expect(!!err).toBe(true);
  expect(err.code).toBe('READ');
  expect(err.message).toBe('Die Datei konnte nicht gelesen werden. Ist sie noch vorhanden und vollständig heruntergeladen?');
});

test('readImportFile: an unreadable PDF fails with a German READ error (before pdf.js is loaded)', async () => {
  let err = null;
  try {
    await readImportFile(unreadableFile('vokabeln.pdf', 'application/pdf'));
  } catch (e) {
    err = e;
  }
  expect(!!err).toBe(true);
  expect(err.code).toBe('READ');
  expect(err.message.includes('could not be read')).toBe(false);
  expect(err.message.includes('ß')).toBe(false);
});

/* ------------------------------------------- scanned pages in text PDFs */

test('extractPdfText: scanned pages that cannot be recognised are reported as a warning', async () => {
  globalThis.Tesseract = {
    createWorker: async () => {
      throw new Error('traineddata download failed');
    },
  };
  const log = newLog();
  const warnings = [];
  const text = await extractPdfText(pdfFile(), {
    pdfjs: fakePdfJs([{ rows: TEXT_ROWS }, { scanned: true }], log),
    onWarning: (m) => warnings.push(m),
  });
  delete globalThis.Tesseract;
  expect(text.includes('le chat')).toBe(true);
  expect(text.includes('der Garten')).toBe(true);
  expect(warnings).toHaveLength(1);
  expect(warnings[0].startsWith('Seite 2 ist gescannt und konnte nicht gelesen werden')).toBe(true);
  expect(warnings[0].includes('ß')).toBe(false);
  expect(log.docDestroyed).toBe(true);
});

test('extractPdfText: the offline case names the missing connection and lists every skipped page', async () => {
  globalThis.Tesseract = {
    createWorker: async () => {
      throw new Error('network');
    },
  };
  globalThis.navigator = { onLine: false };
  const warnings = [];
  try {
    await extractPdfText(pdfFile(), {
      pdfjs: fakePdfJs([{ rows: TEXT_ROWS }, { scanned: true }, { rows: TEXT_ROWS }, { scanned: true }], newLog()),
      onWarning: (m) => warnings.push(m),
    });
  } finally {
    delete globalThis.Tesseract;
    delete globalThis.navigator;
  }
  expect(warnings).toHaveLength(1);
  expect(warnings[0].startsWith('Die Seiten 2 und 4 sind gescannt und konnten nicht gelesen werden')).toBe(true);
  expect(warnings[0].includes('Internetverbindung')).toBe(true);
});

test('extractPdfText: only the scanned pages that failed are reported; recognised ones are kept', async () => {
  installFakeDocument();
  let calls = 0;
  globalThis.Tesseract = {
    createWorker: async () => ({
      recognize: async () => {
        calls++;
        if (calls === 1) return { data: { text: 'le vélo\tdas Velo' } };
        throw new Error('worker crashed');
      },
      terminate: async () => {},
    }),
  };
  const warnings = [];
  let text;
  try {
    text = await extractPdfText(pdfFile(), {
      pdfjs: fakePdfJs([{ rows: TEXT_ROWS }, { scanned: true }, { rows: TEXT_ROWS }, { scanned: true }], newLog()),
      onWarning: (m) => warnings.push(m),
    });
  } finally {
    delete globalThis.Tesseract;
    delete globalThis.document;
  }
  expect(text.includes('le vélo')).toBe(true);
  expect(warnings).toHaveLength(1);
  expect(warnings[0].startsWith('Seite 4 ist gescannt und konnte nicht gelesen werden')).toBe(true);
});

test('extractPdfText: more scanned inserts than the OCR limit are reported with the limit', async () => {
  const pages = [{ rows: TEXT_ROWS }];
  for (let i = 0; i < 31; i++) pages.push({ scanned: true });
  const log = newLog();
  const warnings = [];
  const text = await extractPdfText(pdfFile(), { pdfjs: fakePdfJs(pages, log), onWarning: (m) => warnings.push(m) });
  expect(text.includes('le chat')).toBe(true);
  expect(log.rendered).toEqual([]);
  expect(warnings).toHaveLength(1);
  expect(warnings[0].startsWith('31 Seiten sind gescannt und konnten nicht gelesen werden')).toBe(true);
  expect(warnings[0].includes('30 Seiten beschränkt')).toBe(true);
});

test('extractPdfText: a text PDF without scanned pages warns about nothing', async () => {
  const warnings = [];
  const text = await extractPdfText(pdfFile(), { pdfjs: fakePdfJs([{ rows: TEXT_ROWS }], newLog()), onWarning: (m) => warnings.push(m) });
  expect(text.includes('la maison')).toBe(true);
  expect(warnings).toEqual([]);
});

/* ------------------------------------------------------------- aborting */

test('extractPdfText: aborting while pages are read stops at the next page', async () => {
  const log = newLog();
  const ctl = controller();
  const lib = fakePdfJs([{ rows: TEXT_ROWS }, { rows: TEXT_ROWS }, { rows: TEXT_ROWS }], log, {
    onTextContent: (i) => {
      if (i === 1) ctl.abort();
    },
  });
  let err = null;
  try {
    await extractPdfText(pdfFile(), { pdfjs: lib, signal: ctl.signal });
  } catch (e) {
    err = e;
  }
  expect(!!err).toBe(true);
  expect(err.code).toBe('ABORTED');
  expect(err.name).toBe('AbortError');
  expect(log.getPage).toEqual([1]);
  expect(log.docDestroyed).toBe(true);
});

test('extractPdfText: aborting during text recognition terminates the engine and renders no further page', async () => {
  installFakeDocument();
  const ctl = controller();
  let terminated = 0;
  globalThis.Tesseract = {
    createWorker: async () => ({
      recognize: () => {
        setTimeout(() => ctl.abort(), 0);
        return new Promise(() => {}); // a long recognition that never finishes on its own
      },
      terminate: async () => {
        terminated++;
      },
    }),
  };
  const log = newLog();
  let err = null;
  try {
    await extractPdfText(pdfFile(), {
      pdfjs: fakePdfJs([{ scanned: true }, { scanned: true }, { scanned: true }], log),
      signal: ctl.signal,
    });
  } catch (e) {
    err = e;
  } finally {
    delete globalThis.Tesseract;
    delete globalThis.document;
  }
  expect(!!err).toBe(true);
  expect(err.code).toBe('ABORTED');
  expect(terminated).toBe(1);
  expect(log.rendered).toEqual([1]);
  expect(log.docDestroyed).toBe(true);
});

test('extractPdfText: an abort is not turned into a scanned-page warning', async () => {
  installFakeDocument();
  const ctl = controller();
  globalThis.Tesseract = {
    createWorker: async () => ({
      recognize: () => {
        setTimeout(() => ctl.abort(), 0);
        return new Promise(() => {});
      },
      terminate: async () => {},
    }),
  };
  const warnings = [];
  let err = null;
  try {
    await extractPdfText(pdfFile(), {
      pdfjs: fakePdfJs([{ rows: TEXT_ROWS }, { scanned: true }], newLog()),
      signal: ctl.signal,
      onWarning: (m) => warnings.push(m),
    });
  } catch (e) {
    err = e;
  } finally {
    delete globalThis.Tesseract;
    delete globalThis.document;
  }
  expect(!!err && err.code).toBe('ABORTED');
  expect(warnings).toEqual([]);
});

test('readImportFile: an already aborted signal rejects before anything is read', async () => {
  const ctl = controller();
  ctl.abort();
  let reads = 0;
  const file = { name: 'liste.txt', type: 'text/plain', size: 10, arrayBuffer: async () => (reads++, new ArrayBuffer(10)), slice: () => ({ arrayBuffer: async () => (reads++, new ArrayBuffer(10)) }) };
  let err = null;
  try {
    await readImportFile(file, { signal: ctl.signal });
  } catch (e) {
    err = e;
  }
  expect(!!err && err.code).toBe('ABORTED');
  expect(reads).toBe(0);
});

await run('import-files.test.js');
