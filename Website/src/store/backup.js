// Backup and export helpers. `setToText` is pure; the download/read helpers
// touch browser APIs only inside the functions, so the module imports cleanly
// under jsc.

const READ_ERROR = 'Die Datei konnte nicht gelesen werden.';
const PARSE_ERROR = 'Die Datei ist keine gültige Backup-Datei (JSON).';

function triggerDownload(filename, blob) {
  const doc = globalThis.document;
  const urlApi = globalThis.URL;
  if (!doc || !urlApi || typeof urlApi.createObjectURL !== 'function') {
    throw new Error('Der Download wird in dieser Umgebung nicht unterstützt.');
  }
  const url = urlApi.createObjectURL(blob);
  const a = doc.createElement('a');
  a.href = url;
  a.download = filename;
  a.rel = 'noopener';
  a.style.display = 'none';
  doc.body.appendChild(a);
  a.click();
  a.remove();
  // Revoke later: some browsers start the download asynchronously.
  setTimeout(() => urlApi.revokeObjectURL(url), 1000);
}

export function downloadJson(filename, data) {
  const json = JSON.stringify(data, null, 2);
  triggerDownload(filename, new Blob([json], { type: 'application/json;charset=utf-8' }));
}

export function downloadText(filename, text) {
  triggerDownload(filename, new Blob([String(text ?? '')], { type: 'text/plain;charset=utf-8' }));
}

function fileToText(file) {
  if (file && typeof file.text === 'function') return file.text();
  const Reader = globalThis.FileReader;
  if (!file || typeof Reader !== 'function') return Promise.reject(new Error(READ_ERROR));
  return new Promise((resolve, reject) => {
    const reader = new Reader();
    reader.onload = () => resolve(String(reader.result ?? ''));
    reader.onerror = () => reject(new Error(READ_ERROR));
    reader.readAsText(file);
  });
}

export async function readJsonFile(file) {
  let text;
  try {
    text = await fileToText(file);
  } catch {
    throw new Error(READ_ERROR);
  }
  let data;
  try {
    data = JSON.parse(String(text).replace(/^\uFEFF/, ''));
  } catch {
    throw new Error(PARSE_ERROR);
  }
  if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error(PARSE_ERROR);
  return data;
}

// One field of the text export. Line breaks and tabs inside a field are never
// meaningful for vocabulary, so they become spaces. With ';' between cards, a
// ';' inside a field (alternatives such as "lieben; mögen") becomes ', ':
// grading treats both alike, and importers split cards on every ';' and do
// not honour quotes there. A field that still contains a separator is quoted
// CSV-style so it re-imports intact.
function exportField(value, termSep, cardSep) {
  let s = String(value ?? '').replace(/[\r\n\t]+/g, ' ');
  if (cardSep.trim() === ';') s = s.replace(/\s*;\s*/g, ', ');
  s = s.replace(/ {2,}/g, ' ').trim();
  const clashes = [termSep, cardSep].some((sep) => sep && sep.trim() !== '' && s.includes(sep));
  if (clashes) s = `"${s.replace(/"/g, '""')}"`;
  return s;
}

// Quizlet-compatible text export (default: term TAB definition, one per line).
export function setToText(set, { termSep = '\t', cardSep = '\n' } = {}) {
  const cards = set && Array.isArray(set.cards) ? set.cards : [];
  return cards
    .filter((c) => c && (String(c.term ?? '').trim() || String(c.definition ?? '').trim()))
    .map((c) => exportField(c.term, termSep, cardSep) + termSep + exportField(c.definition, termSep, cardSep))
    .join(cardSep);
}
