// pdf.js text items → layout items (src/import/pdf.js): right-to-left runs.
// A tiny pdf.js stand-in runs extractPdfText under jsc.
import { test, expect, run } from './harness.js';
import { extractPdfText, toLayoutItems } from '../src/import/pdf.js';

const Util = {
  transform: (a, b) => [
    a[0] * b[0] + a[2] * b[1],
    a[1] * b[0] + a[3] * b[1],
    a[0] * b[2] + a[2] * b[3],
    a[1] * b[2] + a[3] * b[3],
    a[0] * b[4] + a[2] * b[5] + a[4],
    a[1] * b[4] + a[3] * b[5] + a[5],
  ],
};
const viewport = { transform: [1, 0, 0, -1, 0, 800], scale: 1, width: 600, height: 800 };

// One text run as pdf.js reports it (PDF space, bottom-left origin); rtl runs end at x.
function item(str, x, y, dir = 'ltr') {
  const width = str.length * 6;
  return { str, dir, transform: [12, 0, 0, 12, dir === 'rtl' ? x - width : x, y], width, height: 12 };
}

const ROWS = [
  ['die alte Stadt', 'المدينة القديمة'],
  ['der grosse Junge', 'الولد الكبير'],
  ['das Buch', 'الكتاب'],
  ['die Schule', 'المدرسة'],
];

function rowItems() {
  return ROWS.flatMap(([de, ar], k) => [item(de, 50, 700 - k * 20), item(ar, 400, 700 - k * 20, 'rtl')]);
}

function fakePdfJs(items) {
  const page = {
    getViewport: () => viewport,
    getTextContent: async () => ({ items }),
    getOperatorList: async () => ({ fnArray: [] }),
    cleanup() {},
  };
  const doc = { numPages: 1, getPage: async () => page, destroy: async () => {} };
  return { OPS: {}, Util, getDocument: () => ({ promise: Promise.resolve(doc), destroy: async () => {} }) };
}

function pdfFile() {
  const bytes = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37]); // %PDF-1.7
  return { name: 'arabisch.pdf', type: 'application/pdf', size: bytes.length, arrayBuffer: async () => bytes.buffer };
}

test('toLayoutItems passes the text direction on', () => {
  const items = toLayoutItems([item('das Buch', 50, 700), item('الكتاب', 400, 700, 'rtl'), { ...item('x', 10, 10), dir: undefined }], viewport, Util);
  expect(items.map((it) => it.dir)).toEqual(['ltr', 'rtl', undefined]);
  expect(items[1].str).toBe('الكتاب');
  expect(items[1].x).toBe(400 - 6 * 6);
  expect(items[1].y).toBe(100);
});

test('extractPdfText: Arabic runs of a table keep their logical word order', async () => {
  const text = await extractPdfText(pdfFile(), { pdfjs: fakePdfJs(rowItems()) });
  expect(text).toBe(ROWS.map(([de, ar]) => `${de}\t${ar}`).join('\n'));
});

test('extractPdfText: an Arabic cell drawn as several runs is read from right to left', async () => {
  const items = [
    item('die alte Stadt', 50, 700),
    item('المدينة', 400, 700, 'rtl'),
    item('القديمة', 400 - 8 * 6, 700, 'rtl'),
    ...rowItems().slice(2),
  ];
  const text = await extractPdfText(pdfFile(), { pdfjs: fakePdfJs(items) });
  expect(text.split('\n')[0]).toBe('die alte Stadt\tالمدينة القديمة');
});

await run('pdf.test.js');
